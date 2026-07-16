/**
 * Smoke tests for the news + civic-briefing module. Mocks out network
 * calls so the suite stays offline-clean.
 */

import { strict as assert } from 'node:assert';
import os from 'node:os';
import path from 'node:path';
import { promises as fs } from 'node:fs';
import { TtlCache } from '../../news/cache.js';
import { renderNewspaper } from '../../news/newspaper-view.js';
import type { NewsBriefing } from '../../news/types.js';

const tests: Array<{ name: string; fn: () => Promise<void> | void }> = [];
function test(name: string, fn: () => Promise<void> | void) { tests.push({ name, fn }); }
let passed = 0;

// ── TtlCache ───────────────────────────────────────────────────────────

test('TtlCache returns null on miss', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-cache-'));
  try {
    const cache = new TtlCache<string>(path.join(tmp, 'cache.json'));
    assert.equal(await cache.get('missing'), null);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('TtlCache set + get round-trips a value', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-cache-'));
  try {
    const cache = new TtlCache<{ x: number }>(path.join(tmp, 'cache.json'));
    await cache.set('k', { x: 42 }, 60);
    const got = await cache.get('k');
    assert.deepEqual(got, { x: 42 });
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('TtlCache expires entries past TTL', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-cache-'));
  try {
    const cache = new TtlCache<string>(path.join(tmp, 'cache.json'));
    const t0 = 1_000_000;
    await cache.set('k', 'value', 60, t0);
    // Inside TTL (59s later) → still fresh.
    assert.equal(await cache.get('k', t0 + 59_000), 'value');
    // Past TTL → null.
    assert.equal(await cache.get('k', t0 + 61_000), null);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('TtlCache survives a fresh instance on the same file', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-cache-'));
  try {
    const file = path.join(tmp, 'cache.json');
    const a = new TtlCache<string>(file);
    await a.set('k', 'persisted', 60);
    const b = new TtlCache<string>(file);
    assert.equal(await b.get('k'), 'persisted');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

// ── renderNewspaper ────────────────────────────────────────────────────

function emptyBriefing(): NewsBriefing {
  return {
    location: { city: 'Londrina', displayName: 'Londrina, Paraná, Brasil', lat: -23.31, lon: -51.16, geocode: '4113700' },
    civic: [],
    news: [],
    generatedAt: Date.UTC(2026, 4, 21, 12, 0),
    warnings: []
  };
}

test('renderNewspaper outputs a masthead with PHENOM DAILY', () => {
  const out = renderNewspaper(emptyBriefing(), { width: 80 });
  assert.ok(out.includes('PHENOM DAILY'), 'expected PHENOM DAILY in masthead');
  assert.ok(out.includes('Londrina'), 'expected location in subheader');
});

test('renderNewspaper places critical alerts above the fold', () => {
  const br = emptyBriefing();
  br.civic = [
    {
      key: 'meteorology',
      alerts: [
        { service: 'Condição atual', description: 'tempestade', severity: 'alert', category: 'meteorology', source: 'Open-Meteo' },
        { service: 'Previsão · Hoje', description: 'chuva moderada', severity: 'info', category: 'meteorology', source: 'Open-Meteo' }
      ]
    }
  ];
  const out = renderNewspaper(br, { width: 80 });
  const criticalIdx = out.indexOf('AVISOS CRÍTICOS');
  const sectionIdx = out.indexOf('Meteorologia');
  assert.ok(criticalIdx >= 0, 'expected critical block');
  assert.ok(sectionIdx >= 0, 'expected section');
  assert.ok(criticalIdx < sectionIdx, 'critical block should appear BEFORE the regular section');
});

test('renderNewspaper omits critical block when no alerts have severity=alert', () => {
  const br = emptyBriefing();
  br.civic = [{
    key: 'meteorology',
    alerts: [{ service: 'Condição', severity: 'info', category: 'meteorology' }]
  }];
  const out = renderNewspaper(br, { width: 80 });
  assert.ok(!out.includes('AVISOS CRÍTICOS'), 'should NOT render critical block without alert-severity items');
});

test('renderNewspaper shows warnings under "Avisos" footer', () => {
  const br = emptyBriefing();
  br.warnings = ['InfoDengue: timeout após 12s'];
  const out = renderNewspaper(br, { width: 80 });
  assert.ok(out.includes('Avisos'), 'expected Avisos section');
  assert.ok(out.includes('InfoDengue: timeout'), 'expected the warning text');
});

test('renderNewspaper deduplicates source list in footnotes', () => {
  const br = emptyBriefing();
  br.civic = [{
    key: 'meteorology',
    alerts: [
      { service: 'A', severity: 'info', category: 'meteorology', source: 'Open-Meteo' },
      { service: 'B', severity: 'info', category: 'meteorology', source: 'Open-Meteo' }
    ]
  }];
  const out = renderNewspaper(br, { width: 80 });
  const matches = (out.match(/Open-Meteo/g) || []).length;
  // The string appears in the sources list AND in any alert that references
  // it inside its description. We just want it to be listed ONCE in
  // "Fontes" — the strip-and-count works because the alert.service ('A'/'B')
  // doesn't repeat the source name. So we expect exactly 1 occurrence.
  assert.equal(matches, 1, `expected source listed once in footnotes, got ${matches}`);
});

async function main() {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (e: any) {
      failures++;
      console.log(`  ❌ ${name}\n     ${e?.message || e}`);
    }
  }
  console.log(`News module tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
}

main();
