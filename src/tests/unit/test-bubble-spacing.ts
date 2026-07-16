/**
 * Verifies the actual bytes written to stdout between the user bubble and
 * the start of assistant streaming. The user reports more than 1 blank line
 * below "[user] query"; this test captures the truth.
 */
import { CliRenderer } from '../../cli-renderer.js';
import { eventBus, EventType } from '../../tui/event-bus.js';

function stripAnsi(s: string): string {
  // Strip CSI sequences (\x1b[...letter), DCS, OSC, etc.
  return s
    .replace(/\x1b\[[\?0-9;]*[A-Za-z]/g, '')
    .replace(/\x1b\][^\x07]*\x07/g, '')
    .replace(/\x1b[=>]/g, '');
}

function makeRenderer(): { renderer: any; writes: string[] } {
  eventBus.clear();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 80,
    rows: 30,
    write: (chunk: any) => {
      writes.push(String(chunk));
      return true;
    },
    on: () => {},
  };
  const renderer: any = new CliRenderer();
  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.altScreenActive = true; // bypass enterAltScreen guard
  renderer.attach();
  return { renderer, writes };
}

function joinWrites(writes: string[]): string {
  return writes.join('');
}

function captureBubbleToContentBytes(): string {
  const { writes } = makeRenderer();
  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'oi' });
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    // Simulate model emitting leading newlines BEFORE actual content
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: '\n\n\nHello world' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }
  return joinWrites(writes);
}

function captureSecondSubmitReplay(): string {
  const { renderer, writes } = makeRenderer();
  try {
    // First turn — bubble + assistant
    eventBus.emit(EventType.USER_MESSAGE, { content: 'first query' });
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: '\n\n\nFirst response' });
    eventBus.emit(EventType.THINK_END, {});
    // Clear capture — we only care about what rebuildViewport replays on the
    // SECOND submit.
    writes.length = 0;
    // Second turn — this triggers rebuildViewportFromHistory.
    eventBus.emit(EventType.USER_MESSAGE, { content: 'second query' });
  } finally {
    eventBus.clear();
  }
  void renderer; // referenced for lifecycle
  return joinWrites(writes);
}

function describeGap(bytes: string, anchor: string, lookAhead: string): string {
  const plain = stripAnsi(bytes);
  const idx = plain.indexOf(anchor);
  if (idx < 0) return `(anchor "${anchor}" not found)`;
  const afterAnchor = plain.slice(idx + anchor.length);
  const targetIdx = afterAnchor.indexOf(lookAhead);
  if (targetIdx < 0) return `(target "${lookAhead}" not found after anchor)`;
  const gap = afterAnchor.slice(0, targetIdx);
  const newlineCount = (gap.match(/\n/g) || []).length;
  return JSON.stringify(gap) + ` (newlines=${newlineCount})`;
}

function captureTrailingNewlines(): { writes: string[] } {
  const { renderer, writes } = makeRenderer();
  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'ola' });
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    // Model emits "Ola" followed by 15 trailing newlines (reproduces the
    // "16 blank rows below the response" bug the user reported).
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'Ola' + '\n'.repeat(15) });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }
  void renderer;
  return { writes };
}

// ── Test -1: countVisualLines must NOT overestimate the user bubble. ──
// Root cause of the "blanks below the bubble grow per turn" bug: the bubble
// is painted to width (cols - 1) but rebuildViewportFromHistory counted it
// against contentWrapWidth (cols - 2), so a single-line bubble entry
// ('\n' + bubble) was counted as 3 rows instead of 2. That phantom row per
// history entry accumulated as blank rows below the freshly submitted bubble.
console.log('── Test -1: bubble entry row-cost (must be 2, not 3) ──');
{
  const r: any = new CliRenderer();
  r.plain = false;
  r.rl = { output: { columns: 80, rows: 30, write: () => true, on: () => {} } };
  const entry = r.renderLayoutEntry('\n[user] ola');
  const cols = 80;
  const countAtPaintWidth = r.countVisualLines(entry, Math.max(1, cols - 1));
  const countAtContentWidth = r.countVisualLines(entry, r.contentWrapWidth(cols));
  console.log(`  cost @ paint width (cols-1): ${countAtPaintWidth} (expected 2)`);
  console.log(`  cost @ old width   (cols-2): ${countAtContentWidth} (was the bug if > 2)`);
  if (countAtPaintWidth !== 2) {
    console.error('  FAIL: bubble entry should cost exactly 2 rows at paint width');
    process.exitCode = 1;
  } else {
    console.log('  PASS');
  }
}

console.log('');
console.log('── Test 0: trailing newlines after short response ──');
const t0 = captureTrailingNewlines();
const joined = joinWrites(t0.writes);
const plain = stripAnsi(joined);
const olaIdx = plain.indexOf('Ola');
if (olaIdx >= 0) {
  const tail = plain.slice(olaIdx);
  const newlinesAfterOla = (tail.match(/\n/g) || []).length;
  console.log(`Newlines after "Ola" in emitted stream: ${newlinesAfterOla}`);
  console.log(`Tail (first 60 chars):`, JSON.stringify(tail.slice(0, 60)));
}

