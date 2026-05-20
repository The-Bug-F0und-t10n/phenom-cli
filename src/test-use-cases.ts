import { buildInferenceMessagesUseCase } from './use-cases/build-inference-messages.js';
import { executeToolWithEventsUseCase } from './use-cases/execute-tool-with-events.js';
import { runToolLoopUseCase } from './use-cases/run-tool-loop.js';
import { EventType } from './tui/event-bus.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error(msg);
}

test('buildInferenceMessagesUseCase appends current query when missing', async () => {
  const messages = await buildInferenceMessagesUseCase({
    systemPrompt: 'sys',
    recentMessages: [{ role: 'assistant', content: 'prev', timestamp: Date.now() }],
    currentQuery: 'latest question',
    maxContextTokens: 4096,
    summarizeConversation: async () => ''
  });

  const last = messages[messages.length - 1];
  assert(last.role === 'user', `expected last role user, got ${last.role}`);
  assert(last.content === 'latest question', `expected current query, got ${String(last.content)}`);
});

test('buildInferenceMessagesUseCase replaces last matching user message with multimodal content', async () => {
  const messages = await buildInferenceMessagesUseCase({
    systemPrompt: 'sys',
    recentMessages: [
      { role: 'user', content: 'same query', timestamp: Date.now() },
      { role: 'assistant', content: 'ok', timestamp: Date.now() },
      { role: 'user', content: 'same query', timestamp: Date.now() }
    ],
    currentQuery: 'same query',
    currentUserContent: [
      { type: 'text', text: 'same query' },
      { type: 'image_url', image_url: { url: 'data:image/png;base64,abc' } }
    ],
    maxContextTokens: 4096,
    summarizeConversation: async () => ''
  });

  const lastUser = [...messages].reverse().find(m => m.role === 'user');
  assert(!!lastUser, 'expected user message');
  assert(Array.isArray(lastUser!.content), 'expected multimodal content array');
});

test('buildInferenceMessagesUseCase compacts and injects summary when above threshold', async () => {
  const long = 'x'.repeat(1200);
  const messages = await buildInferenceMessagesUseCase({
    systemPrompt: 'sys',
    recentMessages: [
      { role: 'user', content: long, timestamp: Date.now() },
      { role: 'assistant', content: long, timestamp: Date.now() },
      { role: 'user', content: long, timestamp: Date.now() },
      { role: 'assistant', content: long, timestamp: Date.now() },
      { role: 'user', content: 'final query', timestamp: Date.now() }
    ],
    currentQuery: 'final query',
    maxContextTokens: 200,
    summarizeConversation: async () => 'SUMMARY_OK'
  });

  const system = messages[0];
  assert(typeof system.content === 'string', 'system content should be string');
  assert(String(system.content).includes('SUMMARY_OK'), 'expected summary in system prompt');
});

test('runToolLoopUseCase executes fallback JSON tool then returns final JSON content', async () => {
  const stateMessages: any[] = [];
  const executed: Array<{ tool: string; args: Record<string, any> }> = [];
  const assistantOutputs: string[] = [];
  const toolsPassed: any[] = [];
  let streamCalls = 0;

  const result = await runToolLoopUseCase(
    {
      llm: {
        chatStream: async (_messages, onChunk, _onToolCall, tools) => {
          toolsPassed.push(tools);
          streamCalls++;
          if (streamCalls === 1) {
            onChunk('{"type":"tool","toolName":"date","args":{}}');
          } else {
            onChunk('{"type":"final","content":"done"}');
          }
          return '';
        },
        chat: async () => ({ message: { content: 'no' } })
      },
      state: {
        addMessage(message) {
          stateMessages.push(message);
        }
      },
      brain: null,
      streamEnabled: false,
      supportsNativeTools: false,
      toolDefs: [{ type: 'function', function: { name: 'date', description: 'date tool' } }],
      buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'q' }],
      extractPlanFromText: () => false,
      extractPlanProgressFromText: () => {},
      stripTemplateArtifacts: (content) => content,
      emitAssistantMessage: (content) => {
        assistantOutputs.push(content);
      },
      normalizeToolName: (toolName) => toolName,
      executeToolWithEvents: async (toolName, args) => {
        executed.push({ tool: toolName, args });
        return { success: true, output: 'ok', error: null };
      },
      formatToolResultForModel: (_toolName, res) => res.output,
      streamFileContent: () => {},
      askModelForMoreIterations: async () => false,
      maxContextTokens: 8192
    },
    'task'
  );

  assert(result === 'done', `expected done, got ${result}`);
  assert(executed.length === 1, `expected 1 tool execution, got ${executed.length}`);
  assert(executed[0].tool === 'date', `expected date tool, got ${executed[0].tool}`);
  assert(toolsPassed.every(t => t === undefined), 'tools should be undefined when supportsNativeTools=false');
  assert(stateMessages.some(m => m.role === 'tool'), 'expected tool message persisted');
  assert(assistantOutputs.includes('done'), 'expected final assistant output');
});

