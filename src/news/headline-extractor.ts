/**
 * Pure helpers for cleaning up news data extracted from RSS / web sources.
 *
 * No I/O — these are deterministic transformations: decode HTML entities,
 * strip CDATA / tags, truncate summaries, normalize dates. Kept separate
 * so they can be tested in isolation and reused by future providers
 * (web scraping, NewsAPI, etc.).
 */

// ── HTML entity decoder ────────────────────────────────────────────────

const HTML_ENTITIES: Record<string, string> = {
  '&amp;':  '&',
  '&lt;':   '<',
  '&gt;':   '>',
  '&quot;': '"',
  '&apos;': "'",
  '&#39;':  "'",
  '&nbsp;': ' ',
  '&ndash;': '–',
  '&mdash;': '—',
  '&hellip;': '…',
  '&laquo;': '«',
  '&raquo;': '»',
  '&aacute;': 'á',
  '&eacute;': 'é',
  '&iacute;': 'í',
  '&oacute;': 'ó',
  '&uacute;': 'ú',
  '&Aacute;': 'Á',
  '&Eacute;': 'É',
  '&Iacute;': 'Í',
  '&Oacute;': 'Ó',
  '&Uacute;': 'Ú',
  '&ccedil;': 'ç',
  '&Ccedil;': 'Ç',
  '&atilde;': 'ã',
  '&otilde;': 'õ',
  '&Atilde;': 'Ã',
  '&Otilde;': 'Õ',
  '&acirc;': 'â',
  '&ecirc;': 'ê',
  '&ocirc;': 'ô',
  '&Acirc;': 'Â',
  '&Ecirc;': 'Ê',
  '&Ocirc;': 'Ô'
};

export function decodeHtmlEntities(s: string): string {
  // Named entities (must run before numeric, since the regex below would
  // otherwise grab "&amp;#39;" → "&" + leftover "#39;").
  let out = s;
  for (const [entity, char] of Object.entries(HTML_ENTITIES)) {
    if (out.includes(entity)) out = out.split(entity).join(char);
  }
  // Numeric entities: &#NNNN; and &#xHHHH;
  out = out.replace(/&#(\d+);/g, (_, dec) => {
    const code = parseInt(dec, 10);
    return Number.isFinite(code) ? String.fromCodePoint(code) : _;
  });
  out = out.replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => {
    const code = parseInt(hex, 16);
    return Number.isFinite(code) ? String.fromCodePoint(code) : _;
  });
  return out;
}

// ── CDATA stripper ────────────────────────────────────────────────────

/**
 * RSS frequently wraps text in <![CDATA[...]]>. Strip the wrapper so the
 * payload is the plain text. Multiple CDATA sections in the same string
 * are all unwrapped.
 */
export function stripCdata(s: string): string {
  return s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1');
}

// ── HTML tag stripper ─────────────────────────────────────────────────

/**
 * Remove all HTML tags. We do NOT preserve link text or anything fancy —
 * RSS descriptions usually have <p>, <a href>, <img>, etc. and we just
 * want the readable content.
 */
export function stripHtmlTags(s: string): string {
  return s.replace(/<[^>]+>/g, '');
}

// ── Whitespace normalizer ─────────────────────────────────────────────

/**
 * Collapse runs of whitespace (including newlines, tabs, NBSPs) to a
 * single space, and trim. Useful for titles that come from RSS with
 * embedded line breaks.
 */
export function normalizeWhitespace(s: string): string {
  return s.replace(/\s+/g, ' ').trim();
}

// ── All-in-one clean ──────────────────────────────────────────────────

/**
 * The standard cleanup pipeline for any text from RSS: strip CDATA →
 * strip HTML → decode entities → normalize whitespace.
 */
export function cleanText(s: string): string {
  return normalizeWhitespace(decodeHtmlEntities(stripHtmlTags(stripCdata(s))));
}

// ── Summary truncation ────────────────────────────────────────────────

/**
 * Truncate to maxChars, breaking at the last whitespace before the limit
 * when possible (so we don't slice mid-word). Adds "…" suffix when
 * actually truncated.
 */
export function truncateSummary(s: string, maxChars: number = 200): string {
  const clean = cleanText(s);
  if (clean.length <= maxChars) return clean;
  const cut = clean.lastIndexOf(' ', maxChars - 1);
  const boundary = cut > maxChars * 0.6 ? cut : maxChars - 1;
  return clean.slice(0, boundary).trimEnd() + '…';
}

// ── Date normalization ────────────────────────────────────────────────

/**
 * Parse RFC-822 (RSS standard) or ISO 8601 dates into a JS Date.
 * Returns null on unparseable input — caller decides whether to drop the
 * item, show "data desconhecida", or fall back to the current time.
 */
export function parseRssDate(s: string): Date | null {
  if (!s) return null;
  const cleaned = cleanText(s);
  // Both RFC-822 ("Wed, 21 May 2025 14:00:00 GMT") and ISO 8601 are
  // accepted by Date.parse in modern Node.
  const ms = Date.parse(cleaned);
  if (Number.isFinite(ms)) return new Date(ms);
  return null;
}

/**
 * Format a date for display in the newspaper view: "21 mai · 14:30".
 * Falls back to the raw input when parsing fails so the user still sees
 * SOMETHING (even if ugly) instead of an empty field.
 */
export function formatNewsDate(d: Date | string | null | undefined): string {
  if (!d) return '';
  const date = d instanceof Date ? d : parseRssDate(d);
  if (!date) return typeof d === 'string' ? d : '';
  const day = String(date.getDate()).padStart(2, '0');
  const monthMap = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
  const month = monthMap[date.getMonth()] || '';
  const hh = String(date.getHours()).padStart(2, '0');
  const mm = String(date.getMinutes()).padStart(2, '0');
  return `${day} ${month} · ${hh}:${mm}`;
}
