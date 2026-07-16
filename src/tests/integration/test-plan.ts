import { Agent } from '../../agent.js';
import { SessionBrain, PlanStep } from '../../session-brain.js';
import { mkdtempSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

function makeAgent(): Agent {
  const agent = new Agent();
  const tmpDir = mkdtempSync(join(tmpdir(), 'phenom-test-plan-'));
  (agent as any).brain = new SessionBrain(tmpDir, 'test-' + Date.now());
  return agent;
}

// ── SessionBrain plan methods ────────────────────────────────────────

test('SessionBrain.setPlanSteps + getPlanSteps + getPlanSummary', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  const steps = [
    { title: 'Read config', status: 'pending', order: 1 },
    { title: 'Write code', status: 'pending', order: 2 },
    { title: 'Run tests', status: 'pending', order: 3 }
  ];
  brain.setPlanSteps(steps);

  const stored = brain.getPlanSteps();
  assert(stored.length === 3, 'deve ter 3 steps');
  assert(stored[0].title === 'Read config', 'step 0 title ok');
  assert(stored[0].status === 'pending', 'step 0 pending');
  assert(typeof stored[0].id === 'string', 'step 0 tem id');
  assert(stored[0].order === 1, 'step 0 order = 1');
  assert(stored[2].order === 3, 'step 2 order = 3');

  const summary = brain.getPlanSummary();
  assert(summary.includes('[ ] Read config'), 'summary shows pending Read config');
  assert(summary.includes('[ ] Write code'), 'summary shows pending Write code');
  assert(summary.includes('[ ] Run tests'), 'summary shows pending Run tests');
});

test('SessionBrain.completeStep / failStep / setCurrentStep', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  brain.setPlanSteps([
    { title: 'Step A', status: 'pending', order: 1 },
    { title: 'Step B', status: 'pending', order: 2 },
    { title: 'Step C', status: 'pending', order: 3 }
  ]);

  const steps = brain.getPlanSteps();
  const idA = steps[0].id;
  const idB = steps[1].id;

  brain.completeStep(idA);
  assert(brain.getPlanSteps()[0].status === 'completed', 'Step A completed');
  let summary = brain.getPlanSummary();
  assert(summary.includes('[✓] Step A'), 'summary shows Step A done');
  assert(summary.includes('[ ] Step B'), 'summary shows Step B pending');

  brain.setCurrentStep(idB);
  assert(brain.getPlanSteps()[1].status === 'in_progress', 'Step B in_progress');
  assert(brain.getPlanSteps()[0].status === 'completed', 'Step A still completed');
  summary = brain.getPlanSummary();
  assert(summary.includes('[→] Step B'), 'summary shows Step B in_progress');

  brain.failStep(idB);
  assert(brain.getPlanSteps()[1].status === 'failed', 'Step B failed');
  summary = brain.getPlanSummary();
  assert(summary.includes('[✗] Step B'), 'summary shows Step B failed');
});

// ── extractPlanFromText ─────────────────────────────────────────────

test('extractPlanFromText: standard ## PLAN block with numbered list', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  const text = `I'll analyze the structure first.

## PLAN
1. Read the config file
2. Create the main module
3. Write unit tests
4. Verify compilation

Let me start with step 1.`;

  const found = (agent as any).extractPlanFromText(text);
  assert(found === true, 'plan found');

  const steps = brain.getPlanSteps();
  assert(steps.length === 4, '4 steps extracted');
  assert(steps[0].title === 'Read the config file', `step 0 title: ${steps[0].title}`);
  assert(steps[1].title === 'Create the main module', `step 1 title: ${steps[1].title}`);
  assert(steps[2].title === 'Write unit tests', `step 2 title: ${steps[2].title}`);
  assert(steps[3].title === 'Verify compilation', `step 3 title: ${steps[3].title}`);
  assert(steps[0].order === 1, 'order preserved');
  assert(steps[3].order === 4, 'order preserved');
});

test('extractPlanFromText: ## PLAN with bullet list', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  const text = `My plan:

## PLAN
- Read the config file
- Create the main module  
- Write unit tests`;

  (agent as any).extractPlanFromText(text);
  const steps = brain.getPlanSteps();
  assert(steps.length === 3, '3 bullet steps extracted');
  assert(steps[0].title === 'Read the config file', `bullet step 0: ${steps[0].title}`);
  assert(steps[1].title === 'Create the main module', `bullet step 1: ${steps[1].title}`);
});

