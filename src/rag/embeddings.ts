// Minimal Ollama embeddings client. Strict about OLLAMA_HOST — refuses to
// fall back to localhost (this project deliberately runs against a remote
// inference host; a silent localhost retry has burned us before).

import { config } from '../config.js';

export interface EmbeddingsClientOptions {
  host?: string;
  model?: string;
  timeoutMs?: number;
}

export class EmbeddingsClient {
  readonly host: string;
  readonly model: string;
  readonly timeoutMs: number;
  private cachedDim: number | null = null;

  constructor(opts: EmbeddingsClientOptions = {}) {
    const host = (opts.host ?? config.ollama.host ?? '').trim();
    if (!host) {
      throw new Error('OLLAMA_HOST não configurado — RAG exige host explícito (ex.: http://inference.local:11434).');
    }
    if (/127\.0\.0\.1|localhost/.test(host) && !process.env.PHENOM_ALLOW_LOCAL_EMBED) {
      throw new Error(`Host de embeddings aponta para localhost (${host}). Configure OLLAMA_HOST para o servidor real ou defina PHENOM_ALLOW_LOCAL_EMBED=1.`);
    }
    this.host = host.replace(/\/+$/, '');
    this.model = opts.model ?? process.env.PHENOM_EMBED_MODEL ?? 'nomic-embed-text';
    this.timeoutMs = opts.timeoutMs ?? 60_000;
  }

  async embed(text: string): Promise<Float32Array> {
    const [vec] = await this.embedBatch([text]);
    return vec;
  }

  async embedBatch(texts: string[]): Promise<Float32Array[]> {
    if (texts.length === 0) return [];

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const res = await fetch(`${this.host}/api/embed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: this.model, input: texts }),
        signal: ctrl.signal
      });
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`embeddings HTTP ${res.status}: ${body.slice(0, 200)}`);
      }
      const json = await res.json() as { embeddings?: number[][]; error?: string };
      if (json.error) throw new Error(`embeddings error: ${json.error}`);
      if (!Array.isArray(json.embeddings) || json.embeddings.length !== texts.length) {
        throw new Error(`embeddings: resposta inválida (esperado ${texts.length} vetores, recebi ${json.embeddings?.length ?? 0})`);
      }
      const out = json.embeddings.map(v => new Float32Array(v));
      if (out[0]) this.cachedDim = out[0].length;
      return out;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Returns the embedding dimensionality once at least one call has succeeded. */
  get dim(): number | null {
    return this.cachedDim;
  }
}
