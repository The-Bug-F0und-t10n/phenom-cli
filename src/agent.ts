import { OllamaClient, OfflineError, OllamaNotFoundError, OllamaResourceError, OllamaTimeoutError } from './ollama-client.js';
import { SessionState } from './state.js';
import { ToolSystem } from './tools.js';
import { registerAdvancedTools } from './advanced-tools.js';
import { config } from './config.js';
import chalk from 'chalk';
import { Message } from './types.js';
import { eventBus, EventType } from './tui/event-bus.js';
import { SemanticSearch } from './semantic-search.js';
import { detectModelCapabilities, ModelCapabilities } from './model-capabilities.js';
import { SessionBrain, SessionManager } from './session-brain.js';
import { ApiContentPart } from './api-client.js';
import { buildInferenceMessagesUseCase } from './use-cases/build-inference-messages.js';
import { executeToolWithEventsUseCase } from './use-cases/execute-tool-with-events.js';
import { InferenceMessage, runToolLoopUseCase } from './use-cases/run-tool-loop.js';
import { existsSync, readFileSync } from 'fs';
import path from 'path';
import {
  formatToolResultForModelPolicy,
  normalizeToolNameWithAliases
} from './use-cases/tool-execution-policy.js';

type AgentMode = 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis';

const TOOL_PROTOCOL_EXAMPLE = `{"type":"tool","toolName":"read_file","args":{"path":"./src/index.ts"}}`;
const FINAL_PROTOCOL_EXAMPLE = `{"type":"final","content":"your markdown answer"}`;

export class Agent {
  private llm: OllamaClient;
  private state: SessionState;
  private toolSystem: ToolSystem;
  private semanticSearch: SemanticSearch;
  private thinkingActive: boolean = false;
  private streamEnabled: boolean = config.chat.stream;
  // BUG-13 fix: removed useNativeTools — derived directly from modelCapabilities.
  private modelCapabilities: ModelCapabilities;
  private brain: SessionBrain | null = null;
  private sessionManager: SessionManager;

  constructor() {
    this.llm = new OllamaClient();
    this.state = new SessionState();
    this.state.setMode(config.system.mode);
    this.toolSystem = new ToolSystem();
    registerAdvancedTools(this.toolSystem);
    this.semanticSearch = new SemanticSearch();
    const initialModel = String(config.ollama.coderModel || config.ollama.model || 'qwen2.5-coder:latest');
    this.modelCapabilities = detectModelCapabilities(initialModel);
    // BUG-16 fix: applyModelProfileForMode called once in constructor only.
    this.applyModelProfileForMode(config.system.mode);
    this.sessionManager = new SessionManager();
  }

  async initialize(existingSessionId?: string): Promise<string> {
    await this.sessionManager.init();

    if (existingSessionId && existingSessionId.length === 16) {
      this.brain = await this.sessionManager.loadSession(existingSessionId);
      if (this.brain) {
        const savedMessages = this.brain.loadMessages();
        for (const msg of savedMessages) {
          this.state.addMessage(msg as Message);
        }
        return existingSessionId;
      }
    }

    this.brain = await this.sessionManager.createSession();
    return this.brain.getData().sessionId;
  }

  getSessionId(): string | null {
    return this.brain?.getData().sessionId || null;
  }

  getBrain(): SessionBrain | null {
    return this.brain;
  }

  async getMostRecentSessionId(): Promise<string | undefined> {
    const sessions = await this.sessionManager.listSessions();
    return sessions[0]?.id;
  }

  async processInput(userInput: string): Promise<void> {
    return this.processInputInternal(userInput);
  }

  async processInputWithContent(userInput: string, content: ApiContentPart[]): Promise<void> {
    return this.processInputInternal(userInput, content);
  }

