import { buildInferenceMessagesUseCase } from '../../use-cases/build-inference-messages.js';
import { executeToolWithEventsUseCase } from '../../use-cases/execute-tool-with-events.js';
import { runToolLoopUseCase } from '../../use-cases/run-tool-loop.js';
import { eventBus, EventType } from '../../tui/event-bus.js';

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
    sessionId: 'test',
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
    sessionId: 'test',
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
    sessionId: 'test',
    summarizeConversation: async () => 'SUMMARY_OK'
  });

  const system = messages[0];
  const summary = messages.find((m, idx) => idx > 0 && m.role === 'system');
  assert(typeof system.content === 'string', 'system content should be string');
  assert(system.content === 'sys', 'system prompt should remain unchanged for prompt-cache reuse');
  assert(String(summary?.content || '').includes('SUMMARY_OK'), 'expected summary in separate system message');
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

test('runToolLoopUseCase auto-RAG orchestration runs status->search on concept queries (canary)', async () => {
  const prev = process.env.PHENOM_AUTO_RAG_ORCHESTRATION;
  process.env.PHENOM_AUTO_RAG_ORCHESTRATION = '1';

  const executed: Array<{ tool: string; args: Record<string, any> }> = [];
  let streamCalls = 0;

  try {
    const result = await runToolLoopUseCase(
      {
        llm: {
          chatStream: async (_messages, onChunk) => {
            streamCalls++;
            onChunk('{"type":"final","content":"done"}');
            return '';
          },
          chat: async () => ({ message: { content: 'no' } })
        },
        state: { addMessage() {} },
        brain: null,
        streamEnabled: false,
        supportsNativeTools: false,
        toolDefs: [],
        buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'q' }],
        extractPlanFromText: () => false,
        extractPlanProgressFromText: () => {},
        stripTemplateArtifacts: (content) => content,
        emitAssistantMessage: () => {},
        normalizeToolName: (toolName) => toolName,
        executeToolWithEvents: async (toolName, args) => {
          executed.push({ tool: toolName, args });
          if (toolName === 'rag_status') {
            return { success: true, output: 'RAG index presente — modelo=test, arquivos=1, chunks=2', error: null };
          }
          if (toolName === 'rag_search') {
            return { success: true, output: 'top 1 hits para: auth\n1. [0.91] src/auth.ts:10-20 (function login)', error: null };
          }
          return { success: true, output: 'ok', error: null };
        },
        formatToolResultForModel: (_toolName, res) => res.output || '',
        streamFileContent: () => {},
        askModelForMoreIterations: async () => false,
        maxContextTokens: 8192
      },
      'onde fica o fluxo de autenticação?'
    );

    assert(result === 'done', `expected done, got ${result}`);
    assert(streamCalls >= 1, `expected at least one stream call, got ${streamCalls}`);
    assert(executed.some(c => c.tool === 'rag_status'), `expected rag_status call, got ${executed.map(c => c.tool).join(',')}`);
    assert(executed.some(c => c.tool === 'rag_search'), `expected rag_search call, got ${executed.map(c => c.tool).join(',')}`);
  } finally {
    if (prev === undefined) delete process.env.PHENOM_AUTO_RAG_ORCHESTRATION;
    else process.env.PHENOM_AUTO_RAG_ORCHESTRATION = prev;
  }
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
  assert(executed === 1, `expected duplicate guard to skip repeated executions, got ${executed}`);
  // Either guard is a valid stop: the per-iteration "repeated plan" message
  // OR the per-call dedup directive. Both prove the loop noticed the model
  // wasn't making progress and bailed.
  const looksLikeNonProgressStop =
    result.includes('repeated non-progressing calls') ||
    /called \d+×.*last/.test(result);
  assert(looksLikeNonProgressStop, `expected non-progress stop message, got ${result}`);
  assert(
    assistantOutputs.some(m => m.includes('repeated non-progressing calls') || /called \d+×.*last/.test(m)),
    'expected assistant message for non-progress loop stop'
  );
});

