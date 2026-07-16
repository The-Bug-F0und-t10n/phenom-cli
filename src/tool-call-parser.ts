import { extractBalancedJson, safeJsonParse } from './json-utils.js';
import { ToolLoopParseResult, ToolLoopResponse } from './domain-contracts.js';

export function parseToolCallOrFinal(raw: string): ToolLoopResponse | null {
  return parseToolCallOrFinalDetailed(raw).response;
}

export function parseToolCallOrFinalDetailed(raw: string): ToolLoopParseResult {
  const trimmed = String(raw || '').trim();
  if (!trimmed) return { response: null, strategy: 'empty' };

  const tagged = parseTaggedToolCall(trimmed);
  if (tagged) return { response: tagged, strategy: 'tagged_tool_call' };

  const primary = parsePrimaryJsonBlock(trimmed);
  if (primary) {
    // If the first parse is a "final" answer but a valid tool call also exists in
    // embedded JSON blocks, prefer the tool path to avoid false completion.
    if (primary.type === 'final') {
      const scanned = parseEmbeddedJsonBlocks(trimmed);
      if (scanned?.type === 'tool') {
        return { response: scanned, strategy: 'embedded_json_scan' };
      }
    }
    return { response: primary, strategy: 'primary_json' };
  }

  const scanned = parseEmbeddedJsonBlocks(trimmed);
  if (scanned) return { response: scanned, strategy: 'embedded_json_scan' };

  const cleaned = stripRendererArtifacts(trimmed);
  if (cleaned && cleaned !== trimmed) {
    const reparsed = parseToolCallOrFinalDetailed(cleaned);
    if (reparsed.response) return { ...reparsed, strategy: 'cleaned_retry' };
  }

  if (looksLikeBrokenToolJson(trimmed)) {
    return { response: null, strategy: 'invalid_broken_tool_json' };
  }
  if (trimmed.length > 5) {
    return { response: { type: 'final', content: trimmed }, strategy: 'plain_text_final' };
  }
  return { response: null, strategy: 'empty' };
}

function parseTaggedToolCall(raw: string): ToolLoopResponse | null {
  // BUG-M6: previously only `<tool_call>...</tool_call>` (the qwen3 /
  // hermes-style marker) was recognized. llama.cpp's PEG grammars
  // (.reference/llama.cpp/common/chat.cpp `common_chat_format`) emit four
  // distinct markers depending on the model template, and the model loops
  // when its native marker is dropped to `looksLikeBrokenToolJson() → null`.
  //
  //   - hermes_2_pro:   <tool_call>{...}</tool_call>  OR  <tool_call>[{...},{...}]</tool_call>
  //   - llama_3_x:      [TOOL_CALLS][{...}, ...][/TOOL_CALLS]   (also accepts no closing tag)
  //   - granite:        <|tool_call|>[{...}, ...]
  //   - mistral_nemo:   [TOOL_CALLS] [{...}, ...]              (no closing tag)
  //
  // Try each marker; the first whose body parses as a tool descriptor wins.
  const markers: Array<{ rx: RegExp; group: number }> = [
    { rx: /<tool_call>([\s\S]*?)<\/tool_call>/i, group: 1 },
    { rx: /\[TOOL_CALLS\]\s*([\s\S]*?)\s*\[\/TOOL_CALLS\]/i, group: 1 },
    { rx: /\[TOOL_CALLS\]\s*(\[[\s\S]*?\]|\{[\s\S]*?\})/i, group: 1 },
    { rx: /<\|tool_call\|>\s*(\[[\s\S]*?\]|\{[\s\S]*?\})/i, group: 1 },
  ];

  for (const { rx, group } of markers) {
    const match = raw.match(rx);
    if (!match) continue;
    const body = match[group].trim();
    if (!body) continue;

    // Body may be either a single object or an array of objects (hermes2pro
    // / llama3 / granite all allow batched tool calls). Take the FIRST tool
    // call when it's an array — the loop processes one tool at a time.
    const parsed = safeJsonParse<unknown>(body);
    const first = Array.isArray(parsed) ? parsed[0] : parsed;
    const obj = (first && typeof first === 'object') ? (first as Record<string, unknown>) : null;
    if (!obj) continue;

    const fn = toObject(obj.function);
    const name = String(obj.name || obj.toolName || fn.name || '').trim();
    if (!name) continue;

    return {
      type: 'tool',
      toolName: name,
      args: toArgsRecord(obj.arguments ?? obj.args ?? obj.parameters ?? fn.arguments ?? {}),
    };
  }
  return null;
}

