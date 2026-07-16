// Verifies that ApiClient pulls REAL prompt token counts from llama-server's
// /tokenize endpoint and emits them via TOKEN_UPDATE BEFORE the stream
// opens. Without this the UI shows a chars/3 estimate for the entire
// prompt-eval phase (which is often 30s+ on a large prompt).
//
// Also verifies cached-token surfacing (llama.cpp prompt cache hits).

import { ApiClient } from '../../api-client.js';
import { eventBus, EventType } from '../../tui/event-bus.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

interface FetchCall { url: string; init?: any }

function patchFetch(handler: (url: string, init?: any) => Promise<Response>): { restore: () => void; calls: FetchCall[] } {
  const original = globalThis.fetch;
  const calls: FetchCall[] = [];
  // @ts-ignore
  globalThis.fetch = async (url: string, init?: any): Promise<Response> => {
    calls.push({ url: String(url), init });
    return handler(String(url), init);
  };
  return { restore: () => { globalThis.fetch = original; }, calls };
}

function resetTokenizeProbeCache(): void {
  // ApiClient.tokenizeSupported is `private static` — for tests we reset it
  // via a typed any cast so subsequent tests don't see leaked state.
  (ApiClient as any).tokenizeSupported = null;
}

function tokenUpdateCollector(): { events: any[]; unsub: () => void } {
  const events: any[] = [];
  const unsub = eventBus.on(EventType.TOKEN_UPDATE, (ev) => events.push(ev.payload));
  return { events, unsub };
}

