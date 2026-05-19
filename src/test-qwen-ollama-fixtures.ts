import { parseToolCallOrFinalDetailed } from './tool-call-parser.js';
import {
  detectModelCapabilities,
  extractNativeToolCalls,
  toolsToOllamaFormat,
  toolsToOpenAIFormat
} from './model-capabilities.js';
import {
  QWEN35_NATIVE_TOOLCALL_RESPONSE,
  QWEN35_OPENAI_COMPAT_TOOLCALL_RESPONSE,
  QWEN35_REASONING_MODEL_NAME,
  QWEN35_REASONING_TEXT_RESPONSE,
  QWEN35_VISION_MODEL_NAME
} from './fixtures/qwen-ollama-fixtures.js';

let passed = 0;
const tests: { name: string; fn: () => void }[] = [];

function test(name: string, fn: () => void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

test('extractNativeToolCalls parses native Ollama qwen3.5 payload', () => {
  const calls = extractNativeToolCalls(QWEN35_NATIVE_TOOLCALL_RESPONSE);
  assert(calls.length === 1, `expected 1 call, got ${calls.length}`);
  assert(calls[0].tool === 'write_file', `tool mismatch: ${calls[0].tool}`);
  assert(calls[0].arguments.path === 'hello-world.html', 'path mismatch');
});

test('extractNativeToolCalls parses OpenAI-compat qwen3.5 payload', () => {
  const calls = extractNativeToolCalls(QWEN35_OPENAI_COMPAT_TOOLCALL_RESPONSE.choices[0].message);
  assert(calls.length === 1, `expected 1 call, got ${calls.length}`);
  assert(calls[0].tool === 'apply_patch', `tool mismatch: ${calls[0].tool}`);
});

test('fallback parser extracts tool call from qwen3.5 reasoning text', () => {
  const parsed = parseToolCallOrFinalDetailed(QWEN35_REASONING_TEXT_RESPONSE);
  assert(parsed.response?.type === 'tool', `expected tool, got ${parsed.response?.type}`);
  if (parsed.response?.type === 'tool') {
    assert(parsed.response.toolName === 'write_file', `tool mismatch: ${parsed.response.toolName}`);
  }
});

test('qwen3.5 fixture model names advertise expected capabilities', () => {
  const visionCaps = detectModelCapabilities(QWEN35_VISION_MODEL_NAME);
  const reasoningCaps = detectModelCapabilities(QWEN35_REASONING_MODEL_NAME);
  assert(visionCaps.supportsVision, 'vision should be enabled');
  assert(reasoningCaps.supportsReasoning, 'reasoning should be enabled');
  assert(reasoningCaps.supportsNativeTools, 'native tools should be enabled for qwen family');
});

test('tool format adapters preserve function schema', () => {
  const defs = [
    {
      name: 'write_file',
      description: 'write a file',
      parameters: {
        type: 'object' as const,
        properties: {
          path: { type: 'string' },
          content: { type: 'string' }
        },
        required: ['path', 'content']
      }
    }
  ];
  const ollama = toolsToOllamaFormat(defs);
  const openai = toolsToOpenAIFormat(defs);
  assert(ollama[0].function.name === 'write_file', 'ollama format mismatch');
  assert(openai[0].function.parameters?.required?.length === 2, 'openai format required mismatch');
});

function main(): void {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (error: unknown) {
      failures++;
      const message = error instanceof Error ? error.message : String(error);
      console.log(`  ❌ ${name}`);
      console.log(`     ${message}`);
    }
  }

  console.log(`\nQwen/Ollama fixture tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