test('runToolLoopUseCase accepts model text response without forcing tool retry', async () => {
  // After the disk-IO heuristic was removed, a text-only response from the
  // model is treated as the final answer. No SYSTEM_GUARD recovery prompt is
  // injected, no failure is raised — the model decides whether a tool is
  // needed.
  const executed: Array<{ tool: string; args: Record<string, unknown> }> = [];
  const streamMessages: Array<Array<{ role: string; content: string | any[] }>> = [];
  const assistantOutputs: string[] = [];
  let streamCalls = 0;

  const result = await runToolLoopUseCase(
    {
      llm: {
        chatStream: async (messages, onChunk) => {
          streamMessages.push(messages.map(m => ({ role: m.role, content: m.content })));
          streamCalls++;
          onChunk('Vou refatorar o arquivo para adicionar um background gradiente animado.');
          return '';
        },
        chat: async () => ({ message: { content: 'no' } })
      },
      state: { addMessage() {} },
      brain: null,
      streamEnabled: false,
      supportsNativeTools: true,
      toolDefs: [{ type: 'function', function: { name: 'write_file', description: 'write', parameters: {} } }],
      buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'q' }],
      extractPlanFromText: () => false,
      extractPlanProgressFromText: () => {},
      stripTemplateArtifacts: (content) => content,
      emitAssistantMessage: (content) => assistantOutputs.push(content),
      normalizeToolName: (toolName) => toolName,
      executeToolWithEvents: async (toolName, args) => {
        executed.push({ tool: toolName, args });
        return { success: true, output: 'ok', error: null };
      },
      formatToolResultForModel: (_toolName, res) => res.output,
      streamFileContent: () => {},
      askModelForMoreIterations: async () => false,
      maxContextTokens: 8192
    },
    'refatore o hello-world.html para um background gradiente que muda de cor sozinho'
  );

  assert(streamCalls === 1, `expected single stream call (no forced retry), got ${streamCalls}`);
  assert(executed.length === 0, `expected zero tool executions when model gives text, got ${executed.length}`);
  assert(
    result === 'Vou refatorar o arquivo para adicionar um background gradiente animado.',
    `expected model text as final, got ${result}`
  );
  assert(
    !assistantOutputs.some(msg => msg.includes('[guard]') || msg.includes('SYSTEM_GUARD')),
    'no guard message should be emitted — guard was removed'
  );
});

test('runToolLoopUseCase stops repeated non-progressing tool-call loop', async () => {
  let streamCalls = 0;
  let executed = 0;
  const assistantOutputs: string[] = [];

  const result = await runToolLoopUseCase(
    {
      llm: {
        chatStream: async (_messages, onChunk) => {
          streamCalls++;
          onChunk('{"type":"tool","toolName":"read_file","args":{"path":"hello-world.html"}}');
          return '';
        },
        chat: async () => ({ message: { content: 'yes' } })
      },
      state: { addMessage() {} },
      brain: null,
      streamEnabled: false,
      supportsNativeTools: false,
      toolDefs: [{ type: 'function', function: { name: 'read_file', description: 'read', parameters: {} } }],
      buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'q' }],
      extractPlanFromText: () => false,
      extractPlanProgressFromText: () => {},
      stripTemplateArtifacts: (content) => content,
      emitAssistantMessage: (content) => assistantOutputs.push(content),
      normalizeToolName: (toolName) => toolName,
      executeToolWithEvents: async () => {
        executed++;
        return { success: true, output: 'same content', error: null };
      },
      formatToolResultForModel: (_toolName, res) => res.output,
      streamFileContent: () => {},
      askModelForMoreIterations: async () => true,
      maxContextTokens: 8192
    },
    'leia hello-world.html'
  );

  assert(streamCalls < 20, `expected early stop before classic limit, got ${streamCalls}`);
  assert(executed >= 3, `expected repeated executions before stop, got ${executed}`);
  assert(
    result.includes('repeated non-progressing calls'),
    `expected non-progress stop message, got ${result}`
  );
  assert(
    assistantOutputs.some(msg => msg.includes('repeated non-progressing calls')),
    'expected assistant message for non-progress loop stop'
  );
});

