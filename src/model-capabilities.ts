export interface ModelCapabilities {
  supportsNativeTools: boolean;
  supportsOpenAIFormat: boolean;
  supportsVision: boolean;
  supportsReasoning: boolean;
  supportsStreaming: boolean;
  modelName: string;
  modelFamily: string;
}

export interface OllamaTool {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters?: {
      type: 'object';
      properties: Record<string, unknown>;
      required?: string[];
    };
  };
}

const NATIVE_TOOLS_MODELS = [
  'qwen3.5',
  'qwen3',
  'qwen3.5-coder',
  'qwen3-coder',
  'qwen2.5-coder',
  'qwen2.5coder',
  'qwen2.1',
  'llama3.1',
  'llama3.2',
  'llama-3.1',
  'llama-3.2',
  'phi4',
  'phi-4',
  'phi3.5',
  'phi3',
  'mistral-large',
  'codestral',
  'command-r',
  'commandr'
];

const VISION_MODELS = [
  '-vision',
  'vision',
  'qwen3.5-vision',
  'qwen3-vision',
  'qwen-vl',
  'qwenvl',
  'llava',
  'bakllava',
  'qwen2.5-vision',
  'qwen2.5coder-vision',
  'llama3.2-vision',
  'llama3.2-v',
  'minicpm-v',
  'minicpmv',
  'gemma3-vision',
  'gemma3v'
];

const REASONING_MODELS = [
  'reasoning',
  'think',
  'thinking',
  'qwen3-thinking',
  'qwen3.5-thinking',
  'r1',
  'deepseek-r1',
  'qwq',
  'deepseekr1',
  // phenom (Qwen3-Next base) emits chain-of-thought natively via Ollama.
  // Marking it as reasoning-capable makes the agent forward the `think`
  // parameter and the renderer expect [thinking] chunks.
  'phenom'
];

const NATIVE_TOOLS_FAMILIES = [
  'qwen',
  'llama',
  'phi',
  'mistral',
  'codestral',
  'command',
  'deepseek',
  'gemma4',
  'gemma-4',
  // 'phenom' is the local Ollama tag derived from a Qwen3-Next base. Without
  // this entry, detectModelCapabilities returns supportsNativeTools=false for
  // 'phenom:latest', which silently falls back to the legacy phenom JSON
  // tool-call protocol and the model never receives the tools schema.
  'phenom'
];

const OPENAI_FORMAT_FAMILIES = [
  'qwen',
  'llama',
  'mistral',
  'codestral',
  'gemma'
];

// Models that lexically match a native-tools family (e.g. include "qwen") but
// were NOT fine-tuned with native tool-calling. Without this guard the family
// catch-all flagged supportsNativeTools=true for plain qwen2.5 / qwen2 /
// qwen1.x and the agent sent the `tools` field — the model couldn't emit
// native tool_calls, looped over the same prompt, and burnt context until
// it crashed. These variants fall back to the text-based <tool_call>
// protocol which the parser in tool-call-parser.ts handles.
//
// Exceptions: qwen2.5-coder and qwen2.1 ARE native-tool-trained — the
// negative lookahead `(?!-coder|\.1)` lets them through.
const NO_NATIVE_TOOLS_PATTERNS: RegExp[] = [
  /\bqwen-?2(\.5)?(?!-coder|\.1)/i,
  /\bqwen-?1(\.\d+)?/i,
  // BUG-M7 audit recommendation was based on an outdated assumption: the
  // project's own test-model-capabilities suite asserts that qwen3 base
  // (e.g. `qwen3:14b`) DOES advertise native tools, and qwen3 is in the
  // explicit NATIVE_TOOLS_MODELS allowlist. No additional blocklist entry
  // is correct here — leaving the array as-is.
];

function detectModelFamily(modelName: string): string {
  const lower = modelName.toLowerCase();

  // phenom is a custom Ollama tag built FROM a qwen3.5 base (see Modelfile).
  // Map it to 'qwen' so family-keyed capability checks (vision, reasoning,
  // etc.) apply to it like to any other Qwen variant.
  if (lower.includes('phenom')) return 'qwen';
  if (lower.includes('qwen')) return 'qwen';
  if (lower.includes('llama')) return 'llama';
  if (lower.includes('phi')) return 'phi';
  if (lower.includes('mistral')) return 'mistral';
  if (lower.includes('codestral')) return 'codestral';
  if (lower.includes('command')) return 'cohere';
  if (lower.includes('deepseek')) return 'deepseek';
  if (lower.includes('gemma')) return 'gemma';

  return 'unknown';
}

