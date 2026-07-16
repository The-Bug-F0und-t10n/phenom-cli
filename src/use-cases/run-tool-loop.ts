import { safeJsonParse } from '../json-utils.js';
import { eventBus, EventType } from '../tui/event-bus.js';
import { parseToolCallOrFinalDetailed } from '../tool-call-parser.js';
import type { ApiContentPart } from '../api-client.js';
import { config } from '../config.js';

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
    /** User-visible form for session restore. See Message.displayContent. */
    displayContent?: string;
  }): void;
}

interface SessionBrainLike {
  addNote(type: 'observation', content: string): string;
  getPlanSummary(): string;
  getPlanSteps(): Array<{ title: string; status: 'pending' | 'in_progress' | 'completed' | 'failed' }>;
  getRequestMetrics?: () => {
    mutationCount: number;
    testsRun: number;
    buildRun: number;
    validationCount: number;
  };
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
  emitAssistantMessage(content: string, storageContent?: string): void;
  normalizeToolName(toolName: string): string;
  executeToolWithEvents(toolName: string, args: Record<string, unknown>): Promise<ToolResultLike>;
  formatToolResultForModel(toolName: string, result: ToolResultLike): string;
  streamFileContent(content: string, filePath?: string): void;
  /** @deprecated Iteration cap removed — kept as optional for binary back-compat. Unused. */
  askModelForMoreIterations?: (userInput: string) => Promise<boolean>;
  maxContextTokens: number;
  /**
   * Optional: called RIGHT BEFORE messages are dropped to fit the context
   * window. Receives the messages that are about to be removed. The
   * implementation typically runs N small per-topic distillation passes
   * and persists the result to .MEMORY.md so the loss is captured as
   * durable knowledge instead of silent truncation. If omitted, the loop
   * falls back to the pure sliding-window behavior.
   */
  distillDroppedMessages?: (dropped: InferenceMessage[]) => Promise<void>;
  /**
   * Optional: exact token count for `text` from the backend's tokenizer.
   * Returns null when the backend can't tokenize. When provided AND
   * non-null, the compaction step uses real token counts instead of the
   * character/4 estimate — eliminates false-positive triggers from
   * unicode-heavy content (CJK, emojis) and false-negatives from
   * JSON-heavy tool output.
   */
  tokenCount?: (text: string) => Promise<number | null>;
}

