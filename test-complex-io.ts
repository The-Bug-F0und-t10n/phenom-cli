import { ToolSystem } from './dist/tools.js';
import { SyntaxValidator } from './dist/syntax-validator.js';
import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

interface LogEntry {
  type: 'model' | 'agent' | 'tool' | 'result' | 'success' | 'error';
  message: string;
  timestamp: Date;
}

const logs: LogEntry[] = [];

function log(type: LogEntry['type'], message: string) {
  const entry: LogEntry = { type, message, timestamp: new Date() };
  logs.push(entry);
  const prefix = {
    model: '🤖 MODELO:',
    agent: '🔧 AGENTE:',
    tool: '🔨 TOOL:',
    result: '📤 RESULT:',
    success: '✅ SUCCESS:',
    error: '❌ ERROR:'
  }[type];
  console.log(`\n${prefix}\n${message}`);
}

function printLogs() {
  console.log('\n' + '='.repeat(60));
  console.log('LOG COMPLETO DA INTERACAO');
  console.log('='.repeat(60));
  for (const entry of logs) {
    const time = entry.timestamp.toISOString().substring(11, 23);
    console.log(`[${time}] ${entry.type.toUpperCase().padEnd(7)}: ${entry.message.substring(0, 100)}`);
  }
}

async function main() {
  const testDir = path.join(__dirname, '.test-complex-io');
  const toolSystem = new ToolSystem();
  const syntaxValidator = new SyntaxValidator();

  log('agent', 'Iniciando teste de I/O complexo...');

  try {
    // LIMPEZA
    try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}
    await fs.mkdir(testDir, { recursive: true });
    process.chdir(testDir);

    // ============================================================
    // FASE 1: MODELO SOLICITA CRIAR ESTRUTURA
    // ============================================================
    log('model', 'Crie uma estrutura de projeto React com: src/, components/, App.tsx, index.html');

    log('agent', 'Analisando request... criando estrutura...');

    // Criar App.tsx - o diretório src/ será criado automaticamente
    log('tool', 'write_file(path: "src/App.tsx", content: "...")');
    const appResult = await toolSystem.execute('write_file', { path: 'src/App.tsx', content: appContent });
    log('result', `write_file src/App.tsx: ${appResult.success ? 'OK' : appResult.error}`);
    if (appResult.error) log('error', appResult.error);
      <Footer />
    </div>
  );
}
`;

    log('tool', `write_file(path: "src/App.tsx", content: "...")`);
    const appResult = await toolSystem.execute('write_file', { path: 'src/App.tsx', content: appContent });
    log('result', `write_file src/App.tsx: ${appResult.success ? 'OK' : appResult.error}`);
    if (appResult.error) log('error', appResult.error);

    // Criar index.html
    const htmlContent = `<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Meu Projeto React</title>
</head>
<body>
  <div id="root"></div>
