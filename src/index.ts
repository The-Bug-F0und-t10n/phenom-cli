#!/usr/bin/env node

import { Command } from 'commander';
import { promises as fs } from 'fs';
import path from 'path';
import chalk from 'chalk';
import { Agent } from './agent.js';
import { config } from './config.js';
import { CliRenderer } from './cli-renderer.js';
import { eventBus, EventType } from './tui/event-bus.js';
import { TtsOrchestrator } from './tts/index.js';
import { TraceLogger } from './trace-logger.js';
import type { AgentState } from './types.js';

const IMAGE_MIME_BY_EXT: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
};

const normalizeMode = (raw: string | undefined): AgentState['mode'] => {
  if (raw === 'fast' || raw === 'reasoning' || raw === 'assistant' || raw === 'plan' || raw === 'code_assistant' || raw === 'jarvis') {
    return raw;
  }
  return 'code_assistant';
};

const program = new Command();

program
  .name('phenom')
  .description('Agente local para coding e debug')
  .version('1.1.0');

program
  .command('chat')
  .description('Inicia sessao interativa de chat')
  .option('-m, --mode <mode>', 'Modo de operacao (fast|reasoning|assistant|plan|code_assistant|jarvis)', 'code_assistant')
  .option('-s, --session <hash>', 'Restaura sessao especifica pelo hash')
  .option('--stream', 'Ativa streaming de resposta em tempo real')
  .option('-p, --prompt <text>', 'Envia prompt e encerra (modo pipe)')
  .option('-i, --image <path-or-url>', 'Anexa imagem (vision) para o prompt atual')
  .action(async (options) => {
    const agent = new Agent();
    const renderer = new CliRenderer();
    renderer.attach();

    // Trace logger — appends JSONL to .phenom-trace.log so the user can see
    // what the agent did when it hangs. Disable with PHENOM_TRACE=0.
    const trace = new TraceLogger();
    trace.start();

    agent.setMode(normalizeMode(options.mode));
    if (options.stream) {
      agent.setStreamEnabled(true);
    }

    // Session selection strategy:
    //   1) --session <hash> explicit resume target
    //   2) fallback to most recent session
    let lastSessionId: string | undefined;
    const explicitSessionId = String(options.session || '').trim() || undefined;
    if (explicitSessionId && !/^[a-f0-9]{16}$/i.test(explicitSessionId)) {
      console.log(chalk.red(`Session hash invalido: ${explicitSessionId}. Esperado: 16 chars hex.`));
      process.exit(1);
    }
    try {
      lastSessionId = await agent.getMostRecentSessionId();
    } catch {}

    try {
      const targetSessionId = explicitSessionId || lastSessionId;
      await agent.initialize(targetSessionId);
      const sid = agent.getSessionId();
      if (targetSessionId && sid === targetSessionId) {
        console.log(chalk.cyan(`Session restored (hash: ${sid})`));
      } else if (explicitSessionId && sid !== explicitSessionId) {
        console.log(chalk.yellow(`Session ${explicitSessionId} nao encontrada. Nova sessao iniciada (hash: ${sid}).`));
      } else {
        console.log(chalk.cyan(`New session (hash: ${sid})`));
      }

      // USER-facing notice: if the restored brain has pending plan steps,
      // tell the user once. The model NEVER sees this — pending tasks are
      // not auto-injected into the system prompt anymore. The user can
      // address the pending work explicitly if they want; otherwise they
      // start fresh and the model has zero awareness of past tasks.
      const brain = agent.getBrain?.();
      const pending = brain?.getPlanSteps?.()
        .filter((s: { status?: string }) => s.status === 'pending' || s.status === 'in_progress') ?? [];
      if (pending.length > 0) {
        console.log(chalk.yellow(
          `(${pending.length} task(s) pendente(s) da sessao anterior. ` +
          `Pra continuar, peca ao modelo "lista tasks pendentes" ou descreva a task. ` +
          `Pra ignorar, prossiga normalmente.)`
        ));
      }

      if (targetSessionId && sid === targetSessionId) {
        const restored = agent.getConversationMessages()
          .filter((m) => (m.role === 'user' || m.role === 'assistant') && String(m.content || '').trim().length > 0);
        if (restored.length > 0) {
          console.log(chalk.dim(`Restored chat messages: ${restored.length}`));
          // Stored assistant content carries <think>…</think> verbatim (kept
          // intact so the server's KV cache matches across turns). When we
          // replay history to the renderer, split those tags out so thinking
          // gets the styled component and the answer area stays clean — same
          // shape the live stream produces via api-client's splitThink.
          const splitThinkFromContent = (raw: string): { reasoning: string; content: string } => {
            const m = /^([\s\S]*?)<think>([\s\S]*?)<\/think>([\s\S]*)$/.exec(raw);
            if (!m) return { reasoning: '', content: raw };
            return { reasoning: m[2].trim(), content: (m[1] + m[3]).trim() };
          };
          for (const msg of restored) {
            if (msg.role === 'user') {
              eventBus.emit(EventType.USER_MESSAGE, { content: msg.content });
            } else {
              const { reasoning, content } = splitThinkFromContent(String(msg.content || ''));
              if (reasoning) eventBus.emit(EventType.REASONING_CHUNK, { chunk: reasoning });
              // Prefer the user-visible form recorded at turn time. Without
              // this, turns where the model emitted only `<think>…</think>` +
              // a tool call (so splitThink yields empty `content`) produced
              // no AGENT_MESSAGE on restore — the user lost the
              // reasoning-fallback answer or "Using: tool_x" hint they saw
              // live. Falls back to splitThink content for sessions written
              // before displayContent existed.
              const visible = ((msg as { displayContent?: string }).displayContent || '').trim() || content;
              if (visible) eventBus.emit(EventType.AGENT_MESSAGE, { content: visible });
            }
          }
        }
      }
    } catch (error: unknown) {
      console.log('Erro ao iniciar sessao:', getErrorMessage(error));
      process.exit(1);
    }

    // ── Pipe mode (non-interactive) ─────────────────────────────────
    if (!process.stdin.isTTY || options.prompt) {
      const text = options.prompt || await readAllStdin();
      if (text) {
        eventBus.emit(EventType.USER_MESSAGE, { content: text });
        const imageInput = String(options.image || '').trim();
        if (imageInput) {
          const imageUrl = await resolveImageInputToUrl(imageInput);
          await agent.processInputWithContent(text, [
            { type: 'text', text },
            { type: 'image_url', image_url: { url: imageUrl } }
          ]);
        } else {
          await agent.processInput(text);
        }
      }
      // Pipe-mode cleanup mirroring onClose() in interactive mode: tear down
      // the trace stream and detach the renderer, then exit explicitly. Without
      // the explicit exit, pending FS close ops on the trace WriteStream keep
      // the event loop alive for ~60s before Node times them out — the
      // interactive mode handles this the same way (process.exit(0) in onClose).
      try { trace.stop(); } catch {}
      try { renderer.detach(); } catch {}
      process.exit(0);
    }

    // ── Interactive mode ────────────────────────────────────────────
    // The renderer now owns input handling end-to-end (raw stdin, bracketed
    // paste, multi-line buffer, history navigation). readline.Interface is
    // not used anymore — we just load/save the history file ourselves.

    // TTS: speaks a SHORT conversational narration of the model's final
    // reply via the Piper service on inference.local. NOT the full
    // response — the narrator callback condenses it to a single spoken
    // sentence ("terminei, encontrei o bug em X"). Off by default;
    // toggle live via /tts.
    const tts = new TtsOrchestrator({
      endpoint: config.tts.endpoint,
      requestTimeoutMs: config.tts.requestTimeoutMs,
      enabledByDefault: config.tts.enabled,
      narrate: (full, query) => agent.narrateForVoice(full, query)
    });
    tts.start();

    const historyPath = path.join(process.cwd(), '.phenom-history');
    let savedHistory: string[] = [];
    try {
      const raw = await fs.readFile(historyPath, 'utf-8');
      savedHistory = raw.split('\n').filter(Boolean).reverse();
    } catch {}

    let processing = false;
    let closing = false;

    const onLine = async (line: string): Promise<void> => {
      const input = line.trim();
      if (!input) {
        renderer.renderPrompt();
        return;
      }
      processing = true;
      eventBus.emit(EventType.USER_MESSAGE, { content: input });

      if (input.startsWith('/')) {
        await handleCommand(input, agent, tts);
        renderer.renderPrompt();
        processing = false;
        return;
      }
      try {
        await agent.processInput(input);
      } catch (error: unknown) {
        console.log('[error]', getErrorMessage(error));
      }
      renderer.renderPrompt();
      processing = false;
    };

    const onClose = async (): Promise<void> => {
      if (closing) return;
      closing = true;
      while (processing) {
        await new Promise(r => setTimeout(r, 100));
      }
      try {
        const dir = path.dirname(historyPath);
        await fs.mkdir(dir, { recursive: true });
        const historyLines = renderer.getInputHistory().filter((l: string) => l);
        const history = historyLines.reverse().join('\n');
        await fs.writeFile(historyPath, history, 'utf-8');
      } catch {}
      await tts.stop();
      trace.stop();
      renderer.detach();
      console.log('Session saved. Use phenom chat to continue.');
      process.exit(0);
    };

    // Best-effort save invoked from uncaughtException so context survives a
    // crash. Mirrors onClose without exiting (the handler does that).
    const onFatalError = async (): Promise<void> => {
      try {
        const dir = path.dirname(historyPath);
        await fs.mkdir(dir, { recursive: true });
        const historyLines = renderer.getInputHistory().filter((l: string) => l);
        await fs.writeFile(historyPath, historyLines.reverse().join('\n'), 'utf-8');
      } catch {}
      try { trace.stop(); } catch {}
    };

    renderer.bindInput({
      onLine: (line) => { void onLine(line); },
      onClose: () => { void onClose(); },
      onFatalError,
      history: savedHistory.slice(0, 100),
    });

    renderer.renderPrompt();
  });

