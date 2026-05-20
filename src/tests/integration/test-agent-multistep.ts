import { Agent } from '../../agent.js';
import { Message } from '../../types.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> | void }[] = [];

function test(name: string, fn: () => Promise<void> | void) {
  tests.push({ name, fn });
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

function toolArgs(tc: any): Record<string, any> {
  const raw = tc?.function?.arguments;
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch {}
  }
  return {};
}

// --- Agent real: test buildMessages after simulated tool calls ---
test('Agent.buildMessages inclui tool_calls do estado', async () => {
  const agent = new Agent();
  const state = (agent as any).state;

  // Simula Iteração 1: user request + assistant (com tool_calls) + tool results
  state.addMessage({ role: 'user', content: 'create portfolio with 2 files', timestamp: 1 });

  // Assistant responde com tool_calls
  state.addMessage({
    role: 'assistant',
    content: 'I will create index.html and styles.css',
    timestamp: 2,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'index.html', content: '<html></html>' } } },
      { function: { name: 'write_file', arguments: { path: 'styles.css', content: 'body {}' } } }
    ]
  });

  // Tool results
  state.addMessage({ role: 'tool', content: '[OK] Created: index.html', timestamp: 3 });
  state.addMessage({ role: 'tool', content: '[OK] Created: styles.css', timestamp: 4 });

  // Chama buildMessages para a próxima iteração
  const msgs: any[] = await (agent as any).buildMessages('create portfolio with 2 files');

  // System prompt + user + assistant(with tool_calls) + tool + tool
  assert(msgs.length >= 5, `should have at least 5 messages, got ${msgs.length}`);

  // Verifica estrutura
  assert(msgs[0].role === 'system', 'msg 0: system (prompt)');

  const userMsgs = msgs.filter((m: any) => m.role === 'user');
  assert(userMsgs.length >= 1, 'should have at least 1 user message');

  const assistantMsgs = msgs.filter((m: any) => m.role === 'assistant');
  assert(assistantMsgs.length >= 1, 'should have at least 1 assistant message');

  const assistantWithTools = assistantMsgs.find((m: any) => m.tool_calls && m.tool_calls.length > 0);
  assert(assistantWithTools !== undefined, 'assistant message should have tool_calls');
  assert(assistantWithTools.tool_calls.length === 2, 'should have 2 tool_calls');
  assert(assistantWithTools.tool_calls[0].function.name === 'write_file', 'first tool: write_file');
  assert(toolArgs(assistantWithTools.tool_calls[0]).path === 'index.html', 'first tool path ok');
  assert(assistantWithTools.tool_calls[1].function.name === 'write_file', 'second tool: write_file');

  const toolMsgs = msgs.filter((m: any) => m.role === 'tool');
  assert(toolMsgs.length >= 2, 'should have at least 2 tool result messages');
  assert(toolMsgs[0].content.includes('[OK]'), 'tool result should start with [OK]');
  assert(toolMsgs[0].role === 'tool', 'tool result role is tool');
});

// --- Simula 3 iterações completas ---
test('Agente mantem tool_calls apos 3 iteracoes de ferramentas', async () => {
  const agent = new Agent();
  const state = (agent as any).state;

  // --- Iteração 1: criar primeiros 2 arquivos ---
  state.addMessage({ role: 'user', content: 'create a react project with 4 files', timestamp: 1 });

  state.addMessage({
    role: 'assistant',
    content: 'Creating the project structure',
    timestamp: 2,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'package.json', content: '{}' } } },
      { function: { name: 'write_file', arguments: { path: 'index.html', content: '<html></html>' } } }
    ]
  });

  state.addMessage({ role: 'tool', content: '[OK] Created: package.json', timestamp: 3 });
  state.addMessage({ role: 'tool', content: '[OK] Created: index.html', timestamp: 4 });

  let msgs: any[] = await (agent as any).buildMessages('create a react project with 4 files');

  // Verifica Iteração 1 → 2: assistant com tool_calls está presente
  let asstWithTools = msgs.filter((m: any) => m.tool_calls && m.tool_calls.length > 0);
  assert(asstWithTools.length >= 1, `iter 1->2: should have assistant with tool_calls, got ${asstWithTools.length}`);

  let toolMsgs = msgs.filter((m: any) => m.role === 'tool');
  assert(toolMsgs.length >= 2, `iter 1->2: should have 2 tool results, got ${toolMsgs.length}`);

  // --- Iteração 2: criar mais 2 arquivos ---
  state.addMessage({
    role: 'assistant',
    content: 'Creating the React components',
    timestamp: 5,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'src/App.tsx', content: '// app' } } },
      { function: { name: 'write_file', arguments: { path: 'src/Counter.tsx', content: '// counter' } } }
    ]
  });

  state.addMessage({ role: 'tool', content: '[OK] Created: src/App.tsx', timestamp: 6 });
  state.addMessage({ role: 'tool', content: '[OK] Created: src/Counter.tsx', timestamp: 7 });

  msgs = await (agent as any).buildMessages('create a react project with 4 files');

  msgs = await (agent as any).buildMessages('create a react project with 4 files');

  // Verifica: assistant messages com tool_calls ainda presentes
  const allAsst = msgs.filter((m: any) => m.role === 'assistant');
  assert(allAsst.length >= 2, 'should have at least 2 assistant messages');

  // tool_calls das iterações anteriores ainda presentes
  const toolCallMsgs = msgs.filter((m: any) => m.tool_calls && m.tool_calls.length > 0);
  assert(toolCallMsgs.length >= 2, 'should still have previous tool_calls in context');
});

