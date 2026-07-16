// Per-format configuration objects. Mirrors the way llama.cpp's
// `common_chat_params_init_*` factory functions encode the protocol of each
// supported model family (chat.cpp:880-1900). When a new model family lands
// upstream, the place to wire it up is here.
//
// All tags are byte-exact matches the parser scans for. They were extracted
// from the actual chat_template.jinja of each model on Hugging Face — NOT
// guessed. References:
//
//   Qwen 2.5+/Qwen 3:   `<tool_call>` … `</tool_call>` around a JSON object.
//                        See Qwen2.5-Coder, Qwen3 chat templates on HF.
//   Mistral / Codestral: `[TOOL_CALLS]` wraps an array; each call is a
//                        `{ "name": "...", "arguments": {...} }` object.
//   DeepSeek (R1/V3):    `<|tool_calls_begin|>` … `<|tool_calls_end|>` with
//                        per-call `<|tool_call_begin|>` … `<|tool_call_end|>`.
//   GPT-OSS / OpenAI O*: `<|channel|>commentary to=...` channel routing (we
//                        treat as PegNative with the `<|channel|>` start).
//   Llama 3.1 / 3.2 tools: `<|python_tag|>{...}<|eom_id|>` for builtin or
//                          plain JSON for custom tools.
//   Gemma 4 (peg-gemma4 — declared, not yet implemented):
//                        `<func_call>` / `<func_result>`.

import { ChatFormat, type FormatConfig } from './types.js';

export const FORMAT_QWEN_TOOL_CALL: FormatConfig = {
  format: ChatFormat.PegNative,
  toolCallStart: '<tool_call>',
  toolCallEnd: '</tool_call>',
  argsStyle: 'single-object',
  thinkingStart: '<think>',
  thinkingEnd: '</think>',
  preservedTokens: [
    '<|im_start|>', '<|im_end|>',
    '<tool_call>', '</tool_call>',
    '<think>', '</think>',
    '<tool_response>', '</tool_response>',
  ],
};

export const FORMAT_MISTRAL_TOOL_CALLS: FormatConfig = {
  format: ChatFormat.PegNative,
  toolCallStart: '[TOOL_CALLS]',
  toolCallEnd: '[/TOOL_CALLS]',
  sectionStart: '[TOOL_CALLS]',
  sectionEnd: '[/TOOL_CALLS]',
  argsStyle: 'single-object',
  thinkingStart: '[THINK]',
  thinkingEnd: '[/THINK]',
  preservedTokens: [
    '[TOOL_CALLS]', '[/TOOL_CALLS]',
    '[THINK]', '[/THINK]',
    '[ARGS]',
  ],
};

export const FORMAT_DEEPSEEK_TOOL_CALL: FormatConfig = {
  format: ChatFormat.PegNative,
  // DeepSeek uses a per-call open/close; we treat the per-call markers as the
  // tool-call delimiters and IGNORE the outer section pair, because matching
  // both layers with one state machine costs nothing and the section may not
  // appear when there's a single call.
  toolCallStart: '<|tool_call_begin|>',
  toolCallEnd: '<|tool_call_end|>',
  sectionStart: '<|tool_calls_begin|>',
  sectionEnd: '<|tool_calls_end|>',
  argsStyle: 'single-object',
  thinkingStart: '<think>',
  thinkingEnd: '</think>',
  preservedTokens: [
    '<|tool_calls_begin|>', '<|tool_calls_end|>',
    '<|tool_call_begin|>', '<|tool_call_end|>',
    '<think>', '</think>',
    '<｜begin▁of▁sentence｜>', '<｜end▁of▁sentence｜>',
  ],
};

export const FORMAT_LLAMA3_PYTHON_TAG: FormatConfig = {
  format: ChatFormat.PegNative,
  // Llama 3.1/3.2 use `<|python_tag|>` to introduce a tool call, then the
  // call is a bare JSON object terminated by `<|eom_id|>`.
  toolCallStart: '<|python_tag|>',
  toolCallEnd: '<|eom_id|>',
  argsStyle: 'single-object',
  preservedTokens: [
    '<|python_tag|>',
    '<|eom_id|>', '<|eot_id|>',
    '<|start_header_id|>', '<|end_header_id|>',
  ],
};

export const FORMAT_GPT_OSS_CHANNEL: FormatConfig = {
  format: ChatFormat.PegNative,
  // GPT-OSS channel-based output: `<|channel|>commentary to=<tool> <|message|>{...}<|end|>`
  // — we anchor on `<|channel|>commentary to=` then parse `<|message|>` … `<|end|>`.
  // The parser treats `<|message|>` as the args-start; the tool name comes
  // from the `to=` prefix which the state machine reads.
  toolCallStart: '<|channel|>commentary',
  toolCallEnd: '<|end|>',
  argsStyle: 'name-then-args',
  thinkingStart: '<|channel|>analysis',
  thinkingEnd: '<|end|>',
  preservedTokens: [
    '<|channel|>', '<|message|>', '<|end|>', '<|start|>',
    '<|return|>', '<|call|>',
  ],
};

export const FORMAT_PEG_SIMPLE_JSON: FormatConfig = {
  format: ChatFormat.PegSimple,
  // No explicit tags — the model just emits a JSON object at the start of
  // its turn when it wants to call a tool. Parser uses brace-counting from
  // the first non-whitespace `{`. If the first non-ws char isn't `{`, the
  // model is just talking → treat the whole stream as content.
  toolCallStart: '{',
  toolCallEnd: '}',
  argsStyle: 'single-object',
  preservedTokens: [],
};

export const FORMAT_CONTENT_ONLY: FormatConfig = {
  format: ChatFormat.ContentOnly,
  toolCallStart: '',
  toolCallEnd: '',
  argsStyle: 'single-object',
  preservedTokens: [],
};

/**
 * Registry of all built-in formats. Order matters for some fallback
 * heuristics in the format detector (more specific names probed first).
 */
export const ALL_FORMATS: ReadonlyArray<{ id: string; config: FormatConfig }> = [
  { id: 'qwen-tool-call', config: FORMAT_QWEN_TOOL_CALL },
  { id: 'mistral-tool-calls', config: FORMAT_MISTRAL_TOOL_CALLS },
  { id: 'deepseek-tool-call', config: FORMAT_DEEPSEEK_TOOL_CALL },
  { id: 'llama3-python-tag', config: FORMAT_LLAMA3_PYTHON_TAG },
  { id: 'gpt-oss-channel', config: FORMAT_GPT_OSS_CHANNEL },
  { id: 'peg-simple-json', config: FORMAT_PEG_SIMPLE_JSON },
  { id: 'content-only', config: FORMAT_CONTENT_ONLY },
] as const;
