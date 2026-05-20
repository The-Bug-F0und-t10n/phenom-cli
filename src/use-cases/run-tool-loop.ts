import { safeJsonParse } from '../json-utils.js';
import { eventBus, EventType } from '../tui/event-bus.js';
import { parseToolCallOrFinalDetailed } from '../tool-call-parser.js';
import type { ApiContentPart } from '../api-client.js';

export type InferenceMessage = {
  role: string;
  content: string | ApiContentPart[];
  tool_calls?: Array<{
    id?: string;
    type?: 'function';
    function: { name: string; arguments: string };
  }>;
  tool_call_id?: string;
};

interface ToolResultLike {
  success: boolean;
  output: string;
  error: string | null;
}

interface SessionStateLike {
  addMessage(message: {
    role: 'assistant' | 'tool';
    content: string;
    timestamp: number;
    tool_calls?: Array<{
      id?: string;
      type?: 'function';
      function: { name: string; arguments: string };
    }>;
    tool_call_id?: string;
  }): void;
}

interface SessionBrainLike {
  addNote(type: 'observation', content: string): string;
  getPlanSummary(): string;
  getPlanSteps(): Array<{ title: string; status: 'pending' | 'in_progress' | 'completed' | 'failed' }>;
}

interface RunToolLoopDeps {
  llm: {
    chatStream(
      messages: Array<{
        role: string;
        content: string | ApiContentPart[];
        tool_calls?: Array<{
          id?: string;
          type?: 'function';
          function: { name: string; arguments: string };
        }>;
        tool_call_id?: string;
      }>,
      onChunk: (chunk: string) => void,
      onToolCall?: (tool: string, args: Record<string, unknown> | string, id?: string) => void,
      tools?: Array<{
        type: 'function';
        function: {
          name: string;
          description: string;
          parameters?: Record<string, unknown>;
        };
      }>,
      onReasoning?: (chunk: string) => void
    ): Promise<string>;
    chat(messages: Array<{ role: string; content: string }>): Promise<{ message?: { content?: string } }>;
  };
  state: SessionStateLike;
  brain: SessionBrainLike | null;
  streamEnabled: boolean;
  supportsNativeTools: boolean;
  toolDefs: Array<{
    type: 'function';
    function: {
      name: string;
      description: string;
      parameters?: Record<string, unknown>;
    };
  }>;
  buildInitialMessages(userInput: string, inputParts?: ApiContentPart[]): Promise<InferenceMessage[]>;
  extractPlanFromText(text: string): boolean;
  extractPlanProgressFromText(text: string): void;
  stripTemplateArtifacts(content: string): string;
  emitAssistantMessage(content: string): void;
  normalizeToolName(toolName: string): string;
  executeToolWithEvents(toolName: string, args: Record<string, unknown>): Promise<ToolResultLike>;
  formatToolResultForModel(toolName: string, result: ToolResultLike): string;
  streamFileContent(content: string, filePath?: string): void;
  askModelForMoreIterations(userInput: string): Promise<boolean>;
  maxContextTokens: number;
}