test('runToolLoopUseCase compacts on Backend context exceeded and retries successfully', async () => {
  let streamCalls = 0;
  const snapshots: string[] = [];

  const result = await runToolLoopUseCase(
    {
      llm: {
        chatStream: async (messages, onChunk) => {
          streamCalls++;
          const serialized = messages.map(m => (typeof m.content === 'string' ? m.content : JSON.stringify(m.content))).join('\n');
          snapshots.push(serialized);
          if (streamCalls === 1) {
            throw new Error('Backend context exceeded: prompt=1200 tokens, server n_ctx=800.');
          }
          onChunk('{"type":"final","content":"ok apos compactar"}');
          return '';
        },
        chat: async () => ({ message: { content: 'no' } })
      },
      state: { addMessage() {} },
      brain: null,
      streamEnabled: false,
      supportsNativeTools: false,
      toolDefs: [],
      buildInitialMessages: async () => [
        { role: 'system', content: 'sys' },
        { role: 'user', content: 'DROP_A contexto antigo' },
        { role: 'assistant', content: 'DROP_B resposta antiga' },
        { role: 'user', content: 'DROP_C historico' },
        { role: 'assistant', content: 'DROP_D historico' },
        { role: 'user', content: 'pedido atual' }
      ],
      extractPlanFromText: () => false,
      extractPlanProgressFromText: () => {},
      stripTemplateArtifacts: (content) => content,
      emitAssistantMessage: () => {},
      normalizeToolName: (toolName) => toolName,
      executeToolWithEvents: async () => ({ success: true, output: 'ok', error: null }),
      formatToolResultForModel: (_toolName, res) => res.output,
      streamFileContent: () => {},
      askModelForMoreIterations: async () => false,
      maxContextTokens: 1000,
      tokenCount: async (text) => (
        text.includes('DROP_A') || text.includes('DROP_B') || text.includes('DROP_C') || text.includes('DROP_D')
          ? 1200
          : 250
      )
    },
    'pedido atual'
  );

  assert(streamCalls === 2, `expected retry after compaction, got ${streamCalls} calls`);
  assert(result === 'ok apos compactar', `expected successful retry result, got ${result}`);
  assert(snapshots.length >= 2, 'expected two message snapshots');
  assert(
    !snapshots[1].includes('DROP_A') && !snapshots[1].includes('DROP_B'),
    'expected old context to be compacted before retry'
  );
  assert(snapshots[1].includes('pedido atual'), 'expected current user request to remain pinned after compaction');
});

