import { parseToolCallOrFinal, parseToolCallOrFinalDetailed } from './tool-call-parser.js';

let passed = 0;
const tests: { name: string; fn: () => void }[] = [];

function test(name: string, fn: () => void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error(msg);
}

test('parse tagged <tool_call> JSON', () => {
  const raw = '<tool_call>{"name":"read_file","arguments":{"path":"src/index.ts"}}</tool_call>';
  const parsed = parseToolCallOrFinal(raw);
  const detailed = parseToolCallOrFinalDetailed(raw);
  assert(parsed?.type === 'tool', 'expected tool');
  assert(detailed.strategy === 'tagged_tool_call', `strategy mismatch: ${detailed.strategy}`);
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'read_file', `toolName mismatch: ${parsed.toolName}`);
    assert(parsed.args.path === 'src/index.ts', 'path mismatch');
  }
});

test('parse protocol JSON tool object', () => {
  const raw = '{"type":"tool","toolName":"list_dir","args":{"path":"."}}';
  const parsed = parseToolCallOrFinal(raw);
  const detailed = parseToolCallOrFinalDetailed(raw);
  assert(parsed?.type === 'tool', 'expected tool');
  assert(detailed.strategy === 'primary_json', `strategy mismatch: ${detailed.strategy}`);
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'list_dir', 'toolName mismatch');
  }
});

test('parse OpenAI-like function object', () => {
  const raw = '{"name":"write_file","arguments":{"path":"a.txt","content":"ok"}}';
  const parsed = parseToolCallOrFinal(raw);
  assert(parsed?.type === 'tool', 'expected tool');
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'write_file', 'toolName mismatch');
    assert(parsed.args.content === 'ok', 'content mismatch');
  }
});

test('parse OpenAI-like function object with JSON string arguments', () => {
  const raw = '{"name":"read_file","arguments":"{\\"path\\":\\"src/index.ts\\"}"}';
  const parsed = parseToolCallOrFinal(raw);
  assert(parsed?.type === 'tool', 'expected tool');
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'read_file', 'toolName mismatch');
    assert(parsed.args.path === 'src/index.ts', 'path mismatch');
  }
});

test('parse protocol JSON tool object with args as JSON string', () => {
  const raw = '{"type":"tool","toolName":"apply_patch","args":"{\\"path\\":\\"a.txt\\",\\"operations\\":[{\\"search\\":\\"x\\",\\"replace\\":\\"y\\"}]}"}';
  const parsed = parseToolCallOrFinal(raw);
  assert(parsed?.type === 'tool', 'expected tool');
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'apply_patch', 'toolName mismatch');
    assert(parsed.args.path === 'a.txt', 'path mismatch');
  }
});

test('parse final JSON response', () => {
  const raw = '{"type":"final","content":"done"}';
  const parsed = parseToolCallOrFinal(raw);
  assert(parsed?.type === 'final', 'expected final');
  if (parsed?.type === 'final') {
    assert(parsed.content === 'done', 'content mismatch');
  }
});

test('parse embedded JSON inside text', () => {
  const raw = 'some prose before\n{"type":"tool","toolName":"date","args":{}}\nafter';
  const detailed = parseToolCallOrFinalDetailed(raw);
  const parsed = detailed.response;
  assert(parsed?.type === 'tool', 'expected tool from embedded json');
  assert(
    detailed.strategy === 'primary_json' ||
      detailed.strategy === 'embedded_json_scan' ||
      detailed.strategy === 'cleaned_retry',
    `strategy mismatch: ${detailed.strategy}`
  );
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'date', 'toolName mismatch');
  }
});

test('reject broken tool JSON as final text', () => {
  const raw = '{"type":"tool","toolName":"read_file"';
  const detailed = parseToolCallOrFinalDetailed(raw);
  assert(detailed.response === null, 'expected null for broken tool JSON');
  assert(detailed.strategy === 'invalid_broken_tool_json', `strategy mismatch: ${detailed.strategy}`);
});

test('accept plain text as final when not JSON-like', () => {
  const raw = 'Tudo concluído com sucesso.';
  const parsed = parseToolCallOrFinal(raw);
  assert(parsed?.type === 'final', 'expected final');
});

test('prefer tool when text contains both final and tool JSON blocks', () => {
  const raw = [
    'texto inicial',
    '{"type":"final","content":"quase pronto"}',
    '{"type":"tool","toolName":"write_file","args":{"path":"hello-world.html","content":"ok"}}'
  ].join('\n');
  const parsed = parseToolCallOrFinal(raw);
  assert(parsed?.type === 'tool', `expected tool, got ${parsed?.type}`);
  if (parsed?.type === 'tool') {
    assert(parsed.toolName === 'write_file', `tool mismatch: ${parsed.toolName}`);
  }
});

test('skip malformed JSON and parse valid tagged tool call', () => {
  const raw = [
    'vou fazer isso',
    '{"type":"tool","toolName":"write_file"',
    '<tool_call>{"name":"apply_patch","arguments":{"path":"hello-world.html","operations":[]}}</tool_call>'
  ].join('\n');
  const detailed = parseToolCallOrFinalDetailed(raw);
  assert(detailed.response?.type === 'tool', `expected tool, got ${detailed.response?.type}`);
  assert(detailed.strategy === 'tagged_tool_call', `strategy mismatch: ${detailed.strategy}`);
  if (detailed.response?.type === 'tool') {
    assert(detailed.response.toolName === 'apply_patch', `tool mismatch: ${detailed.response.toolName}`);
  }
});

function main(): void {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      failures++;
      console.log(`  ❌ ${name}`);
      console.log(`     ${message}`);
    }
  }
  console.log(`\nTool-call parser tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
