// Verifies the CliRenderer raw-stdin parser handles arrow keys correctly even
// when the escape sequence is split across stdin reads. The historical bug:
// pressing ↑ during inference would cancel it because a lone `\x1b` arrived
// in one chunk and `[A` in the next — the lone-ESC branch fired
// INFERENCE_CANCEL before the tail showed up.
//
// We can't drive the real CliRenderer end-to-end here (it expects a TTY + alt
// screen), so this test exercises the same parser semantics by simulating the
// listener: a class that holds the same pendingEsc/timer state machine, fed
// the same byte streams.

import { eventBus, EventType } from '../../tui/event-bus.js';
import { CliRenderer } from '../../cli-renderer.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];
function test(name: string, fn: () => Promise<void> | void): void { tests.push({ name, fn }); }
function assert(cond: boolean, msg: string): void { if (!cond) throw new Error(msg); }

// We reach into the private parser by constructing a renderer instance, then
// calling consumeInputData via `any`. The renderer doesn't need attach() to
// parse — attach() only wires stdin and screen state.
function makeRenderer(): { rdr: any; consumed: () => string; cancelCount: () => number; setHistory: (h: string[]) => void } {
  const rdr: any = new CliRenderer();
  // Avoid any side effects from refreshStatus during tests.
  rdr.refreshStatus = () => {};
  rdr.startWaveAnimation = () => {};
  rdr.drawFixedPrompt = () => {};
  // Stub historyDraft so navigateHistory doesn't rely on render state.
  let cancels = 0;
  const unsub = eventBus.on(EventType.INFERENCE_CANCEL, () => { cancels++; });
  return {
    rdr,
    consumed: () => rdr.promptBuffer as string,
    cancelCount: () => cancels,
    setHistory: (h: string[]) => { rdr.inputHistory = h.slice(); rdr.historyIndex = -1; },
    // @ts-ignore — keep unsub reachable for cleanup
    __unsub: unsub
  } as any;
}

async function sleep(ms: number): Promise<void> { return new Promise(r => setTimeout(r, ms)); }

test('whole CSI in one chunk: ↑ navigates history, no cancel', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1b[A');
  await sleep(0);
  assert(env.consumed() === 'second', `expected promptBuffer 'second', got '${env.consumed()}'`);
  assert(env.cancelCount() === 0, `unexpected cancel fired ${env.cancelCount()} times`);
});

test('split between ESC and [A: ↑ still navigates, no cancel', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1b');
  // Cancel must NOT have fired yet; pendingEsc is holding.
  assert(env.cancelCount() === 0, `cancel fired prematurely on lone ESC`);
  env.rdr.consumeInputData('[A');
  await sleep(0);
  assert(env.consumed() === 'second', `expected 'second' after split, got '${env.consumed()}'`);
  assert(env.cancelCount() === 0, `cancel fired on a split CSI`);
});

test('split between ESC[ and A: still parses as ↑', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1b[');
  assert(env.cancelCount() === 0, `cancel fired on incomplete CSI prefix`);
  env.rdr.consumeInputData('A');
  await sleep(0);
  assert(env.consumed() === 'second', `expected 'second' after CSI-tail split, got '${env.consumed()}'`);
  assert(env.cancelCount() === 0, `cancel fired on a split CSI tail`);
});

test('real lone Esc: cancel fires after the flush timer', async () => {
  const env = makeRenderer();
  env.setHistory(['x']);
  env.rdr.consumeInputData('\x1b');
  // Before the timer: no cancel yet
  assert(env.cancelCount() === 0, `cancel fired before flush window elapsed`);
  // Wait beyond ESC_FLUSH_MS (100ms in source)
  await sleep(160);
  assert(env.cancelCount() === 1, `expected exactly one cancel, got ${env.cancelCount()}`);
  // promptBuffer should NOT have shifted to history
  assert(env.consumed() !== 'x', `lone Esc accidentally navigated history`);
});

test('SS3 (DECCKM) whole: \\x1bOA navigates history, no cancel, no leaked text', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1bOA');
  await sleep(0);
  assert(env.consumed() === 'second', `expected 'second', got '${env.consumed()}'`);
  assert(env.cancelCount() === 0, `cancel fired on SS3 ↑`);
});

test('SS3 split between ESC and OA: still parses as ↑', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1b');
  env.rdr.consumeInputData('OA');
  await sleep(0);
  assert(env.consumed() === 'second', `expected 'second' after split SS3, got '${env.consumed()}'`);
  assert(env.cancelCount() === 0, `cancel fired on split SS3`);
});

test('SS3 split between ESCO and A: still parses as ↑', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1bO');
  assert(env.cancelCount() === 0, `cancel fired on incomplete SS3 prefix`);
  env.rdr.consumeInputData('A');
  await sleep(0);
  assert(env.consumed() === 'second', `expected 'second' after SS3-tail split, got '${env.consumed()}'`);
  assert(env.cancelCount() === 0, `cancel fired on split SS3 tail`);
});

test('SS3 ↓ in DECCKM mode also works', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1bOA'); // up
  env.rdr.consumeInputData('\x1bOB'); // down
  await sleep(0);
  assert(env.consumed() === '', `expected empty draft after ↑↓, got '${env.consumed()}'`);
});

test('↓ after ↑ returns to draft', async () => {
  const env = makeRenderer();
  env.setHistory(['second', 'first']);
  env.rdr.consumeInputData('\x1b[A');
  assert(env.consumed() === 'second', `up failed`);
  env.rdr.consumeInputData('\x1b[B');
  await sleep(0);
  assert(env.consumed() === '', `down should return to empty draft, got '${env.consumed()}'`);
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (e: any) {
      failures++;
      console.log(`  ❌ ${name}: ${e.message}`);
    }
  }
  console.log(`\nCLI input CSI tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