test('runToolLoopUseCase does not stop early on repeated grep_file exploration calls', async () => {
  let streamCalls = 0;
  let executed = 0;
  const assistantOutputs: string[] = [];

  const result = await runToolLoopUseCase(
    {
      llm: {
        chatStream: async (_messages, onChunk) => {
          streamCalls++;
          if (streamCalls <= 3) {
            onChunk(`{"type":"tool","toolName":"grep_file","args":{"path":"src","pattern":"CalculatorDisplay${streamCalls}"}}`);
          } else {
            onChunk('{"type":"final","content":"done"}');
          }
          return '';
        },
        chat: async () => ({ message: { content: 'no' } })
      },
      state: { addMessage() {} },
      brain: null,
      streamEnabled: false,
      supportsNativeTools: false,
      toolDefs: [{ type: 'function', function: { name: 'grep_file', description: 'grep', parameters: {} } }],
      buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'q' }],
      extractPlanFromText: () => false,
      extractPlanProgressFromText: () => {},
      stripTemplateArtifacts: (content) => content,
      emitAssistantMessage: (content) => assistantOutputs.push(content),
      normalizeToolName: (toolName) => toolName,
      executeToolWithEvents: async () => {
        executed++;
        return { success: true, output: 'hit', error: null };
      },
      formatToolResultForModel: (_toolName, res) => res.output,
      streamFileContent: () => {},
      askModelForMoreIterations: async () => true,
      maxContextTokens: 8192
    },
    'investigue o componente'
  );

  assert(result === 'done', `expected done, got ${result}`);
  assert(streamCalls === 4, `expected 4 stream calls (3 grep + final), got ${streamCalls}`);
  assert(executed === 3, `expected 3 grep executions, got ${executed}`);
  assert(
    !assistantOutputs.some(m => m.includes('without taking the result into account')),
    'should not trip per-call dedup guard for repeated grep exploration'
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

test('executeToolWithEventsUseCase allows mutation without plan (gate removed)', async () => {
  // Regression for the plan-gate removal. Previously a mutation without
  // set_plan returned [PLAN_REQUIRED]; now the underlying tool runs. The
  // hard mutation budget at 7 files still applies — covered separately.
  const emitted: Array<{ type: EventType; payload: any }> = [];
  const result = await executeToolWithEventsUseCase(
    {
      executeTool: async () => ({ success: true, output: 'ok', error: null }),
      emit: (type, payload) => emitted.push({ type, payload }),
      addToolCall: () => {},
      sessionId: 'session-1',
      brain: {
        addCreatedFile: () => {},
        addNote: () => 'n',
        addFailedOperation: () => {},
        addInsight: () => {},
        getPlanSteps: () => []
      }
    },
    'apply_patch',
    { path: 'a.ts', operations: [{ search: 'a', replace: 'b' }] }
  );
  assert(result.success, `expected success without plan, got error: ${result.error}`);
  assert(!String(result.error || '').includes('[PLAN_REQUIRED]'), 'gate should be removed');
});

test('executeToolWithEventsUseCase blocks signature-risk patch without caller evidence', async () => {
  const result = await executeToolWithEventsUseCase(
    {
      executeTool: async () => ({ success: true, output: 'ok', error: null }),
      emit: () => {},
      addToolCall: () => {},
      sessionId: 'session-1',
      brain: {
        addCreatedFile: () => {},
        addNote: () => 'n',
        addFailedOperation: () => {},
        addInsight: () => {},
        getPlanSteps: () => [{ status: 'pending' }],
        getRequestMetrics: () => ({ mutationFiles: [], searchCount: 0 }),
        noteMutation: () => {},
        noteSearchEvidence: () => {},
        noteValidation: () => {},
        noteTestsRun: () => {},
        noteBuildRun: () => {}
      } as any
    },
    'apply_patch',
    {
      path: 'a.ts',
      operations: [{ search: 'const x = 1', replace: 'export function foo() { return 1; }' }]
    }
  );
  assert(!result.success, 'expected failure without caller evidence');
  assert(
    String(result.error || '').includes('[CALLER_MATRIX_REQUIRED]'),
    `unexpected error: ${String(result.error)}`
  );
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
  // Unified diff format: each line is "<N> <marker> │ <text>" — same as
  // write_file/create_file. Removed lines get "-", added get "+".
  const content = String(diff!.payload.content || '');
  assert(content.includes('- │ old'), `expected numbered removed line for 'old', got: ${content}`);
  assert(content.includes('+ │ new'), `expected numbered added line for 'new', got: ${content}`);
});

test('executeToolWithEventsUseCase includes output in TOOL_ERROR payload', async () => {
  const emitted: Array<{ type: EventType; payload: any }> = [];

  const result = await executeToolWithEventsUseCase(
    {
      executeTool: async () => ({
        success: false,
        output: '$ tsc --noEmit\nsrc/a.ts:1:1 - error TS2304: Cannot find name',
        error: 'Exit code 1.'
      }),
      emit: (type, payload) => emitted.push({ type, payload }),
      addToolCall: () => {},
      sessionId: 'session-1',
      brain: {
        addCreatedFile: () => {},
        addNote: () => 'n',
        addFailedOperation: () => {},
        addInsight: () => {},
      } as any
    },
    'run_code',
    { command: 'tsc --noEmit' }
  );

  assert(!result.success, 'expected failure result');
  const errEv = emitted.find(e => e.type === EventType.TOOL_ERROR);
  assert(!!errEv, 'expected TOOL_ERROR event');
  assert(String(errEv!.payload.error).includes('Exit code 1'), `unexpected TOOL_ERROR error: ${String(errEv!.payload.error)}`);
  assert(String(errEv!.payload.output).includes('TS2304'), `expected TOOL_ERROR output to include stderr details, got: ${String(errEv!.payload.output)}`);
});

test('runToolLoopUseCase does not convert reasoning-only output into final content', async () => {
  const assistantOutputs: Array<{ visible: string; storage?: string }> = [];

  const result = await runToolLoopUseCase(
    {
      llm: {
        chatStream: async (_messages, _onChunk, _onToolCall, _tools, onReasoning) => {
          // No content; reasoning carries the whole reply.
          if (onReasoning) onReasoning('Ola! Como posso ajudar?');
          return '';
        },
        chat: async () => ({ message: { content: 'no' } })
      },
      state: {
        addMessage() {}
      },
      brain: null,
      streamEnabled: false,
      supportsNativeTools: false,
      toolDefs: [],
      buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'ola' }],
      extractPlanFromText: () => false,
      extractPlanProgressFromText: () => {},
      stripTemplateArtifacts: (content) => content,
      emitAssistantMessage: (visible, storage) => {
        assistantOutputs.push({ visible, storage });
      },
      normalizeToolName: (toolName) => toolName,
      executeToolWithEvents: async () => ({ success: true, output: '', error: null }),
      formatToolResultForModel: (_t, res) => res.output,
      streamFileContent: () => {},
      askModelForMoreIterations: async () => false,
      maxContextTokens: 8192
    },
    'ola'
  );

  assert(result === '', `expected empty final content for reasoning-only stream, got: ${JSON.stringify(result)}`);
  assert(assistantOutputs.length === 0,
    `reasoning-only stream must not be emitted as assistant output, got ${JSON.stringify(assistantOutputs)}`);
});

