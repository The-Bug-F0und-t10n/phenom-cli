import { promises as fs } from 'fs';
import os from 'os';
import path from 'path';
import { OllamaClient } from './ollama-client.js';
import { SessionState } from './state.js';
import { ToolSystem } from './tools.js';
import { SemanticSearch } from './semantic-search.js';
import { Agent } from './agent.js';

const DEFAULT_TIMEOUT = parseInt(process.env.TEST_TIMEOUT_MS || '60000', 10);

const withTimeout = async <T>(promise: Promise<T>, ms: number, label: string): Promise<T> => {
  let timer: NodeJS.Timeout;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Timeout em ${label} (${ms}ms)`)), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer!);
  }
};

async function testOllamaConnection() {
  console.log('🧪 Testando conexão com Ollama...');
  try {
    const client = new OllamaClient();
    const response = await withTimeout(
      client.generate('Answer only: OK', 'You are a test assistant.'),
      DEFAULT_TIMEOUT,
      'Ollama'
    );
    if (response.toLowerCase().includes('ok')) {
      console.log('✅ Ollama conectado e respondendo\n');
      return true;
    }
    console.log('⚠️ Ollama respondeu mas formato inesperado\n');
    return false;
  } catch (error: any) {
    console.log(`❌ Erro ao conectar: ${error.message}\n`);
    return false;
  }
}

async function testSessionState() {
  console.log('🧪 Testando gerenciamento de estado...');
  try {
    const state = new SessionState();
    state.setGoal('Teste de objetivo');
    state.addMessage({ role: 'user', content: 'teste', timestamp: Date.now() });

    const goal = state.getGoal();
    const messages = state.getRecentMessages();

    if (goal === 'Teste de objetivo' && messages.length === 1) {
      console.log('✅ Estado funcionando corretamente\n');
      return true;
    }
    console.log('❌ Estado com problemas\n');
    return false;
  } catch (error: any) {
    console.log(`❌ Erro no estado: ${error.message}\n`);
    return false;
  }
}

async function testToolSystem() {
  console.log('🧪 Testando sistema de tools...');
  try {
    const tools = new ToolSystem();
    const result = await tools.execute('run_code', { command: 'date' });
    if (result.success && String(result.output || '').trim().length > 0) {
      console.log('✅ Tools funcionando\n');
      return true;
    }
    console.log('❌ Tools com problemas\n');
    return false;
  } catch (error: any) {
    console.log(`❌ Erro nas tools: ${error.message}\n`);
    return false;
  }
}

async function testSemanticSearch() {
  console.log('🧪 Testando busca semântica (rg/grep)...');
  try {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-search-'));
    const filePath = path.join(tmpDir, 'sample.ts');
    await fs.writeFile(filePath, 'function getUser() { return true; }\n', 'utf-8');

    const search = new SemanticSearch();
    const results = await search.search('get user', tmpDir, 5);

    if (results.length > 0 && results[0].file.includes('sample.ts')) {
      console.log('✅ Busca semântica retornou resultados\n');
      return true;
    }
    console.log('❌ Busca semântica sem resultados\n');
    return false;
  } catch (error: any) {
    console.log(`❌ Erro na busca semântica: ${error.message}\n`);
    return false;
  }
}

async function testPathExistsTool() {
  console.log('🧪 Testando tool path_exists...');
  try {
    const tools = new ToolSystem();
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-path-'));
    const filePath = path.join(tmpDir, 'sample.txt');
    await fs.writeFile(filePath, 'ok', 'utf-8');

    const exists = await tools.execute('path_exists', { path: filePath });
    const missing = await tools.execute('path_exists', { path: path.join(tmpDir, 'missing.txt') });

    const existsPayload = JSON.parse(exists.output || '{}');
    const missingPayload = JSON.parse(missing.output || '{}');

    if (exists.success && existsPayload.exists === true && missingPayload.exists === false) {
      console.log('✅ path_exists funcionando\n');
      return true;
    }

    console.log('❌ path_exists retornou resultado inesperado\n');
    return false;
  } catch (error: any) {
    console.log(`❌ Erro no path_exists: ${error.message}\n`);
    return false;
  }
}

async function testAgentIntegration() {
  console.log('🧪 Testando execução do agente...');
  try {
    const agent = new Agent();
    agent.setMode('code_assistant');
    await agent.initialize();
    await withTimeout(
      agent.processInput('Liste os arquivos do diretório atual'),
      DEFAULT_TIMEOUT,
      'Agent.processInput'
    );
    console.log('✅ Agente executou fluxo completo\n');
    return true;
  } catch (error: any) {
    console.log(`❌ Erro no agente: ${error.message}\n`);
    return false;
  }
}

async function main() {
  const tests = [
    testOllamaConnection,
    testSessionState,
    testToolSystem,
    testSemanticSearch,
    testPathExistsTool,
    testAgentIntegration,
  ];

  let passed = 0;
  for (const test of tests) {
    if (await test()) passed++;
  }

  console.log(`\nResultado: ${passed}/${tests.length} testes passaram`);
  process.exit(passed === tests.length ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
