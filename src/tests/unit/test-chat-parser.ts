// Tests for the standardized chat parser (src/chat/). Each test feeds a
// realistic stream byte-by-byte OR in deliberate-split chunks to verify the
// state machine handles partial input correctly — the most common cause of
// regression for parsers that rely on regex-after-full-buffer.
//
// Format fixtures match what real models emit (extracted from Qwen3,
// Mistral, DeepSeek, GPT-OSS, Llama 3.x chat templates on HF).

import {
  createChatParser,
  createChatParserFromConfig,
  ChatFormat,
} from '../../chat/index.js';
import {
  FORMAT_QWEN_TOOL_CALL,
  FORMAT_MISTRAL_TOOL_CALLS,
  FORMAT_DEEPSEEK_TOOL_CALL,
  FORMAT_LLAMA3_PYTHON_TAG,
  FORMAT_PEG_SIMPLE_JSON,
  FORMAT_CONTENT_ONLY,
  FORMAT_GPT_OSS_CHANNEL,
} from '../../chat/formats.js';

let passed = 0;
const tests: { name: string; fn: () => void }[] = [];
function test(name: string, fn: () => void): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

/** Drive a parser with a list of chunks and concatenate the deltas. */
function run(parser: ReturnType<typeof createChatParser>, chunks: string[]): {
  content: string;
  reasoning: string;
  toolCalls: Array<{ name: string; arguments: Record<string, unknown> }>;
  done: boolean;
} {
  let content = '';
  let reasoning = '';
  const toolCalls: Array<{ name: string; arguments: Record<string, unknown> }> = [];
  let done = false;
  for (const c of chunks) {
    const d = parser.addChunk(c);
    content += d.content;
    reasoning += d.reasoning;
    for (const t of d.toolCalls) toolCalls.push({ name: t.name, arguments: t.arguments });
    done = d.done;
  }
  const flush = parser.finish();
  content += flush.content;
  reasoning += flush.reasoning;
  for (const t of flush.toolCalls) toolCalls.push({ name: t.name, arguments: t.arguments });
  done = flush.done;
  return { content, reasoning, toolCalls, done };
}

// ── Format detection ─────────────────────────────────────────────────────

test('detectFormat picks Qwen for qwen3.5-coder', () => {
  const p = createChatParser('qwen3.5-coder:14b');
  assert(p.format === ChatFormat.PegNative, `expected PegNative, got ${p.format}`);
});

test('detectFormat picks Mistral for codestral-22b', () => {
  const p = createChatParser('codestral:22b');
  assert(p.format === ChatFormat.PegNative, `expected PegNative, got ${p.format}`);
});

test('detectFormat falls back to PegSimple on unknown model', () => {
  const p = createChatParser('some-unknown-llm:7b');
  assert(p.format === ChatFormat.PegSimple, `expected PegSimple, got ${p.format}`);
});

test('detectFormat respects override', () => {
  const p = createChatParser('qwen3', { formatOverride: 'content-only' });
  assert(p.format === ChatFormat.ContentOnly, `override ignored: got ${p.format}`);
});

// ── Qwen <tool_call> ─────────────────────────────────────────────────────

test('Qwen: simple tool call returns name + args, leaves no content leakage', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, ['<tool_call>\n{"name": "read_file", "arguments": {"path": "a.ts"}}\n</tool_call>']);
  assert(r.toolCalls.length === 1, `expected 1 tool call, got ${r.toolCalls.length}`);
  assert(r.toolCalls[0].name === 'read_file', `wrong name: ${r.toolCalls[0].name}`);
  assert(r.toolCalls[0].arguments.path === 'a.ts', `wrong arg: ${JSON.stringify(r.toolCalls[0].arguments)}`);
  assert(r.content.trim() === '', `content leaked: '${r.content}'`);
});

