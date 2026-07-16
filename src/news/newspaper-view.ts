/**
 * Newspaper view — coherent terminal layout for civic + news briefings.
 *
 * Visual hierarchy (designed for ~80-120 col terminals):
 *
 *   ┌────────────────────────────────────────────────────────────┐
 *   │                    PHENOM DAILY · <date>                   │  ← masthead
 *   │                  <city> · <weather glance>                 │
 *   └────────────────────────────────────────────────────────────┘
 *
 *   ╔═ AVISOS CRÍTICOS ══════════════════════════════════════════╗   ← above the fold
 *   ║   ● <alert 1>                                              ║   (severity=alert)
 *   ║   ● <alert 2>                                              ║
 *   ╚════════════════════════════════════════════════════════════╝
 *
 *   ── Meteorologia ──────────────────────────────────────────────   ← category section
 *   ▸ Condição atual: <description>
 *   ▸ Previsão · Hoje: <description>
 *   ▸ Previsão · Amanhã: <description>
 *
 *   ── Qualidade do ar ──────────────────────────────────────────
 *   ▸ <description>
 *
 *   ── Saúde pública ────────────────────────────────────────────
 *   ▸ <description>
 *
 *   ── Fontes ───────────────────────────────────────────────────   ← footnotes
 *   · Open-Meteo · Open-Meteo Air · InfoDengue
 *
 * Differences from the Python news_layout.py reference:
 *   - Critical alerts get an "above the fold" framed block before everything
 *     else, regardless of which category they're in. Makes scanning easy.
 *   - Single masthead instead of separate news/civic headers.
 *   - Sources collected at the bottom (footnotes) instead of repeated inline
 *     per item — less noise.
 *   - Width is computed from the terminal, not hard-coded 80.
 *   - Severity drives both colour AND glyph (● for alert, ▲ for warning,
 *     ▸ for info, · for normal) so the visual signal works even without
 *     colour support.
 */

import chalk from 'chalk';
import type {
  CityLocation,
  CivicAlert,
  CivicCategory,
  CivicCategoryKey,
  NewsBriefing,
  NewsCategoryKey,
  NewsItem
} from './types.js';
import { formatNewsDate } from './headline-extractor.js';

const DEFAULT_WIDTH = 80;
const MIN_WIDTH = 40;
const MAX_WIDTH = 120;

const CIVIC_LABELS: Record<CivicCategoryKey, string> = {
  meteorology:   'Meteorologia',
  air_quality:   'Qualidade do ar',
  public_health: 'Saúde pública',
  civil_defense: 'Defesa civil',
  utilities:     'Serviços essenciais',
  mobility:      'Mobilidade urbana',
  city_hall:     'Prefeitura',
  other:         'Outros'
};

const CIVIC_GLYPHS: Record<CivicCategoryKey, string> = {
  meteorology:   '⛅',
  air_quality:   '🌬',
  public_health: '🏥',
  civil_defense: '🚨',
  utilities:     '💧',
  mobility:      '🚌',
  city_hall:     '🏛',
  other:         '📌'
};

const NEWS_LABELS: Record<NewsCategoryKey, string> = {
  politics:        'Política',
  health:          'Saúde',
  education:       'Educação',
  sports:          'Esportes',
  economy:         'Economia',
  culture:         'Cultura',
  security:        'Segurança',
  technology:      'Tecnologia',
  infrastructure:  'Infraestrutura',
  environment:     'Meio Ambiente',
  general:         'Geral'
};

const NEWS_GLYPHS: Record<NewsCategoryKey, string> = {
  politics:        '🏛',
  health:          '🏥',
  education:       '📚',
  sports:          '⚽',
  economy:         '💰',
  culture:         '🎭',
  security:        '🚔',
  technology:      '💡',
  infrastructure:  '🏗',
  environment:     '🌿',
  general:         '📰'
};

/** Severity-driven glyph — picked so the rendering still reads in mono. */
function severityGlyph(severity: CivicAlert['severity']): string {
  switch (severity) {
    case 'alert':   return '●';
    case 'warning': return '▲';
    case 'info':    return '▸';
    default:        return '·';
  }
}

function severityColour(severity: CivicAlert['severity']): (s: string) => string {
  switch (severity) {
    case 'alert':   return (s) => chalk.red.bold(s);
    case 'warning': return (s) => chalk.yellow(s);
    case 'info':    return (s) => chalk.cyan(s);
    default:        return (s) => chalk.gray(s);
  }
}

function clampWidth(w: number | undefined): number {
  if (!w || !Number.isFinite(w)) return DEFAULT_WIDTH;
  return Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, Math.floor(w)));
}

