import { OllamaClient, OfflineError, OllamaNotFoundError, OllamaResourceError, OllamaTimeoutError } from './ollama-client.js';
import { SessionState } from './state.js';
import { ToolSystem } from './tools.js';
import { config } from './config.js';
import chalk from 'chalk';
import { eventBus, EventType } from './tui/event-bus.js';
import { SemanticSearch } from './semantic-search.js';
import { detectModelCapabilities, ModelCapabilities } from './model-capabilities.js';
import { SessionManager, SessionBrain } from './session-brain.js';
import { buildInferenceMessagesUseCase } from './use-cases/build-inference-messages.js';
import { executeToolWithEventsUseCase } from './use-cases/execute-tool-with-events.js';
import { runToolLoopUseCase, InferenceMessage } from './use-cases/run-tool-loop.js';
import { buildToolsSchemaBlock } from './use-cases/build-tools-schema-block.js';
import { existsSync, readFileSync } from 'fs';
import path from 'path';
import { formatToolResultForModelPolicy, normalizeToolNameWithAliases } from './use-cases/tool-execution-policy.js';
import { MemoryWriter } from './learning-loop/memory-writer.js';
import { SkillStore } from './learning-loop/skill-store.js';
import { LearningLoop } from './learning-loop/learning-loop.js';
import type { Message } from './types.js';
import type { ApiContentPart, ApiChatMessage } from './api-client.js';

// Protocol shape examples — placeholders only. Concrete values (e.g.
// `read_file` + `./src/index.ts`) acted as few-shot bias: the 9B model
// repeatedly proposed that exact tool + path even when the user's intent
// was unrelated. Angle-bracket placeholders convey the SHAPE without
// nudging the model toward a specific tool or location.
const TOOL_PROTOCOL_EXAMPLE = `{"type":"tool","toolName":"<tool_name>","args":{"<arg>":"<value>"}}`;
const FINAL_PROTOCOL_EXAMPLE = `{"type":"final","content":"<your markdown answer>"}`;

type Mode = 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis';

