import 'dotenv/config';

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

const parseKeepAlive = (value: string | undefined): string | number => {
  const raw = (value || '-1').trim();
  if (!raw) return -1;
  const asNumber = Number(raw);
  if (Number.isFinite(asNumber)) return asNumber;
  return raw;
};

const modelHint = (process.env.OLLAMA_MODEL || '').toLowerCase();
const isSmallModel = modelHint.includes('2b') || modelHint.includes('4b');
const is14bModel = modelHint.includes('9b');
const defaultMaxCtx = isSmallModel ? 32768 : 16384;
const ollamaMaxCtx = parseMinInteger(process.env.OLLAMA_NUM_CTX, defaultMaxCtx, 2048);
const ollamaMinCtx = clampInteger(parseInteger(process.env.OLLAMA_MIN_CTX, is14bModel ? 4096 : 3072), 2048, ollamaMaxCtx);
const defaultNumBatch = is14bModel ? 512 : 256;

export const config = {
  ollama: {
    host: process.env.OLLAMA_HOST,
    chatModel: process.env.OLLAMA_CHAT_MODEL,
    coderModel: process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL,
    model: process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL,
    keepAlive: parseKeepAlive(process.env.OLLAMA_KEEP_ALIVE),
    requestTimeoutMs: parseInteger(process.env.OLLAMA_REQUEST_TIMEOUT_MS, 600000),
    adaptiveContext: {
      enabled: process.env.OLLAMA_ADAPTIVE_CTX === 'true' ? true : false,
      minCtx: ollamaMinCtx,
      maxCtx: ollamaMaxCtx
    },
    options: {
      num_gpu: parseInteger(process.env.OLLAMA_NUM_GPU, -1),
      num_ctx: ollamaMaxCtx,
      num_batch: parseInteger(process.env.OLLAMA_NUM_BATCH, defaultNumBatch),
      temperature: 0.7,
      top_p: 0.9,
      top_k: 40,
      presence_penalty: 0.0,
      repeat_penalty: 1.1,
      min_p: 0.05
    }
  },
  system: {
    maxHistory: parseInteger(process.env.MAX_HISTORY, 50),
    mode: parseMode(process.env.MODE),
    ramGB: 16,
    cpuCores: 8,
    intentDebug: parseBoolean(process.env.INTENT_DEBUG, false)
  },
  chat: {
    stream: parseBoolean(process.env.CHAT_STREAM, true)
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
