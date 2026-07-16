import { CliRenderer } from '../../cli-renderer.js';
import { eventBus, EventType } from '../../tui/event-bus.js';
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
  assert(history.some((line) => line.includes('\nhello')), 'assistant message should be persisted');
});

test('THINK_END flushes stream content and keeps [done] only in status bar', () => {
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
  const assistantIdx = history.findIndex((line) => line.includes('\nresposta final'));
  const doneIdx = history.findIndex((line) => line.includes('[done]'));

  assert(assistantIdx >= 0, 'assistant streamed content should be in history');
  assert(doneIdx === -1, '[done] should not be written to chat history');
  assert(String(renderer.doneStatus || '').includes('[done]'), '[done] should remain available in status bar');
});

test('streamed thinking IS persisted in history after THINK_END', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
    write: () => true,
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: 'primeira linha\nsegunda linha' });
    eventBus.emit(EventType.AGENT_MESSAGE, { content: 'resposta final' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const layout: string[] = renderer.layoutHistory || [];
  const history: string[] = renderer.history || [];
  // Thinking streams live AND survives into layoutHistory with the [thinking]
  // marker so a resize/repaint re-wraps it instead of dropping it. It must
  // appear before the response in the chat.
  const thinkingIdx = layout.findIndex((l) => l.includes('[thinking]') && l.includes('primeira linha'));
  const assistantLayoutIdx = layout.findIndex((line) => line.includes('resposta final'));
  const assistantIdx = history.findIndex((line) => line.includes('resposta final'));
  const doneIdx = history.findIndex((line) => line.includes('[done]'));

  assert(thinkingIdx >= 0, 'streamed thinking must be persisted with the [thinking] marker');
  assert(assistantLayoutIdx > thinkingIdx, 'thinking must be persisted before the response');
  assert(assistantIdx >= 0, 'assistant response should be persisted');
  assert(doneIdx === -1, '[done] should not be written to chat history');
});

test('thinking that duplicates the answer is suppressed at THINK_END', () => {
  // Phenom on trivial prompts emits <think>X</think>X — splitThink classifies
  // the same text as both reasoning and content, and the renderer used to
  // persist both, producing a "│ thinking" block byte-for-byte equal to the
  // assistant answer. The duplicate-of-answer guard must drop the thinking
  // block from history so rebuildViewportFromHistory erases it from screen.
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
    write: () => true,
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.attach();

  const sameText = 'Olá! Como posso ajudar você hoje?';
  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: sameText });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: sameText });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const layout: string[] = renderer.layoutHistory || [];
  const thinkingPersisted = layout.some((l) => l.includes('[thinking]'));
  const answerPersisted = layout.some((l) => l.includes(sameText));

  assert(!thinkingPersisted, 'duplicate thinking must NOT be persisted to history');
  assert(answerPersisted, 'assistant answer must still be persisted');
});

test('thinking that differs from the answer is still persisted', () => {
  // Inverse guard: a real chain-of-thought (different from the answer) must
  // continue to surface in history so the user can audit the model.
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
    write: () => true,
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: 'preciso somar 17 + 23 passo a passo' });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'A resposta é 40.' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const layout: string[] = renderer.layoutHistory || [];
  const thinkingPersisted = layout.some((l) => l.includes('[thinking]') && l.includes('17 + 23'));
  const answerPersisted = layout.some((l) => l.includes('A resposta é 40.'));

  assert(thinkingPersisted, 'genuine reasoning must remain in history');
  assert(answerPersisted, 'assistant answer must remain in history');
});

test('very short reasoning that happens to match a word in the answer is NOT suppressed', () => {
  // Guard against false positive: short reasoning ("ok") that substring-matches
  // the answer should still be persisted. The 20-char threshold prevents the
  // .includes() branch from firing on trivial overlaps.
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
    write: () => true,
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: 'sim' });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'sim, isso está correto e funciona bem.' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const layout: string[] = renderer.layoutHistory || [];
  const thinkingPersisted = layout.some((l) => l.includes('[thinking]') && l.includes('sim'));
  assert(thinkingPersisted, 'short reasoning must not be suppressed by accidental substring match');
});

