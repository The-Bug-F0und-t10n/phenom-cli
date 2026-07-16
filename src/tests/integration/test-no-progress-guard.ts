// Regression: the model emits <think> / reasoning text without making any
// tool call. Today the plan-continuation (5×) and verification-continuation
// (2×) budgets STACK and force up to 7 forced iterations of pure thinking
// before phenom gives up. The no-progress guard bails after 2 consecutive
// empty iterations regardless of those budgets.

import { Agent } from '../../agent.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];
function test(name: string, fn: () => Promise<void> | void) { tests.push({ name, fn }); }
function assert(c: boolean, m: string) { if (!c) throw new Error(m); }

function fakeBrainWithPendingPlan(): any {
  return {
    refreshForNewRequest: () => {},
    setUserRequest: () => {},
    getUserRequest: () => 'test',
    saveMessages: () => {},
    save: async () => {},
    addNote: () => 'n',
    addInsight: () => {},
    addFailedOperation: () => {},
    addCreatedFile: () => {},
    addReadFile: () => {},
    addPatchedFile: () => {},
    getNotes: () => [],
    getCreatedFiles: () => [],
    getReadFiles: () => [],
    getPatchedFiles: () => [],
    getInsights: () => [],
    getFailedOperations: () => [],
    getPlanSummary: () => null,
    getPlanSteps: () => [{ id: 1, title: 'Step 1', status: 'pending' }],
    setPlan: () => {},
    markStepDone: () => {},
    incMetric: () => {},
    getRequestMetrics: () => ({ mutationCount: 0, validationCount: 0, buildRun: 0, testsRun: 0 }),
    getData: () => ({ sessionId: 'test-session' }),
    noteBuildRun: () => {},
    noteTestRun: () => {},
    noteSearchRun: () => {},
  };
}

test('loop bails after 2 consecutive thinking-only iterations (no tool calls)', async () => {
  const agent: any = new Agent();
  agent.brain = fakeBrainWithPendingPlan();

  // LLM emits content but never a tool call. With the old budgets, this
  // would force up to 7 iterations; the guard must cap at 3 calls (iter 1 +
  // iter 2 increments counter to 2 → bail before iter 4 ever runs the LLM).
  let streamCalls = 0;
  agent.llm = {
    chatStream: async (_msgs: any, onChunk: any) => {
      streamCalls++;
      onChunk(`Thinking iteration ${streamCalls}.`);
      return '';
    },
    chat: async () => ({ message: { content: 'no' } }),
    generate: async () => '',
    getEffectiveContextLimit: async () => 32768,
    tokenizeCount: async () => null
  };
  agent.executeToolWithEvents = async () => ({ success: true, output: 'ok', error: null });

  await agent.runToolLoop('explain this');
  assert(streamCalls <= 3, `expected ≤3 thinking iterations, got ${streamCalls}`);
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nNo-progress guard tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
