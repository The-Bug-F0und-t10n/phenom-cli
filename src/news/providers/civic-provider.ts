/**
 * Civic alerts provider — fetches public-API civic data (weather, air
 * quality, public health) for a given city.
 *
 * Sources implemented:
 *   - Open-Meteo (weather forecast)     — no auth, lat/lon
 *   - Open-Meteo Air (air quality)      — no auth, lat/lon
 *   - InfoDengue (dengue alerts)        — no auth, requires IBGE geocode
 *
 * Each source returns a list of CivicAlerts. The provider aggregates and
 * groups them into CivicCategory[] for the renderer. Network failures from
 * one source are logged as briefing warnings and never block the others —
 * meteorology should still appear even if InfoDengue is down.
 */

import type { CityLocation, CivicAlert, CivicCategory } from '../types.js';

const FETCH_TIMEOUT_MS = 12000;

async function fetchJson<T>(url: string, timeoutMs: number = FETCH_TIMEOUT_MS): Promise<T | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': 'phenom-cli/1.1 (civic-briefing)' },
      signal: controller.signal
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// ── Open-Meteo (weather) ────────────────────────────────────────────────

interface OpenMeteoResponse {
  current?: {
    temperature_2m?: number;
    apparent_temperature?: number;
    relative_humidity_2m?: number;
    precipitation?: number;
    weather_code?: number;
    wind_speed_10m?: number;
  };
  daily?: {
    time?: string[];
    weather_code?: number[];
    temperature_2m_max?: number[];
    temperature_2m_min?: number[];
    precipitation_sum?: number[];
  };
}

/**
 * WMO weather codes → human description. Trimmed to the codes Open-Meteo
 * actually emits; unknown codes get a generic "tempo encoberto".
 */
const WMO_CODE_LABELS: Record<number, string> = {
  0: 'céu limpo',
  1: 'predominantemente limpo',
  2: 'parcialmente nublado',
  3: 'nublado',
  45: 'névoa',
  48: 'névoa com geada',
  51: 'garoa leve',
  53: 'garoa moderada',
  55: 'garoa intensa',
  61: 'chuva fraca',
  63: 'chuva moderada',
  65: 'chuva forte',
  71: 'neve fraca',
  73: 'neve moderada',
  75: 'neve forte',
  80: 'pancadas de chuva',
  81: 'pancadas de chuva moderadas',
  82: 'pancadas de chuva violentas',
  95: 'trovoada',
  96: 'trovoada com granizo',
  99: 'trovoada com granizo intenso'
};

function severityFromWeatherCode(code: number | undefined): CivicAlert['severity'] {
  if (code === undefined) return 'info';
  if (code >= 95) return 'alert';                    // thunderstorm
  if (code >= 80 || (code >= 65 && code <= 75)) return 'warning';  // strong rain/snow
  return 'info';
}

