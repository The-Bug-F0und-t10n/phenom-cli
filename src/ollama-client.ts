import { config } from './config.js';
import { eventBus, EventType } from './tui/event-bus.js';
import { ApiChatResponse, ApiClient, ApiChatMessage, ApiContentPart, ApiToolDef } from './api-client.js';
import { BackendInfo, BackendKind, detectBackend, tokenizeCount } from './backend-detector.js';

export class OfflineError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OfflineError';
  }
}

export class OllamaNotFoundError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OllamaNotFoundError';
  }
}

export class OllamaResourceError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OllamaResourceError';
  }
}

export class OllamaTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OllamaTimeoutError';
  }
}

/**
 * Thrown when the backend rejects a request because the prompt exceeds
 * its configured context window (llama-server's `exceed_context_size_error`).
 * Carries the server-reported `n_ctx` so callers can compact to that size
 * and retry instead of failing the whole turn.
 */
export class ContextExceededError extends Error {
  readonly serverNCtx: number;
  readonly promptTokens: number | null;
  constructor(message: string, serverNCtx: number, promptTokens: number | null) {
    super(message);
    this.name = 'ContextExceededError';
    this.serverNCtx = serverNCtx;
    this.promptTokens = promptTokens;
  }
}

export interface TokenUsage {
  input: number;
  output: number;
  total: number;
}

type ToolCallArgs = Record<string, unknown> | string;

interface IncomingToolCall {
  id?: string;
  type?: 'function';
  function: { name: string; arguments: ToolCallArgs };
}

interface IncomingChatMessage {
  role: string;
  content: string | ApiContentPart[];
  tool_calls?: IncomingToolCall[];
  tool_call_id?: string;
}

interface EmbeddingsResponse {
  embeddings?: number[][];
}

interface InferenceProgressHandle {
  stop(): void;
  markModelReady(): void;
}

export class OllamaClient {
  private api: ApiClient;
  private readonly adaptiveContextEnabled: boolean;
  private readonly minContext: number;
  private readonly maxContext: number;
  private readonly requestTimeoutMs: number;
  public lastTokenUsage: TokenUsage = { input: 0, output: 0, total: 0 };
  private readonly maxRetries = 2;
  private readonly retryDelaySeconds = 10;
  // Backend detection runs ONCE on first use (lazy) and the result is
  // cached. llama-server unlocks exact tokenization via /tokenize;
  // Ollama falls back to character-based estimates. See backend-detector.ts.
  private backendInfo: BackendInfo | null = null;
  private backendDetectPromise: Promise<BackendInfo> | null = null;

  constructor() {
    this.adaptiveContextEnabled = config.ollama.adaptiveContext.enabled;
    this.minContext = config.ollama.adaptiveContext.minCtx;
    this.maxContext = config.ollama.adaptiveContext.maxCtx;
    this.requestTimeoutMs = Number.parseInt(String(config.ollama.requestTimeoutMs ?? 180000), 10);
    this.api = new ApiClient();
    const model = String(config.ollama.coderModel || config.ollama.model || '').trim();
    if (model) this.api.setActiveModel(model);
  }

  /**
   * Resolve which backend is on the other end (llama-server | ollama |
   * unknown). Cached after first call. Safe to await concurrently — only
   * one probe is in flight at any time.
   */
  async getBackendInfo(): Promise<BackendInfo> {
    if (this.backendInfo) return this.backendInfo;
    if (!this.backendDetectPromise) {
      const baseUrl = String(config.ollama.host || 'http://127.0.0.1:11434');
      this.backendDetectPromise = detectBackend(baseUrl).then(info => {
        this.backendInfo = info;
        // BUG-H5: plumb the kind into ApiClient so its sync
        // shouldFallbackToNative() can avoid cascading into /api/chat on
        // llama-server (which doesn't expose it).
        ApiClient.setCachedBackendKind(info.kind);
        return info;
      });
    }
    return this.backendDetectPromise;
  }

  /**
   * Count tokens for `text` using the backend's tokenizer when possible.
   * Returns `null` when the backend can't tokenize (Ollama or offline) —
   * callers should fall back to a character-based estimate.
   *
   * The first call awaits backend detection; subsequent calls hit the
   * cached result.
   */
  async tokenizeCount(text: string): Promise<number | null> {
    const info = await this.getBackendInfo();
    return tokenizeCount(info, text);
  }