test('tokenizeRequest returns exact count from llama-server /tokenize', async () => {
  resetTokenizeProbeCache();
  process.env.OLLAMA_HOST = process.env.OLLAMA_HOST || 'http://test.local:11434';
  const patch = patchFetch(async (url) => {
    if (url.endsWith('/tokenize')) {
      // Real /tokenize returns the array of token IDs. Length is the count.
      return new Response(JSON.stringify({ tokens: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] }),
        { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    return new Response('', { status: 404 });
  });
  try {
    const api = new ApiClient();
    const got = await api.tokenizeRequest([{ role: 'user', content: 'hi' }]);
    assert(got === 10, `expected 10, got ${got}`);
    assert(patch.calls.some(c => c.url.endsWith('/tokenize')), '/tokenize was not called');
  } finally {
    patch.restore();
  }
});

test('tokenizeRequest returns null and caches when /tokenize 404s (Ollama backend)', async () => {
  resetTokenizeProbeCache();
  const patch = patchFetch(async () => new Response('not found', { status: 404 }));
  try {
    const api = new ApiClient();
    const first = await api.tokenizeRequest([{ role: 'user', content: 'hi' }]);
    assert(first === null, `expected null on 404, got ${first}`);
    // Second call must short-circuit via cached `false` without a new fetch.
    const callsBefore = patch.calls.length;
    const second = await api.tokenizeRequest([{ role: 'user', content: 'again' }]);
    assert(second === null, `expected null on cached false, got ${second}`);
    assert(patch.calls.length === callsBefore, 'cached path made another fetch');
  } finally {
    patch.restore();
  }
});

test('resolveInputTokenCount uses /tokenize when available (exact=true)', async () => {
  resetTokenizeProbeCache();
  const patch = patchFetch(async (url) => {
    if (url.endsWith('/tokenize')) {
      return new Response(JSON.stringify({ tokens: new Array(42).fill(0) }), { status: 200 });
    }
    return new Response('', { status: 404 });
  });
  try {
    const api = new ApiClient();
    const got = await api.resolveInputTokenCount([{ role: 'user', content: 'whatever' }]);
    assert(got.exact === true, `expected exact=true, got ${got.exact}`);
    assert(got.count === 42, `expected 42, got ${got.count}`);
  } finally {
    patch.restore();
  }
});

test('resolveInputTokenCount falls back to chars/3 estimate when /tokenize unavailable', async () => {
  resetTokenizeProbeCache();
  const patch = patchFetch(async () => new Response('', { status: 404 }));
  try {
    const api = new ApiClient();
    // Drain the probe so the fallback path is sticky for the next call.
    await api.tokenizeRequest([{ role: 'user', content: 'x' }]);
    const got = await api.resolveInputTokenCount([{ role: 'user', content: 'a'.repeat(30) }]);
    assert(got.exact === false, `expected exact=false on fallback, got ${got.exact}`);
    // Estimate is chars/3, but includes overhead from `serializeForTokenize`
    // (role prefix etc). We just assert it's in the right ballpark.
    assert(got.count > 5 && got.count < 30, `unexpected estimate ${got.count}`);
  } finally {
    patch.restore();
  }
});

test('TOKEN_UPDATE includes exact:true and cached:N when usage carries cached_tokens', async () => {
  resetTokenizeProbeCache();
  process.env.OLLAMA_CHAT_MODEL = process.env.OLLAMA_CHAT_MODEL || 'fake';
  const patch = patchFetch(async (url) => {
    if (url.endsWith('/tokenize')) {
      return new Response(JSON.stringify({ tokens: new Array(15).fill(0) }), { status: 200 });
    }
    if (url.endsWith('/v1/chat/completions')) {
      return new Response(JSON.stringify({
        choices: [{ message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
        usage: {
          prompt_tokens: 15,
          completion_tokens: 1,
          prompt_tokens_details: { cached_tokens: 12 }
        }
      }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    return new Response('', { status: 404 });
  });
  const collector = tokenUpdateCollector();
  try {
    const api = new ApiClient();
    await api.chat([{ role: 'user', content: 'hi' }]);
    // Two TOKEN_UPDATEs: one pre-stream (exact via /tokenize), one final.
    assert(collector.events.length >= 2, `expected ≥2 TOKEN_UPDATE, got ${collector.events.length}`);
    const final = collector.events[collector.events.length - 1];
    assert(final.input === 15, `expected input=15, got ${final.input}`);
    assert(final.exact === true, `expected exact=true, got ${final.exact}`);
    assert(final.cached === 12, `expected cached=12, got ${final.cached}`);
  } finally {
    collector.unsub();
    patch.restore();
  }
});

test('chatStreamGenerator emits real tok/s from native eval_count/eval_duration', async () => {
  resetTokenizeProbeCache();
  const patch = patchFetch(async (url) => {
    if (url.endsWith('/tokenize')) {
      // Mark /tokenize unsupported so this path relies on native metrics.
      return new Response('not found', { status: 404 });
    }
    if (url.endsWith('/v1/chat/completions')) {
      // Force native fallback path.
      return new Response('not found', { status: 404 });
    }
    if (url.endsWith('/api/chat')) {
      const encoder = new TextEncoder();
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encoder.encode('{"message":{"content":"ok"},"done":false}\n'));
          controller.enqueue(encoder.encode('{"done":true,"prompt_eval_count":10,"eval_count":20,"eval_duration":2000000000}\n'));
          controller.close();
        }
      });
      return new Response(stream, { status: 200, headers: { 'Content-Type': 'application/x-ndjson' } });
    }
    return new Response('', { status: 404 });
  });

  const collector = tokenUpdateCollector();
  try {
    const api = new ApiClient();
    for await (const _ev of api.chatStreamGenerator([{ role: 'user', content: 'hi' }])) {
      // Drain stream events.
    }
    assert(collector.events.length >= 2, `expected >=2 TOKEN_UPDATE events, got ${collector.events.length}`);
    const final = collector.events[collector.events.length - 1];
    assert(final.output === 20, `expected output=20 from eval_count, got ${final.output}`);
    const tps = Number(final.tokensPerSecond);
    assert(Number.isFinite(tps), `expected finite tokensPerSecond, got ${final.tokensPerSecond}`);
    assert(tps > 9.9 && tps < 10.1, `expected ~10 tok/s, got ${tps}`);
  } finally {
    collector.unsub();
    patch.restore();
  }
});

test('calculateTokensPerSecond handles microsecond durations from compat bridges', async () => {
  const api: any = new ApiClient();
  // 20 tokens over 2s, duration provided in microseconds.
  const tps = api.calculateTokensPerSecond({
    tokens: 20,
    durationNs: 2_000_000, // µs
    startedAtMs: null,
    endedAtMs: Date.now()
  });
  assert(tps !== null, 'expected non-null tps');
  assert(tps! > 9.9 && tps! < 10.1, `expected ~10 tok/s, got ${tps}`);
});

test('calculateTokensPerSecond suppresses ultra-short fallback windows', async () => {
  const api: any = new ApiClient();
  const now = Date.now();
  const tps = api.calculateTokensPerSecond({
    tokens: 1,
    durationNs: null,
    startedAtMs: now - 1, // 1 ms would previously show 1000 tok/s
    endedAtMs: now
  });
  assert(tps === null, `expected null for short window, got ${tps}`);
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nReal token counting tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