test('executeToolWithEventsUseCase emits events and persists tool call metadata', async () => {
  const emitted: Array<{ type: EventType; payload: any }> = [];
  const toolCalls: any[] = [];
  const notes: string[] = [];
  const insights: string[] = [];
  const failedOps: string[] = [];
  const createdFiles: string[] = [];

  const result = await executeToolWithEventsUseCase(
    {
      executeTool: async () => ({ success: true, output: '[REPLACED] ok', error: null }),
      emit: (type, payload) => emitted.push({ type, payload }),
      addToolCall: (call) => toolCalls.push(call),
      sessionId: 'session-1',
      brain: {
        addCreatedFile: (filePath) => createdFiles.push(filePath),
        addNote: (_type, content) => {
          notes.push(content);
          return 'note-id';
        },
        addFailedOperation: (op) => failedOps.push(op),
        addInsight: (insight) => insights.push(insight)
      }
    },
    'write_file',
    { path: 'a.txt', content: 'x\ny' }
  );

  assert(result.success, 'expected successful result');
  assert(toolCalls.length === 1, `expected one persisted tool call, got ${toolCalls.length}`);
  assert(createdFiles.includes('a.txt'), 'expected created file tracking');
  assert(notes.some(n => n.includes('Created: a.txt')), 'expected progress note');
  assert(insights.length === 0, 'no read/search insight expected for write_file');
  assert(failedOps.length === 0, 'no failed op expected');
  assert(emitted.some(e => e.type === EventType.TOOL_START), 'expected TOOL_START event');
  assert(emitted.some(e => e.type === EventType.TOOL_RESULT), 'expected TOOL_RESULT event');
  assert(emitted.some(e => e.type === EventType.FILE_DIFF), 'expected FILE_DIFF event');
  assert(emitted.some(e => e.type === EventType.SESSION_UPDATE), 'expected SESSION_UPDATE event');
});

test('executeToolWithEventsUseCase emits FILE_DIFF deleted for delete_file', async () => {
  const emitted: Array<{ type: EventType; payload: any }> = [];

  await executeToolWithEventsUseCase(
    {
      executeTool: async () => ({ success: true, output: 'deleted', error: null }),
      emit: (type, payload) => emitted.push({ type, payload }),
      addToolCall: () => {},
      sessionId: 'session-1',
      brain: null
    },
    'delete_file',
    { path: 'tmp.txt' }
  );

  const diff = emitted.find(e => e.type === EventType.FILE_DIFF);
  assert(!!diff, 'expected FILE_DIFF for delete_file');
  assert(diff!.payload.action === 'deleted', `expected deleted action, got ${String(diff!.payload.action)}`);
});

test('executeToolWithEventsUseCase emits FILE_DIFF patched for apply_patch', async () => {
  const emitted: Array<{ type: EventType; payload: any }> = [];

  await executeToolWithEventsUseCase(
    {
      executeTool: async () => ({ success: true, output: 'patched', error: null }),
      emit: (type, payload) => emitted.push({ type, payload }),
      addToolCall: () => {},
      sessionId: 'session-1',
      brain: null
    },
    'apply_patch',
    { path: 'hello-world.html', operations: [{ search: 'old', replace: 'new' }] }
  );

  const diff = emitted.find(e => e.type === EventType.FILE_DIFF);
  assert(!!diff, 'expected FILE_DIFF for apply_patch');
  assert(diff!.payload.action === 'patched', `expected patched action, got ${String(diff!.payload.action)}`);
  assert(String(diff!.payload.content || '').includes('- old'), 'expected patch summary content');
});

async function main(): Promise<void> {
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

  console.log(`\nUse-case tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