  /**
   * Effective context window for compaction decisions. Prefers the value
   * the backend actually advertises (llama-server's /props →
   * `default_generation_settings.n_ctx`) over the local OLLAMA_NUM_CTX
   * config, because the local config can be larger than what the server
   * was launched with — and the server is authoritative.
   *
   * Without this, compaction is gated on a local threshold that never
   * trips, while the server rejects the request with
   * `exceed_context_size_error`. See backend-detector.ts:74.
   *
   * Updated reactively when ApiClient sees a 400 exceed_context_size_error
   * carrying an `n_ctx` field (via `noteServerContextLimit`).
   */
  async getEffectiveContextLimit(): Promise<number> {
    const configLimit = Number(config.ollama.options.num_ctx) || 16384;
    const learned = this.learnedServerContextLimit;
    if (typeof learned === 'number' && learned > 0) {
      return Math.min(configLimit, learned);
    }
    try {
      const info = await this.getBackendInfo();
      const settings = info.defaultGenerationSettings as { n_ctx?: unknown } | undefined;
      const serverN = Number(settings?.n_ctx);
      if (Number.isFinite(serverN) && serverN > 0) {
        this.learnedServerContextLimit = serverN;
        return Math.min(configLimit, serverN);
      }
    } catch {
      // /props probe failed — fall through to config value.
    }
    return configLimit;
  }

  /** Called by ApiClient on a 400 exceed_context_size_error so subsequent
   *  compaction passes can use the server's real ceiling. */
  noteServerContextLimit(nCtx: number): void {
    if (!Number.isFinite(nCtx) || nCtx <= 0) return;
    if (this.learnedServerContextLimit && this.learnedServerContextLimit <= nCtx) return;
    this.learnedServerContextLimit = nCtx;
  }

  private learnedServerContextLimit: number | null = null;
  private currentContextLimit: number = 0;

  setActiveModel(model: string): void {
    this.api.setActiveModel(model);
  }

  getActiveModel(): string {
    return this.api.getActiveModel();
  }

  /** Forward the `think` parameter to the underlying ApiClient. */
  setThink(value: boolean | string | null): void {
    this.api.setThink(value);
  }

  async generate(prompt: string, system?: string): Promise<string> {
    for (let attempt = 1; attempt <= this.maxRetries + 1; attempt++) {
      try {
        return await this.api.generate(prompt, system);
      } catch (error: unknown) {
        this.handleApiError(error);
        // BUG-H1: chat completions are NOT idempotent — a retry that hits
        // the server AFTER the model already started generating can
        // duplicate side-effects (rebill, re-run prefill, re-execute tool
        // calls). Only retry on transport-layer errors where we can be
        // confident the server never accepted the request.
        if (attempt <= this.maxRetries && this.isTransportError(error)) {
          await this.delay(this.retryDelaySeconds * attempt * 1000);
          continue;
        }
        throw error;
      }
    }
    return '';
  }

  async chat(
    messages: IncomingChatMessage[],
    tools?: ApiToolDef[]
  ): Promise<ApiChatResponse> {
    this.maybeIncreaseContextForMessages(messages);
    const progress = this.startInferenceProgress();

    const apiMessages: ApiChatMessage[] = messages.map(m => ({
      role: this.toApiRole(m.role),
      content: m.content,
      tool_calls: m.tool_calls?.map(tc => ({
        id: String(tc.id || `call_${Date.now()}`),
        type: 'function' as const,
        function: {
          name: String(tc.function.name || ''),
          arguments: typeof tc.function.arguments === 'string'
            ? tc.function.arguments
            : JSON.stringify(tc.function.arguments || {}),
        }
      })),
      tool_call_id: m.tool_call_id,
    }));

    try {
      for (let attempt = 1; attempt <= this.maxRetries + 1; attempt++) {
        try {
          const response = await this.api.chat(apiMessages, tools);
          progress.markModelReady();
          return response;
        } catch (error: unknown) {
          // FIX-06: On context exceeded, reduce context and retry with smaller window
          if (error instanceof ContextExceededError) {
            const currentCtx = this.api.getRuntimeOption('num_ctx');
            if (typeof currentCtx === 'number' && currentCtx > 4096) {
              const reducedCtx = Math.floor(currentCtx * 0.7);
              this.api.setRuntimeOption('num_ctx', reducedCtx);
              // Retry with reduced context - don't count this attempt
              continue;
            }
          }
          this.handleApiError(error);
          // BUG-H1: chat() is non-streaming; if the server got even one byte
          // it may have already done work. Only retry on transport errors.
          if (attempt <= this.maxRetries && this.isTransportError(error)) {
            await this.delay(this.retryDelaySeconds * attempt * 1000);
            continue;
          }
          throw error;
        }
      }
    } finally {
      progress.stop();
    }

    return { message: { role: 'assistant', content: '' }, prompt_eval_count: null, eval_count: null };
  }

