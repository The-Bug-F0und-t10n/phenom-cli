// Streaming chat parser implemented as a state machine. The TS counterpart
// to llama.cpp's PEG-driven parser pipeline (common/chat.cpp +
// chat-peg-parser.cpp + chat-auto-parser-*) collapsed into one
// configurable state machine. Same observable behaviour for the formats
// every modern instruct model uses; ~600x less code.
//
// State diagram:
//
//   ┌─────────┐  toolCallStart      ┌──────────────┐
//   │ Content │ ───────────────────▶│  ToolCall    │
//   │         │  thinkingStart      ├──────────────┤
//   │         │ ───────────────────▶│  Reasoning   │
//   │         │  sectionStart       ├──────────────┤
//   │         │ ───────────────────▶│   Section    │
//   │         │  preserved token    │              │
//   │         │   (silently drop)   │              │
//   │         │ ──────┐             │              │
//   │         │ ◀─────┘             │              │
//   └─────────┘  ◀──── toolCallEnd ─┘
//                ◀──── thinkingEnd  ─┘
//                ◀──── sectionEnd   ─┘
//
// "Partial-tail awareness": if the current buffer ENDS with a prefix of any
// interesting tag (e.g. "<too" while we're waiting for "<tool_call>"), we
// hold that suffix in the buffer instead of leaking it to the user as
// content. The Ollama parser uses the same trick (tools.go:111-115).

import {
  ChatFormat,
  type FormatConfig,
  type ChatStreamParser,
  type ParsedToolCall,
  type ParserDelta,
} from '../types.js';

type State = 'content' | 'reasoning' | 'tool-call' | 'section' | 'done';

interface JsonObjectResult {
  data: unknown;
  raw: string;
  /** Index in buffer just AFTER the closing brace. */
  endPos: number;
}

export class StateMachineChatParser implements ChatStreamParser {
  readonly format: ChatFormat;
  private cfg: FormatConfig;
  private state: State = 'content';
  private buffer: string = '';
  private toolCallIndex: number = 0;
  /** True until we see the first non-whitespace character — used by PegSimple. */
  private atStreamStart: boolean = true;
  /** Prefix string the caller may want for tool IDs. */
  private readonly idPrefix: string;

  constructor(cfg: FormatConfig, idPrefix: string = 'call') {
    this.cfg = cfg;
    this.format = cfg.format;
    this.idPrefix = idPrefix;
  }

  inspect(): { state: string; bufferLength: number; toolCallIndex: number } {
    return { state: this.state, bufferLength: this.buffer.length, toolCallIndex: this.toolCallIndex };
  }

  addChunk(text: string): ParserDelta {
    if (this.state === 'done') {
      return { content: text, reasoning: '', toolCalls: [], done: true };
    }
    this.buffer += text;
    return this.drain();
  }

  finish(): ParserDelta {
    // Flush whatever remains. For tool-call / reasoning states, the trailing
    // input was incomplete — surfacing it as content is the least-bad option
    // (caller sees raw bytes instead of silent data loss).
    const flushed: ParserDelta = { content: '', reasoning: '', toolCalls: [], done: true };
    if (this.buffer.length > 0) {
      if (this.state === 'reasoning') flushed.reasoning = this.buffer;
      else flushed.content = this.buffer;
      this.buffer = '';
    }
    this.state = 'done';
    return flushed;
  }

  // ── Inner loop ───────────────────────────────────────────────────────

  private drain(): ParserDelta {
    const delta: ParserDelta = { content: '', reasoning: '', toolCalls: [], done: false };

    // Iteration cap is defensive: each transition either consumes ≥1 byte
    // from the buffer or breaks. Without this cap a misconfigured format
    // could spin forever; with it, we crash loudly instead.
    for (let safety = 0; safety < 1_000_000; safety++) {
      const before = this.buffer.length;
      const stateBefore = this.state;

      switch (this.state) {
        case 'content':
          this.stepContent(delta);
          break;
        case 'reasoning':
          this.stepReasoning(delta);
          break;
        case 'tool-call':
          this.stepToolCall(delta);
          break;
        case 'section':
          this.stepSection(delta);
          break;
        case 'done':
          return { ...delta, done: true };
      }

      if (this.buffer.length === before && this.state === stateBefore) break;
    }

    return delta;
  }

  // ── Content state ────────────────────────────────────────────────────

