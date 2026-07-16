import { config } from './config.js';
import { eventBus, EventType } from './tui/event-bus.js';
import { lookup as dnsLookup } from 'dns';
import { promisify } from 'util';
import { createChatParser } from './chat/index.js';

const dnsLookupAsync = promisify(dnsLookup);

export interface ApiChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | ApiContentPart[];
  tool_calls?: ApiToolCall[];
  tool_call_id?: string;
}

export interface ApiContentPart {
  type: 'text' | 'image_url';
  text?: string;
  image_url?: { url: string; detail?: string };
}

export interface ApiToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string;
  };
}

export interface ApiToolDef {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters?: Record<string, unknown>;
  };
}

export interface ApiChatResponse {
  message: {
    role: 'assistant';
    content: string;
    tool_calls?: ApiToolCall[];
  };
  prompt_eval_count: number | null;
  eval_count: number | null;
}

interface OpenAIToolCallDelta {
  id?: string;
  index?: number;
  function?: {
    name?: string;
    arguments?: string;
  };
}

export interface StreamToolCallData {
  tool: string;
  arguments: Record<string, unknown> | string;
  id?: string;
}

interface RuntimeOptions {
  temperature?: number;
  top_p?: number;
  top_k?: number;
  presence_penalty?: number;
  frequency_penalty?: number;
  repeat_penalty?: number;
  min_p?: number;
  num_predict?: number;
  num_ctx?: number;
  num_gpu?: number;
  num_batch?: number;
  stop?: string | string[];
  seed?: number;
}

interface UsageMetrics {
  prompt_tokens?: number | null;
  completion_tokens?: number | null;
  prompt_eval_duration?: number | null;
  eval_duration?: number | null;
}

interface OpenAICompatToolCall {
  id?: string;
  type?: 'function';
  function?: {
    name?: string;
    arguments?: unknown;
  };
}

interface OpenAICompatChoice {
  message?: {
    content?: string;
    tool_calls?: OpenAICompatToolCall[];
  };
  delta?: {
    content?: string;
    reasoning_content?: string;
    tool_calls?: OpenAIToolCallDelta[];
  };
  finish_reason?: string | null;
}

interface OpenAICompatResponse {
  choices?: OpenAICompatChoice[];
  usage?: UsageMetrics;
}

interface NativeToolCall {
  id?: string;
  name?: string;
  function?: {
    name?: string;
    arguments?: unknown;
  };
  arguments?: unknown;
}

interface NativeMessagePayload {
  content?: unknown;
  reasoning?: unknown;
  thinking?: unknown;
  tool_calls?: NativeToolCall[];
}

interface NativeOllamaResponse {
  message?: NativeMessagePayload;
  response?: unknown;
  reasoning?: unknown;
  done?: boolean;
  prompt_eval_count?: number;
  prompt_eval_duration?: number;
  eval_count?: number;
  eval_duration?: number;
  total_duration?: number;
  load_duration?: number;
}

type SerializedContentPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url?: { url: string; detail?: string } };

interface SerializedApiMessage {
  role: ApiChatMessage['role'];
  content?: string | SerializedContentPart[];
  tool_calls?: ApiToolCall[];
  tool_call_id?: string;
}

interface NativeSerializedToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: unknown;
  };
}

interface NativeSerializedMessage {
  role: ApiChatMessage['role'];
  content: string;
  tool_calls?: NativeSerializedToolCall[];
  tool_call_id?: string;
}

export type StreamEvent =
  | { type: 'content'; data: string }
  | { type: 'reasoning'; data: string }
  | { type: 'tool_call'; data: StreamToolCallData }
  | { type: 'error'; data: string }
  // Stream went idle (no bytes for PHENOM_STREAM_IDLE_TIMEOUT_MS). Caller
  // should resume the model with the partial content + a continuation hint
  // instead of surfacing an error. The data carries the reason for logs.
  | { type: 'idle'; data: string }
  | { type: 'done'; data: null };

export class ApiClient {
  private baseUrl: string;
  private apiKey: string;
  private activeModel: string;
  private timeoutMs: number;
  private runtimeOptions: RuntimeOptions;
  /**
   * llama.cpp prompt-prefix cache control. Sent on the `/v1/chat/completions`
   * body so the server reuses the KV of the longest matching prefix instead
   * of re-evaluating the whole prompt every request. llama.cpp defaults this
   * to true, but we send it explicitly so a server (or proxy) that flipped
   * the default off still gets prefix reuse. Disable via PHENOM_CACHE_PROMPT=0.
   */
  private readonly cachePrompt: boolean;
  /**
   * Optional llama.cpp slot to pin requests to (PHENOM_LLAMA_SLOT). On a
   * server launched with `--parallel N`, pinning the CLI to one slot keeps
   * its KV from being evicted by other clients (e.g. the web UI) that land
   * on a different slot. Unset (null) = let the server pick; required when
   * total_slots == 1 since there's nothing to isolate.
   */
  private serverPropsCache: Record<string, unknown> | null = null;
  private slotId: number | null;
  /**
   * Ollama's `think` parameter. null/undefined omits the field entirely
   * (compatible with older Ollama versions and non-thinking models). The Agent
   * sets this based on model capability + OLLAMA_THINK env.
   */
  private thinkValue: boolean | string | null = null;

  /**
   * Delay before assuming the request is blocked on model load and starting
   * the /health poller. Short enough that the user sees progress quickly on a
   * cold model, long enough not to fire for normal cached requests.
   */
  private static readonly LOAD_PROBE_DELAY_MS = 1500;
  private static readonly LOAD_PROBE_INTERVAL_MS = 1000;

  /**
   * Process-wide circuit breaker: after 3 consecutive 404s on /health we
   * conclude this baseUrl is Ollama (which has no /health route) and stop
   * probing entirely for the rest of the process. Saves one round-trip per
   * second on every slow Ollama chat. Resets to 0 on any non-404 response —
   * if the backend was llama-server but transiently flapped, we'll re-enable.
   */
  private static healthProbeConsecutive404 = 0;
  private static healthProbeDisabled = false;
  private static readonly HEALTH_PROBE_404_THRESHOLD = 3;

  /**
   * BUG-H5: Cached backend kind so the SYNC `shouldFallbackToNative` gate
   * can avoid routing to `/api/chat` when the backend is llama-server (which
   * doesn't expose that route). Populated by OllamaClient after async
   * detection. `'unknown'` keeps the old conservative behavior.
   */
  private static cachedBackendKind: 'llama-server' | 'ollama' | 'unknown' = 'unknown';
  static setCachedBackendKind(kind: 'llama-server' | 'ollama' | 'unknown'): void {
    ApiClient.cachedBackendKind = kind;
    // BUG-M3: a freshly-detected llama-server invalidates the "Ollama signal"
    // that previously disabled /health probing. Without this, switching
    // OLLAMA_HOST from Ollama to llama-server mid-process leaves the load
    // probe permanently off.
    if (kind === 'llama-server') {
      ApiClient.healthProbeDisabled = false;
      ApiClient.healthProbeConsecutive404 = 0;
    }
  }

  /**
   * Whether the configured baseUrl supports llama-server's POST /tokenize
   * (returns `{tokens: [...]}` for a given content string). Cached per-process
   * so we don't probe on every request. `null` = not yet probed; `true` =
   * available; `false` = not available (Ollama or older llama.cpp).
   *
   * Used to display the REAL prompt token count during the prompt-eval
   * phase. Without /tokenize we fall back to chars/3 estimate.
   *
   * Reference: llama.cpp server-context.cpp:4209-4246 `POST /tokenize`.
   */
  private static tokenizeSupported: boolean | null = null;

  /**
   * Tracks every in-flight HTTP request issued via fetchWithTimeout so
   * INFERENCE_CANCEL (Esc / Ctrl-C) can actually stop the model — the cancel
   * event used to update only the UI label while the underlying fetch kept
   * draining tokens server-side. We hold a Set because chat + tool calls +
   * streams can overlap; on cancel we abort them all.
   */
  private static inflightControllers = new Set<AbortController>();
  private static cancelSubscribed = false;

