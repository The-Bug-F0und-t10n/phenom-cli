/**
 * Tests for MemoryWriter.distillBySection — the memory-as-compaction
 * mechanism. We mock llmFn so the suite stays offline-clean. The key
 * properties exercised:
 *
 *   1. Per-pass focus: each pass receives a tiny prompt with ONE question.
 *   2. Parallel independence: a malformed response in pass N must not
 *      block the other passes.
 *   3. Section routing: results land in the correct .MEMORY.md section.
 *   4. JSON robustness: parser tolerates prose wrapping a {...} block.
 *   5. Append mode: subsequent calls accumulate rather than overwrite.
 *   6. No-op on empty input.
 */

import { strict as assert } from 'node:assert';
import os from 'node:os';
import path from 'node:path';
import { promises as fs, readFileSync } from 'node:fs';
import {
  MemoryWriter,
  DEFAULT_COMPACTION_PASSES,
  CompactableMessage
} from '../../learning-loop/memory-writer.js';

const tests: Array<{ name: string; fn: () => Promise<void> | void }> = [];
function test(name: string, fn: () => Promise<void> | void) { tests.push({ name, fn }); }
let passed = 0;

async function withTempCwd<T>(work: (cwd: string) => Promise<T>): Promise<T> {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-mem-'));
  try {
    return await work(tmp);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

const sampleMessages: CompactableMessage[] = [
  { role: 'user', content: 'use snake_case in this codebase, our convention' },
  { role: 'assistant', content: 'understood; will rename the variables' },
  { role: 'user', content: 'also try the regex approach first' },
  { role: 'assistant', content: 'tried regex but it failed on nested quotes; switched to parser' },
  { role: 'user', content: 'we will defer the schema migration to next sprint' }
];

// ── 1. Per-pass focus ──────────────────────────────────────────────────

test('each pass receives ONE focused question and the excerpt', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    const promptsSeen: string[] = [];
    const llmFn = async (prompt: string): Promise<string> => {
      promptsSeen.push(prompt);
      return '{"items": []}';
    };
    await writer.distillBySection(sampleMessages, llmFn);
    assert.equal(promptsSeen.length, DEFAULT_COMPACTION_PASSES.length);
    // Each prompt must contain the excerpt + JSON instruction.
    for (const p of promptsSeen) {
      assert.match(p, /snake_case/);
      assert.match(p, /STRICT JSON/);
    }
    // Each prompt must mention only ONE question (the pass's question
    // appears, the others' core verbs should not all appear in any single
    // prompt — sanity check that prompts are not merged).
    const decisionsCount = promptsSeen.filter(p => /decisions made/i.test(p)).length;
    assert.equal(decisionsCount, 1, 'decisions question appears in exactly one pass prompt');
  });
});

// ── 2. Parallel independence ──────────────────────────────────────────

test('one bad-JSON pass does not block other passes from landing', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    const llmFn = async (prompt: string): Promise<string> => {
      if (/constraints, rules/i.test(prompt)) {
        return 'this is not JSON at all sorry';
      }
      if (/decisions made/i.test(prompt)) {
        return '{"items": ["switched parser approach — regex failed"]}';
      }
      return '{"items": []}';
    };
    const results = await writer.distillBySection(sampleMessages, llmFn);
    assert.equal(results.length, DEFAULT_COMPACTION_PASSES.length);
    const decisions = results.find(r => r.pass === 'decisions');
    const constraints = results.find(r => r.pass === 'constraints');
    assert.ok(decisions && decisions.items.length === 1, 'decisions landed');
    assert.ok(constraints && constraints.items.length === 0, 'constraints gracefully empty');
  });
});

// ── 3. Section routing ────────────────────────────────────────────────

test('items land in the section declared by the pass', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    const llmFn = async (prompt: string): Promise<string> => {
      if (/constraints, rules/i.test(prompt)) {
        return '{"items": ["snake_case — codebase convention"]}';
      }
      if (/tried and did NOT work/i.test(prompt)) {
        return '{"items": ["regex on nested quotes — failed, switched to parser"]}';
      }
      return '{"items": []}';
    };
    await writer.distillBySection(sampleMessages, llmFn);
    const memFile = readFileSync(path.join(cwd, '.MEMORY.md'), 'utf-8');
    // custom_rules section must hold the snake_case constraint.
    assert.match(memFile, /## Custom rules\n[\s\S]*snake_case/);
    // insights section must hold the failed regex attempt.
    assert.match(memFile, /## Insights\n[\s\S]*regex on nested quotes/);
  });
});