export async function runToolLoopUseCase(
  deps: RunToolLoopDeps,
  userInput: string,
  inputParts?: ApiContentPart[]
): Promise<string> {
  // No iteration ceiling. We rely on progress-based guards (per-call dedup,
  // repeated plan, stagnant outcome, all-failed run) to stop the loop when
  // the model is genuinely spinning. Ctrl-C/Esc still aborts via the
  // ApiClient inflight controllers. The previous 20/60 caps interrupted
  // healthy long tasks (refactor + validate + build) before they could
  // finish, and the askModelForMoreIterations bounce always answered yes.
  const MAX_ITERATIONS_SOFT_CAP = 10_000;
  const messages = await deps.buildInitialMessages(userInput, inputParts);
  const availableTools = new Set(deps.toolDefs.map(d => String(d.function?.name || '').trim()).filter(Boolean));
  const lexicalFallbackEnabled = config.rag.autoLexicalFallback;
  let consecutiveAllFailures = 0;
  // BUG-A12: dedicated counter for "model keeps emitting unparseable tool
  // arguments JSON". Without it the loop could spin ~5 iterations alternating
  // between two malformed shapes before consecutiveAllFailures (which
  // counted only full-iteration failures) tripped.
  let consecutiveArgsParseErrors = 0;
  const MAX_CONSECUTIVE_ARGS_PARSE_ERRORS = 2;
  let stagnantIterations = 0;
  let repeatedToolPlanIterations = 0;
  let previousToolPlanSignature = '';
  let previousOutcomeSignature = '';
  // Sliding window of the last N individual tool calls (across iterations).
  // Catches the calculadora-style pattern: same bad call interleaved with
  // other tools so the per-iteration plan signature differs but the wrong
  // call repeats. Detector trips when any (tool, args-hash) shows up >=3
  // times in the last 8 calls.
  const RECENT_CALLS_WINDOW = 8;
  const RECENT_CALLS_THRESHOLD = 3;
  const recentCallHashes: string[] = [];
  // Exploration tools are often called repeatedly with nearby patterns while
  // the model builds micro-context. Treating those repeats as a hard loop
  // causes premature aborts on healthy diagnose flows.
  const LOOP_GUARD_EXEMPT_TOOLS = new Set([
    'grep_file',
    'search_code',
    'find_function',
    'who_calls',
    'list_dir',
    'path_exists',
    'project_map'
  ]);
  // Consecutive iterations that produced ZERO tool calls AND no progress
  // signal from the brain (plan unchanged, metrics unchanged). Trips at 2
  // BEFORE plan/verification continuation budgets so a model that just
  // emits <think> blocks without acting can't stall for 7 iterations.
  let noProgressIterations = 0;
  const MAX_NO_PROGRESS_ITERATIONS = 2;
  let lastBrainProgressSnapshot = '';
  let planContinuationAttempts = 0;
  const MAX_PLAN_CONTINUATIONS = 5;
  let verificationContinuationAttempts = 0;
  const MAX_VERIFICATION_CONTINUATIONS = 2;
  let serverParseErrorRecoveryAttempts = 0;
  const MAX_SERVER_PARSE_RECOVERIES = 2;
  const autoMicroContext = process.env.PHENOM_AUTO_MICRO_CONTEXT !== '0';
  const ioIntent = autoMicroContext && looksLikeIoTask(userInput);
  const autoRagOrchestration = process.env.PHENOM_AUTO_RAG_ORCHESTRATION === '1';
  const autoRagIndex = process.env.PHENOM_AUTO_RAG_INDEX !== '0';
  const ragIntent = autoRagOrchestration && looksLikeConceptTask(userInput);
  let ragPreludeAttempted = false;
  let ioContinuationAttempts = 0;
  const MAX_IO_CONTINUATIONS = 3;
  let sawAnyToolCall = false;
  let contextThresholdTokens = Math.max(1024, Math.floor(deps.maxContextTokens * 0.9));
  let contextRecoveryAttempts = 0;
  // 2 was too low: a single oversized turn often needs more shrink passes to
  // fit, especially after large tool results land mid-loop. 5 gives the
  // compaction path room to shrink-and-retry without surrendering to a hard
  // error (which used to crash to the index.ts catch — and on some paths
  // bypass the brain.save entirely, leaving the user with a wiped context).
  const MAX_CONTEXT_RECOVERIES = 5;

  // Post-mutation validation discipline. The 7B failure mode is "edit a file,
  // forget to check that the edit compiled". We track mutated paths per
  // iteration and, when an iteration ends with unvalidated mutations, push
  // a focused reminder that the NEXT iteration must validate. Bounded to
  // MAX_VALIDATION_NUDGES so a model that genuinely doesn't need to call
  // validate_syntax (e.g. edited a markdown file) can finish anyway.
  const MUTATION_TOOL_NAMES = new Set(['write_file', 'create_file', 'apply_patch']);
  const VALIDATION_TOOL_NAMES = new Set(['validate_syntax']);
  // Skip files that don't make sense to lint/parse — markdown, JSON config,
  // plain text, etc. The check is best-effort; the user's syntax_validator
  // would just no-op on these anyway, so the nudge would be wasted.
  const SKIP_VALIDATION_EXTENSIONS = new Set(['.md', '.txt', '.json', '.yml', '.yaml', '.toml', '.ini', '.lock', '.env']);
  let validationNudges = 0;
  const MAX_VALIDATION_NUDGES = 3;

  const appendAutoToolResult = async (
    toolName: string,
    args: Record<string, unknown>,
    toolResult: ToolResultLike
  ): Promise<void> => {
    const toolResultContent = deps.formatToolResultForModel(toolName, toolResult);
    const packedToolResult = packToolResultForContext(toolName, toolResultContent, deps.maxContextTokens);
    // Header + payload. The header binds this <tool_response> back to the
    // specific (name, args) the model just emitted, which is the only signal
    // a 9B has for "is this the result of the call I just made or a stale
    // older one?". stableStringify keeps the bytes identical across rebuilds
    // so the server's KV cache still hits on the next user turn.
    const decoratedContent = renderToolResultBody(toolName, args, packedToolResult);
    deps.state.addMessage({
      role: 'tool',
      content: decoratedContent,
      timestamp: Date.now()
    });
    pushToolResultDeduped(messages, {
      role: 'tool',
      content: decoratedContent
    });
    await compactLoopMessages(messages, contextThresholdTokens, deps.distillDroppedMessages, deps.tokenCount, userInput);
  };

  for (let iteration = 0; iteration < MAX_ITERATIONS_SOFT_CAP; iteration++) {
    eventBus.emit(EventType.PROGRESS_UPDATE, {
      message: `Iteration ${iteration + 1}`,
      intentType: 'general'
    });

    if (ragIntent && !ragPreludeAttempted) {
      ragPreludeAttempted = true;
      eventBus.emit(EventType.PROGRESS_UPDATE, {
        message: 'Auto-RAG preflight (status -> index? -> search)',
        intentType: 'general'
      });

      const ragStatusArgs: Record<string, unknown> = {};
      const ragStatus = await deps.executeToolWithEvents('rag_status', ragStatusArgs);
      await appendAutoToolResult('rag_status', ragStatusArgs, ragStatus);

      const statusBlob = `${ragStatus.output || ''}\n${ragStatus.error || ''}`.toLowerCase();
      const needsIndex =
        !ragStatus.success ||
        statusBlob.includes('index ausente') ||
        statusBlob.includes('índice rag ausente') ||
        statusBlob.includes('incompatível') ||
        statusBlob.includes('incompatible');

      if (needsIndex && autoRagIndex) {
        const ragIndexArgs: Record<string, unknown> = { force: false };
        const ragIndex = await deps.executeToolWithEvents('rag_index', ragIndexArgs);
        await appendAutoToolResult('rag_index', ragIndexArgs, ragIndex);
      }

      const ragSearchArgs: Record<string, unknown> = { query: userInput, k: 8 };
      const ragSearch = await deps.executeToolWithEvents('rag_search', ragSearchArgs);
      await appendAutoToolResult('rag_search', ragSearchArgs, ragSearch);

      const ragOut = `${ragSearch.output || ''}\n${ragSearch.error || ''}`.toLowerCase();
      const ragHasUsefulHits =
        ragSearch.success &&
        !ragOut.includes('nenhum resultado') &&
        !ragOut.includes('index ausente') &&
        !ragOut.includes('índice rag ausente') &&
        !ragOut.includes('query muito distante');

      if (!ragHasUsefulHits && lexicalFallbackEnabled && availableTools.has('grep_file')) {
        eventBus.emit(EventType.PROGRESS_UPDATE, {
          message: 'RAG fallback: lexical grep micro-context',
          intentType: 'general'
        });
        const lexicalNeedles = extractLexicalNeedles(userInput, 3);
        for (const needle of lexicalNeedles) {
          const grepArgs: Record<string, unknown> = {
            pattern: escapeRegexLiteral(needle),
            path: '.',
            context: 1,
            maxResults: 6,
          };
          const grepResult = await deps.executeToolWithEvents('grep_file', grepArgs);
          await appendAutoToolResult('grep_file', grepArgs, grepResult);
        }
      }

      messages.push({
        role: 'user',
        content: ragHasUsefulHits
          ? 'Use the rag_search evidence above as primary context. If needed, confirm specifics with grep_file/find_function/read_file ranges.'
          : 'RAG did not provide enough evidence. Fallback now to lexical micro-context: grep_file/find_function first, then read_file with startLine/endLine.'
      });
      await compactLoopMessages(messages, contextThresholdTokens, deps.distillDroppedMessages, deps.tokenCount, userInput);
    }

    let accumulatedContent = '';
    let accumulatedReasoning = '';
    let hadNativeToolCalls = false;
    const toolCallsFromStream: Array<{
      id?: string;
      tool: string;
      arguments: Record<string, unknown> | string;
    }> = [];

    // Per-iteration display filter. The raw stream goes into
    // accumulatedContent (the protocol parser needs to see the tool-call
    // envelope to extract it), but the user shouldn't see fenced JSON or
    // {"type":"tool",...} blobs in the answer area. This stateful stripper
    // swallows ```…``` fences and JSON envelopes across chunk boundaries.
    let displayStripMode: 'pass' | 'fence' | 'envelope' = 'pass';
    let displayStripBuf = '';
    let displayEnvelopeDepth = 0;
    const filterForDisplay = (chunk: string): string => {
      let out = '';
      let i = 0;
      const buf = displayStripBuf + chunk;
      displayStripBuf = '';
      while (i < buf.length) {
        if (displayStripMode === 'pass') {
          const fenceIdx = buf.indexOf('```', i);
          const envIdx = buf.indexOf('{"type"', i);
          let nextIdx = -1;
          let nextMode: 'fence' | 'envelope' = 'fence';
          if (fenceIdx !== -1 && (envIdx === -1 || fenceIdx < envIdx)) {
            nextIdx = fenceIdx; nextMode = 'fence';
          } else if (envIdx !== -1) {
            nextIdx = envIdx; nextMode = 'envelope';
          }
          if (nextIdx === -1) {
            const tail = buf.slice(i);
            // Hold back the last 7 chars (enough for ``` partial or `{"typ`).
            if (tail.length > 7) {
              out += tail.slice(0, tail.length - 7);
              displayStripBuf = tail.slice(-7);
            } else {
              displayStripBuf = tail;
            }
            break;
          }
          out += buf.slice(i, nextIdx);
          if (nextMode === 'fence') {
            i = nextIdx + 3;
            displayStripMode = 'fence';
          } else {
            i = nextIdx;
            displayStripMode = 'envelope';
            displayEnvelopeDepth = 0;
          }
        } else if (displayStripMode === 'fence') {
          const closeIdx = buf.indexOf('```', i);
          if (closeIdx === -1) { displayStripBuf = ''; break; }
          i = closeIdx + 3;
          displayStripMode = 'pass';
        } else if (displayStripMode === 'envelope') {
          for (; i < buf.length; i++) {
            const c = buf[i];
            if (c === '{') displayEnvelopeDepth++;
            else if (c === '}') {
              displayEnvelopeDepth--;
              if (displayEnvelopeDepth <= 0) { i++; displayStripMode = 'pass'; break; }
            }
          }
          if (displayStripMode === 'envelope') { displayStripBuf = ''; break; }
        }
      }
      return out;
    };

    const flushDisplayFilter = (): string => {
      if (displayStripMode !== 'pass' || !displayStripBuf) return '';
      const out = displayStripBuf;
      displayStripBuf = '';
      return out;
    };

    try {
      await deps.llm.chatStream(
        messages,
        (chunk) => {
          accumulatedContent += chunk;
          if (deps.streamEnabled) {
            const visible = filterForDisplay(chunk);
            if (visible) eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: visible });
          }
        },
        (toolName, args, id) => {
          hadNativeToolCalls = true;
          toolCallsFromStream.push({ id, tool: toolName, arguments: args });
        },
        deps.supportsNativeTools ? deps.toolDefs : undefined,
        (reasoning) => {
          accumulatedReasoning += reasoning;
          if (deps.streamEnabled) {
            const filtered = reasoning.replace(/<think>|<\/think>/g, '');
            if (filtered) eventBus.emit(EventType.REASONING_CHUNK, { chunk: filtered });
          }
        }
      );
      const remainingVisible = flushDisplayFilter();
      if (remainingVisible && deps.streamEnabled) {
        eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: remainingVisible });
      }
    } catch (error: any) {
      // Recover from "prompt exceeds context size" by lowering the
      // threshold to the server's real n_ctx (carried on the typed
      // error), force-compacting, then retrying. Without this, a single
      // oversized turn permanently kills the conversation even though
      // compaction is exactly the operation that would fix it.
      const isContextExceeded =
        error?.name === 'ContextExceededError' ||
        /exceed_context_size_error|exceeds the available context size|backend context exceeded/i.test(String(error?.message || ''));
      if (isContextExceeded && contextRecoveryAttempts < MAX_CONTEXT_RECOVERIES) {
        contextRecoveryAttempts++;
        const serverNCtx = Number(error?.serverNCtx) || extractNCtxFromMessage(error?.message);
        if (serverNCtx > 0) {
          // Use 80% of the server ceiling so the next request leaves room
          // for the model's reply. 90% (the steady-state setting) bit us
          // here — keep some headroom on the recovery path.
          contextThresholdTokens = Math.max(1024, Math.floor(serverNCtx * 0.8));
        } else {
          contextThresholdTokens = Math.max(1024, Math.floor(contextThresholdTokens * 0.6));
        }
        eventBus.emit(EventType.PROGRESS_UPDATE, {
          message: `Context exceeded — compacting to ${contextThresholdTokens} tokens and retrying (${contextRecoveryAttempts}/${MAX_CONTEXT_RECOVERIES})`,
          intentType: 'general'
        });
        await compactLoopMessages(messages, contextThresholdTokens, deps.distillDroppedMessages, deps.tokenCount, userInput, true);
        iteration--; // retry this iteration with the smaller window
        continue;
      }
      // Recover from server-side tool-call JSON parse errors (notably
      // llama.cpp's --jinja parser truncating large content args). We
      // don't retry blindly — same prompt would produce same truncation —
      // we re-prompt the model with explicit instructions to shrink the
      // next tool call. Bounded by MAX_SERVER_PARSE_RECOVERIES so a
      // persistent server bug doesn't loop forever.
      const errMsg = String(error?.message || '').toLowerCase();
      const isToolParseError =
        errMsg.includes('failed to parse tool call arguments') ||
        errMsg.includes('parse error') && errMsg.includes('tool');
      if (isToolParseError && serverParseErrorRecoveryAttempts < MAX_SERVER_PARSE_RECOVERIES) {
        serverParseErrorRecoveryAttempts++;
        messages.push({
          role: 'user',
          content:
            `The server rejected your previous tool call with a JSON parse ` +
            `error in the arguments. This happens when the content argument ` +
            `is too long OR contains characters that confuse the server's ` +
            `parser (multi-byte unicode like ╔═╗║╚═╝, emojis, deeply nested ` +
            `quotes).\n\n` +
            `Retry with a MUCH SMALLER tool call:\n` +
            `1. If you were writing a whole file: break it into 2-4 separate ` +
            `   apply_patch / write_file calls (per Rule 3 block-based).\n` +
            `2. Keep each "content" or "patch" argument under ~400 characters.\n` +
            `3. Avoid box-drawing characters and emojis in code content for ` +
            `   the next attempt — use plain ASCII alternatives.\n` +
            `4. After each small block call validate_syntax before the next.`
        });
        eventBus.emit(EventType.PROGRESS_UPDATE, {
          message: `Recovering from server parse error (${serverParseErrorRecoveryAttempts}/${MAX_SERVER_PARSE_RECOVERIES})`,
          intentType: 'general'
        });
        continue;
      }
      // Not a recoverable parse error, or budget exhausted — rethrow so the
      // caller (agent.ts) can surface it normally.
      throw error;
    }

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
          : accumulatedContent)?.trim() || '';
        // KV-cache storage: same rationale as contentForKVCache below — use the
        // raw assistant stream so the slot's cached tokens match on the next
        // turn. If thinking was split from content, re-wrap it in the model's
        // standard tag form for the next prompt prefix.
        const finalForKVCache = accumulatedReasoning.trim()
          ? `<think>\n${accumulatedReasoning.trimEnd()}\n</think>\n${accumulatedContent || ''}`
          : (accumulatedContent || finalContent);

        // IO-guard: when the user's request clearly requires disk/code
        // operations, do not accept a plain-text stop before any tool call
        // landed. This prevents premature [done] exits after lost tool-call
        // payloads or shallow model replies.
        if (ioIntent && !sawAnyToolCall && ioContinuationAttempts < MAX_IO_CONTINUATIONS) {
          ioContinuationAttempts++;
          messages.push({
            role: 'user',
            content:
              `You have not executed any tool call yet, but this task requires filesystem/code operations.\n` +
              `Use a micro-context workflow now:\n` +
              `1) project_map (once, if needed)\n` +
              `2) grep_file/find_function to locate exact region\n` +
              `3) read_file with startLine/endLine (small window)\n` +
              `4) mutate (apply_patch/write_file) only after concrete evidence\n\n` +
              `Do not conclude yet.`
          });
          eventBus.emit(EventType.PROGRESS_UPDATE, {
            message: `Micro-context continuation (${ioContinuationAttempts}/${MAX_IO_CONTINUATIONS})`,
            intentType: 'plan'
          });
          continue;
        }

        // No-progress guard. If two iterations in a row produce zero tool
        // calls AND no brain state change, the model is spinning on
        // thinking text without acting — bail BEFORE the plan/verification
        // continuation budgets force more iterations. The snapshot
        // captures plan progress + mutation/test/build counters; a real
        // change between iterations (model called a tool, completed a
        // step, etc.) resets the counter to zero.
        const brainSnapshot = snapshotBrainProgress(deps.brain);
        if (brainSnapshot === lastBrainProgressSnapshot) {
          noProgressIterations++;
          if (noProgressIterations >= MAX_NO_PROGRESS_ITERATIONS) {
            const msg =
              `Tool loop stopped: ${MAX_NO_PROGRESS_ITERATIONS}+ iterations without tool calls or ` +
              `brain progress (model is producing only thinking text). Accepting current answer.`;
            const tail = finalContent ? finalContent : msg;
            const tailStorage = tail === finalContent ? finalForKVCache : tail;
            deps.emitAssistantMessage(tail, tailStorage);
            return tail;
          }
        } else {
          noProgressIterations = 0;
          lastBrainProgressSnapshot = brainSnapshot;
        }

        if (deps.brain?.getRequestMetrics && verificationContinuationAttempts < MAX_VERIFICATION_CONTINUATIONS) {
          const metrics = deps.brain.getRequestMetrics();
          const mutated = metrics.mutationCount > 0;
          const verified = (metrics.testsRun > 0) || (metrics.buildRun > 0);
          const validated = metrics.validationCount > 0;
          if (mutated && (!validated || !verified)) {
            verificationContinuationAttempts++;
            messages.push({
              role: 'user',
              content:
                `Before concluding, complete defensive verification for this request:\n` +
                `- Mutations detected: ${metrics.mutationCount}\n` +
                `- validate_syntax calls: ${metrics.validationCount}\n` +
                `- build runs: ${metrics.buildRun}\n` +
                `- run_tests calls: ${metrics.testsRun}\n\n` +
                `Run missing validation/verification now, then continue.`
            });
            eventBus.emit(EventType.PROGRESS_UPDATE, {
              message: `Verification continuation (${verificationContinuationAttempts}/${MAX_VERIFICATION_CONTINUATIONS})`,
              intentType: 'plan'
            });
            continue;
          }
        }

        // Plan-driven continuation: if the model declared a plan (via
        // set_plan or by emitting "Plan:" text that the extractor picked up)
        // and there are still pending/in_progress steps, push it back to
        // continue instead of accepting the premature stop. This is NOT a
        // keyword heuristic on user input — it's checking the model's OWN
        // declared work-state via the brain. The model itself chose to make
        // a plan; we just hold it to the plan it set.
        if (deps.brain && planContinuationAttempts < MAX_PLAN_CONTINUATIONS) {
          const pending = deps.brain.getPlanSteps()
            .filter(s => s.status === 'pending' || s.status === 'in_progress');
          if (pending.length > 0) {
            planContinuationAttempts++;
            const pendingList = pending
              .map((s, i) => `${i + 1}. ${s.title} (${s.status})`)
              .join('\n');
            messages.push({
              role: 'user',
              content:
                `You declared a plan and ${pending.length} step(s) are still ` +
                `pending or in progress:\n${pendingList}\n\n` +
                `Continue with the next pending step. Call complete_step after ` +
                `each step finishes. Only stop when every step is marked done — ` +
                `or call set_plan again with a revised plan if the task changed.`
            });
            eventBus.emit(EventType.PROGRESS_UPDATE, {
              message: `Plan continuation (${planContinuationAttempts}/${MAX_PLAN_CONTINUATIONS}) — ${pending.length} pending`,
              intentType: 'plan'
            });
            continue;
          }
        }

        // No plan, all steps complete, OR continuation budget exhausted —
        // accept the model's stop. No keyword-based forcing of tool use.
        if (finalContent) {
          deps.emitAssistantMessage(finalContent, finalForKVCache);
        }
        return finalContent;
      }
    }

    if (toolCallsFromStream.length > 0) sawAnyToolCall = true;

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

    // Tool calls present → real progress this iteration. Reset the
    // no-progress counter and re-snapshot the brain so the next empty
    // iteration compares against post-tool state.
    noProgressIterations = 0;
    lastBrainProgressSnapshot = snapshotBrainProgress(deps.brain);

    const thought = deps.stripTemplateArtifacts(accumulatedContent?.trim() || '');
    // KV-cache content MUST be the raw bytes the model emitted, so the
    // server's slot KV (which holds the original generated tokens) matches
    // the round-tripped prompt prefix on the next request. stripTemplateArtifacts
    // removes <tool_call>, JSON envelopes, ```json``` blocks — anything stripped
    // here causes a token-sequence divergence and a full prefill on every turn.
    // Thinking may arrive as a native reasoning channel or inline
    // <think>...</think>. Store it in the same structural form so the
    // round-tripped prompt matches the generated token sequence.
    const rawContent = accumulatedContent || '';
    const contentForKVCache = accumulatedReasoning.trim()
      ? `<think>\n${accumulatedReasoning.trimEnd()}\n</think>\n${rawContent}`
      : rawContent;

    if (thought || toolCallsFromStream.length > 0) {
      const visibleForTurn = thought || `Using: ${toolCallsFromStream.map(t => t.tool).join(', ')}`;
      eventBus.emit(EventType.AGENT_MESSAGE, {
        content: visibleForTurn
      });
      // Preserve the user-visible form for session restore (see
      // Message.displayContent in types.ts). `contentForKVCache` keeps the
      // raw <think>…</think>\n bytes the model emitted (often with empty
      // tail when only tool_calls were produced); displayContent stores
      // the "thought" or "Using: tool_x" string that actually appeared on
      // screen.
      deps.state.addMessage({
        role: 'assistant',
        content: contentForKVCache,
        timestamp: Date.now(),
        tool_calls: toolCallEntries,
        ...(visibleForTurn && visibleForTurn !== contentForKVCache
          ? { displayContent: visibleForTurn }
          : {})
      });
    }

    if (hadNativeToolCalls) {
      messages.push({
        role: 'assistant',
        content: contentForKVCache,
        tool_calls: toolCallEntries
      });
    } else {
      messages.push({
        role: 'assistant',
        content: contentForKVCache
      });
    }
    await compactLoopMessages(messages, contextThresholdTokens, deps.distillDroppedMessages, deps.tokenCount, userInput);

    eventBus.emit(EventType.CLEAR_STREAMING, {});

    let allFailed = toolCallsFromStream.length > 0;
    let hadSuccessfulTool = false;
    const normalizedToolCalls = toolCallsFromStream.map(tc => {
      const normalizedName = deps.normalizeToolName(tc.tool);
      const parsedArgs = parseToolCallArgs(tc.arguments);
      return { name: normalizedName, ...parsedArgs };
    });
    const currentToolPlanSignature = normalizedToolCalls
      .map(tc => `${tc.name}:${stableStringify(tc.args)}`)
      .join('||');

    // Tracks files mutated this iteration whose extension is "validatable"
    // (.ts/.py/etc — not markdown/json). After the for-loop, if any of
    // these were not followed by a validate_syntax call on the same path,
    // we inject a nudge for the next iteration.
    const mutatedFilesThisIter = new Set<string>();
    const validatedFilesThisIter = new Set<string>();

    for (let i = 0; i < toolCallsFromStream.length; i++) {
      const tc = toolCallsFromStream[i];
      const toolCallId = toolCallEntries[i].id;
      const toolName = normalizedToolCalls[i].name;

      const rawArgs: Record<string, unknown> = normalizedToolCalls[i].args;
      const argsParseError = normalizedToolCalls[i].parseError;

      // Per-call dedup window. Append BEFORE execute so a duplicate is
      // detected even on its triggering call. We don't skip the call itself
      // (the result may have changed); we just count it for the guard below.
      const callHash = argsParseError
        ? `${toolName}:<invalid-args:${normalizedToolCalls[i].signaturePayload}>`
        : `${toolName}:${stableStringify(rawArgs)}`;

      // Call-time bypass: if THIS exact (name, args) already appears in the
      // recent window, short-circuit. LOOP_GUARD_EXEMPT_TOOLS gives a free
      // pass to the WINDOW-LIMIT guard further down (so grep_file with
      // varied queries doesn't trip the abort), but NOT here — bit-for-bit
      // identical args are repetition regardless of which tool, and the
      // prior result is already in context. Re-executing wastes a turn
      // AND feeds the model the same bytes it already failed to parse.
      const previousIdx = recentCallHashes.lastIndexOf(callHash);
      const isImmediateRepeat = previousIdx >= 0;
      recentCallHashes.push(callHash);
      if (recentCallHashes.length > RECENT_CALLS_WINDOW) recentCallHashes.shift();

      const toolResult = argsParseError
        ? {
            success: false,
            output: '',
            error:
              `Invalid tool arguments JSON for ${toolName}. ` +
              `The call was skipped to avoid executing with empty args. ` +
              `Details: ${argsParseError}`
          }
        : isImmediateRepeat
        ? {
            success: false,
            output: '',
            error:
              `Duplicate call skipped: ${toolName} with the same args was already ` +
              `executed ${recentCallHashes.length - previousIdx} call(s) ago. ` +
              `The prior <tool_response> with this same (tool, args) is above — ` +
              `read it instead of re-issuing the call. If you genuinely need fresh ` +
              `data, change the args (different path, different pattern, etc).`
          }
        : await deps.executeToolWithEvents(toolName, rawArgs);
      if (toolResult.success) {
        allFailed = false;
        hadSuccessfulTool = true;

        // Track mutations on validatable files only. apply_patch + write_file
        // + create_file all carry `path` at the top level of args.
        const argPath = typeof rawArgs.path === 'string' ? rawArgs.path : '';
        if (MUTATION_TOOL_NAMES.has(toolName) && argPath) {
          const ext = extractExtension(argPath);
          if (!SKIP_VALIDATION_EXTENSIONS.has(ext)) {
            mutatedFilesThisIter.add(argPath);
            // write_file/create_file/apply_patch validate syntax inline. When
            // that passed, the explicit validate_syntax nudge is pure
            // redundancy — mark the path validated. When it FAILED (error set
            // or a ⚠ marker in the output) leave it unvalidated so the nudge
            // still pushes a fix.
            const inlineSyntaxOk = !toolResult.error && !toolResult.output.includes('⚠');
            if (inlineSyntaxOk) validatedFilesThisIter.add(argPath);
          }
        }
        if (VALIDATION_TOOL_NAMES.has(toolName) && argPath) {
          validatedFilesThisIter.add(argPath);
        }
      }

      const toolResultContent = deps.formatToolResultForModel(toolName, toolResult);
      const packedToolResult = packToolResultForContext(toolName, toolResultContent, deps.maxContextTokens);
      // Bind the response to the call that produced it. Without (name, args)
      // visible inside the <tool_response> block, the 9B treats every result
      // as ambient and re-calls the same tool with the same args. See
      // appendAutoToolResult above for the same header.
      const decoratedContent = renderToolResultBody(toolName, rawArgs, packedToolResult);

      // BUG-A8: align tool_call_id between the in-loop messages array and
      // state.memory. Previously state.memory ALWAYS stored tool_call_id
      // while the in-loop push only set it when native tools fired — so on
      // the next turn buildInferenceMessagesUseCase reconstructed the
      // prefix WITH tool_call_id while the cached prefix didn't have it,
      // forcing a full KV-cache invalidation.
      deps.state.addMessage({
        role: 'tool',
        content: decoratedContent,
        timestamp: Date.now(),
        ...(hadNativeToolCalls ? { tool_call_id: toolCallId } : {})
      });

      // Identical role/content for both native and text protocols so the
      // in-loop messages array matches what buildInferenceMessagesUseCase
      // reconstructs from state.memory on the next request. Any mismatch
      // here makes the server retokenize the whole prefix.
      pushToolResultDeduped(messages, {
        role: 'tool',
        content: decoratedContent,
        ...(hadNativeToolCalls ? { tool_call_id: toolCallId } : {})
      });
      await compactLoopMessages(messages, contextThresholdTokens, deps.distillDroppedMessages, deps.tokenCount, userInput);
    }

    // Post-mutation validation gate. Files mutated this iteration that
    // were NOT validated this iteration → ask the model to validate them
    // before continuing. Bounded by MAX_VALIDATION_NUDGES so we never
    // loop forever on a model that refuses to validate (e.g. validator
    // doesn't support the language). The nudge is a `user`-role message
    // so it shows up in the model's "what to do next" context, not as
    // a tool result it might ignore.
    const unvalidated = [...mutatedFilesThisIter].filter(p => !validatedFilesThisIter.has(p));
    if (unvalidated.length > 0 && validationNudges < MAX_VALIDATION_NUDGES) {
      validationNudges++;
      const fileList = unvalidated.slice(0, 5).join(', ');
      const more = unvalidated.length > 5 ? ` (+${unvalidated.length - 5} more)` : '';
      messages.push({
        role: 'user',
        content:
          `Post-edit check: you mutated ${unvalidated.length} file(s) this turn without ` +
          `calling validate_syntax. Before the next mutation or final answer, run:\n` +
          unvalidated.slice(0, 5).map(p => `  validate_syntax({ path: "${p}" })`).join('\n') +
          `${more}\n\n` +
          `If the file is not lintable (markdown, json, etc) say so explicitly and ` +
          `continue. If validation fails, fix it with apply_patch before moving on.`
      });
      eventBus.emit(EventType.PROGRESS_UPDATE, {
        message: `Validation reminder: ${unvalidated.length} file(s) need validate_syntax (${validationNudges}/${MAX_VALIDATION_NUDGES})`,
        intentType: 'general'
      });
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

    // Per-call dedup guard. If any (tool, args) hash dominates the recent
    // window (≥ RECENT_CALLS_THRESHOLD out of the last RECENT_CALLS_WINDOW
    // calls), the model is hammering the same call without taking the
    // result into account — break with a directive that quotes the call.
    if (recentCallHashes.length >= RECENT_CALLS_THRESHOLD) {
      const counts = new Map<string, number>();
      for (const h of recentCallHashes) {
        const idx = h.indexOf(':');
        const tool = idx > 0 ? h.slice(0, idx) : h;
        if (LOOP_GUARD_EXEMPT_TOOLS.has(tool)) continue;
        counts.set(h, (counts.get(h) || 0) + 1);
      }
      let worst: { hash: string; count: number } | null = null;
      for (const [hash, count] of counts) {
        if (count >= RECENT_CALLS_THRESHOLD && (!worst || count > worst.count)) {
          worst = { hash, count };
        }
      }
      if (worst) {
        // Hash format is `tool:stableStringified(args)`; only the head is
        // useful in the user-facing message, args may be long.
        const colonIdx = worst.hash.indexOf(':');
        const repeatedTool = colonIdx > 0 ? worst.hash.slice(0, colonIdx) : worst.hash;
        const repeatedArgs = colonIdx > 0 ? worst.hash.slice(colonIdx + 1).slice(0, 200) : '';
        const msg =
          `Tool loop stopped: ${repeatedTool}(${repeatedArgs}) was called ${worst.count}× ` +
          `in the last ${recentCallHashes.length} calls without taking the result into account. ` +
          `Read the previous tool output, change strategy, or finish the turn.`;
        deps.emitAssistantMessage(msg);
        return msg;
      }
    }

    if (allFailed) {
      consecutiveAllFailures++;
    } else {
      consecutiveAllFailures = 0;
    }

    // BUG-A12: tight cap on args-parse-error streaks. If EVERY tool call
    // this iteration failed to parse its arguments JSON, count it; reset
    // as soon as any call parses cleanly.
    const allArgsParseErrorsThisIter =
      normalizedToolCalls.length > 0 &&
      normalizedToolCalls.every(c => Boolean(c.parseError));
    if (allArgsParseErrorsThisIter) {
      consecutiveArgsParseErrors++;
    } else {
      consecutiveArgsParseErrors = 0;
    }
    if (consecutiveArgsParseErrors >= MAX_CONSECUTIVE_ARGS_PARSE_ERRORS) {
      const msg =
        `Tool loop stopped: ${MAX_CONSECUTIVE_ARGS_PARSE_ERRORS} consecutive ` +
        `iterations where every tool call had unparseable arguments JSON. ` +
        `The model is emitting malformed tool envelopes — finishing the turn.`;
      deps.emitAssistantMessage(msg);
      return msg;
    }

    if (consecutiveAllFailures >= 3) {
      const msg = 'All tools failed 3 consecutive iterations. Stopping.';
      deps.emitAssistantMessage(msg);
      return msg;
    }

    // Soft safety net — won't trigger in any realistic session, just stops
    // a runaway from burning forever if every progress guard somehow misses.
    if (iteration + 1 >= MAX_ITERATIONS_SOFT_CAP) {
      const limitMessage = `Tool iteration soft cap reached (${MAX_ITERATIONS_SOFT_CAP}). Task concluded.`;
      deps.emitAssistantMessage(limitMessage);
      return limitMessage;
    }
  }

  const limitMessage = 'Tool iteration soft cap reached.';
  deps.emitAssistantMessage(limitMessage);
  return limitMessage;
}