export function detectModelCapabilities(modelName: string): ModelCapabilities {
  const lower = modelName.toLowerCase();
  const family = detectModelFamily(modelName);
  
  const explicitlyBlocked = NO_NATIVE_TOOLS_PATTERNS.some(rx => rx.test(modelName));
  // Explicit model match (e.g. 'qwen2.5-coder') wins over the blocklist —
  // it's a more specific signal than the qwen2.5-base regex.
  const explicitlyAllowed = NATIVE_TOOLS_MODELS.some(m => lower.includes(m));
  const familyAllowed = NATIVE_TOOLS_FAMILIES.some(f => lower.includes(f));
  const supportsNativeTools = explicitlyAllowed || (familyAllowed && !explicitlyBlocked);
  
  const supportsOpenAIFormat = !supportsNativeTools && OPENAI_FORMAT_FAMILIES.some(f => lower.includes(f));
  
  const supportsVision = VISION_MODELS.some(m => lower.includes(m)) ||
    (family === 'llama' && lower.includes('3.2')) ||
    (family === 'qwen' && lower.includes('vision')) ||
    (family === 'gemma' && lower.includes('vision'));
  
  const supportsReasoning = REASONING_MODELS.some(m => lower.includes(m)) ||
    (family === 'qwen' && (lower.includes('reasoning') || lower.includes('think') || lower.includes('qwq'))) ||
    (family === 'deepseek' && (lower.includes('r1') || lower.includes('reasoning'))) ||
    lower.includes('-thinking') ||
    !!lower.match(/r1\b/);
  
  const supportsStreaming = true;
  
  return {
    supportsNativeTools,
    supportsOpenAIFormat,
    supportsVision,
    supportsReasoning,
    supportsStreaming,
    modelName,
    modelFamily: family
  };
}

export function toolsToOllamaFormat(tools: Array<{
  name: string;
  description: string;
  parameters?: {
    type: 'object';
    properties: Record<string, unknown>;
    required?: string[];
  };
}>): OllamaTool[] {
  return tools.map(tool => ({
    type: 'function' as const,
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  }));
}

export function toolsToOpenAIFormat(tools: Array<{
  name: string;
  description: string;
  parameters?: {
    type: 'object';
    properties: Record<string, unknown>;
    required?: string[];
  };
}>): OllamaTool[] {
  return tools.map(tool => ({
    type: 'function' as const,
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  }));
}

interface NativeToolCallPayload {
  name?: string;
  function?: {
    name?: string;
    arguments?: unknown;
  };
  arguments?: unknown;
}

interface NativeToolCallResponse {
  message?: {
    tool_calls?: NativeToolCallPayload[];
  };
  tool_calls?: NativeToolCallPayload[];
}

export function extractNativeToolCalls(response: unknown): Array<{ tool: string; arguments: Record<string, unknown> }> {
  if (!response) return [];

  const root = (response && typeof response === 'object') ? (response as NativeToolCallResponse) : {};
  const message = root.message || root;

  if (Array.isArray(message.tool_calls) && message.tool_calls.length > 0) {
    const result: Array<{ tool: string; arguments: Record<string, unknown> }> = [];
    for (const tc of message.tool_calls) {
      const toolName = tc.function?.name || tc.name || '';
      const rawArgs = typeof tc.function?.arguments === 'string'
        ? safeParseObject(tc.function.arguments)
        : (tc.function?.arguments || tc.arguments || {});
      const toolArgs = toObject(rawArgs);
      result.push({ tool: toolName, arguments: toolArgs });
    }
    return result;
  }
  
  return [];
}

interface ToolResultLike {
  success?: boolean;
  output?: unknown;
  error?: unknown;
}

export function formatToolResultForNative(result: ToolResultLike | null | undefined): string {
  if (!result) return '[OK] Tool executed successfully';

  const rawOutput = typeof result.output === 'string' ? result.output : '';
  const truncated = rawOutput.length > 4000
    ? `${rawOutput.slice(0, 4000)}\n...[truncated]`
    : rawOutput;

  if (result.success) {
    if (truncated.length > 0) return `[OK] ${truncated}`;
    return '[OK] Tool completed';
  }

  // Failure: include the captured output below the error tag so the model
  // can read the actual stderr/stdout instead of just "Exit code 1".
  const head = `[FAIL] ${result.error || 'Unknown error'}`;
  return truncated ? `${head}\n--- output ---\n${truncated}` : head;
}

function safeParseObject(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function toObject(value: unknown): Record<string, unknown> {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

// FIX-08: Fetch model capabilities from backend API when available
export async function fetchModelCapabilities(
  baseUrl: string,
  modelName: string
): Promise<Partial<ModelCapabilities> | null> {
  try {
    // Try Ollama's /api/show endpoint to get model info
    const url = `${baseUrl.replace(/\/+$/, '')}/api/show`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: modelName }),
      signal: AbortSignal.timeout(5000)
    });
    if (!res.ok) return null;

    const info = await res.json() as { capabilities?: string[]; model?: string } | null;
    if (!info) return null;

    // Check if model explicitly supports tools
    if (info.capabilities?.includes('tools')) {
      return { supportsNativeTools: true };
    }

    // Try to detect family from model name
    const family = detectModelFamily(modelName);
    const supportsNative = NATIVE_TOOLS_FAMILIES.some(f => family === f);

    return {
      modelFamily: family,
      supportsNativeTools: supportsNative,
    };
  } catch {
    return null;
  }
}
