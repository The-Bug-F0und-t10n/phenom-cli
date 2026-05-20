import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import { execFile as execFileCb } from 'child_process';
import { promisify } from 'util';
import { Agent } from '../../agent.js';

const execFile = promisify(execFileCb);
const TIMEOUT_MS = Number.parseInt(process.env.TEST_TIMEOUT_MS || '240000', 10);

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
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

function getState(agent: Agent): any {
  return (agent as any).state.getState();
}

function assistantMessages(agent: Agent): string[] {
  return getState(agent).memory.filter((m: any) => m.role === 'assistant').map((m: any) => String(m.content || ''));
}

function toolCalls(agent: Agent): any[] {
  return getState(agent).memory
    .filter((m: any) => m.role === 'assistant' && Array.isArray(m.tool_calls))
    .flatMap((m: any) => m.tool_calls || []);
}

async function exists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

async function runScenario() {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-e2e-'));
  const originalCwd = process.cwd();
  process.chdir(tmpDir);

  console.log(`Workspace temporario: ${tmpDir}`);

  try {
    const agent = new Agent();
    agent.setMode('code_assistant');
    agent.setStreamEnabled(false);
    await agent.initialize();

    // 1) Criacao de projeto pequeno
    console.log('\n[1/6] Criacao de pequeno projeto...');
    await withTimeout(
      agent.processInput(
        'Crie um pequeno projeto web em uma pasta "mini_calc" com 3 arquivos: index.html, style.css e script.js. ' +
        'Use ferramentas de escrita de arquivo e implemente uma mini calculadora com soma e subtracao.'
      ),
      TIMEOUT_MS,
      'projeto pequeno'
    );

    const calcDir = path.join(tmpDir, 'mini_calc');
    const indexHtml = path.join(calcDir, 'index.html');
    const styleCss = path.join(calcDir, 'style.css');
    const scriptJs = path.join(calcDir, 'script.js');
    const step1Calls = toolCalls(agent).map((tc: any) => tc?.function?.name);
    const step1Assistant = assistantMessages(agent).slice(-2);
    const step1ToolMsgs = getState(agent).memory
      .filter((m: any) => m.role === 'tool')
      .map((m: any) => String(m.content || '').slice(0, 220));
    console.log('  tool calls step1:', step1Calls);
    console.log('  ultimas respostas step1:', step1Assistant);
    console.log('  tool results step1:', step1ToolMsgs);
    assert(await exists(indexHtml), 'index.html nao foi criado');
    assert(await exists(styleCss), 'style.css nao foi criado');
    assert(await exists(scriptJs), 'script.js nao foi criado');

    // 2) Correcao de bug
    console.log('[2/6] Correcao de bug...');
    const buggyPath = path.join(tmpDir, 'buggy.js');
    await fs.writeFile(buggyPath, 'function sum(a,b){ return a - b; }\nconsole.log(sum(2,3));\n', 'utf-8');

    await withTimeout(
      agent.processInput('Corrija o bug do arquivo buggy.js para que sum(2,3) retorne 5. Edite o arquivo.'),
      TIMEOUT_MS,
      'correcao de bug'
    );

    const buggyContent = await fs.readFile(buggyPath, 'utf-8');
    assert(buggyContent.includes('a + b') || buggyContent.includes('a+b'), 'buggy.js nao foi corrigido para soma');
    const { stdout: buggyOut } = await execFile('node', [buggyPath]);
    assert(String(buggyOut).trim() === '5', `execucao do buggy.js esperava 5, recebeu: ${String(buggyOut).trim()}`);

    // 3) Refatoracao
    console.log('[3/6] Refatoracao...');
    const refactorPath = path.join(tmpDir, 'refactor.js');
    await fs.writeFile(
      refactorPath,
      'const a = "maria";\nconst b = "joao";\nconsole.log(a.trim().toUpperCase());\nconsole.log(b.trim().toUpperCase());\n',
      'utf-8'
    );

    await withTimeout(
      agent.processInput('Refatore refactor.js criando uma funcao helper chamada formatUserName e use nos dois logs sem mudar o comportamento.'),
      TIMEOUT_MS,
      'refatoracao'
    );

    const refContent = await fs.readFile(refactorPath, 'utf-8');
    assert(refContent.includes('formatUserName'), 'refatoracao nao criou helper formatUserName');

    // 4) Execucao de comandos shell
    console.log('[4/6] Execucao de shell command...');
    await withTimeout(
      agent.processInput('Execute o comando shell "pwd" usando run_code e me diga o resultado.'),
      TIMEOUT_MS,
      'run_code pwd'
    );

    const runCodeCalled = toolCalls(agent).some((tc: any) => tc?.function?.name === 'run_code');
    assert(runCodeCalled, 'run_code nao foi chamado');

    // 5) Validacao de sintaxe
    console.log('[5/6] Validacao de sintaxe...');
    const syntaxPath = path.join(tmpDir, 'syntax-ok.js');
    await withTimeout(
      agent.processInput('Crie o arquivo syntax-ok.js com JavaScript valido: uma funcao multiply(a,b) e export dela.'),
      TIMEOUT_MS,
      'criar arquivo sintaxe'
    );

    assert(await exists(syntaxPath), 'syntax-ok.js nao foi criado');
    await execFile('node', ['--check', syntaxPath]);

    // 6) Criacao de testes + execucao
    console.log('[6/6] Criacao de testes e execucao...');
    await withTimeout(
      agent.processInput(
        'Crie math.js com funcao add(a,b) e math.test.js usando node:test para testar add. ' +
        'Depois execute os testes com run_code usando "node --test math.test.js".'
      ),
      TIMEOUT_MS,
      'criacao e execucao de testes'
    );

    const mathPath = path.join(tmpDir, 'math.js');
    const mathTestPath = path.join(tmpDir, 'math.test.js');
    assert(await exists(mathPath), 'math.js nao foi criado');
    assert(await exists(mathTestPath), 'math.test.js nao foi criado');

    const testRunCalled = toolCalls(agent).some((tc: any) => {
      if (tc?.function?.name !== 'run_code') return false;
      const argsRaw = tc?.function?.arguments;
      const args = typeof argsRaw === 'string' ? JSON.parse(argsRaw) : argsRaw;
      return String(args?.command || '').includes('node --test');
    });
    assert(testRunCalled, 'run_code para testes nao foi chamado');

    console.log('\n✅ E2E pratico concluido com sucesso');
    console.log(`Assistente respondeu ${assistantMessages(agent).length} mensagens nesta sessao.`);
  } finally {
    process.chdir(originalCwd);
  }
}

runScenario().catch((error) => {
  console.error('\n❌ Falha no teste E2E pratico');
  console.error(error?.message || error);
  process.exit(1);
});