/**
 * Push a tool result onto the message log. If the EXACT same content is
 * already present in the last 10 messages, push a short reference marker
 * instead of duplicating the payload — the model already has the data in
 * its context and a verbatim re-emit just consumes window budget and
 * accelerates the compaction trigger. Bounded look-back keeps the scan
 * O(1) per push.
 *
 * Both protocols now use the same shape: `role: 'tool'` with
 * `content: packedToolResult` (and `tool_call_id` set only on the native
 * tools path, where the API needs it to bind the result to its originating
 * call). Keeping a single shape makes the in-loop messages match what
 * buildInferenceMessagesUseCase later reconstructs from state.memory — that
 * byte-stability is what lets the server's slot KV reuse the prefix across
 * user turns. Dedup compares (role, content) so it works identically.
 *
 * Intentionally NOT mutating the older message — keeping the previous
 * full result intact means the model's reasoning that referenced it stays
 * coherent.
 */
function pushToolResultDeduped(messages: InferenceMessage[], next: InferenceMessage): void {
  const limit = Math.max(1, messages.length - 10);
  for (let i = messages.length - 1; i >= limit; i--) {
    const prev = messages[i];
    if (prev.role !== next.role) continue;
    if (typeof prev.content !== 'string' || typeof next.content !== 'string') continue;
    if (prev.content !== next.content) continue;
    // Exact recent duplicate — emit a short reference marker.
    const ago = messages.length - i;
    const marker = next.role === 'tool'
      ? `[Tool result] (identical to ${ago} message(s) ago — no new info)`
      : `[Tool result] (identical to ${ago} message(s) ago — no new info)`;
    const replacement: InferenceMessage = { ...next, content: marker };
    messages.push(replacement);
    return;
  }
  messages.push(next);
}