</body>
</html>
`;

    log('tool', `write_file(path: "index.html", content: "...")`);
    const htmlResult = await toolSystem.execute('write_file', { path: 'index.html', content: htmlContent });
    log('result', `write_file index.html: ${htmlResult.success ? 'OK' : htmlResult.error}`);
    if (htmlResult.error) log('error', htmlResult.error);

    log('agent', 'Estrutura básica criada. Aguardando próxima instrução...');

    // ============================================================
    // FASE 2: MODELO SOLICITA CRIAR COMPONENTES
    // ============================================================
    log('model', 'Crie os componentes Header.tsx e Footer.tsx no diretório components/');

    const headerContent = `export function Header() {
  return \`
    <header class="header">
      <nav>
        <a href="/">Início</a>
        <a href="/sobre">Sobre</a>
      </nav>
    </header>
  \`;
}
`;

    log('tool', `write_file(path: "src/components/Header.tsx", content: "...")`);
    const headerResult = await toolSystem.execute('write_file', { path: 'src/components/Header.tsx', content: headerContent });
    log('result', `write_file src/components/Header.tsx: ${headerResult.success ? 'OK' : headerResult.error}`);
    if (headerResult.error) log('error', headerResult.error);

    const footerContent = `export function Footer() {
  const year = new Date().getFullYear();
  return \`
    <footer class="footer">
      <p>&copy; \${year} - Meu Projeto</p>
    </footer>
  \`;
}
`;

    log('tool', `write_file(path: "src/components/Footer.tsx", content: "...")`);
    const footerResult = await toolSystem.execute('write_file', { path: 'src/components/Footer.tsx', content: footerContent });
    log('result', `write_file src/components/Footer.tsx: ${footerResult.success ? 'OK' : footerResult.error}`);
    if (footerResult.error) log('error', footerResult.error);

    log('agent', 'Componentes criados. Verificando sintaxe...');

    // ============================================================
    // FASE 3: VERIFICAR ESTRUTURA
    // ============================================================
    log('model', 'Liste os arquivos criados');

    log('tool', 'list_dir(path: ".")');
    const listResult = await toolSystem.execute('list_dir', { path: '.' });
    log('success', `list_dir: ${listResult.output}`);

    log('tool', 'list_dir(path: "src/")');
    const listSrcResult = await toolSystem.execute('list_dir', { path: 'src' });
    log('success', `list_dir src/: ${listSrcResult.output}`);

    log('tool', 'list_dir(path: "src/components/")');
    const listComponentsResult = await toolSystem.execute('list_dir', { path: 'src/components' });
    log('success', `list_dir src/components/: ${listComponentsResult.output}`);

    // ============================================================
    // FASE 4: EDITAR ARQUIVOS
    // ============================================================
    log('model', 'Adicione um link para /contato no Header usando apply_patch');

    log('tool', `apply_patch(path: "src/components/Header.tsx", operations: [...])`);
    const patchResult = await toolSystem.execute('apply_patch', {
      path: 'src/components/Header.tsx',
      operations: [
        {
          find: `<a href="/sobre">Sobre</a>`,
          replace: `<a href="/sobre">Sobre</a>\n        <a href="/contato">Contato</a>`
        }
      ]
    });
    log('result', `apply_patch: ${patchResult.success ? 'OK' : 'FAILED'}`);
    log('success', patchResult.output);

    // ============================================================
    // FASE 5: CRIAR UTILS COM APPEND
    // ============================================================
    log('model', 'Crie um arquivo src/utils.ts incrementalmente. Primeiro cabeçalho, depois funções.');

    log('tool', `write_file(path: "src/utils.ts", content: "// Utils module\\n")`);
    const utilsResult1 = await toolSystem.execute('write_file', {
      path: 'src/utils.ts',
      content: '// Math utilities\\nexport const PI = 3.14159;\\n'
    });
    log('result', `write_file (new): ${utilsResult1.success ? 'OK' : utilsResult1.error}`);

    log('tool', `write_file(path: "src/utils.ts", content: "export function sum...", append: true)`);
    const utilsResult2 = await toolSystem.execute('write_file', {
      path: 'src/utils.ts',
      content: 'export function sum(a: number, b: number): number {\\n  return a + b;\\n}\\n',
      append: true
    });
    log('result', `write_file (append 1): ${utilsResult2.success ? 'OK' : utilsResult2.error}`);

    log('tool', `write_file(path: "src/utils.ts", content: "export function multiply...", append: true)`);
    const utilsResult3 = await toolSystem.execute('write_file', {
      path: 'src/utils.ts',
      content: 'export function multiply(a: number, b: number): number {\\n  return a * b;\\n}\\n',
      append: true
    });
    log('result', `write_file (append 2): ${utilsResult3.success ? 'OK' : utilsResult3.error}`);

    // Verificar conteúdo final do utils.ts
    log('tool', 'read_file(path: "src/utils.ts")');
    const utilsReadResult = await toolSystem.execute('read_file', { path: 'src/utils.ts' });
    log('success', `src/utils.ts content:\\n${utilsReadResult.output}`);

    // ============================================================
    // FASE 6: VALIDACAO DE SINTAXE
    // ============================================================
    log('model', 'Verifique a sintaxe do arquivo utils.ts');

    const validation = await syntaxValidator.validate(path.join(testDir, 'src/utils.ts'));
    log('success', `Sintaxe: ${validation.valid ? 'VALIDA' : 'INVALIDA'}`);
    if (!validation.valid) {
      log('error', validation.output);
    } else {
      log('success', validation.output);
    }

    // ============================================================
    // FASE 7: CRIAR ARQUIVO COM ERRO DE SINTAXE
    // ============================================================
    log('model', 'Crie um arquivo src/broken.ts com erro de sintaxe (faltando closing brace)');

    log('tool', `write_file(path: "src/broken.ts", content: "...")`);
    const brokenContent = `export function broken() {
  const x = 1;
  const y = 2;
  console.log(x + y);
// Missing closing brace
`;
    const brokenResult = await toolSystem.execute('write_file', {
      path: 'src/broken.ts',
      content: brokenContent
    });
    log('result', `write_file: ${brokenResult.success ? 'OK (file created)' : brokenResult.error}`);

    log('agent', 'Arquivo criado com erro intencional. Corrigindo...');

    // ============================================================
    // FASE 8: CORRIGIR ERRO
    // ============================================================
    log('model', 'Corrija o arquivo broken.ts usando apply_patch');

    log('tool', `apply_patch(path: "src/broken.ts", operations: [...])`);
    const fixResult = await toolSystem.execute('apply_patch', {
      path: 'src/broken.ts',
      operations: [
        {
          find: `console.log(x + y);`,
          replace: `console.log(x + y);\n}`
        }
      ]
    });
    log('result', `apply_patch fix: ${fixResult.success ? 'OK' : 'FAILED'}`);
    if (!fixResult.success && fixResult.error) {
      log('error', fixResult.error);
    } else {
      log('success', fixResult.output.substring(0, 200));
    }

    // Verificar sintaxe após correção
    const fixedValidation = await syntaxValidator.validate(path.join(testDir, 'src/broken.ts'));
    log('success', `Sintaxe apos correcao: ${fixedValidation.valid ? 'VALIDA' : 'INVALIDA'}`);
    log('success', fixedValidation.output);

    // ============================================================
    // FASE 9: ESTRUTURA FINAL
    // ============================================================
    log('model', 'Mostre a estrutura final do projeto');

    async function showTree(dir: string, indent = ''): Promise<void> {
      const entries = await fs.readdir(dir, { withFileTypes: true });
      for (const entry of entries) {
        if (entry.name === '.test-complex-io') continue;
        if (entry.isDirectory()) {
          log('success', `${indent}📁 ${entry.name}/`);
          await showTree(path.join(dir, entry.name), indent + '   ');
        } else {
          log('success', `${indent}📄 ${entry.name}`);
        }
      }
    }

    await showTree(testDir);

    // Mostrar conteúdo final de App.tsx
    log('model', 'Mostre o conteúdo final de App.tsx');
    const finalAppContent = await fs.readFile(path.join(testDir, 'src/App.tsx'), 'utf-8');
    log('success', `src/App.tsx:\n${finalAppContent}`);

    // Mostrar conteúdo final do Header.tsx
    const finalHeaderContent = await fs.readFile(path.join(testDir, 'src/components/Header.tsx'), 'utf-8');
    log('success', `src/components/Header.tsx:\n${finalHeaderContent}`);

    // ============================================================
    // FASE 10: TENTAR SOBREESCREVER (DEVE FALHAR)
    // ============================================================
    log('model', 'Tente sobrescrever App.tsx sem append (deve falhar)');

    log('tool', `write_file(path: "src/App.tsx", content: "// NEW CONTENT")`);
    const overwriteResult = await toolSystem.execute('write_file', {
      path: 'src/App.tsx',
      content: '// NEW CONTENT THAT SHOULD NOT WORK'
    });
    log('result', `Sobrescrita: ${overwriteResult.success ? 'PERMITIDA (BUG!)' : 'BLOQUEADA (correto)'}`);
    if (!overwriteResult.success) {
      log('success', overwriteResult.error || 'Protegido contra sobrescrita');
    }

    // ============================================================
    // LIMPEZA FINAL
    // ============================================================
    log('agent', 'Teste completo. Fazendo cleanup...');
    try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}

    // Print summary
    printLogs();

    log('success', 'TESTES DE I/O COMPLEXOS CONCLUIDOS');
    log('success', 'Verifique o log acima para detalhes da interacao');

  } catch (error: any) {
    log('error', `ERRO: ${error.message}`);
    console.error(error.stack);
    try { await fs.rm(testDir, { recursive: true, force: true }); } catch {}
  }
}

main().catch(console.error);