  private stepContent(delta: ParserDelta): void {
    // PegSimple: if at stream start and the first non-ws is `{`, the whole
    // turn is a tool-call. Otherwise the entire stream is content with no
    // tool parsing. This mirrors Ollama's behaviour (tools.go:68-73).
    if (this.cfg.format === ChatFormat.PegSimple && this.atStreamStart) {
      const trimmed = this.buffer.replace(/^\s+/, '');
      if (trimmed.length === 0) {
        // All whitespace so far — wait for a non-ws character.
        delta.content += this.buffer;
        this.buffer = '';
        return;
      }
      this.atStreamStart = false;
      if (trimmed.startsWith('{')) {
        // Skip leading whitespace, switch to tool-call state.
        const wsLen = this.buffer.length - trimmed.length;
        delta.content += this.buffer.slice(0, wsLen);
        this.buffer = trimmed;
        this.state = 'tool-call';
        return;
      }
      // Non-{ start — disable tool parsing for the rest of the stream.
      // Move to a "content-only flush" mode by terminating once we've
      // drained the buffer here. We set atStreamStart=false above, so we
      // won't re-enter this branch.
      delta.content += this.buffer;
      this.buffer = '';
      return;
    }

    // ContentOnly format: never look for tags. Pass everything through.
    if (this.cfg.format === ChatFormat.ContentOnly) {
      delta.content += this.buffer;
      this.buffer = '';
      return;
    }

    // PegNative path. Find the earliest "interesting" tag — whichever
    // protocol marker appears first in the buffer wins. We don't commit
    // to a tag until its FULL bytes are present (partial-tail awareness).
    const candidates: Array<{ pos: number; tag: string; target: State; isPreserved?: boolean }> = [];
    // When sectionStart === toolCallStart (Mistral [TOOL_CALLS]), prefer
    // routing to 'section' state — section handles multi-call payloads,
    // tool-call expects exactly one JSON object. The reverse (only
    // toolCallStart present) routes to 'tool-call' as expected.
    const sectionEqualsToolStart =
      !!this.cfg.sectionStart && this.cfg.sectionStart === this.cfg.toolCallStart;
    if (this.cfg.toolCallStart && !sectionEqualsToolStart) {
      const idx = this.buffer.indexOf(this.cfg.toolCallStart);
      if (idx >= 0) candidates.push({ pos: idx, tag: this.cfg.toolCallStart, target: 'tool-call' });
    }
    if (this.cfg.sectionStart) {
      const idx = this.buffer.indexOf(this.cfg.sectionStart);
      if (idx >= 0) candidates.push({ pos: idx, tag: this.cfg.sectionStart, target: 'section' });
    }
    if (this.cfg.thinkingStart) {
      const idx = this.buffer.indexOf(this.cfg.thinkingStart);
      if (idx >= 0) candidates.push({ pos: idx, tag: this.cfg.thinkingStart, target: 'reasoning' });
    }
    // Preserved tokens are silently dropped from content (they're protocol,
    // not user-visible). Treat them like tags with a content-state target.
    for (const tok of this.cfg.preservedTokens) {
      if (!tok) continue;
      // Skip tokens we've already enumerated as actual tags — would double-count.
      if (tok === this.cfg.toolCallStart) continue;
      if (tok === this.cfg.sectionStart) continue;
      if (tok === this.cfg.thinkingStart) continue;
      if (tok === this.cfg.toolCallEnd) continue;
      if (tok === this.cfg.sectionEnd) continue;
      if (tok === this.cfg.thinkingEnd) continue;
      const idx = this.buffer.indexOf(tok);
      if (idx >= 0) candidates.push({ pos: idx, tag: tok, target: 'content', isPreserved: true });
    }

    if (candidates.length === 0) {
      // No complete tag found. Check for a partial tail of ANY interesting
      // tag — if present, hold that suffix in the buffer instead of leaking
      // it as content. Otherwise flush all to content.
      const partial = this.findPartialTagSuffixLength();
      if (partial > 0 && partial <= this.buffer.length) {
        delta.content += this.buffer.slice(0, this.buffer.length - partial);
        this.buffer = this.buffer.slice(this.buffer.length - partial);
      } else {
        delta.content += this.buffer;
        this.buffer = '';
      }
      return;
    }

    candidates.sort((a, b) => a.pos - b.pos);
    const chosen = candidates[0];
    // Emit everything before the tag as content.
    delta.content += this.buffer.slice(0, chosen.pos);
    this.buffer = this.buffer.slice(chosen.pos + chosen.tag.length);

    if (chosen.isPreserved) {
      // Silent consume — stay in content state.
      return;
    }
    this.state = chosen.target;
  }

  // ── Reasoning state ──────────────────────────────────────────────────

  private stepReasoning(delta: ParserDelta): void {
    const end = this.cfg.thinkingEnd || '';
    if (!end) {
      // Config error path — treat all remaining as reasoning until end-of-stream.
      delta.reasoning += this.buffer;
      this.buffer = '';
      return;
    }
    const i = this.buffer.indexOf(end);
    if (i < 0) {
      const partial = this.lengthOfTagSuffixInBuffer(end);
      if (partial > 0) {
        delta.reasoning += this.buffer.slice(0, this.buffer.length - partial);
        this.buffer = this.buffer.slice(this.buffer.length - partial);
      } else {
        delta.reasoning += this.buffer;
        this.buffer = '';
      }
      return;
    }
    delta.reasoning += this.buffer.slice(0, i);
    this.buffer = this.buffer.slice(i + end.length);
    this.state = 'content';
  }