test('extractPlanFromText: inline Step N: markers (fallback)', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  const text = `Let me work through this systematically.
Step 1: Read the existing files to understand the structure.
Step 2: Write the implementation for the main feature.
Step 3: Verify with tests.`;

  (agent as any).extractPlanFromText(text);
  const steps = brain.getPlanSteps();
  assert(steps.length === 3, '3 steps from inline markers');
  assert(steps[0].title === 'Read the existing files to understand the structure.', `step 0: ${steps[0].title}`);
  assert(steps[1].title === 'Write the implementation for the main feature.', `step 1: ${steps[1].title}`);
  assert(steps[2].title === 'Verify with tests.', `step 2: ${steps[2].title}`);
});

test('extractPlanFromText: PT-BR inline Etapa markers', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  const text = `Vou resolver isso em etapas.
Etapa 1: Ler os arquivos de configuracao
Etapa 2: Implementar a correcao
Etapa 3: Rodar os testes`;

  (agent as any).extractPlanFromText(text);
  const steps = brain.getPlanSteps();
  assert(steps.length === 3, '3 PT-BR steps');
  assert(steps[0].title.includes('Ler os arquivos'), `step 0 PT: ${steps[0].title}`);
});

test('extractPlanFromText: no plan in text returns false', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;
  brain.setPlanSteps([]);

  const text = `I'm just responding to the user without any plan.`;
  const found = (agent as any).extractPlanFromText(text);
  assert(found === false, 'no plan found');

  const steps = brain.getPlanSteps();
  assert(steps.length === 0, 'no steps added');
});

test('extractPlanFromText: does NOT overwrite existing plan with fewer steps', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  // First call with 4 steps
  (agent as any).extractPlanFromText(`## PLAN\n1. Step A\n2. Step B\n3. Step C\n4. Step D`);
  assert(brain.getPlanSteps().length === 4, 'first plan has 4 steps');

  // Second call with only 2 steps - should NOT overwrite
  (agent as any).extractPlanFromText(`## PLAN\n1. Step X\n2. Step Y`);
  const steps = brain.getPlanSteps();
  assert(steps.length === 4, 'still has 4 steps (not overwritten)');
  assert(steps[0].title === 'Step A', 'original steps preserved');
});

test('extractPlanFromText: updates plan when new one has MORE steps', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  (agent as any).extractPlanFromText(`## PLAN\n1. Step A\n2. Step B`);
  assert(brain.getPlanSteps().length === 2, 'first plan has 2 steps');

  (agent as any).extractPlanFromText(`## PLAN\n1. Step 1\n2. Step 2\n3. Step 3`);
  assert(brain.getPlanSteps().length === 3, 'updated to 3 steps');
  assert(brain.getPlanSteps()[0].title === 'Step 1', 'titles updated');
});

// ── extractPlanProgressFromText is now a no-op ─────────────────────
//
// The prior regex-based progress tracker matched loose patterns like
// "Step N done" anywhere in model output, which false-positives on
// prose discussing future work ("I'll only do step 2 once step 1 is
// done" auto-completed step 1). Progress is now driven EXCLUSIVELY by
// the explicit `complete_step` tool. These tests assert the no-op
// contract: feeding any prose into extractPlanProgressFromText must
// not mutate step status. Tools own progress; prose does not.

test('extractPlanProgressFromText: no-op — prose does not auto-complete steps', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  brain.setPlanSteps([
    { title: 'Read files', status: 'in_progress', order: 1 },
    { title: 'Write code', status: 'pending', order: 2 },
  ]);

  (agent as any).extractPlanProgressFromText('Step 1 done, moving to step 2');
  assert(brain.getPlanSteps()[0].status === 'in_progress', 'step 1 still in_progress (no auto-complete from prose)');
  assert(brain.getPlanSteps()[1].status === 'pending', 'step 2 still pending');

  (agent as any).extractPlanProgressFromText('Step 2 done as well');
  assert(brain.getPlanSteps()[1].status === 'pending', 'step 2 still pending (prose ignored)');
});

test('extractPlanProgressFromText: no-op — prose does not promote to in_progress', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  brain.setPlanSteps([
    { title: 'Explore', status: 'completed', order: 1 },
    { title: 'Implement', status: 'pending', order: 2 },
    { title: 'Test', status: 'pending', order: 3 },
  ]);

  (agent as any).extractPlanProgressFromText('Now working on step 2: implementing the feature');
  assert(brain.getPlanSteps()[1].status === 'pending', 'step 2 stays pending (prose ignored)');
  assert(brain.getPlanSteps()[0].status === 'completed', 'step 1 stays completed (untouched)');
});

test('extractPlanProgressFromText: no-op — PT-BR prose patterns ignored', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  brain.setPlanSteps([
    { title: 'Ler arquivos', status: 'in_progress', order: 1 },
    { title: 'Escrever codigo', status: 'pending', order: 2 },
  ]);

  (agent as any).extractPlanProgressFromText('Passo 1 concluido, seguindo para o passo 2');
  assert(brain.getPlanSteps()[0].status === 'in_progress', 'step 1 still in_progress (PT-BR prose ignored)');

  (agent as any).extractPlanProgressFromText('trabalhando no passo 2');
  assert(brain.getPlanSteps()[1].status === 'pending', 'step 2 still pending (PT-BR prose ignored)');
});

