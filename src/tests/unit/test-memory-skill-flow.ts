import { strict as assert } from 'node:assert';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Agent } from '../../agent.js';
import { eventBus, EventType } from '../../tui/event-bus.js';
import { SkillStore } from '../../learning-loop/skill-store.js';
import { registerMemoryTools } from '../../tools/registrars/memory-tools.js';

const tests: Array<{ name: string; fn: () => Promise<void> | void }> = [];
function test(name: string, fn: () => Promise<void> | void) { tests.push({ name, fn }); }

let passed = 0;

async function withTempCwd<T>(work: (cwd: string) => Promise<T>): Promise<T> {
  const prev = process.cwd();
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-flow-'));
  try {
    process.chdir(tmp);
    return await work(tmp);
  } finally {
    process.chdir(prev);
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

test('buildSystemPrompt expõe ferramentas de MEMORY/SKILL sem auto-injetar conteúdo', async () => {
  await withTempCwd(async (cwd) => {
    await fs.writeFile(
      path.join(cwd, '.MEMORY.md'),
      [
        '# Phenom Memory',
        '> Updated: 2026-05-23 | Tasks: 1',
        '',
        '## Project description',
        '- test description sentinel',
        '',
        '## Custom rules',
        '- memory sentinel rule',
        '',
        '## Specific behaviors',
        '- behavior sentinel',
        '',
        '## Active tasks & notes',
        '- task sentinel',
        '',
        '## Insights',
        '- insight sentinel'
      ].join('\n'),
      'utf-8'
    );

    await fs.writeFile(
      path.join(cwd, '.SKILL.md'),
      [
        '# Skills',
        '> Updated: 2026-05-23 | Tasks: 1 | Skills: 1',
        '',
        '## skill sentinel',
        '> Tools: grep_file → apply_patch'
      ].join('\n'),
      'utf-8'
    );

    const agent: any = new Agent();
    const prompt = String(agent.buildSystemPrompt('continue this task'));

    assert.match(prompt, /read_memory/);
    assert.match(prompt, /read_skills/);
    assert.match(prompt, /update_memory/);
    assert.match(prompt, /record_skill/);
    assert.doesNotMatch(prompt, /memory sentinel rule/);
    assert.doesNotMatch(prompt, /skill sentinel/);
    assert.doesNotMatch(prompt, /task sentinel/);
  });
});

test('distillDroppedMessages emite status "Resuming ..." e resumo de memória', async () => {
  await withTempCwd(async () => {
    eventBus.clear();
    const seen: string[] = [];
    eventBus.on(EventType.PROGRESS_UPDATE, (event) => {
      seen.push(String(event?.payload?.message || ''));
    });

    const agent: any = new Agent();
    agent.memWriter = {
      distillBySection: async () => ([
        { pass: 'decisions', section: 'insights', items: ['one', 'two'], wroteChars: 12 }
      ])
    };

    await agent.distillDroppedMessages([{ role: 'user', content: 'keep this decision' }]);

    assert.ok(
      seen.some(m => m.startsWith('Resuming ... compacting context into memory (1 msgs)')),
      `expected compacting status with Resuming..., got: ${JSON.stringify(seen)}`
    );
    assert.ok(
      seen.some(m => m.includes('Memory updated: decisions=2')),
      `expected memory summary event, got: ${JSON.stringify(seen)}`
    );
    eventBus.clear();
  });
});

test('SkillStore persiste .SKILL.md e readSkillsMdCompact retorna conteúdo', async () => {
  await withTempCwd(async (cwd) => {
    const store = new SkillStore('.phenom-skills-test');
    await store.init();
    store.incrementTaskCount();
    store.addOrRefine({
      name: 'edit-validate-loop',
      domain: 'general',
      description: 'Patch small blocks then run validation.',
      toolSequence: ['set_plan', 'apply_patch', 'validate_syntax', 'run_tests'],
      triggerKeywords: ['patch', 'test', 'validate']
    });
    await store.save();

    const skillsMdPath = path.join(cwd, '.SKILL.md');
    const raw = await fs.readFile(skillsMdPath, 'utf-8');
    assert.match(raw, /edit-validate-loop/);

    const compact = SkillStore.readSkillsMdCompact(cwd, 300);
    assert.match(compact, /edit-validate-loop/);
  });
});

test('record_skill persiste skill quando argumentos sao validos', async () => {
  await withTempCwd(async (cwd) => {
    const tools: any[] = [];
    registerMemoryTools({ register: (tool) => tools.push(tool) });
    const recordSkill = tools.find((t) => t.name === 'record_skill');
    assert.ok(recordSkill, 'record_skill tool not registered');

    const result = await recordSkill.execute({
      name: 'debug-helper-flow',
      description: 'Use when adding a debug helper with validation.',
      toolSequence: ['read_file', 'apply_patch', 'validate_syntax'],
      triggerKeywords: ['debug', 'helper', 'validate'],
      domain: 'typescript'
    });

    assert.equal(result.success, true, `expected success, got: ${result.error || result.output}`);
    const raw = await fs.readFile(path.join(cwd, '.SKILL.md'), 'utf-8');
    assert.match(raw, /debug-helper-flow/);
  });
});

test('record_skill rejeita descricao ausente', async () => {
  await withTempCwd(async () => {
    const tools: any[] = [];
    registerMemoryTools({ register: (tool) => tools.push(tool) });
    const recordSkill = tools.find((t) => t.name === 'record_skill');
    const result = await recordSkill.execute({
      name: 'missing-description',
      toolSequence: ['read_file']
    });
    assert.equal(result.success, false);
    assert.match(String(result.error || ''), /description is required/);
  });
});

test('record_skill rejeita toolSequence vazia', async () => {
  await withTempCwd(async () => {
    const tools: any[] = [];
    registerMemoryTools({ register: (tool) => tools.push(tool) });
    const recordSkill = tools.find((t) => t.name === 'record_skill');
    const result = await recordSkill.execute({
      name: 'empty-sequence',
      description: 'Invalid skill',
      toolSequence: []
    });
    assert.equal(result.success, false);
    assert.match(String(result.error || ''), /toolSequence must contain at least one tool name/);
  });
});

test('update_memory accepts project_description alias and writes Project description', async () => {
  await withTempCwd(async (cwd) => {
    const tools: any[] = [];
    registerMemoryTools({
      register: (tool) => tools.push(tool)
    });
    const updateMemory = tools.find((t) => t.name === 'update_memory');
    assert.ok(updateMemory, 'update_memory tool not registered');

    const result = await updateMemory.execute({
      section: 'project_description',
      content: 'Alias write sentinel'
    });
    assert.equal(result.success, true, `expected success, got: ${result.error || result.output}`);

    const mem = await fs.readFile(path.join(cwd, '.MEMORY.md'), 'utf-8');
    assert.match(mem, /## Project description/);
    assert.match(mem, /Alias write sentinel/);
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
  console.log(`Memory/Skill flow tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
}

main();
