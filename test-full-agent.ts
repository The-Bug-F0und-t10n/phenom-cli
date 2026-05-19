import { Agent } from './src/agent.js';
import { eventBus, EventType } from './src/tui/event-bus.js';
import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const GREEN = '\x1b[32m';
const RED = '\x1b[31m';
const YELLOW = '\x1b[33m';
const BLUE = '\x1b[36m';
const RESET = '\x1b[0m';

function log(msg: string, color = RESET) {
  console.log(`${color}${msg}${RESET}`);
}

function divider() {
  console.log('\n' + BLUE + '═'.repeat(70) + RESET);
}

let sessionId: string | null = null;

eventBus.on(EventType.SESSION_UPDATE, (data: any) => {
  if (data?.sessionId && !sessionId) {
    sessionId = data.sessionId;
    log(`\n   🔑 Session ID: ${sessionId}`, YELLOW);
  }
  if (data?.toolName) {
    log(`   🔨 ${data.toolName}: ${data.toolResult ? '✅' : '❌'}`, data.toolResult ? GREEN : RED);
  }
});

eventBus.on(EventType.AGENT_MESSAGE, (data: any) => {
  const content = data?.content || '';
  if (content && content.length > 10) {
    log(`\n   💬 FINAL: ${content.substring(0, 300)}...`, RESET);
  }
});

eventBus.on(EventType.MESSAGE_CHUNK, (data: any) => {
  // Only log if it's tool-related content
  const chunk = data?.chunk || '';
  if (chunk.includes('tool') || chunk.includes('write_file') || chunk.includes('{"type')) {
    process.stdout.write(chunk.substring(0, 50));
  }
});

eventBus.on(EventType.TOOL_START, (data: any) => {
  log(`\n   🔨 TOOL START: ${data?.name || 'unknown'}`, YELLOW);
});

eventBus.on(EventType.TOOL_RESULT, (data: any) => {
  const result = data?.result;
  if (result) {
    log(`   📤 Result: ${result.success ? '✅' : '❌'} ${(result.output || result.error || '').substring(0, 150)}`, 
        result.success ? GREEN : RED);
  }
});

eventBus.on(EventType.TOOL_ERROR, (data: any) => {
  log(`   ❌ Tool Error: ${data?.error || 'unknown'}`, RED);
});

async function main() {
  divider();
  log('TESTE DE INTERACAO COMPLETA - AGENTE + MODELO', BLUE);
  divider();

  const testDir = path.join(__dirname, '.test-full-agent');
  const agent = new Agent();
  await agent.initialize();

  const instructions = [
    'Crie uma estrutura de projeto React com: pasta src/, pasta src/components/, arquivo src/App.tsx (componente funcional que retorna uma div com h1 "Meu App"), e arquivo index.html básico. Use write_file para cada arquivo.',
    'Crie o arquivo src/components/Header.tsx com um componente funcional que retorna um header HTML com título "Meu Projeto". Use write_file.',
    'Crie o arquivo src/components/Footer.tsx com um componente funcional que retorna um footer com copyright do ano atual. Use write_file.',
    'Liste os arquivos da pasta src/ e src/components/ para verificar a estrutura.',
    'Adicione o import do Header e Footer no arquivo src/App.tsx usando apply_patch.',
    'Crie o arquivo src/utils.ts incrementalmente. Primeiro com "export const VERSION = 1.0;" e depois adicione funções sum e multiply usando append=true em chamadas separadas.',
  ];

  try {
    log('\n🧹 LIMPEZA INICIAL', YELLOW);
    try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}
    await fs.mkdir(testDir, { recursive: true });
    process.chdir(testDir);
    log(`   Diretório de teste: ${testDir}`, GREEN);

    const initResult = await agent.initialize();
    sessionId = initResult;
    log(`\n   🔑 Nova Sessão: ${sessionId}`, YELLOW);
    log(`   💡 Para continuar: --session ${sessionId}`, RESET);

    for (let i = 0; i < instructions.length; i++) {
      divider();
      log(`\n📋 INSTRUCAO ${i + 1}/${instructions.length}`, YELLOW);
      log(`   "${instructions[i]}"\n`, RESET);
      
      log('🤖 ENVIANDO PARA O MODELO...', BLUE);
      
      await agent.processInput(instructions[i]);
      
      log('\n📁 ESTRUTURA ATUAL DO PROJETO:', YELLOW);
      
      async function showTree(dir: string, indent = ''): Promise<void> {
        try {
          const entries = await fs.readdir(dir, { withFileTypes: true });
          for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
            if (entry.isDirectory()) {
              log(`${indent}📁 ${entry.name}/`);
              await showTree(path.join(dir, entry.name), indent + '   ');
            } else {
              log(`${indent}📄 ${entry.name}`);
            }
          }
        } catch (e: any) {
          log(`${indent}❌ Erro: ${e.message}`, RED);
        }
      }
      
      await showTree(testDir);
      
      // Verificar arquivos importantes
      log('\n🔍 VERIFICACAO DE ARQUIVOS:', YELLOW);
      
      const checks = [
        'index.html',
        'src/App.tsx',
        'src/components/Header.tsx',
        'src/components/Footer.tsx',
        'src/utils.ts',
      ];
      
      for (const file of checks) {
        const filePath = path.join(testDir, file);
        try {
          const stat = await fs.stat(filePath);
          if (stat.isFile()) {
            const content = await fs.readFile(filePath, 'utf-8');
            log(`   ✅ ${file} (${content.split('\n').length} linhas)`, GREEN);
          } else {
            log(`   ❌ ${file} existe mas não é arquivo`, RED);
          }
        } catch {
          log(`   ❌ ${file} não encontrado`, RED);
        }
      }
    }

    divider();
    log('\n📄 CONTEUDO FINAL DOS ARQUIVOS', BLUE);
    divider();

    const finalFiles = ['index.html', 'src/App.tsx', 'src/components/Header.tsx', 'src/components/Footer.tsx', 'src/utils.ts'];
    
    for (const file of finalFiles) {
      const filePath = path.join(testDir, file);
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        divider();
        log(`\n📄 ${file}`, YELLOW);
        log('-'.repeat(50), BLUE);
        console.log(content);
      } catch {
        log(`\n❌ ${file} não encontrado`, RED);
      }
    }

    divider();
    log('\n✅ TESTE COMPLETO', GREEN);
    divider();

  } catch (error: any) {
    log(`\n❌ ERRO: ${error.message}`, RED);
    console.error(error.stack);
  } finally {
    log('\n🧹 LIMPEZA FINAL', YELLOW);
    try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}
  }
}

main().catch(console.error);