  private async processInputInternal(
    userInput: string,
    inputParts?: ApiContentPart[]
  ): Promise<void> {
    const input = String(userInput || '').trim();
    if (!input) return;

    // BUG-16 fix: only re-apply if mode changed (applyModelProfileForMode guards internally).
    this.applyModelProfileForMode(this.state.getMode());

    if (Array.isArray(inputParts) && inputParts.some(p => p?.type === 'image_url') && !this.modelCapabilities.supportsVision) {
      throw new Error(`Modelo atual não suporta visão: ${this.llm.getActiveModel()}`);
    }

    this.state.addMessage({ role: 'user', content: input, timestamp: Date.now() });

    if (this.brain) {
      this.brain.refreshForNewRequest();
      this.brain.setUserRequest(input);
      this.brain.saveMessages(this.state.getState().memory);
    }

    try {
      this.thinkingActive = true;
      eventBus.emit(EventType.THINK_START, { message: input });
      eventBus.emit(EventType.PROGRESS_UPDATE, { message: input });
      eventBus.emit(EventType.SESSION_UPDATE, { sessionId: this.getSessionId() });

      const finalText = await this.runToolLoop(input, inputParts);
      if (!finalText) {
        const fallback = 'Não recebi saída do modelo. Reformule o pedido ou tente novamente.';
        this.emitAssistantMessage(fallback);
      }

      if (this.brain) {
        this.brain.saveMessages(this.state.getState().memory);
        await this.brain.save();
      }

      eventBus.emit(EventType.SESSION_UPDATE, { sessionId: this.getSessionId(), complete: true });
      this.endThinking();
    } catch (error) {
      if (this.brain) {
        this.brain.addNote('error', `Error: ${(error as Error).message}`);
        await this.brain.save();
      }
      if (this.thinkingActive && !(error instanceof OfflineError)) {
        eventBus.emit(EventType.INFERENCE_CANCEL, { reason: this.formatInferenceError(error) });
      }
      this.thinkingActive = false;
      throw error;
    }
  }

  // ── Plan extraction ─────────────────────────────────────────────────

  private extractPlanFromText(text: string): boolean {
    if (!this.brain) return false;
    const lines = text.split('\n');
    let inPlanSection = false;
    const steps: Array<{ title: string; order: number }> = [];
    const planHeaderRe = /^#{1,3}\s*PLAN\s*$/im;

    for (const raw of lines) {
      const line = raw.trim();
      if (planHeaderRe.test(line)) { inPlanSection = true; continue; }
      if (inPlanSection && line.startsWith('#')) break;
      if (!inPlanSection) continue;

      const numbered = line.match(/^(?:[-*]\s*)?(\d+)[.:\)]\s+(.+)$/);
      if (numbered) {
        steps.push({ title: numbered[2].trim(), order: parseInt(numbered[1], 10) });
        continue;
      }
      const bullet = line.match(/^[-*]\s+(.+)$/);
      if (bullet) {
        steps.push({ title: bullet[1].trim(), order: steps.length + 1 });
      }
    }