  // ── Tool-call state ──────────────────────────────────────────────────

  private stepToolCall(delta: ParserDelta): void {
    // Skip leading whitespace so brace-counting always starts at `{`.
    const wsLen = this.buffer.length - this.buffer.replace(/^\s+/, '').length;
    if (wsLen > 0) this.buffer = this.buffer.slice(wsLen);

    // GPT-OSS channel format: between `<|channel|>commentary` and `<|end|>`
    // the buffer looks like ` to=<tool_name><|message|>{json}`. The
    // name-then-args path handles this.
    if (this.cfg.argsStyle === 'name-then-args') {
      this.parseNameThenArgs(delta);
      return;
    }

    const obj = this.tryParseJsonObject(this.buffer);
    if (!obj) return; // incomplete — wait for more

    const tc = this.objectToToolCall(obj);
    if (tc) {
      delta.toolCalls.push(tc);
    }
    this.buffer = this.buffer.slice(obj.endPos);

    // Skip optional close tag if present.
    const close = this.cfg.toolCallEnd;
    if (close) {
      // Allow whitespace between JSON and close tag.
      const trimmed = this.buffer.replace(/^\s+/, '');
      if (trimmed.startsWith(close)) {
        const wsBefore = this.buffer.length - trimmed.length;
        this.buffer = this.buffer.slice(wsBefore + close.length);
      }
    }
    this.state = 'content';
  }

  // ── Section state (Mistral-style wrapper) ────────────────────────────

