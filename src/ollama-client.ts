import { config } from './config.js';
import { eventBus, EventType } from './tui/event-bus.js';
import { ApiChatResponse, ApiClient, ApiChatMessage, ApiContentPart, ApiToolDef } from './api-client.js';

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

export class OllamaClient {
  private api: ApiClient;
  private readonly adaptiveContextEnabled: boolean;
  private readonly minContext: number;
  private readonly maxContext: number;
  private readonly requestTimeoutMs: number;
  public lastTokenUsage: TokenUsage = { input: 0, output: 0, total: 0 };
  private readonly maxRetries = 2;
  private readonly retryDelaySeconds = 10;

  constructor() {
    this.adaptiveContextEnabled = config.ollama.adaptiveContext.enabled;
    this.minContext = config.ollama.adaptiveContext.minCtx;
    this.maxContext = config.ollama.adaptiveContext.maxCtx;
    this.requestTimeoutMs = Number.parseInt(String(config.ollama.requestTimeoutMs ?? 180000), 10);
    this.api = new ApiClient();
    const model = String(config.ollama.coderModel || config.ollama.model || '').trim();
    if (model) this.api.setActiveModel(model);
  }

  setActiveModel(model: string): void {
    this.api.setActiveModel(model);
  }

  getActiveModel(): string {
    return this.api.getActiveModel();
  }

  async generate(prompt: string, system?: string): Promise<string> {
    for (let attempt = 1; attempt <= this.maxRetries + 1; attempt++) {
      try {
        return await this.api.generate(prompt, system);
      } catch (error: unknown) {
        this.handleApiError(error);
        if (attempt <= this.maxRetries) {
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

    eventBus.emit(EventType.PROGRESS_UPDATE, {
      message: `Thinking (${this.getActiveModel()})`,
      intentType: 'general',
    });

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

    let progressTimer: ReturnType<typeof setInterval> | null = null;
    if (typeof setInterval !== 'undefined') {
      let elapsed = 0;
      progressTimer = setInterval(() => {
        elapsed += 5;
        eventBus.emit(EventType.PROGRESS_UPDATE, {
          message: `Thinking (${this.getActiveModel()}) ${elapsed}s`,
          intentType: 'general',
        });
      }, 5000);
    }

    try {
      for (let attempt = 1; attempt <= this.maxRetries + 1; attempt++) {
        try {
          return await this.api.chat(apiMessages, tools);
        } catch (error: unknown) {
          this.handleApiError(error);
          if (attempt <= this.maxRetries) {
            await this.delay(this.retryDelaySeconds * attempt * 1000);
            continue;
          }
          throw error;
        }
      }
    } finally {
      if (progressTimer) clearInterval(progressTimer);
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

    for (let attempt = 1; attempt <= this.maxRetries + 1; attempt++) {
      try {
        const generator = this.api.chatStreamGenerator(apiMessages, tools);
        let hasToolCalls = false;

        for await (const event of generator) {
          switch (event.type) {
            case 'content':
              accumulatedContent += event.data;
              onChunk(event.data);
              break;
            case 'reasoning':
              if (onReasoning) onReasoning(event.data);
              break;
            case 'tool_call':
              hasToolCalls = true;
              onToolCall?.(event.data.tool, event.data.arguments, event.data.id);
              break;
            case 'error':
              throw new Error(event.data);
            case 'done':
              break;
          }
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
        this.handleApiError(error);
        if (attempt <= this.maxRetries) {
          await this.delay(this.retryDelaySeconds * attempt * 1000);
          continue;
        }
        if (!accumulatedContent) throw error;
        return accumulatedContent;
      }
    }

    return accumulatedContent;
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
    const msg = this.getErrorMessage(error).toLowerCase();
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

  private maybeIncreaseContext(_requiredTokens: number): void {
    if (!this.adaptiveContextEnabled) return;
    // Adaptive context is disabled by default
  }

  private maybeIncreaseContextForPrompt(_prompt: string, _system?: string): void {
    if (!this.adaptiveContextEnabled) return;
  }

  private maybeIncreaseContextForMessages(_messages: Array<{ role: string; content: string | ApiContentPart[] }>): void {
    if (!this.adaptiveContextEnabled) return;
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
}
