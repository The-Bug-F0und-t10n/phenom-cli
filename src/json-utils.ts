/**
 * Robust JSON extraction from LLM responses.
 *
 * The naive extractJson(raw.indexOf('{')) breaks when code content contains
 * literal `{` inside JSON string values (e.g.: {"content": "function foo() { return 1; }"}).
 *
 * This module uses balanced-brace matching to find the correct outermost JSON object.
 */

/**
 * Extract the first balanced `{...}` block from raw LLM text.
 *
 * Walks character-by-character, tracking brace depth.  String literals
 * (including escaped quotes) are skipped so that `{` inside strings
 * does not affect depth tracking.
 *
 * Strips ```json fences and trailing code fences before processing.
 * Ignores any text before the first `{`.
 */
export function extractBalancedJson(raw: string): string {
  const stripped = raw
    .trim()
    .replace(/```json\s*/gi, '')
    .replace(/```\s*/g, '');

  const start = stripped.indexOf('{');
  if (start === -1) return stripped;

  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let i = start; i < stripped.length; i++) {
    const ch = stripped[i];

    if (escaped) {
      escaped = false;
      continue;
    }

    if (inString) {
      if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === '{') depth++;
    if (ch === '}') depth--;

    if (depth === 0) {
      return stripped.slice(start, i + 1);
    }
  }

  // Fallback: no balanced braces found
  return stripped;
}

/**
 * Safe JSON parse — returns null on any failure.
 */
export function safeJsonParse<T = any>(raw: string): T | null {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

/**
 * Extract and parse JSON from an LLM response in one step.
 */
export function extractAndParse<T = any>(raw: string): T | null {
  const cleaned = extractBalancedJson(raw);
  return safeJsonParse<T>(cleaned);
}
