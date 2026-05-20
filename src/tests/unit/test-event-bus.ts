import { EventBus, EventType } from '../../tui/event-bus.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(`Assertion failed: ${msg}`);
}

// --- Tests ---

test('AGENT_MESSAGE - handler recebe event com payload.content', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.AGENT_MESSAGE, (event) => {
    received = event;
  });

  bus.emit(EventType.AGENT_MESSAGE, { content: 'hello world' });

  assert(received !== null, 'handler should have been called');
  assert(received.type === EventType.AGENT_MESSAGE, 'event should have type');
  assert(received.payload.content === 'hello world', 'event.payload.content should match');
  assert(typeof received.timestamp === 'number', 'event should have timestamp');
});

test('TOOL_START - handler recebe event com payload.id/name/args', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.TOOL_START, (event) => {
    received = event;
  });

  bus.emit(EventType.TOOL_START, { id: '1', name: 'test', args: {} });

  assert(received.payload.id === '1', 'event.payload.id should match');
  assert(received.payload.name === 'test', 'event.payload.name should match');
});

test('MESSAGE_CHUNK - handler recebe event com payload.chunk', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.MESSAGE_CHUNK, (event) => {
    received = event;
  });

  bus.emit(EventType.MESSAGE_CHUNK, { chunk: 'streaming text' });

  assert(received.payload.chunk === 'streaming text', 'event.payload.chunk should match');
});

test('THINK_START - handler recebe event com payload.message', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.THINK_START, (event) => {
    received = event;
  });

  bus.emit(EventType.THINK_START, { message: 'thinking...', inputTokens: 100 });

  assert(received.payload.message === 'thinking...', 'event.payload.message should match');
});

test('PROGRESS_UPDATE - handler recebe event com payload.message', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.PROGRESS_UPDATE, (event) => {
    received = event;
  });

  bus.emit(EventType.PROGRESS_UPDATE, { message: 'Working...' });

  assert(received.payload.message === 'Working...', 'event.payload.message should match');
});

test('TOKEN_UPDATE - handler recebe event com payload.total/output/input', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.TOKEN_UPDATE, (event) => {
    received = event;
  });

  bus.emit(EventType.TOKEN_UPDATE, { total: 1000, output: 500, input: 500 });

  assert(received.payload.total === 1000, 'event.payload.total should match');
  assert(received.payload.output === 500, 'event.payload.output should match');
});

test('INFERENCE_CANCEL - handler recebe event com payload.reason', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.INFERENCE_CANCEL, (event) => {
    received = event;
  });

  bus.emit(EventType.INFERENCE_CANCEL, { reason: 'User cancelled' });

  assert(received.payload.reason === 'User cancelled', 'event.payload.reason should match');
});

test('THINK_END - handler recebe event mesmo com payload vazio', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.THINK_END, (event) => {
    received = event;
  });

  bus.emit(EventType.THINK_END, {});

  assert(received !== null, 'handler should be called');
  assert(received.type === EventType.THINK_END, 'event.type should be THINK_END');
  assert(typeof received.timestamp === 'number', 'event.timestamp should be a number');
});

test('REASONING_CHUNK - handler recebe event com chunk de reasoning', () => {
  const bus = new EventBus();
  let received: any = null;

  bus.on(EventType.REASONING_CHUNK, (event) => {
    received = event;
  });

  const chunkText = 'analisando o codigo fonte...';
  bus.emit(EventType.REASONING_CHUNK, { chunk: chunkText });

  assert(received !== null, 'handler should be called');
  assert(received.type === EventType.REASONING_CHUNK, 'event.type should be REASONING_CHUNK');
  assert(received.payload.chunk === chunkText, 'event.payload.chunk should match');
  assert(typeof received.timestamp === 'number', 'event.timestamp should be a number');
});