// ── 4. JSON robustness ────────────────────────────────────────────────

test('parser tolerates prose wrapping a JSON block', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    const llmFn = async (prompt: string): Promise<string> => {
      if (/decisions made/i.test(prompt)) {
        return 'Sure! Here is the JSON you asked for:\n\n{"items": ["chose parser over regex"]}\n\nLet me know if you need more.';
      }
      return '{"items": []}';
    };
    const results = await writer.distillBySection(sampleMessages, llmFn);
    const decisions = results.find(r => r.pass === 'decisions');
    assert.ok(decisions);
    assert.equal(decisions!.items.length, 1);
    assert.match(decisions!.items[0], /chose parser/);
  });
});

// ── 5. Append mode (subsequent compactions accumulate) ────────────────

test('subsequent distillations append rather than overwrite', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    let callIdx = 0;
    const llmFn = async (prompt: string): Promise<string> => {
      if (/constraints, rules/i.test(prompt)) {
        callIdx++;
        return callIdx === 1
          ? '{"items": ["rule one — first call"]}'
          : '{"items": ["rule two — second call"]}';
      }
      return '{"items": []}';
    };
    await writer.distillBySection(sampleMessages, llmFn);
    await writer.distillBySection(sampleMessages, llmFn);
    const memFile = readFileSync(path.join(cwd, '.MEMORY.md'), 'utf-8');
    assert.match(memFile, /rule one/);
    assert.match(memFile, /rule two/);
  });
});

test('parse preserves legacy "Project context" content and maps to Project description', async () => {
  await withTempCwd(async (cwd) => {
    const legacy = [
      '# Phenom Memory',
      '> Updated: 2026-05-23 | Tasks: 1',
      '',
      '## Project context',
      '- legacy context sentinel',
      '',
      '## Custom rules',
      '- keep this rule',
      '',
      '---',
      '<!-- phenom:preserve -->'
    ].join('\n');
    await fs.writeFile(path.join(cwd, '.MEMORY.md'), legacy, 'utf-8');

    const writer = new MemoryWriter(cwd);
    await writer.updateSection('insights', '- new insight', 'append');
    const mem = readFileSync(path.join(cwd, '.MEMORY.md'), 'utf-8');

    assert.match(mem, /## Project description/);
    assert.match(mem, /legacy context sentinel/);
    assert.match(mem, /## Insights/);
    assert.match(mem, /new insight/);
  });
});

// ── 6. No-op on empty input ───────────────────────────────────────────

test('empty message list returns [] without calling llmFn', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    let llmCalls = 0;
    const llmFn = async (): Promise<string> => { llmCalls++; return '{"items": []}'; };
    const results = await writer.distillBySection([], llmFn);
    assert.equal(results.length, 0);
    assert.equal(llmCalls, 0);
  });
});

// ── 7. Line cap enforcement ───────────────────────────────────────────

test('items longer than the per-line cap are truncated', async () => {
  await withTempCwd(async (cwd) => {
    const writer = new MemoryWriter(cwd);
    const longLine = 'x'.repeat(500);
    const llmFn = async (prompt: string): Promise<string> => {
      if (/decisions made/i.test(prompt)) {
        return `{"items": ["${longLine}"]}`;
      }
      return '{"items": []}';
    };
    const results = await writer.distillBySection(sampleMessages, llmFn);
    const decisions = results.find(r => r.pass === 'decisions');
    assert.ok(decisions);
    assert.equal(decisions!.items.length, 1);
    assert.ok(decisions!.items[0].length <= 200, `item length ${decisions!.items[0].length} exceeds cap`);
  });
});

async function main() {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (e: any) {
      failures++;
      console.log(`  ❌ ${name}\n     ${e?.message || e}`);
    }
  }
  console.log(`Memory distillation tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
}

main();
