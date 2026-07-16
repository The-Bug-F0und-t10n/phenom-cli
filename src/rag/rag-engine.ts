// RagEngine — orchestrates chunking + embedding + cosine search.
//
// Indexing strategy: walk `git ls-files` (so .gitignore is honored for free),
// hash each file, re-embed only files whose hash changed since the last
// index. Deleted files drop out. The whole index lives under
// .phenom-context/rag/.

import { execFile } from 'child_process';
import { promisify } from 'util';
import { createHash } from 'crypto';
import { promises as fs } from 'fs';
import path from 'path';

import { EmbeddingsClient } from './embeddings.js';
import { chunkFile, type Chunk } from './chunker.js';
import { IndexStore, type ChunkRecord } from './index-store.js';

const execFileAsync = promisify(execFile);

const EMBED_BATCH = 16;

export interface IndexStats {
  filesScanned: number;
  filesReused: number;
  filesReindexed: number;
  filesRemoved: number;
  chunksTotal: number;
  durationMs: number;
}

export interface SearchHit {
  filePath: string;
  startLine: number;
  endLine: number;
  kind: string;
  name: string;
  language: string;
  score: number;          // cosine, in [-1, 1] — closer to 1 = better
  snippet: string;        // a short head of the chunk text
}

function cosine(a: Float32Array, b: Float32Array): number {
  let dot = 0, na = 0, nb = 0;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i++) {
    dot += a[i] * b[i];
    na  += a[i] * a[i];
    nb  += b[i] * b[i];
  }
  if (na === 0 || nb === 0) return 0;
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}

function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex');
}

async function gitListedFiles(projectRoot: string): Promise<string[]> {
  // `git ls-files` returns tracked files + untracked-but-not-ignored
  // when given --others --exclude-standard. Honors .gitignore for free.
  const { stdout } = await execFileAsync('git', [
    'ls-files', '--cached', '--others', '--exclude-standard'
  ], { cwd: projectRoot, maxBuffer: 16 * 1024 * 1024 });
  return stdout.split('\n').map(s => s.trim()).filter(Boolean);
}

const INDEXABLE_EXT = new Set([
  '.ts','.tsx','.mts','.cts','.js','.mjs','.cjs','.jsx',
  '.rs','.java','.c','.h','.cpp','.cc','.cxx','.hpp','.hh',
  '.py','.go','.rb','.php',
  '.md','.txt','.toml','.yaml','.yml','.json','.sh','.sql'
]);

function isIndexable(rel: string): boolean {
  const ext = path.extname(rel).toLowerCase();
  if (!ext) return false;
  if (!INDEXABLE_EXT.has(ext)) return false;
  // Skip lockfiles / generated.
  const base = path.basename(rel);
  if (base === 'package-lock.json' || base === 'yarn.lock' || base === 'pnpm-lock.yaml') return false;
  if (rel.startsWith('node_modules/') || rel.startsWith('dist/') || rel.startsWith('.phenom-context/') || rel.startsWith('.reference/')) return false;
  return true;
}

export class RagEngine {
  readonly projectRoot: string;
  readonly client: EmbeddingsClient;
  private store: IndexStore | null = null;

  constructor(projectRoot: string, client?: EmbeddingsClient) {
    this.projectRoot = path.resolve(projectRoot);
    this.client = client ?? new EmbeddingsClient();
  }

  /** Loads the persisted index, or null if none exists or model/dim mismatch. */
  async loadIfCompatible(): Promise<IndexStore | null> {
    const store = await IndexStore.load(this.projectRoot).catch(() => null);
    if (!store) return null;
    if (store.manifest.model !== this.client.model) return null;
    this.store = store;
    return store;
  }

  async status(): Promise<{ present: boolean; model: string; files: number; chunks: number; bytes: number; updatedAt: string | null }> {
    const store = await this.loadIfCompatible();
    if (!store) {
      return { present: false, model: this.client.model, files: 0, chunks: 0, bytes: 0, updatedAt: null };
    }
    const sz = store.size();
    return { present: true, model: store.manifest.model, files: sz.files, chunks: sz.chunks, bytes: sz.bytes, updatedAt: store.manifest.updatedAt };
  }