console.log('');
console.log('── Test 1: bytes between [user] bubble and first content char ──');
const t1 = captureBubbleToContentBytes();
console.log('Captured bytes (length):', t1.length);
console.log('Plain visible chars between "oi" and "Hello":');
console.log('  ', describeGap(t1, 'oi', 'Hello'));

console.log('');
console.log('── Test 2: rebuildViewport on second submit (history replay) ──');
const t2 = captureSecondSubmitReplay();
console.log('Captured bytes (length):', t2.length);
console.log('Plain visible chars between "First response" and "second query":');
console.log('  ', describeGap(t2, 'First response', 'second query'));
console.log('Plain visible chars between "first query" and "First response":');
console.log('  ', describeGap(t2, 'first query', 'First response'));

// ── Test 3: thinking wrap must respect width across fragmented chunks ──
// Reasoning arrives in many small chunks with no newlines. Each chunk
// continues the current visual line. The wrap must account for the running
// column so no thinking line exceeds the terminal width (which would make
// the terminal hard-wrap it past the "│ " gutter, outside the block).
console.log('');
console.log('── Test 3: thinking line width on narrow screen (cols=40) ──');
{
  eventBus.clear();
  const writes: string[] = [];
  const cols = 40;
  const fakeOutput: any = {
    columns: cols,
    rows: 24,
    write: (c: any) => { writes.push(String(c)); return true; },
    on: () => {},
  };
  const r: any = new CliRenderer();
  r.plain = false;
  r.rl = { output: fakeOutput };
  r.altScreenActive = true;
  r.attach();
  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    // Feed a long reasoning sentence as many tiny no-newline fragments.
    const sentence = 'The user is just saying ola repeatedly which is a short social message so I should reply with one short sentence no lists no emojis';
    for (const word of sentence.split(' ')) {
      eventBus.emit(EventType.REASONING_CHUNK, { chunk: word + ' ' });
    }
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }
  // Reconstruct visible rows: split the emitted stream on newlines, strip ANSI.
  const joined3 = joinWrites(writes);
  // Take only what was written inside the scroll region (rough: split on \n).
  const rows = stripAnsi(joined3).split('\n');
  // A correctly-wrapped thinking line never exceeds cols visible chars.
  let maxLen = 0;
  let offending = '';
  for (const row of rows) {
    // Ignore the status/visualizer/prompt rows (they contain ▁ or '>').
    if (row.includes('▁') || row.trimStart().startsWith('>')) continue;
    if (row.length > maxLen) { maxLen = row.length; offending = row; }
  }
  console.log(`  cols=${cols}; widest thinking/content row = ${maxLen}`);
  if (maxLen > cols) {
    console.error(`  FAIL: a row exceeds ${cols} cols (would hard-wrap past the gutter): ${JSON.stringify(offending)}`);
    process.exitCode = 1;
  } else {
    console.log('  PASS');
  }
}

// ── Test 4: thinking re-wraps on RESIZE (wide → narrow) ──
// Thinking is streamed at a wide width, then the terminal shrinks and a
// reflow rebuilds the viewport from history. The persisted thinking must
// re-wrap at the new (narrow) width, not replay the baked-in wide wrap.
console.log('');
console.log('── Test 4: thinking re-wraps on resize (120 → 40) ──');
{
  eventBus.clear();
  const out: any = {
    columns: 120,
    rows: 24,
    write: () => true,
    on: () => {},
  };
  const r: any = new CliRenderer();
  r.plain = false;
  r.rl = { output: out };
  r.altScreenActive = true;
  r.attach();
  const longLine = 'The user is just saying ola repeatedly which is a short social message so I should reply with one short sentence no lists no emojis no tool calls at all whatsoever';
  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: longLine });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }
  // Now shrink the terminal and reflow from history.
  out.columns = 40;
  const narrowCaptured: string[] = [];
  out.write = (c: any) => { narrowCaptured.push(String(c)); return true; };
  r.rebuildViewportFromHistory();
  const rows4 = stripAnsi(narrowCaptured.join('')).split('\n');
  let maxLen4 = 0;
  let offending4 = '';
  for (const row of rows4) {
    if (row.includes('▁') || row.trimStart().startsWith('>')) continue;
    if (row.length > maxLen4) { maxLen4 = row.length; offending4 = row; }
  }
  console.log(`  after resize to 40: widest row = ${maxLen4}`);
  if (maxLen4 > 40) {
    console.error(`  FAIL: thinking did not re-wrap on resize: ${JSON.stringify(offending4)}`);
    process.exitCode = 1;
  } else {
    console.log('  PASS');
  }
}
