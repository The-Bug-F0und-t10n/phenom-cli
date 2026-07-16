// Public API for the standardized chat-stream parser. Single factory:
// `createChatParser(modelName, opts)`. The factory selects the right
// FormatConfig via the detector and instantiates the state machine.
//
// Architectural counterpart to llama.cpp's `common_chat_templates_apply` →
// `common_chat_parse` pipeline. Phenom's port is one factory + one state
// machine, parameterized by FormatConfig.
//
// Activation: phenom keeps the legacy regex-based parser as default. To opt
// in, set `PHENOM_CHAT_PARSER=v2` in the environment (checked by callers in
// ollama-client.ts after the cutover). This keeps risk-of-rollback low
// during the migration.

import { detectFormat, detectFormatWithFamily } from './format-detector.js';
import { StateMachineChatParser } from './parsers/state-machine.js';
import type { ChatStreamParser, FormatConfig } from './types.js';

export {
  ChatFormat,
  type FormatConfig,
  type ChatStreamParser,
  type ParsedToolCall,
  type ParsedReasoning,
  type ParserDelta,
} from './types.js';

export { detectFormat, detectFormatWithFamily };

export interface CreateParserOptions {
  /**
   * Override the auto-detected format (matches a detector family label OR
   * one of: 'peg-simple', 'content-only'). Useful for tests and for the
   * `PHENOM_CHAT_FORMAT` env var.
   */
  formatOverride?: string;
  /** Prefix used when generating tool-call IDs. Default: 'call'. */
  idPrefix?: string;
}

/**
 * Build a streaming chat parser for a given model. Caller feeds chunks via
 * `parser.addChunk(text)` and calls `parser.finish()` at end-of-stream.
 */
export function createChatParser(modelName: string, opts: CreateParserOptions = {}): ChatStreamParser {
  const cfg: FormatConfig = detectFormat(modelName, opts.formatOverride);
  return new StateMachineChatParser(cfg, opts.idPrefix);
}

/** Build a parser from a known FormatConfig (skips detection). */
export function createChatParserFromConfig(cfg: FormatConfig, opts: { idPrefix?: string } = {}): ChatStreamParser {
  return new StateMachineChatParser(cfg, opts.idPrefix);
}

/** True when the new parser is opted-in via env (caller convenience). */
export function isV2ParserEnabled(): boolean {
  const v = (process.env.PHENOM_CHAT_PARSER || '').toLowerCase().trim();
  return v === 'v2' || v === '2' || v === 'true';
}
