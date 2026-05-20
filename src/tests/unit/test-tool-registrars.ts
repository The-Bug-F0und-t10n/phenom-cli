import { ToolSystem } from '../../tools.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error(msg);
}

test('run_code rejects empty command', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('run_code', { command: '' });
  assert(!result.success, 'expected failure');
  assert((result.error || '').includes('Comando vazio'), `unexpected error: ${result.error}`);
});

test('grep_file rejects invalid regex before executing rg', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('grep_file', { pattern: '[' });
  assert(!result.success, 'expected failure');
  assert((result.error || '').includes('Regex inválido'), `unexpected error: ${result.error}`);
});

test('web_search rejects empty query', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('web_search', { query: '   ' });
  assert(!result.success, 'expected failure');
  assert((result.error || '').includes('Query não fornecida'), `unexpected error: ${result.error}`);
});

test('find_function rejects missing name', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('find_function', { path: '.' });
  assert(!result.success, 'expected failure');
  assert((result.error || '').includes('Nome não fornecido'), `unexpected error: ${result.error}`);
});

test('extract_block rejects invalid startLine', async () => {
  const tools = new ToolSystem();
  const result = await tools.execute('extract_block', { path: 'package.json', startLine: 0 });
  assert(!result.success, 'expected failure');
  assert((result.error || '').includes('startLine inválido'), `unexpected error: ${result.error}`);
});

async function main(): Promise<void> {
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
  console.log(`\nTool registrars tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