interface ToolResultLike {
  success: boolean;
  output: string;
  error: string | null;
}

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
  private memWriter: MemoryWriter = new MemoryWriter();
  // Fase 5 (7B engineering plan): post-turn skill auto-extraction.
  // Init runs lazily on first use inside onTaskCompleted; we keep a single
  // instance so the in-memory SkillStore is shared across turns.
  private learningLoop: LearningLoop = new LearningLoop();
  private projectDomainCache: string | null = null;
  private static readonly NEWS_TOOLS = new Set<string>([
    'get_civic_briefing',
    'get_news_preferences',
    'set_news_preferences'
  ]);
  // Reentrancy guard: while distillation is running, an inner llm.chat
  // call must NOT trigger another distillation (it would loop).
  private isDistilling: boolean = false;

  constructor() {
    this.llm = new OllamaClient();
    this.state = new SessionState();
    this.state.setMode(config.system.mode);
    this.toolSystem = new ToolSystem();
    this.semanticSearch = new SemanticSearch();
    const initialModel = String(config.ollama.coderModel || config.ollama.model || 'qwen2.5-coder:latest');
    this.modelCapabilities = detectModelCapabilities(initialModel);
    // BUG-16 fix: applyModelProfileForMode called once in constructor only.
    this.applyModelProfileForMode(config.system.mode);
    this.sessionManager = new SessionManager();
  }

  async initialize(existingSessionId?: string): Promise<string | null> {
    await this.ensurePersistentKnowledgeFiles();
    await this.sessionManager.init();
    // Wire the brain getter so session-scoped tools (list_session_files,
    // list_pending_tasks, etc.) observe the current brain through this
    // provider, surviving session restores without needing tool re-registration.
    this.toolSystem.setBrainProvider(() => this.brain);
    if (existingSessionId && existingSessionId.length === 16) {
      this.brain = await this.sessionManager.loadSession(existingSessionId);
      if (this.brain) {
        // Restore chat memory so `phenom chat --session <hash>` can resume
        // the exact conversation context.
        this.state.setMemory(this.brain.loadMessages());
        return existingSessionId;
      }
    }
    this.brain = await this.sessionManager.createSession();
    return this.brain.getData().sessionId;
  }

  private async ensurePersistentKnowledgeFiles(): Promise<void> {
    try {
      const store = new SkillStore();
      await store.init();
      await store.save();
    } catch { /* best-effort seed */ }
    try {
      await this.memWriter.ensureExists();
    } catch { /* best-effort seed */ }
  }

  getSessionId(): string | null {
    return this.brain?.getData().sessionId || null;
  }

  getBrain(): SessionBrain | null {
    return this.brain;
  }

  getConversationMessages(): Message[] {
    return this.state.getRecentMessages(config.system.maxHistory);
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

  private async processInputInternal(userInput: string, inputParts?: ApiContentPart[]): Promise<void> {
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
      let userFacingFinal = finalText;
      if (!finalText) {
        const fallback = 'Não recebi saída do modelo. Reformule o pedido ou tente novamente.';
        this.emitAssistantMessage(fallback);
        userFacingFinal = fallback;
      }
      // Distinct from AGENT_MESSAGE (which also fires mid-loop for tool
      // announcements). This event guarantees "the user's turn produced a
      // complete answer" — TTS, notifications, telemetry hook here.
      eventBus.emit(EventType.AGENT_FINAL_RESPONSE, { content: userFacingFinal });

      if (this.brain) {
        this.brain.saveMessages(this.state.getState().memory);
        await this.brain.save();
      }

      eventBus.emit(EventType.SESSION_UPDATE, { sessionId: this.getSessionId(), complete: true });
      this.endThinking();
    } catch (error: any) {
      if (this.brain) {
        this.brain.addNote('error', `Error: ${error.message}`);
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
  extractPlanFromText(text: string): boolean {
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
      let match;
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

  extractPlanProgressFromText(_text: string): void {
    // Intentional no-op. Prior implementation matched loose regex
    // ("step N done", "working on step N", etc.) against the entire model
    // output, which false-positives on prose discussing future steps
    // ("I will only work on step 2 once step 1 is done"). That regex
    // auto-completed step 1 the moment the model mentioned it, even
    // when no real work had happened. Combined with the plan-continuation
    // logic in run-tool-loop.ts:244-267, this drove the brain into
    // inconsistent states (steps marked done that weren't).
    //
    // Plan progress is now updated EXCLUSIVELY via the `complete_step`
    // tool — explicit, intent-driven, audit-able. The Modelfile rule 3f
    // ("Call complete_step after each plan step finishes") aligns with
    // this. If a model never calls complete_step despite finishing work,
    // the plan continuation loop will push it to call set_plan again or
    // explicitly mark steps — which is the correct intervention point.
    //
    // The method is retained (as no-op) because run-tool-loop.ts depends
    // on it via the deps interface. Deleting it would break that contract
    // unnecessarily; making it a no-op preserves the interface and zero
    // behavior contribution.
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
    const toolDefs = this.getExposedToolDefinitions();
    // Use the server's authoritative n_ctx when available (llama-server
    // /props), clamped against the local OLLAMA_NUM_CTX. Avoids the
    // "compaction never triggers because local threshold says we're fine,
    // server rejects with exceed_context_size_error" failure mode.
    //
    // BUG-A6: cache the value for this turn so buildInitialMessages reuses
    // it instead of awaiting a second /props probe — previously the build
    // and loop paths could race and end up with divergent thresholds.
    const maxContextTokens = await this.llm.getEffectiveContextLimit();
    this._turnMaxContextTokens = maxContextTokens;
    return runToolLoopUseCase({
      llm: this.llm,
      state: this.state,
      brain: this.brain,
      streamEnabled: this.streamEnabled,
      // Native-tools is gated by the EFFECTIVE protocol — env var
      // PHENOM_TOOLS_PROTOCOL=text wins over model capability detection.
      // In text mode we don't pass the tools schema as an API parameter
      // (buildSystemPrompt injects it into the system message instead).
      supportsNativeTools: this.effectiveSupportsNativeTools(),
      toolDefs,
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
      maxContextTokens,
      distillDroppedMessages: this.distillDroppedMessages.bind(this),
      tokenCount: this.tokenCountForLoop.bind(this)
    }, userInput, inputParts);
  }

  /**
   * Produce a SHORT conversational narration of what was just done — to be
   * spoken aloud by TTS. NOT a re-render of the full reply; just a "como
   * uma conversa entre duas pessoas" sentence acknowledging completion or
   * naming the mindset of the problem, without reading code or markdown.
   *
   * Trade-offs considered:
   *   - Extra LLM call per turn (~0.5-1.5s). Async, doesn't block display.
   *   - Cheaper alternatives (model-emitted `<voice>` tag, first-sentence
   *     heuristic) were rejected: tag-emission depends on 9B following
   *     instructions perfectly; first-sentence fails for replies that
   *     open with code blocks or lists.
   *
   * Failure is silent: empty string returned. Caller skips TTS for that turn.
   */
  async narrateForVoice(fullResponse: string, userQuery: string): Promise<string> {
    if (!fullResponse || !fullResponse.trim()) return '';
    // Cap input so the narration call stays fast. The model only needs the
    // gist, not the full code dump that a long reply might contain.
    const trimmedResponse = fullResponse.length > 2000
      ? fullResponse.slice(0, 2000) + '\n[...truncado para narração...]'
      : fullResponse;
    const trimmedQuery = userQuery.length > 400
      ? userQuery.slice(0, 400) + '...'
      : userQuery;

    const prompt = [
      'Você é o narrador de voz do assistente Phenom.',
      'O assistente acabou de responder ao usuário (texto abaixo).',
      'Sua tarefa: gerar UMA frase curta em português brasileiro,',
      'como se fosse uma conversa entre dois colegas, comunicando o que',
      'foi feito ou o mindset/conclusão sobre o problema.',
      '',
      'REGRAS RÍGIDAS:',
      '- Máximo 20 palavras.',
      '- Sem ler código, sem citar arquivos/linhas/comandos.',
      '- Sem markdown, sem listas, sem aspas.',
      '- Tom natural, falado. Pode começar com "terminei", "encontrei",',
      '  "achei que", "ajustei", "o problema era", etc.',
      '- Se a resposta foi puramente código sem explicação, narre só a',
      '  intenção alto-nível (ex: "implementei a função que você pediu").',
      '- Não invente detalhes que não estão na resposta.',
      '',
      `Pergunta do usuário:\n${trimmedQuery}`,
      '',
      `Resposta do assistente:\n${trimmedResponse}`,
      '',
      'Frase de narração (apenas a frase, sem aspas):'
    ].join('\n');

    // IMPORTANT: bypass agent.llm.chat(). Going through OllamaClient drags
    // the full agent pipeline (system prompt with .MEMORY.md/.SKILL.md,
    // adaptive context, message history) — which we measured at ~118s for
    // a narration that takes 4s via raw POST. The narration call needs
    // ZERO of that scaffolding; it's a one-shot stateless ask. Direct
    // POST keeps it under ~5s.
    try {
      // OLLAMA_HOST is the single source of truth for the inference
      // endpoint. NO localhost fallback — guessing 127.0.0.1 burns the
      // 15s timeout when the real LLM lives on a remote host (the
      // common case here), and adds an unwanted "default" that hides
      // misconfiguration.
      const host = config.ollama.host;
      if (!host) return '';
      const model = config.ollama.coderModel || config.ollama.chatModel || config.ollama.model;
      if (!model) return '';

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 15_000);
      try {
        const res = await fetch(`${host.replace(/\/+$/, '')}/v1/chat/completions`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model,
            messages: [{ role: 'user', content: prompt }],
            max_tokens: 60,
            temperature: 0.5,
            stream: false
          }),
          signal: controller.signal
        });
        if (!res.ok) return '';
        const data: any = await res.json();
        const raw = String(data?.choices?.[0]?.message?.content || '').trim();
        // Defensive cleanup: model sometimes wraps in quotes or adds a
        // label despite instructions. Strip both. Single line only.
        let narration = raw.split('\n').find((l: string) => l.trim().length > 0) || '';
        narration = narration.trim().replace(/^["'`]+|["'`]+$/g, '').trim();
        if (narration.length > 240) narration = narration.slice(0, 240);
        return narration;
      } finally {
        clearTimeout(timer);
      }
    } catch {
      return '';
    }
  }

  async askModelForMoreIterations(userInput: string): Promise<boolean> {
    const state = this.state.getState();
    const askMessages: ApiChatMessage[] = [
      ...((state.memory || []).slice(-6) as ApiChatMessage[]),
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
  async buildMessages(currentQuery: string): Promise<InferenceMessage[]> {
    return this.buildInitialMessages(currentQuery);
  }

  /** BUG-A6: populated once per turn in runToolLoop(); reused by
   *  buildInitialMessages instead of a second /props probe. */
  private _turnMaxContextTokens: number | null = null;

  private async buildInitialMessages(
    currentQuery: string,
    currentUserContent?: ApiContentPart[]
  ): Promise<InferenceMessage[]> {
    // BUG-A6: prefer the per-turn cached value; only fall back to a fresh
    // probe when called outside a runToolLoop turn (e.g. via the buildMessages
    // legacy shim).
    const maxContextTokens =
      this._turnMaxContextTokens ?? (await this.llm.getEffectiveContextLimit());
    return buildInferenceMessagesUseCase({
      systemPrompt: this.buildSystemPrompt(currentQuery),
      recentMessages: this.state.getRecentMessages(config.system.maxHistory),
      currentQuery,
      currentUserContent,
      // Session context (active plan / focused step) is NOT injected here.
      // Injection mutated the cached prefix between turns and triggered
      // llama.cpp "erased invalidated context checkpoint" + full reprefill
      // on SWA/hybrid models. The model pulls it on demand via the
      // `get_session_context` tool — keeps the prompt prefix append-only.
      maxContextTokens,
      summarizeConversation: this.summarizeConversationWithModel.bind(this),
      tokenCount: (text: string) => this.llm.tokenizeCount(text)
    });
  }

  /**
   * Resolve the effective tools protocol. PHENOM_TOOLS_PROTOCOL env var
   * overrides model capability detection so a user with a buggy server
   * (e.g. llama.cpp --jinja parse errors on long content) can force the
   * text-protocol path without changing model code.
   */
  private effectiveSupportsNativeTools(): boolean {
    const setting = config.ollama.toolsProtocol;
    if (setting === 'text') return false;
    if (setting === 'native') return true;
    return this.modelCapabilities.supportsNativeTools;
  }

  private buildSystemPrompt(_currentQuery: string = ''): string {
    const cwd = process.cwd();
    const projectContext = this.buildProjectContext(cwd);
    const nativeTools = this.effectiveSupportsNativeTools();
    const exposedToolDefs = this.getExposedToolDefinitions();

    // Persistent project knowledge (.MEMORY.md / .SKILL.md) is NOT injected
    // here. Injection mutated the system prompt every turn (learning-loop
    // writes between turns), forcing a full prompt re-prefill on the server
    // slot — token-0 cache divergence. The model now reads them on-demand
    // through `read_memory` / `read_skills` tools and writes through
    // `update_memory` / `record_skill`. System prompt stays byte-stable
    // across a session → slot KV is reused → first token is fast.
    const exposedToolNames = exposedToolDefs.map(t => t.function.name);
    const toolSection = `Available tools for this mode: ${exposedToolNames.join(', ')}`;

    const callProtocol = nativeTools
      ? `Use tools via native tool calls whenever an operation is needed.
If native tool call is not emitted, output exactly one JSON tool object:
- Tool call: ${TOOL_PROTOCOL_EXAMPLE}
After all operations are complete, reply with a concise plain-text summary.`
      : `Reply with exactly one JSON object per message:\n- Tool call: ${TOOL_PROTOCOL_EXAMPLE}\n- Final answer: ${FINAL_PROTOCOL_EXAMPLE}`;

    // When in text-protocol mode, we inject the actual tools schema into
    // the system prompt because the server is no longer doing it via
    // --jinja. The block is structured exactly like the Modelfile TEMPLATE
    // would emit, so the model's tool-call output looks identical
    // regardless of which transport handles delivery.
    const toolsSchemaBlock = nativeTools
      ? ''
      : buildToolsSchemaBlock(exposedToolDefs);

    // Identity + behavior rules are NOT sent by the client — they are applied
    // server-side (via the model's chat template) to avoid a duplicate/colliding
    // system framing. The client's system message carries only the dynamic,
    // request-specific context the server can't know.
    //
    // This system message must be BYTE-IDENTICAL across turns within a session
    // so the server's prompt cache can reuse it as a stable prefix. That is
    // mandatory for hybrid/recurrent-attention models (e.g. Qwen3.5 family),
    // where the KV/recurrent state cannot rewind to a mid-sequence divergence:
    // ANY change in the system block forces a full prompt re-process. The only
    // per-turn VOLATILE piece — the active-plan/session context — is therefore
    // NOT placed here; it is appended to the CURRENT user message instead (see
    // buildInitialMessages → currentTurnContext), keeping system + history
    // append-only. Everything below is stable within a session (cwd, project
    // signals, persistent knowledge, call protocol, tool list + schema).
    return `Working directory: ${cwd}
${projectContext}
${callProtocol}

${toolSection}
${toolsSchemaBlock}`;
  }

  private getExposedToolDefinitions(): Array<{
    type: 'function';
    function: {
      name: string;
      description: string;
      parameters?: Record<string, unknown>;
    };
  }> {
    const defs = this.toolSystem.getToolDefinitions();
    return defs.filter(def => this.shouldExposeTool(def.function?.name || ''));
  }

  private shouldExposeTool(toolName: string): boolean {
    const name = String(toolName || '').trim();
    if (!name) return false;
    const mode = this.state.getMode();
    if (mode !== 'assistant' && Agent.NEWS_TOOLS.has(name)) {
      return false;
    }
    return true;
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
        } catch { /* ignore malformed package.json */ }
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

  /**
   * Best-effort project domain string for the learning loop's pattern
   * extractor. Cached on first call — the cwd doesn't change mid-session.
   * Falls through to 'general' so `detectDomain(request, projectDomain)`
   * still works (it overrides with file-extension hints from the request
   * itself when present).
   */
  private getProjectDomain(): string {
    if (this.projectDomainCache !== null) return this.projectDomainCache;
    const cwd = process.cwd();
    const has = (name: string): boolean => existsSync(path.join(cwd, name));
    let domain = 'general';
    if (has('tsconfig.json')) domain = 'typescript';
    else if (has('package.json')) domain = 'javascript';
    else if (has('pyproject.toml') || has('requirements.txt')) domain = 'python';
    else if (has('Cargo.toml')) domain = 'rust';
    else if (has('go.mod')) domain = 'go';
    this.projectDomainCache = domain;
    return domain;
  }

  /**
   * Exact token count for the loop's compaction step. Delegates to
   * OllamaClient which probes the backend and uses /tokenize on
   * llama-server, returning null on Ollama (caller falls back to
   * character-based estimate).
   */
  async tokenCountForLoop(text: string): Promise<number | null> {
    return this.llm.tokenizeCount(text);
  }

  /**
   * Memory-as-compaction-point. Called by the tool loop right before
   * messages get dropped to fit the context window. Runs N small per-topic
   * passes (decisions / constraints / failed paths / deferred) against
   * .MEMORY.md so the dropped context is captured as durable knowledge
   * instead of vanishing silently.
   *
   * Each pass is independent and short — the LLM never sees the full
   * degraded history; only the chunk being dropped + the target section.
   *
   * Guarded by `isDistilling` to prevent recursion (the inner llm.chat
   * call must not trigger another compaction).
   */
  async distillDroppedMessages(dropped: InferenceMessage[]): Promise<void> {
    if (this.isDistilling) return;
    if (!dropped || dropped.length === 0) return;
    this.isDistilling = true;
    try {
      eventBus.emit(EventType.PROGRESS_UPDATE, {
        message: `Resuming ... compacting context into memory (${dropped.length} msgs)…`,
        intentType: 'general'
      });
      const llmFn = async (prompt: string): Promise<string> => {
        const response = await this.llm.chat([{ role: 'user', content: prompt }]);
        return String(response?.message?.content || '');
      };
      const results = await this.memWriter.distillBySection(dropped as any, llmFn);
      const persisted = results.filter(r => r.items.length > 0);
      if (persisted.length > 0) {
        const summary = persisted
          .map(r => `${r.pass}=${r.items.length}`)
          .join(' ');
        eventBus.emit(EventType.PROGRESS_UPDATE, {
          message: `Memory updated: ${summary}`,
          intentType: 'general'
        });
      }
    } catch {
      // Best-effort: never block the loop on a distillation failure.
    } finally {
      this.isDistilling = false;
    }
  }

  private async summarizeConversationWithModel(messages: InferenceMessage[]): Promise<string> {
    if (messages.length === 0) return '';
    const summaryPrompt = `Summarise the conversation above concisely in 3-5 lines. Focus on:
- What the user requested
- What files were examined and what was found
- What changes were made and to which files
- What is still pending

Keep the summary under 400 tokens. Do not add commentary.`;

    const payload: ApiChatMessage[] = [
      ...(messages.slice(-8) as ApiChatMessage[]),
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
    // Strip protocol wrappers that the model sometimes echoes back into
    // its prose. Leaving them in state.memory means the next inference
    // sees its own raw protocol output as "context" and starts mimicking
    // the envelope shape in places where it shouldn't (compounds noise
    // over a long session). Shapes covered:
    //   - <tool_call>...</tool_call>            (native-tools-as-text format)
    //   - {"type":"final","content":"..."}      (text-protocol final → unwrap content)
    //   - {"type":"tool",...}                   (text-protocol tool call envelope)
    //   - ```json …``` fences with tool-call    (qwen3.5 leaks tool calls as fenced JSON
    //     shapes (any keys)                      with arbitrary key names — toolName,
    //                                            tool, name; args, arguments; etc.)
    //   - Stray `}` lines left after the above  (orphan close-brace from a partially
    //                                            stripped envelope)
    cleaned = cleaned.replace(/<tool_call>[\s\S]*?<\/tool_call>\s*/gi, '');
    cleaned = cleaned.replace(/\{"type"\s*:\s*"final"\s*,\s*"content"\s*:\s*"((?:[^"\\]|\\.)*)"\s*\}/g, (_m, captured) => {
      try { return JSON.parse('"' + captured + '"'); }
      catch { return captured; }
    });
    cleaned = cleaned.replace(/\{"type"\s*:\s*"tool"[\s\S]*?\}\s*/g, '');
    // Drop ALL fenced JSON blocks — the model only emits these as protocol
    // leakage. A user who legitimately wants to share JSON would be writing
    // an answer, not a tool call. If false positives appear, narrow back to
    // patterns that mention tool/toolName/name keys.
    cleaned = cleaned.replace(/```json\s*[\s\S]*?```\s*/gi, '');
    // Sweep up stray close-braces or open-braces on their own lines left by
    // the above strips (when the model emitted partial envelopes that we
    // half-matched).
    cleaned = cleaned.replace(/^\s*[}{]\s*$/gm, '');
    // Collapse runs of blank lines created by the strips.
    cleaned = cleaned.replace(/\n{3,}/g, '\n\n');
    return cleaned.trim();
  }

  // BUG-21 fix: always return a string (normalized or original), never silent wrong tool.
  private normalizeToolName(toolName: string): string {
    return normalizeToolNameWithAliases(toolName, (name: string) => Boolean(this.toolSystem.getTool(name)));
  }

  // BUG-18 fix: no [TOOL] prefix — role:'tool' already contextualizes the message.
  // Truncation raised to 40 000 chars (~10 000 tokens) to allow reading large files.
  // The context compaction in buildInitialMessages handles overall window budgeting.
  private formatToolResultForModel(toolName: string, result: ToolResultLike): string {
    return formatToolResultForModelPolicy(toolName, result);
  }

  private async executeToolWithEvents(toolName: string, args: Record<string, unknown>): Promise<ToolResultLike> {
    return executeToolWithEventsUseCase({
      executeTool: (name: string, inputArgs: Record<string, unknown>) => this.toolSystem.execute(name, inputArgs),
      emit: (type, payload) => eventBus.emit(type, payload),
      addToolCall: (call) => this.state.addToolCall(call),
      sessionId: this.getSessionId(),
      brain: this.brain
    }, toolName, args);
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

  private emitAssistantMessage(content: string, storageContent?: string): void {
    eventBus.emit(EventType.AGENT_MESSAGE, { content });
    // When the storage form differs from the visible form (storageContent
    // exists and is not byte-equal to content), persist BOTH: `content`
    // keeps the KV-cache byte form, `displayContent` lets session restore
    // show the user the exact text they saw live. The empty-content turn
    // (storageContent=`<think>…</think>\n`, content=reasoning-fallback) is
    // the canonical case this fixes — restoration previously emitted no
    // AGENT_MESSAGE for it.
    const stored = storageContent ?? content;
    const msg: Message = { role: 'assistant', content: stored, timestamp: Date.now() };
    if (storageContent !== undefined && storageContent !== content) {
      msg.displayContent = content;
    }
    this.state.addMessage(msg);
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
  setMode(mode: Mode): void {
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
  private applyModelProfileForMode(mode: Mode): void {
    const targetModel = mode === 'code_assistant'
      ? String(config.ollama.coderModel || config.ollama.chatModel || config.ollama.model || '').trim()
      : String(config.ollama.chatModel || config.ollama.coderModel || config.ollama.model || '').trim();
    if (!targetModel) return;
    const currentModel = this.llm.getActiveModel();
    if (currentModel === targetModel) {
      // Even on no-op model swap, re-apply think setting (covers first-time setup).
      this.applyThinkSetting();
      return;
    }
    this.llm.setActiveModel(targetModel);
    // Sync capabilities to the new model so native-tools routing stays correct.
    this.modelCapabilities = detectModelCapabilities(targetModel);
    this.applyThinkSetting();
  }

  /**
   * Resolve OLLAMA_THINK env override + supportsReasoning into a concrete
   * `think` value and push it to the LLM client.
   *
   * Resolution rules:
   *   - env "auto" or unset → think=true when supportsReasoning, else null
   *   - env "true"/"1"/"yes" → think=true
   *   - env "false"/"0"/"no" → think=false (sent explicitly)
   *   - env "low"/"medium"/"high" → forward the level string
   */
  private applyThinkSetting(): void {
    const mode = config.ollama.thinkMode;
    let resolved: boolean | string | null;
    if (!mode || mode === 'auto') {
      resolved = this.modelCapabilities.supportsReasoning ? true : null;
    } else if (mode === 'true' || mode === '1' || mode === 'yes') {
      resolved = true;
    } else if (mode === 'false' || mode === '0' || mode === 'no') {
      resolved = false;
    } else if (mode === 'low' || mode === 'medium' || mode === 'high') {
      resolved = mode;
    } else {
      resolved = this.modelCapabilities.supportsReasoning ? true : null;
    }
    this.llm.setThink(resolved);
  }
}