/**
 * Lowercase file extension including the leading dot. Returns "" for
 * paths without an extension. Used by the validation gate to decide
 * whether a mutated file is worth nudging the model to validate (we
 * skip markdown/json/etc — the validator is a no-op there and would
 * waste an iteration).
 */
function extractExtension(filePath: string): string {
  const lastSlash = Math.max(filePath.lastIndexOf('/'), filePath.lastIndexOf('\\'));
  const base = lastSlash >= 0 ? filePath.slice(lastSlash + 1) : filePath;
  const dot = base.lastIndexOf('.');
  if (dot <= 0) return '';
  return base.slice(dot).toLowerCase();
}

/**
 * Pull `n_ctx` out of a context-exceeded error message when the typed
 * `ContextExceededError` isn't available (e.g., because the error came
 * up through a non-OllamaClient path). The message format llama-server
 * uses includes `"n_ctx":<number>` verbatim.
 */
function extractNCtxFromMessage(message: unknown): number {
  const m = String(message || '').match(/"n_ctx"\s*:\s*(\d+)|\bn_ctx\s*=\s*(\d+)/i);
  const value = m?.[1] || m?.[2];
  if (!value) return 0;
  return Number(value);
}

async function compactLoopMessages(
  messages: InferenceMessage[],
  thresholdTokens: number,
  distillFn?: (dropped: InferenceMessage[]) => Promise<void>,
  tokenCount?: (text: string) => Promise<number | null>,
  pinnedUserContent?: string,
  forceExactCheck: boolean = false
): Promise<void> {
  if (messages.length <= 3) return;

  // Fast gate: char/4 estimate is cheap. In steady-state we trust this
  // for speed and only call tokenizer when estimate is above threshold.
  // In forced mode (context-exceeded recovery) we ALWAYS verify with exact
  // tokenization when available — char/4 underestimation was the root cause
  // of retry loops that never actually compacted.
  const estimated = estimateLoopTokens(messages);
  if (estimated <= thresholdTokens && !forceExactCheck) return;
  if (tokenCount) {
    const exact = await exactLoopTokens(messages, tokenCount);
    if (exact !== null && exact <= thresholdTokens) return;
    if (exact === null && estimated <= thresholdTokens && !forceExactCheck) return;
  } else if (estimated <= thresholdTokens && !forceExactCheck) {
    return;
  }

  // BUG-A14: preserve the FULL contiguous block of leading `system`
  // messages, not just index 0. buildInferenceMessagesUseCase can inject a
  // second system message right after the base prompt (the conversation
  // summary — see FIX-01). The previous `system = messages[0]` dropped
  // that summary on the first in-loop compaction, undoing the build-time
  // summarization.
  let systemBlockEnd = 0;
  while (systemBlockEnd < messages.length && messages[systemBlockEnd].role === 'system') {
    systemBlockEnd++;
  }
  const systemBlock = messages.slice(0, Math.max(1, systemBlockEnd));
  const tail = messages.slice(systemBlock.length);
  const dropped: InferenceMessage[] = [];
  // Steady-state keeps at least 4 turns for continuity. Recovery mode can
  // shrink deeper because the alternative is guaranteed hard failure.
  const minTailMessages = forceExactCheck ? 2 : 4;

  // Keep only the newest conversation turns until we fit. In forced mode
  // re-check exact count at each step (when available), so recovery never
  // stops early on an underestimated char/4 count.
  while (tail.length > minTailMessages) {
    const estimatedNow = estimateLoopTokens([...systemBlock, ...tail]);
    let over = estimatedNow > thresholdTokens;
    if (!over && forceExactCheck) {
      if (tokenCount) {
        const exactNow = await exactLoopTokens([...systemBlock, ...tail], tokenCount);
        over = exactNow !== null ? exactNow > thresholdTokens : estimatedNow > Math.floor(thresholdTokens * 0.75);
      } else {
        // No exact tokenizer available in recovery mode: still shrink a bit
        // beyond the nominal threshold to increase odds of fitting server n_ctx.
        over = estimatedNow > Math.floor(thresholdTokens * 0.75);
      }
    }
    if (!over) break;
    const removed = tail.shift();
    if (removed) {
      dropped.push(removed);
      continue;
    }
    break;
  }

  // Pin the user's current request: if it got dropped while shrinking the
  // window, re-insert it at the head of tail so the model retains its
  // anchor. Without this, long tool-heavy loops strip the user's intent
  // and the model pattern-matches a trajectory with no destination — the
  // observed "model divaga" symptom. Removing it from `dropped` also
  // prevents distillation from treating the live intent as old context.
  if (pinnedUserContent) {
    const matchesPinned = (m: InferenceMessage): boolean => {
      if (m.role !== 'user') return false;
      if (typeof m.content === 'string') return m.content === pinnedUserContent;
      if (Array.isArray(m.content)) {
        const textPart = m.content.find(p => p && (p as { type?: string }).type === 'text');
        return Boolean(textPart && (textPart as { text?: string }).text === pinnedUserContent);
      }
      return false;
    };
    const stillPresent = tail.some(matchesPinned);
    if (!stillPresent) {
      const droppedIdx = dropped.findIndex(matchesPinned);
      if (droppedIdx >= 0) dropped.splice(droppedIdx, 1);
      // Restore as text-only — multimodal parts (images) from the original
      // call were consumed on the first inference; the model has already
      // reasoned on them. The text intent is what must persist.
      tail.unshift({ role: 'user', content: pinnedUserContent });
    }
  }

  // Last safety net for recovery: if exact tokenization still says we're
  // above threshold, keep shrinking (best effort) until min tail or fit.
  // This only runs in forced mode.
  if (forceExactCheck && tail.length > minTailMessages && tokenCount) {
    while (tail.length > minTailMessages) {
      const exactNow = await exactLoopTokens([...systemBlock, ...tail], tokenCount);
      if (exactNow === null || exactNow <= thresholdTokens) break;
      const removed = tail.shift();
      if (removed) dropped.push(removed);
      else break;
    }
  }

  // BUG-A14: rewrite using the full preserved system block.
  messages.splice(0, messages.length, ...systemBlock, ...tail);

  // Distillation runs AFTER the window shrinks so the loop can resume
  // immediately on the in-place tail; if the LLM call fails or hangs the
  // worst case is we lose the durable copy, not block the conversation.
  // We still await to keep ordering predictable for tests and so a follow-up
  // compaction can observe the updated memory.
  if (distillFn && dropped.length > 0) {
    try {
      await distillFn(dropped);
    } catch {
      // Swallow: distillation is best-effort; never block the loop.
    }
  }
}