async function fetchWeather(loc: CityLocation): Promise<CivicAlert[]> {
  const url = new URL('https://api.open-meteo.com/v1/forecast');
  url.searchParams.set('latitude', String(loc.lat));
  url.searchParams.set('longitude', String(loc.lon));
  url.searchParams.set('current', 'temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m');
  url.searchParams.set('daily', 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum');
  url.searchParams.set('timezone', 'auto');
  url.searchParams.set('forecast_days', '3');

  const data = await fetchJson<OpenMeteoResponse>(url.toString());
  if (!data?.current) return [];

  const cur = data.current;
  const codeLabel = WMO_CODE_LABELS[cur.weather_code ?? -1] || 'tempo variável';

  const nowAlert: CivicAlert = {
    service: 'Condição atual',
    description: `${codeLabel} · ${cur.temperature_2m?.toFixed(0) ?? '?'}°C ` +
                 `(sensação ${cur.apparent_temperature?.toFixed(0) ?? '?'}°C) · ` +
                 `umidade ${cur.relative_humidity_2m?.toFixed(0) ?? '?'}% · ` +
                 `vento ${cur.wind_speed_10m?.toFixed(0) ?? '?'} km/h`,
    source: 'Open-Meteo',
    severity: severityFromWeatherCode(cur.weather_code),
    category: 'meteorology'
  };

  const alerts: CivicAlert[] = [nowAlert];

  // Forecast — one alert per day, up to 3
  const daily = data.daily;
  if (daily?.time && daily.weather_code && daily.temperature_2m_max && daily.temperature_2m_min) {
    for (let i = 0; i < Math.min(3, daily.time.length); i++) {
      const dayCode = daily.weather_code[i];
      const max = daily.temperature_2m_max[i];
      const min = daily.temperature_2m_min[i];
      const precip = daily.precipitation_sum?.[i] ?? 0;
      const label = i === 0 ? 'Hoje' : i === 1 ? 'Amanhã' : daily.time[i];
      alerts.push({
        service: `Previsão · ${label}`,
        description: `${WMO_CODE_LABELS[dayCode] || 'tempo variável'} · ` +
                     `${min?.toFixed(0)}°C → ${max?.toFixed(0)}°C` +
                     (precip > 0 ? ` · chuva acumulada ${precip.toFixed(1)} mm` : ''),
        source: 'Open-Meteo',
        severity: severityFromWeatherCode(dayCode),
        category: 'meteorology',
        observedAt: daily.time[i]
      });
    }
  }

  return alerts;
}

// ── Open-Meteo Air (air quality) ────────────────────────────────────────

interface OpenMeteoAirResponse {
  current?: {
    european_aqi?: number;
    us_aqi?: number;
    pm10?: number;
    pm2_5?: number;
    ozone?: number;
    nitrogen_dioxide?: number;
  };
}

function severityFromAqi(aqi: number | undefined): CivicAlert['severity'] {
  if (aqi === undefined) return 'info';
  // European AQI scale (1-5+): 1-2 good, 3 moderate, 4 poor, 5+ very poor
  if (aqi >= 5) return 'alert';
  if (aqi >= 4) return 'warning';
  if (aqi >= 3) return 'info';
  return 'normal';
}

function describeAqi(aqi: number | undefined): string {
  if (aqi === undefined) return 'sem dados';
  if (aqi >= 5) return 'muito ruim';
  if (aqi >= 4) return 'ruim';
  if (aqi >= 3) return 'moderada';
  if (aqi >= 2) return 'razoável';
  return 'boa';
}

async function fetchAirQuality(loc: CityLocation): Promise<CivicAlert[]> {
  const url = new URL('https://air-quality-api.open-meteo.com/v1/air-quality');
  url.searchParams.set('latitude', String(loc.lat));
  url.searchParams.set('longitude', String(loc.lon));
  url.searchParams.set('current', 'european_aqi,us_aqi,pm10,pm2_5,ozone,nitrogen_dioxide');
  url.searchParams.set('timezone', 'auto');
  url.searchParams.set('forecast_days', '1');

  const data = await fetchJson<OpenMeteoAirResponse>(url.toString());
  if (!data?.current) return [];

  const cur = data.current;
  const aqi = cur.european_aqi;
  return [{
    service: 'Qualidade do ar',
    description: `${describeAqi(aqi)} (AQI europeu ${aqi ?? '?'}) · ` +
                 `PM2.5 ${cur.pm2_5?.toFixed(1) ?? '?'} µg/m³ · ` +
                 `PM10 ${cur.pm10?.toFixed(1) ?? '?'} µg/m³ · ` +
                 `O₃ ${cur.ozone?.toFixed(0) ?? '?'} µg/m³`,
    source: 'Open-Meteo Air',
    severity: severityFromAqi(aqi),
    category: 'air_quality'
  }];
}

// ── InfoDengue (dengue alerts — requires IBGE geocode) ──────────────────

interface InfoDengueEntry {
  SE?: number;          // week
  data_iniSE?: string;  // ISO date string
  casos_est?: number;
  nivel?: number;       // alert level 1-4
  receptivo?: number;
}

function severityFromDengueLevel(level: number | undefined): CivicAlert['severity'] {
  if (!level) return 'info';
  if (level >= 4) return 'alert';
  if (level >= 3) return 'warning';
  if (level >= 2) return 'info';
  return 'normal';
}

async function fetchDengue(loc: CityLocation): Promise<CivicAlert[]> {
  if (!loc.geocode) return []; // silently skip when we don't have the IBGE code

  const url = new URL('https://info.dengue.mat.br/api/alertcity');
  url.searchParams.set('geocode', loc.geocode);
  url.searchParams.set('disease', 'dengue');
  url.searchParams.set('format', 'json');
  // InfoDengue requires ew_start, ew_end and ey_start, ey_end. Easiest is to
  // pull the last 4 weeks of the current year.
  const now = new Date();
  const year = now.getUTCFullYear();
  const week = isoWeek(now);
  url.searchParams.set('ew_start', String(Math.max(1, week - 3)));
  url.searchParams.set('ew_end', String(week));
  url.searchParams.set('ey_start', String(year));
  url.searchParams.set('ey_end', String(year));

  const data = await fetchJson<InfoDengueEntry[]>(url.toString());
  if (!Array.isArray(data) || data.length === 0) return [];

  // Take the most recent week (highest SE).
  const latest = data.reduce((a, b) => ((a.SE ?? 0) > (b.SE ?? 0) ? a : b));
  const cases = Math.round(latest.casos_est ?? 0);
  return [{
    service: 'Dengue · semana epidemiológica',
    description: `nível ${latest.nivel ?? '?'} · ~${cases} casos estimados · ` +
                 `receptividade ${latest.receptivo ?? '?'}`,
    source: 'InfoDengue',
    severity: severityFromDengueLevel(latest.nivel),
    category: 'public_health',
    observedAt: latest.data_iniSE
  }];
}

function isoWeek(d: Date): number {
  const date = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  date.setUTCDate(date.getUTCDate() + 4 - (date.getUTCDay() || 7));
  const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1));
  return Math.ceil(((date.getTime() - yearStart.getTime()) / 86400000 + 1) / 7);
}

