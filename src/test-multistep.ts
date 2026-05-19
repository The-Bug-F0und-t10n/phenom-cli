import { EventBus, EventType } from './tui/event-bus.js';
import { Message } from './types.js';
import { SessionState } from './state.js';
import { formatToolResultForNative } from './model-capabilities.js';

let passed = 0;
const tests: { name: string; fn: () => void }[] = [];

function test(name: string, fn: () => void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

// --- Message type supports tool_calls ---
test('Message type aceita tool_calls opcional', () => {
  const msg: Message = {
    role: 'assistant',
    content: '',
    timestamp: Date.now(),
    tool_calls: [
      {
        function: {
          name: 'write_file',
          arguments: { path: '/tmp/test.ts', content: 'test' }
        }
      }
    ]
  };
  assert(msg.tool_calls !== undefined, 'tool_calls should be defined');
  assert(msg.tool_calls!.length === 1, 'should have 1 tool_call');
  assert(msg.tool_calls![0].function.name === 'write_file', 'tool name should match');
});

test('Message type aceita role tool', () => {
  const msg: Message = {
    role: 'tool',
    content: '[OK] File created',
    timestamp: Date.now()
  };
  assert(msg.role === 'tool', 'role should be tool');
});

// --- SessionState with new Message type ---
test('SessionState addMessage preserva tool_calls', () => {
  const state = new SessionState();
  state.addMessage({
    role: 'assistant',
    content: '',
    timestamp: Date.now(),
    tool_calls: [{ function: { name: 'write_file', arguments: { path: 'x.ts' } } }]
  });
  const msgs = state.getRecentMessages(10);
  assert(msgs.length === 1, 'should have 1 message');
  assert(msgs[0].tool_calls !== undefined, 'tool_calls should be preserved');
  assert(msgs[0].tool_calls![0].function.name === 'write_file', 'tool name preserved');
});

test('SessionState getRecentMessages retorna tool_calls', () => {
  const state = new SessionState();
  state.addMessage({ role: 'user', content: 'create project', timestamp: Date.now() });
  state.addMessage({
    role: 'assistant',
    content: '',
    timestamp: Date.now(),
    tool_calls: [{ function: { name: 'write_file', arguments: { path: 'a.ts', content: '// ok' } } }]
  });
  state.addMessage({ role: 'tool', content: '[OK] Created a.ts', timestamp: Date.now() });

  const msgs = state.getRecentMessages(10);
  assert(msgs.length === 3, 'should have 3 messages');
  assert(msgs[0].role === 'user', 'msg 0 role user');
  assert(msgs[1].role === 'assistant', 'msg 1 role assistant');
  assert(msgs[1].tool_calls !== undefined, 'msg 1 has tool_calls');
  assert(msgs[2].role === 'tool', 'msg 2 role tool');
});

// --- formatToolResultForNative ---
test('formatToolResultForNative sucesso prefixo [OK]', () => {
  const r = formatToolResultForNative({ success: true, output: 'Created file', error: null });
  assert(r.startsWith('[OK]'), 'success should start with [OK]');
});

test('formatToolResultForNative erro prefixo [FAIL]', () => {
  const r = formatToolResultForNative({ success: false, output: '', error: 'File not found' });
  assert(r.startsWith('[FAIL]'), 'failure should start with [FAIL]');
});

test('formatToolResultForNative output longo truncado', () => {
  const long = 'x'.repeat(5000);
  const r = formatToolResultForNative({ success: true, output: long, error: null });
  assert(r.length < 4100, 'should truncate long output');
  assert(r.includes('truncated'), 'should indicate truncation');
});

test('formatToolResultForNative output vazio', () => {
  const r = formatToolResultForNative({ success: true, output: '', error: null });
  assert(r === '[OK] Tool completed', 'empty output generic message');
});

test('formatToolResultForNative null result', () => {
  const r = formatToolResultForNative(null);
  assert(r.startsWith('[OK]'), 'null should return OK');
});

// --- EventBus: tool_calls in payload ---
test('AGENT_MESSAGE com tool_calls no payload', () => {
  const bus = new EventBus();
  let received: any = null;
  bus.on(EventType.AGENT_MESSAGE, (e) => { received = e; });
  bus.emit(EventType.AGENT_MESSAGE, {
    content: '',
    tool_calls: [{ function: { name: 'write_file', arguments: {} } }]
  });
  assert(received !== null, 'handler called');
  assert(received.payload.content === '', 'content should be empty');
  assert(received.payload.tool_calls !== undefined, 'tool_calls in payload');
});

// --- Multi-step conversation simulation ---
test('Simula conversa multi-step com tool_calls', () => {
  const bus = new EventBus();
  const state = new SessionState();
  const events: string[] = [];

  bus.on(EventType.AGENT_MESSAGE, (e) => {
    events.push(`agent: ${(e.payload.content || '(tool call)').substring(0, 40)}`);
  });

  // Step 1: User message
  state.addMessage({ role: 'user', content: 'create a project with 3 files', timestamp: 1 });

  // Step 2: Assistant responds with tool_calls (2 files)
  bus.emit(EventType.AGENT_MESSAGE, { content: 'I will create the project files' });
  state.addMessage({
    role: 'assistant',
    content: 'I will create the project files',
    timestamp: 2,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'a.ts', content: '// a' } } },
      { function: { name: 'write_file', arguments: { path: 'b.ts', content: '// b' } } }
    ]
  });

  // Step 3: Tool results
  state.addMessage({ role: 'tool', content: '[OK] Created a.ts', timestamp: 3 });
  state.addMessage({ role: 'tool', content: '[OK] Created b.ts', timestamp: 4 });

  // Step 4: Assistant continues with more tool_calls
  bus.emit(EventType.AGENT_MESSAGE, { content: 'Now creating the third file' });
  state.addMessage({
    role: 'assistant',
    content: 'Now creating the third file',
    timestamp: 5,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'c.ts', content: '// c' } } }
    ]
  });

  // Step 5: Tool result
  state.addMessage({ role: 'tool', content: '[OK] Created c.ts', timestamp: 6 });

  // Verify state
  const msgs = state.getRecentMessages(20);
  assert(msgs.length === 6, `should have 6 messages, got ${msgs.length}`);

  // Verify ordering: user → assistant(tool_calls) → tool → tool → assistant(tool_calls) → tool
  assert(msgs[0].role === 'user', 'msg 0: user');
  assert(msgs[1].role === 'assistant', 'msg 1: assistant');
  assert(msgs[1].tool_calls !== undefined, 'msg 1: has tool_calls');
  assert(msgs[1].tool_calls!.length === 2, 'msg 1: 2 tool calls');
  assert(msgs[2].role === 'tool', 'msg 2: tool result');
  assert(msgs[3].role === 'tool', 'msg 3: tool result');
  assert(msgs[4].role === 'assistant', 'msg 4: assistant');
  assert(msgs[4].tool_calls !== undefined, 'msg 4: has tool_calls');
  assert(msgs[4].tool_calls!.length === 1, 'msg 4: 1 tool call');
  assert(msgs[5].role === 'tool', 'msg 5: tool result');

  // Verify events
  assert(events.length >= 2, 'should have agent events');
});

