#!/usr/bin/env node

/**
 * TUI Entry Point - Professional layout
 *
 * Session restore: previously the TUI always called `agent.initialize()`
 * without a session id, so it permanently started fresh and never
 * displayed prior turns even when the on-disk session JSON had them.
 *
 * Resolution order for the target session id:
 *   1) --session <16-hex-hash> CLI arg
 *   2) PHENOM_SESSION env var (same 16-hex format)
 *   3) Most recent session on disk (fallback, opt-in via PHENOM_RESUME=1)
 *
 * Why opt-in for fallback (PHENOM_RESUME=1): the CLI `chat` command
 * auto-resumes the last session by design (interactive shell expectation).
 * The TUI is often launched as a fresh editor-style session, so we keep
 * the "always new" default and let the user opt in.
 *
 * Restoration display path: we push directly into stateStore instead of
 * re-emitting USER_MESSAGE / AGENT_MESSAGE on the event bus. The TUI's
 * USER_MESSAGE handler triggers `agent.processInput`, which would kick
 * off real inference for every restored user turn — that is NOT what we
 * want on restore. stateStore.addMessage only updates the rendered chat.
 */

import { ProfessionalTUI } from './tui/professional-tui.js';
import { Agent } from './agent.js';
import { stateStore } from './tui/state-store.js';

const SESSION_HASH_RE = /^[a-f0-9]{16}$/i;

function parseSessionArg(argv: string[]): string | undefined {
  // Accept `--session <hash>` and `-s <hash>` and `--session=<hash>`.
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--session' || a === '-s') {
      const next = argv[i + 1];
      if (next && SESSION_HASH_RE.test(next)) return next;
    } else if (a.startsWith('--session=')) {
      const v = a.slice('--session='.length);
      if (SESSION_HASH_RE.test(v)) return v;
    }
  }
  return undefined;
}

function splitThinkFromContent(raw: string): { reasoning: string; content: string } {
  // Mirrors index.ts's splitThink so persisted `<think>…</think>\nanswer`
  // round-trips into a thinking block + visible answer on restore.
  const m = /^([\s\S]*?)<think>([\s\S]*?)<\/think>([\s\S]*)$/.exec(raw);
  if (!m) return { reasoning: '', content: raw };
  return { reasoning: m[2].trim(), content: (m[1] + m[3]).trim() };
}

async function main(): Promise<void> {
  console.log('Diretório de trabalho:', process.cwd());
  console.log('Arquivos serão criados em:', process.cwd());
  console.log('');

  const agent = new Agent();

  // Resolve target session id.
  const cliSession = parseSessionArg(process.argv.slice(2));
  const envSession = process.env.PHENOM_SESSION && SESSION_HASH_RE.test(process.env.PHENOM_SESSION)
    ? process.env.PHENOM_SESSION
    : undefined;
  let fallbackLast: string | undefined;
  if (!cliSession && !envSession && process.env.PHENOM_RESUME === '1') {
    try {
      fallbackLast = await agent.getMostRecentSessionId();
    } catch { /* offline / no sessions yet — start fresh */ }
  }
  const targetSessionId = cliSession || envSession || fallbackLast;

  await agent.initialize(targetSessionId);
  const sid = agent.getSessionId();

  if (targetSessionId && sid === targetSessionId) {
    console.log(`Sessão restaurada (hash: ${sid})`);
  } else if (targetSessionId && sid !== targetSessionId) {
    console.log(`Sessão ${targetSessionId} não encontrada. Nova sessão (hash: ${sid}).`);
  } else {
    console.log(`Nova sessão (hash: ${sid})`);
  }

  // Hydrate the TUI's chat with the restored conversation BEFORE starting
  // the screen so the first paint already shows prior turns. We bypass the
  // event bus on purpose — the TUI's USER_MESSAGE handler calls
  // `agent.processInput`, which would re-trigger inference for every
  // restored user message. stateStore.addMessage only updates render
  // state, never invokes the agent.
  if (targetSessionId && sid === targetSessionId) {
    const restored = agent.getConversationMessages()
      .filter((m) => (m.role === 'user' || m.role === 'assistant') && String(m.content || '').trim().length > 0);
    if (restored.length > 0) {
      console.log(`Replay: ${restored.length} mensagem(ns)`);
      for (const msg of restored) {
        if (msg.role === 'user') {
          stateStore.addMessage({ role: 'user', content: msg.content });
        } else {
          // Prefer the recorded user-visible form (see Message.displayContent
          // in types.ts). When a turn only emitted reasoning + tool calls,
          // splitThink yields empty content; without displayContent the
          // turn vanishes on restore. Fall back to splitThink content for
          // sessions written before the field existed.
          const { content } = splitThinkFromContent(String(msg.content || ''));
          const visible = ((msg as { displayContent?: string }).displayContent || '').trim() || content;
          if (visible) {
            stateStore.addMessage({ role: 'assistant', content: visible });
          }
        }
      }
    }
  }

  // Brief pause so the user can read the session banner before alt-screen
  // takes over (blessed clears the scroll buffer when it grabs the screen).
  await new Promise(resolve => setTimeout(resolve, 600));

  const tui = new ProfessionalTUI(agent);
  tui.start();
}

main().catch(console.error);
