/**
 * News briefing use case — top-level orchestrator that turns a city name
 * into a rendered newspaper view.
 *
 * Pipeline:
 *   1. Cache lookup (key = normalized city). Skip on hit.
 *   2. Geocode the city (IBGE static map + Nominatim fallback).
 *   3. Fetch civic providers in parallel (weather + air + dengue).
 *   4. Compose NewsBriefing.
 *   5. Cache the briefing (1h TTL by default).
 *   6. Render via the newspaper view.
 *
 * Errors at any step degrade gracefully — missing geocode skips InfoDengue,
 * Nominatim outage falls back to a "location not resolved" briefing with
 * an empty civic list, etc.
 */

import { geocodeCity } from '../news/geocoding.js';
import { TtlCache } from '../news/cache.js';
import { fetchAllCivic } from '../news/providers/civic-provider.js';
import { fetchAllRssNews, DEFAULT_BR_FEEDS, type RssFeedConfig } from '../news/providers/rss-news-provider.js';
import { renderNewspaper, type RenderOptions } from '../news/newspaper-view.js';
import { PreferencesStore, filterAndRankNews } from '../news/preferences.js';
import type { NewsBriefing, NewsCategory, NewsCategoryKey, NewsItem, NewsStatusSink } from '../news/types.js';
import { silentSink } from '../news/types.js';

export interface BriefingOptions {
  /** TTL for the cached briefing in seconds. Default 1h. */
  cacheTtlSec?: number;
  /** Force a fresh fetch even if cache is warm. */
  bypassCache?: boolean;
  /** Render options forwarded to renderNewspaper. */
  render?: RenderOptions;
  /** Inject a custom status sink (defaults to silent). */
  status?: NewsStatusSink;
  /** Inject a custom cache (for tests). */
  cache?: TtlCache<NewsBriefing>;
  /**
   * Pull RSS news headlines in addition to civic data. Default true.
   * When false, the briefing only contains weather/air-quality/health
   * (faster, no external news fetch). Useful for slow connections.
   */
  includeNews?: boolean;
  /**
   * Override the default Brazilian RSS feed list. When omitted, uses
   * DEFAULT_BR_FEEDS (G1 sections + BBC Brasil).
   */
  feeds?: RssFeedConfig[];
  /**
   * Max items per category to keep in the final briefing. Default 5 —
   * keeps the newspaper view scannable. Pass higher for "give me
   * everything" requests.
   */
  itemsPerCategory?: number;
  /** TTL for the RSS cache in seconds. Default 30 minutes (news moves faster than civic). */
  newsCacheTtlSec?: number;
  /** Custom preferences store (for tests). */
  preferences?: PreferencesStore;
}

export interface BriefingResult {
  briefing: NewsBriefing;
  rendered: string;
  fromCache: boolean;
}

export async function runNewsBriefingUseCase(city: string, opts: BriefingOptions = {}): Promise<BriefingResult> {
  const status = opts.status ?? silentSink;
  const cache = opts.cache ?? new TtlCache<NewsBriefing>();
  const cacheKey = `briefing:${city.trim().toLowerCase()}`;
  const ttl = opts.cacheTtlSec ?? 3600;
  const includeNews = opts.includeNews !== false; // default true
  const itemsPerCategory = Math.max(1, Math.min(50, opts.itemsPerCategory ?? 5));
  const newsTtl = opts.newsCacheTtlSec ?? 1800;
  const prefsStore = opts.preferences ?? new PreferencesStore();

  if (!opts.bypassCache) {
    const cached = await cache.get(cacheKey);
    if (cached) {
      status.emit('cache hit', 'cache');
      return {
        briefing: cached,
        rendered: renderNewspaper(cached, opts.render),
        fromCache: true
      };
    }
  }

  status.emit('resolvendo localização', 'geocode');
  const loc = await geocodeCity(city);
  const warnings: string[] = [];
  if (!loc) warnings.push(`Não foi possível resolver "${city}" via Nominatim — verifique conexão ou tente outra grafia.`);

  // Civic + news fetched in PARALLEL (independent pipelines). News needs no
  // location; civic needs the geocoded loc — but both can run concurrently
  // while geocoding happens, since we already awaited geocodeCity above.
  const [civicResult, newsCategories] = await Promise.all([
    loc ? (status.emit('buscando dados cívicos', 'civic'), fetchAllCivic(loc)) : Promise.resolve({ categories: [], warnings: [] }),
    includeNews ? fetchNewsForBriefing(opts, status, prefsStore, itemsPerCategory, cache, newsTtl, opts.bypassCache === true) : Promise.resolve({ categories: [], warnings: [] })
  ]);

  warnings.push(...civicResult.warnings, ...newsCategories.warnings);

  const briefing: NewsBriefing = {
    location: loc,
    civic: civicResult.categories,
    news: newsCategories.categories,
    generatedAt: Date.now(),
    warnings
  };

  if (loc && (civicResult.categories.length > 0 || newsCategories.categories.length > 0)) {
    await cache.set(cacheKey, briefing, ttl);
  }

  return {
    briefing,
    rendered: renderNewspaper(briefing, opts.render),
    fromCache: false
  };
}

