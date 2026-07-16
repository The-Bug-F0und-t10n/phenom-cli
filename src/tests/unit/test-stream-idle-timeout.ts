// Regression: chatStreamGenerator's reader.read() loop had no deadline once
// headers arrived. A silent server (no bytes flowing) hung the agent for
// hours. PHENOM_STREAM_IDLE_TIMEOUT_MS now caps idle gaps and yields an
// error so the tool loop can recover.

import { ApiClient } from '../../api-client.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

function silentBodyResponse(controller?: { onAbort?: () => void }): Response {
  // ReadableStream that never enqueues — emulates a server that opens the
  // connection, sends headers, then stops sending bytes (the 138-minute hang).
  const stream = new ReadableStream<Uint8Array>({
    start(streamController) {
      controller?.onAbort && (controller.onAbort = () => {
        try { streamController.close(); } catch {}
      });
    }
  });
  return new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

function patchFetchSilent(): { restore: () => void; lastSignal: AbortSignal | null } {
  const original = globalThis.fetch;
  const state: { lastSignal: AbortSignal | null } = { lastSignal: null };
  // @ts-ignore
  globalThis.fetch = async (_url: string, init?: any): Promise<Response> => {
    state.lastSignal = init?.signal || null;
    // Pipe abort into closing the stream body so reader.read() rejects.
    const stream = new ReadableStream<Uint8Array>({
      start(streamController) {
        const sig: AbortSignal | undefined = init?.signal;
        if (sig) {
          if (sig.aborted) { streamController.error(new DOMException('aborted', 'AbortError')); return; }
          sig.addEventListener('abort', () => {
            try { streamController.error(new DOMException('aborted', 'AbortError')); } catch {}
          }, { once: true });
        }
        // Otherwise never enqueue: the read promise hangs until abort.
      }
    });
    return new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
  };
  return { restore: () => { globalThis.fetch = original; }, get lastSignal() { return state.lastSignal; } } as any;
}

test('stream idle timeout aborts and yields recoverable idle event (not error)', async () => {
  process.env.OLLAMA_HOST = process.env.OLLAMA_HOST || 'http://test.local:11434';
  process.env.OLLAMA_CHAT_MODEL = process.env.OLLAMA_CHAT_MODEL || 'fake-model';
  // Tight idle window for the test (real default is 90s).
  const prevIdle = process.env.PHENOM_STREAM_IDLE_TIMEOUT_MS;
  process.env.PHENOM_STREAM_IDLE_TIMEOUT_MS = '300';

  const patch = patchFetchSilent();
  try {
    const api = new ApiClient();
    const gen = api.chatStreamGenerator([{ role: 'user', content: 'hi' }]);

    const events: any[] = [];
    const started = Date.now();
    for await (const ev of gen) {
      events.push(ev);
      if (events.length > 5) break; // safety stop
    }
    const elapsed = Date.now() - started;

    const idle = events.find(e => e.type === 'idle');
    assert(!!idle, `expected an 'idle' event for recoverable timeout, got: ${JSON.stringify(events)}`);
    assert(/idle timeout/i.test(String(idle.data)), `expected idle reason text, got: ${idle.data}`);
    // No 'error' event — idle is the recovery path, not a hard failure.
    assert(!events.some(e => e.type === 'error'), `should NOT emit 'error' on idle; got: ${JSON.stringify(events)}`);
    // Should fire within ~1s for a 300ms idle window.
    assert(elapsed < 2000, `idle timer too slow: ${elapsed}ms`);
  } finally {
    patch.restore();
    if (prevIdle === undefined) delete process.env.PHENOM_STREAM_IDLE_TIMEOUT_MS;
    else process.env.PHENOM_STREAM_IDLE_TIMEOUT_MS = prevIdle;
  }
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nStream idle timeout tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