test('REASONING_CHUNK - chunks acumulam corretamente em multiplos eventos', () => {
  const bus = new EventBus();
  const received: string[] = [];

  bus.on(EventType.REASONING_CHUNK, (event) => {
    received.push(event.payload.chunk);
  });

  bus.emit(EventType.REASONING_CHUNK, { chunk: 'passo 1: ler ' });
  bus.emit(EventType.REASONING_CHUNK, { chunk: 'passo 2: editar ' });
  bus.emit(EventType.REASONING_CHUNK, { chunk: 'passo 3: testar' });

  assert(received.length === 3, '3 chunks recebidos');
  assert(received[0] === 'passo 1: ler ', 'primeiro chunk correto');
  assert(received[1] === 'passo 2: editar ', 'segundo chunk correto');
  assert(received[2] === 'passo 3: testar', 'terceiro chunk correto');
});

test('eventos diferentes nao interferem entre si', () => {
  const bus = new EventBus();
  let agentMsg: any = null;
  let toolStart: any = null;

  bus.on(EventType.AGENT_MESSAGE, (e) => { agentMsg = e; });
  bus.on(EventType.TOOL_START, (e) => { toolStart = e; });

  bus.emit(EventType.AGENT_MESSAGE, { content: 'msg' });
  bus.emit(EventType.TOOL_START, { id: '1', name: 'x', args: {} });

  assert(agentMsg.payload.content === 'msg', 'AGENT_MESSAGE handler should only receive its own events');
  assert(toolStart.payload.id === '1', 'TOOL_START handler should only receive its own events');
});

test('unsubscribe funciona', () => {
  const bus = new EventBus();
  let count = 0;
  const unsub = bus.on(EventType.AGENT_MESSAGE, () => { count++; });
  bus.emit(EventType.AGENT_MESSAGE, { content: '1' });
  assert(count === 1, 'handler should be called once');
  unsub();
  bus.emit(EventType.AGENT_MESSAGE, { content: '2' });
  assert(count === 1, 'handler should not be called after unsubscribe');
});

test('erro no handler nao quebra outros handlers', () => {
  const bus = new EventBus();
  let secondCalled = false;
  const origError = console.error;
  console.error = () => {};

  bus.on(EventType.AGENT_MESSAGE, () => { throw new Error('handler error'); });
  bus.on(EventType.AGENT_MESSAGE, () => { secondCalled = true; });

  bus.emit(EventType.AGENT_MESSAGE, { content: 'test' });

  console.error = origError;
  assert(secondCalled, 'second handler should still be called even if first throws');
});

test('EventHandler type recebe Event corretamente', () => {
  const bus = new EventBus();
  let captured: any = null;

  const handler: (event: { type: EventType; payload: any; timestamp: number }) => void = (event) => {
    captured = event;
  };

  bus.on(EventType.AGENT_MESSAGE, handler);
  bus.emit(EventType.AGENT_MESSAGE, { content: 'type check' });

  assert(captured.type === EventType.AGENT_MESSAGE, 'event.type should be AGENT_MESSAGE');
  assert('payload' in captured, 'event should have payload');
  assert('timestamp' in captured, 'event should have timestamp');
});

test('off - remove todos handlers de um tipo', () => {
  const bus = new EventBus();
  let count = 0;

  bus.on(EventType.AGENT_MESSAGE, () => { count++; });
  bus.on(EventType.AGENT_MESSAGE, () => { count++; });
  bus.emit(EventType.AGENT_MESSAGE, { content: '1' });
  assert(count === 2, 'both handlers should fire before off');

  bus.off(EventType.AGENT_MESSAGE);
  bus.emit(EventType.AGENT_MESSAGE, { content: '2' });
  assert(count === 2, 'handlers should not fire after off');
});

test('clear - remove todos handlers de todos os tipos', () => {
  const bus = new EventBus();
  let count = 0;

  bus.on(EventType.AGENT_MESSAGE, () => { count++; });
  bus.on(EventType.TOOL_START, () => { count++; });
  bus.emit(EventType.AGENT_MESSAGE, { content: '1' });
  assert(count === 1, 'handler should fire before clear');

  bus.clear();
  bus.emit(EventType.AGENT_MESSAGE, { content: '2' });
  bus.emit(EventType.TOOL_START, { id: '1', name: 'x', args: {} });
  assert(count === 1, 'handlers should not fire after clear');
});

// --- Runner ---

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
