/**
 * test-toolcall-comprehensive.ts
 *
 * Teste definitivo do fluxo de tool calling do phenom-cli.
 *
 * Seção 1 — UNIT TESTS (LLM mockado, sem rede)
 *   Verifica a mecânica interna do Agent após o refator completo.
 *
 * Seção 2 — INTEGRATION TESTS (modelo real via Ollama)
 *   Ciclo completo: criar arquivo → refatorar → excluir →
 *                   criar projeto → refatorar → corrigir bug → excluir projeto.
 *
 * Execução: npx tsx src/test-toolcall-comprehensive.ts
 */

import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import { execFile as execFileCb } from 'child_process';
import { promisify } from 'util';
import { lookup as dnsLookup } from 'dns';
import { Agent } from './agent.js';
import { detectModelCapabilities } from './model-capabilities.js';
import { config } from './config.js';

const dnsLookupAsync = promisify(dnsLookup);

/** Resolve mDNS / .local hostnames via dns.lookup (honours nsswitch/Avahi). */
async function resolveHost(url: string): Promise<string> {
  try {
    const parsed = new URL(url);
    const hostname = parsed.hostname;
    if (hostname === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(hostname)) return url;
    const { address } = await dnsLookupAsync(hostname);
    parsed.hostname = address;
    return parsed.toString();
  } catch {
    return url;
  }
}

const execFile = promisify(execFileCb);

// ── Colours ──────────────────────────────────────────────────────────
const C = {
  reset: '\x1b[0m',
  bold:  '\x1b[1m',
  dim:   '\x1b[2m',
  green: '\x1b[32m',
  red:   '\x1b[31m',
  yellow:'\x1b[33m',
  cyan:  '\x1b[36m',
  blue:  '\x1b[34m',
  grey:  '\x1b[90m',
};
const ok    = (s: string) => `${C.green}✅ ${s}${C.reset}`;
const fail  = (s: string) => `${C.red}❌ ${s}${C.reset}`;
const info  = (s: string) => `${C.cyan}ℹ  ${s}${C.reset}`;
const warn  = (s: string) => `${C.yellow}⚠  ${s}${C.reset}`;
const step  = (s: string) => `\n${C.bold}${C.blue}▶ ${s}${C.reset}`;
const dim   = (s: string) => `${C.grey}${s}${C.reset}`;

// ── Helpers ───────────────────────────────────────────────────────────
function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(msg);
}

async function exists(p: string): Promise<boolean> {
  try { await fs.access(p); return true; } catch { return false; }
}

async function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  let t: NodeJS.Timeout;
  const timeout = new Promise<T>((_, rej) => {
    t = setTimeout(() => rej(new Error(`TIMEOUT (${ms}ms): ${label}`)), ms);
  });
  try { return await Promise.race([p, timeout]); }
  finally { clearTimeout(t!); }
}

function getMemory(agent: Agent): any[] {
  return (agent as any).state.getState().memory || [];
}

function toolCallsMade(agent: Agent): string[] {
  return getMemory(agent)
    .filter((m: any) => m.role === 'assistant' && Array.isArray(m.tool_calls))
    .flatMap((m: any) => (m.tool_calls || []).map((tc: any) => tc?.function?.name || '?'));
}

function lastAssistantText(agent: Agent): string {
  const msgs = getMemory(agent).filter((m: any) => m.role === 'assistant' && m.content);
  return msgs.length ? String(msgs[msgs.length - 1].content || '') : '';
}

function toolMessages(agent: Agent): string[] {
  return getMemory(agent)
    .filter((m: any) => m.role === 'tool')
    .map((m: any) => String(m.content || '').slice(0, 200));
}

// ── Counters ─────────────────────────────────────────────────────────
let unitPassed = 0, unitFailed = 0;
let intPassed  = 0, intFailed  = 0;
const failures: string[] = [];

