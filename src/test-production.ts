// Teste de producao: fluxo real multi-step com Ollama
// OLLAMA_HOST=http://192.168.1.122:11434 npx tsx src/test-production.ts
import { Agent } from './agent.js';
import { mkdtempSync, existsSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

async function waitForModel(agent: Agent): Promise<void> {
  // Aguarda o agente inicializar (chama initialize que ja e sync no test)
  const sessionId = await agent.initialize();
  console.log(`  📋 Session: ${sessionId}`);
}

async function runAgent(agent: Agent, prompt: string, label: string): Promise<string> {
  console.log(`  🤖 ${label}: "${prompt.slice(0, 60)}..."`);
  const result = await (agent as any).runToolLoop(prompt) as any;
  const content = result.content || '';
  console.log(`  📝 Tipo: ${result.type} | Tam: ${content.length} chars`);
  return content;
}

let passed = 0;
let failed = 0;
let testCount = 0;

function check(condition: boolean, msg: string) {
  testCount++;
  if (condition) { passed++; console.log(`    ✅ ${msg}`); }
  else { failed++; console.error(`    ❌ ${msg}`); }
}

async function runProductionTest() {
  process.env.OLLAMA_HOST = process.env.OLLAMA_HOST || 'http://192.168.1.122:11434';
  const model = process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL || 'qwen2.5-coder:7b-instruct-q4_K_M';
  console.log(`\n🧪 Phenom Agent - Teste de Producao`);
  console.log(`📦 Modelo ativo: ${model}`);
  console.log(`🔗 Host: ${process.env.OLLAMA_HOST}\n`);

  // ────────────────────────────────────────────
  // Cenario 1: Criar 2 arquivos
  // ────────────────────────────────────────────
  console.log('═══ Cenario 1: Criar 2 arquivos (index.html + style.css) ═══');
  const dir1 = mkdtempSync(join(tmpdir(), 'phenom-prod-1-'));
  const cwd = process.cwd();
  process.chdir(dir1);
  console.log(`  📁 ${dir1}`);

  const agent1 = new Agent();
  await waitForModel(agent1);
  await runAgent(agent1, 'create index.html with a basic page structure and style.css with nice styles', 'Creating files');

  check(existsSync('index.html'), 'index.html existe');
  check(existsSync('style.css'), 'style.css existe');
  if (existsSync('index.html')) {
    const c = readFileSync('index.html', 'utf-8');
    check(c.length > 30, `index.html com conteudo (${c.length} chars)`);
  }
  if (existsSync('style.css')) {
    const c = readFileSync('style.css', 'utf-8');
    check(c.length > 20, `style.css com conteudo (${c.length} chars)`);
  }

  // ────────────────────────────────────────────
  // Cenario 2: Modificar arquivo existente c/ apply_patch
  // ────────────────────────────────────────────
  console.log('\n═══ Cenario 2: apply_patch em arquivo existente ═══');
  const dir2 = mkdtempSync(join(tmpdir(), 'phenom-prod-2-'));
  writeFileSync(join(dir2, 'app.js'), 'function greet() {\n  console.log("Hello")\n}\n\ngreet()');
  process.chdir(dir2);
  console.log(`  📁 ${dir2}`);
  const agent2 = new Agent();
  await waitForModel(agent2);
  await runAgent(agent2, 'edit app.js using apply_patch: change "Hello" to "Hello World"', 'Editing file');

  check(existsSync('app.js'), 'app.js existe');
  if (existsSync('app.js')) {
    const c = readFileSync('app.js', 'utf-8');
    check(c.includes('Hello World'), 'app.js contem "Hello World"');
  }

  // ────────────────────────────────────────────
  // Cenario 3: Projeto com 3+ arquivos
  // ────────────────────────────────────────────
  console.log('\n═══ Cenario 3: Projeto com 3 arquivos (package.json + index.js + README.md) ═══');
  const dir3 = mkdtempSync(join(tmpdir(), 'phenom-prod-3-'));
  process.chdir(dir3);
  console.log(`  📁 ${dir3}`);
  const agent3 = new Agent();
  await waitForModel(agent3);
  await runAgent(agent3, 'create a small node.js project with 3 files: package.json, index.js (with a simple HTTP server), and README.md', 'Creating project');

  check(existsSync('package.json'), 'package.json existe');
  check(existsSync('index.js'), 'index.js existe');
  check(existsSync('README.md'), 'README.md existe');

  // Volta ao diretorio original
  process.chdir(cwd);

  // Limpeza
  try { rmSync(dir1, { recursive: true, force: true }); } catch {}
  try { rmSync(dir2, { recursive: true, force: true }); } catch {}
  try { rmSync(dir3, { recursive: true, force: true }); } catch {}

  // ────────────────────────────────────────────
  console.log(`\n═══════════════════════════════════════`);
  console.log(`✅ ${passed}/${testCount} verificacoes OK`);
  if (failed > 0) console.log(`❌ ${failed} falhas`);
  console.log(`═══════════════════════════════════════\n`);
  process.exit(failed > 0 ? 1 : 0);
}

runProductionTest();
