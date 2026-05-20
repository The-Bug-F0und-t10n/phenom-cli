import { promises as fs } from 'fs';
import os from 'os';
import path from 'path';
import { runToolLoopUseCase } from '../../use-cases/run-tool-loop.js';
import { ToolSystem } from '../../tools.js';
import { executeToolWithEventsUseCase } from '../../use-cases/execute-tool-with-events.js';
import { EventType } from '../../tui/event-bus.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void): void {
  tests.push({ name, fn });
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

async function inTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-io-seq-'));
  const oldCwd = process.cwd();
  process.chdir(dir);
  try {
    return await fn(dir);
  } finally {
    process.chdir(oldCwd);
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

test('tool loop executes refactor/create/delete in same inference', async () => {
  await inTempDir(async (tmpDir) => {
    const htmlPath = path.join(tmpDir, 'hello-world.html');
    await fs.writeFile(
      htmlPath,
      '<html><body style="background:#fff">Hello</body></html>\n',
      'utf-8'
    );
    await fs.writeFile(path.join(tmpDir, 'obsolete.txt'), 'old\n', 'utf-8');

    const toolSystem = new ToolSystem();
    const emitted: Array<{ type: EventType; payload: unknown }> = [];
    const stateMessages: Array<{ role: 'assistant' | 'tool'; content: string }> = [];
    const assistantOutputs: string[] = [];

    let streamCalls = 0;
    const result = await runToolLoopUseCase(
      {
        llm: {
          chatStream: async (_messages, onChunk, onToolCall) => {
            streamCalls++;
            if (streamCalls === 1) {
              onToolCall?.('write_file', {
                path: 'hello-world.html',
                content: '<html><body style="background:linear-gradient(90deg,#ff7e5f,#feb47b);animation:bg 8s ease infinite">Hello</body></html>\n'
              }, 'call_refactor');
              onToolCall?.('create_file', {
                path: 'notes.txt',
                content: 'gradient applied\n'
              }, 'call_create');
              onToolCall?.('delete_file', {
                path: 'obsolete.txt'
              }, 'call_delete');
            } else {
              onChunk('{"type":"final","content":"concluido"}');
            }
            return '';
          },
          chat: async () => ({ message: { content: 'no' } })
        },
        state: {
          addMessage(message) {
            stateMessages.push({ role: message.role, content: message.content });
          }
        },
        brain: null,
        streamEnabled: false,
        supportsNativeTools: true,
        toolDefs: toolSystem.getToolDefinitions(),
        buildInitialMessages: async () => [{ role: 'system', content: 'sys' }, { role: 'user', content: 'q' }],
        extractPlanFromText: () => false,
        extractPlanProgressFromText: () => {},
        stripTemplateArtifacts: (content) => content,
        emitAssistantMessage: (content) => assistantOutputs.push(content),
        normalizeToolName: (toolName) => toolName,
        executeToolWithEvents: async (toolName, args) => {
          return executeToolWithEventsUseCase(
            {
              executeTool: (name, inputArgs) => toolSystem.execute(name, inputArgs),
              emit: (type, payload) => emitted.push({ type, payload }),
              addToolCall: () => {},
              sessionId: 'test-session',
              brain: null
            },
            toolName,
            args
          );
        },
        formatToolResultForModel: (_toolName, toolResult) => toolResult.output || (toolResult.error || ''),
        streamFileContent: () => {},
        askModelForMoreIterations: async () => false,
        maxContextTokens: 8192
      },
      'refatore o hello-world.html, crie notes.txt e delete obsolete.txt'
    );

    const html = await fs.readFile(htmlPath, 'utf-8');
    const notes = await fs.readFile(path.join(tmpDir, 'notes.txt'), 'utf-8');
    const obsoleteExists = await fs.access(path.join(tmpDir, 'obsolete.txt')).then(() => true).catch(() => false);

    assert(streamCalls >= 2, `expected at least 2 llm turns, got ${streamCalls}`);
    assert(html.includes('linear-gradient'), 'expected refactored html with gradient');
    assert(notes.includes('gradient applied'), 'expected notes.txt created');
    assert(!obsoleteExists, 'expected obsolete.txt deleted');
    assert(result.includes('concluido'), `expected final result concluido, got ${result}`);
    assert(assistantOutputs.some(m => m.includes('concluido')), 'expected final assistant output');

    const toolStartCount = emitted.filter(e => e.type === EventType.TOOL_START).length;
    const toolResultCount = emitted.filter(e => e.type === EventType.TOOL_RESULT).length;
    assert(toolStartCount === 3, `expected 3 TOOL_START events, got ${toolStartCount}`);
    assert(toolResultCount === 3, `expected 3 TOOL_RESULT events, got ${toolResultCount}`);

    const toolMessages = stateMessages.filter(m => m.role === 'tool');
    assert(toolMessages.length >= 3, `expected >=3 tool messages in state, got ${toolMessages.length}`);
  });
});

async function main(): Promise<void> {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (error: unknown) {
      failures++;
      const message = error instanceof Error ? error.message : String(error);
      console.log(`  ❌ ${name}`);
      console.log(`     ${message}`);
    }
  }

  console.log(`\nTool-loop IO sequence tests: ${passed}/${tests.length} passaram`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