test('extractPlanProgressFromText: no-op — Etapa prose ignored', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  brain.setPlanSteps([
    { title: 'Config', status: 'in_progress', order: 1 },
    { title: 'Build', status: 'pending', order: 2 },
  ]);

  (agent as any).extractPlanProgressFromText('Etapa 1 concluida');
  assert(brain.getPlanSteps()[0].status === 'in_progress', 'etapa 1 stays in_progress (prose ignored)');
});

// ── Integration: plan flows through buildMessages ────────────────────

function lastUserText(msgs: any[]): string {
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role === 'user') {
      const c = msgs[i].content;
      return typeof c === 'string' ? c : (Array.isArray(c) ? c.map((p: any) => p.text || '').join('') : '');
    }
  }
  return '';
}

test('buildMessages keeps pending plan out of prompt prefix and user text', async () => {
  // Session continuity is pulled on demand through get_session_context.
  // buildMessages keeps both system prompt and current user text stable so
  // prompt-cache reuse is not invalidated by pending plan state.
  const agent = makeAgent();
  const brain = (agent as any).brain;
  const state = (agent as any).state;

  brain.setPlanSteps([
    { title: 'Analyze code', status: 'completed', order: 1 },
    { title: 'Write patch', status: 'in_progress', order: 2 },
    { title: 'Verify', status: 'pending', order: 3 },
  ]);

  state.addMessage({ role: 'user', content: 'fix the bug', timestamp: 1 });
  state.addMessage({ role: 'assistant', content: 'Working on it', timestamp: 2 });

  const msgs: any[] = await (agent as any).buildMessages('fix the bug');
  const system = msgs[0];
  const userText = lastUserText(msgs);

  assert(system.role === 'system', 'msg 0 is system prompt');
  assert(!system.content.includes('## Active plan'), 'plan is NOT in the system prompt (stable prefix)');
  assert(!system.content.includes('## PLAN'), 'plan summary is NOT in the system prompt');
  assert(!userText.includes('## Active plan'), 'plan is NOT injected into the current user message');
  assert(!userText.includes('## PLAN'), 'plan summary is NOT injected into the current user message');
  assert(userText.includes('fix the bug'), 'still carries the actual user query');
  assert(!userText.includes('Analyze code'), 'does not include completed step details');
});

test('buildMessages does NOT inject pending plan for greeting-only queries', async () => {
  // Prevent greeting autopilot: with a short social message the model should
  // not receive pending plan context (neither in system nor user message).
  const agent = makeAgent();
  const brain = (agent as any).brain;
  const state = (agent as any).state;

  brain.setPlanSteps([
    { title: 'Analyze code', status: 'completed', order: 1 },
    { title: 'Write patch', status: 'in_progress', order: 2 },
    { title: 'Verify', status: 'pending', order: 3 },
  ]);

  state.addMessage({ role: 'user', content: 'oi', timestamp: 1 });

  const msgs: any[] = await (agent as any).buildMessages('oi');
  const system = msgs[0];
  assert(!system.content.includes('## Active plan'), 'no plan block in system for greeting');
  assert(!lastUserText(msgs).includes('## Active plan'), 'no plan block in user message for greeting');
});

test('plan context is empty when no plan exists', async () => {
  const agent = makeAgent();
  const state = (agent as any).state;

  state.addMessage({ role: 'user', content: 'hello', timestamp: 1 });

  const msgs: any[] = await (agent as any).buildMessages('hello');
  const system = msgs[0];
  // Should NOT contain "## Plan" section with steps (only "### Plan tracking" directive)
  assert(!system.content.includes('## Plan\n'), 'no plan section when no plan exists');
});

// ── getPlanSummary edge cases ────────────────────────────────────────

test('getPlanSummary: empty plan returns empty string', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;
  assert(brain.getPlanSummary() === '', 'empty plan = empty summary');
});

test('getPlanSummary: sorts by order field', () => {
  const agent = makeAgent();
  const brain = (agent as any).brain;

  brain.setPlanSteps([
    { title: 'Z last', status: 'pending', order: 3 },
    { title: 'A first', status: 'pending', order: 1 },
    { title: 'M middle', status: 'pending', order: 2 },
  ]);

  const summary = brain.getPlanSummary();
  const lines = summary.split('\n');
  assert(lines[0].includes('A first'), 'first line = order 1');
  assert(lines[1].includes('M middle'), 'second line = order 2');
  assert(lines[2].includes('Z last'), 'third line = order 3');
});

// ── Runner ───────────────────────────────────────────────────────────

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