async function runUnit(name: string, fn: () => Promise<void>): Promise<void> {
  const t0 = Date.now();
  try {
    await fn();
    unitPassed++;
    console.log(`  ${ok(name)} ${dim(`(${Date.now() - t0}ms)`)}`);
  } catch (e: any) {
    unitFailed++;
    failures.push(`[UNIT] ${name}: ${e.message}`);
    console.log(`  ${fail(name)}`);
    console.log(`    ${C.red}${e.message}${C.reset}`);
  }
}

async function runInt(name: string, fn: () => Promise<void>, timeoutMs = 120_000): Promise<void> {
  const t0 = Date.now();
  try {
    await withTimeout(fn(), timeoutMs, name);
    intPassed++;
    console.log(`  ${ok(name)} ${dim(`(${Math.round((Date.now() - t0) / 1000)}s)`)}`);
  } catch (e: any) {
    intFailed++;
    failures.push(`[INT] ${name}: ${e.message}`);
    console.log(`  ${fail(name)}`);
    console.log(`    ${C.red}${e.message}${C.reset}`);
  }
}

// ════════════════════════════════════════════════════════════════════
// SEÇÃO 1 — UNIT TESTS
// ════════════════════════════════════════════════════════════════════

async function runUnitTests(): Promise<void> {
  console.log(step('UNIT TESTS — mecânica interna (LLM mockado)'));

  // ── U1: JSON fallback — model retorna JSON de tool call no texto ──
  await runUnit('U1: JSON fallback executa tool e retorna final', async () => {
    const agent: any = new Agent();
    let calls = 0;
    const executed: string[] = [];

    agent.llm = {
      chatStream: async (_msgs: any, onChunk: any) => {
        calls++;
        if (calls === 1)
          onChunk('{"type":"tool","toolName":"list_dir","args":{"path":"."}}');
        else
          onChunk('{"type":"final","content":"listagem concluida"}');
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    agent.executeToolWithEvents = async (name: string) => {
      executed.push(name);
      return { success: true, output: 'file1.ts\nfile2.ts', error: null };
    };

    const result = await agent.runToolLoop('liste o diretório');
    assert(executed.includes('list_dir'), `list_dir não foi executado, got: ${executed}`);
    assert(result.includes('listagem'), `resultado esperado, got: ${result}`);
  });

  // ── U2: Native tool call — onToolCall dispara, tool executa ──────
  await runUnit('U2: Native tool call — onToolCall → executar → final', async () => {
    const agent: any = new Agent();
    let calls = 0;
    const executed: Array<{ tool: string; args: any }> = [];

    agent.llm = {
      chatStream: async (_msgs: any, onChunk: any, onToolCall: any) => {
        calls++;
        if (calls === 1) {
          onToolCall('write_file', { path: 'native-test.txt', content: 'hello' }, 'call_native_001');
        } else {
          onChunk('Arquivo criado com sucesso.');
        }
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    agent.executeToolWithEvents = async (name: string, args: any) => {
      executed.push({ tool: name, args });
      return { success: true, output: 'Created: native-test.txt', error: null };
    };

    const result = await agent.runToolLoop('crie native-test.txt');
    assert(executed.some(e => e.tool === 'write_file'), `write_file não executado`);
    assert(executed.some(e => e.args.path === 'native-test.txt'), `path errado`);
    assert(result.includes('criado'), `resultado inesperado: ${result}`);
  });

  // ── U3: tool_call_id preservado — assistant.tool_calls[i].id === tool.tool_call_id ──
  await runUnit('U3: tool_call_id é emparelhado corretamente', async () => {
    const agent: any = new Agent();
    let calls = 0;

    agent.llm = {
      chatStream: async (_msgs: any, onChunk: any, onToolCall: any) => {
        calls++;
        if (calls === 1)
          onToolCall('read_file', { path: 'x.ts' }, 'call_id_xyz');
        else
          onChunk('lido.');
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    agent.executeToolWithEvents = async () => ({ success: true, output: 'content', error: null });

    await agent.runToolLoop('leia x.ts');
    const mem = getMemory(agent);
    const assistantWithCalls = mem.find((m: any) =>
      m.role === 'assistant' && m.tool_calls?.some((tc: any) => tc.id === 'call_id_xyz')
    );
    const toolMsg = mem.find((m: any) => m.role === 'tool' && m.tool_call_id === 'call_id_xyz');
    assert(!!assistantWithCalls, 'assistant message com tool_call_id call_id_xyz não encontrada');
    assert(!!toolMsg, 'tool message com tool_call_id call_id_xyz não encontrada');
  });

  // ── U4: Native path usa role:'tool'; JSON fallback usa role:'user' ─
  await runUnit('U4: Native usa role:tool; JSON fallback usa role:user (janela ativa)', async () => {
    // Native path: ferramentas enviadas pelo onToolCall
    const agentNative: any = new Agent();
    (agentNative as any).modelCapabilities = { ...detectModelCapabilities('qwen2.5-coder:7b'), supportsNativeTools: true };
    const nativeWindow: any[][] = [];

    let ncalls = 0;
    agentNative.llm = {
      chatStream: async (msgs: any[], onChunk: any, onToolCall: any) => {
        nativeWindow.push(msgs.map(m => ({ role: m.role, hasToolCalls: !!m.tool_calls?.length, hasTcId: !!m.tool_call_id })));
        ncalls++;
        if (ncalls === 1) onToolCall('date', {}, 'call_nat');
        else onChunk('done native');
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    agentNative.executeToolWithEvents = async () => ({ success: true, output: '2026', error: null });
    await agentNative.runToolLoop('data atual');

    // After iteration 1, the active window should contain a role:'tool' message
    const lastWindow = nativeWindow[nativeWindow.length - 1] || [];
    const hasToolRole = lastWindow.some((m: any) => m.hasTcId);
    assert(hasToolRole, `Native path: esperava role:tool na janela, got: ${JSON.stringify(lastWindow)}`);

    // JSON fallback path
    const agentJson: any = new Agent();
    (agentJson as any).modelCapabilities = { ...detectModelCapabilities('qwen2.5-coder:7b'), supportsNativeTools: false };
    const jsonWindow: any[][] = [];

    let jcalls = 0;
    agentJson.llm = {
      chatStream: async (msgs: any[], onChunk: any) => {
        jsonWindow.push(msgs.map(m => ({ role: m.role })));
        jcalls++;
        if (jcalls === 1)
          onChunk('{"type":"tool","toolName":"date","args":{}}');
        else
          onChunk('{"type":"final","content":"data ok"}');
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    agentJson.executeToolWithEvents = async () => ({ success: true, output: '2026', error: null });
    await agentJson.runToolLoop('data atual');

    const jsonLastWindow = jsonWindow[jsonWindow.length - 1] || [];
    const hasUserRole = jsonLastWindow.some((m: any) => m.role === 'user');
    assert(hasUserRole, `JSON fallback: esperava role:user injetado na janela, got: ${JSON.stringify(jsonLastWindow)}`);
  });

  // ── U5: Contador de falhas — 3 iterações all-fail → para ─────────
  await runUnit('U5: consecutiveAllFailures >= 3 para o loop', async () => {
    const agent: any = new Agent();
    let calls = 0;

    agent.llm = {
      chatStream: async (_msgs: any, onChunk: any, onToolCall: any) => {
        calls++;
        onToolCall('read_file', { path: 'none.txt' }, `call_${calls}`);
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    // Sempre falha
    agent.executeToolWithEvents = async () => ({ success: false, output: '', error: 'file not found' });

    const result = await agent.runToolLoop('leia none.txt');
    assert(result.includes('failed') || result.includes('falh'), `esperava mensagem de stop, got: ${result}`);
    assert(calls <= 4, `esperava parar em ≤4 iterações, rodou ${calls}`);
  });

  // ── U6: buildInitialMessages — query sempre presente ────────────
  await runUnit('U6: buildInitialMessages inclui sempre a query atual', async () => {
    const agent: any = new Agent();
    const messages = await agent.buildInitialMessages('test query xyz');
    const userMsgs = messages.filter((m: any) => m.role === 'user');
    assert(userMsgs.some((m: any) => m.content === 'test query xyz'),
      `query não encontrada em messages: ${JSON.stringify(userMsgs.map((m: any) => m.content))}`);
  });

  // ── U7: supportsNativeTools=false → chatStream recebe toolDefs=undefined ──
  await runUnit('U7: modelo sem native tools não recebe toolDefs', async () => {
    const agent: any = new Agent();
    agent.modelCapabilities = { ...detectModelCapabilities('codellama:7b'), supportsNativeTools: false };
    let receivedTools: any = 'NOT_CHECKED';

    agent.llm = {
      chatStream: async (_msgs: any, _onChunk: any, _onToolCall: any, tools: any) => {
        receivedTools = tools;
        return '';
      },
      chat: async () => ({ message: { content: 'no' } }),
    };
    agent.executeToolWithEvents = async () => ({ success: true, output: '', error: null });

    await agent.runToolLoop('hello');
    assert(receivedTools === undefined, `esperava undefined tools, got: ${JSON.stringify(receivedTools)}`);
  });

  // ── U8: formatToolResultForModel — sem prefixo [TOOL] ────────────
  await runUnit('U8: formatToolResultForModel não inclui prefixo [TOOL]', async () => {
    const agent: any = new Agent();
    const result = agent.formatToolResultForModel('read_file', { success: true, output: 'file content here', error: null });
    assert(!result.startsWith('[TOOL]'), `resultado ainda tem prefixo [TOOL]: ${result}`);
    assert(result === 'file content here', `resultado inesperado: ${result}`);

    const errResult = agent.formatToolResultForModel('read_file', { success: false, output: '', error: 'not found' });
    assert(errResult.includes('Error') && errResult.includes('not found'), `erro inesperado: ${errResult}`);
    assert(!errResult.startsWith('[TOOL]'), `erro ainda tem [TOOL]: ${errResult}`);
  });

  console.log(info(`Unit: ${unitPassed} passed, ${unitFailed} failed`));
}

// ════════════════════════════════════════════════════════════════════
// SEÇÃO 2 — INTEGRATION TESTS (modelo real)
// ════════════════════════════════════════════════════════════════════

/**
 * Executa agent.processInput com log em tempo real via eventBus.
 * Sem isso o teste fica mudo — todo output do agente vai pelo eventBus.
 *
 * Notas sobre EventBus:
 *  - eventBus.on(type, handler) retorna uma função unsubscribe()
 *  - handler recebe Event { type, payload, timestamp }; payload é o segundo arg de emit()
 */
async function runAgent(agent: Agent, input: string, testLabel: string): Promise<void> {
  const { eventBus, EventType } = await import('./tui/event-bus.js');

  let lastToolName = '';
  let tokenTotal = 0;
  let iterCount = 0;

  // Heartbeat: prova que o processo está vivo durante inferência longa
  const heartbeat = setInterval(() => {
    const status = lastToolName ? `tool: ${lastToolName}` : 'inferindo...';
    process.stdout.write(`\r    ${C.dim}[${testLabel}] ${status} | ${iterCount} iter | ${tokenTotal} tokens${C.reset}     `);
  }, 3000);

  const unsubs: Array<() => void> = [];

  unsubs.push(eventBus.on(EventType.PROGRESS_UPDATE, (e: any) => {
    const msg = e?.payload?.message;
    if (msg) iterCount++;
  }));

  unsubs.push(eventBus.on(EventType.TOOL_START, (e: any) => {
    lastToolName = String(e?.payload?.name || '');
    process.stdout.write(`\r    ${C.cyan}→ ${lastToolName}${C.reset}                              \n`);
  }));

  unsubs.push(eventBus.on(EventType.TOOL_RESULT, (e: any) => {
    const ok = e?.payload?.result?.success;
    process.stdout.write(`    ${ok ? C.green + '✓' : C.red + '✗'} ${lastToolName}: ${ok ? 'ok' : 'fail'}${C.reset}\n`);
    lastToolName = '';
  }));

  unsubs.push(eventBus.on(EventType.TOOL_ERROR, (e: any) => {
    process.stdout.write(`    ${C.red}✗ ${e?.payload?.toolName || '?'}: ${e?.payload?.error || ''}${C.reset}\n`);
    lastToolName = '';
  }));

  unsubs.push(eventBus.on(EventType.TOKEN_UPDATE, (e: any) => {
    if (typeof e?.payload?.total === 'number') tokenTotal = e.payload.total;
  }));

  unsubs.push(eventBus.on(EventType.AGENT_MESSAGE, (e: any) => {
    const txt = String(e?.payload?.content || '').slice(0, 140).replace(/\n/g, ' ');
    if (txt) process.stdout.write(`    ${C.grey}» ${txt}${C.reset}\n`);
  }));

  unsubs.push(eventBus.on(EventType.MESSAGE_CHUNK, (e: any) => {
    if (e?.payload?.chunk) process.stdout.write(C.dim + e.payload.chunk + C.reset);
  }));

  unsubs.push(eventBus.on(EventType.REASONING_CHUNK, (e: any) => {
    if (e?.payload?.chunk) process.stdout.write(C.yellow + e.payload.chunk + C.reset);
  }));

  try {
    await agent.processInput(input);
    process.stdout.write('\n');
  } finally {
    clearInterval(heartbeat);
    unsubs.forEach(u => u());
  }
}

async function runIntegrationTests(): Promise<void> {
  const modelName = config.ollama.coderModel || config.ollama.model || 'unknown';
  const caps = detectModelCapabilities(modelName);
  const host = config.ollama.host || 'http://127.0.0.1:11434';

  console.log(step('INTEGRATION TESTS — modelo real'));
  console.log(info(`Modelo: ${modelName}`));
  console.log(info(`Host:   ${host}`));
  console.log(info(`Native tools: ${caps.supportsNativeTools}`));

  // ── I0: Conectividade ────────────────────────────────────────────
  await runInt('I0: Ollama acessível', async () => {
    const resolvedHost = await resolveHost(host);
    const res = await fetch(`${resolvedHost}/api/tags`);
    assert(res.ok, `Ollama retornou ${res.status}`);
    const json: any = await res.json();
    const names = (json.models || []).map((m: any) => m.name);
    const found = names.some((n: string) => n === modelName || n.startsWith(modelName.split(':')[0]));
    assert(found, `Modelo '${modelName}' não encontrado. Disponíveis: ${names.slice(0, 5).join(', ')}`);
  }, 10_000);

  // Workspace isolado
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-inttest-'));
  const origCwd = process.cwd();
  process.chdir(tmpDir);
  console.log(dim(`  Workspace: ${tmpDir}`));

  const STEP_TIMEOUT = 300_000; // 5 min por step — modelo 9b pode ser lento

  try {
    const agent = new Agent();
    agent.setMode('code_assistant');
    agent.setStreamEnabled(true); // stream=true para ver tokens em tempo real
    await agent.initialize();

    // ── I1: Criar arquivo ────────────────────────────────────────
    await runInt('I1: Criar hello.js com função greet()', async () => {
      console.log(dim(`    prompt → criação de arquivo`));
      await runAgent(agent,
        'Crie o arquivo hello.js no diretório atual com uma função greet(name) que retorna "Hello, " + name. ' +
        'Use write_file ou create_file.',
        'I1'
      );
      const filePath = path.join(tmpDir, 'hello.js');
      assert(await exists(filePath), `hello.js não criado. Calls: ${toolCallsMade(agent).join(',')}`);
      const content = await fs.readFile(filePath, 'utf-8');
      assert(content.includes('greet'), `função greet ausente:\n${content}`);
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I2: Refatorar arquivo ────────────────────────────────────
    await runInt('I2: Refatorar hello.js — export + JSDoc', async () => {
      console.log(dim(`    prompt → refatoração`));
      await runAgent(agent,
        'Leia hello.js, adicione JSDoc à função greet e adicione "module.exports = { greet };" no final. ' +
        'Use read_file primeiro, depois apply_patch ou write_file.',
        'I2'
      );
      const content = await fs.readFile(path.join(tmpDir, 'hello.js'), 'utf-8');
      assert(
        content.includes('module.exports') || content.includes('export'),
        `export ausente após refatoração:\n${content.slice(0, 300)}`
      );
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I3: Excluir arquivo ──────────────────────────────────────
    await runInt('I3: Excluir hello.js com delete_file', async () => {
      console.log(dim(`    prompt → delete_file`));
      await runAgent(agent, 'Exclua o arquivo hello.js usando delete_file.', 'I3');
      assert(!await exists(path.join(tmpDir, 'hello.js')), `hello.js ainda existe após delete`);
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I4: Criar projeto ────────────────────────────────────────
    await runInt('I4: Criar projeto simple_calc/ com 3 arquivos', async () => {
      console.log(dim(`    prompt → criar 3 arquivos`));
      await runAgent(agent,
        'Crie um projeto "simple_calc" com:\n' +
        '1. simple_calc/math.js — funções add(a,b) e subtract(a,b)\n' +
        '2. simple_calc/index.js — importa math.js e imprime add(5,3) e subtract(10,4)\n' +
        '3. simple_calc/README.md — descrição de uma linha\n' +
        'Use create_file ou write_file para cada arquivo.',
        'I4'
      );
      const calcDir = path.join(tmpDir, 'simple_calc');
      assert(await exists(path.join(calcDir, 'math.js')),   'math.js ausente');
      assert(await exists(path.join(calcDir, 'index.js')), 'index.js ausente');
      assert(await exists(path.join(calcDir, 'README.md')), 'README.md ausente');
      const mathContent = await fs.readFile(path.join(calcDir, 'math.js'), 'utf-8');
      assert(mathContent.includes('add') && mathContent.includes('subtract'), `math.js incompleto`);
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I5: Adicionar função ─────────────────────────────────────
    await runInt('I5: Adicionar multiply() em simple_calc/math.js', async () => {
      console.log(dim(`    prompt → adicionar função`));
      await runAgent(agent,
        'Leia simple_calc/math.js e adicione a função multiply(a,b) = a*b. ' +
        'Use apply_patch ou write_file.',
        'I5'
      );
      const content = await fs.readFile(path.join(tmpDir, 'simple_calc', 'math.js'), 'utf-8');
      assert(content.includes('multiply'), `multiply ausente em math.js`);
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I6: Corrigir bug ─────────────────────────────────────────
    await runInt('I6: Corrigir bug divide(a,b) retorna a*b → a/b', async () => {
      const bugPath = path.join(tmpDir, 'simple_calc', 'math.js');
      let cur = await fs.readFile(bugPath, 'utf-8');
      cur += '\nfunction divide(a,b){ return a * b; }\nmodule.exports = { add, subtract, multiply, divide };\n';
      await fs.writeFile(bugPath, cur, 'utf-8');
      console.log(dim(`    bug injetado → solicitando correção`));
      await runAgent(agent,
        'Há um bug em simple_calc/math.js: divide(a,b) retorna a * b mas deveria retornar a / b. ' +
        'Leia o arquivo e corrija com apply_patch.',
        'I6'
      );
      const fixed = await fs.readFile(bugPath, 'utf-8');
      assert(fixed.includes('a / b') || fixed.includes('a/b'), `bug não corrigido:\n${fixed}`);
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I7: Excluir projeto ──────────────────────────────────────
    await runInt('I7: Excluir simple_calc/ com delete_dir', async () => {
      console.log(dim(`    prompt → delete_dir`));
      await runAgent(agent, 'Exclua o diretório simple_calc/ recursivamente com delete_dir.', 'I7');
      assert(!await exists(path.join(tmpDir, 'simple_calc')), `simple_calc/ ainda existe`);
      console.log(dim(`    Tool calls: [${toolCallsMade(agent).join(', ')}]`));
    }, STEP_TIMEOUT);

    // ── I8: Multi-step ───────────────────────────────────────────
    await runInt('I8: Multi-step — criar test_add.js, executar, verificar saída', async () => {
      console.log(dim(`    prompt → multi-step`));
      await runAgent(agent,
        'Faça 3 passos:\n' +
        '1. Crie test_add.js com: console.log(2 + 3);\n' +
        '2. Execute com run_code: "node test_add.js"\n' +
        '3. Diga o resultado\n' +
        'Use create_file e run_code.',
        'I8'
      );
      const allCalls = toolCallsMade(agent);
      assert(
        allCalls.includes('create_file') || allCalls.includes('write_file'),
        `create_file/write_file não chamado`
      );
      assert(allCalls.includes('run_code'), `run_code não chamado`);
      const msgs = toolMessages(agent);
      assert(msgs.some(t => t.includes('5')), `saída 5 ausente: ${msgs.slice(-3).join(' | ')}`);
      console.log(dim(`    Tool calls: [${allCalls.join(', ')}]`));
    }, STEP_TIMEOUT);

  } finally {
    process.chdir(origCwd);
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}
  }

  console.log(info(`Integration: ${intPassed} passed, ${intFailed} failed`));
}

// ════════════════════════════════════════════════════════════════════
// DIAGNÓSTICO — exibe detalhes de falhas
// ════════════════════════════════════════════════════════════════════

function printDiagnostics(): void {
  if (failures.length === 0) return;
  console.log(`\n${C.bold}${C.red}═══ FALHAS ═══${C.reset}`);
  for (const f of failures) {
    console.log(`  ${C.red}•${C.reset} ${f}`);
  }
}

// ════════════════════════════════════════════════════════════════════
// MAIN
// ════════════════════════════════════════════════════════════════════

async function main(): Promise<void> {
  const t0 = Date.now();
  console.log(`\n${C.bold}${C.cyan}phenom-cli — Teste Definitivo de Tool Calling${C.reset}`);
  console.log(dim(`${'─'.repeat(55)}`));

  await runUnitTests();
  await runIntegrationTests();

  const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
  const totalPassed = unitPassed + intPassed;
  const totalFailed = unitFailed + intFailed;
  const total = totalPassed + totalFailed;

  console.log(`\n${C.bold}${'═'.repeat(55)}${C.reset}`);
  console.log(`${C.bold}RESULTADO: ${totalPassed}/${total} passaram em ${elapsed}s${C.reset}`);
  console.log(`  Unit:        ${unitPassed}/${unitPassed + unitFailed}`);
  console.log(`  Integration: ${intPassed}/${intPassed + intFailed}`);

  printDiagnostics();

  if (totalFailed === 0) {
    console.log(`\n${C.bold}${C.green}✅ TODOS OS TESTES PASSARAM — Tool calling operacional${C.reset}\n`);
  } else {
    console.log(`\n${C.bold}${C.red}❌ ${totalFailed} TESTE(S) FALHARAM${C.reset}\n`);
  }

  process.exit(totalFailed === 0 ? 0 : 1);
}

main().catch(e => {
  console.error('\n' + fail('Erro fatal no runner:'), e?.message || e);
  process.exit(1);
});
