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

test('qwen2.5 base (not coder) must NOT advertise native tools', () => {
  const caps = detectModelCapabilities('qwen2.5:7b');
  assert(!caps.supportsNativeTools, 'plain qwen2.5 should fall back to text-based tools');
});

test('qwen2.5-coder keeps native tools', () => {
  const caps = detectModelCapabilities('qwen2.5-coder:7b');
  assert(caps.supportsNativeTools, 'qwen2.5-coder is tool-tuned and must keep native flag');
});

test('qwen2 base must NOT advertise native tools', () => {
  const caps = detectModelCapabilities('qwen2:7b-instruct');
  assert(!caps.supportsNativeTools, 'qwen2 base is not tool-tuned');
});

test('qwen2.1 keeps native tools (explicit allowlist)', () => {
  const caps = detectModelCapabilities('qwen2.1:32b');
  assert(caps.supportsNativeTools, 'qwen2.1 is in NATIVE_TOOLS_MODELS — must remain native');
});

test('qwen1.5 must NOT advertise native tools', () => {
  const caps = detectModelCapabilities('qwen1.5:14b');
  assert(!caps.supportsNativeTools, 'qwen1.x has no tool support');
});

test('qwen3 / qwen3.5 unaffected by the qwen2 blocklist', () => {
  for (const name of ['qwen3:14b', 'qwen3.5:32b', 'qwen3-coder:7b']) {
    const caps = detectModelCapabilities(name);
    assert(caps.supportsNativeTools, `${name} should keep native tools`);
  }
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
