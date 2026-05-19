#!/usr/bin/env node

import { Command } from 'commander';
import { promises as fs } from 'fs';
import path from 'path';
import { Agent } from './agent.js';
import { config } from './config.js';
import { CliRenderer } from './cli-renderer.js';
import { eventBus, EventType } from './tui/event-bus.js';
import type { AgentState } from './types.js';

const IMAGE_MIME_BY_EXT: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
};

type ReadlineWithHistory = import('readline').Interface & { history: string[] };

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
  .option('--stream', 'Ativa streaming de resposta em tempo real')
  .option('-p, --prompt <text>', 'Envia prompt e encerra (modo pipe)')
  .option('-i, --image <path-or-url>', 'Anexa imagem (vision) para o prompt atual')
  .action(async (options) => {
    const agent = new Agent();
    const renderer = new CliRenderer();
    renderer.attach();

    agent.setMode(normalizeMode(options.mode));
    if (options.stream) {
      agent.setStreamEnabled(true);
    }

    let lastSessionId: string | undefined;
    try {
      lastSessionId = await agent.getMostRecentSessionId();
    } catch {}

    try {
      await agent.initialize(lastSessionId);
      const sid = agent.getSessionId();
      if (lastSessionId && sid === lastSessionId) {
        console.log('Session restored (' + sid.slice(0, 8) + '...)');
      } else {
        console.log('New session (' + sid?.slice(0, 8) + '...)');
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
      return;
    }

    // ── Interactive mode ────────────────────────────────────────────
    const rl = await importReadline();
    const reader = rl.createInterface({
      input: process.stdin,
      output: process.stdout,
      prompt: '',
      historySize: 100
    }) as ReadlineWithHistory;

    const historyPath = path.join(process.cwd(), '.phenom-history');
    let savedHistory: string[] = [];
    try {
      const raw = await fs.readFile(historyPath, 'utf-8');
      savedHistory = raw.split('\n').filter(Boolean).reverse();
    } catch {}
    reader.history = savedHistory.slice(0, 100);
    renderer.bindReadline(reader);

    let processing = false;

    reader.on('line', async (line) => {
      const input = line.trim();
      if (!input) {
        renderer.renderPrompt();
        return;
      }

      processing = true;
      eventBus.emit(EventType.USER_MESSAGE, { content: input });

      if (input.startsWith('/')) {
        await handleCommand(input, agent, reader);
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
    });

    reader.on('close', async () => {
      while (processing) {
        await new Promise(r => setTimeout(r, 100));
      }
      try {
        const dir = path.dirname(historyPath);
        await fs.mkdir(dir, { recursive: true });
        const historyLines = reader.history?.filter((l: string) => l) || [];
        const history = historyLines.reverse().join('\n');
        await fs.writeFile(historyPath, history, 'utf-8');
      } catch {}
      console.log('Session saved. Use phenom chat to continue.');
      process.exit(0);
    });

    // Mostrar prompt inicial
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

async function handleCommand(command: string, agent: Agent, rl: ReadlineWithHistory): Promise<void> {
  const parts = command.split(' ');
  const cmd = parts[0];

  switch (cmd) {
    case '/exit':
      rl.close();
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
    default:
      console.log('Unknown command:', cmd);
      console.log('Available: /exit, /mode, /reset');
  }
}

async function readAllStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf-8').trim();
}

async function importReadline(): Promise<typeof import('readline')> {
  return import('readline');
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

program.parse();
