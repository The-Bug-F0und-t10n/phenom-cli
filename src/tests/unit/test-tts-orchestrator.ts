/**
 * Flow test for the TTS orchestration. Mocks the HTTP player + narrator
 * callback so we can verify the event sequence end-to-end without
 * touching the network or the audio device:
 *
 *   USER_MESSAGE      → speakIntro called (when enabled, not greeting/command)
 *   AGENT_FINAL...    → narrate called → speak called with narration
 *   /tts off          → no speak even on subsequent events
 *   /speak (repeat)   → re-uses last narration
 *   INFERENCE_CANCEL  → stop called
 *   missing narrator  → fallback first-sentence path
 *
 * Why this test matters: the TTS pipeline crosses 4 modules (event bus,
 * orchestrator, player, narrator). A regression in any of those silently
 * breaks audio for the user — there's no error surfaced. This test
 * locks the orchestration contract so refactors notice immediately.
 */
import assert from 'assert';
import { TtsOrchestrator } from '../../tts/index.js';
import { eventBus, EventType } from '../../tui/event-bus.js';

interface SpeakLog {
  text: string;
  at: number;
}

interface FakePlayer {
  speak: (text: string) => Promise<void>;
  stop: () => void;
  cleanup: () => Promise<void>;
  log: SpeakLog[];
  stopCount: number;
}

function makeFakePlayer(): FakePlayer {
  const log: SpeakLog[] = [];
  let stopCount = 0;
  return {
    log,
    get stopCount() { return stopCount; },
    speak: async (text: string) => { log.push({ text, at: Date.now() }); },
    stop: () => { stopCount++; },
    cleanup: async () => {}
  } as FakePlayer;
}

/**
 * Build an orchestrator pre-wired with a fake player. We monkey-patch the
 * private `player` field after construction — keeps the public API clean
 * (production code never sees the test fake) while letting us inspect
 * what was spoken.
 */
function makeOrchestrator(opts: {
  narration?: string | null;
  narrateThrows?: boolean;
  enabledByDefault?: boolean;
} = {}): { orch: TtsOrchestrator; fake: FakePlayer; narrateCalls: Array<{ full: string; query: string }> } {
  const fake = makeFakePlayer();
  const narrateCalls: Array<{ full: string; query: string }> = [];
  const narrate = opts.narration === undefined
    ? undefined
    : async (full: string, query: string): Promise<string> => {
        narrateCalls.push({ full, query });
        if (opts.narrateThrows) throw new Error('narrate failed');
        return opts.narration ?? '';
      };

  const orch = new TtsOrchestrator({
    endpoint: 'http://localhost:0/speak',  // unused (fake player)
    enabledByDefault: opts.enabledByDefault ?? true,
    narrate
  });

  // Replace the real player with the fake. Property is private; cast to
  // any solely for test access — the test file is the only place this
  // boundary is breached.
  (orch as unknown as { player: FakePlayer }).player = fake;
  orch.start();
  return { orch, fake, narrateCalls };
}

const tests: Array<{ name: string; fn: () => Promise<void> | void }> = [];
const test = (name: string, fn: () => Promise<void> | void): void => { tests.push({ name, fn }); };

// ── 1. Full happy path ────────────────────────────────────────────────

test('USER_MESSAGE + AGENT_FINAL_RESPONSE → intro + narration, in order', async () => {
  eventBus.clear();
  const { orch, fake, narrateCalls } = makeOrchestrator({ narration: 'Terminei o ajuste no parser.' });
  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'arruma esse bug no parser de tools' });
    // Yield so the optional-async intro speak resolves.
    await new Promise(r => setImmediate(r));

    eventBus.emit(EventType.AGENT_FINAL_RESPONSE, { content: 'Bug corrigido em src/parser.ts:42' });
    // Wait for the async narrate → speak chain.
    await new Promise(r => setTimeout(r, 20));

    assert(fake.log.length === 2, `expected 2 speak calls, got ${fake.log.length}: ${JSON.stringify(fake.log)}`);
    assert(fake.log[0].text && fake.log[0].text.length > 0, 'first call should be the intro (non-empty)');
    assert(fake.log[1].text === 'Terminei o ajuste no parser.', `narration mismatch: ${fake.log[1].text}`);
    assert(narrateCalls.length === 1, 'narrate callback called exactly once');
    assert(narrateCalls[0].query === 'arruma esse bug no parser de tools', 'query passed to narrate');
    assert(narrateCalls[0].full === 'Bug corrigido em src/parser.ts:42', 'full content passed to narrate');
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 2. Disabled state ─────────────────────────────────────────────────