test('thinking and response both remain in history when AGENT_MESSAGE precedes THINK_END', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
    write: () => true,
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.attach();

  try {
    eventBus.emit(EventType.THINK_START, { message: 'Thinking' });
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: 'linha de raciocinio' });
    eventBus.emit(EventType.AGENT_MESSAGE, { content: 'resposta final' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const layout: string[] = renderer.layoutHistory || [];
  const thinkingIdx = layout.findIndex((l) => l.includes('[thinking]') && l.includes('linha de raciocinio'));
  const assistantIdx = layout.findIndex((line) => line.includes('resposta final'));

  assert(thinkingIdx >= 0, 'thinking must be persisted alongside the response');
  assert(assistantIdx > thinkingIdx, 'response must be persisted after the thinking block');
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

test('writeBlock applies fixed lateral gutter in TTY mode', () => {
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
  renderer.writeBlock('[assistant] hello');

  const joined = writes.join('');
  assert(joined.includes(' [assistant] hello\n'), `expected left gutter, got: ${joined}`);
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
  const assistantLines = history.filter((line) => line.includes('\nresultado final'));
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
  const assistantContentCount = (joined.match(/abc/g) || []).length;
  assert(assistantContentCount === 1, `assistant content should be rendered once, got ${assistantContentCount}`);
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
  const layoutHistory: string[] = renderer.layoutHistory || [];
  const userTag = `[${String(renderer.userLabel || 'user')}]`;
  const userLines = history.filter((line) => line.includes(`${userTag} msg unica`));
  assert(userLines.length === 1, `user output should appear once, got ${userLines.length}`);
  assert(layoutHistory.some((line) => line.startsWith('\n[user] msg unica')), 'user layout entry should keep top separator');
});

test('TOOL_ERROR for run_code renders output details (stdout/stderr)', () => {
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
    eventBus.emit(EventType.TOOL_START, { id: 'r1', name: 'run_code', args: { command: 'tsc --noEmit' } });
    eventBus.emit(EventType.TOOL_ERROR, {
      id: 'r1',
      toolName: 'run_code',
      error: 'Exit code 1.',
      output: '$ tsc --noEmit\nsrc/a.ts:1:1 - error TS2304: Cannot find name\n--- stderr ---\nfail'
    });
  } finally {
    console.log = originalLog;
    eventBus.clear();
  }

  const joined = logs.join('\n');
  assert(joined.includes('Exit code 1.'), 'expected error headline');
  assert(joined.includes('TS2304'), `expected run_code output details, got: ${joined}`);
  assert(joined.includes('--- stderr ---'), 'expected stderr section');
});

test('FILE_DIFF events render inline in real time (no buffer to THINK_END)', () => {
  // Semantics changed: diffs no longer wait for THINK_END. Each FILE_DIFF
  // renders immediately so multi-step mutations are visible while the agent
  // is still working. Two sequential writes to the same path now produce two
  // distinct diff blocks in the order they happened — which is what the
  // user actually wants to see.
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
    const afterFirst = logs.length;
    eventBus.emit(EventType.FILE_DIFF, {
      path: 'hello-world.html',
      lineCount: 2,
      byteSize: 12,
      action: 'updated',
      content: '   1 │ new\n   2 │ b'
    });
    const afterSecond = logs.length;
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    console.log = originalLog;
    eventBus.clear();
  }

  const joined = logs.join('\n');
  // Header changed from `[file] <path>` to `◆ <path>` for visual clarity.
  const fileHeaderCount = (joined.match(/◆ hello-world\.html/g) || []).length;
  assert(fileHeaderCount === 2, `expected two real-time diff blocks (one per FILE_DIFF), got ${fileHeaderCount}`);
  assert(joined.includes('1 ~ │ new'), 'expected decorated diff line for second write');
  assert(joined.includes('1 ~ │ old'), 'expected first write to be visible too (no consolidation)');
});

