/**
 * Build the `<tools>...</tools>` block that gets injected into the system
 * prompt when running in text-protocol mode (no --jinja on the server).
 *
 * The output mirrors the format the Modelfile TEMPLATE emits when llama.cpp
 * --jinja is active — same delimiters, same JSON shape per tool — so the
 * model behaves the same way regardless of which transport is in use. The
 * model emits tool calls as:
 *
 *   <tool_call>
 *   {"name": "...", "arguments": {...}}
 *   </tool_call>
 *
 * and phenom-cli's `parseToolCallOrFinalDetailed` lifts them out of the
 * stream text.
 */

import type { ApiToolDef } from '../api-client.js';

export interface ToolsBlockOptions {
  /** Keep schema descriptions short — long ones bloat the system prompt. */
  maxDescChars?: number;
}

const DEFAULT_MAX_DESC = 280;

export function buildToolsSchemaBlock(tools: ApiToolDef[] | undefined, opts: ToolsBlockOptions = {}): string {
  if (!tools || tools.length === 0) return '';
  const maxDesc = opts.maxDescChars ?? DEFAULT_MAX_DESC;

  const lines: string[] = [
    '',
    '# Tools (text protocol)',
    '',
    'You may call one or more functions. Function signatures are inside <tools></tools>:',
    '<tools>'
  ];

  for (const t of tools) {
    const fn = t.function;
    if (!fn?.name) continue;
    // Compact JSON — single line per tool keeps the block scannable and
    // saves significant tokens compared to pretty-printed multi-line.
    const compact = {
      type: 'function',
      function: {
        name: fn.name,
        description: typeof fn.description === 'string'
          ? (fn.description.length > maxDesc ? fn.description.slice(0, maxDesc - 1) + '…' : fn.description)
          : '',
        parameters: fn.parameters ?? { type: 'object', properties: {} }
      }
    };
    lines.push(JSON.stringify(compact));
  }

  lines.push('</tools>');
  lines.push('');
  lines.push('A tool call is a JSON object inside <tool_call></tool_call> tags. You may write reasoning prose BEFORE the <tool_call> block in the same turn.');
  lines.push('');
  lines.push('<tool_call>');
  lines.push('{"name": "<function-name>", "arguments": {"<arg>": "<value>"}}');
  lines.push('</tool_call>');

  return lines.join('\n');
}