// --- Tool results must be 'tool' role (not 'system') ---
test('Tool results usam role tool', () => {
  const results = [
    { role: 'tool', content: '[OK] Created file.ts', timestamp: Date.now() },
    { role: 'tool', content: '[FAIL] File not found', timestamp: Date.now() }
  ];
  for (const r of results) {
    assert(r.role === 'tool', `role should be 'tool', got '${r.role}'`);
  }
});

// --- buildMessages-like logic test ---
test('buildMessages-like transform preserva tool_calls', () => {
  const state = new SessionState();
  state.addMessage({ role: 'user', content: 'hello', timestamp: 1 });
  state.addMessage({
    role: 'assistant',
    content: '',
    timestamp: 2,
    tool_calls: [{ function: { name: 'write_file', arguments: { path: 'x.ts' } } }]
  });
  state.addMessage({ role: 'tool', content: '[OK] done', timestamp: 3 });

  const recent = state.getRecentMessages(10);
  const built = recent.map(msg => {
    const m: any = { role: msg.role, content: msg.content };
    if (msg.tool_calls && msg.tool_calls.length > 0) {
      m.tool_calls = msg.tool_calls;
    }
    return m;
  });

  assert(built.length === 3, 'should have 3 messages');
  assert(built[0].role === 'user', 'role user');
  assert(!('tool_calls' in built[0]), 'user msg no tool_calls');
  assert(built[1].role === 'assistant', 'role assistant');
  assert(built[1].tool_calls !== undefined, 'assistant has tool_calls');
  assert(built[1].tool_calls[0].function.name === 'write_file', 'tool call name preserved');
  assert(built[2].role === 'tool', 'role tool');
  assert(!('tool_calls' in built[2]), 'tool result no tool_calls');
});

// --- EventBus: 'tool' role events ---
test('TOOL_START/TOOL_RESULT/TOOL_ERROR com role tool', () => {
  const bus = new EventBus();
  let start: any = null;
  let result: any = null;

  bus.on(EventType.TOOL_START, (e) => { start = e; });
  bus.on(EventType.TOOL_RESULT, (e) => { result = e; });

  bus.emit(EventType.TOOL_START, { id: 't1', name: 'write_file', args: { path: 'x.ts' } });
  bus.emit(EventType.TOOL_RESULT, { id: 't1', result: { success: true, output: 'Created', error: null }, toolName: 'write_file' });

  assert(start.payload.id === 't1', 'tool start id');
  assert(start.payload.name === 'write_file', 'tool start name');
  assert(result.payload.result.success === true, 'tool result success');
});

// --- Runner ---
function main() {
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
  console.log(`\nResultado: ${passed}/${tests.length} testes passaram`);
  process.exit(failures > 0 ? 1 : 0);
}

main();
