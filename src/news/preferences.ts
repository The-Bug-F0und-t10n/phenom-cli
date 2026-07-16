/**
 * User preferences store for news personalization.
 *
 * Persisted to `.phenom-data/news-preferences.json` so the agent can
 * remember the user's location + interests across sessions. The
 * preferences shape is intentionally small — a few category lists +
 * location — to keep the JSON readable and editable by hand.
 *
 * Apply functions live here too: filterAndRankNews takes a flat list of
 * NewsItem and applies the user's filters/priorities in a single pass.
 */

import { promises as fs } from 'fs';
import path from 'path';
import type { NewsCategoryKey, NewsItem } from './types.js';

export interface NewsPreferences {
  /** Default city for civic briefings when none is passed explicitly. */
  defaultCity?: string;
  /** Categories the user wants emphasized (ranked higher in output). */
  categoriesOfInterest: NewsCategoryKey[];
  /** Categories the user wants hidden. Wins over categoriesOfInterest. */
  blockedCategories: NewsCategoryKey[];
  /** Whitelist of source names (e.g. "G1", "BBC Brasil"). Empty = all sources allowed. */
  preferredSources: string[];
  /** Source names to drop entirely. Wins over preferredSources. */
  blockedSources: string[];
  /** Display language hint. Currently only affects labels in the renderer. */
  language: 'pt' | 'en';
}

export const DEFAULT_PREFERENCES: NewsPreferences = {
  defaultCity: undefined,
  categoriesOfInterest: [],
  blockedCategories: [],
  preferredSources: [],
  blockedSources: [],
  language: 'pt'
};

const VALID_CATEGORIES: NewsCategoryKey[] = [
  'politics', 'health', 'education', 'sports', 'economy',
  'culture', 'security', 'technology', 'infrastructure',
  'environment', 'general'
];

export function isValidCategory(c: string): c is NewsCategoryKey {
  return (VALID_CATEGORIES as string[]).includes(c);
}

// ── Persistence ────────────────────────────────────────────────────────

export class PreferencesStore {
  private readonly filePath: string;
  private memory: NewsPreferences | null = null;

  constructor(filePath: string = path.join(process.cwd(), '.phenom-data', 'news-preferences.json')) {
    this.filePath = filePath;
  }

  async load(): Promise<NewsPreferences> {
    if (this.memory) return this.memory;
    try {
      const raw = await fs.readFile(this.filePath, 'utf-8');
      const parsed = JSON.parse(raw) as Partial<NewsPreferences>;
      this.memory = mergeWithDefaults(parsed);
      return this.memory;
    } catch {
      this.memory = { ...DEFAULT_PREFERENCES };
      return this.memory;
    }
  }

  async save(prefs: NewsPreferences): Promise<void> {
    this.memory = prefs;
    const dir = path.dirname(this.filePath);
    await fs.mkdir(dir, { recursive: true });
    const tmp = this.filePath + '.tmp';
    await fs.writeFile(tmp, JSON.stringify(prefs, null, 2), 'utf-8');
    await fs.rename(tmp, this.filePath);
  }

  /**
   * Convenience mutator — load, apply patch, save. Used by the
   * set_news_preferences tool.
   */
  async update(patch: Partial<NewsPreferences>): Promise<NewsPreferences> {
    const current = await this.load();
    const merged: NewsPreferences = {
      ...current,
      ...patch,
      // Array fields need shallow merge, not full replacement, when patch
      // is a partial (the tool semantics are "add" / "remove" through
      // dedicated helpers; raw replacement happens via .save()).
    };
    await this.save(merged);
    return merged;
  }
}

function mergeWithDefaults(p: Partial<NewsPreferences>): NewsPreferences {
  return {
    defaultCity: p.defaultCity,
    categoriesOfInterest: Array.isArray(p.categoriesOfInterest)
      ? p.categoriesOfInterest.filter(isValidCategory)
      : [],
    blockedCategories: Array.isArray(p.blockedCategories)
      ? p.blockedCategories.filter(isValidCategory)
      : [],
    preferredSources: Array.isArray(p.preferredSources) ? p.preferredSources.map(String) : [],
    blockedSources: Array.isArray(p.blockedSources) ? p.blockedSources.map(String) : [],
    language: p.language === 'en' ? 'en' : 'pt'
  };
}

// ── Filter + rank application ─────────────────────────────────────────

interface FilterReport {
  kept: number;
  droppedByCategory: number;
  droppedBySource: number;
}

/**
 * Apply blocked-category + blocked-source filters to a flat list, then
 * sort with `categoriesOfInterest` items first (in the order they appear
 * in the preference). News items with no category or in 'general' end up
 * at the bottom of the list.
 *
 * Returns the filtered+sorted list plus a small report so callers can
 * surface "12 items dropped by your filters" without having to recompute.
 */
export function filterAndRankNews(items: NewsItem[], prefs: NewsPreferences): { items: NewsItem[]; report: FilterReport } {
  const blockedCat = new Set(prefs.blockedCategories);
  const blockedSrc = new Set(prefs.blockedSources.map(s => s.toLowerCase()));
  const interestOrder = new Map<NewsCategoryKey, number>();
  prefs.categoriesOfInterest.forEach((c, i) => interestOrder.set(c, i));

  let droppedByCategory = 0;
  let droppedBySource = 0;
  const filtered: NewsItem[] = [];

  for (const item of items) {
    if (item.category && blockedCat.has(item.category)) {
      droppedByCategory++;
      continue;
    }
    if (item.source && blockedSrc.has(item.source.toLowerCase())) {
      droppedBySource++;
      continue;
    }
    filtered.push(item);
  }

  // Stable sort: interest categories first (preserving relative order),
  // then everything else in original order.
  filtered.sort((a, b) => {
    const aRank = a.category ? (interestOrder.get(a.category) ?? Infinity) : Infinity;
    const bRank = b.category ? (interestOrder.get(b.category) ?? Infinity) : Infinity;
    if (aRank !== bRank) return aRank - bRank;
    // Same interest rank — keep original order (stable in modern V8).
    return 0;
  });

  return {
    items: filtered,
    report: { kept: filtered.length, droppedByCategory, droppedBySource }
  };
}