function rule(width: number, char: string = '─'): string {
  return char.repeat(width);
}

function center(text: string, width: number): string {
  const visible = text.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, '');
  const pad = Math.max(0, Math.floor((width - visible.length) / 2));
  return ' '.repeat(pad) + text;
}

function formatDate(epochMs: number): string {
  const d = new Date(epochMs);
  return d.toLocaleDateString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long', year: 'numeric' });
}

// ── Masthead ────────────────────────────────────────────────────────────

function renderMasthead(briefing: NewsBriefing, width: number): string[] {
  const top    = '╭' + rule(width - 2, '─') + '╮';
  const bottom = '╰' + rule(width - 2, '─') + '╯';

  const titleText = chalk.bold('PHENOM DAILY') + chalk.dim('  ·  ') +
                    chalk.cyan(formatDate(briefing.generatedAt));
  const subtitleText = briefing.location
    ? chalk.gray(`${briefing.location.displayName}`)
    : chalk.dim('localização não definida');

  // Pad each line to width-2 (account for the bordering │).
  const innerWidth = width - 2;
  const titleLine    = '│' + center(titleText,    innerWidth) + '│';
  const subtitleLine = '│' + center(subtitleText, innerWidth) + '│';

  return [top, titleLine, subtitleLine, bottom];
}

// ── Above the fold (critical alerts) ────────────────────────────────────

function renderAboveTheFold(critical: CivicAlert[], width: number): string[] {
  if (critical.length === 0) return [];

  const inner = width - 4; // ║ + space + ... + space + ║
  const top    = chalk.red.bold('╔═ AVISOS CRÍTICOS ' + rule(width - 19, '═') + '╗');
  const bottom = chalk.red.bold('╚' + rule(width - 2, '═') + '╝');
  const lines = [top];
  for (const alert of critical) {
    const glyph = chalk.red.bold(severityGlyph(alert.severity));
    const body = `${glyph} ${chalk.bold(alert.service)}` +
                 (alert.description ? chalk.gray(' · ' + alert.description) : '');
    // Wrap to inner width using simple word splits.
    const wrapped = wrapText(body, inner);
    for (const w of wrapped) {
      lines.push(chalk.red.bold('║') + ' ' + padRightVisible(w, inner) + ' ' + chalk.red.bold('║'));
    }
  }
  lines.push(bottom);
  return lines;
}

// ── Category sections ───────────────────────────────────────────────────

function renderCategorySection(cat: CivicCategory, width: number): string[] {
  const glyph = CIVIC_GLYPHS[cat.key] || CIVIC_GLYPHS.other;
  const label = CIVIC_LABELS[cat.key] || cat.key;
  const header = chalk.cyan(`── ${glyph} ${label} `) + chalk.cyan(rule(Math.max(3, width - 6 - label.length - 2), '─'));

  const body: string[] = [header];
  for (const alert of cat.alerts) {
    const colour = severityColour(alert.severity);
    const glyphS = colour(severityGlyph(alert.severity));
    const service = chalk.bold(alert.service);
    let line = `  ${glyphS} ${service}`;
    if (alert.description) line += chalk.gray(' · ' + alert.description);
    body.push(...wrapText(line, width).map((l, idx) => idx === 0 ? l : '    ' + l));
  }
  body.push('');
  return body;
}

// ── News section ───────────────────────────────────────────────────────

function renderNewsSection(key: NewsCategoryKey, items: NewsItem[], width: number): string[] {
  const glyph = NEWS_GLYPHS[key] || NEWS_GLYPHS.general;
  const label = NEWS_LABELS[key] || key;
  const headerPrefix = `── ${glyph} ${label} `;
  const header = chalk.magenta(headerPrefix) +
                 chalk.magenta(rule(Math.max(3, width - visibleLen(headerPrefix)), '─'));

  const body: string[] = [header];
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    // Numbered title in bold so the eye scans the headlines first.
    const number = chalk.cyan(`${String(i + 1).padStart(2, ' ')}.`);
    const titleLines = wrapText(`${number} ${chalk.bold(it.title)}`, width - 2);
    for (let j = 0; j < titleLines.length; j++) {
      body.push('  ' + titleLines[j]);
    }
    // Summary: dim, indented under the title.
    if (it.summary) {
      const sumLines = wrapText(it.summary, width - 8);
      for (const line of sumLines) {
        body.push(chalk.gray('      ' + line));
      }
    }
    // Meta line: source · date. Only when at least one is present.
    const date = it.date ? formatNewsDate(it.date) : '';
    const metaParts: string[] = [];
    if (it.source) metaParts.push(it.source);
    if (date) metaParts.push(date);
    if (metaParts.length > 0) {
      body.push(chalk.dim('      ' + metaParts.join(' · ')));
    }
    // Separator between items so the visual rhythm is clear.
    if (i < items.length - 1) body.push('');
  }
  body.push('');
  return body;
}

