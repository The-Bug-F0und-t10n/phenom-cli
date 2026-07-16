// Verifies the per-call dedup guard fires when the model hammers the same
// (tool, args) across interleaved iterations — the calculadora-session
// pattern where the per-iteration plan signature differed but the same
// wrong apply_patch call repeated.

import { Agent } from '../../agent.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];
function test(name: string, fn: () => Promise<void> | void) { tests.push({ name, fn }); }
function assert(c: boolean, m: string) { if (!c) throw new Error(m); }

test('dedup guard trips when same (tool,args) repeats 3x interleaved', async () => {
  const agent: any = new Agent();

  // Per-iteration, the model emits TWO tool calls: a probe (varies each
  // iter) and the bad apply_patch (constant). After 3 iters the dedup
  // window holds 6 calls including 3× apply_patch — guard must fire.
  // Tools succeed so the all-failed-3x guard cannot win the race.
  const probes = ['read_file', 'list_dir', 'grep_file', 'path_exists', 'project_map'];
  const badCall = { tool: 'apply_patch', args: { path: 'wrong.tsx', startLine: 1, endLine: 1, replace: 'a' } };
  let iter = 0;

  agent.llm = {
    chatStream: async (_msgs: any, onChunk: any, onToolCall: any) => {
      if (iter >= probes.length) { onChunk('done'); return ''; }
      onToolCall(probes[iter], { idx: iter }, `probe_${iter}`);
      onToolCall(badCall.tool, badCall.args, `bad_${iter}`);
      iter++;
      return '';
    },
    chat: async () => ({ message: { content: 'no' } }),
    generate: async () => '',
    getEffectiveContextLimit: async () => 32768,
    tokenizeCount: async () => null
  };

  agent.executeToolWithEvents = async () => ({ success: true, output: 'ok', error: null });

  const result = await agent.runToolLoop('do the thing');
  assert(/called \d+×.*last/.test(result), `expected dedup directive in result, got: ${result}`);
  assert(result.includes('apply_patch'), `directive should quote the repeated tool, got: ${result}`);
});

test('dedup guard does NOT trip on diverse tool calls', async () => {
  const agent: any = new Agent();

  const tools = ['read_file', 'grep_file', 'list_dir', 'path_exists', 'project_map', 'find_function'];
  let cursor = 0;

  agent.llm = {
    chatStream: async (_msgs: any, onChunk: any, onToolCall: any) => {
      if (cursor < tools.length) {
        onToolCall(tools[cursor], { path: `file-${cursor}.ts` }, `id_${cursor}`);
        cursor++;
      } else {
        // After 6 unique calls, finish — dedup guard must not have fired.
        onChunk('all done');
      }
      return '';
    },
    chat: async () => ({ message: { content: 'no' } }),
    generate: async () => '',
    getEffectiveContextLimit: async () => 32768,
    tokenizeCount: async () => null
  };

  agent.executeToolWithEvents = async () => ({ success: true, output: 'ok', error: null });

  const result = await agent.runToolLoop('explore');
  assert(!/called \d+×/.test(result), `dedup guard tripped on diverse calls: ${result}`);
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nDedup guard tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