/**
 * Exact token count via backend tokenizer (llama-server's /tokenize).
 * Returns null when the backend can't tokenize OR any single tokenization
 * call fails — caller falls back to the estimate. We tokenize the whole
 * concatenated content as one call to keep the round-trip count low.
 */
async function exactLoopTokens(
  messages: InferenceMessage[],
  tokenCount: (text: string) => Promise<number | null>
): Promise<number | null> {
  const chunks: string[] = [];
  let overhead = 0;
  for (const msg of messages) {
    if (typeof msg.content === 'string') {
      chunks.push(msg.content);
    } else if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        if (part.text) chunks.push(part.text);
      }
    }
    overhead += 12;
    if (msg.tool_calls?.length) {
      chunks.push(JSON.stringify(msg.tool_calls));
    }
  }
  const joined = chunks.join('\n');
  if (!joined) return overhead;
  const exact = await tokenCount(joined);
  if (exact === null) return null;
  return exact + overhead;
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

function parseToolCallArgs(
  value: Record<string, unknown> | string
): {
  args: Record<string, unknown>;
  parseError: string | null;
  signaturePayload: string;
} {
  if (typeof value !== 'string') {
    return {
      args: value || {},
      parseError: null,
      signaturePayload: stableStringify(value || {}),
    };
  }

  const trimmed = value.trim();
  if (!trimmed) {
    return {
      args: {},
      parseError: 'arguments string is empty',
      signaturePayload: 'empty',
    };
  }

  const parsed = safeJsonParse<unknown>(trimmed);
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
    return {
      args: parsed as Record<string, unknown>,
      parseError: null,
      signaturePayload: stableStringify(parsed),
    };
  }

  return {
    args: {},
    parseError: 'malformed JSON string in tool call arguments',
    signaturePayload: trimmed.slice(0, 200).replace(/\s+/g, ' '),
  };
}

