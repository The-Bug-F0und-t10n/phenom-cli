// Regression: read_file/apply_patch on a non-existent path used to return a
// raw ENOENT message that didn't help the model recover, so it looped on the
// same wrong path (calculadora session: 3× ENOENT on
// "src/components/calculator/Calculator.tsx" while the real file was
// "src/components/Calculator.tsx"). Now the error lists candidates with
// matching basename so the model can self-correct.

import os from 'os';
import path from 'path';
import { promises as fs } from 'fs';

import type { Tool } from '../../tools.js';
import { registerFilesystemTools } from '../../tools/registrars/filesystem-tools.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

function buildTools(): Map<string, Tool> {
  const out = new Map<string, Tool>();
  registerFilesystemTools({
    register: t => { out.set(t.name, t); },
    validateSyntax: async () => ({ valid: true, output: '', error: null })
  });
  return out;
}

async function withCalculadoraFixture(fn: (tmp: string) => Promise<void>): Promise<void> {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-enoent-'));
  // Mirror the calculadora layout: real file at src/components/Calculator.tsx
  // (the model kept asking for src/components/calculator/Calculator.tsx).
  await fs.mkdir(path.join(tmp, 'src', 'components'), { recursive: true });
  await fs.writeFile(path.join(tmp, 'src', 'components', 'Calculator.tsx'), 'export const X = 1;\n');
  await fs.mkdir(path.join(tmp, 'src', 'utils'), { recursive: true });
  await fs.writeFile(path.join(tmp, 'src', 'utils', 'calculator.ts'), 'export const Y = 2;\n');
  const prevCwd = process.cwd();
  try {
    process.chdir(tmp);
    await fn(tmp);
  } finally {
    process.chdir(prevCwd);
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

test('read_file ENOENT surfaces basename-matching candidates', async () => {
  await withCalculadoraFixture(async () => {
    const tools = buildTools();
    const r = await tools.get('read_file')!.execute({ path: 'src/components/calculator/Calculator.tsx' });
    assert(r.success === false, 'expected failure on wrong path');
    assert(/PATH_NOT_FOUND \(read_file\)/.test(String(r.error)), `missing typed error: ${r.error}`);
    assert(/src\/components\/Calculator\.tsx/.test(String(r.error)), `missing real path suggestion: ${r.error}`);
    assert(/NÃO repita/.test(String(r.error)), `missing directive to stop retrying: ${r.error}`);
  });
});

test('apply_patch ENOENT lists candidates too', async () => {
  await withCalculadoraFixture(async () => {
    const tools = buildTools();
    const r = await tools.get('apply_patch')!.execute({
      path: 'src/components/calculator/Calculator.tsx',
      startLine: 1,
      endLine: 1,
      replace: 'new'
    });
    assert(r.success === false, 'expected failure on wrong path');
    assert(/PATH_NOT_FOUND \(apply_patch\)/.test(String(r.error)), `missing typed error: ${r.error}`);
    assert(/src\/components\/Calculator\.tsx/.test(String(r.error)), `missing real path: ${r.error}`);
  });
});

test('no suggestions surfaces a different directive', async () => {
  await withCalculadoraFixture(async () => {
    const tools = buildTools();
    const r = await tools.get('read_file')!.execute({ path: 'does-not-exist/Nothing.tsx' });
    assert(r.success === false, 'expected failure');
    assert(/Nenhum arquivo com basename similar/.test(String(r.error)), `expected no-match directive: ${r.error}`);
  });
});

test('correct path still reads normally (no false alarms)', async () => {
  await withCalculadoraFixture(async () => {
    const tools = buildTools();
    const r = await tools.get('read_file')!.execute({ path: 'src/components/Calculator.tsx' });
    assert(r.success === true, `valid path should succeed: ${r.error}`);
    assert(r.output.includes('export const X'), 'content missing');
  });
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nENOENT suggestions tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
