import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function testWriteFile(toolSystem: any, filePath: string, content: string, append = false) {
  console.log(`\n📝 write_file: ${filePath}${append ? ' (append)' : ''}`);
  const result = await toolSystem.execute('write_file', { path: filePath, content, append });
  console.log(`   Success: ${result.success}`);
  if (result.error) console.log(`   Error: ${result.error}`);
  else console.log(`   Output: ${result.output}`);
  return result;
}

async function testApplyPatch(toolSystem: any, filePath: string, operations: any[]) {
  console.log(`\n✏️  apply_patch: ${filePath}`);
  const result = await toolSystem.execute('apply_patch', { path: filePath, operations });
  console.log(`   Success: ${result.success}`);
  if (result.error) console.log(`   Error: ${result.error}`);
  else console.log(`   Output: ${result.output.substring(0, 200)}...`);
  return result;
}

async function testReadFile(toolSystem: any, filePath: string) {
  console.log(`\n📖 read_file: ${filePath}`);
  const result = await toolSystem.execute('read_file', { path: filePath });
  console.log(`   Success: ${result.success}`);
  if (result.error) console.log(`   Error: ${result.error}`);
  else console.log(`   Content (${result.output.split('\n').length} lines):\n${result.output.substring(0, 100)}...`);
  return result;
}

async function testMkdir(dirPath: string) {
  console.log(`\n📁 mkdir: ${dirPath}`);
  await fs.mkdir(dirPath, { recursive: true });
  const exists = await fs.stat(dirPath);
  console.log(`   Created: ${exists.isDirectory()}`);
}

async function testRmdir(dirPath: string) {
  console.log(`\n🗑️  rmdir: ${dirPath}`);
  await fs.rm(dirPath, { recursive: true, force: true });
  console.log(`   Removed`);
}

async function testRm(filePath: string) {
  console.log(`\n🗑️  rm: ${filePath}`);
  await fs.rm(filePath);
  console.log(`   Removed`);
}

async function testListDir(dirPath: string) {
  console.log(`\n📂 list_dir: ${dirPath}`);
  const files = await fs.readdir(dirPath);
  console.log(`   Files: ${files.join(', ')}`);
}

