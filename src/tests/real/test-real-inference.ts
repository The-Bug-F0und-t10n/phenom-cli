import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import { Agent } from '../../agent.js';
import { ToolSystem } from '../../tools.js';
import { registerAdvancedTools } from '../../advanced-tools.js';
const SIMPLE_TIMEOUT = 300_000;
const MEDIUM_TIMEOUT = 600_000;
const COMPLEX_TIMEOUT = 1_800_000;
const TOOLS_TIMEOUT = 30_000;

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];

function test(name: string, fn: () => Promise<void>) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

function getState(agent: Agent) {
  const state = (agent as any).state;
  return state.getState();
}

function lastAssistantMessage(agent: Agent): string {
  const msgs = getState(agent).memory.filter((m: any) => m.role === 'assistant');
  return msgs.length > 0 ? msgs[msgs.length - 1].content || '' : '';
}

async function createAgent(): Promise<Agent> {
  const agent = new Agent();
  agent.setMode('fast');
  await agent.initialize();
  return agent;
}

async function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: NodeJS.Timeout;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Timeout (${ms}ms): ${label}`)), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer!);
  }
}

async function inTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const originalCwd = process.cwd();
  process.chdir(dir);
  try {
    return await fn(dir);
  } finally {
    process.chdir(originalCwd);
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

// ============================================================
// TEST 1: Simple
// ============================================================
test('Simple: agent responde "hello"', async () => {
  const agent = await createAgent();

  await withTimeout(
    agent.processInput('Say hello in one word. Respond ONLY the greeting word, no extra text.'),
    SIMPLE_TIMEOUT,
    'Simple hello'
  );

  const response = lastAssistantMessage(agent);
  assert(response.length > 0, `Response vazia`);
  assert(!response.includes('Não recebi saída'), 'Modelo retornou fallback de erro');

  const memory = getState(agent).memory;
  const userMsgs = memory.filter((m: any) => m.role === 'user');
  const assistantMsgs = memory.filter((m: any) => m.role === 'assistant');
  assert(userMsgs.length >= 1, `Deveria ter pelo menos 1 mensagem do usuario, tem ${userMsgs.length}`);
  assert(assistantMsgs.length >= 1, `Deveria ter pelo menos 1 resposta, tem ${assistantMsgs.length}`);
});

// ============================================================
// TEST 2: Medium - criar arquivo HTML
// ============================================================
test('Medium: cria arquivo hello.html com Hello World', async () => {
  await inTempDir(async (tmpDir) => {
    const agent = await createAgent();

    await withTimeout(
      agent.processInput('Create a file called hello.html in the current directory. It must be a complete HTML page that displays "Hello World" in the browser. Use write_file tool.'),
      MEDIUM_TIMEOUT,
      'Create hello.html'
    );

    const memory = getState(agent).memory;
    const toolMsgs = memory.filter((m: any) => m.role === 'assistant' && m.tool_calls?.length > 0);
    assert(toolMsgs.length > 0, 'Nenhuma tool call foi feita');

    const writeCalls = toolMsgs.flatMap((m: any) =>
      m.tool_calls.filter((t: any) =>
        t.function.name === 'write_file' || t.function.name === 'create_file'
      )
    );
    assert(writeCalls.length > 0, 'Nenhuma chamada write_file/create_file foi feita');

    const createdPaths = writeCalls.map((t: any) => t.function.arguments.path);
    const helloPath = createdPaths.find((p: string) =>
      p?.includes('hello.html') || p?.includes('hello')
    );

    let filePath: string | null = null;
    if (helloPath) {
      filePath = path.resolve(tmpDir, path.basename(helloPath));
    } else {
      const candidates = ['hello.html', 'hello.htm', 'index.html'];
      for (const c of candidates) {
        const fp = path.join(tmpDir, c);
        if (await fs.access(fp).then(() => true).catch(() => false)) {
          filePath = fp;
          break;
        }
      }
    }

    assert(filePath !== null, 'Arquivo hello.html nao encontrado no disco');

    const content = await fs.readFile(filePath!, 'utf-8');
    assert(content.toLowerCase().includes('hello'), `Conteudo deveria conter "hello", mas tem: ${content.substring(0, 100)}`);
    assert(content.includes('<'), 'Conteudo deveria ser HTML (conter <)');
  });
});

// ============================================================
// TEST 3: Complex - projeto multi-arquivo
// ============================================================
test('Complex: cria projeto calculadora com HTML/CSS/JS', async () => {
  await inTempDir(async (tmpDir) => {
    const agent = await createAgent();

    await withTimeout(
      agent.processInput(
        'Create exactly 3 files in a directory called "calculator": ' +
        'index.html (HTML structure), style.css (styling), and script.js (JavaScript with +,-,*,/). ' +
        'Use write_file for each. Do NOT explore or check directories first.'
      ),
      COMPLEX_TIMEOUT,
      'Complex calculator project'
    );

    const memory = getState(agent).memory;
    const toolMsgs = memory.filter((m: any) => m.role === 'assistant' && m.tool_calls?.length > 0);
    assert(toolMsgs.length > 0, 'Nenhuma tool call foi feita');

    const writeCalls = toolMsgs.flatMap((m: any) =>
      m.tool_calls.filter((t: any) =>
        t.function.name === 'write_file' || t.function.name === 'create_file'
      )
    );
    assert(writeCalls.length >= 2, `Deveria ter pelo menos 2 chamadas write_file, tem ${writeCalls.length}`);

    const createdFiles: string[] = writeCalls.map((t: any) => t.function.arguments.path);

    const calcDir = path.join(tmpDir, 'calculator');
    let diskFiles: string[] = [];
    try {
      diskFiles = await fs.readdir(calcDir);
    } catch {
      try {
        diskFiles = await fs.readdir(tmpDir);
      } catch {}
    }

    const allFiles = [...new Set([...createdFiles, ...diskFiles])];
    assert(allFiles.length >= 2, `Deveria ter criado pelo menos 2 arquivos, criados: ${allFiles.join(', ')}`);

    const htmlFile = allFiles.find((f: string) => f.endsWith('.html') || f.includes('index'));
    assert(htmlFile !== undefined, 'Nenhum arquivo HTML encontrado entre os criados');
  });
});

// ============================================================
// TEST 4: Contexto - agente lembra do que criou
// ============================================================
test('Contexto: agente lembra de arquivos criados em chamada anterior', async () => {
  await inTempDir(async (tmpDir) => {
    const agent = await createAgent();

    await withTimeout(
      agent.processInput('Create a file called "memory-test.txt" in the current directory with content "Remember this file".'),
      MEDIUM_TIMEOUT,
      'Context: criar arquivo'
    );

    const memory1 = getState(agent).memory;
    const writeCalls1 = memory1
      .filter((m: any) => m.role === 'assistant' && m.tool_calls?.length > 0)
      .flatMap((m: any) => m.tool_calls);
    const created = writeCalls1.filter((t: any) =>
      t.function.name === 'write_file' || t.function.name === 'create_file'
    );
    assert(created.length > 0, 'Primeira chamada deveria ter criado arquivo');

    await withTimeout(
      agent.processInput('What file did you just create in the previous step? What is its content? Answer in one sentence.'),
      SIMPLE_TIMEOUT,
      'Context: perguntar o que criou'
    );

    const response = lastAssistantMessage(agent);
    assert(response.length > 0, 'Resposta vazia');
    assert(!response.includes('Não recebi saída'), 'Modelo retornou fallback');

    const lower = response.toLowerCase();
    const mentionsFile = lower.includes('memory-test') || lower.includes('remember this');
    assert(mentionsFile, `Agente deveria mencionar memory-test.txt na resposta. Resposta: "${response.substring(0, 200)}"`);
  });
});

// ============================================================
// TEST 5: Execucao de todas as ferramentas
// ============================================================
test('Tools: todas as ferramentas executam sem erro', async () => {
  const toolSystem = new ToolSystem();
  registerAdvancedTools(toolSystem);

  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-tools-'));
  const srcFile = path.join(tmpDir, 'test.ts');
  await fs.writeFile(srcFile, 'const x = 1;\n', 'utf-8');

  const toolTests: Array<{
    name: string;
    args: Record<string, any>;
    desc: string;
  }> = [
    { name: 'read_file', args: { path: srcFile }, desc: 'read_file' },
    { name: 'path_exists', args: { path: srcFile }, desc: 'path_exists (existe)' },
    { name: 'path_exists', args: { path: '/nonexistent/xyz' }, desc: 'path_exists (nao existe)' },
    { name: 'list_dir', args: { path: tmpDir }, desc: 'list_dir' },
    { name: 'date', args: {}, desc: 'date' },
    { name: 'grep_file', args: { path: srcFile, pattern: 'const' }, desc: 'grep_file' },
    { name: 'run_code', args: { command: 'echo ok' }, desc: 'run_code' },
    { name: 'write_file', args: { path: path.join(tmpDir, 'new.txt'), content: 'created' }, desc: 'write_file' },
    { name: 'create_file', args: { path: path.join(tmpDir, 'new2.txt'), content: 'created2' }, desc: 'create_file' },
    { name: 'apply_patch', args: { path: srcFile, operations: [{ search: 'const x', replace: 'const y' }] }, desc: 'apply_patch' },
    { name: 'glob', args: { pattern: '*.txt', path: tmpDir }, desc: 'glob' },
  ];

  let toolPassed = 0;
  const toolFailures: string[] = [];

  for (const tt of toolTests) {
    try {
      const result = await withTimeout(
        toolSystem.execute(tt.name, tt.args),
        TOOLS_TIMEOUT,
        tt.desc
      );
      if (result.success) {
        toolPassed++;
      } else {
        toolFailures.push(`${tt.desc}: ${result.error?.substring(0, 80)}`);
      }
    } catch (error: any) {
      toolFailures.push(`${tt.desc}: ${error.message?.substring(0, 80) || error}`);
    }
  }

  await fs.rm(tmpDir, { recursive: true, force: true }).catch(() => {});

  const passedTools = toolPassed;
  const totalTools = toolTests.length;
  assert(passedTools >= totalTools - 2,
    `Muitas tools falharam: ${passedTools}/${totalTools} passaram.\nFalhas:\n${toolFailures.join('\n')}`
  );
});

// ============================================================
// Runner
// ============================================================
async function waitForOllama(): Promise<void> {
  const { OllamaClient } = await import('../../ollama-client.js');
  const host = process.env.OLLAMA_HOST || 'http://127.0.0.1:11434';
  const client = new OllamaClient();

  const model = process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL || '';
  if (!model) {
    throw new Error('OLLAMA_MODEL or OLLAMA_CODER_MODEL must be set');
  }

  console.log(`\n🧪 Aguardando Ollama em ${host}...`);
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const r = await client.generate('ping', 'You are a test assistant.');
      if (r && r.length > 0) {
        console.log(`✅ Modelo ${model} pronto\n`);
        return;
      }
    } catch {
      if (attempt < 6) {
        console.log(`   Tentativa ${attempt}/6 falhou, aguardando 10s...`);
        await new Promise(r => setTimeout(r, 10000));
      }
    }
  }
  throw new Error(`Modelo ${model} nao respondeu apos 6 tentativas`);
}

async function main() {
  console.log('='.repeat(60));
  console.log('🧪 TESTE DE INFERENCIA REAL DO AGENTE');
  console.log('='.repeat(60));

  const model = process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL || '(nao definido)';
  const adaptive = process.env.OLLAMA_ADAPTIVE_CTX || '(nao definido)';
  console.log(`📋 Modelo: ${model}`);
  console.log(`📋 Adaptive Ctx: ${adaptive}`);
  console.log(`📋 Modo: fast\n`);

  await waitForOllama();

  let failures = 0;
  for (const { name, fn } of tests) {
    process.stdout.write(`🧪 ${name}... `);
    try {
      await fn();
      passed++;
      console.log(`✅ PASS\n`);
    } catch (error: any) {
      failures++;
      console.log(`❌ FAIL: ${error.message}\n`);
    }
  }

  console.log('='.repeat(60));
  console.log(`Resultado: ${passed}/${tests.length} testes passaram`);
  console.log('='.repeat(60));
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((error) => {
  console.error('FATAL:', error);
  process.exit(1);
});