  async chatStream(
    messages: IncomingChatMessage[],
    onChunk: (chunk: string) => void,
    onToolCall?: (tool: string, args: ToolCallArgs, id?: string) => void,
    tools?: ApiToolDef[],
    onReasoning?: (chunk: string) => void
  ): Promise<string> {
    const progress = this.startInferenceProgress();
    const apiMessages: ApiChatMessage[] = messages.map(m => {
      const msg: ApiChatMessage = {
        role: this.toApiRole(m.role),
        content: m.content,
      };
      if (m.tool_calls?.length) {
        msg.tool_calls = m.tool_calls.map(tc => ({
          id: String(tc.id || `call_${Date.now()}`),
          type: 'function' as const,
          function: {
            name: String(tc.function.name || ''),
            arguments: typeof tc.function.arguments === 'string'
              ? tc.function.arguments
              : JSON.stringify(tc.function.arguments || {}),
          }
        }));
      }
      if (m.tool_call_id) msg.tool_call_id = m.tool_call_id;
      return msg;
    });

    let accumulatedContent = '';
    // Track idle-driven continuations within a single turn so a permanently
    // stalled server eventually surfaces as an error instead of looping
    // forever. Each idle event prepends the partial assistant content + a
    // "Continue from where you stopped" nudge and restarts the inner stream.
    let idleContinuations = 0;
    // FIX-09: Scale idle limit based on model size/complexity
    const MAX_IDLE_CONTINUATIONS = this.getMaxIdleContinuations();
    const streamMessages: ApiChatMessage[] = [...apiMessages];
    try {
      for (let attempt = 1; attempt <= this.maxRetries + 1; attempt++) {
        try {
          let hasToolCalls = false;
          let modelReadyMarked = false;

          const markModelReady = (): void => {
            if (modelReadyMarked) return;
            modelReadyMarked = true;
            progress.markModelReady();
          };

          // Inner resume loop: replays the stream after an `idle` event with
          // the partial reply preserved + a continuation hint appended.
          // Breaks naturally on `done`, throws on `error`, exits on AbortError.
          // eslint-disable-next-line no-constant-condition
          while (true) {
            const generator = this.api.chatStreamGenerator(streamMessages, tools);
            let sawIdle = false;
            let idleReason = '';
            let contentBeforeIdle = '';

            for await (const event of generator) {
              switch (event.type) {
                case 'content':
                  markModelReady();
                  accumulatedContent += event.data;
                  contentBeforeIdle += event.data;
                  onChunk(event.data);
                  break;
                case 'reasoning':
                  markModelReady();
                  if (onReasoning) onReasoning(event.data);
                  break;
                case 'tool_call':
                  markModelReady();
                  hasToolCalls = true;
                  onToolCall?.(event.data.tool, event.data.arguments, event.data.id);
                  break;
                case 'error':
                  throw new Error(event.data);
                case 'idle':
                  sawIdle = true;
                  idleReason = event.data;
                  break;
                case 'done':
                  break;
              }
            }

            if (!sawIdle) break;
            if (idleContinuations >= MAX_IDLE_CONTINUATIONS) {
              // Bounded recovery: after N silent stalls the server is likely
              // truly stuck. Surface as a normal error so the upper layer
              // can show diagnostics.
              throw new Error(`stream idle: ${idleReason} (exceeded ${MAX_IDLE_CONTINUATIONS} continuations)`);
            }
            idleContinuations++;
            // BUG-M4: previously pushed a synthetic `user: "Continue."`
            // turn, which under llama.cpp's chat template closes the
            // assistant block and opens a fresh user turn — so the model
            // produced a NEW independent reply instead of continuing the
            // cut-off thought (the very symptom the resume was supposed to
            // fix). llama.cpp supports `continue_final_message: true` (see
            // .reference/llama.cpp/common/chat.h:171,
            // COMMON_CHAT_CONTINUATION_AUTO) which keeps the trailing
            // assistant message open and prefills from where it stopped.
            //
            // On llama-server: append only the partial assistant content
            // (no trailing user) — ApiClient.chatStreamGenerator forwards
            // `continue_final_message` via runtimeOptions when the body is
            // built (see runtimeOptionsToParams).
            // On Ollama: keep the legacy nudge — Ollama's template can't
            // continue a partial assistant turn.
            if (contentBeforeIdle) {
              streamMessages.push({ role: 'assistant', content: contentBeforeIdle });
            }
            const backendKind = this.backendInfo?.kind ?? 'unknown';
            if (backendKind === 'llama-server') {
              // One-shot — cleared by ApiClient after the next request.
              this.api.setOneShotBodyExtras({ continue_final_message: true });
            } else {
              streamMessages.push({
                role: 'user',
                content: 'Continue.'
              });
            }
            eventBus.emit(EventType.PROGRESS_UPDATE, {
              message: `Stream stalled — resuming (${idleContinuations}/${MAX_IDLE_CONTINUATIONS})`,
              intentType: 'general'
            });
            // Loop back into the while(true) — restart the stream with the
            // extended messages. modelReadyMarked stays true so we don't
            // re-fire load probes.
          }

          if (!hasToolCalls) {
            return accumulatedContent;
          }
          return accumulatedContent;
        } catch (error: unknown) {
          if (error instanceof Error && error.name === 'AbortError') {
            eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'Request timed out' });
            throw new OllamaTimeoutError(
              `Request timed out after ${this.requestTimeoutMs}ms. ` +
              `Increase OLLAMA_REQUEST_TIMEOUT_MS or use a faster model.`
            );
          }
          // FIX-06: On context exceeded, reduce context and retry with smaller window
          if (error instanceof ContextExceededError) {
            const currentCtx = this.api.getRuntimeOption('num_ctx');
            if (typeof currentCtx === 'number' && currentCtx > 4096) {
              const reducedCtx = Math.floor(currentCtx * 0.7);
              this.api.setRuntimeOption('num_ctx', reducedCtx);
              // Retry with reduced context - don't count this attempt
              continue;
            }
          }
          this.handleApiError(error);
          // BUG-H1: never retry the stream once we already received output
          // (the existing accumulatedContent guard); additionally, gate on
          // transport-level errors so a 4xx/5xx after headers doesn't get
          // duplicated.
          if (
            attempt <= this.maxRetries &&
            !accumulatedContent &&
            this.isTransportError(error)
          ) {
            await this.delay(this.retryDelaySeconds * attempt * 1000);
            continue;
          }
          if (!accumulatedContent) throw error;
          return accumulatedContent;
        }
      }