function parsePrimaryJsonBlock(raw: string): ToolLoopResponse | null {
  const extracted = extractBalancedJson(raw);
  const parsed = safeJsonParse<Record<string, unknown>>(extracted);
  if (!parsed || typeof parsed !== 'object') return null;

  if (parsed.type === 'tool' && typeof parsed.toolName === 'string' && parsed.toolName.trim()) {
    return { type: 'tool', toolName: parsed.toolName.trim(), args: toArgsRecord(parsed.args || {}) };
  }

  if (parsed.type === 'final' && typeof parsed.content === 'string') {
    return { type: 'final', content: parsed.content };
  }

  // OpenAI-like function object: {"name":"...", "arguments":{...}}
  if (
    typeof parsed.name === 'string' &&
    parsed.name.trim() &&
    (parsed.arguments !== undefined || parsed.args !== undefined || parsed.parameters !== undefined)
  ) {
    return {
      type: 'tool',
      toolName: parsed.name.trim(),
      args: toArgsRecord(parsed.arguments ?? parsed.args ?? parsed.parameters ?? {}),
    };
  }

  return null;
}

function parseEmbeddedJsonBlocks(raw: string): ToolLoopResponse | null {
  const toolCandidates: ToolLoopResponse[] = [];
  const finalCandidates: ToolLoopResponse[] = [];
  let pos = 0;

  while (pos < raw.length) {
    const idx = raw.indexOf('{', pos);
    if (idx === -1) break;

    const block = extractBalancedJson(raw.slice(idx));
    if (block && block.startsWith('{')) {
      const parsed = safeJsonParse<Record<string, unknown>>(block);
      if (parsed?.type === 'tool' && typeof parsed.toolName === 'string' && parsed.toolName.trim()) {
        toolCandidates.push({ type: 'tool', toolName: parsed.toolName, args: toArgsRecord(parsed.args || {}) });
      } else if (parsed?.type === 'final' && typeof parsed.content === 'string' && parsed.content.trim()) {
        finalCandidates.push({ type: 'final', content: parsed.content });
      }
      pos = idx + block.length;
      continue;
    }

    pos = idx + 1;
  }

  if (toolCandidates.length > 0) return toolCandidates[0];
  if (finalCandidates.length > 0) return finalCandidates[0];
  return null;
}

function stripRendererArtifacts(raw: string): string {
  return raw
    .replace(/^\[assistant\]\s*/gi, '')
    .replace(/^\[reasoning\]\s*/gi, '')
    .replace(/^#.*\n*/gm, '')
    .replace(/```json\s*/gi, '')
    .replace(/```\s*/g, '')
    .trim();
}

function looksLikeBrokenToolJson(raw: string): boolean {
  // BUG-M6: include the additional markers parseTaggedToolCall now accepts
  // so an unclosed/garbled native marker is reported as "broken" (and the
  // loop retries) rather than falling through to plain_text_final.
  return (
    raw.includes('{"type"') ||
    raw.includes('"toolName"') ||
    raw.includes('"tool_call"') ||
    raw.includes('[TOOL_CALLS]') ||
    raw.includes('<|tool_call|>') ||
    /<tool_call>/i.test(raw)
  );
}

function toObject(value: unknown): Record<string, unknown> {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

function toArgsRecord(value: unknown): Record<string, unknown> {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) return {};
    const parsed = safeJsonParse<unknown>(trimmed);
    return toObject(parsed);
  }
  return toObject(value);
}