function buildIterationOutcomeSignature(
  calls: Array<{ name: string; args: Record<string, unknown> }>,
  allFailed: boolean,
  hadSuccessfulTool: boolean
): string {
  const callSignature = calls.map(c => `${c.name}:${stableStringify(c.args)}`).join('|');
  return `${callSignature}::failed=${allFailed}::success=${hadSuccessfulTool}`;
}

/**
 * Compact snapshot of brain-observable progress for the no-progress
 * guard: plan steps + their statuses + mutation/test/build counters.
 * If two consecutive iterations produce identical snapshots AND no tool
 * calls landed, the model is spinning without acting. Empty string for
 * brains that don't expose either accessor (test mocks).
 */
function snapshotBrainProgress(brain: RunToolLoopDeps['brain']): string {
  if (!brain) return '';
  const parts: string[] = [];
  if (brain.getPlanSteps) {
    try {
      const steps = brain.getPlanSteps() || [];
      parts.push('plan:' + steps.map((s: any) => `${s.title ?? ''}=${s.status ?? ''}`).join(';'));
    } catch { /* ignore */ }
  }
  if (brain.getRequestMetrics) {
    try {
      const m = brain.getRequestMetrics();
      parts.push(`mut:${m.mutationCount}|val:${m.validationCount}|build:${m.buildRun}|tests:${m.testsRun}`);
    } catch { /* ignore */ }
  }
  return parts.join('||');
}