// ── Aggregator ──────────────────────────────────────────────────────────

interface FetchResult {
  categories: CivicCategory[];
  warnings: string[];
}

/**
 * Fetch all civic data sources in parallel. Individual failures become
 * warnings in the returned briefing — never throws.
 */
export async function fetchAllCivic(loc: CityLocation): Promise<FetchResult> {
  const warnings: string[] = [];

  const wrap = async (label: string, fn: () => Promise<CivicAlert[]>): Promise<CivicAlert[]> => {
    try {
      return await fn();
    } catch (err: any) {
      warnings.push(`${label}: ${err?.message || 'falha ao buscar'}`);
      return [];
    }
  };

  const [weather, air, dengue] = await Promise.all([
    wrap('Open-Meteo (tempo)', () => fetchWeather(loc)),
    wrap('Open-Meteo (ar)', () => fetchAirQuality(loc)),
    wrap('InfoDengue', () => fetchDengue(loc))
  ]);

  // Group by category. We preserve a stable order: civil_defense first
  // (most urgent), then meteorology, air_quality, public_health, etc.
  const buckets = new Map<string, CivicAlert[]>();
  for (const alert of [...weather, ...air, ...dengue]) {
    const list = buckets.get(alert.category) || [];
    list.push(alert);
    buckets.set(alert.category, list);
  }

  const order: Array<CivicAlert['category']> = [
    'civil_defense', 'meteorology', 'air_quality', 'public_health',
    'utilities', 'mobility', 'city_hall', 'other'
  ];
  const categories: CivicCategory[] = [];
  for (const key of order) {
    const alerts = buckets.get(key);
    if (alerts && alerts.length > 0) categories.push({ key, alerts });
  }

  return { categories, warnings };
}