// ── Footnotes (sources) ────────────────────────────────────────────────

function renderFootnotes(briefing: NewsBriefing, width: number): string[] {
  const sources = new Set<string>();
  for (const cat of briefing.civic) for (const a of cat.alerts) if (a.source) sources.add(a.source);
  for (const cat of briefing.news)  for (const n of cat.items)  if (n.source) sources.add(n.source);

  const lines: string[] = [];
  if (sources.size > 0) {
    lines.push(chalk.dim(`── Fontes ` + rule(Math.max(3, width - 10), '─')));
    lines.push(chalk.dim('  · ' + Array.from(sources).join(' · ')));
  }
  if (briefing.warnings.length > 0) {
    lines.push('');
    lines.push(chalk.yellow('── Avisos ') + chalk.yellow(rule(Math.max(3, width - 10), '─')));
    for (const w of briefing.warnings) {
      lines.push(chalk.yellow(`  ! ${w}`));
    }
  }
  return lines;
}

// ── Main entry point ───────────────────────────────────────────────────

export interface RenderOptions {
  /** Terminal width. Defaults to process.stdout.columns or 80. */
  width?: number;
  /** Set false to skip the "above the fold" critical block. */
  showCritical?: boolean;
  /** Set false to render only critical alerts (compact mode). */
  showSections?: boolean;
  /** Set false to skip sources/warnings at the bottom. */
  showFootnotes?: boolean;
}

export function renderNewspaper(briefing: NewsBriefing, opts: RenderOptions = {}): string {
  const ttyCols = typeof process !== 'undefined' ? process.stdout?.columns : undefined;
  const width = clampWidth(opts.width ?? ttyCols ?? DEFAULT_WIDTH);
  const out: string[] = [];

  out.push(...renderMasthead(briefing, width));
  out.push('');

  if (opts.showCritical !== false) {
    const critical: CivicAlert[] = [];
    for (const cat of briefing.civic) {
      for (const a of cat.alerts) if (a.severity === 'alert') critical.push(a);
    }
    if (critical.length > 0) {
      out.push(...renderAboveTheFold(critical, width));
      out.push('');
    }
  }

  if (opts.showSections !== false) {
    for (const cat of briefing.civic) {
      if (cat.alerts.length === 0) continue;
      out.push(...renderCategorySection(cat, width));
    }
    // News categories rendered with the same visual grammar as civic
    // sections so the page reads as a coherent newspaper (one
    // typography system, one rhythm).
    for (const newsCat of briefing.news) {
      if (newsCat.items.length === 0) continue;
      out.push(...renderNewsSection(newsCat.key, newsCat.items, width));
    }
  }

  if (opts.showFootnotes !== false) {
    out.push(...renderFootnotes(briefing, width));
  }

  if (briefing.civic.length === 0 && briefing.news.length === 0 && briefing.warnings.length === 0) {
    out.push(chalk.dim('  Nenhuma informação disponível no momento.'));
  }

  return out.join('\n');
}

// ── Utilities ──────────────────────────────────────────────────────────

function stripAnsi(s: string): string {
  return s.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, '');
}

function visibleLen(s: string): number {
  return stripAnsi(s).length;
}

function padRightVisible(s: string, width: number): string {
  const pad = Math.max(0, width - visibleLen(s));
  return s + ' '.repeat(pad);
}

/**
 * Word-wrap that preserves ANSI escapes. Splits on whitespace; if a single
 * "word" (e.g. URL) is longer than width, it's hard-broken.
 */
function wrapText(s: string, width: number): string[] {
  if (visibleLen(s) <= width) return [s];

  const words = s.split(/(\s+)/);
  const lines: string[] = [];
  let buf = '';
  let bufLen = 0;
  for (const w of words) {
    const wLen = visibleLen(w);
    if (bufLen + wLen > width) {
      if (buf) lines.push(buf.trimEnd());
      if (wLen > width) {
        // Hard break a long word.
        let remaining = w;
        while (visibleLen(remaining) > width) {
          lines.push(remaining.slice(0, width));
          remaining = remaining.slice(width);
        }
        buf = remaining;
        bufLen = visibleLen(remaining);
      } else {
        buf = w;
        bufLen = wLen;
      }
    } else {
      buf += w;
      bufLen += wLen;
    }
  }
  if (buf) lines.push(buf.trimEnd());
  return lines;
}
