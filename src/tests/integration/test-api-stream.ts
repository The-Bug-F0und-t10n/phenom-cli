import { ApiClient } from '../../api-client.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(`Assertion failed: ${msg}`);
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
