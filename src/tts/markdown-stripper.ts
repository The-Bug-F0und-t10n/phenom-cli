/**
 * Strip markdown + protocol artifacts so TTS doesn't read syntax aloud.
 *
 * Without this the synth produces literal "asterisco asterisco oi" for `**oi**`,
 * "tres acentos graves" for code fences, and `chalk` color codes leak in as
 * garbage glyphs. Each pattern below was added in response to an observed
 * artefact in real model output, not theoretical — keep it that way; do not
 * pre-emptively widen.
 */
export function stripForTts(input: string): string {
  if (!input) return '';
  let s = input;

  // Strip ANSI escapes (chalk leftovers if the content was lifted from a
  // styled string somewhere upstream).
  s = s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');

  // Strip protocol envelopes that should never reach the user, much less
  // the TTS. Matches the same shapes the renderer guards against.
  s = s.replace(/<tool_call>[\s\S]*?<\/tool_call>\s*/gi, '');
  s = s.replace(
    /\{"type"\s*:\s*"final"\s*,\s*"content"\s*:\s*"((?:[^"\\]|\\.)*)"\s*\}/g,
    (_m, captured: string) => {
      try { return JSON.parse('"' + captured + '"'); } catch { return captured; }
    }
  );
  s = s.replace(/\{"type"\s*:\s*"tool"[\s\S]*?\}\s*/g, '');

  // Code fences -> drop the entire block. TTS reading code is useless.
  s = s.replace(/```[\s\S]*?```/g, ' (bloco de código omitido) ');
  // Inline code -> keep content but drop the backticks (single backtick form).
  s = s.replace(/`([^`]+)`/g, '$1');

  // Images and links: keep the label, drop the URL.
  s = s.replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1');
  s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');

  // Bold / italic markers — keep the word, drop the *. Order matters:
  // double asterisks first, then single.
  s = s.replace(/\*\*([^*]+)\*\*/g, '$1');
  s = s.replace(/__([^_]+)__/g, '$1');
  s = s.replace(/\*([^*\n]+)\*/g, '$1');
  s = s.replace(/(?<!_)_([^_\n]+)_(?!_)/g, '$1');

  // Headings: drop the leading hashes, keep the text.
  s = s.replace(/^#{1,6}\s+/gm, '');

  // Block quotes: drop the leading > .
  s = s.replace(/^>\s+/gm, '');

  // List markers (bullet or numbered) at the start of a line.
  s = s.replace(/^\s*[-*+]\s+/gm, '');
  s = s.replace(/^\s*\d+[.)]\s+/gm, '');

  // Table pipes and horizontal rules — collapse to a sentence break.
  s = s.replace(/^\s*\|.*\|.*$/gm, '');
  s = s.replace(/^\s*[-=]{3,}\s*$/gm, '');

  // Internal phenom labels ("[user]", "[assistant]", "[done]", "[Tool result]")
  // — if present in the text being spoken, drop the bracket part so it
  // reads naturally.
  s = s.replace(/^\[(?:user|assistant|done|cancelled|tool result|search|error)\]\s*/gim, '');

  // Collapse repeated whitespace + newlines.
  s = s.replace(/[ \t]+/g, ' ');
  s = s.replace(/\n{2,}/g, '\n');
  s = s.trim();

  return s;
}