function looksLikeIoTask(input: string): boolean {
  const q = String(input || '').toLowerCase();
  if (!q.trim()) return false;
  const hints = [
    'read_file', 'write_file', 'apply_patch', 'create_file', 'list_dir', 'grep_file',
    'file', 'arquivo', 'arquivos', 'codigo', 'código', 'source', 'refactor',
    'edit', 'editar', 'corrigir', 'fix', 'patch', 'implement', 'implementar',
    'alterar', 'modificar', 'função', 'function', 'classe', 'class'
  ];
  return hints.some(h => q.includes(h));
}

function looksLikeConceptTask(input: string): boolean {
  const q = String(input || '').toLowerCase();
  if (!q.trim()) return false;
  const hints = [
    'onde', 'where', 'como funciona', 'how does', 'arquitetura', 'architecture',
    'fluxo', 'flow', 'pipeline', 'depend', 'dependency', 'dependência',
    'responsável', 'responsavel', 'who handles', 'which file', 'qual arquivo',
    'find the part', 'find where'
  ];
  return hints.some(h => q.includes(h));
}

/**
 * Compose the body of a <tool_response> with a deterministic header that
 * identifies the call (name + args) plus the packed result. Used by both
 * the in-loop messages array and state.memory so the byte sequence matches
 * across requests — required for llama.cpp's prompt-cache prefix match.
 *
 * The header is intentionally short and structured so the model can scan
 * for it without spending tokens on prose. `stableStringify` keeps key
 * ordering deterministic so the same logical args produce the same bytes
 * even if the model emitted them in different order.
 *
 * Args longer than 240 chars are truncated with a marker — full args
 * are usually redundant (a path or query is enough to identify the call)
 * and a 5000-char patch body would dominate the tool_response.
 */
