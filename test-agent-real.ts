import { Agent } from './src/agent.js';
import { ToolSystem } from './src/tools.js';
import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const LOG = {
  info: (msg: string) => console.log(`\n📋 ${msg}`),
  success: (msg: string) => console.log(`  ✅ ${msg}`),
  error: (msg: string) => console.log(`  ❌ ${msg}`),
  model: (msg: string) => console.log(`\n🤖 MODELO:\n${msg}`),
  agent: (msg: string) => console.log(`\n🔧 AGENTE:\n${msg}`),
  tool: (name: string, args: any) => console.log(`\n🔨 TOOL: ${name}\n   Args: ${JSON.stringify(args)}`),
  result: (success: boolean, output: string) => console.log(`   Result: ${success ? '✅' : '❌'} ${output}`),
  divider: () => console.log('\n' + '═'.repeat(60)),
};

async function setupTestEnvironment(testDir: string) {
  LOG.info(`Setup: ${testDir}`);
  try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}
  await fs.mkdir(testDir, { recursive: true });
  process.chdir(testDir);
}

async function cleanup(testDir: string) {
  LOG.info('Cleanup');
  try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}
}

async function runAgentTest() {
  LOG.divider();
  LOG.info('TESTE DE INTERACAO COMPLETA AGENTE-MODELO');
  LOG.divider();

  const testDir = path.join(__dirname, '.test-agent-io');
  const agent = new Agent();
  await agent.initialize();

  try {
    await setupTestEnvironment(testDir);

    // TESTE 1: Criar estrutura de projeto
    LOG.divider();
    LOG.info('TESTE 1: CRIAR ESTRUTURA DE PROJETO REACT');
    LOG.divider();

    LOG.model('Crie uma estrutura de projeto React com components/, src/, App.tsx e index.html');
    
    const response1 = await agent.processInput('Crie uma estrutura de projeto React com uma pasta components/, um arquivo src/App.tsx com um componente funcional React e um index.html básico. Crie cada arquivo separadamente usando write_file.');
    
    // Verificar resultado
    try {
      const files = await fs.readdir(path.join(testDir, 'components'));
      LOG.success(`components/ criada com: ${files.join(', ')}`);
    } catch {
      LOG.error('components/ não encontrada');
    }
    try {
      const appContent = await fs.readFile(path.join(testDir, 'src', 'App.tsx'), 'utf-8');
      LOG.success(`src/App.tsx criado (${appContent.split('\n').length} linhas)`);
    } catch {
      LOG.error('src/App.tsx não encontrado');
    }
    try {
      const htmlContent = await fs.readFile(path.join(testDir, 'index.html'), 'utf-8');
      LOG.success(`index.html criado (${htmlContent.split('\n').length} linhas)`);
    } catch {
      LOG.error('index.html não encontrado');
    }

    // TESTE 2: Editar arquivo existente
    LOG.divider();
    LOG.info('TESTE 2: EDITAR ARQUIVO COM PATCH');
    LOG.divider();

    LOG.model('Adicione um novo componente Header ao arquivo src/App.tsx usando apply_patch. O componente deve ter um título "Meu App".');
    
    const response2 = await agent.processInput('No arquivo src/App.tsx, adicione um novo componente Header funcional antes do App principal. Use apply_patch para fazer a edição.');
    
    // Verificar se arquivo foi editado
    try {
      const content = await fs.readFile(path.join(testDir, 'src', 'App.tsx'), 'utf-8');
      if (content.includes('Header')) {
        LOG.success('Header adicionado ao App.tsx');
      } else {
        LOG.error('Header não encontrado em App.tsx');
      }
    } catch (e: any) {
      LOG.error(`Erro ao ler: ${e.message}`);
    }

    // TESTE 3: Criar múltiplos arquivos incrementais
    LOG.divider();
    LOG.info('TESTE 3: CRIAR ARQUIVOS INCREMENTALMENTE');
    LOG.divider();

    LOG.model('Crie um arquivo src/utils.ts incrementalmente. Primeiro crie com o cabeçalho do módulo, depois adicione 3 funções: calculateSum, multiply e divide.');
    
    const response3 = await agent.processInput('Crie o arquivo src/utils.ts incrementalmente. Primeiro crie com "export const VERSION = 1.0;" e depois adicione 3 funções de matemática usando append=true: calculateSum(a, b), multiply(a, b) e divide(a, b). Cada função em uma chamada separada.');
    
    try {
      const utilsContent = await fs.readFile(path.join(testDir, 'src', 'utils.ts'), 'utf-8');
      const lines = utilsContent.split('\n');
      LOG.success(`src/utils.ts criado com ${lines.length} linhas`);
      if (utilsContent.includes('calculateSum')) LOG.success('calculateSum encontrada');
      if (utilsContent.includes('multiply')) LOG.success('multiply encontrada');
      if (utilsContent.includes('divide')) LOG.success('divide encontrada');
    } catch {
      LOG.error('src/utils.ts não encontrado');
    }

    // TESTE 4: Deletar e reorganizar
    LOG.divider();
    LOG.info('TESTE 4: DELETAR E REORGANIZAR');
    LOG.divider();

    LOG.model('Crie uma pasta src/components/ui/, mova o Header para lá como Header.tsx, e delete o arquivo antigo do src/ se existir.');
    
    const response4 = await agent.processInput('Crie uma pasta src/components/ui/, leia o conteúdo do src/App.tsx, crie o arquivo src/components/ui/Header.tsx com o conteúdo do Header que está no App.tsx, e depois remova o código do Header do App.tsx deixando apenas o App principal.');
    
    try {
      const headerContent = await fs.readFile(path.join(testDir, 'src', 'components', 'ui', 'Header.tsx'), 'utf-8');
      LOG.success(`src/components/ui/Header.tsx criado (${headerContent.split('\n').length} linhas)`);
    } catch {
      LOG.error('Header.tsx não encontrado');
    }

    // TESTE 5: Verificar estrutura final
    LOG.divider();
    LOG.info('TESTE 5: VERIFICAR ESTRUTURA FINAL');
    LOG.divider();

    async function listDirRecursive(dir: string, indent = ''): Promise<void> {
      const files = await fs.readdir(dir);
      for (const file of files) {
        const fullPath = path.join(dir, file);
        const stat = await fs.stat(fullPath);
        if (stat.isDirectory()) {
          LOG.success(`${indent}📁 ${file}/`);
          await listDirRecursive(fullPath, indent + '   ');
        } else {
          LOG.success(`${indent}📄 ${file}`);
        }
      }
    }

    await listDirRecursive(testDir);

    // TESTE 6: Mostrar conteúdo dos arquivos principais
    LOG.divider();
    LOG.info('TESTE 6: CONTEUDO DOS ARQUIVOS');
    LOG.divider();

    const mainFiles = [
      'index.html',
      'src/App.tsx',
      'src/utils.ts',
    ];

    for (const file of mainFiles) {
      try {
        const content = await fs.readFile(path.join(testDir, file), 'utf-8');
        LOG.info(`${file} (${content.split('\n').length} linhas):`);
        console.log(content.substring(0, 300) + (content.length > 300 ? '...' : ''));
      } catch {
        LOG.error(`${file} não encontrado`);
      }
    }

    LOG.divider();
    LOG.success('TESTES COMPLETOS');
    LOG.divider();

  } catch (error: any) {
    LOG.error(`ERRO: ${error.message}`);
    console.error(error.stack);
  } finally {
    await cleanup(testDir);
  }
}

runAgentTest().catch(console.error);
