import { config } from './config.js';
import { eventBus, EventType } from './tui/event-bus.js';
import { lookup as dnsLookup } from 'dns';
import { promisify } from 'util';

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
  tool_calls?: NativeToolCall[];
}

interface NativeOllamaResponse {
  message?: NativeMessagePayload;
  response?: unknown;
  reasoning?: unknown;
  done?: boolean;
  prompt_eval_count?: number;
  eval_count?: number;
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
  | { type: 'done'; data: null };

export class ApiClient {
  private baseUrl: string;
  private apiKey: string;
  private activeModel: string;
  private timeoutMs: number;
  private runtimeOptions: RuntimeOptions;
  /**
   * Ollama's `think` parameter. null/undefined omits the field entirely
   * (compatible with older Ollama versions and non-thinking models). The Agent
   * sets this based on model capability + OLLAMA_THINK env.
   */
  private thinkValue: boolean | string | null = null;

  constructor() {
    this.baseUrl = this.normalizeHost(String(config.ollama.host || 'http://127.0.0.1:11434'));
    this.apiKey = process.env.OPENAI_API_KEY || '';
    this.activeModel = String(config.ollama.coderModel || config.ollama.model || '').trim();
    this.timeoutMs = Number.parseInt(String(config.ollama.requestTimeoutMs || '180000'), 10);
    this.runtimeOptions = { ...config.ollama.options };
  }

  setActiveModel(model: string): void {
    const next = String(model || '').trim();
    if (!next) return;
    this.activeModel = next;
  }

  getActiveModel(): string {
    return this.activeModel;
  }

  /** Set the `think` field sent in chat requests. null = omit. */
  setThink(value: boolean | string | null): void {
    this.thinkValue = value;
  }

  async chat(
    messages: ApiChatMessage[],
    tools?: ApiToolDef[]
  ): Promise<ApiChatResponse> {
    const url = this.apiUrl('/v1/chat/completions');
    const body: Record<string, unknown> = {
      model: this.activeModel,
      messages: this.serializeMessages(messages),
      stream: false,
      ...this.runtimeOptionsToParams(),
    };
    if (tools && tools.length > 0) {
      body.tools = tools;
      body.tool_choice = 'auto';
    }
    if (this.thinkValue !== null) body.think = this.thinkValue;

    let res = await this.fetchWithTimeout(url, body);
    let json: OpenAICompatResponse;

    if (!res.ok) {
      const text = await res.text().catch(() => 'unknown');
      if (this.shouldFallbackToNative(res.status, text)) {
        const nativeUrl = this.apiUrl('/api/chat');
        const nativeRes = await this.fetchWithTimeout(nativeUrl, this.nativeChatBody(messages, tools, false));
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
    const inputTokens = usage.prompt_tokens || Math.ceil(this.estimateChars(messages) / 3);
    const outputTokens = usage.completion_tokens || Math.ceil(outputContent.length / 3);
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: inputTokens,
      output: outputTokens,
      total: inputTokens + outputTokens,
    });

    return this.toOllamaChatResponse(json);
  }