    if (steps.length === 0) {
      const inlineRe = /(?:^|\n)\s*(?:Step|Passo|Etapa)\s*(\d+)[:.)]\s+([^\n]+)/gi;
      let match: RegExpExecArray | null;
      while ((match = inlineRe.exec('\n' + text)) !== null) {
        steps.push({ title: match[2].trim(), order: parseInt(match[1], 10) });
      }
    }

    if (steps.length > 0) {
      const existing = this.brain.getPlanSteps();
      if (existing.length === 0 || steps.length > existing.length) {
        this.brain.setPlanSteps(steps.map(s => ({
          title: s.title,
          status: 'pending' as const,
          order: s.order
        })));
        return true;
      }
    }
    return false;
  }

  private extractPlanProgressFromText(text: string): void {
    if (!this.brain) return;
    const steps = this.brain.getPlanSteps();
    if (steps.length === 0) return;

    const lower = text.toLowerCase();
    for (const step of steps) {
      const donePattern = new RegExp(
        `(?:step|passo|etapa)\\s*${step.order}\\s*(?:done|complete|conclu[íi]d[oa]|finished|ok)`, 'i'
      );
      if (donePattern.test(lower) && (step.status === 'pending' || step.status === 'in_progress')) {
        this.brain.completeStep(step.id);
        continue;
      }
      const workPattern = new RegExp(
        `(?:working on|starting|executing|come[çc]ando|trabalhando|fazendo).{0,40}(?:step|passo|etapa)?\\s*${step.order}`, 'i'
      );
      if (workPattern.test(lower) && step.status === 'pending') {
        this.brain.setCurrentStep(step.id);
      }
    }
  }

  // ── Core tool loop ──────────────────────────────────────────────────
  //
  // Fixes applied:
  //   BUG-01 / BUG-02: tools only sent when model supports native tool calling.
  //   BUG-03: no secondary LLM repair call; fallback parsing is synchronous only.
  //   BUG-06: consecutive failure counter tracks full-iteration failures only.
  //   BUG-07: message window built once before loop; appended incrementally.
  //   BUG-08: no Agent-level normalizeToolArgs — ToolSystem handles it.
  //   BUG-18: tool result has no [TOOL] prefix noise.
  //   BUG-22: text accepted as final only when it clearly isn't a broken JSON call.

  private async runToolLoop(userInput: string, inputParts?: ApiContentPart[]): Promise<string> {
    return runToolLoopUseCase(
      {
        llm: this.llm,
        state: this.state,
        brain: this.brain,
        streamEnabled: this.streamEnabled,
        supportsNativeTools: this.modelCapabilities.supportsNativeTools,
        toolDefs: this.toolSystem.getToolDefinitions(),
        buildInitialMessages: this.buildInitialMessages.bind(this),
        extractPlanFromText: this.extractPlanFromText.bind(this),
        extractPlanProgressFromText: this.extractPlanProgressFromText.bind(this),
        stripTemplateArtifacts: this.stripTemplateArtifacts.bind(this),
        emitAssistantMessage: this.emitAssistantMessage.bind(this),
        normalizeToolName: this.normalizeToolName.bind(this),
        executeToolWithEvents: this.executeToolWithEvents.bind(this),
        formatToolResultForModel: this.formatToolResultForModel.bind(this),
        streamFileContent: this.streamFileContent.bind(this),
        askModelForMoreIterations: this.askModelForMoreIterations.bind(this),
        maxContextTokens: config.ollama.options.num_ctx || 16384
      },
      userInput,
      inputParts
    );
  }

  private async askModelForMoreIterations(userInput: string): Promise<boolean> {
    const state = this.state.getState();
    const askMessages = [
      ...(state.memory || []).slice(-6),
      {
        role: 'user',
        content: `You reached the tool iteration limit. Do you need more iterations to complete the task? Answer ONLY with "yes" or "no". Task: ${userInput}`
      }
    ];
    try {
      const response = await this.llm.chat(askMessages);
      const answer = (response?.message?.content || '').trim().toLowerCase();
      return answer.startsWith('y') || answer.includes('sim') || answer.includes('preciso') || answer.includes('continue');
    } catch {
      return false;
    }
  }

  // ── Message window ──────────────────────────────────────────────────
  //
  // BUG-07 fix: called once before the tool loop; never called inside the loop.
  // BUG-09 fix: estimateMessagesTokens now accounts for tool_calls payload size.
  // BUG-20 fix: ensures current query is always present as the last user message.

  // Compatibility shim for legacy tests/tools that still call buildMessages().
  // Keep until the test suite and external scripts are migrated.
  private async buildMessages(currentQuery: string): Promise<InferenceMessage[]> {
    return this.buildInitialMessages(currentQuery);
  }

  private async buildInitialMessages(
    currentQuery: string,
    currentUserContent?: ApiContentPart[]
  ): Promise<InferenceMessage[]> {
    return buildInferenceMessagesUseCase({
      systemPrompt: this.buildSystemPrompt(),
      recentMessages: this.state.getRecentMessages(config.system.maxHistory),
      currentQuery,
      currentUserContent,
      maxContextTokens: config.ollama.options.num_ctx || 16384,
      summarizeConversation: this.summarizeConversationWithModel.bind(this)
    });
  }

  private buildSystemPrompt(): string {
    const cwd = process.cwd();
    const projectContext = this.buildProjectContext(cwd);

    const brain = this.brain;
    const contextParts: string[] = [];
    if (brain) {
      const planSteps = brain.getPlanSteps();
      const hasActivePlan = planSteps.some(s => s.status === 'pending' || s.status === 'in_progress');
      if (hasActivePlan) {
        contextParts.push(`## Active Plan\n${brain.getPlanSummary()}`);
      }
      const created = brain.getCreatedFiles();
      if (created.length > 0) {
        contextParts.push(`## Files Modified This Session\n${created.join('\n')}`);
      }
    }
    const sessionContext = contextParts.length > 0 ? `\n${contextParts.join('\n\n')}\n` : '';

    // BUG-03 (system prompt side): tool section and protocol are already conditional.
    const toolSection = this.modelCapabilities.supportsNativeTools
      ? `**Available tools:** ${this.toolSystem.listTools().map(t => t.name).join(', ')}`
      : `**Available tools:**\n${this.toolSystem.listTools().map(t => `- ${t.name}: ${t.description}`).join('\n')}`;

    const callProtocol = this.modelCapabilities.supportsNativeTools
      ? `Use tools via native tool calls whenever an operation is needed.
If native tool call is not emitted, output exactly one JSON tool object:
- Tool call: ${TOOL_PROTOCOL_EXAMPLE}
After all operations are complete, reply with a concise plain-text summary.`
      : `Reply with exactly one JSON object per message:\n- Tool call: ${TOOL_PROTOCOL_EXAMPLE}\n- Final answer: ${FINAL_PROTOCOL_EXAMPLE}`;

    return `You are Phenom, an AI coding assistant. Working directory: ${cwd}
${projectContext}
${sessionContext}
## Behavior
- Preserve your default coding/debugging behavior and reasoning quality.
- Use tools only when needed to inspect or change real project state.
- For existing files, prefer read_file before editing.
- If a tool fails, use the exact error message to correct arguments and retry.
- For large or unclear tasks, create a short plan and execute incrementally.

${callProtocol}

## Tool Reference
- \`read_file\` — read file contents (supports startLine/endLine/maxChars; always do this before editing an existing file)
- \`write_file\` / \`create_file\` — full file write (overwrites existing content)
- \`apply_patch\` — surgical edit: either "path"+"operations":[{"search":"...","replace":"..."}] OR "path"+startLine+endLine+replace
- \`list_dir\` — explore directory structure
- \`run_code\` — execute shell commands
- \`search_code\` — search file contents with regex
- \`delete_file\` — delete a single file
- \`delete_dir\` — delete a directory recursively
- Subdirectories are created automatically

${toolSection}`;
  }

  private buildProjectContext(cwd: string): string {
    const signals: string[] = [];

    const has = (name: string): boolean => existsSync(path.join(cwd, name));
    const tryRead = (name: string): string => {
      try {
        return readFileSync(path.join(cwd, name), 'utf-8');
      } catch {
        return '';
      }
    };

    if (has('package.json')) {
      signals.push('Runtime: Node.js project (package.json)');
      const raw = tryRead('package.json');
      if (raw) {
        try {
          const pkg = JSON.parse(raw) as {
            dependencies?: Record<string, string>;
            devDependencies?: Record<string, string>;
          };
          const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
          if (deps.next) signals.push('Framework: Next.js');
          else if (deps.react) signals.push('Framework: React');
          else if (deps.vue) signals.push('Framework: Vue');
          else if (deps.svelte) signals.push('Framework: Svelte');
          else if (deps['@angular/core']) signals.push('Framework: Angular');
          if (deps.typescript) signals.push('Language: TypeScript');
        } catch {}
      }
      if (has('pnpm-lock.yaml')) signals.push('Package manager: pnpm');
      else if (has('yarn.lock')) signals.push('Package manager: yarn');
      else if (has('package-lock.json')) signals.push('Package manager: npm');
    }

    if (has('pyproject.toml') || has('requirements.txt')) signals.push('Runtime: Python project');
    if (has('go.mod')) signals.push('Runtime: Go project');
    if (has('Cargo.toml')) signals.push('Runtime: Rust project');
    if (has('pom.xml') || has('build.gradle') || has('build.gradle.kts')) signals.push('Runtime: JVM project');
    if (has('composer.json')) signals.push('Runtime: PHP project');
    if (has('Gemfile')) signals.push('Runtime: Ruby project');

    if (signals.length === 0) return '';
    return `## Project Context (best effort)\n- ${signals.join('\n- ')}`;
  }

  private async summarizeConversationWithModel(messages: InferenceMessage[]): Promise<string> {
    if (messages.length === 0) return '';
    const summaryPrompt = `Summarise the conversation above concisely in 3-5 lines. Focus on:
- What the user requested
- What files were examined and what was found
- What changes were made and to which files
- What is still pending

Keep the summary under 400 tokens. Do not add commentary.`;

    const payload = [
      ...messages.slice(-8),
      { role: 'user', content: summaryPrompt }
    ];

    try {
      const response = await this.llm.chat(payload);
      return (response?.message?.content || '').trim();
    } catch {
      return '';
    }
  }

  private stripTemplateArtifacts(content: string): string {
    if (!content) return content;
    let cleaned = content.replace(/<tools>[\s\S]*?<\/tools>/gi, '');
    cleaned = cleaned.replace(/For each function call,\s*return a json object[^\n]*/gi, '');
    return cleaned.trim();
  }

  // BUG-21 fix: always return a string (normalized or original), never silent wrong tool.
  private normalizeToolName(toolName: string): string {
    return normalizeToolNameWithAliases(toolName, (name) => Boolean(this.toolSystem.getTool(name)));
  }

  // BUG-18 fix: no [TOOL] prefix — role:'tool' already contextualizes the message.
  // Truncation raised to 40 000 chars (~10 000 tokens) to allow reading large files.
  // The context compaction in buildInitialMessages handles overall window budgeting.
  private formatToolResultForModel(
    toolName: string,
    result: { success: boolean; output: string; error: string | null }
  ): string {
    return formatToolResultForModelPolicy(toolName, result);
  }

  private async executeToolWithEvents(
    toolName: string,
    args: Record<string, unknown>
  ): Promise<{ success: boolean; output: string; error: string | null }> {
    return executeToolWithEventsUseCase(
      {
        executeTool: (name, inputArgs) => this.toolSystem.execute(name, inputArgs),
        emit: (type, payload) => eventBus.emit(type, payload),
        addToolCall: (call) => this.state.addToolCall(call),
        sessionId: this.getSessionId(),
        brain: this.brain
      },
      toolName,
      args
    );
  }

  private streamFileContent(content: string, filePath?: string): void {
    const data = String(content);
    const lines = data.split('\n');
    const header = filePath
      ? `\n${chalk.cyan('📄')} ${filePath} (${lines.length} lines, ${Buffer.byteLength(data, 'utf-8')} B)\n`
      : '';
    if (header) eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: header });
    for (let i = 0; i < lines.length; i++) {
      const lineNum = String(i + 1).padStart(4, ' ');
      eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: `${lineNum} ${chalk.green('│')} ${lines[i]}\n` });
    }
  }

  private emitAssistantMessage(content: string): void {
    eventBus.emit(EventType.AGENT_MESSAGE, { content });
    this.state.addMessage({ role: 'assistant', content, timestamp: Date.now() });
  }

  private endThinking(): void {
    if (!this.thinkingActive) return;
    this.thinkingActive = false;
    eventBus.emit(EventType.THINK_END, {});
  }

  private formatInferenceError(error: unknown): string {
    if (error instanceof OllamaNotFoundError) return error.message;
    if (error instanceof OllamaResourceError) return error.message;
    if (error instanceof OfflineError) return error.message;
    if (error instanceof OllamaTimeoutError) return error.message;
    const message = error instanceof Error ? error.message : '';
    if (typeof message === 'string' && message.trim()) return message.trim();
    return 'Inferencia interrompida por erro';
  }

  // ── Public API ──────────────────────────────────────────────────────

  setMode(mode: AgentMode): void {
    this.state.setMode(mode);
    this.applyModelProfileForMode(mode);
  }

  setStreamEnabled(enabled: boolean): void {
    this.streamEnabled = enabled;
  }

  isStreamEnabled(): boolean {
    return this.streamEnabled;
  }

  reset(): void {
    this.state.reset();
    eventBus.emit(EventType.AGENT_MESSAGE, { content: 'Estado resetado' });
  }

  async indexRepository(path: string): Promise<void> {
    eventBus.emit(EventType.AGENT_MESSAGE, { content: `ℹ️ Busca semântica via rg não requer indexação: ${path}` });
  }

  async searchCode(query: string): Promise<void> {
    eventBus.emit(EventType.AGENT_MESSAGE, { content: `🔍 Buscando: ${query}` });
    try {
      eventBus.emit(EventType.SEARCH_START, { query });
      const results = await this.semanticSearch.search(query, '.');
      eventBus.emit(EventType.SEARCH_RESULTS, { query, resultsCount: results.length });
      const output = this.semanticSearch.formatResults(results);
      eventBus.emit(EventType.AGENT_MESSAGE, { content: output });
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error || 'erro desconhecido');
      eventBus.emit(EventType.SEARCH_ERROR, { query, error: message });
      eventBus.emit(EventType.AGENT_MESSAGE, { content: `Erro na busca: ${message}` });
    }
  }

  async listSessionTopics(): Promise<string> {
    const message = 'Topics de sessão foram removidos deste runtime simplificado.';
    eventBus.emit(EventType.AGENT_MESSAGE, { content: message });
    return message;
  }

  // BUG-04 fix: update modelCapabilities whenever active model changes.
  // BUG-16 fix: early return when model is already correct — avoids redundant work.
  private applyModelProfileForMode(mode: AgentMode): void {
    const targetModel = mode === 'code_assistant'
      ? String(config.ollama.coderModel || config.ollama.model || '').trim()
      : String(config.ollama.chatModel || config.ollama.model || '').trim();

    if (!targetModel) return;

    const currentModel = this.llm.getActiveModel();
    if (currentModel === targetModel) return;

    this.llm.setActiveModel(targetModel);
    // Sync capabilities to the new model so native-tools routing stays correct.
    this.modelCapabilities = detectModelCapabilities(targetModel);
  }
}
