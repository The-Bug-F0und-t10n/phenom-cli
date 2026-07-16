// Verifies TraceLogger writes well-formed JSONL on emitted events and
// truncates oversized payloads. Uses a temp cwd so it doesn't pollute the
// real project trace.

import os from 'os';
import path from 'path';
import { promises as fs } from 'fs';
import { eventBus, EventType } from '../../tui/event-bus.js';
import { TraceLogger } from '../../trace-logger.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }
async function sleep(ms: number): Promise<void> { return new Promise(r => setTimeout(r, ms)); }

async function readLog(p: string): Promise<any[]> {
  // Give the WriteStream a tick to flush.
  await sleep(20);
  const raw = await fs.readFile(p, 'utf-8');
  return raw.split('\n').filter(Boolean).map(line => JSON.parse(line));
}

test('writes SESSION_START + tool events as JSONL', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-trace-'));
  try {
    const t = new TraceLogger(tmp);
    t.start();
    eventBus.emit(EventType.TOOL_START, { tool: 'read_file', args: { path: 'src/foo.ts' } });
    eventBus.emit(EventType.TOOL_RESULT, { tool: 'read_file', success: true, output: 'ok' });
    t.stop();
    const records = await readLog(path.join(tmp, '.phenom-trace.log'));
    assert(records[0]?.type === 'SESSION_START', `expected SESSION_START first, got ${records[0]?.type}`);
    const types = records.map(r => r.type);
    assert(types.includes('TOOL_START'), `missing TOOL_START in ${types.join(',')}`);
    assert(types.includes('TOOL_RESULT'), `missing TOOL_RESULT in ${types.join(',')}`);
    assert(records[records.length - 1].type === 'SESSION_END', 'expected SESSION_END last');
    const toolStart = records.find(r => r.type === 'TOOL_START');
    assert(toolStart?.payload?.tool === 'read_file', 'TOOL_START payload missing tool name');
    assert(typeof toolStart?.dt === 'number', 'missing dt (ms since session start)');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('truncates oversized string payloads', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-trace-'));
  try {
    const t = new TraceLogger(tmp);
    t.start();
    eventBus.emit(EventType.TOOL_RESULT, { output: 'x'.repeat(5000) });
    t.stop();
    const records = await readLog(path.join(tmp, '.phenom-trace.log'));
    const tr = records.find(r => r.type === 'TOOL_RESULT');
    assert(!!tr, 'TOOL_RESULT not logged');
    const outStr: string = tr.payload.output;
    assert(outStr.includes('…[+'), `expected truncation marker, got first 30: ${outStr.slice(0, 30)}`);
    assert(outStr.length < 5000, 'string was not truncated');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('skips noisy streaming events', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-trace-'));
  try {
    const t = new TraceLogger(tmp);
    t.start();
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'hello ' });
    eventBus.emit(EventType.TOKEN_UPDATE, { tokens: 42 });
    eventBus.emit(EventType.TOOL_START, { tool: 'date' });
    t.stop();
    const records = await readLog(path.join(tmp, '.phenom-trace.log'));
    const types = records.map(r => r.type);
    assert(!types.includes('MESSAGE_CHUNK'), 'MESSAGE_CHUNK leaked into log');
    assert(!types.includes('TOKEN_UPDATE'), 'TOKEN_UPDATE leaked into log');
    assert(types.includes('TOOL_START'), 'TOOL_START missing');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('PHENOM_TRACE_TOKENS=1 includes compact TOKEN_UPDATE events', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-trace-'));
  const prev = process.env.PHENOM_TRACE_TOKENS;
  process.env.PHENOM_TRACE_TOKENS = '1';
  try {
    const t = new TraceLogger(tmp);
    t.start();
    eventBus.emit(EventType.TOKEN_UPDATE, {
      input: 100,
      output: 25,
      total: 125,
      exact: true,
      cached: 80,
      tokensPerSecond: 12.34567,
      ignoredField: 'x'.repeat(3000),
    });
    t.stop();
    const records = await readLog(path.join(tmp, '.phenom-trace.log'));
    const tokenRec = records.find(r => r.type === 'TOKEN_UPDATE');
    assert(!!tokenRec, 'TOKEN_UPDATE should be logged when PHENOM_TRACE_TOKENS=1');
    assert(tokenRec.payload.input === 100, 'input missing in TOKEN_UPDATE payload');
    assert(tokenRec.payload.output === 25, 'output missing in TOKEN_UPDATE payload');
    assert(tokenRec.payload.total === 125, 'total missing in TOKEN_UPDATE payload');
    assert(tokenRec.payload.exact === true, 'exact missing in TOKEN_UPDATE payload');
    assert(tokenRec.payload.cached === 80, 'cached missing in TOKEN_UPDATE payload');
    assert(tokenRec.payload.tokensPerSecond === 12.35, `tokensPerSecond should be rounded, got ${tokenRec.payload.tokensPerSecond}`);
    assert(tokenRec.payload.ignoredField === undefined, 'unexpected extra TOKEN_UPDATE fields in trace payload');
  } finally {
    if (prev === undefined) delete process.env.PHENOM_TRACE_TOKENS; else process.env.PHENOM_TRACE_TOKENS = prev;
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('PHENOM_TRACE=0 disables logging', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-trace-'));
  const prev = process.env.PHENOM_TRACE;
  process.env.PHENOM_TRACE = '0';
  try {
    const t = new TraceLogger(tmp);
    t.start();
    eventBus.emit(EventType.TOOL_START, { tool: 'date' });
    t.stop();
    const exists = await fs.stat(path.join(tmp, '.phenom-trace.log')).then(() => true, () => false);
    assert(!exists, 'log file should not be created when PHENOM_TRACE=0');
  } finally {
    if (prev === undefined) delete process.env.PHENOM_TRACE; else process.env.PHENOM_TRACE = prev;
    await fs.rm(tmp, { recursive: true, force: true });
  }
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
  console.log(`\nTraceLogger tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