async function runTests() {
  console.log('═'.repeat(60));
  console.log('TESTE COMPLEXO DE I/O - CRIACAO/EDICAO/DELECAO');
  console.log('═'.repeat(60));

  const { ToolSystem } = await import('./dist/tools.js');
  const toolSystem = new ToolSystem();

  const testDir = path.join(__dirname, '.test-io');
  const projectDir = path.join(testDir, 'meu-projeto');
  const srcDir = path.join(projectDir, 'src');
  const componentsDir = path.join(srcDir, 'components');

  try {
    // LIMPEZA INICIAL
    console.log('\n🧹 LIMPEZA INICIAL');
    try {
      await fs.rm(testDir, { recursive: true, force: true });
    } catch {}

    // 1. CRIAR ESTRUTURA DE DIRETORIOS
    console.log('\n' + '─'.repeat(60));
    console.log('1. CRIAR ESTRUTURA DE DIRETORIOS');
    await testMkdir(componentsDir);

    // 2. CRIAR ARQUIVOS INCREMENTALMENTE
    console.log('\n' + '─'.repeat(60));
    console.log('2. CRIAR ARQUIVOS INCREMENTALMENTE (append)');

    await testWriteFile(toolSystem, path.join(srcDir, 'index.ts'), '// Entry point\n');

    await testWriteFile(toolSystem, path.join(srcDir, 'index.ts'), 'import { App } from "./app";\n', true);
    await testWriteFile(toolSystem, path.join(srcDir, 'index.ts'), 'import { Config } from "./config";\n', true);
    await testWriteFile(toolSystem, path.join(srcDir, 'index.ts'), '\nconst app = new App(new Config());\napp.start();\n', true);

    await testReadFile(toolSystem, path.join(srcDir, 'index.ts'));

    // 3. CRIAR COMPONENTES
    console.log('\n' + '─'.repeat(60));
    console.log('3. CRIAR COMPONENTES');

    await testWriteFile(toolSystem, path.join(componentsDir, 'Button.tsx'), `export interface ButtonProps {
  label: string;
  onClick: () => void;
  variant?: 'primary' | 'secondary';
}

export function Button({ label, onClick, variant = 'primary' }: ButtonProps) {
  return \`<button class="btn btn-\${variant}">\${label}</button>\`;
}
`);

    await testWriteFile(toolSystem, path.join(componentsDir, 'Header.tsx'), `export function Header() {
  return \`
    <header class="header">
      <h1>Meu Projeto</h1>
    </header>
  \`;
}
`);

    await testWriteFile(toolSystem, path.join(componentsDir, 'Footer.tsx'), `export function Footer() {
  const year = new Date().getFullYear();
  return \`
    <footer>
      <p>&copy; \${year} - Todos os direitos reservados</p>
    </footer>
  \`;
}
`);

    // 4. EDITAR ARQUIVOS COM PATCH
    console.log('\n' + '─'.repeat(60));
    console.log('4. EDITAR ARQUIVOS COM PATCH');

    await testApplyPatch(toolSystem, path.join(componentsDir, 'Button.tsx'), [
      {
        find: `variant?: 'primary' | 'secondary';`,
        replace: `variant?: 'primary' | 'secondary' | 'danger';`
      },
      {
        find: `return \`<button class="btn btn-\${variant}">\${label}</button>\`;`,
        replace: `return \`<button class="btn btn-\${variant}" onclick="handleClick()">\${label}</button>\`;`
      }
    ]);

    // 5. CRIAR ARQUIVO COM SYNTAX ERROR PARA TESTAR VALIDACAO
    console.log('\n' + '─'.repeat(60));
    console.log('5. CRIAR ARQUIVO COM SYNTAX ERROR');

    await testWriteFile(toolSystem, path.join(srcDir, 'broken.ts'), `export function brokenFunction() {
  const x = 1;
  const y = 2;
  // Missing closing brace
  console.log(x + y);
`);

    // 6. CORRIGIR SYNTAX ERROR COM PATCH
    console.log('\n' + '─'.repeat(60));
    console.log('6. CORRIGIR SYNTAX ERROR');

    await testApplyPatch(toolSystem, path.join(srcDir, 'broken.ts'), [
      {
        find: `  console.log(x + y);`,
        replace: `  console.log(x + y);\n}`
      }
    ]);

    // 7. VERIFICAR ESTRUTURA FINAL
    console.log('\n' + '─'.repeat(60));
    console.log('7. VERIFICAR ESTRUTURA FINAL');

    await testListDir(testDir);
    await testListDir(projectDir);
    await testListDir(srcDir);
    await testListDir(componentsDir);

    // 8. DELETAR ARQUIVOS
    console.log('\n' + '─'.repeat(60));
    console.log('8. DELETAR ARQUIVOS');

    await testRm(path.join(srcDir, 'broken.ts'));
    console.log('   Deleted: broken.ts');

    // 9. REORGANIZAR - MOVER CONTEUDO
    console.log('\n' + '─'.repeat(60));
    console.log('9. REORGANIZAR - MOVER CONTEUDO');

    const newDir = path.join(srcDir, 'ui');
    await testMkdir(newDir);

    const buttonContent = await fs.readFile(path.join(componentsDir, 'Button.tsx'), 'utf-8');
    const headerContent = await fs.readFile(path.join(componentsDir, 'Header.tsx'), 'utf-8');

    await testWriteFile(toolSystem, path.join(newDir, 'Button.tsx'), buttonContent);
    await testWriteFile(toolSystem, path.join(newDir, 'Header.tsx'), headerContent);

    await testRm(path.join(componentsDir, 'Button.tsx'));
    await testRm(path.join(componentsDir, 'Header.tsx'));

    await testListDir(componentsDir);
    await testListDir(newDir);

    // 10. DELETAR DIRETORIOS VAZIOS
    console.log('\n' + '─'.repeat(60));
    console.log('10. DELETAR DIRETORIOS VAZIOS');

    await testRmdir(componentsDir);
    console.log('   Deleted: components/');

    await testListDir(srcDir);

    // 11. TESTAR VALIDACAO DE SINTAXE
    console.log('\n' + '─'.repeat(60));
    console.log('11. TESTAR VALIDACAO DE SINTAXE');

    await testWriteFile(toolSystem, path.join(srcDir, 'valid.ts'), `export function calculateSum(a: number, b: number): number {
  return a + b;
}

console.log(calculateSum(1, 2));
`);

    await testApplyPatch(toolSystem, path.join(srcDir, 'valid.ts'), [
      {
        find: `return a + b;`,
        replace: `return a + b + 1;`
      }
    ]);

    // 12. TESTAR OVERWRITE BLOQUEADO
    console.log('\n' + '─'.repeat(60));
    console.log('12. TESTAR PROtecaO DE SOBRESCRITA');

    const overwriteResult = await testWriteFile(toolSystem, path.join(srcDir, 'index.ts'), 'NEW CONTENT WITHOUT APPEND', false);
    console.log(`   Sobrescrita bloqueada: ${!overwriteResult.success}`);

    // 13. OUTPUT FINAL
    console.log('\n' + '─'.repeat(60));
    console.log('13. OUTPUT FINAL DOS ARQUIVOS');

    const finalFiles = ['index.ts', 'valid.ts'];
    for (const file of finalFiles) {
      const filePath = path.join(srcDir, file);
      const exists = await fs.stat(filePath).catch(() => null);
      if (exists) {
        const content = await fs.readFile(filePath, 'utf-8');
        console.log(`\n📄 ${file}:`);
        console.log('─'.repeat(40));
        console.log(content);
      }
    }

    // LIMPEZA FINAL
    console.log('\n' + '─'.repeat(60));
    console.log('🧹 LIMPEZA FINAL');
    await fs.rm(testDir, { recursive: true, force: true });
    console.log('   Test directory removed');

    console.log('\n' + '═'.repeat(60));
    console.log('✅ TESTES COMPLETOS');
    console.log('═'.repeat(60));

  } catch (error: any) {
    console.error('\n❌ ERRO:', error.message);
    console.error(error.stack);
    try {
      await fs.rm(testDir, { recursive: true, force: true });
    } catch {}
    process.exit(1);
  }
}

runTests();