// --- Assistant com content vazio ainda propaga tool_calls ---
test('buildMessages preserva assistant message mesmo com content vazio', async () => {
  const agent = new Agent();
  const state = (agent as any).state;

  state.addMessage({ role: 'user', content: 'create file', timestamp: 1 });

  // Assistant com content='' + tool_calls (padrão Ollama native tool calling)
  state.addMessage({
    role: 'assistant',
    content: '',
    timestamp: 2,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'test.ts', content: '// ok' } } }
    ]
  });

  state.addMessage({ role: 'tool', content: '[OK] Created: test.ts', timestamp: 3 });

  const msgs: any[] = await (agent as any).buildMessages('create file');
  const asst = msgs.find((m: any) => m.role === 'assistant');
  assert(asst !== undefined, 'assistant message should exist');
  assert(asst.tool_calls !== undefined, 'assistant should have tool_calls even with empty content');
  assert(asst.tool_calls.length === 1, 'should have 1 tool_call');
  assert(asst.tool_calls[0].function.name === 'write_file', 'tool name preserved');
});

// --- Estado nao perde tool_calls quando tem muitas mensagens ---
test('Estado com muitas mensagens preserva tool_calls após limite', async () => {
  const agent = new Agent();
  const state = (agent as any).state;

  // Adiciona mensagens até passar do limite de 20
  for (let i = 0; i < 5; i++) {
    state.addMessage({ role: 'user', content: `query ${i}`, timestamp: i * 10 + 1 });
    state.addMessage({
      role: 'assistant',
      content: `response ${i}`,
      timestamp: i * 10 + 2,
      tool_calls: [
        { function: { name: 'write_file', arguments: { path: `file${i}.ts`, content: `// ${i}` } } }
      ]
    });
    state.addMessage({ role: 'tool', content: `[OK] Created: file${i}.ts`, timestamp: i * 10 + 3 });
  }

  const msgs: any[] = await (agent as any).buildMessages('query 4');

  // As tool_calls mais recentes devem estar preservadas
  const assistantMsgs = msgs.filter((m: any) => m.role === 'assistant' && m.tool_calls);
  assert(assistantMsgs.length >= 1, 'should have at least 1 assistant with tool_calls');

  // A última tool_call deve ser do último arquivo
  const lastAsst = assistantMsgs[assistantMsgs.length - 1];
  const lastPath = toolArgs(lastAsst.tool_calls[0]).path;
  assert(lastPath === 'file4.ts', `last file should be file4.ts, got ${lastPath}`);
});

// --- Simula fluxo com apply_patch apos write_file ---
test('buildMessages com write_file + apply_patch em sequencia', async () => {
  const agent = new Agent();
  const state = (agent as any).state;

  state.addMessage({ role: 'user', content: 'create and edit a file', timestamp: 1 });

  // Passo 1: write_file
  state.addMessage({
    role: 'assistant',
    content: 'Creating the file',
    timestamp: 2,
    tool_calls: [
      { function: { name: 'write_file', arguments: { path: 'app.ts', content: '// initial' } } }
    ]
  });
  state.addMessage({ role: 'tool', content: '[OK] Created: app.ts', timestamp: 3 });

  // Passo 2: apply_patch no mesmo arquivo
  state.addMessage({
    role: 'assistant',
    content: 'Editing the file to add more code',
    timestamp: 4,
    tool_calls: [
      { function: { name: 'apply_patch', arguments: { path: 'app.ts', operations: [{ search: '// initial', replace: '// updated\nconsole.log("ok")' }] } } }
    ]
  });
  state.addMessage({ role: 'tool', content: '[OK] Patch applied: app.ts', timestamp: 5 });

  const msgs: any[] = await (agent as any).buildMessages('create and edit a file');
  const withTools = msgs.filter((m: any) => m.tool_calls);

  assert(withTools.length >= 2, `should have 2 assistant tool_calls, got ${withTools.length}`);

  // write_file
  assert(withTools[0].tool_calls[0].function.name === 'write_file', 'first tool: write_file');
  assert(toolArgs(withTools[0].tool_calls[0]).path === 'app.ts', 'write_file path');

  // apply_patch
  assert(withTools[1].tool_calls[0].function.name === 'apply_patch', 'second tool: apply_patch');
  assert(toolArgs(withTools[1].tool_calls[0]).path === 'app.ts', 'apply_patch path');
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