function renderToolResultBody(
  toolName: string,
  args: Record<string, unknown> | undefined,
  packedToolResult: string
): string {
  const argsJson = stableStringify(args || {});
  const argsTrimmed = argsJson.length > 240
    ? argsJson.slice(0, 237) + '...'
    : argsJson;
  const header = `tool: ${toolName}\nargs: ${argsTrimmed}`;
  if (!packedToolResult) return header;
  return `${header}\n---\n${packedToolResult}`;
}

function packToolResultForContext(toolName: string, content: string, maxContextTokens?: number): string {
  if (!config.contextPacking.enabled) return content;
  const normalizedName = String(toolName || '').toLowerCase().trim();
  const normalized = String(content || '').replace(/\r\n/g, '\n');
  if (!normalized) return normalized;

  const budget = getToolContextBudget(normalizedName, maxContextTokens);
  let packed = limitToolResultLines(normalized, budget.maxLines);
  if (packed.length <= budget.maxChars) return packed;

  const omission = packed.length - budget.maxChars;
  const tailKeep = Math.min(budget.keepTailChars, Math.max(0, budget.maxChars - 240));
  const headKeep = Math.max(200, budget.maxChars - tailKeep - 96);
  const head = packed.slice(0, headKeep);
  const tail = tailKeep > 0 ? packed.slice(-tailKeep) : '';

  packed = `${head}\n...[context-packed: ${omission} chars omitted]...\n${tail}`.trim();
  return packed;
}

// FIX-05: Scale budgets dynamically based on available context window
function getToolContextBudget(toolName: string, maxContextTokens?: number): { maxChars: number; maxLines: number; keepTailChars: number } {
  // Default to 32K context if not specified
  const ctx = maxContextTokens || 32768;
  const contextScale = Math.min(1, ctx / 32768);

  const base = {
    maxChars: Math.floor(config.contextPacking.maxChars * contextScale),
    maxLines: Math.floor(config.contextPacking.maxLines * contextScale),
    keepTailChars: Math.floor(config.contextPacking.keepTailChars * contextScale),
  };
  if (toolName === 'project_map') {
    return { maxChars: Math.min(base.maxChars, 2800), maxLines: Math.min(base.maxLines, 120), keepTailChars: Math.min(base.keepTailChars, 700) };
  }
  if (toolName === 'web_search' || toolName === 'get_civic_briefing') {
    return { maxChars: Math.min(base.maxChars, 3200), maxLines: Math.min(base.maxLines, 120), keepTailChars: Math.min(base.keepTailChars, 800) };
  }
  if (toolName === 'grep_file' || toolName === 'search_code') {
    return { maxChars: Math.min(base.maxChars, 3800), maxLines: Math.min(base.maxLines, 140), keepTailChars: Math.min(base.keepTailChars, 900) };
  }
  if (toolName === 'read_file') {
    // read_file is the primary context tool — give it the full base budget so
    // a default-window read survives packing intact. The old 4200/150 caps
    // chopped ~25% off every default read, making the model re-read or patch
    // regions it never fully retained.
    return { maxChars: base.maxChars, maxLines: base.maxLines, keepTailChars: base.keepTailChars };
  }
  return base;
}

function limitToolResultLines(content: string, maxLines: number): string {
  if (maxLines <= 0) return content;
  const lines = content.split('\n');
  if (lines.length <= maxLines) return content;
  const headLines = Math.max(8, Math.floor(maxLines * 0.75));
  const tailLines = Math.max(3, maxLines - headLines);
  const head = lines.slice(0, headLines);
  const tail = lines.slice(-tailLines);
  return `${head.join('\n')}\n...[context-packed: ${lines.length - (headLines + tailLines)} lines omitted]...\n${tail.join('\n')}`;
}

function extractLexicalNeedles(input: string, limit: number): string[] {
  const text = String(input || '');
  const candidates = (text.match(/[A-Za-z_][A-Za-z0-9_./:-]{2,}/g) || [])
    .map(t => t.trim())
    .filter(t => t.length >= 3 && t.length <= 64);
  const stop = new Set([
    'with', 'from', 'para', 'como', 'that', 'this', 'isso', 'isto', 'uma', 'the',
    'and', 'sem', 'semelhante', 'sobre', 'quando', 'where', 'which', 'please', 'poderia',
    'analise', 'analyze', 'implement', 'implemente', 'token', 'tokens'
  ]);
  const uniq: string[] = [];
  for (const token of candidates) {
    const lower = token.toLowerCase();
    if (stop.has(lower)) continue;
    if (uniq.some(v => v.toLowerCase() === lower)) continue;
    uniq.push(token);
    if (uniq.length >= limit) break;
  }
  return uniq.length > 0 ? uniq : ['token', 'tool_call'];
}

function escapeRegexLiteral(value: string): string {
  return String(value || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
