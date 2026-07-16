/**
 * Smoke tests for buildToolsSchemaBlock — the helper that injects tool
 * schemas into the system prompt when running in text-protocol mode (no
 * --jinja on the server). Verifies the output shape matches what the
 * Modelfile TEMPLATE produces.
 */

import { strict as assert } from 'node:assert';
import { buildToolsSchemaBlock } from '../../use-cases/build-tools-schema-block.js';
import type { ApiToolDef } from '../../api-client.js';

const tests: Array<{ name: string; fn: () => void }> = [];
function test(name: string, fn: () => void) { tests.push({ name, fn }); }
let passed = 0;

test('returns empty string for undefined tools', () => {
  assert.equal(buildToolsSchemaBlock(undefined), '');
  assert.equal(buildToolsSchemaBlock([]), '');
});

test('emits <tools>...</tools> block with each tool as one JSON line', () => {
  const tools: ApiToolDef[] = [
    {
      type: 'function',
      function: {
        name: 'read_file',
        description: 'Read a file',
        parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] }
      }
    },
    {
      type: 'function',
      function: {
        name: 'write_file',
        description: 'Write a file',
        parameters: { type: 'object', properties: {} }
      }
    }
  ];
  const out = buildToolsSchemaBlock(tools);
  assert.ok(out.includes('<tools>'), 'should have <tools> opener');
  assert.ok(out.includes('</tools>'), 'should have </tools> closer');
  assert.ok(out.includes('"name":"read_file"'), 'should include read_file');
  assert.ok(out.includes('"name":"write_file"'), 'should include write_file');
  // One JSON object per tool — count by counting opening braces of "function":
  const fnCount = (out.match(/"function":\{/g) || []).length;
  assert.equal(fnCount, 2, `expected 2 tools, got ${fnCount}`);
});

test('emits tool_call example structure', () => {
  const tools: ApiToolDef[] = [{
    type: 'function',
    function: { name: 'x', description: 'y', parameters: { type: 'object', properties: {} } }
  }];
  const out = buildToolsSchemaBlock(tools);
  assert.ok(out.includes('<tool_call>'), 'should have <tool_call> tag in example');
  assert.ok(out.includes('</tool_call>'), 'should have </tool_call> closer');
  assert.ok(out.includes('"name":'), 'example has name field');
  assert.ok(out.includes('"arguments":'), 'example has arguments field');
});

test('truncates long descriptions to maxDescChars', () => {
  const longDesc = 'a'.repeat(500);
  const tools: ApiToolDef[] = [{
    type: 'function',
    function: { name: 'x', description: longDesc, parameters: { type: 'object', properties: {} } }
  }];
  const out = buildToolsSchemaBlock(tools, { maxDescChars: 50 });
  // Truncated text ends with ellipsis "…"
  assert.ok(out.includes('aaaaaa…'), 'description should be truncated and end with …');
  // Make sure the full 500-char description is NOT in there.
  assert.ok(!out.includes('a'.repeat(100)), 'full long description should NOT be present');
});

test('skips tools with no name', () => {
  const tools: ApiToolDef[] = [
    { type: 'function', function: { name: '', description: '', parameters: { type: 'object', properties: {} } } },
    { type: 'function', function: { name: 'ok', description: '', parameters: { type: 'object', properties: {} } } }
  ];
  const out = buildToolsSchemaBlock(tools);
  // Only one function definition line.
  const fnCount = (out.match(/"function":\{/g) || []).length;
  assert.equal(fnCount, 1, `expected 1 valid tool (empty-name skipped), got ${fnCount}`);
});

function main() {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (e: any) {
      failures++;
      console.log(`  ❌ ${name}\n     ${e?.message || e}`);
    }
  }
  console.log(`Tools-schema-block tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
}

main();