  private stepSection(delta: ParserDelta): void {
    // Skip leading whitespace and optional `[` of array, comma between calls, etc.
    let s = this.buffer.replace(/^[\s,\[]+/, '');
    const skipped = this.buffer.length - s.length;
    if (skipped > 0) this.buffer = this.buffer.slice(skipped);

    // End of section?
    if (this.cfg.sectionEnd && this.buffer.startsWith(this.cfg.sectionEnd)) {
      this.buffer = this.buffer.slice(this.cfg.sectionEnd.length);
      this.state = 'content';
      return;
    }
    if (this.cfg.sectionEnd) {
      const partial = this.lengthOfTagSuffixInBuffer(this.cfg.sectionEnd);
      // If buffer is entirely a partial close tag, hold and wait.
      if (partial === this.buffer.length && partial > 0) return;
    }

    if (this.buffer.length === 0 || !this.buffer.startsWith('{')) {
      // Wait for the next object or for sectionEnd.
      return;
    }
    const obj = this.tryParseJsonObject(this.buffer);
    if (!obj) return;
    const tc = this.objectToToolCall(obj);
    if (tc) delta.toolCalls.push(tc);
    this.buffer = this.buffer.slice(obj.endPos);
  }

  private parseNameThenArgs(delta: ParserDelta): void {
    // Format: ` to=<NAME>...<|message|>{...}<|end|>`
    // Extract name first, then look for `<|message|>` and parse the JSON
    // object after it.
    const TO_MARKER = 'to=';
    const MSG_MARKER = '<|message|>';
    const toIdx = this.buffer.indexOf(TO_MARKER);
    if (toIdx < 0) return;
    const msgIdx = this.buffer.indexOf(MSG_MARKER, toIdx + TO_MARKER.length);
    if (msgIdx < 0) {
      // Wait for `<|message|>` to arrive.
      return;
    }
    const nameRaw = this.buffer.slice(toIdx + TO_MARKER.length, msgIdx).trim();
    // Tool name often shaped like `functions.<name>` in GPT-OSS — strip the
    // namespace if present.
    const name = nameRaw.replace(/^functions\./, '').trim();
    const afterMsg = msgIdx + MSG_MARKER.length;
    const tail = this.buffer.slice(afterMsg);

    // Parse JSON object from tail.
    const obj = this.tryParseJsonObject(tail);
    if (!obj) return;
    const args = obj.data && typeof obj.data === 'object' && !Array.isArray(obj.data)
      ? (obj.data as Record<string, unknown>) : {};
    delta.toolCalls.push({
      index: this.toolCallIndex,
      id: `${this.idPrefix}_${this.toolCallIndex}_${Date.now().toString(36)}`,
      name,
      arguments: args,
      raw: this.buffer.slice(0, afterMsg + obj.endPos),
    });
    this.toolCallIndex++;

    // Advance past JSON. Then skip optional close tag.
    this.buffer = this.buffer.slice(afterMsg + obj.endPos);
    const close = this.cfg.toolCallEnd;
    if (close) {
      const trimmed = this.buffer.replace(/^\s+/, '');
      if (trimmed.startsWith(close)) {
        const wsBefore = this.buffer.length - trimmed.length;
        this.buffer = this.buffer.slice(wsBefore + close.length);
      }
    }
    this.state = 'content';
  }

  // ── JSON object extraction ───────────────────────────────────────────

  /**
   * Find the first complete JSON object in `s` starting from the first `{`.
   * Returns null if the object is still incomplete. Handles string escapes.
   * Adapted from Ollama's findArguments (tools/tools.go:227-336).
   */
  private tryParseJsonObject(s: string): JsonObjectResult | null {
    if (s.length === 0) return null;
    let i = 0;
    while (i < s.length && s[i] !== '{') i++;
    if (i >= s.length) return null;
    const start = i;
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (; i < s.length; i++) {
      const c = s[i];
      if (escaped) { escaped = false; continue; }
      if (c === '\\') { escaped = true; continue; }
      if (c === '"') { inString = !inString; continue; }
      if (inString) continue;
      if (c === '{') depth++;
      else if (c === '}') {
        depth--;
        if (depth === 0) {
          const raw = s.slice(start, i + 1);
          try {
            const data = JSON.parse(raw);
            return { data, raw, endPos: i + 1 };
          } catch {
            // Malformed JSON — give up on this object. Move past start to
            // avoid an infinite re-scan; let the parser drop this brace and
            // continue in content state (the buffer-slice in the caller
            // does not happen unless we return non-null, so we drop the
            // first brace manually here).
            return { data: null, raw, endPos: i + 1 };
          }
        }
      }
    }
    return null;
  }

  /**
   * Convert a parsed JSON object into a ParsedToolCall. Recognizes both the
   * standard shape `{"name":"X","arguments":{...}}` and the legacy shape
   * `{"X":{...}}`. Mirrors Ollama's findObject (tools/tools.go:275-320).
   */
  private objectToToolCall(obj: JsonObjectResult): ParsedToolCall | null {
    const data = obj.data;
    if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
    const o = data as Record<string, unknown>;

    let name: string | null = null;
    let args: Record<string, unknown> = {};

    if (typeof o.name === 'string') {
      name = o.name;
      const a = o.arguments ?? o.parameters;
      if (a && typeof a === 'object' && !Array.isArray(a)) {
        args = a as Record<string, unknown>;
      } else if (typeof a === 'string') {
        try { args = JSON.parse(a); } catch { /* keep empty */ }
      }
    } else {
      // Legacy: a single-key wrapper with the tool name as the key.
      const keys = Object.keys(o);
      if (keys.length === 1) {
        name = keys[0];
        const v = o[keys[0]];
        if (v && typeof v === 'object' && !Array.isArray(v)) {
          args = v as Record<string, unknown>;
        }
      }
    }

    if (!name) return null;

    const tc: ParsedToolCall = {
      index: this.toolCallIndex,
      id: `${this.idPrefix}_${this.toolCallIndex}_${Date.now().toString(36)}`,
      name,
      arguments: args,
      raw: obj.raw,
    };
    this.toolCallIndex++;
    return tc;
  }

  // ── Partial-tag detection ────────────────────────────────────────────

  /**
   * Length of the longest "interesting tag" prefix that the buffer ends
   * with. Used in the content state to hold back potential tag bytes
   * instead of leaking them. E.g. buffer="hi <too" returns 4 (length of
   * "<too", a prefix of "<tool_call>").
   */
  private findPartialTagSuffixLength(): number {
    let best = 0;
    const tags: string[] = [];
    if (this.cfg.toolCallStart) tags.push(this.cfg.toolCallStart);
    if (this.cfg.sectionStart && this.cfg.sectionStart !== this.cfg.toolCallStart) tags.push(this.cfg.sectionStart);
    if (this.cfg.thinkingStart) tags.push(this.cfg.thinkingStart);
    for (const t of this.cfg.preservedTokens) if (t) tags.push(t);
    for (const tag of tags) {
      const len = this.lengthOfTagSuffixInBuffer(tag);
      if (len > best) best = len;
    }
    return best;
  }

  /**
   * Returns N if buffer's last N characters equal the first N of `tag`
   * (for any 1 <= N <= min(len(buffer), len(tag) - 1)). Zero otherwise.
   * Caller may hold N suffix bytes in the buffer waiting for completion.
   */
  private lengthOfTagSuffixInBuffer(tag: string): number {
    const max = Math.min(this.buffer.length, tag.length - 1);
    for (let n = max; n >= 1; n--) {
      if (this.buffer.endsWith(tag.slice(0, n))) return n;
    }
    return 0;
  }
}