program
  .command('run')
  .description('Executa comando unico sem modo interativo')
  .argument('<query>', 'Comando a executar')
  .option('-m, --mode <mode>', 'Modo de operacao (fast|reasoning|assistant|plan|code_assistant|jarvis)', 'code_assistant')
  .option('--stream', 'Ativa streaming de resposta em tempo real')
  .option('-i, --image <path-or-url>', 'Anexa imagem (vision) para o prompt atual')
  .action(async (query, options) => {
    const agent = new Agent();
    const renderer = new CliRenderer();
    renderer.attach();

    // Trace logger — appends JSONL to .phenom-trace.log so the user can see
    // what the agent did when it hangs. Disable with PHENOM_TRACE=0.
    const trace = new TraceLogger();
    trace.start();

    agent.setMode(normalizeMode(options.mode));
    if (options.stream) agent.setStreamEnabled(true);

    try {
      await agent.initialize();
      const text = String(query || '');
      eventBus.emit(EventType.USER_MESSAGE, { content: text });
      const imageInput = String(options.image || '').trim();
      if (imageInput) {
        const imageUrl = await resolveImageInputToUrl(imageInput);
        await agent.processInputWithContent(text, [
          { type: 'text', text },
          { type: 'image_url', image_url: { url: imageUrl } }
        ]);
      } else {
        await agent.processInput(query);
      }
    } catch (error: unknown) {
      console.log('[error]', getErrorMessage(error));
      process.exit(1);
    }
  });

