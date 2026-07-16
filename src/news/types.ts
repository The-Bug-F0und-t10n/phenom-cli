/**
 * Domain types for the news + civic-alerts module.
 *
 * Ported from the reference Python implementation in cli-agent-v2
 * (news_contracts.py + news_layout.py dataclasses), simplified to what we
 * actually use here — no Protocol/legacy callback adapter, since phenom-cli
 * uses the event bus for status updates and structured types throughout.
 */

/**
 * Public-feed news item (web article, press release, etc.).
 * Kept minimal: title + summary + source + date. URL optional for the
 * rendered newspaper view (we don't always want to print URLs).
 */
export interface NewsItem {
  title: string;
  summary?: string;
  url?: string;
  source?: string;
  date?: string;
  category?: NewsCategoryKey;
}

/**
 * Known category keys. The renderer maps these to display labels + glyphs.
 * "general" is the catch-all when classification is ambiguous.
 */
export type NewsCategoryKey =
  | 'politics'
  | 'health'
  | 'education'
  | 'sports'
  | 'economy'
  | 'culture'
  | 'security'
  | 'technology'
  | 'infrastructure'
  | 'environment'
  | 'general';

export interface NewsCategory {
  key: NewsCategoryKey;
  items: NewsItem[];
}

/**
 * A civic alert / public service entry: weather warnings, air quality,
 * disease outbreaks, utility outages, etc.
 *
 * `severity` drives both colour and the "above the fold" placement on the
 * newspaper view — `alert` items always render first, regardless of their
 * category, so a user scanning the briefing sees emergencies immediately.
 */
export interface CivicAlert {
  service: string;
  description?: string;
  source?: string;
  url?: string;
  severity: 'normal' | 'info' | 'warning' | 'alert';
  category: CivicCategoryKey;
  observedAt?: string;
}

export type CivicCategoryKey =
  | 'meteorology'
  | 'air_quality'
  | 'public_health'
  | 'civil_defense'
  | 'utilities'
  | 'mobility'
  | 'city_hall'
  | 'other';

export interface CivicCategory {
  key: CivicCategoryKey;
  alerts: CivicAlert[];
}

/**
 * Geocoded city — output of the geocoding service. `geocode` is the
 * Brazilian IBGE code, only populated for known BR cities; APIs that
 * require it (InfoDengue) gracefully skip when absent.
 */
export interface CityLocation {
  city: string;
  displayName: string;
  lat: number;
  lon: number;
  /** IBGE municipality code, when known. */
  geocode?: string;
  /** Country, defaults to 'BR' for the current providers. */
  country?: string;
}

/**
 * A complete briefing — civic + news combined, ready for the newspaper
 * renderer. `generatedAt` enables cache hits and the masthead date.
 */
export interface NewsBriefing {
  location: CityLocation | null;
  civic: CivicCategory[];
  news: NewsCategory[];
  generatedAt: number; // epoch ms
  warnings: string[];  // soft errors collected during fetch (e.g. "InfoDengue offline")
}

/**
 * Sink interface for status updates during a briefing fetch. Mirrors
 * NewsStatusSink from the Python contracts. In phenom-cli, the default
 * implementation forwards to the event bus.
 */
export interface NewsStatusSink {
  emit(message: string, stage?: string): void;
}

/**
 * No-op sink — used when the caller doesn't need progress updates
 * (e.g. tests, scripted runs).
 */
export const silentSink: NewsStatusSink = {
  emit() {}
};