test('runToolLoopUseCase routes reasoning-only stream only to thinking channel', async () => {
  const events: Array<{ type: EventType; payload: any }> = [];
  const unsubs = [
    eventBus.on(EventType.REASONING_CHUNK, (event) => events.push({ type: event.type, payload: event.payload })),
    eventBus.on(EventType.MESSAGE_CHUNK, (event) => events.push({ type: event.type, payload: event.payload })),
  ];

  try {
    const result = await runToolLoopUseCase(
      {
        llm: {
          chatStream: async (_messages, _onChunk, _onToolCall, _tools, onReasoning) => {
            onReasoning?.('Ola! Como posso ajudar?');
            return '';
          },
          chat: async () => ({ message: { content: 'no' } })
        },
        state: { addMessage: () => {} },
        brain: null,
        streamEnabled: true,
        supportsNativeTools: false,
        toolDefs: [],
        buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'ola' }],
        extractPlanFromText: () => false,
        extractPlanProgressFromText: () => {},
        stripTemplateArtifacts: (content) => content,
        emitAssistantMessage: () => {},
        normalizeToolName: (toolName) => toolName,
        executeToolWithEvents: async () => ({ success: true, output: '', error: null }),
        formatToolResultForModel: (_t, res) => res.output,
        streamFileContent: () => {},
        askModelForMoreIterations: async () => false,
        maxContextTokens: 8192
      },
      'ola'
    );

    const reasoningChunks = events.filter(e => e.type === EventType.REASONING_CHUNK);
    const messageText = events
      .filter(e => e.type === EventType.MESSAGE_CHUNK)
      .map(e => String(e.payload?.chunk || ''))
      .join('');
    const reasoningText = reasoningChunks.map(e => String(e.payload?.chunk || '')).join('');
    assert(result === '', `expected empty final content, got: ${JSON.stringify(result)}`);
    assert(reasoningText === 'Ola! Como posso ajudar?', `expected thinking channel, got ${JSON.stringify(reasoningText)}`);
    assert(messageText === '', `reasoning-only stream must not be MESSAGE_CHUNK, got ${JSON.stringify(messageText)}`);
  } finally {
    unsubs.forEach(unsub => unsub());
  }
});

test('runToolLoopUseCase keeps real reasoning separate from final content', async () => {
  const events: Array<{ type: EventType; payload: any }> = [];
  const unsubs = [
    eventBus.on(EventType.REASONING_CHUNK, (event) => events.push({ type: event.type, payload: event.payload })),
    eventBus.on(EventType.MESSAGE_CHUNK, (event) => events.push({ type: event.type, payload: event.payload })),
  ];

  try {
    const result = await runToolLoopUseCase(
      {
        llm: {
          chatStream: async (_messages, onChunk, _onToolCall, _tools, onReasoning) => {
            onReasoning?.('Preciso responder uma saudacao curta.');
            onChunk('Ola!');
            return 'Ola!';
          },
          chat: async () => ({ message: { content: 'no' } })
        },
        state: { addMessage: () => {} },
        brain: null,
        streamEnabled: true,
        supportsNativeTools: false,
        toolDefs: [],
        buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'ola' }],
        extractPlanFromText: () => false,
        extractPlanProgressFromText: () => {},
        stripTemplateArtifacts: (content) => content,
        emitAssistantMessage: () => {},
        normalizeToolName: (toolName) => toolName,
        executeToolWithEvents: async () => ({ success: true, output: '', error: null }),
        formatToolResultForModel: (_t, res) => res.output,
        streamFileContent: () => {},
        askModelForMoreIterations: async () => false,
        maxContextTokens: 8192
      },
      'ola'
    );

    const reasoningText = events
      .filter(e => e.type === EventType.REASONING_CHUNK)
      .map(e => String(e.payload?.chunk || ''))
      .join('');
    const messageText = events
      .filter(e => e.type === EventType.MESSAGE_CHUNK)
      .map(e => String(e.payload?.chunk || ''))
      .join('');
    assert(result === 'Ola!', `unexpected result: ${result}`);
    assert(reasoningText === 'Preciso responder uma saudacao curta.', `reasoning lost: ${JSON.stringify(reasoningText)}`);
    assert(messageText === 'Ola!', `content lost: ${JSON.stringify(messageText)}`);
  } finally {
    unsubs.forEach(unsub => unsub());
  }
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