  async *chatStreamGenerator(
    messages: ApiChatMessage[],
    tools?: ApiToolDef[]
  ): AsyncGenerator<StreamEvent> {
    const url = this.apiUrl('/v1/chat/completions');
    const body: Record<string, unknown> = {
      model: this.activeModel,
      messages: this.serializeMessages(messages),
      stream: true,
      ...this.runtimeOptionsToParams(),
    };
    if (tools && tools.length > 0) {
      body.tools = tools;
      body.tool_choice = 'auto';
    }
    if (this.thinkValue !== null) body.think = this.thinkValue;

    let res = await this.fetchWithTimeout(url, body);
    if (!res.ok) {
      const text = await res.text().catch(() => 'unknown');
      if (this.shouldFallbackToNative(res.status, text)) {
        const nativeUrl = this.apiUrl('/api/chat');
        res = await this.fetchWithTimeout(nativeUrl, this.nativeChatBody(messages, tools, true));
        if (!res.ok) {
          const nativeText = await res.text().catch(() => 'unknown');
          yield { type: 'error', data: `API ${res.status}: ${nativeText}` };
          return;
        }
      } else {
        yield { type: 'error', data: `API ${res.status}: ${text}` };
        return;
      }
    }

    const reader = res.body?.getReader();
    if (!reader) {
      yield { type: 'error', data: 'No response body' };
      return;
    }

    const decoder = new TextDecoder();
    let buffer = '';
    let activeCalls: Record<number, ApiToolCall> = {};
    let outputChars = 0;
    let lastUsage: UsageMetrics | null = null;
    const estimatedInputTokens = Math.ceil(this.estimateChars(messages) / 3);
    let emittedOutputTokens = 0;
    let doneEmitted = false;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

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
          const openAI = this.asOpenAICompatResponse(parsed);

          // OpenAI-compatible SSE (Ollama /v1/chat/completions)
          if (openAI.choices?.[0]) {
            const delta = openAI.choices[0]?.delta || {};
            const finish = openAI.choices[0]?.finish_reason;

            if (delta.content) {
              outputChars += delta.content.length;
              const estOutputTokens = Math.ceil(outputChars / 3);
              if (estOutputTokens !== emittedOutputTokens) {
                emittedOutputTokens = estOutputTokens;
                eventBus.emit(EventType.TOKEN_UPDATE, {
                  input: estimatedInputTokens,
                  output: estOutputTokens,
                  total: estimatedInputTokens + estOutputTokens,
                });
              }
              yield { type: 'content', data: delta.content };
            }
            if (delta.reasoning_content) {
              yield { type: 'reasoning', data: delta.reasoning_content };
            }
            if (delta.tool_calls) {
              this.accumulateToolCalls(delta.tool_calls, activeCalls);
            }
            // Flush accumulated tool calls on ANY finish reason.
            // Some Ollama models emit finish_reason:'stop' instead of 'tool_calls'.
            // Flush before yielding done so tool_calls always precede done in the stream.
            if (finish) {
              for (const tc of Object.values(activeCalls)) {
                try {
                  const args = JSON.parse(tc.function.arguments);
                  yield { type: 'tool_call', data: { tool: tc.function.name, arguments: args, id: tc.id } };
                } catch {
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
            outputChars += ollamaContent.length;
            const estOutputTokens = Math.ceil(outputChars / 3);
            if (estOutputTokens !== emittedOutputTokens) {
              emittedOutputTokens = estOutputTokens;
              eventBus.emit(EventType.TOKEN_UPDATE, {
                input: estimatedInputTokens,
                output: estOutputTokens,
                total: estimatedInputTokens + estOutputTokens,
              });
            }
            yield { type: 'content', data: ollamaContent };
          }

          const ollamaReasoning = nativeParsed.message?.reasoning ?? nativeParsed.reasoning;
          if (typeof ollamaReasoning === 'string' && ollamaReasoning.length > 0) {
            yield { type: 'reasoning', data: ollamaReasoning };
          }

          const ollamaToolCalls = nativeParsed.message?.tool_calls;
          if (Array.isArray(ollamaToolCalls) && ollamaToolCalls.length > 0) {
            for (const tc of ollamaToolCalls) {
              const fn = tc?.function || {};
              let args: Record<string, unknown> | string = this.normalizeToolArgs(fn.arguments ?? {});
              if (typeof args === 'string') {
                try {
                  args = JSON.parse(args);
                } catch {}
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
            if (typeof nativeParsed.prompt_eval_count === 'number' || typeof nativeParsed.eval_count === 'number') {
              lastUsage = {
                prompt_tokens: typeof nativeParsed.prompt_eval_count === 'number' ? nativeParsed.prompt_eval_count : undefined,
                completion_tokens: typeof nativeParsed.eval_count === 'number' ? nativeParsed.eval_count : undefined,
              };
            }
            if (!doneEmitted) {
              doneEmitted = true;
              yield { type: 'done', data: null };
            }
          }
        } catch {
          // skip unparseable lines
        }
      }
    }

    // Emit token update with real usage or estimate
    const inputTokens = lastUsage?.prompt_tokens || estimatedInputTokens;
    const outputTokens = lastUsage?.completion_tokens || Math.ceil(outputChars / 3);
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: inputTokens,
      output: outputTokens,
      total: inputTokens + outputTokens,
    });

    // Flush remaining tool calls
    for (const tc of Object.values(activeCalls)) {
      try {
        const args = JSON.parse(tc.function.arguments);
        yield { type: 'tool_call', data: { tool: tc.function.name, arguments: args, id: tc.id } };
      } catch {
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

  private async fetchWithTimeout(url: string, body: unknown): Promise<Response> {
    const resolvedUrl = await this.resolveUrl(url);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.apiKey) headers['Authorization'] = `Bearer ${this.apiKey}`;

    return fetch(resolvedUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    }).finally(() => clearTimeout(timer));
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
    return {
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
    };
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
    if (status === 404) return true;
    const lower = String(bodyText || '').toLowerCase();
    return lower.includes('not found') && lower.includes('/v1/chat/completions');
  }

  private nativeChatBody(messages: ApiChatMessage[], tools: ApiToolDef[] | undefined, stream: boolean): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: this.activeModel,
      stream,
      messages: this.serializeNativeMessages(messages),
      options: this.nativeRuntimeOptions(),
    };
    if (tools && tools.length > 0) {
      body.tools = tools;
    }
    if (this.thinkValue !== null) body.think = this.thinkValue;
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

  private nativeToOpenAICompat(nativeResponse: unknown): OpenAICompatResponse {
    const native = this.asNativeOllamaResponse(nativeResponse);
    const message = native.message || {};
    const toolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];

    return {
      choices: [
        {
          message: {
            content: String(message.content || ''),
            tool_calls: toolCalls.map((tc) => ({
              id: tc.id || `call_${Date.now()}`,
              type: 'function',
              function: {
                name: tc?.function?.name || tc?.name || '',
                arguments: typeof tc?.function?.arguments === 'string'
                  ? tc.function.arguments
                  : JSON.stringify(tc?.function?.arguments || tc?.arguments || {}),
              }
            }))
          }
        }
      ],
      usage: {
        prompt_tokens: native.prompt_eval_count ?? null,
        completion_tokens: native.eval_count ?? null,
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
      // Name arrives in the first delta — assign, do not concatenate.
      if (tc.function?.name) active[index].function.name = tc.function.name;
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
}
