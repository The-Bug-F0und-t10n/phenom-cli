// Repro for "model puts whole reply inside <think>" bug.
// Hits the live Ollama endpoint with the same prompts that produced the bug
// in session 5b8e149b06a32f85.json, captures the RAW byte stream, then feeds
// the same bytes into StateMachineChatParser to see what content/reasoning
// the pipeline produces.

import { StateMachineChatParser } from '../../chat/parsers/state-machine.js';
import { FORMAT_QWEN_TOOL_CALL } from '../../chat/formats.js';

const OLLAMA_HOST = process.env.OLLAMA_HOST;
const MODEL = process.env.OLLAMA_CODER_MODEL || process.env.OLLAMA_MODEL;

if (!OLLAMA_HOST) {
  console.error('FAIL: OLLAMA_HOST not set');
  process.exit(2);
}
if (!MODEL) {
  console.error('FAIL: OLLAMA_MODEL/OLLAMA_CODER_MODEL not set');
  process.exit(2);
}

interface CapturedTurn {
  prompt: string;
  raw: string;
  parsedContent: string;
  parsedReasoning: string;
}

async function callBackend(prompt: string): Promise<string> {
  // llama.cpp serves OpenAI-compat at /v1/chat/completions. SSE stream with
  // `data: {...}` lines, terminated by `data: [DONE]`. Capture delta.content
  // and (if the server splits thinking) delta.reasoning_content into a single
  // raw string in protocol form so the parser sees the same bytes either way.
  const url = `${OLLAMA_HOST}/v1/chat/completions`;
  const body = {
    model: MODEL,
    messages: [{ role: 'user', content: prompt }],
    stream: true,
    temperature: 0.25,
  };
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok || !res.body) {
    throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let allContent = '';
  let pendingThinking = '';
  let thinkingOpen = false;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let nl: number;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (payload === '[DONE]') break;
      try {
        const obj = JSON.parse(payload);
        const delta = obj?.choices?.[0]?.delta ?? {};
        const reason = typeof delta.reasoning_content === 'string' ? delta.reasoning_content : '';
        const text = typeof delta.content === 'string' ? delta.content : '';
        if (reason) {
          if (!thinkingOpen) { pendingThinking += '<think>'; thinkingOpen = true; }
          pendingThinking += reason;
        }
        if (text) {
          if (thinkingOpen) { pendingThinking += '</think>'; thinkingOpen = false; }
          allContent += pendingThinking + text;
          pendingThinking = '';
        }
      } catch {
        // ignore
      }
    }
  }
  if (thinkingOpen) pendingThinking += '</think>';
  allContent += pendingThinking;
  return allContent;
}

function parseWithStateMachine(raw: string): { content: string; reasoning: string } {
  const parser = new StateMachineChatParser(FORMAT_QWEN_TOOL_CALL);
  let content = '';
  let reasoning = '';
  // Feed in small chunks to simulate streaming.
  const chunkSize = 8;
  for (let i = 0; i < raw.length; i += chunkSize) {
    const d = parser.addChunk(raw.slice(i, i + chunkSize));
    content += d.content;
    reasoning += d.reasoning;
  }
  const fin = parser.finish();
  content += fin.content;
  reasoning += fin.reasoning;
  return { content, reasoning };
}

async function runOne(prompt: string): Promise<CapturedTurn> {
  const raw = await callBackend(prompt);
  const { content, reasoning } = parseWithStateMachine(raw);
  return { prompt, raw, parsedContent: content, parsedReasoning: reasoning };
}

function summarize(s: string, max = 200): string {
  if (s.length <= max) return JSON.stringify(s);
  return JSON.stringify(s.slice(0, max)) + `… (+${s.length - max} chars)`;
}

async function main() {
  const prompts = ['ola', 'quem e voce?', 'por que esta responsendo no thining?'];
  const results: CapturedTurn[] = [];
  for (const p of prompts) {
    process.stdout.write(`\n── PROMPT: ${p}\n`);
    try {
      const r = await runOne(p);
      results.push(r);
      console.log(`  raw (${r.raw.length} chars): ${summarize(r.raw)}`);
      console.log(`  parsed.content    (${r.parsedContent.length}): ${summarize(r.parsedContent)}`);
      console.log(`  parsed.reasoning  (${r.parsedReasoning.length}): ${summarize(r.parsedReasoning)}`);
    } catch (e: any) {
      console.error(`  FAIL: ${e?.message || e}`);
      process.exit(1);
    }
  }

  // Verdict
  console.log('\n── VERDICT ──');
  let leaks = 0;
  for (const r of results) {
    const onlyReasoning = r.parsedContent.trim().length === 0 && r.parsedReasoning.trim().length > 0;
    if (onlyReasoning) {
      leaks++;
      console.log(`  LEAK: "${r.prompt}" → empty content, reasoning has ${r.parsedReasoning.trim().length} chars`);
    } else {
      console.log(`  OK:   "${r.prompt}" → content has ${r.parsedContent.trim().length} chars`);
    }
  }
  if (leaks > 0) {
    console.log(`\n  ${leaks}/${results.length} turn(s) leaked the entire reply into <think>.`);
    console.log('  Conclusion: parser is correctly routing bytes, but the MODEL is emitting');
    console.log('  the answer inside <think>…</think> with no content after the close tag.');
    process.exit(3);
  }
  console.log('\n  No leaks. Parser produced non-empty content for every turn.');
}

main().catch((e) => {
  console.error('FATAL:', e);
  process.exit(1);
});