  static cancelInflight(): void {
    if (ApiClient.inflightControllers.size === 0) return;
    for (const c of ApiClient.inflightControllers) {
      try { c.abort(); } catch { /* already aborted or torn down */ }
    }
    ApiClient.inflightControllers.clear();
  }

  constructor() {
    this.baseUrl = this.normalizeHost(String(config.ollama.host || 'http://127.0.0.1:11434'));
    this.apiKey = process.env.OPENAI_API_KEY || '';
    this.activeModel = this.resolveModelName();
    this.timeoutMs = Number.parseInt(String(config.ollama.requestTimeoutMs || '180000'), 10);
    this.runtimeOptions = { ...config.ollama.options };
    this.cachePrompt = process.env.PHENOM_CACHE_PROMPT !== '0';
    const slotRaw = Number.parseInt(String(process.env.PHENOM_LLAMA_SLOT ?? ''), 10);
    this.slotId = Number.isFinite(slotRaw) && slotRaw >= 0 ? slotRaw : null;


    // FIX-02: When total_slots == 1, force pinning to slot 0 even if not specified.
    // A single-slot server has no other choice, and explicit pinning avoids
    // the server picking a different slot each time.
    if (this.slotId === null) {
      this.resolveServerProps().then(props => {
        const totalSlots = props?.total_slots as number | undefined;
        if (totalSlots === 1) {
          this.slotId = 0;
        }
      }).catch(() => { /* Best-effort: don't block on slot detection */ });
    }
    // Subscribe ONCE per process. INFERENCE_CANCEL → abort every in-flight
    // request so Esc / Ctrl-C truly stops the model instead of letting the
    // server finish its generation in the background.
    if (!ApiClient.cancelSubscribed) {
      ApiClient.cancelSubscribed = true;
      eventBus.on(EventType.INFERENCE_CANCEL, () => { ApiClient.cancelInflight(); });
    }
  }

  setActiveModel(model: string): void {
    const next = String(model || '').trim();
    if (!next) return;
    this.activeModel = next;
  }

  // FIX-06: Allow runtime option access for adaptive context adjustments
  getRuntimeOption(key: keyof RuntimeOptions): number | undefined {
    const value = this.runtimeOptions[key];
    return typeof value === 'number' ? value : undefined;
  }

  setRuntimeOption(key: keyof RuntimeOptions, value: number): void {
    if (key === 'num_ctx' || key === 'num_gpu' || key === 'num_batch' || key === 'num_predict') {
      (this.runtimeOptions as any)[key] = value;
    }
  }

  /**
   * BUG-M4: one-shot body extras consumed and cleared on the next
   * chat()/chatStreamGenerator call. Used to inject llama.cpp-specific
   * flags like `continue_final_message: true` for stream resume without
   * leaking into subsequent turns.
   */
  private oneShotBodyExtras: Record<string, unknown> | null = null;
  setOneShotBodyExtras(extras: Record<string, unknown> | null): void {
    this.oneShotBodyExtras = extras;
  }
  private consumeOneShotBodyExtras(): Record<string, unknown> {
    const v = this.oneShotBodyExtras;
    this.oneShotBodyExtras = null;
    return v ?? {};
  }

  getActiveModel(): string {
    return this.activeModel;
  }

  private resolveModelName(): string {
    return String(
      this.activeModel ||
      config.ollama.coderModel ||
      config.ollama.chatModel ||
      config.ollama.model ||
      ''
    ).trim();
  }

  private requireModelName(): string {
    const model = this.resolveModelName();
    if (!model) {
      throw new Error(
        'Modelo não configurado. Defina OLLAMA_MODEL ou OLLAMA_CODER_MODEL ou OLLAMA_CHAT_MODEL.'
      );
    }
    this.activeModel = model;
    return model;
  }

  /** Set the `think` field sent in chat requests. null = omit. */
  setThink(value: boolean | string | null): void {
    this.thinkValue = value;
  }

  /**
   * Apply the configured `thinkValue` to an outgoing request body using the
   * convention the backend actually understands.
   *
   * - Ollama: top-level `think: true|false|"low"|"medium"|"high"`. Ollama
   *   /api/chat and the OpenAI-compat /v1/chat/completions proxy both honor
   *   this field; it gates whether `message.reasoning` (native) or
   *   `delta.reasoning_content` (compat) is populated.
   * - llama-server: no native `/api/chat`; use OpenAI-compatible `/v1` and
   *   forward `chat_template_kwargs.enable_thinking` for templates that honor
   *   it. Without server reasoning extraction, thinking arrives inline and is
   *   split from `delta.content` by the stream parser.
   * - unknown backend: send `think` for backward compatibility (the field is
   *   harmless on llama-server — it is ignored — and required on Ollama).
   */
  private applyThinkToBody(body: Record<string, unknown>, route: 'oai' | 'native'): void {
    if (this.thinkValue === null) return;
    const kind = ApiClient.cachedBackendKind;
    const isThinkingOn = this.thinkValue === true ||
      (typeof this.thinkValue === 'string' && this.thinkValue !== 'false' && this.thinkValue !== '0' && this.thinkValue !== 'no');
    if (kind === 'llama-server') {
      // No /api/chat on llama-server, so route is always 'oai' here in
      // practice. Forward as chat_template_kwargs so Jinja templates that
      // declare an `enable_thinking` kwarg flip with the user's preference.
      const existing = (body.chat_template_kwargs as Record<string, unknown> | undefined) ?? {};
      body.chat_template_kwargs = { ...existing, enable_thinking: isThinkingOn };
      return;
    }
    if (kind === 'ollama') {
      body.think = this.thinkValue;
      return;
    }
    // unknown — both routes accept top-level `think`; harmless on llama-server.
    body.think = this.thinkValue;
    if (route === 'oai') {
      const existing = (body.chat_template_kwargs as Record<string, unknown> | undefined) ?? {};
      body.chat_template_kwargs = { ...existing, enable_thinking: isThinkingOn };
    }
  }

