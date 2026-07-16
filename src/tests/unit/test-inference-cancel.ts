// Regression: pressing Esc/Ctrl-C must actually abort the in-flight model
// HTTP request. Previously INFERENCE_CANCEL only updated UI/TTS labels;
// the fetch kept running on the server. We monkey-patch global fetch to
// hang until aborted and verify the abort propagates.

import { eventBus, EventType } from '../../tui/event-bus.js';
import { ApiClient } from '../../api-client.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

function patchFetchHang(): { restore: () => void; signals: AbortSignal[] } {
  const original = globalThis.fetch;
  const signals: AbortSignal[] = [];
  // @ts-ignore — overriding for the test
  globalThis.fetch = (_url: string, init?: any): Promise<Response> => {
    return new Promise((_resolve, reject) => {
      const sig: AbortSignal | undefined = init?.signal;
      if (sig) {
        signals.push(sig);
        if (sig.aborted) {
          reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
          return;
        }
        sig.addEventListener('abort', () => {
          reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
        }, { once: true });
      }
      // Otherwise hang forever — caller MUST cancel us.
    });
  };
  return { restore: () => { globalThis.fetch = original; }, signals };
}

test('INFERENCE_CANCEL aborts in-flight chat fetch', async () => {
  process.env.OLLAMA_HOST = process.env.OLLAMA_HOST || 'http://test.local:11434';
  const patch = patchFetchHang();
  try {
    const api = new ApiClient();
    // Kick off a chat that will hang in fetch until we cancel.
    const promise = api.chat([{ role: 'user', content: 'hi' }]);
    // Give fetchWithTimeout a tick to register its controller.
    await new Promise(r => setTimeout(r, 10));
    eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'test' });
    let threw = false;
    try {
      await promise;
    } catch (e: any) {
      threw = true;
      const msg = String(e?.name || e?.message || '');
      assert(/abort/i.test(msg), `expected AbortError, got ${msg}`);
    }
    assert(threw, 'chat should have rejected after INFERENCE_CANCEL');
    assert(patch.signals.length > 0 && patch.signals[0].aborted, 'fetch signal must be aborted');
  } finally {
    patch.restore();
  }
});

test('cancel is a no-op when nothing is in flight', async () => {
  // Just ensure the static cancel does not throw or hang.
  ApiClient.cancelInflight();
  ApiClient.cancelInflight();
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nInference cancel tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
