import { Agent } from './agent.js';
import { mkdtempSync, existsSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

let passed = 0, failed = 0, testCount = 0;
function check(condition: boolean, msg: string) {
  testCount++;
  if (condition) { passed++; console.log(`  ✅ ${msg}`); }
  else { failed++; console.error(`  ❌ ${msg}`); }
}

async function runTest(label: string, prompt: string, fileChecks: [string, (content: string) => boolean][], _agent: Agent, agent: Agent) {
  console.log(`\n═══ ${label} ═══`);
  const dir = mkdtempSync(join(tmpdir(), 'phenom-e2e-'));
  const cwd = process.cwd();
  process.chdir(dir);
  console.log(`  📁 ${dir}`);

  const sessionId = await agent.initialize();
  console.log(`  🆔 ${sessionId}`);

  const t0 = Date.now();
  const result = await (agent as any).runToolLoop(prompt) as any;
  const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`  ⏱️  ${elapsed}s | tipo=${result.type} | tam=${(result.content || '').length}`);

  for (const [fname, validator] of fileChecks) {
    const fpath = join(dir, fname);
    check(existsSync(fpath), `${fname} criado`);
    if (existsSync(fpath)) {
      const c = readFileSync(fpath, 'utf-8');
      check(validator(c), `${fname} conteudo valido (${c.length} chars)`);
    }
  }

  process.chdir(cwd);
  try { rmSync(dir, { recursive: true, force: true }); } catch {}
}

async function main() {
  console.log('🧪 E2E: testes ISOLADOS (cada um cria seu proprio Agent)\n');

  // Cenario 1: 1 arquivo simples (mais rapido)
  const a1 = new Agent();
  await runTest('Cenario 1: criar 1 arquivo (index.html)', 'create a single index.html with "Hello World"', [
    ['index.html', (c) => c.includes('Hello') || c.includes('hello') || c.includes('Hello')]
  ], a1, a1);

  // Cenario 2: 2 arquivos
  const a2 = new Agent();
  await runTest('Cenario 2: criar 2 arquivos', 'create index.html with a basic page and style.css with styles', [
    ['index.html', (c) => c.length > 20],
    ['style.css', (c) => c.length > 10]
  ], a2, a2);

  // Cenario 3: editar arquivo existente
  const a3 = new Agent();
  const dir3 = mkdtempSync(join(tmpdir(), 'phenom-e2e-3-'));
  writeFileSync(join(dir3, 'app.js'), 'const x = 1;\nconsole.log(x);\n');
  const cwd = process.cwd();
  process.chdir(dir3);
  console.log(`\n═══ Cenario 3: editar arquivo (apply_patch) ═══`);
  console.log(`  📁 ${dir3}`);
  const s3 = await a3.initialize();
  const t0_3 = Date.now();
  const r3 = await (a3 as any).runToolLoop('edit app.js using apply_patch: change "const x = 1" to "const x = 42"') as any;
  const e3 = ((Date.now() - t0_3) / 1000).toFixed(1);
  console.log(`  ⏱️  ${e3}s | tipo=${r3.type}`);
  check(existsSync('app.js'), 'app.js existe');
  if (existsSync('app.js')) {
    const c = readFileSync('app.js', 'utf-8');
    check(c.includes('42'), 'app.js contem "42"');
  }
  process.chdir(cwd);
  try { rmSync(dir3, { recursive: true, force: true }); } catch {}

  console.log(`\n═══════════════════════════════════════`);
  console.log(`${passed}/${testCount} OK`);
  if (failed > 0) console.log(`❌ ${failed} falhas`);
  process.exit(failed > 0 ? 1 : 0);
}

main();
