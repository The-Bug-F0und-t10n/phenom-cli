import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import { ToolSystem } from '../../tools.js';
import { formatToolResultForNative } from '../../model-capabilities.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

// --- apply_patch: search/replace (bug fix) ---
test('apply_patch: aceita operações com search/replace (nao so find)', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.ts');
  await fs.writeFile(filePath, 'const x = 1;\nconst y = 2;\n', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('apply_patch', {
    path: filePath,
    operations: [
      { search: 'const x = 1;', replace: 'const x = 10;' }
    ]
  });

  assert(result.success === true, `patch should succeed: ${result.error}`);
  assert(result.output.includes('Patch aplicado'), `output should confirm patch: ${result.output}`);

  const content = await fs.readFile(filePath, 'utf-8');
  assert(content.includes('const x = 10;'), 'file should contain updated value');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('apply_patch: aceita operações com find/replace (compatibilidade reversa)', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.ts');
  await fs.writeFile(filePath, 'const a = 1;\nconst b = 2;\nconst c = 3;\n', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('apply_patch', {
    path: filePath,
    operations: [
      { find: 'const b = 2;', replace: 'const b = 20;' }
    ]
  });

  assert(result.success === true, `patch should succeed: ${result.error}`);

  const content = await fs.readFile(filePath, 'utf-8');
  assert(content.includes('const b = 20;'), 'file should contain updated value');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('apply_patch: rejeita tentativa de reescrita total', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.ts');
  await fs.writeFile(filePath, 'todo content\n', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('apply_patch', {
    path: filePath,
    operations: [
      { search: 'todo content', replace: 'completely different' }
    ]
  });

  // Should reject because the search text matches the entire trimmed file
  assert(result.success === false, 'should reject full file replacement via apply_patch');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('apply_patch: retorna erro claro quando arquivo nao existe', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('apply_patch', {
    path: '/tmp/nonexistent-file-12345.ts',
    operations: [{ search: 'foo', replace: 'bar' }]
  });

  assert(result.success === false, 'should fail for nonexistent file');
  assert((result.error || '').includes('não existe'), `error should mention file not exists: ${result.error}`);
});

test('apply_patch: falha quando patch nao altera nada (evita loop silencioso)', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.ts');
  await fs.writeFile(filePath, 'const x = 1;\nconst y = 2;\n', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('apply_patch', {
    path: filePath,
    operations: [
      { search: 'const x = 1;', replace: 'const x = 1;' }
    ]
  });

  assert(result.success === false, 'no-op patch should fail');
  assert(!!result.error, `expected descriptive error: ${result.error}`);

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('apply_patch: edita por faixa de linhas (startLine/endLine)', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.ts');
  await fs.writeFile(filePath, 'line1\nline2\nline3\nline4\n', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('apply_patch', {
    path: filePath,
    startLine: 2,
    endLine: 3,
    replace: 'new2\nnew3'
  });

  assert(result.success === true, `line-range patch should succeed: ${result.error}`);
  assert(result.output.includes('linhas 2-3'), `output should mention edited line range: ${result.output}`);

  const content = await fs.readFile(filePath, 'utf-8');
  assert(content === 'line1\nnew2\nnew3\nline4\n', `unexpected content:\n${content}`);

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('read_file: retorna metadados estruturados com path/range/content', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'sample.txt');
  await fs.writeFile(filePath, 'a\nb\nc\nd\n', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('read_file', {
    path: filePath,
    startLine: 2,
    endLine: 3
  });

  assert(result.success === true, `read_file should succeed: ${result.error}`);
  const out = String(result.output || '');
  assert(out.includes('[READ_FILE]'), 'missing read_file header');
  assert(out.includes(`path: ${filePath}`), 'missing path metadata');
  assert(out.includes('range: 2-3'), 'missing range metadata');
  assert(out.includes('---BEGIN CONTENT---'), 'missing begin marker');
  assert(out.includes('b\nc'), 'missing selected content');
  assert(out.includes('---END CONTENT---'), 'missing end marker');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

// --- write_file: directory creation & overwrite ---
test('write_file: cria diretórios automaticamente', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const nestedDir = path.join(tmpDir, 'a', 'b', 'c');
  const filePath = path.join(nestedDir, 'test.txt');

  const tools = new ToolSystem();
  const result = await tools.execute('write_file', {
    path: filePath,
    content: 'nested content'
  });

  assert(result.success === true, `write_file in nested dir should succeed: ${result.error}`);

  const content = await fs.readFile(filePath, 'utf-8');
  assert(content === 'nested content', 'file content should match');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('write_file: sobrescreve com overwrite=true', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.txt');
  await fs.writeFile(filePath, 'original', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('write_file', {
    path: filePath,
    content: 'modified',
    overwrite: true
  });

  assert(result.success === true, `overwrite should succeed: ${result.error}`);

  const content = await fs.readFile(filePath, 'utf-8');
  assert(content === 'modified', 'file should be overwritten');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('write_file: sobrescreve sem backup por padrao (overwrite implicito)', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.txt');
  const bakPath = filePath + '.bak';
  await fs.writeFile(filePath, 'original', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('write_file', {
    path: filePath,
    content: 'modified'
  });

  assert(result.success === true, `should overwrite: ${result.error}`);
  assert(!result.output?.includes('[BAK]'), `should NOT mention backup: ${result.output}`);

  const fileContent = await fs.readFile(filePath, 'utf-8');
  assert(fileContent === 'modified', `file should have new content: ${fileContent}`);

  const bakExists = await fs.stat(bakPath).then(() => true).catch(() => false);
  assert(!bakExists, 'backup file should NOT exist');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('write_file: faz backup quando overwrite=false explicitamente', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.txt');
  const bakPath = filePath + '.bak';
  await fs.writeFile(filePath, 'original', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('write_file', {
    path: filePath,
    content: 'modified',
    overwrite: false
  });

  assert(result.success === true, `should backup and overwrite: ${result.error}`);
  assert(result.output?.includes('[BAK]'), `output should mention backup: ${result.output}`);

  const fileContent = await fs.readFile(filePath, 'utf-8');
  assert(fileContent === 'modified', `file should have new content: ${fileContent}`);

  const bakExists = await fs.stat(bakPath).then(() => true).catch(() => false);
  assert(bakExists, 'backup file should exist');
  if (bakExists) {
    const bakContent = await fs.readFile(bakPath, 'utf-8');
    assert(bakContent === 'original', `backup should have original content: ${bakContent}`);
  }

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('write_file: conteudo identico retorna sucesso sem escrever', async () => {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'test.txt');
  await fs.writeFile(filePath, 'same content', 'utf-8');

  const tools = new ToolSystem();
  const result = await tools.execute('write_file', {
    path: filePath,
    content: 'same content'
  });

  assert(result.success === true, 'identical content should succeed');
  assert((result.output || '').includes('[NO_OP]'), `should mark no-op: ${result.output}`);
  assert((result.output || '').includes('unchanged'), `should say unchanged: ${result.output}`);

  await fs.rm(tmpDir, { recursive: true, force: true });
});

// --- normalizeToolArgs behavior (via ToolSystem directly) ---
test('list_dir: aceita file_path alias', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('list_dir', {
    file_path: '.'
  });

  assert(result.success === true, `list_dir with file_path should work: ${result.error}`);
});

test('delete_file: bloqueia caminho fora do workspace', async () => {
  const tools = new ToolSystem();
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));
  const filePath = path.join(tmpDir, 'outside.txt');
  await fs.writeFile(filePath, 'outside', 'utf-8');

  const result = await tools.execute('delete_file', { path: filePath });
  assert(result.success === false, 'delete_file should fail for outside workspace path');
  assert((result.error || '').includes('outside workspace'), `unexpected error: ${result.error}`);

  const stillExists = await fs.stat(filePath).then(() => true).catch(() => false);
  assert(stillExists, 'file should not be deleted when outside workspace');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

test('delete_dir: bloqueia caminho fora do workspace', async () => {
  const tools = new ToolSystem();
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-test-'));

  const result = await tools.execute('delete_dir', { path: tmpDir });
  assert(result.success === false, 'delete_dir should fail for outside workspace path');
  assert((result.error || '').includes('outside workspace'), `unexpected error: ${result.error}`);

  const stillExists = await fs.stat(tmpDir).then(() => true).catch(() => false);
  assert(stillExists, 'directory should not be deleted when outside workspace');

  await fs.rm(tmpDir, { recursive: true, force: true });
});

// --- formatToolResultForNative ---
test('formatToolResultForNative: sucesso com output é conciso', () => {
  const result = formatToolResultForNative({ success: true, output: 'arquivo criado', error: null });
  assert(result.startsWith('[OK]'), `should start with [OK]: ${result}`);
  assert(result.length < 100, `should be concise: ${result.length} chars`);
});

test('formatToolResultForNative: erro é prefixado com [FAIL]', () => {
  const result = formatToolResultForNative({ success: false, output: '', error: 'Arquivo existe' });
  assert(result.startsWith('[FAIL]'), `should start with [FAIL]: ${result}`);
});

test('formatToolResultForNative: output longo é truncado em 4000', () => {
  const long = 'x'.repeat(5000);
  const result = formatToolResultForNative({ success: true, output: long, error: null });
  assert(result.length <= 4020, `long output should be truncated: ${result.length}`);
  assert(result.includes('truncated'), 'should indicate truncation');
});

test('formatToolResultForNative: null result retorna OK', () => {
  const result = formatToolResultForNative(null);
  assert(result.startsWith('[OK]'), 'null result should return OK');
});

test('formatToolResultForNative: sucesso sem output é OK conciso', () => {
  const result = formatToolResultForNative({ success: true, output: '', error: null });
  assert(result === '[OK] Tool completed', 'empty output should return generic OK');
});

// --- Runner ---
async function main() {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (error: any) {
      failures++;
      console.log(`  ❌ ${name}`);
      console.log(`     ${error.message}`);
    }
  }

  console.log(`\nResultado: ${passed}/${tests.length} testes passaram`);
  process.exit(failures > 0 ? 1 : 0);
}

main();