/**
 * Helper: fetch RSS news, classify, apply user preferences, group by
 * category. Caches the RAW item list separately (short TTL) so consecutive
 * briefings within the same hour reuse the network round-trips.
 */
async function fetchNewsForBriefing(
  opts: BriefingOptions,
  status: NewsStatusSink,
  prefsStore: PreferencesStore,
  itemsPerCategory: number,
  briefingCache: TtlCache<NewsBriefing>,
  newsTtl: number,
  bypassCache: boolean
): Promise<{ categories: NewsCategory[]; warnings: string[] }> {
  const feeds = opts.feeds ?? DEFAULT_BR_FEEDS;
  // The raw-news cache lives in the SAME TtlCache instance as the briefing
  // cache, just under a different key namespace. Keeps the on-disk file
  // count minimal (one cache file total).
  const rawKey = 'news-raw:' + feeds.map(f => f.url).sort().join('|').slice(0, 64);

  type RawCachedNews = { items: NewsItem[]; warnings: string[]; cachedAt: number };
  const rawCache = briefingCache as unknown as TtlCache<RawCachedNews>;

  let items: NewsItem[];
  let warnings: string[] = [];

  if (!bypassCache) {
    const cached = await rawCache.get(rawKey);
    if (cached) {
      items = cached.items;
      warnings = cached.warnings.slice();
      status.emit('cache hit (notícias)', 'news-cache');
    } else {
      status.emit('buscando manchetes RSS', 'news-fetch');
      const result = await fetchAllRssNews(feeds);
      items = result.items;
      warnings = result.warnings;
      if (items.length > 0) await rawCache.set(rawKey, { items, warnings, cachedAt: Date.now() }, newsTtl);
    }
  } else {
    status.emit('buscando manchetes RSS (sem cache)', 'news-fetch');
    const result = await fetchAllRssNews(feeds);
    items = result.items;
    warnings = result.warnings;
    if (items.length > 0) await rawCache.set(rawKey, { items, warnings, cachedAt: Date.now() }, newsTtl);
  }

  // Apply user preferences (block + rank).
  const prefs = await prefsStore.load();
  const { items: filtered, report } = filterAndRankNews(items, prefs);
  if (report.droppedByCategory > 0 || report.droppedBySource > 0) {
    const parts: string[] = [];
    if (report.droppedByCategory > 0) parts.push(`${report.droppedByCategory} por categoria bloqueada`);
    if (report.droppedBySource > 0) parts.push(`${report.droppedBySource} por fonte bloqueada`);
    status.emit(`Filtros descartaram ${parts.join(' + ')}`, 'news-filter');
  }

  // Group by category, capped per-category. Preserve interest order from
  // the preference (already applied by filterAndRankNews above).
  const byCategory = new Map<NewsCategoryKey, NewsItem[]>();
  for (const item of filtered) {
    const key = item.category ?? 'general';
    const list = byCategory.get(key) || [];
    if (list.length < itemsPerCategory) list.push(item);
    byCategory.set(key, list);
  }

  // Emit categories in interest order first, then everything else in the
  // order it appeared.
  const categories: NewsCategory[] = [];
  const seen = new Set<NewsCategoryKey>();
  for (const interest of prefs.categoriesOfInterest) {
    const items = byCategory.get(interest);
    if (items && items.length > 0) {
      categories.push({ key: interest, items });
      seen.add(interest);
    }
  }
  for (const [key, items] of byCategory) {
    if (seen.has(key)) continue;
    if (items.length > 0) categories.push({ key, items });
  }

  return { categories, warnings };
}
