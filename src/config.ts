import 'dotenv/config';

/**
 * Project-baked defaults. The CLI will work out of the box pointing at the
 * production phenom server with sane parameters — no .env required.
 *
 * Env vars STILL win when set, so a different machine can override any of
 * these without rebuilding. The defaults exist so the common case (this
 * project, this server, this model) needs zero configuration.
 *
 * Edit ONLY this block when the production server, model, or sampling
 * defaults change. Leave the env-reading code below alone.
 */
const PROJECT_DEFAULTS = {
  // Inference server (llama-server or Ollama, OpenAI-compat /v1 endpoint).
  // Per [[feedback-no-localhost-fallback]], never default to 127.0.0.1 —
  // this is the project's real backend.
  host: 'http://192.168.1.122:11434',

  // Model alias the backend reports. `phenom` is the local Modelfile tag
  // built on a Qwen3-Next base — recognized as Qwen family by
  // model-capabilities.ts (native tools + reasoning).
  model: 'phenom',

  // Context window we *request*. The runtime clamps this against the
  // server's actual /props.n_ctx (see ollama-client.getEffectiveContextLimit).
  // Set generously — the clamp protects against config drift.
  numCtx: 32768,

  // Batch sizes tuned for an 8 GB VRAM + 16 GB RAM box running a MoE
  // 30B-A3B model with experts offloaded to CPU via -ot.
  numBatch: 512,

  // Sampling tuned for a 7B coder model editing real code.
  //
  // The defaults shipped earlier (temp 0.25, repeat_penalty 1.08) were
  // generalist-chat values that produced inconsistent edits and "creative"
  // tool-call arguments. For coding agents on a 7B these knobs matter
  // a LOT more than on a 14B+: every degree of freedom the sampler gets
  // is one the model uses to drift from the user's intent.
  //
  //   temperature 0.15 — code wants determinism. The model still varies
  //     within a request (top_p does that), but the floor is lower.
  //   top_p 0.8       — tighter nucleus, fewer wild tokens.
  //   top_k 20        — cuts the long tail of confused tokens earlier.
  //   repeat_penalty 1.03 — high penalty (1.08) punishes legitimate code
  //     repetition like `} else if {` chains or `const x = ...; const y = ...;`
  //     blocks. 1.03 is enough to break loops without distorting code.
  //   min_p 0.05      — unchanged; works fine for code.
  //
  // For chat-only / brainstorming use, override per session via the live
  // sampling controls, not the project default.
  temperature: 0.15,
  top_p: 0.8,
  top_k: 20,
  repeat_penalty: 1.03,
  min_p: 0.05,

  // Thinking / tool protocol — auto lets model-capabilities decide.
  thinkMode: 'auto',
  toolsProtocol: 'auto' as 'auto' | 'native' | 'text',

  // Keep the model resident; the box only runs this one workload.
  keepAlive: -1 as number | string,

  // Generous: long tool loops on slow prompt eval can take a minute.
  requestTimeoutMs: 600_000,

  maxHistory: 40,
} as const;

const parseInteger = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const parseMinInteger = (value: string | undefined, fallback: number, min: number): number => {
  return Math.max(min, parseInteger(value, fallback));
};

const clampInteger = (value: number, min: number, max: number): number => {
  return Math.min(max, Math.max(min, value));
};

const parseBoolean = (value: string | undefined, fallback: boolean): boolean => {
  if (value === undefined) return fallback;
  const normalized = value.trim().toLowerCase();
  if (normalized === 'true' || normalized === '1' || normalized === 'yes') return true;
  if (normalized === 'false' || normalized === '0' || normalized === 'no') return false;
  return fallback;
};

const parseMode = (value: string | undefined): 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis' => {
  const normalized = (value || 'code_assistant').trim().toLowerCase();
  if (normalized === 'fast') return 'fast';
  if (normalized === 'assistant') return 'assistant';
  if (normalized === 'plan') return 'plan';
  if (normalized === 'jarvis') return 'jarvis';
  if (normalized === 'code_assistant' || normalized === 'coder') return 'code_assistant';
  if (normalized === 'reasoning' || normalized === 'deep') return 'reasoning';
  return 'code_assistant';
};

const parseKeepAlive = (value: string | undefined): string | number | undefined => {
  if (value === undefined) return undefined;
  const raw = value.trim();
  if (!raw) return undefined;
  const asNumber = Number(raw);
  if (Number.isFinite(asNumber)) return asNumber;
  return raw;
};

