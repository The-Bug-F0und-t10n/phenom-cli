/**
 * Tests for backend-detector.ts. The whole module is HTTP probes against
 * a configured baseUrl; we mock `fetch` per-test so each scenario controls
 * what the "server" answers.
 *
 * Properties exercised:
 *
 *   1. llama-server detection: /health returns ok → kind='llama-server'.
 *   2. Ollama detection: /health 404 + /api/tags ok → kind='ollama'.
 *   3. Both fail: kind='unknown'.
 *   4. tokenizeCount on llama-server hits /tokenize and returns N.
 *   5. tokenizeCount on Ollama returns null (no endpoint).
 *   6. Network/JSON error on /tokenize returns null, not a throw.
 *   7. /props is captured into defaultGenerationSettings when present.
 */

import { strict as assert } from 'node:assert';
import {
  detectBackend,
  tokenizeCount,
  capabilitiesFor
} from '../../backend-detector.js';

const tests: Array<{ name: string; fn: () => Promise<void> | void }> = [];
function test(name: string, fn: () => Promise<void> | void) { tests.push({ name, fn }); }
let passed = 0;

type FetchMock = (url: string, init?: RequestInit) => Promise<Response>;
const realFetch: typeof fetch = globalThis.fetch;

function installFetchMock(mock: FetchMock): void {
  (globalThis as any).fetch = mock as unknown as typeof fetch;
}
function restoreFetch(): void {
  (globalThis as any).fetch = realFetch;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' }
  });
}

// ── 1. llama-server detection ─────────────────────────────────────────

test('detects llama-server via /health', async () => {
  installFetchMock(async (url: string) => {
    if (url.endsWith('/health')) return jsonResponse({ status: 'ok' });
    if (url.endsWith('/props')) return jsonResponse({ n_ctx: 8192 });
    return new Response('', { status: 404 });
  });
  try {
    const info = await detectBackend('http://127.0.0.1:8080');
    assert.equal(info.kind, 'llama-server');
    assert.equal(info.baseUrl, 'http://127.0.0.1:8080');
    assert.deepEqual(info.defaultGenerationSettings, { n_ctx: 8192 });
  } finally {
    restoreFetch();
  }
});

// ── 2. Ollama detection ───────────────────────────────────────────────

test('detects Ollama when /health 404 and /api/tags ok', async () => {
  installFetchMock(async (url: string) => {
    if (url.endsWith('/health')) return new Response('', { status: 404 });
    if (url.endsWith('/api/tags')) return jsonResponse({ models: [{ name: 'foo' }] });
    return new Response('', { status: 404 });
  });
  try {
    const info = await detectBackend('http://127.0.0.1:11434');
    assert.equal(info.kind, 'ollama');
    assert.equal(info.defaultGenerationSettings, undefined);
  } finally {
    restoreFetch();
  }
});

// ── 3. Both fail ──────────────────────────────────────────────────────

test('returns unknown when both probes fail', async () => {
  installFetchMock(async () => new Response('', { status: 500 }));
  try {
    const info = await detectBackend('http://127.0.0.1:9999');
    assert.equal(info.kind, 'unknown');
  } finally {
    restoreFetch();
  }
});

// ── 4. tokenize on llama-server ───────────────────────────────────────

test('tokenizeCount returns length on llama-server', async () => {
  installFetchMock(async (url: string, init?: RequestInit) => {
    assert.equal(url, 'http://srv:8080/tokenize');
    assert.equal(init?.method, 'POST');
    const body = JSON.parse(String(init?.body));
    assert.equal(body.content, 'hello world');
    return jsonResponse({ tokens: [1, 2, 3, 4, 5] });
  });
  try {
    const n = await tokenizeCount({ kind: 'llama-server', baseUrl: 'http://srv:8080' }, 'hello world');
    assert.equal(n, 5);
  } finally {
    restoreFetch();
  }
});

// ── 5. tokenize on Ollama returns null ────────────────────────────────

test('tokenizeCount returns null on Ollama (no endpoint)', async () => {
  let called = false;
  installFetchMock(async () => { called = true; return jsonResponse({}); });
  try {
    const n = await tokenizeCount({ kind: 'ollama', baseUrl: 'http://srv:11434' }, 'hello');
    assert.equal(n, null);
    assert.equal(called, false, 'must not hit network on ollama backend');
  } finally {
    restoreFetch();
  }
});

// ── 6. Network/JSON error returns null ────────────────────────────────

test('tokenizeCount returns null on network error', async () => {
  installFetchMock(async () => { throw new Error('boom'); });
  try {
    const n = await tokenizeCount({ kind: 'llama-server', baseUrl: 'http://srv:8080' }, 'x');
    assert.equal(n, null);
  } finally {
    restoreFetch();
  }
});

test('tokenizeCount returns null on malformed JSON', async () => {
  installFetchMock(async () => new Response('not json', { status: 200 }));
  try {
    const n = await tokenizeCount({ kind: 'llama-server', baseUrl: 'http://srv:8080' }, 'x');
    assert.equal(n, null);
  } finally {
    restoreFetch();
  }
});

test('tokenizeCount on empty string returns 0 without network hit', async () => {
  let called = false;
  installFetchMock(async () => { called = true; return jsonResponse({ tokens: [] }); });
  try {
    const n = await tokenizeCount({ kind: 'llama-server', baseUrl: 'http://srv:8080' }, '');
    assert.equal(n, 0);
    assert.equal(called, false);
  } finally {
    restoreFetch();
  }
});

// ── 7. Capabilities ───────────────────────────────────────────────────

test('capabilitiesFor reports exactTokenize for llama-server only', () => {
  assert.equal(capabilitiesFor({ kind: 'llama-server', baseUrl: 'x' }).exactTokenize, true);
  assert.equal(capabilitiesFor({ kind: 'ollama', baseUrl: 'x' }).exactTokenize, false);
  assert.equal(capabilitiesFor({ kind: 'unknown', baseUrl: 'x' }).exactTokenize, false);
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
  console.log(`Backend detector tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
}

main();