test('disabled by default: no speak on either event', async () => {
  eventBus.clear();
  const { orch, fake, narrateCalls } = makeOrchestrator({
    narration: 'should not be spoken',
    enabledByDefault: false
  });
  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'qualquer pergunta longa aqui' });
    await new Promise(r => setImmediate(r));
    eventBus.emit(EventType.AGENT_FINAL_RESPONSE, { content: 'resposta' });
    await new Promise(r => setTimeout(r, 20));

    assert(fake.log.length === 0, `expected 0 speaks when disabled, got ${fake.log.length}`);
    // narrate STILL runs (to keep lastNarration up to date for /speak)
    // — only the actual speak is gated by `enabled`.
    assert(narrateCalls.length === 1, 'narrate runs even when disabled (so /speak can repeat it)');
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 3. Greetings + slash commands are silent ──────────────────────────

test('greetings and slash commands: no intro spoken', async () => {
  eventBus.clear();
  const { orch, fake } = makeOrchestrator({ narration: 'x' });
  try {
    for (const greeting of ['ola', 'oi', 'hi', 'hello', 'bom dia']) {
      eventBus.emit(EventType.USER_MESSAGE, { content: greeting });
      await new Promise(r => setImmediate(r));
    }
    eventBus.emit(EventType.USER_MESSAGE, { content: '/tts on' });
    await new Promise(r => setImmediate(r));

    assert(fake.log.length === 0, `greetings + commands should not speak; got ${JSON.stringify(fake.log)}`);
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 4. /speak repeat ──────────────────────────────────────────────────

test('repeat() replays the last narration', async () => {
  eventBus.clear();
  const { orch, fake } = makeOrchestrator({ narration: 'Resumo da última resposta.' });
  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'pergunta substancial qualquer' });
    eventBus.emit(EventType.AGENT_FINAL_RESPONSE, { content: 'resposta' });
    await new Promise(r => setTimeout(r, 20));

    const before = fake.log.length;
    orch.repeat();
    await new Promise(r => setImmediate(r));

    assert(fake.log.length === before + 1, 'repeat triggers one additional speak');
    assert(fake.log[fake.log.length - 1].text === 'Resumo da última resposta.', 'repeats the narration');
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 5. INFERENCE_CANCEL stops the player ──────────────────────────────

test('INFERENCE_CANCEL calls player.stop', async () => {
  eventBus.clear();
  const { orch, fake } = makeOrchestrator({ narration: 'x' });
  try {
    const before = fake.stopCount;
    eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'user esc' });
    await new Promise(r => setImmediate(r));
    assert(fake.stopCount === before + 1, 'stop called once on cancel');
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 6. No narrator → fallback first sentence ──────────────────────────

test('no narrate callback: falls back to first sentence of stripped content', async () => {
  eventBus.clear();
  // narration: undefined → no narrate wired
  const { orch, fake } = makeOrchestrator({});
  try {
    eventBus.emit(EventType.AGENT_FINAL_RESPONSE, {
      content: 'Encontrei o bug. O cache não invalida quando o token expira. Vou ajustar.'
    });
    await new Promise(r => setTimeout(r, 20));

    assert(fake.log.length === 1, `expected 1 speak from fallback, got ${fake.log.length}`);
    assert(
      fake.log[0].text.startsWith('Encontrei o bug.'),
      `fallback should pick first sentence; got: ${fake.log[0].text}`
    );
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 7. Narrator throws → fallback path still runs ─────────────────────

test('narrator throws: still speaks something via fallback', async () => {
  eventBus.clear();
  const { orch, fake } = makeOrchestrator({ narration: 'unused', narrateThrows: true });
  try {
    eventBus.emit(EventType.AGENT_FINAL_RESPONSE, { content: 'Primeira frase aqui. Segunda parte.' });
    await new Promise(r => setTimeout(r, 20));

    assert(fake.log.length === 1, `expected fallback speak when narrator throws, got ${fake.log.length}`);
    assert(
      fake.log[0].text.startsWith('Primeira frase'),
      `fallback should still produce output; got: ${fake.log[0].text}`
    );
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── 8. setEnabled live toggle ─────────────────────────────────────────

test('setEnabled(false) silences subsequent events', async () => {
  eventBus.clear();
  const { orch, fake } = makeOrchestrator({ narration: 'frase' });
  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'pergunta substancial' });
    await new Promise(r => setImmediate(r));
    const introSpeaks = fake.log.length;
    assert(introSpeaks >= 1, 'baseline: intro spoken while enabled');

    orch.setEnabled(false);
    eventBus.emit(EventType.AGENT_FINAL_RESPONSE, { content: 'qualquer resposta' });
    await new Promise(r => setTimeout(r, 20));

    assert(
      fake.log.length === introSpeaks,
      `disabling mid-turn should suppress the narration speak; got ${fake.log.length - introSpeaks} extra`
    );
  } finally {
    await orch.stop();
    eventBus.clear();
  }
});

// ── Runner ────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  let passed = 0;
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
      console.log(`  ✅ ${t.name}`);
      passed++;
    } catch (err: any) {
      console.log(`  ❌ ${t.name}`);
      console.log(`     ${err?.message || err}`);
      failed++;
    }
  }
  console.log(`\nTts orchestrator tests: ${passed}/${tests.length} passaram`);
  if (failed > 0) process.exit(1);
}

main();
