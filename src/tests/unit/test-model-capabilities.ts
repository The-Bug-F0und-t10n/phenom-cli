import { detectModelCapabilities } from '../../model-capabilities.js';

let passed = 0;
const tests: { name: string; fn: () => void }[] = [];

function test(name: string, fn: () => void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

test('qwen3.5 coder advertises native tools', () => {
  const caps = detectModelCapabilities('qwen3.5-coder:14b');
  assert(caps.supportsNativeTools, 'supportsNativeTools should be true');
  assert(caps.modelFamily === 'qwen', `family mismatch: ${caps.modelFamily}`);
});

test('qwen3.5 vision advertises vision support', () => {
  const caps = detectModelCapabilities('qwen3.5-vision:latest');
  assert(caps.supportsVision, 'supportsVision should be true');
});

test('qwen3.5 thinking advertises reasoning support', () => {
  const caps = detectModelCapabilities('qwen3.5-thinking:32b');
  assert(caps.supportsReasoning, 'supportsReasoning should be true');
});

test('unknown model stays conservative for vision/reasoning', () => {
  const caps = detectModelCapabilities('custom-local-model');
  assert(!caps.supportsVision, 'supportsVision should be false');
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

  console.log(`\nModel capabilities tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
