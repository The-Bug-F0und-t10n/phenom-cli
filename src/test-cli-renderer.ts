import { CliRenderer } from './cli-renderer.js';
import { eventBus, EventType } from './tui/event-bus.js';
import readline from 'readline';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(`Assertion failed: ${msg}`);
}

test('finalizeStreaming persists assistant message in history', () => {
  const renderer: any = new CliRenderer();
  renderer.plain = true;
  renderer.streamingBlockId = 'stream-1';
  renderer.streamingContent = 'hello';
  renderer.streaming = true;

  const originalLog = console.log;
  console.log = () => {};
  try {
    renderer.finalizeStreaming('[assistant] hello');
  } finally {
    console.log = originalLog;
  }

  const history: string[] = renderer.history || [];
  assert(history.some((line) => line.includes('[assistant] hello')), 'assistant message should be persisted');
});

test('THINK_END flushes stream content before [done]', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  renderer.plain = true;
  renderer.rl = {
    output: {
      write: () => true,
      on: () => {},
    }
  };
  renderer.attach();

  const originalLog = console.log;
  console.log = () => {};
  try {
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'resposta final' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    console.log = originalLog;
    eventBus.clear();
  }

  const history: string[] = renderer.history || [];
  const assistantIdx = history.findIndex((line) => line.includes('[assistant] resposta final'));
  const doneIdx = history.findIndex((line) => line.includes('[done]'));

  assert(assistantIdx >= 0, 'assistant streamed content should be in history');
  assert(doneIdx >= 0, '[done] should be emitted');
  assert(assistantIdx < doneIdx, 'assistant content should appear before [done]');
});

test('countLines accounts for terminal soft-wrap', () => {
  const renderer: any = new CliRenderer();
  const lines = renderer.countLines(['12345', 'abc'], 4);
  assert(lines === 3, `expected 3 visual lines, got ${lines}`);
});

test('TOKEN_UPDATE refreshes token total for current inference', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  renderer.plain = true;
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.TOKEN_UPDATE, { input: 100, output: 12, total: 112 });
  } finally {
    eventBus.clear();
  }

  assert(renderer.tokenTotal === 112, `tokenTotal should be 112, got ${renderer.tokenTotal}`);
  assert(renderer.startTokens === 0, `startTokens should reset to 0, got ${renderer.startTokens}`);
});

test('writeBlock in TTY mode does not clear full screen', () => {
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 80,
    write: (data: string) => {
      writes.push(String(data));
      return true;
    },
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };

  const originalClearScreenDown = (readline as any).clearScreenDown;
  let clearScreenDownCalls = 0;
  (readline as any).clearScreenDown = (...args: any[]) => {
    clearScreenDownCalls++;
    return originalClearScreenDown(...args);
  };

  try {
    renderer.writeBlock('[assistant] hello');
  } finally {
    (readline as any).clearScreenDown = originalClearScreenDown;
  }

  assert(clearScreenDownCalls === 0, 'writeBlock should not call clearScreenDown');
  assert(writes.join('').includes('[assistant] hello\n'), 'block text should be written');
});

test('does not duplicate assistant output when AGENT_MESSAGE repeats streamed final text', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  renderer.plain = true;
  renderer.rl = {
    output: {
      write: () => true,
      on: () => {},
    }
  };
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'resultado final' });
    eventBus.emit(EventType.THINK_END, {});
    eventBus.emit(EventType.AGENT_MESSAGE, { content: 'resultado final' });
  } finally {
    eventBus.clear();
  }

  const history: string[] = renderer.history || [];
  const assistantLines = history.filter((line) => line.includes('[assistant] resultado final'));
  assert(assistantLines.length === 1, `assistant output should appear once, got ${assistantLines.length}`);
});

test('does not render second assistant line when AGENT_MESSAGE arrives before THINK_END', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 120,
    write: (data: string) => {
      writes.push(String(data));
      return true;
    },
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'abc' });
    eventBus.emit(EventType.AGENT_MESSAGE, { content: 'abc' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const joined = writes.join('');
  const assistantLabelCount = (joined.match(/\[assistant\]\s/g) || []).length;
  assert(assistantLabelCount === 1, `assistant label should be rendered once, got ${assistantLabelCount}`);
});

test('attach is idempotent (no duplicated handlers)', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  renderer.plain = true;
  renderer.rl = {
    output: {
      write: () => true,
      on: () => {},
    }
  };

  renderer.attach();
  renderer.attach();

  try {
    eventBus.emit(EventType.USER_MESSAGE, { content: 'msg unica' });
  } finally {
    eventBus.clear();
  }

  const history: string[] = renderer.history || [];
  const userLines = history.filter((line) => line.includes('[user] msg unica'));
  assert(userLines.length === 1, `user output should appear once, got ${userLines.length}`);
});

test('FILE_DIFF events render inline in real time (no buffer to THINK_END)', () => {
  // Semantics changed: diffs no longer wait for THINK_END. Each FILE_DIFF
  // renders immediately so multi-step mutations are visible while the agent
  // is still working. Two sequential writes to the same path now produce two
  // distinct diff blocks in the order they happened.
  eventBus.clear();
  const renderer: any = new CliRenderer();
  renderer.plain = true;
  renderer.rl = {
    output: {
      write: () => true,
      on: () => {},
    }
  };
  renderer.attach();

  const logs: string[] = [];
  const originalLog = console.log;
  console.log = (...args: any[]) => {
    logs.push(args.map(String).join(' '));
  };

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.FILE_DIFF, {
      path: 'hello-world.html',
      lineCount: 2,
      byteSize: 10,
      action: 'updated',
      content: '   1 │ old\n   2 │ a'
    });
    eventBus.emit(EventType.FILE_DIFF, {
      path: 'hello-world.html',
      lineCount: 2,
      byteSize: 12,
      action: 'updated',
      content: '   1 │ new\n   2 │ b'
    });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    console.log = originalLog;
    eventBus.clear();
  }

  const joined = logs.join('\n');
  const fileHeaderCount = (joined.match(/\[file\] hello-world\.html/g) || []).length;
  assert(fileHeaderCount === 2, `expected two real-time diff blocks (one per FILE_DIFF), got ${fileHeaderCount}`);
  assert(joined.includes('1 ~ │ new'), 'expected decorated diff line for second write');
  assert(joined.includes('1 ~ │ old'), 'expected first write to be visible too (no consolidation)');
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

  console.log(`\nCliRenderer tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