      return accumulatedContent;
    } finally {
      progress.stop();
    }
  }

  async embed(text: string): Promise<number[]> {
    try {
      const url = this.normalizeHost(String(config.ollama.host || 'http://127.0.0.1:11434')) + '/api/embed';
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: this.getActiveModel(), input: text }),
      });
      const json = await res.json() as EmbeddingsResponse;
      return json.embeddings?.[0] || [];
    } catch {
      return [];
    }
  }

  private handleApiError(error: unknown): void {
    const raw = this.getErrorMessage(error);
    const msg = raw.toLowerCase();
    // Context-exceeded is checked BEFORE the generic 400 fall-through so
    // we can extract the server's real n_ctx and surface a typed error
    // the tool loop knows how to recover from.
    if (msg.includes('exceed_context_size_error') || msg.includes('exceeds the available context size')) {
      const parsed = this.parseContextExceeded(raw);
      if (parsed) {
        this.noteServerContextLimit(parsed.nCtx);
        throw new ContextExceededError(
          `Backend context exceeded: prompt=${parsed.promptTokens ?? '?'} tokens, server n_ctx=${parsed.nCtx}.`,
          parsed.nCtx,
          parsed.promptTokens
        );
      }
    }
    if (msg.includes('fetch failed') || msg.includes('network') || msg.includes('econnrefused') || msg.includes('enotfound')) {
      eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'Ollama server offline' });
      throw new OfflineError('Ollama server offline. Check if ollama is running.');
    }
    if (msg.includes('not found') || msg.includes('404')) {
      throw new OllamaNotFoundError(`Model '${this.getActiveModel()}' not found. Pull it with: ollama pull ${this.getActiveModel()}`);
    }
    if (msg.includes('out of memory') || msg.includes('cuda') || msg.includes('cublas')) {
      throw new OllamaResourceError(`GPU out of memory. Try a smaller model or reduce num_ctx.`);
    }
  }

  /**
   * Extract `n_ctx` and `n_prompt_tokens` from the body of an
   * exceed_context_size_error response. The body is embedded in the
   * thrown Error's message (formatted by ApiClient as `API 400: <body>`).
   *
   * BUG-M1: previous regex matched the first `"n_ctx":NNN` anywhere in the
   * string, including inside a stringified `message` field embedding an
   * example. Parse the JSON envelope first and only fall back to regex
   * when JSON parsing fails. Even the regex fallback now prefers an
   * `error` object's `n_ctx` field over a raw match.
   */
  private parseContextExceeded(raw: string): { nCtx: number; promptTokens: number | null } | null {
    // `API 400: <body>` — peel the prefix.
    const bodyIdx = raw.indexOf('{');
    const body = bodyIdx >= 0 ? raw.slice(bodyIdx) : raw;
    // Try strict JSON parse first.
    try {
      const parsed = JSON.parse(body) as unknown;
      const candidates: any[] = [];
      const walk = (node: any): void => {
        if (!node || typeof node !== 'object') return;
        if (typeof node.n_ctx === 'number') candidates.push(node);
        for (const v of Object.values(node)) {
          if (v && typeof v === 'object') walk(v);
        }
      };
      walk(parsed);
      if (candidates.length > 0) {
        // Prefer the one with the smallest n_ctx (server's actual limit),
        // not any larger value that might appear in an example string.
        candidates.sort((a, b) => Number(a.n_ctx) - Number(b.n_ctx));
        const node = candidates[0];
        return {
          nCtx: Number(node.n_ctx),
          promptTokens: typeof node.n_prompt_tokens === 'number' ? Number(node.n_prompt_tokens) : null,
        };
      }
    } catch {
      // Not valid JSON — fall back to regex below.
    }
    const nCtxMatch = raw.match(/"n_ctx"\s*:\s*(\d+)/);
    if (!nCtxMatch) return null;
    const promptMatch = raw.match(/"n_prompt_tokens"\s*:\s*(\d+)/);
    return {
      nCtx: Number(nCtxMatch[1]),
      promptTokens: promptMatch ? Number(promptMatch[1]) : null,
    };
  }

  /**
   * BUG-H1: only transport-level errors (DNS, connection refused, abort
   * before any byte) are safe to auto-retry. Anything past the response
   * headers — including 4xx/5xx with a body, parsed JSON errors, or a
   * `ContextExceededError` — must NOT be retried because the server may
   * have already consumed tokens / executed tool calls.
   */
  private isTransportError(error: unknown): boolean {
    if (error instanceof ContextExceededError) return false;
    const msg = this.getErrorMessage(error).toLowerCase();
    if (msg.startsWith('api ')) return false; // API 4xx/5xx with body
    if (msg.includes('stream parse error')) return false;
    if (msg.includes('truncated')) return false;
    return (
      msg.includes('fetch failed') ||
      msg.includes('network') ||
      msg.includes('econnrefused') ||
      msg.includes('econnreset') ||
      msg.includes('enotfound') ||
      msg.includes('eai_again') ||
      msg.includes('socket hang up') ||
      msg.includes('aborterror')
    );
  }

  // FIX-04: Track current context limit
  private updateCurrentContextLimit(limit: number): void {
    this.currentContextLimit = limit;
  }

  // FIX-04: Implement adaptive context to proactively increase context window
  // Note: getEffectiveContextLimit is async, so we use config values directly here
  private maybeIncreaseContext(_requiredTokens: number): void {
    if (!this.adaptiveContextEnabled) return;
    if (typeof _requiredTokens !== 'number' || _requiredTokens <= 0) return;

    // Use configured max context as the limit (synchronous approach)
    const effectiveLimit = this.maxContext;
    // If we're using >80% of context and have room to increase, do so
    if (_requiredTokens > effectiveLimit * 0.8 && effectiveLimit < this.maxContext) {
      const newCtx = Math.min(effectiveLimit + 4096, this.maxContext);
      this.api.setRuntimeOption('num_ctx', newCtx);
      this.updateCurrentContextLimit(newCtx);
    }
  }

  private maybeIncreaseContextForPrompt(_prompt: string, _system?: string): void {
    if (!this.adaptiveContextEnabled) return;
    // Estimate prompt tokens and check if we need more context
    const estimated = Math.ceil((_prompt.length + (_system?.length || 0)) / 4);
    this.maybeIncreaseContext(estimated);
  }

  private maybeIncreaseContextForMessages(_messages: Array<{ role: string; content: string | ApiContentPart[] }>): void {
    if (!this.adaptiveContextEnabled) return;

    try {
      let total = 0;
      for (const msg of _messages) {
        const msgContent = typeof msg.content === 'string'
          ? msg.content
          : (msg.content as ApiContentPart[]).map(p => p.text || '').join('');
        total += Math.ceil(msgContent.length / 4);
      }
      // Add overhead for ChatML formatting (~6 tokens per message)
      total += _messages.length * 6;

      this.maybeIncreaseContext(total);
    } catch {
      // Best-effort: don't block inference on estimation failure
    }
  }

  // FIX-09: Calculate adaptive idle continuation limit based on model size
  private getMaxIdleContinuations(): number {
    const model = this.getActiveModel().toLowerCase();
    if (model.includes('70b') || model.includes('90b') || model.includes('llama-3.3')) return 8;
    if (model.includes('30b') || model.includes('32b') || model.includes('14b')) return 6;
    if (model.includes('8b') || model.includes('7b')) return 4;
    return 3; // Default for smaller models
  }

  private normalizeHost(host: string): string {
    let h = String(host || '').trim();
    if (!h) return 'http://127.0.0.1:11434';
    if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://' + h;
    return h.replace(/\/+$/, '');
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  private toApiRole(role: string): ApiChatMessage['role'] {
    if (role === 'system' || role === 'user' || role === 'assistant' || role === 'tool') {
      return role;
    }
    return 'user';
  }

  private getErrorMessage(error: unknown): string {
    if (error instanceof Error) return error.message;
    return String(error ?? '');
  }

  private startInferenceProgress(): InferenceProgressHandle {
    const model = this.getActiveModel();
    let backendKind: BackendKind = 'unknown';
    let elapsed = 0;
    let modelReady = false;
    let stopped = false;
    let timer: ReturnType<typeof setInterval> | null = null;

    const emit = (message: string): void => {
      if (stopped) return;
      eventBus.emit(EventType.PROGRESS_UPDATE, {
        message,
        intentType: 'general',
      });
    };

    emit(`Thinking (${model})`);

    void this.getBackendInfo()
      .then((info) => {
        if (stopped) return;
        backendKind = info.kind;
        if (backendKind === 'llama-server' && !modelReady) {
          emit(`Carregando modelo no llama.cpp (${model})`);
        }
      })
      .catch(() => {
        // No-op: progress degrades to generic "Thinking".
      });

    if (typeof setInterval !== 'undefined') {
      timer = setInterval(() => {
        elapsed += 5;
        if (backendKind === 'llama-server') {
          if (!modelReady) {
            emit(`Carregando modelo no llama.cpp (${model}) ${elapsed}s`);
            return;
          }
          emit(`Inferindo com llama.cpp (${model}) ${elapsed}s`);
          return;
        }
        emit(`Thinking (${model}) ${elapsed}s`);
      }, 5000);
    }

    return {
      stop: () => {
        if (stopped) return;
        stopped = true;
        if (timer) clearInterval(timer);
      },
      markModelReady: () => {
        if (stopped || modelReady) return;
        modelReady = true;
        if (backendKind === 'llama-server') {
          emit(`Inferindo com llama.cpp (${model})`);
        }
      }
    };
  }
}