/**
 * Raw OLLAMA_THINK value, kept as-is for the Agent to resolve at runtime
 * (it needs supportsReasoning to compute the "auto" default). Accepted:
 *   undefined / "" / "auto"  → auto-on for reasoning-capable models
 *   "true" | "1" | "yes"     → force on
 *   "false" | "0" | "no"     → force off
 *   "low" | "medium" | "high" → graded level (forwarded as string)
 */
const parseThinkMode = (value: string | undefined): string | undefined => {
  if (value === undefined) return undefined;
  const raw = value.trim().toLowerCase();
  if (!raw || raw === 'auto') return 'auto';
  const allowed = new Set(['true', '1', 'yes', 'false', '0', 'no', 'low', 'medium', 'high']);
  return allowed.has(raw) ? raw : 'auto';
};

const modelHint = (process.env.OLLAMA_MODEL || PROJECT_DEFAULTS.model).toLowerCase();
const isSmallModel = modelHint.includes('2b') || modelHint.includes('4b');
const is14bModel = modelHint.includes('9b');
const ollamaMaxCtx = parseMinInteger(process.env.OLLAMA_NUM_CTX, PROJECT_DEFAULTS.numCtx, 2048);
const ollamaMinCtx = clampInteger(parseInteger(process.env.OLLAMA_MIN_CTX, is14bModel ? 4096 : 3072), 2048, ollamaMaxCtx);
const canaryPerfTuning = parseBoolean(process.env.PHENOM_CANARY_PERF_TUNING, false);
const defaultNumBatch = canaryPerfTuning ? 256 : PROJECT_DEFAULTS.numBatch;
const defaultAdaptiveContextEnabled = canaryPerfTuning ? true : false;

