// Regression: read_file used to hard-reject out-of-range startLine
// ("Faixa inválida: 427-426. Total: 426") and the model would loop on the
// same bad call. We now auto-clamp into bounds and surface a hint so the
// model sees what happened and can adjust.

import os from 'os';
import path from 'path';
import { promises as fs } from 'fs';

import type { Tool } from '../../tools.js';
import { registerFilesystemTools } from '../../tools/registrars/filesystem-tools.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

function buildReadFile(): Tool {
  let captured: Tool | null = null;
  registerFilesystemTools({
    register: (t) => { if (t.name === 'read_file') captured = t; },
    validateSyntax: async () => ({ valid: true, output: '', error: null })
  });
  if (!captured) throw new Error('read_file not registered');
  return captured;
}

async function withTempFile(lineCount: number, fn: (abs: string) => Promise<void>): Promise<void> {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-readfile-'));
  const p = path.join(tmp, 'sample.ts');
  const content = Array.from({ length: lineCount }, (_, i) => `line ${i + 1}`).join('\n');
  await fs.writeFile(p, content, 'utf-8');
  try { await fn(p); } finally { await fs.rm(tmp, { recursive: true, force: true }); }
}

test('startLine past EOF reclamps safely with hint', async () => {
  const tool = buildReadFile();
  await withTempFile(800, async (abs) => {
    const r = await tool.execute({ path: abs, startLine: 801 });
    assert(r.success === true, `expected success after auto-clamp, got error: ${r.error}`);
    assert(r.output.includes('range: 1-200'), `expected bounded fallback window 1-200, got: ${r.output.slice(0, 200)}`);
    assert(/startLine 801 é além/.test(r.output), `missing reclamp hint`);
    assert(r.output.includes('line 200'), `expected clamped window content`);
  });
});

test('endLine past EOF clamps to total without failing', async () => {
  const tool = buildReadFile();
  await withTempFile(50, async (abs) => {
    const r = await tool.execute({ path: abs, startLine: 30, endLine: 999 });
    assert(r.success === true, `expected success after end-clamp, got error: ${r.error}`);
    assert(r.output.includes('range: 30-50'), `expected clamped range 30-50`);
    assert(/endLine 999.*total \(50\)/.test(r.output), `missing endLine clamp hint`);
  });
});

test('normal in-range request unaffected (no reclamp hint)', async () => {
  const tool = buildReadFile();
  await withTempFile(50, async (abs) => {
    const r = await tool.execute({ path: abs, startLine: 10, endLine: 20 });
    assert(r.success === true, `expected success`);
    assert(r.output.includes('range: 10-20'), `wrong range`);
    assert(!/startLine .* além/.test(r.output), `unexpected reclamp hint on valid range`);
    assert(!/endLine .* total/.test(r.output), `unexpected end-clamp hint on valid range`);
  });
});

test('no-range read uses bounded first window by default', async () => {
  const tool = buildReadFile();
  await withTempFile(500, async (abs) => {
    const r = await tool.execute({ path: abs });
    assert(r.success === true, `expected success`);
    assert(r.output.includes('whole_file: false'), `expected whole_file false`);
    assert(r.output.includes('range: 1-200'), `expected default bounded range 1-200`);
    assert(!r.output.includes('line 250'), `unexpected content beyond default window`);
  });
});

test('wholeFile=true reads the full file explicitly', async () => {
  const tool = buildReadFile();
  await withTempFile(220, async (abs) => {
    const r = await tool.execute({ path: abs, wholeFile: true });
    assert(r.success === true, `expected success`);
    assert(r.output.includes('whole_file: true'), `expected whole_file true`);
    assert(r.output.includes('range: 1-220'), `expected full-file range`);
    assert(r.output.includes('line 220'), `expected tail content`);
  });
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nread_file clamp tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
