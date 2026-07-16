// Standardized chat parser types — port of the architectural concepts from
// llama.cpp's common/chat.cpp (`common_chat_msg`, `common_chat_params`,
// `COMMON_CHAT_FORMAT_*`). The TypeScript port collapses llama.cpp's full
// PEG grammar machinery into a configurable streaming state machine: the
// trade-off is we don't validate every byte against a formal grammar, but
// we get the same robustness for the formats every modern instruct model
// actually produces.
//
// Naming follows llama.cpp where direct equivalents exist (Format,
// ParsedMessage, ToolCall) so anyone reading both sides can map the
// concepts 1:1. Differences from llama.cpp are documented in-line.

/**
 * Output format produced by a given model template. Mirrors
 * `enum COMMON_CHAT_FORMAT_*` in llama.cpp/common/chat.h:
 *
 *   - PEG_NATIVE  → the modern instruct format used by Qwen2.5+/Qwen3,
 *                   Mistral, DeepSeek, GPT-OSS, Llama 3.x, Codestral,
 *                   GigaChat, Kimi, LFM2 — all of which wrap tool calls
 *                   in a distinctive tag pair the parser locates.
 *   - PEG_GEMMA4  → Gemma 4's `<func_call>` / `<func_result>` flow
 *                   (declared but not yet implemented in the TS port).
 *   - PEG_SIMPLE  → minimalist json-object-as-content fallback for
 *                   templates with no explicit tool tag (the model emits a
 *                   bare `{ "name": ..., "arguments": ... }`).
 *   - CONTENT_ONLY → no tool support at all; passthrough.
 */
export enum ChatFormat {
  ContentOnly = 'content-only',
  PegNative = 'peg-native',
  PegSimple = 'peg-simple',
  PegGemma4 = 'peg-gemma4',
}

/** A single tool call parsed out of the stream. */
export interface ParsedToolCall {
  /** Per-stream incrementing index — matches the order in which tool calls were emitted. */
  index: number;
  /** Tool name. */
  name: string;
  /** Decoded arguments. Keys/values are model-emitted, NOT validated against schema here. */
  arguments: Record<string, unknown>;
  /**
   * Stable ID. Caller may overwrite with their own ID scheme; provided so the
   * parser can emit consistent IDs across the partial→complete transition.
   */
  id: string;
  /** Raw text the parser consumed for this call (for diagnostics/replay). */
  raw: string;
}

/** Reasoning ("think") block extracted from the stream, if the format supports it. */
export interface ParsedReasoning {
  text: string;
  /** True if the closing tag has been observed; false means still streaming. */
  complete: boolean;
}

/**
 * Incremental parser output for a single `addChunk` call. The parser yields
 * each kind of data as soon as it's complete:
 *
 *   - `content`: text the user is meant to see. Emitted immediately when the
 *               parser is sure it isn't part of a tool/reasoning block — this
 *               matches Ollama's design and is the reason we can stream
 *               smoothly without waiting for the whole response.
 *   - `reasoning`: chunks of `<think>` content. Empty when no reasoning was
 *                  seen in this chunk.
 *   - `toolCalls`: zero or more complete tool calls parsed in this chunk.
 *   - `done`: true once the parser hit a terminal state (close tag for a
 *             json-bracketed format, or `addChunk` was called after finish).
 */
export interface ParserDelta {
  content: string;
  reasoning: string;
  toolCalls: ParsedToolCall[];
  done: boolean;
}

/**
 * Configuration object that tells the state machine what tags to look for in
 * a given format. Built by `format-detector.ts` from a model identifier;
 * llama.cpp builds the equivalent (with PEG rules) inside its
 * `common_chat_params_init_*` factory functions.
 */
export interface FormatConfig {
  format: ChatFormat;
  /**
   * Opening marker of a tool-call block, e.g. `<tool_call>`, `[TOOL_CALLS]`,
   * `<|tool_calls_begin|>`. Empty for ContentOnly. For PegSimple the
   * "marker" is the brace `{` itself — handled specially.
   */
  toolCallStart: string;
  /** Closing marker; empty when the model just relies on the json brace close. */
  toolCallEnd: string;
  /**
   * Optional outer wrapper for models that group multiple tool calls
   * (Mistral: `[TOOL_CALLS]` wraps the section; each call is a separate
   * `{...}` object inside).
   */
  sectionStart?: string;
  sectionEnd?: string;
  /**
   * Layout of the JSON inside a tool call:
   *   - `single-object`: `{"name": "X", "arguments": {...}}` — Qwen, Mistral, Llama 3.x, DeepSeek
   *   - `name-then-args`: name on its own line, args block separated — Functionary v3
   */
  argsStyle: 'single-object' | 'name-then-args';
  /**
   * Reasoning tag pair (e.g. `<think>`/`</think>`). When set, content
   * between these tags is routed to the `reasoning` channel instead of
   * `content`. Mirrors llama.cpp's `thinking_start_tag`/`thinking_end_tag`.
   */
  thinkingStart?: string;
  thinkingEnd?: string;
  /**
   * Tokens the model emits as part of the protocol that we must never
   * surface to the user even if they land outside a tool/reasoning block.
   * Mirrors llama.cpp's `preserved_tokens` (chat.cpp:934-939).
   */
  preservedTokens: string[];
}

/** Public parser interface. Implementations are stateful per-stream. */
export interface ChatStreamParser {
  /** Format the parser was built for (informational). */
  readonly format: ChatFormat;
  /**
   * Feed the next chunk of stream content. Safe to call with partial input —
   * the parser holds an internal buffer and yields whatever it can prove is
   * complete in this chunk. Subsequent chunks resume seamlessly.
   */
  addChunk(text: string): ParserDelta;
  /**
   * Signal end-of-stream. Anything still pending in the buffer is flushed
   * as content (best-effort — a truncated tool call IS lost, the parser
   * does not invent arguments).
   */
  finish(): ParserDelta;
  /** Snapshot of internal buffer for diagnostics. */
  inspect(): { state: string; bufferLength: number; toolCallIndex: number };
}
