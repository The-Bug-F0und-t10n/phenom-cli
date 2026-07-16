/**
 * Geocoding — resolve a city name into lat/lon (and IBGE geocode when
 * known). Two-tier strategy:
 *   1. Static map of well-known Brazilian cities (instant, no network)
 *   2. Nominatim (OpenStreetMap) fallback for anything not in the map
 *
 * Ported from civic_apis_config.py:get_city_coordinates with the same
 * normalization rules but using native fetch + AbortController instead of
 * aiohttp.
 */

import type { CityLocation } from './types.js';

/**
 * IBGE municipality codes for major Brazilian cities. Used by providers
 * that need the geocode (e.g. InfoDengue). Cities outside this list still
 * work for lat/lon-based providers; they just skip the geocode-requiring
 * ones.
 */
const IBGE_GEOCODES: Record<string, string> = {
  'londrina': '4113700',
  'curitiba': '4106902',
  'são paulo': '3550308',
  'sao paulo': '3550308',
  'rio de janeiro': '3304557',
  'belo horizonte': '3106200',
  'porto alegre': '4314902',
  'brasília': '5300108',
  'brasilia': '5300108',
  'salvador': '2927408',
  'fortaleza': '2304400',
  'recife': '2611606',
  'manaus': '1302603',
  'goiânia': '5208707',
  'goiania': '5208707',
  'belém': '1501402',
  'belem': '1501402',
  'florianópolis': '4205407',
  'florianopolis': '4205407'
};

function normalizeCity(city: string): string {
  return city.trim().toLowerCase();
}

/**
 * Resolve a city to a CityLocation. Returns null on hard failure
 * (Nominatim unreachable AND city not in static map).
 *
 * No throws — callers always get a Location-or-null; the briefing use case
 * surfaces the failure via warnings instead.
 */
export async function geocodeCity(city: string, timeoutMs: number = 10000): Promise<CityLocation | null> {
  const normalized = normalizeCity(city);
  const knownGeocode = IBGE_GEOCODES[normalized];

  // Try Nominatim regardless — we always need lat/lon for weather APIs.
  // The static map only fills in the IBGE geocode for InfoDengue.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const url = new URL('https://nominatim.openstreetmap.org/search');
    url.searchParams.set('q', `${city}, Brasil`);
    url.searchParams.set('format', 'json');
    url.searchParams.set('limit', '1');

    const res = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        // Nominatim requires a meaningful User-Agent — sending a vague one
        // is an explicit policy violation in their usage docs.
        'User-Agent': 'phenom-cli/1.1 (civic-briefing)'
      },
      signal: controller.signal
    });
    if (!res.ok) return null;

    const data = await res.json() as Array<{ lat: string; lon: string; display_name?: string }>;
    if (!Array.isArray(data) || data.length === 0) return null;

    const first = data[0];
    return {
      city,
      displayName: first.display_name || city,
      lat: parseFloat(first.lat),
      lon: parseFloat(first.lon),
      geocode: knownGeocode,
      country: 'BR'
    };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Returns the IBGE geocode for a known city without making any network
 * call. Useful for callers that already have lat/lon and just want the
 * geocode (e.g. coming from a user profile).
 */
export function lookupIbgeGeocode(city: string): string | undefined {
  return IBGE_GEOCODES[normalizeCity(city)];
}
