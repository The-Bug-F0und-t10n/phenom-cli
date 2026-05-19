import { Agent } from './src/agent.js';
import { eventBus, EventType } from './src/tui/event-bus.js';
import { promises as fs } from 'fs';
import path from 'path';

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

const testDir = path.join(process.cwd(), '.test-complex-agent');

async function main() {
  divider();
  log('TESTE COMPLEXO - Native Tools Agent', BLUE);
  divider();

  await fs.mkdir(testDir, { recursive: true });
  process.chdir(testDir);

  const agent = new Agent();
  await agent.initialize();

  const tasks = [
    {
      name: 'Criar projeto base',
      input: `Crie um projeto JavaScript simples com:
1. Arquivo package.json com nome "math-utils" e versão "1.0.0"
2. Arquivo src/calculator.js com funções: sum(a, b), subtract(a, b), multiply(a, b), divide(a, b)
3. Arquivo src/index.js que exporta todas as funções do calculator
4. Arquivo index.html básico que inclui um script que testa as funções
Use write_file para cada arquivo.`,
      validate: async () => {
        const files = ['package.json', 'src/calculator.js', 'src/index.js', 'index.html'];
        for (const f of files) {
          const stat = await fs.stat(f);
          if (!stat.isFile()) throw new Error(`Arquivo ${f} não criado`);
        }
        const pkg = JSON.parse(await fs.readFile('package.json', 'utf-8'));
        if (pkg.name !== 'math-utils' || pkg.version !== '1.0.0') {
          throw new Error('package.json incorreto');
        }
        return 'Projeto base criado com sucesso';
      }
    },
    {
      name: 'Correção de Bug',
      input: `Adicione um bug no arquivo src/calculator.js: a função divide deve retornar "Erro: divisão por zero" quando o divisor for 0 (atualmente ela retorna Infinity). Use apply_patch para fazer essa correção.`,
      validate: async () => {
        const content = await fs.readFile('src/calculator.js', 'utf-8');
        if (!content.includes('divisão por zero') && !content.includes('divisor for 0') && !content.includes('divisor === 0')) {
          throw new Error('Bug não foi corrigido - função divide ainda não verifica divisão por zero');
        }
        return 'Bug corrigido: divisão por zero agora retorna mensagem de erro';
      }
    },
    {
      name: 'Implementação de Feature',
      input: `Adicione uma nova função "power(base, exponent)" no arquivo src/calculator.js que calcula base elevada ao expoente. Use apply_patch para adicionar a função e atualize src/index.js para exportar essa nova função.`,
      validate: async () => {
        const calc = await fs.readFile('src/calculator.js', 'utf-8');
        const idx = await fs.readFile('src/index.js', 'utf-8');
        if (!calc.includes('power') && !calc.includes('exponent')) {
          throw new Error('Função power não foi adicionada');
        }
        if (!idx.includes('power')) {
          throw new Error('Função power não foi exportada em index.js');
        }
        return 'Feature implementada: função power adicionada e exportada';
      }
    },
    {
      name: 'Debug e Testes',
      input: `Crie um arquivo tests/calculator.test.js com testes para todas as funções (sum, subtract, multiply, divide, power). Use write_file.`,
      validate: async () => {
        const stat = await fs.stat('tests/calculator.test.js');
        if (!stat.isFile()) throw new Error('Arquivo de testes não criado');
        const content = await fs.readFile('tests/calculator.test.js', 'utf-8');
        const hasTests = content.includes('test(') || content.includes('it(') || content.includes('describe(');
        if (!hasTests) throw new Error('Arquivo não contém testes');
        return 'Testes criados com sucesso';
      }
    }
  ];

  const results: { task: string; success: boolean; message: string }[] = [];

  for (let i = 0; i < tasks.length; i++) {
    divider();
    log(`\n📋 TAREFA ${i + 1}/${tasks.length}: ${tasks[i].name}`, YELLOW);
    log(`   ${tasks[i].input.substring(0, 100)}...`, RESET);
    
    try {
      await agent.processInput(tasks[i].input);
      
      const validation = await tasks[i].validate();
      log(`   ✅ ${validation}`, GREEN);
      results.push({ task: tasks[i].name, success: true, message: validation });
    } catch (error: any) {
      log(`   ❌ ${error.message}`, RED);
      results.push({ task: tasks[i].name, success: false, message: error.message });
    }
  }

  divider();
  log('\n📊 RESUMO DOS RESULTADOS', BLUE);
  divider();
  
  let passed = 0;
  let failed = 0;
  
  for (const r of results) {
    if (r.success) {
      log(`   ✅ ${r.task}: ${r.message}`, GREEN);
      passed++;
    } else {
      log(`   ❌ ${r.task}: ${r.message}`, RED);
      failed++;
    }
  }
  
  divider();
  log(`\n   Total: ${passed}/${results.length} concluídos com sucesso`, passed === results.length ? GREEN : YELLOW);
  divider();

  console.log('\n📁 ESTRUTURA FINAL DO PROJETO:');
  await showTree(testDir);
  
  console.log('\n📄 CONTEÚDOS DOS ARQUIVOS:');
  for (const f of ['src/calculator.js', 'src/index.js', 'tests/calculator.test.js']) {
    divider();
    log(`\n📄 ${f}`, YELLOW);
    console.log(await fs.readFile(f, 'utf-8'));
  }

  await fs.rm(testDir, { recursive: true, force: true });
  log('\n🧹 Limpeza concluída', BLUE);
}

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

main().catch(console.error);