test('reflow rebuild uses logical history for user messages', () => {
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 80,
    rows: 24,
    write: (data: string) => {
      writes.push(String(data));
      return true;
    },
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.altScreenActive = true;
  renderer.history = ['STALE_PRE_RENDERED_BLOCK'];
  renderer.layoutHistory = ['[user] ola'];
  renderer.rebuildViewportFromHistory();

  const joined = writes.join('');
  const userTag = `[${String(renderer.userLabel || 'user')}]`;
  assert(!joined.includes('STALE_PRE_RENDERED_BLOCK'), 'rebuild should not use stale rendered history');
  assert(joined.includes(`${userTag} ola`), 'rebuild should re-render from logical user history');
});

test('reflow rebuild keeps content anchored near bottom (no jump to top)', () => {
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 80,
    rows: 24,
    write: (data: string) => {
      writes.push(String(data));
      return true;
    },
    on: () => {},
  };

  renderer.plain = false;
  renderer.rl = { output: fakeOutput };
  renderer.altScreenActive = true;
  renderer.layoutHistory = ['linha unica'];
  renderer.rebuildViewportFromHistory();

  const joined = writes.join('');
  // rows=24, bottomBarRows=5 => contentRows=19; with one visual line used,
  // start row must be 19 (bottom-anchored), not 1.
  assert(joined.includes('\x1b[19;1H'), `expected bottom-anchored redraw cursor, got: ${joined}`);
});

test('streamed assistant chunk uses fixed lateral gutter', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
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
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'abc\ndef' });
    eventBus.emit(EventType.CLEAR_STREAMING, {});
  } finally {
    eventBus.clear();
  }

  const joined = writes.join('');
  assert(joined.includes('\n abc\n def'), `expected guttered streamed output, got: ${joined}`);
});

test('user bubble renders content without extra gray spacer rows', () => {
  const renderer: any = new CliRenderer();
  const block = renderer.formatUserMessageBubble('quem e voce');
  const userTag = `[${String(renderer.userLabel || 'user')}]`;
  assert(!block.includes('\n\n'), `expected no empty spacer rows in user bubble, got: ${JSON.stringify(block)}`);
  assert(block.includes(`${userTag} quem e voce`), `expected user content in bubble, got: ${JSON.stringify(block)}`);
});

test('writeBlock user bubble path does not append extra trailing newline', () => {
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
  const bubble = renderer.formatUserMessageBubble('msg unica');
  renderer.writeBlock(bubble, true, '[user] msg unica');

  const joined = writes.join('');
  assert(joined.includes(bubble + '\n'), 'user bubble should receive exactly one trailing newline at writeBlock');
});

test('assistant message block has separators before and after content', () => {
  const renderer: any = new CliRenderer();
  const block = renderer.formatAssistantMessageBlock('Ola!');
  assert(block.startsWith('\nOla!'), `expected leading separator before assistant content, got: ${JSON.stringify(block)}`);
  assert(block.endsWith('Ola!'), `expected no trailing separator inside assistant formatter, got: ${JSON.stringify(block)}`);
});

test('thinking block has separator before and after content', () => {
  const renderer: any = new CliRenderer();
  const block = renderer.formatThinkingBlock('linha 1');
  assert(block.startsWith('\n'), 'expected leading separator before thinking block');
  assert(block.endsWith('linha 1'), 'expected no trailing separator inside thinking formatter');
});

