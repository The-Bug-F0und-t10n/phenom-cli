import {
  formatToolResultForModelPolicy,
  normalizeToolNameWithAliases
} from './use-cases/tool-execution-policy.js';

let passed = 0;
const tests: { name: string; fn: () => void }[] = [];

function test(name: string, fn: () => void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error(msg);
}

test('normalizeToolNameWithAliases resolves known aliases when target tool exists', () => {
  const hasTool = (name: string) => ['read_file', 'write_file', 'apply_patch'].includes(name);
  const resolved = normalizeToolNameWithAliases('read', hasTool);
  assert(resolved === 'read_file', `expected read_file, got ${resolved}`);
});

test('normalizeToolNameWithAliases preserves original when alias target does not exist', () => {
  const hasTool = (_name: string) => false;
  const resolved = normalizeToolNameWithAliases('read', hasTool);
  assert(resolved === 'read', `expected read, got ${resolved}`);
});

test('formatToolResultForModelPolicy formats success fallback with empty output', () => {
  const out = formatToolResultForModelPolicy('date', { success: true, output: '', error: null });
  assert(out === 'date: success', `unexpected output: ${out}`);
});

test('formatToolResultForModelPolicy truncates long output', () => {
  const raw = 'x'.repeat(45000);
  const out = formatToolResultForModelPolicy('read_file', { success: true, output: raw, error: null });
  assert(out.includes('...[truncated:'), 'expected truncation marker');
  assert(out.length < raw.length, 'expected truncated output to be shorter');
});

test('formatToolResultForModelPolicy formats error consistently', () => {
  const out = formatToolResultForModelPolicy('read_file', { success: false, output: '', error: 'not found' });
  assert(out === 'Error (read_file): not found', `unexpected output: ${out}`);
});

function main(): void {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (error: any) {
      failures++;
      console.log(`  ❌ ${name}`);
      console.log(`     ${error.message}`);
    }
  }

  console.log(`\nTool execution policy tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