  async chat(
    messages: ApiChatMessage[],
    tools?: ApiToolDef[]
  ): Promise<ApiChatResponse> {
    if (ApiClient.cachedBackendKind === 'ollama') {
      return this.chatNativeOllama(messages, tools);
    }

    const model = this.requireModelName();
    const url = this.apiUrl('/v1/chat/completions');
    const body: Record<string, unknown> = {
      model,
      messages: this.serializeMessages(messages),
      stream: false,
      ...this.runtimeOptionsToParams(),
    };
    if (tools && tools.length > 0) {
      body.tools = tools;
      body.tool_choice = 'auto';
    }
    this.applyThinkToBody(body, 'oai');

    // Emit chars/3 estimate immediately; do not block this non-streaming
    // chat on a /tokenize roundtrip. (Same rationale as chatStreamGenerator
    // above — see the longer comment there.)
    const estimatedInputTokens = Math.ceil(this.estimateChars(messages) / 3);
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: estimatedInputTokens,
      output: 0,
      total: estimatedInputTokens,
      exact: false,
      tokensPerSecond: null,
    });
    void this.tokenizeRequest(messages).then((exact) => {
      if (typeof exact === 'number' && Number.isFinite(exact) && exact >= 0) {
        eventBus.emit(EventType.TOKEN_UPDATE, {
          input: exact,
          output: 0,
          total: exact,
          exact: true,
          tokensPerSecond: null,
        });
      }
    }).catch(() => { /* best-effort UI refinement only */ });

    const loadProbe = this.startLoadProbe();
    let res: Response;
    try {
      res = await this.fetchWithTimeout(url, body);
    } finally {
      loadProbe.stop();
    }
    let json: OpenAICompatResponse;

    if (!res.ok) {
      const text = await res.text().catch(() => 'unknown');
      if (this.shouldFallbackToNative(res.status, text)) {
        const nativeUrl = this.apiUrl('/api/chat');
        const nativeProbe = this.startLoadProbe();
        let nativeRes: Response;
        try {
          nativeRes = await this.fetchWithTimeout(nativeUrl, this.nativeChatBody(messages, tools, false));
        } finally {
          nativeProbe.stop();
        }
        if (!nativeRes.ok) {
          const nativeText = await nativeRes.text().catch(() => 'unknown');
          throw new Error(`API ${nativeRes.status}: ${nativeText}`);
        }
        const nativeJson = await nativeRes.json();
        json = this.nativeToOpenAICompat(nativeJson);
      } else {
        throw new Error(`API ${res.status}: ${text}`);
      }
    } else {
      json = this.asOpenAICompatResponse(await res.json());
    }

    const outputContent = json.choices?.[0]?.message?.content || '';
    const usage = json.usage || {};
    const inputTokens = this.coalesceMetric(usage.prompt_tokens, estimatedInputTokens);
    const outputTokens = await this.resolveOutputTokenCount(outputContent, usage.completion_tokens);
    const tokensPerSecond = this.calculateTokensPerSecond({
      tokens: outputTokens.count,
      durationNs: usage.eval_duration ?? null,
      startedAtMs: null,
      endedAtMs: Date.now()
    });
    // Surface llama.cpp prompt cache hits when present (Anthropic-compat
    // ports them through too): the user gets to see when a warm-cache
    // request is essentially free.
    const cachedTokens = (usage as any)?.prompt_tokens_details?.cached_tokens ?? null;
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: inputTokens,
      output: outputTokens.count,
      total: inputTokens + outputTokens.count,
      exact: typeof usage.prompt_tokens === 'number' && outputTokens.exact,
      cached: typeof cachedTokens === 'number' ? cachedTokens : undefined,
      tokensPerSecond,
    });

    return this.toOllamaChatResponse(json);
  }

  private async chatNativeOllama(
    messages: ApiChatMessage[],
    tools?: ApiToolDef[]
  ): Promise<ApiChatResponse> {
    const estimatedInputTokens = Math.ceil(this.estimateChars(messages) / 3);
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: estimatedInputTokens,
      output: 0,
      total: estimatedInputTokens,
      exact: false,
      tokensPerSecond: null,
    });

    const url = this.apiUrl('/api/chat');
    const loadProbe = this.startLoadProbe();
    let res: Response;
    try {
      res = await this.fetchWithTimeout(url, this.nativeChatBody(messages, tools, false));
    } finally {
      loadProbe.stop();
    }
    if (!res.ok) {
      const text = await res.text().catch(() => 'unknown');
      throw new Error(`API ${res.status}: ${text}`);
    }

    const native = this.asNativeOllamaResponse(await res.json());
    const response = this.nativeToOllamaChatResponse(native);
    const outputContent = response.message.content || '';
    const inputTokens = this.coalesceMetric(response.prompt_eval_count, estimatedInputTokens);
    const outputTokens = await this.resolveOutputTokenCount(outputContent, response.eval_count);
    const tokensPerSecond = this.calculateTokensPerSecond({
      tokens: outputTokens.count,
      durationNs: native.eval_duration ?? null,
      startedAtMs: null,
      endedAtMs: Date.now()
    });
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: inputTokens,
      output: outputTokens.count,
      total: inputTokens + outputTokens.count,
      exact: typeof response.prompt_eval_count === 'number' && outputTokens.exact,
      tokensPerSecond,
    });
    return response;
  }

  async *chatStreamGenerator(
    messages: ApiChatMessage[],
    tools?: ApiToolDef[]
  ): AsyncGenerator<StreamEvent> {
    const strictToolStream = process.env.PHENOM_STRICT_TOOL_STREAM !== '0';
    const looksJsonish = (raw: string): boolean => /^[\s]*[\[{]/.test(String(raw || ''));
    const model = this.requireModelName();
    const route = ApiClient.cachedBackendKind === 'ollama' ? 'native' : 'oai';
    const url = route === 'native'
      ? this.apiUrl('/api/chat')
      : this.apiUrl('/v1/chat/completions');
    const body = route === 'native'
      ? this.nativeChatBody(messages, tools, true)
      : this.openAIChatBody(messages, tools, true);

    // Emit the chars/3 estimate IMMEDIATELY so the UI has something to
    // show, then kick the real /tokenize off in the background — do NOT
    // block the chat request on it. Previously this was awaited in series
    // (up to 3s timeout per turn), adding 100ms-3s of pure latency before
    // the slot could even start prefilling. /tokenize is a UI-only refinement;
    // the server already tokenizes the prompt as part of normal request
    // handling and reports the final count via `usage.prompt_tokens`.
    const estimatedInputTokens = Math.ceil(this.estimateChars(messages) / 3);
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: estimatedInputTokens,
      output: 0,
      total: estimatedInputTokens,
      exact: false,
      tokensPerSecond: null,
    });
    // Background refinement — when the exact count arrives, emit it so the
    // UI flips from estimate to real. Errors are silenced (the estimate is
    // already on screen, nothing to recover).
    void this.tokenizeRequest(messages).then((exact) => {
      if (typeof exact === 'number' && Number.isFinite(exact) && exact >= 0) {
        eventBus.emit(EventType.TOKEN_UPDATE, {
          input: exact,
          output: 0,
          total: exact,
          exact: true,
          tokensPerSecond: null,
        });
      }
    }).catch(() => { /* best-effort UI refinement only */ });

    const loadProbe = this.startLoadProbe();
    let res: Response;
    let controller: AbortController;
    let releaseController: () => void;
    try {
      const got = await this.fetchStreamWithController(url, body);
      res = got.response;
      controller = got.controller;
      releaseController = got.release;
    } catch (e) {
      loadProbe.stop();
      throw e;
    }
    if (!res.ok) {
      const text = await res.text().catch(() => 'unknown');
      if (this.shouldFallbackToNative(res.status, text)) {
        releaseController();
        const nativeUrl = this.apiUrl('/api/chat');
        try {
        const got = await this.fetchStreamWithController(nativeUrl, this.nativeChatBody(messages, tools, true));
          res = got.response;
          controller = got.controller;
          releaseController = got.release;
        } catch (e) {
          loadProbe.stop();
          throw e;
        }
        if (!res.ok) {
          loadProbe.stop();
          releaseController();
          const nativeText = await res.text().catch(() => 'unknown');
          yield { type: 'error', data: `API ${res.status}: ${nativeText}` };
          return;
        }
      } else {
        loadProbe.stop();
        releaseController();
        yield { type: 'error', data: `API ${res.status}: ${text}` };
        return;
      }
    }

    const reader = res.body?.getReader();
    if (!reader) {
      loadProbe.stop();
      releaseController();
      yield { type: 'error', data: 'No response body' };
      return;
    }

    // Two-phase stream watchdog:
    //   - PREFILL phase (before first byte): tolerate long silence (default
    //     10 min, configurable via PHENOM_STREAM_PREFILL_TIMEOUT_MS). Prompt
    //     evaluation on a cold/contended slot legitimately produces zero
    //     bytes for tens of seconds. The previous single-phase timer armed
    //     immediately and treated this as "idle", which aborted mid-prefill
    //     and triggered ollama-client's continuation retry → another full
    //     prefill → cascade ("3x prefill before inference" symptom).
    //   - IDLE phase (after first byte): tighter ceiling (default 90s) for
    //     real stream stalls. Rearmed on each chunk so a steadily-emitting
    //     model never trips it.
    const prefillMs = Number.parseInt(process.env.PHENOM_STREAM_PREFILL_TIMEOUT_MS || '600000', 10);
    const idleMs = Number.parseInt(process.env.PHENOM_STREAM_IDLE_TIMEOUT_MS || '90000', 10);
    let idleTimedOut = false;
    let idleTimer: NodeJS.Timeout | null = null;
    const armPrefill = (): void => {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        idleTimedOut = true;
        try { controller.abort(); } catch {}
      }, prefillMs);
    };
    const armIdle = (): void => {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        idleTimedOut = true;
        try { controller.abort(); } catch {}
      }, idleMs);
    };
    armPrefill();

    const decoder = new TextDecoder();
    let buffer = '';
    let activeCalls: Record<number, ApiToolCall> = {};
    let outputChars = 0;
    let outputText = '';
    let firstByteSeen = false;
    let firstOutputAtMs: number | null = null;
    let lastUsage: UsageMetrics | null = null;
    // Re-use the same chars/3 estimate we announced at request open. The
    // background /tokenize refinement may upgrade this asynchronously via
    // its own TOKEN_UPDATE; the stream's per-chunk updates intentionally
    // stay on the estimate so they don't fight the background path.
    let emittedOutputTokens = 0;
    let doneEmitted = false;
    let malformedToolPayloads = 0;

    const inlineParser = createChatParser(model);
    let inlineParserFinished = false;
    function* drainParserDelta(text?: string, finish: boolean = false): Generator<StreamEvent> {
      const delta = finish ? inlineParser.finish() : inlineParser.addChunk(String(text || ''));
      if (finish) inlineParserFinished = true;
      if (delta.reasoning) yield { type: 'reasoning', data: delta.reasoning };
      if (delta.content) yield { type: 'content', data: delta.content };
      for (const tc of delta.toolCalls) {
        yield { type: 'tool_call', data: { tool: tc.name, arguments: tc.arguments, id: tc.id } };
      }
    }


    while (true) {
      let readResult: { done: boolean; value?: Uint8Array };
      try {
        readResult = await reader.read();
      } catch (e: any) {
        if (idleTimer) clearTimeout(idleTimer);
        loadProbe.stop();
        releaseController();
        if (idleTimedOut) {
          // Recoverable: signal the consumer to resume with a continuation
          // prompt instead of surfacing this as an error to the user.
          yield {
            type: 'idle',
            data: `stream idle timeout (no bytes for ${Math.round(idleMs / 1000)}s)`
          };
          return;
        }
        // True abort (user pressed Esc / INFERENCE_CANCEL) or transport error.
        const reason = e?.name === 'AbortError' ? 'request aborted' : String(e?.message || e);
        yield { type: 'error', data: reason };
        return;
      }
      if (readResult.done) break;
      armIdle(); // rearm: we got bytes, the stream is alive
      if (!firstByteSeen) {
        firstByteSeen = true;
        loadProbe.stop();
      }
      buffer += decoder.decode(readResult.value, { stream: true });

      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        if (trimmed.startsWith(':')) continue;

        let payload = trimmed;
        if (payload.startsWith('data:')) {
          payload = payload.slice(5).trim();
        }
        if (!payload) continue;

        if (payload === '[DONE]') {
          if (!doneEmitted) {
            doneEmitted = true;
            yield { type: 'done', data: null };
          }
          continue;
        }

        try {
          const parsed = JSON.parse(payload) as unknown;

          // BUG-B1: llama.cpp can emit `data: {"error":{...}}` AFTER the
          // connection upgraded to SSE (format_oai_sse(error) — see
          // .reference/llama.cpp/tools/server/server-context.cpp:3599). The
          // previous parser only looked at `choices[0]` / `nativeParsed.message`
          // and silently dropped this case, so a real mid-stream error became
          // an empty assistant reply with `done`. Detect it explicitly so the
          // upper layer can react (compact + retry for context-exceeded,
          // surface for everything else).
          if (parsed && typeof parsed === 'object' && (parsed as any).error) {
            const errObj = (parsed as any).error;
            const errMsg = typeof errObj === 'string'
              ? errObj
              : (errObj?.message || JSON.stringify(errObj));
            const lower = String(errMsg || '').toLowerCase();
            // Re-route exceed_context_size into the existing 400-path so
            // OllamaClient.handleApiError can throw ContextExceededError.
            if (lower.includes('exceed_context_size') || lower.includes('exceeds the available context')) {
              yield { type: 'error', data: `API 400: ${errMsg}` };
            } else {
              yield { type: 'error', data: String(errMsg || 'stream error') };
            }
            return;
          }

          const openAI = this.asOpenAICompatResponse(parsed);

          // OpenAI-compatible SSE (Ollama /v1/chat/completions)
          if (openAI.choices?.[0]) {
            const delta = openAI.choices[0]?.delta || {};
            const finish = openAI.choices[0]?.finish_reason;
            // BUG-H6: llama.cpp's OAI proxy strips the native `truncated`
            // flag, but maps cut-off output to `finish_reason: "length"`
            // (server-task.cpp:1862). Surface truncation so the upper layer
            // can decide whether to grow num_predict or compact — previously
            // we treated truncated replies as normal completions.
            if (finish === 'length') {
              yield { type: 'error', data: 'response truncated (finish_reason=length): output cut by num_predict or context limit' };
            }

            if (delta.content) {
              if (firstOutputAtMs === null) firstOutputAtMs = Date.now();
              outputChars += delta.content.length;
              outputText += delta.content;
              const estOutputTokens = Math.ceil(outputChars / 3);
              if (estOutputTokens !== emittedOutputTokens) {
                emittedOutputTokens = estOutputTokens;
                const tokensPerSecond = this.calculateTokensPerSecond({
                  tokens: estOutputTokens,
                  durationNs: null,
                  startedAtMs: firstOutputAtMs,
                  endedAtMs: Date.now()
                });
                eventBus.emit(EventType.TOKEN_UPDATE, {
                  input: estimatedInputTokens,
                  output: estOutputTokens,
                  total: estimatedInputTokens + estOutputTokens,
                  tokensPerSecond,
                });
              }
              yield* drainParserDelta(delta.content);
            }
            if (delta.reasoning_content) {
              if (firstOutputAtMs === null) firstOutputAtMs = Date.now();
              outputChars += delta.reasoning_content.length;
              outputText += delta.reasoning_content;
              const estOutputTokens = Math.ceil(outputChars / 3);
              if (estOutputTokens !== emittedOutputTokens) {
                emittedOutputTokens = estOutputTokens;
                const tokensPerSecond = this.calculateTokensPerSecond({
                  tokens: estOutputTokens,
                  durationNs: null,
                  startedAtMs: firstOutputAtMs,
                  endedAtMs: Date.now()
                });
                eventBus.emit(EventType.TOKEN_UPDATE, {
                  input: estimatedInputTokens,
                  output: estOutputTokens,
                  total: estimatedInputTokens + estOutputTokens,
                  tokensPerSecond,
                });
              }
              yield { type: 'reasoning', data: delta.reasoning_content };
            }
            if (delta.tool_calls) {
              this.accumulateToolCalls(delta.tool_calls, activeCalls);
            }
            // Flush accumulated tool calls on ANY finish reason.
            // Some Ollama models emit finish_reason:'stop' instead of 'tool_calls'.
            // Flush before yielding done so tool_calls always precede done in the stream.
            if (finish) {
              if (!inlineParserFinished) yield* drainParserDelta('', true);
              for (const tc of Object.values(activeCalls)) {
                try {
                  const args = JSON.parse(tc.function.arguments);
                  yield { type: 'tool_call', data: { tool: tc.function.name, arguments: args, id: tc.id } };
                } catch {
                  if (strictToolStream && looksJsonish(tc.function.arguments)) {
                    const snippet = String(tc.function.arguments || '').slice(0, 240).replace(/\s+/g, ' ');
                    yield { type: 'error', data: `stream parse error in tool arguments: ${snippet}` };
                    return;
                  }
                  yield { type: 'tool_call', data: { tool: tc.function.name, arguments: tc.function.arguments, id: tc.id } };
                }
              }
              activeCalls = {};
            }
            if (finish && !doneEmitted) {
              doneEmitted = true;
              yield { type: 'done', data: null };
            }

            const usage = openAI.usage;
            if (usage) {
              lastUsage = usage;
            }
            continue;
          }

          // Native Ollama stream (NDJSON via /api/chat or /api/generate)
          const nativeParsed = this.asNativeOllamaResponse(parsed);
          const ollamaContent = String(nativeParsed.message?.content ?? nativeParsed.response ?? '');
          if (ollamaContent) {
            if (firstOutputAtMs === null) firstOutputAtMs = Date.now();
            outputChars += ollamaContent.length;
            outputText += ollamaContent;
            const estOutputTokens = Math.ceil(outputChars / 3);
            if (estOutputTokens !== emittedOutputTokens) {
              emittedOutputTokens = estOutputTokens;
              const tokensPerSecond = this.calculateTokensPerSecond({
                tokens: estOutputTokens,
                durationNs: null,
                startedAtMs: firstOutputAtMs,
                endedAtMs: Date.now()
              });
              eventBus.emit(EventType.TOKEN_UPDATE, {
                input: estimatedInputTokens,
                output: estOutputTokens,
                total: estimatedInputTokens + estOutputTokens,
                tokensPerSecond,
              });
            }
            yield* drainParserDelta(ollamaContent);
          }

          const ollamaReasoning = nativeParsed.message?.reasoning ?? nativeParsed.message?.thinking ?? nativeParsed.reasoning;
          if (typeof ollamaReasoning === 'string' && ollamaReasoning.length > 0) {
            if (firstOutputAtMs === null) firstOutputAtMs = Date.now();
            outputChars += ollamaReasoning.length;
            outputText += ollamaReasoning;
            const estOutputTokens = Math.ceil(outputChars / 3);
            if (estOutputTokens !== emittedOutputTokens) {
              emittedOutputTokens = estOutputTokens;
              const tokensPerSecond = this.calculateTokensPerSecond({
                tokens: estOutputTokens,
                durationNs: null,
                startedAtMs: firstOutputAtMs,
                endedAtMs: Date.now()
              });
              eventBus.emit(EventType.TOKEN_UPDATE, {
                input: estimatedInputTokens,
                output: estOutputTokens,
                total: estimatedInputTokens + estOutputTokens,
                tokensPerSecond,
              });
            }
            yield { type: 'reasoning', data: ollamaReasoning };
          }

          const ollamaToolCalls = nativeParsed.message?.tool_calls;
          if (Array.isArray(ollamaToolCalls) && ollamaToolCalls.length > 0) {
            for (const tc of ollamaToolCalls) {
              const fn = tc?.function || {};
              let args: Record<string, unknown> | string = this.normalizeToolArgs(fn.arguments ?? {});
              if (typeof args === 'string') {
                const rawArgs = args;
                try {
                  args = JSON.parse(args);
                } catch {
                  if (strictToolStream && looksJsonish(rawArgs)) {
                    const snippet = rawArgs.slice(0, 240).replace(/\s+/g, ' ');
                    yield { type: 'error', data: `stream parse error in tool arguments: ${snippet}` };
                    return;
                  }
                }
              }
              yield {
                type: 'tool_call',
                data: {
                  tool: String(fn.name || ''),
                  arguments: args,
                  id: String(tc?.id || `call_${Date.now()}`),
                }
              };
            }
          }

          if (nativeParsed.done === true) {
            if (!inlineParserFinished) yield* drainParserDelta('', true);
            if (typeof nativeParsed.prompt_eval_count === 'number' || typeof nativeParsed.eval_count === 'number') {
              lastUsage = {
                prompt_tokens: typeof nativeParsed.prompt_eval_count === 'number' ? nativeParsed.prompt_eval_count : undefined,
                completion_tokens: typeof nativeParsed.eval_count === 'number' ? nativeParsed.eval_count : undefined,
                prompt_eval_duration: typeof nativeParsed.prompt_eval_duration === 'number' ? nativeParsed.prompt_eval_duration : undefined,
                eval_duration: typeof nativeParsed.eval_duration === 'number' ? nativeParsed.eval_duration : undefined,
              };
            }
            if (!doneEmitted) {
              doneEmitted = true;
              yield { type: 'done', data: null };
            }
          }
        } catch {
          // Historically we swallowed malformed stream lines. That's risky:
          // if a tool_call payload is the malformed line, the loop sees
          // "no tool call" and may conclude prematurely. In strict mode,
          // treat suspicious tool-call payload parse failures as hard errors
          // so the upper loop can recover explicitly.
          const looksLikeToolPayload =
            /"tool_calls"\s*:/.test(payload) ||
            /<tool_call>/i.test(payload) ||
            /"function"\s*:\s*\{/.test(payload);
          if (strictToolStream && looksLikeToolPayload) {
            malformedToolPayloads++;
            const snippet = payload.slice(0, 240).replace(/\s+/g, ' ');
            yield {
              type: 'error',
              data: `stream parse error in tool payload (${malformedToolPayloads}): ${snippet}`
            };
            return;
          }
          // Non-tool payload parse failures are still ignored as before.
        }
      }
    }
    loadProbe.stop();
    if (idleTimer) clearTimeout(idleTimer);
    releaseController();

    if (!inlineParserFinished) {
      yield* drainParserDelta('', true);
    }

    // Emit final token update — real usage when the server included it,
    // resolved estimate (often /tokenize-exact) otherwise. `exact` reflects
    // whether either side of the count came from the model's tokenizer
    // (so the UI can drop any "~" prefix it might be showing).
    const inputTokens = this.coalesceMetric(lastUsage?.prompt_tokens, estimatedInputTokens);
    const outputTokens = await this.resolveOutputTokenCount(outputText, lastUsage?.completion_tokens);
    const cachedTokens = (lastUsage as any)?.prompt_tokens_details?.cached_tokens ?? null;
    const tokensPerSecond = this.calculateTokensPerSecond({
      tokens: outputTokens.count,
      durationNs: lastUsage?.eval_duration ?? null,
      startedAtMs: firstOutputAtMs,
      endedAtMs: Date.now()
    });
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: inputTokens,
      output: outputTokens.count,
      total: inputTokens + outputTokens.count,
      exact: typeof lastUsage?.prompt_tokens === 'number' && outputTokens.exact,
      cached: typeof cachedTokens === 'number' ? cachedTokens : undefined,
      tokensPerSecond,
    });

    // Flush remaining tool calls
    for (const tc of Object.values(activeCalls)) {
      try {
        const args = JSON.parse(tc.function.arguments);
        yield { type: 'tool_call', data: { tool: tc.function.name, arguments: args, id: tc.id } };
      } catch {
        if (strictToolStream && looksJsonish(tc.function.arguments)) {
          const snippet = String(tc.function.arguments || '').slice(0, 240).replace(/\s+/g, ' ');
          yield { type: 'error', data: `stream parse error in tool arguments: ${snippet}` };
          return;
        }
        yield { type: 'tool_call', data: { tool: tc.function.name, arguments: tc.function.arguments, id: tc.id } };
      }
    }

    if (!doneEmitted) {
      yield { type: 'done', data: null };
    }
  }

  async generate(prompt: string, system?: string): Promise<string> {
    const messages: ApiChatMessage[] = [];
    if (system) messages.push({ role: 'system', content: system });
    messages.push({ role: 'user', content: prompt });

    const res = await this.chat(messages);
    return res?.message?.content || '';
  }


  // FIX-02: Fetch server properties to detect total_slots for slot pinning
  private async resolveServerProps(): Promise<Record<string, unknown> | null> {
    if (this.serverPropsCache) return this.serverPropsCache;
    try {
      const res = await fetch(`${this.baseUrl}/props`, {
        signal: AbortSignal.timeout(3000)
      });
      if (!res.ok) return null;
      const json = await res.json().catch(() => null);
      if (json && typeof json === 'object') {
        this.serverPropsCache = json as Record<string, unknown>;
        return this.serverPropsCache;
      }
      return null;
    } catch {
      return null;
    }
  }

  // Node.js Undici (the native fetch impl) does NOT use the system's mDNS resolver,
  // so hostnames like `inference.local` fail. We pre-resolve via dns.lookup() which
  // honours /etc/nsswitch.conf and therefore Avahi/mDNS.
  private async resolveUrl(url: string): Promise<string> {
    try {
      const parsed = new URL(url);
      const hostname = parsed.hostname;
      // Only resolve non-IP, non-localhost hostnames — especially *.local (mDNS)
      if (hostname === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(hostname)) return url;
      const { address } = await dnsLookupAsync(hostname);
      parsed.hostname = address;
      return parsed.toString();
    } catch {
      return url; // fallback to original if resolution fails
    }
  }

  /**
   * Watchdog for model-load progress. If a chat request doesn't begin
   * streaming within LOAD_PROBE_DELAY_MS, poll `/health` to check whether
   * the backend is in its loading phase, and emit PROGRESS_UPDATE events
   * with elapsed seconds so the renderer's status line shows activity.
   *
   * llama-server middleware returns 503 with body `{"error": {... "Loading
   * model" ...}}` while the model is loading and 200 `{"status":"ok"}`
   * once ready (see .reference/llama.cpp/tools/server/server-http.cpp:233
   * and server-context.cpp:3696). Ollama has no equivalent endpoint, so on
   * that backend the probe degrades to a generic "loading model..." label
   * driven purely by elapsed time.
   */
  private startLoadProbe(): { stop: () => void } {
    const startedAt = Date.now();
    let stopped = false;
    let announced = false;
    let interval: NodeJS.Timeout | null = null;

    const emit = (message: string) => {
      eventBus.emit(EventType.PROGRESS_UPDATE, { message });
    };

    const poll = async () => {
      if (stopped) return;
      const elapsedS = Math.round((Date.now() - startedAt) / 1000);

      // Short-circuit: backend already proven to lack /health (3× 404 → Ollama).
      // Skip the round-trip entirely and emit a time-based label.
      if (ApiClient.healthProbeDisabled) {
        announced = true;
        emit(`Loading model… ${elapsedS}s`);
        return;
      }

      const healthUrl = this.apiUrl('/health');
      let label: string | null = null;
      try {
        const resolvedHealth = await this.resolveUrl(healthUrl);
        const controller = new AbortController();
        const t = setTimeout(() => controller.abort(), 1200);
        const r = await fetch(resolvedHealth, { signal: controller.signal }).finally(() => clearTimeout(t));
        if (r.status === 404) {
          ApiClient.healthProbeConsecutive404++;
          if (ApiClient.healthProbeConsecutive404 >= ApiClient.HEALTH_PROBE_404_THRESHOLD) {
            ApiClient.healthProbeDisabled = true;
          }
          label = `Loading model… ${elapsedS}s`;
        } else if (r.status === 503) {
          ApiClient.healthProbeConsecutive404 = 0;
          const text = await r.text().catch(() => '');
          label = /loading/i.test(text) ? `Loading model… ${elapsedS}s` : `Backend warming up… ${elapsedS}s`;
        } else if (r.ok) {
          ApiClient.healthProbeConsecutive404 = 0;
          // Backend healthy but our request still pending — likely prompt
          // eval on a long context. Keep the user informed.
          label = `Processing prompt… ${elapsedS}s`;
        } else {
          // Other 4xx/5xx — don't count toward the Ollama signal (could be a
          // proxy hiccup), but still surface something.
          ApiClient.healthProbeConsecutive404 = 0;
          label = `Loading model… ${elapsedS}s`;
        }
      } catch {
        // /health unreachable (network/timeout). Don't bump the 404 counter —
        // a transient error isn't proof of Ollama. Fall back to a neutral label.
        label = `Loading model… ${elapsedS}s`;
      }
      if (stopped || !label) return;
      announced = true;
      emit(label);
    };

    const initialTimer = setTimeout(() => {
      if (stopped) return;
      void poll();
      interval = setInterval(() => { void poll(); }, ApiClient.LOAD_PROBE_INTERVAL_MS);
    }, ApiClient.LOAD_PROBE_DELAY_MS);

    return {
      stop: () => {
        if (stopped) return;
        stopped = true;
        clearTimeout(initialTimer);
        if (interval) clearInterval(interval);
        if (announced) {
          // Clear the "loading…" label so the next state owner (think/
          // working/etc.) controls the status line cleanly.
          emit('');
        }
      }
    };
  }

  private async fetchWithTimeout(url: string, body: unknown): Promise<Response> {
    // Non-streaming callers consume the body right after this returns and
    // never iterate a long-lived reader, so we release as soon as headers
    // are in. (This matches the prior fetch().finally() contract — body
    // reads after headers were never tracked for abort.)
    const { response, release } = await this.fetchTracked(url, body);
    release();
    return response;
  }

  /**
   * Same as fetchWithTimeout but returns both the Response and the
   * AbortController so a streaming caller can keep aborting the request
   * AFTER headers arrive (the connection timeout in fetchTracked only
   * guards header receipt — the body stream can run indefinitely otherwise,
   * which caused the 138-minute "Thinking" hang). Caller is responsible for
   * removing the controller from inflightControllers when the body is done.
   */
  private async fetchStreamWithController(url: string, body: unknown): Promise<{ response: Response; controller: AbortController; release: () => void }> {
    const { response, controller, release } = await this.fetchTracked(url, body);
    return { response, controller, release };
  }

  private async fetchTracked(url: string, body: unknown): Promise<{ response: Response; controller: AbortController; release: () => void }> {
    const resolvedUrl = await this.resolveUrl(url);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    // Register so INFERENCE_CANCEL can abort us. Cleared via the returned
    // `release` once the caller is done with the response/body.
    ApiClient.inflightControllers.add(controller);
    let released = false;
    const release = (): void => {
      if (released) return;
      released = true;
      clearTimeout(timer);
      ApiClient.inflightControllers.delete(controller);
    };

    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.apiKey) headers['Authorization'] = `Bearer ${this.apiKey}`;

    try {
      const response = await fetch(resolvedUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      return { response, controller, release };
    } catch (e) {
      release();
      throw e;
    }
  }

  private apiUrl(path: string): string {
    return this.baseUrl.replace(/\/+$/, '') + path;
  }

  private normalizeHost(host: string): string {
    let h = host.trim();
    if (!h) return 'http://127.0.0.1:11434';
    if (!h.startsWith('http://') && !h.startsWith('https://')) {
      h = 'http://' + h;
    }
    return h.replace(/\/+$/, '');
  }

  private serializeMessages(messages: ApiChatMessage[]): SerializedApiMessage[] {
    return messages.map(msg => {
      const m: SerializedApiMessage = { role: msg.role };
      if (typeof msg.content === 'string') {
        m.content = msg.content;
      } else if (Array.isArray(msg.content)) {
        m.content = msg.content.map(part => {
          if (part.type === 'image_url') {
            return { type: 'image_url', image_url: part.image_url };
          }
          return { type: 'text', text: part.text || '' };
        });
      }
      if (msg.tool_calls && msg.tool_calls.length > 0) {
        m.tool_calls = msg.tool_calls;
      }
      if (msg.tool_call_id) {
        m.tool_call_id = msg.tool_call_id;
      }
      return m;
    });
  }

  // BUG-17 fix: OpenAI-compat path uses standard param names.
  // BUG-B fix: num_ctx included so Ollama uses the configured context window.
  // `max_tokens` maps Ollama's `num_predict`; Ollama's /v1 endpoint accepts it.
  private runtimeOptionsToParams(): Record<string, unknown> {
    const params: Record<string, unknown> = {
      temperature: this.runtimeOptions.temperature ?? 0.7,
      top_p: this.runtimeOptions.top_p ?? 0.9,
      top_k: this.runtimeOptions.top_k ?? 40,
      presence_penalty: this.runtimeOptions.presence_penalty ?? 0.0,
      frequency_penalty: this.runtimeOptions.frequency_penalty,
      repeat_penalty: this.runtimeOptions.repeat_penalty ?? 1.1,
      min_p: this.runtimeOptions.min_p ?? 0.05,
      max_tokens: this.runtimeOptions.num_predict,   // OpenAI standard (was num_predict)
      num_ctx: this.runtimeOptions.num_ctx,           // BUG-B: context window for Ollama compat
      stop: this.runtimeOptions.stop,
      seed: this.runtimeOptions.seed,
      // llama.cpp prefix-cache control. Reuses the slot's KV for the matching
      // prompt prefix; without it a server with caching disabled re-evaluates
      // the entire prompt every request. Ignored by Ollama's /v1 endpoint.
      cache_prompt: this.cachePrompt,
    };
    if (this.slotId !== null) params.id_slot = this.slotId;
    return params;
  }

  // Native Ollama /api/chat uses Ollama-specific param names inside `options`.
  // BUG-B / BUG-E fix: num_ctx, num_gpu, num_batch included.
  private nativeRuntimeOptions(): Record<string, unknown> {
    return {
      temperature: this.runtimeOptions.temperature ?? 0.7,
      top_p: this.runtimeOptions.top_p ?? 0.9,
      top_k: this.runtimeOptions.top_k ?? 40,
      presence_penalty: this.runtimeOptions.presence_penalty ?? 0.0,
      repeat_penalty: this.runtimeOptions.repeat_penalty ?? 1.1,
      min_p: this.runtimeOptions.min_p ?? 0.05,
      num_predict: this.runtimeOptions.num_predict,  // Ollama native name
      num_ctx: this.runtimeOptions.num_ctx,           // BUG-B: context window
      num_gpu: this.runtimeOptions.num_gpu,           // BUG-E: GPU layer offload
      num_batch: this.runtimeOptions.num_batch,       // BUG-E: batch size
      stop: this.runtimeOptions.stop,
      seed: this.runtimeOptions.seed,
    };
  }

  private shouldFallbackToNative(status: number, bodyText: string): boolean {
    // BUG-H5: llama-server has no `/api/chat` route — cascading into the
    // fallback only swaps a real error for a guaranteed 404, hiding the
    // original cause. Gate on the detected backend.
    if (ApiClient.cachedBackendKind === 'llama-server') return false;
    if (status === 404) return true;
    const lower = String(bodyText || '').toLowerCase();
    return lower.includes('not found') && lower.includes('/v1/chat/completions');
  }

  private openAIChatBody(messages: ApiChatMessage[], tools: ApiToolDef[] | undefined, stream: boolean): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: this.requireModelName(),
      messages: this.serializeMessages(messages),
      stream,
      ...this.runtimeOptionsToParams(),
      ...this.consumeOneShotBodyExtras(),
    };
    if (tools && tools.length > 0) {
      body.tools = tools;
      body.tool_choice = 'auto';
    }
    this.applyThinkToBody(body, 'oai');
    return body;
  }

  private nativeChatBody(messages: ApiChatMessage[], tools: ApiToolDef[] | undefined, stream: boolean): Record<string, unknown> {
    const model = this.requireModelName();
    const body: Record<string, unknown> = {
      model,
      stream,
      messages: this.serializeNativeMessages(messages),
      options: this.nativeRuntimeOptions(),
    };
    if (tools && tools.length > 0) {
      body.tools = tools;
    }
    this.applyThinkToBody(body, 'native');
    return body;
  }

  private serializeNativeMessages(messages: ApiChatMessage[]): NativeSerializedMessage[] {
    return messages.map((msg) => {
      const m: NativeSerializedMessage = {
        role: msg.role,
        content: typeof msg.content === 'string'
          ? msg.content
          : msg.content.map((part) => (part.type === 'text' ? part.text || '' : '')).join('\n')
      };

      if (msg.tool_calls && msg.tool_calls.length > 0) {
        m.tool_calls = msg.tool_calls.map((tc) => ({
          id: tc.id,
          type: tc.type || 'function',
          function: {
            name: tc.function?.name || '',
            arguments: typeof tc.function?.arguments === 'string'
              ? (() => {
                  try { return JSON.parse(tc.function.arguments); } catch { return tc.function.arguments; }
                })()
              : tc.function?.arguments || {}
          }
        }));
      }

      if (msg.tool_call_id) {
        m.tool_call_id = msg.tool_call_id;
      }

      return m;
    });
  }

  private nativeToOllamaChatResponse(native: NativeOllamaResponse): ApiChatResponse {
    const message = native.message || {};
    const toolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
    const responseMessage: ApiChatResponse['message'] = {
      role: 'assistant',
      content: String(message.content ?? native.response ?? ''),
    };

    if (toolCalls.length > 0) {
      responseMessage.tool_calls = toolCalls.map((tc) => ({
        id: tc.id || `call_${Date.now()}`,
        type: 'function' as const,
        function: {
          name: tc?.function?.name || tc?.name || '',
          arguments: typeof tc?.function?.arguments === 'string'
            ? tc.function.arguments
            : JSON.stringify(tc?.function?.arguments || tc?.arguments || {}),
        }
      }));
    }

    return {
      message: responseMessage,
      prompt_eval_count: native.prompt_eval_count ?? null,
      eval_count: native.eval_count ?? null,
    };
  }

  private nativeToOpenAICompat(nativeResponse: unknown): OpenAICompatResponse {
    const native = this.asNativeOllamaResponse(nativeResponse);
    const response = this.nativeToOllamaChatResponse(native);

    return {
      choices: [
        {
          message: {
            content: response.message.content,
            tool_calls: response.message.tool_calls,
          }
        }
      ],
      usage: {
        prompt_tokens: native.prompt_eval_count ?? null,
        completion_tokens: native.eval_count ?? null,
        prompt_eval_duration: native.prompt_eval_duration ?? null,
        eval_duration: native.eval_duration ?? null,
      }
    };
  }

  private accumulateToolCalls(toolCalls: OpenAIToolCallDelta[], active: Record<number, ApiToolCall>): void {
    for (const tc of toolCalls) {
      // BUG-11 fix: use numeric index only; fall back to current entry count so
      // multiple tool calls without an explicit index don't collapse into slot 0.
      const index = typeof tc.index === 'number' ? tc.index : Object.keys(active).length;
      if (!active[index]) {
        active[index] = {
          id: tc.id || `call_${Date.now()}_${index}`,
          type: 'function',
          function: { name: '', arguments: '' },
        };
      }
      if (tc.id) active[index].id = tc.id;
      // BUG-M5: llama.cpp's PEG tool-call parsers (hermes2pro, qwen3) can
      // split the function name across two SSE deltas when a grammar-trigger
      // stop fires mid-token (e.g. `"web_se"` + `"arch"`). The previous
      // unconditional assign dropped the prefix. Concatenate when the new
      // delta is clearly a continuation (no id, slot already has a partial
      // name) or when prefix/suffix overlap is detected; otherwise assign as
      // before so well-formed single-delta names aren't mangled.
      if (tc.function?.name) {
        const incoming = tc.function.name;
        const existing = active[index].function.name;
        if (!existing) {
          active[index].function.name = incoming;
        } else if (existing === incoming) {
          // duplicate delta — no-op
        } else if (!tc.id && !incoming.startsWith(existing) && !existing.startsWith(incoming)) {
          // Continuation delta (no id) with disjoint text → append.
          active[index].function.name = existing + incoming;
        } else if (incoming.startsWith(existing) && incoming.length > existing.length) {
          // Server resent a longer prefix-extension — adopt it.
          active[index].function.name = incoming;
        }
        // existing.startsWith(incoming): keep the longer existing name.
      }
      // Arguments arrive fragmented — concatenate.
      if (tc.function?.arguments) active[index].function.arguments += tc.function.arguments;
    }
  }

  private estimateChars(messages: ApiChatMessage[]): number {
    let total = 0;
    for (const msg of messages) {
      if (typeof msg.content === 'string') {
        total += msg.content.length;
      } else if (Array.isArray(msg.content)) {
        for (const part of msg.content) {
          total += (part.text || '').length;
        }
      }
    }
    return total;
  }

  /**
   * Build a single concatenated string equivalent (for tokenization) of the
   * messages array. This is NOT what the server actually tokenizes — the
   * server applies its chat template first, which adds turn markers like
   * `<|im_start|>` per role. We add a small constant per message to
   * approximate that overhead. Caller can sanity-check against the final
   * `usage.prompt_tokens` and the difference tells you the template cost.
   */
  private serializeForTokenize(messages: ApiChatMessage[]): string {
    const parts: string[] = [];
    for (const msg of messages) {
      // Approximate `<|im_start|>role\n...<|im_end|>\n` overhead with role name.
      parts.push(`${msg.role}:`);
      if (typeof msg.content === 'string') {
        parts.push(msg.content);
      } else if (Array.isArray(msg.content)) {
        for (const part of msg.content) {
          if (part.text) parts.push(part.text);
        }
      }
      if (msg.tool_calls?.length) {
        parts.push(JSON.stringify(msg.tool_calls));
      }
    }
    return parts.join('\n');
  }

  /**
   * Real prompt token count via llama-server's POST /tokenize. Probes the
   * endpoint once per process; if it 404s or errors, caches `false` and
   * subsequent calls return null immediately (no per-request round trip
   * against an Ollama server that doesn't expose /tokenize).
   *
   * Returns null when the count can't be obtained — caller falls back to
   * the chars/3 estimate.
   */
  async tokenizeRequest(messages: ApiChatMessage[]): Promise<number | null> {
    if (ApiClient.cachedBackendKind === 'ollama') return null;
    if (ApiClient.tokenizeSupported === false) return null;
    const content = this.serializeForTokenize(messages);
    if (!content) return 0;
    return this.tokenizeText(content);
  }

  /**
   * Count tokens for plain text via llama.cpp `/tokenize`.
   * Returns null when the backend does not expose `/tokenize`.
   */
  async tokenizeText(content: string): Promise<number | null> {
    if (ApiClient.cachedBackendKind === 'ollama') return null;
    if (ApiClient.tokenizeSupported === false) return null;
    const text = String(content || '');
    if (!text) return 0;
    try {
      const url = await this.resolveUrl(this.apiUrl('/tokenize'));
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 3000);
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        // BUG-M2: `add_special: true` so the BOS/special tokens that the
        // server prepends during real tokenization are counted here too.
        // Previously the local estimate under-counted by ~1 + N (per-turn
        // chatml wrappers), making the compaction threshold look ~5%
        // slacker than reality and contributing to "compactação não funciona".
        body: JSON.stringify({ content: text, add_special: true, with_pieces: false }),
        signal: ctrl.signal
      }).finally(() => clearTimeout(timer));
      if (!res.ok) {
        if (res.status === 404 || res.status === 405) {
          ApiClient.tokenizeSupported = false;
        }
        return null;
      }
      const body = await res.json() as { tokens?: number[] };
      if (!Array.isArray(body?.tokens)) return null;
      ApiClient.tokenizeSupported = true;
      return body.tokens.length;
    } catch {
      return null;
    }
  }

  /**
   * Best-effort real-or-estimated input token count. Tries /tokenize first
   * (llama-server) and falls back to the chars/3 estimate (Ollama, or
   * llama-server with /tokenize disabled). Caller emits a TOKEN_UPDATE
   * with this value BEFORE the stream starts so the UI shows an accurate
   * count during the prompt-eval phase (otherwise the user stares at a
   * 30%-off estimate for 30 seconds on a big prompt).
   */
  async resolveInputTokenCount(messages: ApiChatMessage[]): Promise<{ count: number; exact: boolean }> {
    const exact = await this.tokenizeRequest(messages);
    if (exact !== null) return { count: exact, exact: true };
    return { count: Math.ceil(this.estimateChars(messages) / 3), exact: false };
  }

  private toOllamaChatResponse(openaiResponse: OpenAICompatResponse): ApiChatResponse {
    const choice = openaiResponse.choices?.[0];
    if (!choice) {
      return {
        message: { role: 'assistant', content: '' },
        prompt_eval_count: null,
        eval_count: null
      };
    }

    const message: ApiChatResponse['message'] = {
      role: 'assistant',
      content: choice.message?.content || '',
    };

    if (choice.message?.tool_calls && choice.message.tool_calls.length > 0) {
      message.tool_calls = choice.message.tool_calls.map((tc) => ({
        id: tc.id || `call_${Date.now()}`,
        type: 'function' as const,
        function: {
          name: tc.function?.name || '',
          arguments: typeof tc.function?.arguments === 'string'
            ? tc.function.arguments
            : JSON.stringify(tc.function?.arguments || {}),
        },
      }));
    }

    return {
      message,
      prompt_eval_count: openaiResponse.usage?.prompt_tokens ?? null,
      eval_count: openaiResponse.usage?.completion_tokens ?? null,
    };
  }

  private asOpenAICompatResponse(value: unknown): OpenAICompatResponse {
    if (value && typeof value === 'object') {
      return value as OpenAICompatResponse;
    }
    return {};
  }

  private asNativeOllamaResponse(value: unknown): NativeOllamaResponse {
    if (value && typeof value === 'object') {
      return value as NativeOllamaResponse;
    }
    return {};
  }

  private normalizeToolArgs(value: unknown): Record<string, unknown> | string {
    if (typeof value === 'string') return value;
    if (value && typeof value === 'object') {
      return value as Record<string, unknown>;
    }
    return {};
  }

  private coalesceMetric(primary: number | null | undefined, fallback: number): number {
    if (typeof primary === 'number' && Number.isFinite(primary) && primary >= 0) return primary;
    return Math.max(0, fallback);
  }

  private calculateTokensPerSecond(input: {
    tokens: number | null | undefined;
    durationNs: number | null | undefined;
    startedAtMs: number | null;
    endedAtMs: number;
  }): number | null {
    const tokens = Number(input.tokens);
    if (!Number.isFinite(tokens) || tokens <= 0) return null;

    const durationSecs = this.normalizeDurationSeconds(
      input.durationNs,
      input.startedAtMs,
      input.endedAtMs
    );
    if (typeof durationSecs === 'number' && Number.isFinite(durationSecs) && durationSecs > 0) {
      return tokens / durationSecs;
    }

    if (typeof input.startedAtMs === 'number' && Number.isFinite(input.startedAtMs)) {
      const elapsedMs = input.endedAtMs - input.startedAtMs;
      // Avoid absurd spikes (e.g. 1 token in 1ms => 1000 tok/s).
      // For very short windows the metric is statistically meaningless.
      if (!Number.isFinite(elapsedMs) || elapsedMs < 250) return null;
      return tokens / (elapsedMs / 1000);
    }
    return null;
  }

  private normalizeDurationSeconds(
    rawDuration: number | null | undefined,
    startedAtMs: number | null,
    endedAtMs: number
  ): number | null {
    const raw = Number(rawDuration);
    if (!Number.isFinite(raw) || raw <= 0) return null;

    const nsSecs = raw / 1_000_000_000;
    const usSecs = raw / 1_000_000;
    const msSecs = raw / 1_000;
    const sSecs = raw;
    const candidates = [nsSecs, usSecs, msSecs, sSecs].filter((v) => Number.isFinite(v) && v > 0);
    if (candidates.length === 0) return null;

    // If we have a wall-clock window, pick the candidate closest to it.
    if (typeof startedAtMs === 'number' && Number.isFinite(startedAtMs)) {
      const wallSecs = Math.max(0.001, (endedAtMs - startedAtMs) / 1000);
      let best: number | null = null;
      let bestScore = Number.POSITIVE_INFINITY;
      for (const c of candidates) {
        const score = Math.abs(Math.log10(c / wallSecs));
        if (score < bestScore) {
          bestScore = score;
          best = c;
        }
      }
      if (best !== null) return best;
    }

    // No wall-clock anchor: choose by plausible magnitude.
    // Ollama reports ns, but some OpenAI-compat bridges return µs/ms.
    if (raw >= 100_000_000) return nsSecs; // >=100ms in ns scale
    if (raw >= 1_000_000) return usSecs;   // >=1s in µs scale (or very tiny ns)
    if (raw >= 1_000) return msSecs;
    return sSecs;
  }

  // FIX-03: Detect content type for accurate token estimation
  private getCharsPerToken(text: string): number {
    // CJK (Chinese/Japanese/Korean) characters - typically 1-2 chars per token
    if (/[\u4e00-\u9fff\u3040-\u30ff]/.test(text)) {
      return 1.5;
    }
    // Code-like content - typically 3-4 chars per token
    if (text.includes('```') || /(?:function|const|let|import|def|class|var|return|if|for)\s+/.test(text)) {
      return 3.5;
    }
    // English prose - typically 4-5 chars per token
    if (/^[A-Za-z\s.,!?;:'"()-]+$/.test(text)) {
      return 4.5;
    }
    // Mixed content - conservative estimate
    return 4.0;
  }

  private async resolveOutputTokenCount(
    outputText: string,
    reportedCompletionTokens: number | null | undefined
  ): Promise<{ count: number; exact: boolean }> {
    if (typeof reportedCompletionTokens === 'number' && Number.isFinite(reportedCompletionTokens) && reportedCompletionTokens >= 0) {
      return { count: reportedCompletionTokens, exact: true };
    }
    const exactFromTokenizer = await this.tokenizeText(outputText);
    if (exactFromTokenizer !== null) {
      return { count: Math.max(0, exactFromTokenizer), exact: true };
    }
    // FIX-03: Use content-type-aware estimation instead of fixed chars/3
    const text = String(outputText || '');
    const charsPerToken = this.getCharsPerToken(text);
    return { count: Math.max(0, Math.ceil(text.length / charsPerToken)), exact: false };
  }
}
