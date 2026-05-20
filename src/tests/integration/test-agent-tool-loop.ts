import { Agent } from '../../agent.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

test('runToolLoop executes JSON tool protocol fallback when native tool call is missing', async () => {
  const agent: any = new Agent();

  let streamCalls = 0;
  const executed: Array<{ tool: string; args: any }> = [];

  agent.llm = {
    chatStream: async (_messages: any, onChunk: (c: string) => void) => {
      streamCalls++;
      if (streamCalls === 1) {
        onChunk('{"type":"tool","toolName":"write_file","args":{"path":"fallback.txt","content":"ok"}}');
      } else {
        onChunk('{"type":"final","content":"finalizado"}');
      }
      return '';
    },
    chat: async () => ({ message: { content: 'no' } }),
    generate: async () => ''
  };

  agent.executeToolWithEvents = async (toolName: string, args: any) => {
    executed.push({ tool: toolName, args });
    return { success: true, output: 'ok', error: null };
  };

  const result = await agent.runToolLoop('crie um arquivo');

  assert(executed.length === 1, `expected 1 tool execution, got ${executed.length}`);
  assert(executed[0].tool === 'write_file', `expected write_file, got ${executed[0].tool}`);
  assert(executed[0].args.path === 'fallback.txt', `expected fallback.txt, got ${executed[0].args.path}`);
  assert(result.includes('finalizado'), `expected finalizado, got ${result}`);
});

test('runToolLoop preserves tool_call_id in tool role messages', async () => {
  const agent: any = new Agent();
  const state = agent.state;

  let streamCalls = 0;
  agent.llm = {
    chatStream: async (_messages: any, onChunk: (c: string) => void, onToolCall: any) => {
      streamCalls++;
      if (streamCalls === 1) {
        onToolCall('write_file', { path: 'id-test.txt', content: 'x' }, 'call_abc123');
      } else {
        onChunk('done');
      }
      return '';
    },
    chat: async () => ({ message: { content: 'no' } }),
    generate: async () => ''
  };

  agent.executeToolWithEvents = async () => ({ success: true, output: 'ok', error: null });

  await agent.runToolLoop('crie arquivo com id');

  const memory = state.getState().memory || [];
  const toolMsgs = memory.filter((m: any) => m.role === 'tool');
  assert(toolMsgs.length >= 1, 'expected at least one tool message');
  assert(toolMsgs.some((m: any) => m.tool_call_id === 'call_abc123'), 'expected tool_call_id call_abc123 in tool message');
});

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

  console.log(`\nAgent tool-loop tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