program
  .command('config')
  .description('Mostra configuracao atual')
  .action(() => {
    console.log('Ollama:');
    console.log('  Host:', config.ollama.host);
    console.log('  Chat Model:', config.ollama.chatModel);
    console.log('  Coder Model:', config.ollama.coderModel);
    console.log('  GPU Layers:', config.ollama.options.num_gpu);
    console.log('  Context Max:', config.ollama.options.num_ctx);
    console.log('  Context Min:', config.ollama.adaptiveContext.minCtx);
    console.log('  Adaptive Context:', config.ollama.adaptiveContext.enabled);
    console.log('  Keep Alive:', config.ollama.keepAlive);
    console.log('Sistema:');
    console.log('  Mode:', config.system.mode);
    console.log('  Max History:', config.system.maxHistory);
    console.log('  Stream:', config.chat.stream);
  });

async function handleCommand(command: string, agent: Agent, tts: TtsOrchestrator): Promise<void> {
  const parts = command.split(' ');
  const cmd = parts[0];

  switch (cmd) {
    case '/exit':
      // Defer to the renderer's onClose path via Ctrl+D-style shutdown:
      // emit a signal the input loop watches. Simpler: just exit here —
      // the alt-screen cleanup hooks in CliRenderer fire on process exit.
      process.exit(0);
      break;
    case '/mode':
      if (parts[1] === 'fast' || parts[1] === 'reasoning' || parts[1] === 'assistant' || parts[1] === 'plan' || parts[1] === 'code_assistant' || parts[1] === 'jarvis') {
        agent.setMode(parts[1]);
      } else {
        console.log('Invalid mode. Use: fast, reasoning, assistant, plan, code_assistant, jarvis');
      }
      break;
    case '/reset':
      agent.reset();
      console.log('State reset.');
      break;
    case '/tts': {
      // Forms: /tts          → toggle  /tts on  /tts off
      const arg = (parts[1] || '').toLowerCase();
      const next = arg === 'on' ? true : arg === 'off' ? false : !tts.isEnabled();
      tts.setEnabled(next);
      console.log(`TTS ${next ? 'on' : 'off'}.`);
      break;
    }
    case '/speak':
      // Re-speak the last final response (e.g. user missed the audio or
      // toggled TTS on after the answer was already on screen).
      tts.repeat();
      break;
    default:
      console.log('Unknown command:', cmd);
      console.log('Available: /exit, /mode, /reset, /tts [on|off], /speak');
  }
}

async function readAllStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf-8').trim();
}

async function resolveImageInputToUrl(imageInput: string): Promise<string> {
  const value = String(imageInput || '').trim();
  if (!value) {
    throw new Error('Imagem não informada');
  }
  if (/^https?:\/\//i.test(value) || /^data:/i.test(value)) {
    return value;
  }

  const absolutePath = path.resolve(value);
  const raw = await fs.readFile(absolutePath);
  const ext = path.extname(absolutePath).toLowerCase();
  const mime = IMAGE_MIME_BY_EXT[ext] || 'application/octet-stream';
  return `data:${mime};base64,${raw.toString('base64')}`;
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return String(error || 'erro desconhecido');
}

// Global safety nets. Without these, an unhandled promise rejection on the
// agent path (e.g. context-exceeded that escaped its retry budget, or a
// distillation chat that failed) would terminate the process in Node ≥15 with
// no chance to flush brain/history. The user reported the symptom directly:
// "ao atingir o total de contexto cli fecha e nao faz o resumo da sessao".
// We log the rejection and let the interactive loop continue — the user can
// retry in the same session.
process.on('unhandledRejection', (reason) => {
  const msg = reason instanceof Error ? (reason.stack || reason.message) : String(reason);
  console.error('[unhandledRejection]', msg);
});

program.parse();