test('Qwen: surrounding content is emitted before/after the tool call', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, [
    'Let me read the file.\n',
    '<tool_call>{"name":"read_file","arguments":{"path":"a.ts"}}</tool_call>',
    '\nDone.'
  ]);
  assert(r.toolCalls.length === 1, `expected 1 tool call`);
  assert(r.content.includes('Let me read the file'), `pre-content lost: '${r.content}'`);
  assert(r.content.includes('Done'), `post-content lost: '${r.content}'`);
  assert(!r.content.includes('<tool_call>'), `tag leaked: '${r.content}'`);
});

test('Qwen: split between <tool and _call> still parses', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, ['hi <tool', '_call>{"name":"date","arguments":{}}</tool_call>']);
  assert(r.toolCalls.length === 1, `partial-tag handling broken`);
  assert(r.toolCalls[0].name === 'date', `wrong name`);
  assert(r.content.trim() === 'hi', `content wrong: '${r.content}'`);
});

test('Qwen: split inside JSON body still parses when complete', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, ['<tool_call>{"name":"f",', '"arguments":{"x":1}}', '</tool_call>']);
  assert(r.toolCalls.length === 1, `split-body broken`);
  assert(r.toolCalls[0].arguments.x === 1, `arg lost`);
});

test('Qwen: multiple tool calls in one stream', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, [
    '<tool_call>{"name":"a","arguments":{}}</tool_call>',
    '<tool_call>{"name":"b","arguments":{}}</tool_call>',
  ]);
  assert(r.toolCalls.length === 2, `expected 2 calls, got ${r.toolCalls.length}`);
  assert(r.toolCalls[0].name === 'a' && r.toolCalls[1].name === 'b', `wrong order/names`);
});

test('Qwen: <think> reasoning routed to reasoning channel, not content', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, [
    '<think>I should read the file first.</think>',
    'Ok.',
  ]);
  assert(r.reasoning.includes('I should read the file first'), `reasoning lost: '${r.reasoning}'`);
  assert(r.content.includes('Ok.'), `post-think content lost`);
  assert(!r.content.includes('<think>'), `think tag leaked into content`);
});

test('Qwen: preserved tokens are silently dropped from content', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, ['<|im_start|>Hello<|im_end|>']);
  assert(!r.content.includes('<|im_start|>'), `<|im_start|> leaked`);
  assert(!r.content.includes('<|im_end|>'), `<|im_end|> leaked`);
  assert(r.content.includes('Hello'), `actual content lost`);
});

// ── Mistral [TOOL_CALLS] ─────────────────────────────────────────────────

test('Mistral: section with single call parses', () => {
  const p = createChatParserFromConfig(FORMAT_MISTRAL_TOOL_CALLS);
  const r = run(p, ['[TOOL_CALLS]{"name":"search","arguments":{"q":"hi"}}[/TOOL_CALLS]']);
  assert(r.toolCalls.length === 1, `expected 1 call`);
  assert(r.toolCalls[0].name === 'search', `name lost`);
  assert(r.toolCalls[0].arguments.q === 'hi', `arg lost`);
});

test('Mistral: section with multiple calls', () => {
  const p = createChatParserFromConfig(FORMAT_MISTRAL_TOOL_CALLS);
  const r = run(p, [
    '[TOOL_CALLS]',
    '{"name":"a","arguments":{}},',
    '{"name":"b","arguments":{}}',
    '[/TOOL_CALLS]',
  ]);
  assert(r.toolCalls.length === 2, `expected 2 calls, got ${r.toolCalls.length}`);
});

// ── DeepSeek ─────────────────────────────────────────────────────────────

test('DeepSeek: per-call markers parse', () => {
  const p = createChatParserFromConfig(FORMAT_DEEPSEEK_TOOL_CALL);
  const r = run(p, [
    '<|tool_call_begin|>{"name":"foo","arguments":{"k":1}}<|tool_call_end|>',
  ]);
  assert(r.toolCalls.length === 1, `deepseek call lost`);
  assert(r.toolCalls[0].arguments.k === 1, `arg lost`);
});