export const config = {
  ollama: {
    host: process.env.OLLAMA_HOST || PROJECT_DEFAULTS.host,
    chatModel: process.env.OLLAMA_CHAT_MODEL || process.env.OLLAMA_MODEL || process.env.OLLAMA_CODER_MODEL || PROJECT_DEFAULTS.model,
    coderModel: process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL || process.env.OLLAMA_CHAT_MODEL || PROJECT_DEFAULTS.model,
    model: process.env.OLLAMA_MODEL || process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_CHAT_MODEL || PROJECT_DEFAULTS.model,
    keepAlive: parseKeepAlive(process.env.OLLAMA_KEEP_ALIVE) ?? PROJECT_DEFAULTS.keepAlive,
    requestTimeoutMs: parseInteger(process.env.OLLAMA_REQUEST_TIMEOUT_MS, PROJECT_DEFAULTS.requestTimeoutMs),
    thinkMode: parseThinkMode(process.env.OLLAMA_THINK) ?? PROJECT_DEFAULTS.thinkMode,
    /**
     * Tool-call protocol selection:
     *   'auto'   — use model-capabilities detection (default; native when
     *              the model family supports it, text otherwise).
     *   'native' — force native OpenAI-style tool_calls. Server must support
     *              them (Ollama with native tools, or llama.cpp with --jinja).
     *   'text'   — force text-protocol where tool calls are emitted as
     *              <tool_call>{...}</tool_call> blocks inside the assistant
     *              content stream. Use this when the server has a buggy
     *              native parser (e.g. llama.cpp --jinja with multi-byte
     *              escape sequences in long content arguments). When this
     *              is selected, phenom-cli injects the tools schema into
     *              the system prompt itself instead of via the `tools` API
     *              parameter.
     */
    toolsProtocol: ((): 'auto' | 'native' | 'text' => {
      const raw = (process.env.PHENOM_TOOLS_PROTOCOL || PROJECT_DEFAULTS.toolsProtocol).toLowerCase().trim();
      if (raw === 'native' || raw === 'text') return raw;
      return 'auto';
    })(),
    adaptiveContext: {
      enabled: parseBoolean(process.env.OLLAMA_ADAPTIVE_CTX, defaultAdaptiveContextEnabled),
      minCtx: ollamaMinCtx,
      maxCtx: ollamaMaxCtx
    },
    options: {
      num_gpu: parseInteger(process.env.OLLAMA_NUM_GPU, -1),
      num_ctx: ollamaMaxCtx,
      num_batch: parseInteger(process.env.OLLAMA_NUM_BATCH, defaultNumBatch),
      // Keep runtime defaults aligned with Modelfile sampling so behavior
      // stays consistent between direct `ollama run` and API calls.
      temperature: PROJECT_DEFAULTS.temperature,
      top_p: PROJECT_DEFAULTS.top_p,
      top_k: PROJECT_DEFAULTS.top_k,
      presence_penalty: 0.0,
      repeat_penalty: PROJECT_DEFAULTS.repeat_penalty,
      min_p: PROJECT_DEFAULTS.min_p
    }
  },
  system: {
    maxHistory: parseInteger(process.env.MAX_HISTORY, PROJECT_DEFAULTS.maxHistory),
    mode: parseMode(process.env.MODE),
    ramGB: 16,
    cpuCores: 8,
    intentDebug: parseBoolean(process.env.INTENT_DEBUG, false)
  },
  chat: {
    stream: parseBoolean(process.env.CHAT_STREAM, true)
  },
  canary: {
    perfTuning: canaryPerfTuning,
  },
  contextPacking: {
    enabled: parseBoolean(process.env.PHENOM_CONTEXT_PACKING, true),
    maxChars: parseMinInteger(process.env.PHENOM_CONTEXT_PACK_MAX_CHARS, 6000, 1000),
    maxLines: parseMinInteger(process.env.PHENOM_CONTEXT_PACK_MAX_LINES, 160, 20),
    keepTailChars: parseMinInteger(process.env.PHENOM_CONTEXT_PACK_KEEP_TAIL_CHARS, 1200, 120),
  },
  rag: {
    autoLexicalFallback: parseBoolean(process.env.PHENOM_AUTO_RAG_LEXICAL_FALLBACK, true),
  },
  trace: {
    includeTokenUpdate: parseBoolean(process.env.PHENOM_TRACE_TOKENS, false),
  },
  // Text-to-speech (Piper HTTP service on inference.local). All knobs
  // env-driven; defaults match the standalone Piper service we ship.
  // PHENOM_TTS=on flips it on at startup; users still toggle live via /tts.
  tts: {
    enabled: parseBoolean(process.env.PHENOM_TTS, false),
    endpoint: process.env.PHENOM_TTS_ENDPOINT || 'http://inference.local:8765/speak',
    requestTimeoutMs: parseInteger(process.env.PHENOM_TTS_TIMEOUT_MS, 60000)
  },
  search: {
    maxResults: parseInteger(process.env.SEARCH_MAX_RESULTS, 15),
    contextLines: parseInteger(process.env.SEARCH_CONTEXT_LINES, 2),
    maxFileHits: parseInteger(process.env.SEARCH_MAX_FILE_HITS, 3),
    queryMaxLen: parseInteger(process.env.SEARCH_QUERY_MAX_LEN, 120),
    queryMaxTokens: parseInteger(process.env.SEARCH_QUERY_MAX_TOKENS, 10),
    queryTruncateLen: parseInteger(process.env.SEARCH_QUERY_TRUNCATE_LEN, 100),
    companionMaxTokens: parseInteger(process.env.SEARCH_COMPANION_MAX_TOKENS, 3),
    needleMaxTokens: parseInteger(process.env.SEARCH_NEEDLE_MAX_TOKENS, 6)
  },
  workspace: {
    maxFiles: parseMinInteger(process.env.WORKSPACE_MAX_FILES, 6, 1),
    maxTotalBytes: parseInteger(process.env.WORKSPACE_MAX_TOTAL_BYTES, 60000),
    maxFileBytes: parseInteger(process.env.WORKSPACE_MAX_FILE_BYTES, 20000)
  },
  edit: {
    fullReplaceMaxBytes: parseInteger(process.env.EDIT_FULL_REPLACE_MAX_BYTES, 20000),
    fullReplaceMaxLines: parseInteger(process.env.EDIT_FULL_REPLACE_MAX_LINES, 200),
    placeholderMaxBytes: parseInteger(process.env.EDIT_PLACEHOLDER_MAX_BYTES, 400),
    placeholderMaxLines: parseInteger(process.env.EDIT_PLACEHOLDER_MAX_LINES, 6)
  },
  tui: {
    renderDebounceMs: parseInteger(process.env.TUI_RENDER_DEBOUNCE_MS, 50),
    streamDebounceMs: parseInteger(process.env.TUI_STREAM_DEBOUNCE_MS, 80),
    reasoningHeight: parseInteger(process.env.TUI_REASONING_HEIGHT, 5),
    maxColumns: parseInteger(process.env.TUI_MAX_COLUMNS, 80)
  }
};