export async function runToolLoopUseCase(
  deps: RunToolLoopDeps,
  userInput: string,
  inputParts?: ApiContentPart[]
): Promise<string> {
  let maxToolIterations = 20;
  const hardMaxIterations = 60;
  let limitExtended = false;
  const messages = await deps.buildInitialMessages(userInput, inputParts);
  let consecutiveAllFailures = 0;
  let stagnantIterations = 0;
  let repeatedToolPlanIterations = 0;
  let previousToolPlanSignature = '';
  let previousOutcomeSignature = '';
  const contextThresholdTokens = Math.max(1024, Math.floor(deps.maxContextTokens * 0.9));

  for (let iteration = 0; iteration < maxToolIterations; iteration++) {
    eventBus.emit(EventType.PROGRESS_UPDATE, {
      message: `Iteration ${iteration + 1}/${maxToolIterations}`,
      intentType: 'general'
    });

    let accumulatedContent = '';
    let hadNativeToolCalls = false;
    const toolCallsFromStream: Array<{
      id?: string;
      tool: string;
      arguments: Record<string, unknown> | string;
    }> = [];

    await deps.llm.chatStream(
      messages,
      (chunk) => {
        accumulatedContent += chunk;
        if (deps.streamEnabled) {
          eventBus.emit(EventType.MESSAGE_CHUNK, { chunk });
        }
      },
      (toolName, args, id) => {
        hadNativeToolCalls = true;
        toolCallsFromStream.push({ id, tool: toolName, arguments: args });
      },
      deps.supportsNativeTools ? deps.toolDefs : undefined,
      (reasoning) => {
        if (deps.streamEnabled) {
          eventBus.emit(EventType.REASONING_CHUNK, { chunk: reasoning });
        }
      }
    );

    if (accumulatedContent?.trim()) {
      deps.extractPlanFromText(accumulatedContent);
      deps.extractPlanProgressFromText(accumulatedContent);

      if (deps.brain) {
        const planSummary = deps.brain.getPlanSummary();
        if (planSummary) {
          const pendingSteps = deps.brain.getPlanSteps()
            .filter(s => s.status === 'pending' || s.status === 'in_progress');
          const currentStep = pendingSteps.find(s => s.status === 'in_progress') || pendingSteps[0];
          eventBus.emit(EventType.PROGRESS_UPDATE, {
            message: currentStep ? `Plan: ${currentStep.title}` : planSummary.split('\n')[0],
            intentType: 'plan'
          });
        }
      }
    }

    if (toolCallsFromStream.length === 0) {
      const parsed = parseToolCallOrFinalDetailed(accumulatedContent || '');
      if (parsed.response?.type === 'tool') {
        toolCallsFromStream.push({ tool: parsed.response.toolName, arguments: parsed.response.args || {} });
        if (deps.brain) {
          deps.brain.addNote('observation', `Fallback parser strategy: ${parsed.strategy}`);
        }
      } else {
        const finalContent = (parsed.response?.type === 'final'
          ? parsed.response.content
          : accumulatedContent)?.trim() || 'Concluded.';

        // No keyword-based "task requires disk I/O" heuristic. The model
        // decides whether to use tools. If it answered with text, accept it.
        if (finalContent && finalContent !== 'Concluded.') {
          deps.emitAssistantMessage(finalContent);
        }
        return finalContent;
      }
    }

    const toolCallEntries = toolCallsFromStream.map(tc => ({
      id: tc.id || `call_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
      type: 'function' as const,
      function: {
        name: tc.tool,
        arguments: typeof tc.arguments === 'string'
          ? tc.arguments
          : JSON.stringify(tc.arguments || {})
      }
    }));

    const thought = deps.stripTemplateArtifacts(accumulatedContent?.trim() || '');

    if (thought || toolCallsFromStream.length > 0) {
      eventBus.emit(EventType.AGENT_MESSAGE, {
        content: thought || `Using: ${toolCallsFromStream.map(t => t.tool).join(', ')}`
      });
      deps.state.addMessage({
        role: 'assistant',
        content: thought || '',
        timestamp: Date.now(),
        tool_calls: toolCallEntries
      });
    }

    if (hadNativeToolCalls) {
      messages.push({
        role: 'assistant',
        content: thought || '',
        tool_calls: toolCallEntries
      });
    } else {
      messages.push({
        role: 'assistant',
        content: accumulatedContent || ''
      });
    }
    compactLoopMessages(messages, contextThresholdTokens);

    eventBus.emit(EventType.CLEAR_STREAMING, {});

    let allFailed = toolCallsFromStream.length > 0;
    let hadSuccessfulTool = false;
    const normalizedToolCalls = toolCallsFromStream.map(tc => {
      const normalizedName = deps.normalizeToolName(tc.tool);
      const args = typeof tc.arguments === 'string'
        ? (safeJsonParse<Record<string, unknown>>(tc.arguments) || {})
        : tc.arguments;
      return { name: normalizedName, args };
    });
    const currentToolPlanSignature = normalizedToolCalls
      .map(tc => `${tc.name}:${stableStringify(tc.args)}`)
      .join('||');

    for (let i = 0; i < toolCallsFromStream.length; i++) {
      const tc = toolCallsFromStream[i];
      const toolCallId = toolCallEntries[i].id;
      const toolName = normalizedToolCalls[i].name;

      const rawArgs: Record<string, unknown> = normalizedToolCalls[i].args;

      const toolResult = await deps.executeToolWithEvents(toolName, rawArgs);
      if (toolResult.success) {
        allFailed = false;
        hadSuccessfulTool = true;
      }

      const toolResultContent = deps.formatToolResultForModel(toolName, toolResult);

      deps.state.addMessage({
        role: 'tool',
        content: toolResultContent,
        timestamp: Date.now(),
        tool_call_id: toolCallId
      });

      if (hadNativeToolCalls) {
        messages.push({
          role: 'tool',
          content: toolResultContent,
          tool_call_id: toolCallId
        });
      } else {
        const argsContext = stableStringify(rawArgs);
        messages.push({
          role: 'user',
          content: `[Tool result]\nname: ${toolName}\nargs: ${argsContext}\n${toolResultContent}`
        });
      }
      compactLoopMessages(messages, contextThresholdTokens);
    }

    if (currentToolPlanSignature && currentToolPlanSignature === previousToolPlanSignature) {
      repeatedToolPlanIterations++;
    } else {
      repeatedToolPlanIterations = 0;
    }
    previousToolPlanSignature = currentToolPlanSignature;

    const outcomeSignature = buildIterationOutcomeSignature(normalizedToolCalls, allFailed, hadSuccessfulTool);
    if (outcomeSignature === previousOutcomeSignature) {
      stagnantIterations++;
    } else {
      stagnantIterations = 0;
    }
    previousOutcomeSignature = outcomeSignature;

    if (repeatedToolPlanIterations >= 3 || stagnantIterations >= 4) {
      const msg = 'Tool loop stopped due to repeated non-progressing calls. Review tool-call strategy.';
      deps.emitAssistantMessage(msg);
      return msg;
    }

    if (allFailed) {
      consecutiveAllFailures++;
    } else {
      consecutiveAllFailures = 0;
    }

    if (consecutiveAllFailures >= 3) {
      const msg = 'All tools failed 3 consecutive iterations. Stopping.';
      deps.emitAssistantMessage(msg);
      return msg;
    }

    if (iteration + 1 >= maxToolIterations) {
      if (limitExtended || maxToolIterations >= hardMaxIterations) {
        const limitMessage = 'Tool iteration limit reached. Task concluded.';
        deps.emitAssistantMessage(limitMessage);
        return limitMessage;
      }

      const needsMore = await deps.askModelForMoreIterations(userInput);
      if (needsMore) {
        const nextLimit = Math.min(maxToolIterations * 2, hardMaxIterations);
        if (nextLimit === maxToolIterations) {
          const limitMessage = 'Tool iteration limit reached. Task concluded.';
          deps.emitAssistantMessage(limitMessage);
          return limitMessage;
        }
        maxToolIterations = nextLimit;
        limitExtended = true;
        eventBus.emit(EventType.PROGRESS_UPDATE, {
          message: `Limit extended to ${maxToolIterations}`,
          intentType: 'general'
        });
      } else {
        const limitMessage = 'Tool iteration limit reached. Task concluded.';
        deps.emitAssistantMessage(limitMessage);
        return limitMessage;
      }
    }
  }

  const limitMessage = 'Tool iteration limit reached.';
  deps.emitAssistantMessage(limitMessage);
  return limitMessage;
}

function compactLoopMessages(messages: InferenceMessage[], thresholdTokens: number): void {
  if (messages.length <= 3) return;
  if (estimateLoopTokens(messages) <= thresholdTokens) return;

  const system = messages[0];
  const tail = messages.slice(1);

  // Keep only the newest conversation turns until we fit.
  while (tail.length > 4 && estimateLoopTokens([system, ...tail]) > thresholdTokens) {
    tail.shift();
  }

  messages.splice(0, messages.length, system, ...tail);
}

function estimateLoopTokens(messages: InferenceMessage[]): number {
  let total = 0;
  for (const msg of messages) {
    if (typeof msg.content === 'string') {
      total += Math.ceil(msg.content.length / 4) + 12;
    } else if (Array.isArray(msg.content)) {
      let chars = 0;
      for (const part of msg.content) {
        chars += (part.text || '').length;
        chars += (part.image_url?.url || '').length;
      }
      total += Math.ceil(chars / 4) + 12;
    } else {
      total += 12;
    }
    if (msg.tool_calls?.length) {
      total += Math.ceil(JSON.stringify(msg.tool_calls).length / 4);
    }
  }
  return total;
}

function stableStringify(value: unknown): string {
  if (value === null || value === undefined) return String(value);
  if (typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(',')}]`;
  }
  const entries = Object.entries(value as Record<string, unknown>)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${JSON.stringify(k)}:${stableStringify(v)}`);
  return `{${entries.join(',')}}`;
}

function buildIterationOutcomeSignature(
  calls: Array<{ name: string; args: Record<string, unknown> }>,
  allFailed: boolean,
  hadSuccessfulTool: boolean
): string {
  const callSignature = calls.map(c => `${c.name}:${stableStringify(c.args)}`).join('|');
  return `${callSignature}::failed=${allFailed}::success=${hadSuccessfulTool}`;
}
