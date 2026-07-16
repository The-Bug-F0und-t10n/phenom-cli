import { ApiClient } from '../../api-client.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(`Assertion failed: ${msg}`);
}

function setBackendKind(kind: 'llama-server' | 'ollama' | 'unknown') {
  (ApiClient as any).setCachedBackendKind(kind);
}

function makeResponseFromChunks(chunks: string[]): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) {
        controller.enqueue(encoder.encode(chunk));
      }
      controller.close();
    }
  });

  return new Response(stream, {
    status: 200,
    headers: { 'Content-Type': 'text/event-stream' },
  });
}

test('chatStreamGenerator parses OpenAI-compatible SSE', async () => {
  const originalFetch = globalThis.fetch;
  setBackendKind('unknown');

  const sse = [
    'data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}\n',
    'data: [DONE]\n',
  ];

  globalThis.fetch = async () => makeResponseFromChunks(sse);

  try {
    const api = new ApiClient();
    const events: Array<{ type: string; data: any }> = [];

    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'hi' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }

    const content = events.filter(e => e.type === 'content').map(e => e.data).join('');
    const doneCount = events.filter(e => e.type === 'done').length;

    assert(content === 'Hello', `expected content Hello, got ${content}`);
    assert(doneCount === 1, `expected done once, got ${doneCount}`);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('chatStreamGenerator parses Ollama NDJSON stream', async () => {
  const originalFetch = globalThis.fetch;
  setBackendKind('unknown');

  const ndjson = [
    '{"model":"qwen","message":{"role":"assistant","content":"Oi"},"done":false}\n',
    '{"model":"qwen","message":{"role":"assistant","content":"!"},"done":false}\n',
    '{"model":"qwen","done":true,"prompt_eval_count":8,"eval_count":2}\n',
  ];

  globalThis.fetch = async () => makeResponseFromChunks(ndjson);

  try {
    const api = new ApiClient();
    const events: Array<{ type: string; data: any }> = [];

    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'ola' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }

    const content = events.filter(e => e.type === 'content').map(e => e.data).join('');
    const doneCount = events.filter(e => e.type === 'done').length;

    assert(content === 'Oi!', `expected content Oi!, got ${content}`);
    assert(doneCount === 1, `expected done once, got ${doneCount}`);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('chatStreamGenerator normalizes inline Qwen tool-call blocks', async () => {
  const originalFetch = globalThis.fetch;
  setBackendKind('unknown');
  // The generator should not semantically rewrite model output, but it must
  // structurally parse the model-native protocol markers. <tool_call> is a
  // tool event, not visible assistant content.
  const sse = [
    'data: {"choices":[{"delta":{"content":"<tool_"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{"content":"call>{\\"name\\":\\"read_file\\",\\"arguments\\":{\\"path\\":\\"a.ts\\"}}</tool_call>"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n',
    'data: [DONE]\n',
  ];
  globalThis.fetch = async () => makeResponseFromChunks(sse);
  try {
    const api = new ApiClient();
    const events: Array<{ type: string; data: any }> = [];
    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'go' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }
    const content = events.filter(e => e.type === 'content').map(e => e.data).join('');
    const toolCalls = events.filter(e => e.type === 'tool_call').map(e => e.data);
    assert(content === '', `tool protocol leaked as content: ${JSON.stringify(content)}`);
    assert(toolCalls.length === 1, `expected one tool_call, got ${JSON.stringify(toolCalls)}`);
    assert(toolCalls[0].tool === 'read_file', `wrong tool: ${JSON.stringify(toolCalls[0])}`);
    assert(toolCalls[0].arguments.path === 'a.ts', `wrong args: ${JSON.stringify(toolCalls[0])}`);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('chatStreamGenerator separates inline Qwen thinking from final content', async () => {
  const originalFetch = globalThis.fetch;
  setBackendKind('llama-server');

  const sse = [
    'data: {"choices":[{"delta":{"content":"<think>pla"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{"content":"n</think>Oi"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n',
    'data: [DONE]\n',
  ];

  globalThis.fetch = async () => makeResponseFromChunks(sse);

  try {
    const api = new ApiClient();
    const events: Array<{ type: string; data: any }> = [];
    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'ola' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }

    const reasoning = events.filter(e => e.type === 'reasoning').map(e => e.data).join('');
    const content = events.filter(e => e.type === 'content').map(e => e.data).join('');
    assert(reasoning === 'plan', `expected reasoning plan, got ${JSON.stringify(reasoning)}`);
    assert(content === 'Oi', `expected content Oi, got ${JSON.stringify(content)}`);
  } finally {
    setBackendKind('unknown');
    globalThis.fetch = originalFetch;
  }
});

test('chatStreamGenerator fails fast on malformed tool-call payload line', async () => {
  const originalFetch = globalThis.fetch;
  setBackendKind('unknown');

  const sse = [
    'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"write_file","arguments":"{\\"path\\":\\"a.ts\\""}}]},"finish_reason":null}]}\n',
  ];

  globalThis.fetch = async () => makeResponseFromChunks(sse);
  process.env.PHENOM_STRICT_TOOL_STREAM = '1';

  try {
    const api = new ApiClient();
    const events: Array<{ type: string; data: any }> = [];

    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'hi' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }

    const err = events.find(e => e.type === 'error');
    assert(!!err, `expected error event for malformed tool payload, got: ${JSON.stringify(events)}`);
    const msg = String(err!.data);
    assert(msg.includes('tool payload') || msg.includes('tool arguments'), `unexpected error message: ${msg}`);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('chatStreamGenerator uses native Ollama route when backend is Ollama', async () => {
  const originalFetch = globalThis.fetch;
  const urls: string[] = [];
  setBackendKind('ollama');

  const ndjson = [
    '{"message":{"content":"<think>plan</think>Oi"},"done":false}\n',
    '{"done":true,"prompt_eval_count":8,"eval_count":2}\n',
  ];

  globalThis.fetch = async (url: any) => {
    urls.push(String(url));
    return makeResponseFromChunks(ndjson);
  };

  try {
    const api = new ApiClient();
    const events: Array<{ type: string; data: any }> = [];
    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'ola' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }

    assert(urls.some(u => u.endsWith('/api/chat')), `expected /api/chat, got ${urls.join(', ')}`);
    assert(!urls.some(u => u.endsWith('/v1/chat/completions')), `did not expect /v1 route, got ${urls.join(', ')}`);
    const content = events.filter(e => e.type === 'content').map(e => e.data).join('');
    const reasoning = events.filter(e => e.type === 'reasoning').map(e => e.data).join('');
    assert(content === 'Oi', `expected content Oi, got ${content}`);
    assert(reasoning === 'plan', `expected reasoning plan, got ${reasoning}`);
  } finally {
    setBackendKind('unknown');
    globalThis.fetch = originalFetch;
  }
});

test('chatStreamGenerator uses llama.cpp compat route when backend is llama-server', async () => {
  const originalFetch = globalThis.fetch;
  const calls: Array<{ url: string; body: any }> = [];
  setBackendKind('llama-server');

  const sse = [
    'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}\n',
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}\n',
    'data: [DONE]\n',
  ];

  globalThis.fetch = async (url: any, init: any) => {
    calls.push({ url: String(url), body: JSON.parse(String(init?.body || '{}')) });
    return makeResponseFromChunks(sse);
  };

  try {
    const api = new ApiClient();
    api.setThink(true);
    const events: Array<{ type: string; data: any }> = [];
    for await (const ev of api.chatStreamGenerator([{ role: 'user', content: 'hi' } as any])) {
      events.push({ type: ev.type, data: ev.data });
    }

    assert(calls.some(c => c.url.endsWith('/v1/chat/completions')), `expected /v1 route, got ${calls.map(c => c.url).join(', ')}`);
    assert(!calls.some(c => c.url.endsWith('/api/chat')), `did not expect /api/chat, got ${calls.map(c => c.url).join(', ')}`);
    const body = calls.find(c => c.url.endsWith('/v1/chat/completions'))?.body || {};
    assert(body.chat_template_kwargs?.enable_thinking === true, 'expected enable_thinking=true for llama-server');
    const content = events.filter(e => e.type === 'content').map(e => e.data).join('');
    assert(content === 'ok', `expected content ok, got ${content}`);
  } finally {
    setBackendKind('unknown');
    globalThis.fetch = originalFetch;
  }
});

async function main() {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (error: any) {
      failures++;
      console.log(`  ❌ ${name}`);
      console.log(`     ${error.message}`);
    }
  }

  console.log(`\nApi stream tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