  async index(opts: { force?: boolean; onProgress?: (msg: string) => void } = {}): Promise<IndexStats> {
    const t0 = Date.now();
    const log = opts.onProgress ?? (() => {});

    const files = (await gitListedFiles(this.projectRoot)).filter(isIndexable);

    // Probe embedding dim with a tiny ping (only when we have no store).
    let store = opts.force ? null : await this.loadIfCompatible();
    if (!store) {
      log(`probing embedding model: ${this.client.model}`);
      const probe = await this.client.embed('probe');
      store = IndexStore.empty(this.projectRoot, this.client.model, probe.length);
    }

    let filesReused = 0, filesReindexed = 0;
    const seen = new Set<string>();
    const newChunks: { record: ChunkRecord; vec: Float32Array }[] = [];
    const keepChunks: { record: ChunkRecord; vec: Float32Array }[] = [];

    for (const rel of files) {
      seen.add(rel);
      const abs = path.join(this.projectRoot, rel);
      let buf: Buffer;
      try { buf = await fs.readFile(abs); } catch { continue; }
      const sha = sha256(buf.toString('utf-8'));

      const cached = store.manifest.files[rel];
      if (cached && cached.sha === sha && !opts.force) {
        filesReused++;
        for (const id of cached.chunkIds) {
          const rec = store.manifest.chunks[id];
          if (rec && store.vectors[id]) keepChunks.push({ record: rec, vec: store.vectors[id] });
        }
        continue;
      }

      const chunks = await chunkFile(abs, this.projectRoot);
      if (!chunks.length) {
        // Empty / binary / too large — drop any prior entry.
        delete store.manifest.files[rel];
        continue;
      }
      log(`embedding ${rel} (${chunks.length} chunks)`);

      const vecs: Float32Array[] = [];
      for (let i = 0; i < chunks.length; i += EMBED_BATCH) {
        const batch = chunks.slice(i, i + EMBED_BATCH);
        const got = await this.client.embedBatch(batch.map(c => c.embedText));
        for (const v of got) vecs.push(v);
      }
      // Stage; we'll assign final ids after the keep+new merge.
      for (let i = 0; i < chunks.length; i++) {
        const c = chunks[i];
        newChunks.push({
          record: {
            id: -1,
            filePath: c.filePath,
            startLine: c.startLine,
            endLine: c.endLine,
            kind: c.kind,
            name: c.name,
            language: c.language
          },
          vec: vecs[i]
        });
      }
      // Remember which file these chunks belong to (filled in later with final ids).
      store.manifest.files[rel] = { sha, chunkIds: [] };
      filesReindexed++;
    }

    // Drop files that no longer exist.
    const removedFiles: string[] = [];
    for (const rel of Object.keys(store.manifest.files)) {
      if (!seen.has(rel)) {
        removedFiles.push(rel);
        delete store.manifest.files[rel];
      }
    }

    // Merge keep + new into final chunk list, renumber ids, and rebuild file→ids map.
    const allChunks = [...keepChunks, ...newChunks];
    const fileChunkIds: Record<string, number[]> = {};
    const finalRecords: ChunkRecord[] = [];
    const finalVectors: Float32Array[] = [];
    for (let i = 0; i < allChunks.length; i++) {
      const rec: ChunkRecord = { ...allChunks[i].record, id: i };
      finalRecords.push(rec);
      finalVectors.push(allChunks[i].vec);
      (fileChunkIds[rec.filePath] ??= []).push(i);
    }
    store.manifest.chunks = finalRecords;
    store.vectors = finalVectors;
    for (const rel of Object.keys(store.manifest.files)) {
      store.manifest.files[rel].chunkIds = fileChunkIds[rel] ?? [];
    }

    await store.save();
    this.store = store;

    return {
      filesScanned: files.length,
      filesReused,
      filesReindexed,
      filesRemoved: removedFiles.length,
      chunksTotal: finalRecords.length,
      durationMs: Date.now() - t0
    };
  }

  async search(query: string, k = 8): Promise<SearchHit[]> {
    if (!this.store) {
      this.store = await this.loadIfCompatible();
      if (!this.store) {
        throw new Error('Índice RAG ausente ou modelo incompatível. Rode `rag_index` primeiro.');
      }
    }
    if (!this.store.vectors.length) return [];

    const qVec = await this.client.embed(query);
    const scored: SearchHit[] = [];

    for (let i = 0; i < this.store.vectors.length; i++) {
      const score = cosine(qVec, this.store.vectors[i]);
      const rec = this.store.manifest.chunks[i];
      scored.push({
        filePath: rec.filePath,
        startLine: rec.startLine,
        endLine: rec.endLine,
        kind: rec.kind,
        name: rec.name,
        language: rec.language,
        score,
        snippet: ''  // filled below for the survivors only — avoids reading files we don't return
      });
    }

    scored.sort((a, b) => b.score - a.score);
    const top = scored.slice(0, k);

    // Lazily attach snippets from disk for the survivors.
    await Promise.all(top.map(async hit => {
      try {
        const abs = path.join(this.projectRoot, hit.filePath);
        const text = await fs.readFile(abs, 'utf-8');
        const lines = text.split('\n').slice(hit.startLine - 1, hit.endLine);
        let snip = lines.join('\n').replace(/\s+$/, '');
        if (snip.length > 480) snip = snip.slice(0, 477) + '...';
        hit.snippet = snip;
      } catch {
        hit.snippet = '';
      }
    }));

    return top;
  }
}