// ── Llama 3.x <|python_tag|> ─────────────────────────────────────────────

test('Llama3: python_tag tool call', () => {
  const p = createChatParserFromConfig(FORMAT_LLAMA3_PYTHON_TAG);
  const r = run(p, ['<|python_tag|>{"name":"calc","arguments":{"x":2}}<|eom_id|>']);
  assert(r.toolCalls.length === 1, `llama3 call lost`);
  assert(r.toolCalls[0].name === 'calc', `name lost`);
});

// ── GPT-OSS channel format ───────────────────────────────────────────────

test('GPT-OSS: channel format extracts tool name from to= prefix', () => {
  const p = createChatParserFromConfig(FORMAT_GPT_OSS_CHANNEL);
  const r = run(p, [
    '<|channel|>commentary to=functions.get_weather<|message|>{"city":"São Paulo"}<|end|>',
  ]);
  assert(r.toolCalls.length === 1, `gpt-oss call lost`);
  assert(r.toolCalls[0].name === 'get_weather', `name wrong: ${r.toolCalls[0].name}`);
  assert(r.toolCalls[0].arguments.city === 'São Paulo', `arg lost`);
});

// ── PegSimple (bare JSON object) ─────────────────────────────────────────

test('PegSimple: bare JSON object is parsed as tool call', () => {
  const p = createChatParserFromConfig(FORMAT_PEG_SIMPLE_JSON);
  const r = run(p, ['{"name":"foo","arguments":{"x":1}}']);
  assert(r.toolCalls.length === 1, `peg-simple call lost`);
});

test('PegSimple: non-{ start is treated as pure content (model is talking)', () => {
  const p = createChatParserFromConfig(FORMAT_PEG_SIMPLE_JSON);
  const r = run(p, ['Hello, how can I help?']);
  assert(r.toolCalls.length === 0, `false positive on plain text`);
  assert(r.content.includes('Hello'), `content lost`);
});

// ── ContentOnly ──────────────────────────────────────────────────────────

test('ContentOnly: passes everything as content, ignores fake tool markers', () => {
  const p = createChatParserFromConfig(FORMAT_CONTENT_ONLY);
  const r = run(p, ['<tool_call>{"name":"x"}</tool_call> hi']);
  assert(r.toolCalls.length === 0, `content-only should not parse tools`);
  assert(r.content.includes('<tool_call>'), `expected raw passthrough`);
});

// ── Malformed input ──────────────────────────────────────────────────────

test('Qwen: malformed JSON inside tool_call drops the call but does not crash', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, ['<tool_call>{"name": broken,</tool_call>']);
  assert(r.toolCalls.length === 0, `should drop malformed JSON, not parse it`);
});

test('Qwen: truncated tool_call at EOS flushes nothing as content (best-effort)', () => {
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const r = run(p, ['<tool_call>{"name":"f","arguments":{']);
  // The truncated JSON was inside the tool-call state, and finish() emits
  // it as content for caller visibility. It must NOT be parsed as a tool call.
  assert(r.toolCalls.length === 0, `should not parse truncated`);
});

// ── Byte-by-byte stress ──────────────────────────────────────────────────

test('Qwen: byte-by-byte streaming reaches the same result as one-shot', () => {
  const full = 'pre <tool_call>{"name":"f","arguments":{"a":1,"b":"hi"}}</tool_call> post';
  const p = createChatParserFromConfig(FORMAT_QWEN_TOOL_CALL);
  const chunks: string[] = [];
  for (const ch of full) chunks.push(ch);
  const r = run(p, chunks);
  assert(r.toolCalls.length === 1, `byte-stream lost the call`);
  assert(r.toolCalls[0].arguments.a === 1, `byte-stream arg lost`);
  assert(r.toolCalls[0].arguments.b === 'hi', `byte-stream string arg lost`);
  assert(r.content.includes('pre'), `pre-content lost`);
  assert(r.content.includes('post'), `post-content lost`);
});

(() => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nChat parser tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
