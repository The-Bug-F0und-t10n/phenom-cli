// Maps a model identifier (the string sent to the server in the `model`
// field) to one of the configured chat formats. This is the TypeScript
// counterpart to llama.cpp's `common_chat_try_specialized_template` chain
// (chat.cpp:2300-2400) — we identify the model family then return its
// FormatConfig.
//
// Detection here is intentionally STRING-BASED (model name), not template-
// based. llama.cpp can do template-based detection because it has the
// rendered template in hand; phenom is a network client and never sees the
// jinja source. The trade-off: when a user runs a model with a non-standard
// template, we fall back to PegSimple and let the parser tolerate it.

import {
  FORMAT_QWEN_TOOL_CALL,
  FORMAT_MISTRAL_TOOL_CALLS,
  FORMAT_DEEPSEEK_TOOL_CALL,
  FORMAT_LLAMA3_PYTHON_TAG,
  FORMAT_GPT_OSS_CHANNEL,
  FORMAT_PEG_SIMPLE_JSON,
  FORMAT_CONTENT_ONLY,
} from './formats.js';
import type { FormatConfig } from './types.js';

interface DetectionRule {
  /** Human-readable family label for logs/telemetry. */
  family: string;
  /** Substrings that, if present in the (lowercased) model name, select this format. */
  needles: string[];
  config: FormatConfig;
}

// Detection rules ordered most-specific first. The first matching rule wins.
const RULES: DetectionRule[] = [
  {
    family: 'qwen',
    needles: ['qwen2.5-coder', 'qwen3', 'qwen3.5', 'qwen-2.5-coder', 'qwen2.1', 'phenom'],
    config: FORMAT_QWEN_TOOL_CALL,
  },
  {
    // Qwen plain (qwen2.5 instruct, qwen2 base) — these CAN emit <tool_call>
    // when the system prompt demonstrates it, but were not RLHF'd on it.
    // We still use the Qwen format; the agent's text-protocol fallback in
    // the prompt is what carries them.
    family: 'qwen-loose',
    needles: ['qwen'],
    config: FORMAT_QWEN_TOOL_CALL,
  },
  {
    family: 'gpt-oss',
    needles: ['gpt-oss', 'gptoss', 'gpt_oss', 'openai-oss'],
    config: FORMAT_GPT_OSS_CHANNEL,
  },
  {
    family: 'deepseek',
    needles: ['deepseek-r1', 'deepseek-v3', 'deepseek-v2.5', 'deepseekr1'],
    config: FORMAT_DEEPSEEK_TOOL_CALL,
  },
  {
    family: 'mistral',
    needles: ['mistral-large', 'codestral', 'ministral', 'mixtral', 'mistral'],
    config: FORMAT_MISTRAL_TOOL_CALLS,
  },
  {
    family: 'llama3',
    needles: ['llama-3.1', 'llama-3.2', 'llama3.1', 'llama3.2', 'llama-3.3', 'llama3.3'],
    config: FORMAT_LLAMA3_PYTHON_TAG,
  },
];

/**
 * Pick the format config for a given model name. When no rule matches we
 * return PegSimple — the brace-counter handles any model that emits a bare
 * JSON tool call without explicit tags (which is the de-facto baseline).
 *
 * Set `force` to override detection (for tests or PHENOM_CHAT_FORMAT env).
 */
export function detectFormat(modelName: string, force?: string): FormatConfig {
  if (force) {
    const f = force.toLowerCase().trim();
    const direct = RULES.find(r => r.family === f);
    if (direct) return direct.config;
    if (f === 'peg-simple' || f === 'simple') return FORMAT_PEG_SIMPLE_JSON;
    if (f === 'content-only' || f === 'none') return FORMAT_CONTENT_ONLY;
    // Unknown override — fall through to detection.
  }
  const lower = String(modelName || '').toLowerCase();
  for (const rule of RULES) {
    if (rule.needles.some(n => lower.includes(n))) return rule.config;
  }
  return FORMAT_PEG_SIMPLE_JSON;
}

/** Like detectFormat but also returns the family label, for telemetry. */
export function detectFormatWithFamily(modelName: string): { family: string; config: FormatConfig } {
  const lower = String(modelName || '').toLowerCase();
  for (const rule of RULES) {
    if (rule.needles.some(n => lower.includes(n))) return { family: rule.family, config: rule.config };
  }
  return { family: 'fallback', config: FORMAT_PEG_SIMPLE_JSON };
}
