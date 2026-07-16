/**
 * RSS news provider — fetches and parses public RSS feeds from Brazilian
 * news sources. Pure regex parser; no XML dep added to the project.
 *
 * Why regex and not a proper XML parser:
 *   - RSS 2.0 has a regular, narrow shape: <item> blocks with a fixed set
 *     of expected child elements (title, link, description, pubDate,
 *     category, guid). The full XML spec (namespaces, DTDs, entities) is
 *     overkill.
 *   - Adding `fast-xml-parser` or similar pulls a 50KB+ dep for one
 *     feature. We can do this in ~80 LOC instead.
 *   - The parser is permissive — malformed XML at the item level skips
 *     that item, doesn't kill the whole feed.
 *
 * What the provider does NOT try to handle:
 *   - Atom feeds (different structure). All listed BR feeds are RSS 2.0.
 *   - RSS embedded in other XML containers via namespaces (rare in BR
 *     news).
 *   - Reading article bodies — we use the RSS `<description>` as the
 *     summary, which is already a short editorial summary from the
 *     publisher.
 */

import type { NewsItem } from '../types.js';
import {
  cleanText,
  parseRssDate,
  truncateSummary
} from '../headline-extractor.js';
import { classifyNews, normalizeRssCategory } from '../classification.js';

const FETCH_TIMEOUT_MS = 12_000;
const SUMMARY_MAX_CHARS = 240;

/**
 * Per-feed config. `categoryHint` is what the feed's editorial focus is
 * (G1 has separate feeds per section); when the RSS item itself doesn't
 * carry a category tag, we fall back to the hint instead of running the
 * keyword classifier. Hint is overridden if the item has a usable tag.
 */
export interface RssFeedConfig {
  name: string;
  url: string;
  categoryHint?: import('../types.js').NewsCategoryKey;
}

/**
 * Curated default list of well-known, free, no-auth Brazilian RSS feeds.
 * Picked for editorial diversity (G1 = mainstream, Folha = print, BBC =
 * international perspective) and topical coverage (politics, economy,
 * tech).
 *
 * Order doesn't affect anything — fetches run in parallel.
 */
export const DEFAULT_BR_FEEDS: RssFeedConfig[] = [
  // G1 — feeds por seção (categoria já vem da própria URL)
  { name: 'G1 Política',     url: 'https://g1.globo.com/rss/g1/politica/',           categoryHint: 'politics' },
  { name: 'G1 Economia',     url: 'https://g1.globo.com/rss/g1/economia/',           categoryHint: 'economy' },
  { name: 'G1 Tecnologia',   url: 'https://g1.globo.com/rss/g1/tecnologia/',         categoryHint: 'technology' },
  { name: 'G1 Saúde',        url: 'https://g1.globo.com/rss/g1/bemestar/',           categoryHint: 'health' },
  { name: 'G1 Educação',     url: 'https://g1.globo.com/rss/g1/educacao/',           categoryHint: 'education' },
  // BBC Brasil — feed unificado, requer classificação por keyword
  { name: 'BBC Brasil',      url: 'https://www.bbc.com/portuguese/index.xml' }
];

// ── Parser ────────────────────────────────────────────────────────────

interface RawItem {
  title?: string;
  link?: string;
  description?: string;
  pubDate?: string;
  category?: string;
  guid?: string;
}

/**
 * Pull <item>...</item> blocks out of an RSS document and extract the
 * sub-fields we care about. Order of children inside <item> is not
 * relied on — each field is matched independently.
 */
function parseRssXml(xml: string): RawItem[] {
  const items: RawItem[] = [];
  const itemPattern = /<item\b[^>]*>([\s\S]*?)<\/item>/gi;
  let match: RegExpExecArray | null;
  while ((match = itemPattern.exec(xml)) !== null) {
    const body = match[1];
    items.push({
      title:       extractField(body, 'title'),
      link:        extractField(body, 'link'),
      description: extractField(body, 'description'),
      pubDate:     extractField(body, 'pubDate'),
      category:    extractField(body, 'category'),
      guid:        extractField(body, 'guid')
    });
  }
  return items;
}

function extractField(body: string, name: string): string | undefined {
  const re = new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)<\\/${name}>`, 'i');
  const m = body.match(re);
  return m ? m[1] : undefined;
}

// ── Fetch a single feed ────────────────────────────────────────────────

async function fetchFeed(feed: RssFeedConfig, timeoutMs: number = FETCH_TIMEOUT_MS): Promise<NewsItem[]> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(feed.url, {
      headers: {
        'User-Agent': 'phenom-cli/1.1 (news-briefing)',
        'Accept': 'application/rss+xml, application/xml, text/xml, */*'
      },
      signal: controller.signal
    });
    if (!res.ok) return [];
    const xml = await res.text();
    return parseRssXml(xml).map(raw => toNewsItem(raw, feed)).filter(Boolean) as NewsItem[];
  } catch {
    return [];
  } finally {
    clearTimeout(timer);
  }
}

function toNewsItem(raw: RawItem, feed: RssFeedConfig): NewsItem | null {
  const title = raw.title ? cleanText(raw.title) : '';
  if (!title) return null; // an item with no title is unusable

  const summary = raw.description ? truncateSummary(raw.description, SUMMARY_MAX_CHARS) : '';
  const link = raw.link ? cleanText(raw.link) : '';
  const date = raw.pubDate ? parseRssDate(raw.pubDate)?.toISOString() : undefined;

  // Resolution order for category:
  //   1. RSS <category> tag (normalized)
  //   2. Feed config hint
  //   3. Keyword classifier as last resort
  const fromTag = raw.category ? normalizeRssCategory(cleanText(raw.category)) : null;
  const category = fromTag ?? feed.categoryHint ?? classifyNews(title, summary);

  return {
    title,
    summary,
    url: link,
    source: feed.name,
    date,
    category
  };
}

// ── Aggregate fetch ───────────────────────────────────────────────────

export interface RssFetchResult {
  items: NewsItem[];
  warnings: string[];
}

/**
 * Fetch every feed in parallel; collect items, deduplicate by URL +
 * normalized title (different feeds often republish the same story),
 * and return a flat list. Failures per-feed surface as warnings — the
 * other feeds still contribute.
 */
export async function fetchAllRssNews(
  feeds: RssFeedConfig[] = DEFAULT_BR_FEEDS,
  perItemCap: number = 12
): Promise<RssFetchResult> {
  const warnings: string[] = [];
  const results = await Promise.all(feeds.map(async (feed) => {
    try {
      const items = await fetchFeed(feed);
      return { feed, items, error: null as string | null };
    } catch (err: any) {
      return { feed, items: [] as NewsItem[], error: err?.message || 'falha ao buscar' };
    }
  }));

  const seen = new Set<string>();
  const merged: NewsItem[] = [];
  for (const r of results) {
    if (r.error) {
      warnings.push(`${r.feed.name}: ${r.error}`);
      continue;
    }
    if (r.items.length === 0) {
      warnings.push(`${r.feed.name}: feed vazio ou inacessível`);
      continue;
    }
    // Per-feed cap so a single chatty feed doesn't dominate the briefing.
    const capped = r.items.slice(0, perItemCap);
    for (const it of capped) {
      const key = dedupeKey(it);
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push(it);
    }
  }

  return { items: merged, warnings };
}

function dedupeKey(item: NewsItem): string {
  // Prefer the URL when present — it's the most reliable identity. Fall
  // back to the title normalised aggressively (lowercase, no punctuation)
  // for items that come with an empty link.
  if (item.url) return item.url.split('?')[0];
  return item.title.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
}