test('thinking and assistant output keep a blank separator in stream mode', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
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
    eventBus.emit(EventType.REASONING_CHUNK, {
      chunk: "The user sent a short greeting in Portuguese. I'll reply briefly."
    });
    eventBus.emit(EventType.MESSAGE_CHUNK, { chunk: 'Ola!' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const joined = writes.join('');
  const marker = '│ thinking';
  const markerIdx = joined.lastIndexOf(marker);
  const outputIdx = joined.lastIndexOf('Ola!');
  assert(markerIdx >= 0 && outputIdx > markerIdx, 'thinking and output should both be rendered');
  const between = joined.slice(markerIdx, outputIdx);
  assert(/\n\s*\n/.test(between), `expected blank separator between thinking and output, got: ${between}`);
});

test('reasoning chunk ending with newline does not render dangling marker line', () => {
  eventBus.clear();
  const renderer: any = new CliRenderer();
  const writes: string[] = [];
  const fakeOutput: any = {
    columns: 120,
    rows: 24,
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
    eventBus.emit(EventType.REASONING_CHUNK, { chunk: 'linha final com quebra\n' });
    eventBus.emit(EventType.THINK_END, {});
  } finally {
    eventBus.clear();
  }

  const joined = writes.join('');
  assert(!joined.includes('│\n\n'), `unexpected dangling thinking marker, got: ${joined}`);
});

test('computePromptViewport wraps at paint width to avoid hiding last input char', () => {
  const renderer: any = new CliRenderer();
  // With cols=20, drawFixedPrompt paints 19 cols (last col reserved),
  // leaving 17 chars for content after the 2-char prompt prefix.
  renderer.promptBuffer = '123456789012345678'; // 18 chars
  renderer.cursorOffset = renderer.promptBuffer.length;
  const viewport = renderer.computePromptViewport(20);

  assert(viewport.visibleLines.length === 2, `expected wrap into 2 lines, got ${viewport.visibleLines.length}`);
  assert(viewport.visibleLines[0] === '12345678901234567', `unexpected first line: ${viewport.visibleLines[0]}`);
  assert(viewport.visibleLines[1] === '8', `unexpected second line: ${viewport.visibleLines[1]}`);
});

test('Up arrow does not open history when prompt has content', () => {
  const renderer: any = new CliRenderer();
  renderer.promptBuffer = 'abc';
  renderer.cursorOffset = 3;
  renderer.inputHistory = ['old command'];
  renderer.historyIndex = -1;

  const changed = renderer.handleCsi('\x1b[A');
  assert(changed === false, `expected no change, got changed=${changed}`);
  assert(renderer.promptBuffer === 'abc', `prompt changed unexpectedly: ${renderer.promptBuffer}`);
  assert(renderer.historyIndex === -1, `historyIndex changed unexpectedly: ${renderer.historyIndex}`);
});

test('History navigation starts only on empty prompt and remains navigable', () => {
  const renderer: any = new CliRenderer();
  renderer.promptBuffer = '';
  renderer.cursorOffset = 0;
  renderer.inputHistory = ['old command'];
  renderer.historyIndex = -1;

  const opened = renderer.handleCsi('\x1b[A');
  assert(opened === true, 'expected history open on empty prompt');
  assert(renderer.promptBuffer === 'old command', `expected history entry, got: ${renderer.promptBuffer}`);
  assert(renderer.historyIndex === 0, `expected historyIndex=0, got ${renderer.historyIndex}`);

  const closed = renderer.handleCsi('\x1b[B');
  assert(closed === true, 'expected history close on Down');
  assert(renderer.promptBuffer === '', `expected draft restore, got: ${renderer.promptBuffer}`);
  assert(renderer.historyIndex === -1, `expected historyIndex=-1, got ${renderer.historyIndex}`);
});

test('bottom bar reserves one blank line above and below input area', () => {
  const renderer: any = new CliRenderer();
  renderer.promptRowsRendered = 1;
  const rows = renderer.bottomBarRows();
  // BOTTOM_GAP_ROWS(1) + status(1) + inputTop(1) + prompt(1) + inputBottom(1)
  assert(rows === 5, `expected bottom bar rows=5, got ${rows}`);
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
