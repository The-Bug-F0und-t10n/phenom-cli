/**
 * Backend detection + capability layer.
 *
 * Both llama-server (from llama.cpp) and Ollama serve OpenAI-compatible
 * `/v1/chat/completions` and we route normal inference through that. This
 * module exists for the few places where the two diverge:
 *
 *   1. Token counting: llama-server has `/tokenize` returning an exact
 *      token array. Ollama has no public tokenize endpoint, so we fall
 *      back to a character/4 estimate.
 *
 *   2. (Future) Truncation detection: llama-server's native `/completion`
 *      response carries `truncated` and `tokens_evaluated`. The OpenAI
 *      compat layer strips them, so getting them requires migrating off
 *      `/v1/chat/completions`. Out of scope for this pass; the type is
 *      shaped to accept it when wired.
 *
 * Detection probes are cheap (`/health` for llama-server, `/api/tags` for
 * Ollama) and the result is cached for the process lifetime. If neither
 * probe succeeds we report 'unknown' and degrade to estimates only.
 *
 * Source references (`.reference/` clones, read-only):
 *   - llama.cpp/tools/server/server.cpp:176   /health
 *   - llama.cpp/tools/server/server.cpp:202   /tokenize
 *   - ollama/server/routes.go:1692            /api/tags
 */

export type BackendKind = 'llama-server' | 'ollama' | 'unknown';

export interface BackendInfo {
  kind: BackendKind;
  baseUrl: string;
  /** llama-server only. Populated from `/props` if available. */
  defaultGenerationSettings?: Record<string, unknown>;
}

export interface BackendCapabilities {
  /** True if `/tokenize` returns exact token IDs. */
  exactTokenize: boolean;
  /**
   * True if responses carry a `truncated` / `tokens_evaluated` field that
   * we can read directly. Always false today; documented for when we wire
   * llama-server's native `/completion`.
   */
  truncationFlag: boolean;
}

const PROBE_TIMEOUT_MS = 1500;

/**
 * Probe the configured baseUrl to determine which backend is listening.
 *
 * Order matters: llama-server is probed FIRST because Ollama's catch-all
 * 404 page can spuriously match weaker llama-server signals. The probes
 * are cheap GETs with a tight timeout — when offline both fail fast and
 * we return 'unknown'.
 */
export async function detectBackend(baseUrl: string): Promise<BackendInfo> {
  const root = baseUrl.replace(/\/+$/, '');

  // 1. llama-server: GET /health → {"status": "ok"} (server.cpp:176)
  //
  // BUG-H4: During the loading window, llama-server starts the HTTP server
  // BEFORE loading the model so it can answer /health requests — but the
  // status during that window is 503 ("Loading model"), not 200 (see
  // .reference/llama.cpp/tools/server/server.cpp:278 and
  // server-context.cpp:3696). The previous check (`llamaHealth?.ok`) was
  // false for 503 and the probe fell through to Ollama's `/api/tags` (also
  // 404), so backend was cached as `unknown` for the rest of the process —
  // disabling /tokenize, /props, and the proper progress label.
  //
  // Treat any 2xx OR 503-with-loading-body as a positive llama-server
  // signal. /props may still be unavailable while loading; that's fine
  // (defaultGenerationSettings stays undefined and getEffectiveContextLimit
  // falls back to the config value).
  const llamaHealth = await safeFetch(`${root}/health`);
  const llamaPositive = await (async (): Promise<boolean> => {
    if (!llamaHealth) return false;
    if (llamaHealth.ok) return true;
    if (llamaHealth.status === 503) {
      const body = await llamaHealth.text().catch(() => '');
      return /loading|warming|model/i.test(body);
    }
    return false;
  })();
  if (llamaPositive) {
    let props: Record<string, unknown> | undefined;
    try {
      const r = await safeFetch(`${root}/props`);
      if (r?.ok) {
        const body = await r.json().catch(() => null);
        if (body && typeof body === 'object') {
          props = body as Record<string, unknown>;
        }
      }
    } catch { /* /props is optional */ }
    return { kind: 'llama-server', baseUrl: root, defaultGenerationSettings: props };
  }

  // 2. Ollama: GET /api/tags → {"models": [...]} (routes.go:1692)
  const ollamaTags = await safeFetch(`${root}/api/tags`);
  if (ollamaTags?.ok) {
    return { kind: 'ollama', baseUrl: root };
  }

  return { kind: 'unknown', baseUrl: root };
}

export function capabilitiesFor(info: BackendInfo): BackendCapabilities {
  switch (info.kind) {
    case 'llama-server':
      return { exactTokenize: true, truncationFlag: false };
    case 'ollama':
    case 'unknown':
      return { exactTokenize: false, truncationFlag: false };
  }
}

/**
 * Tokenize `content` against the backend's tokenizer. Returns the number
 * of tokens, or `null` when the backend can't tokenize (Ollama) — caller
 * should fall back to the character-based estimate in that case.
 *
 * On llama-server: POST /tokenize with `{"content": "..."}` returns
 * `{"tokens": [id, id, ...]}` (verified in
 * .reference/llama.cpp/tools/server/server-context.cpp:4209-4246).
 *
 * Errors are swallowed — tokenization is best-effort. A failed probe must
 * not block inference.
 */
export async function tokenizeCount(
  info: BackendInfo,
  content: string
): Promise<number | null> {
  if (info.kind !== 'llama-server') return null;
  if (!content) return 0;
  try {
    const res = await safeFetch(`${info.baseUrl}/tokenize`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      // BUG-M2: include BOS/special tokens to match how the server actually
      // tokenizes a chat-templated prompt; under-counting was contributing
      // to compaction-threshold drift.
      body: JSON.stringify({ content, add_special: true, with_pieces: false })
    });
    if (!res?.ok) return null;
    const body = await res.json() as { tokens?: number[] };
    if (!body || !Array.isArray(body.tokens)) return null;
    return body.tokens.length;
  } catch {
    return null;
  }
}

async function safeFetch(url: string, init?: RequestInit): Promise<Response | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
