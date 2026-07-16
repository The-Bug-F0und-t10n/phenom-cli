// On-disk RAG index: a JSON manifest + a flat Float32 vectors file.
//
// Why flat-file instead of SQLite/sqlite-vss: at the scale of a single
// project (~few thousand chunks) a naive O(N·dim) cosine in RAM is sub-ms,
// and avoiding the native dep keeps the dev story painless.

import { promises as fs } from 'fs';
import path from 'path';

export interface ChunkRecord {
  id: number;             // index into the vectors file
  filePath: string;       // project-relative
  startLine: number;
  endLine: number;
  kind: string;
  name: string;
  language: string;
}

export interface FileRecord {
  sha: string;
  chunkIds: number[];
}

export interface Manifest {
  version: 1;
  model: string;          // embedding model id
  dim: number;            // vector dimensionality
  createdAt: string;      // ISO
  updatedAt: string;      // ISO
  chunks: ChunkRecord[];
  files: Record<string, FileRecord>;  // keyed by project-relative path
}

const DIR = '.phenom-context/rag';
const MANIFEST_FILE = 'manifest.json';
const VECTORS_FILE = 'vectors.bin';

export class IndexStore {
  readonly projectRoot: string;
  manifest: Manifest;
  vectors: Float32Array[];

  private constructor(projectRoot: string, manifest: Manifest, vectors: Float32Array[]) {
    this.projectRoot = projectRoot;
    this.manifest = manifest;
    this.vectors = vectors;
  }

  static empty(projectRoot: string, model: string, dim: number): IndexStore {
    const now = new Date().toISOString();
    return new IndexStore(projectRoot, {
      version: 1,
      model,
      dim,
      createdAt: now,
      updatedAt: now,
      chunks: [],
      files: {}
    }, []);
  }

  static async load(projectRoot: string): Promise<IndexStore | null> {
    const base = path.join(projectRoot, DIR);
    const manifestPath = path.join(base, MANIFEST_FILE);
    const vectorsPath = path.join(base, VECTORS_FILE);

    let manifestRaw: string;
    try { manifestRaw = await fs.readFile(manifestPath, 'utf-8'); }
    catch { return null; }

    let manifest: Manifest;
    try { manifest = JSON.parse(manifestRaw) as Manifest; }
    catch (e: any) { throw new Error(`manifest.json corrompido: ${e.message}`); }

    if (manifest.version !== 1) {
      throw new Error(`versão de manifesto não suportada: ${manifest.version}`);
    }

    const buf = await fs.readFile(vectorsPath).catch(() => null);
    if (!buf) {
      // Manifest sem vetores → trate como vazio para forçar reindex.
      return IndexStore.empty(projectRoot, manifest.model, manifest.dim);
    }
    const expected = manifest.chunks.length * manifest.dim * 4;
    if (buf.byteLength !== expected) {
      throw new Error(`vectors.bin tamanho ${buf.byteLength} ≠ esperado ${expected} (chunks ${manifest.chunks.length}, dim ${manifest.dim}). Reconstrua o índice.`);
    }

    const vectors: Float32Array[] = new Array(manifest.chunks.length);
    for (let i = 0; i < manifest.chunks.length; i++) {
      const start = i * manifest.dim * 4;
      vectors[i] = new Float32Array(
        buf.buffer.slice(buf.byteOffset + start, buf.byteOffset + start + manifest.dim * 4)
      );
    }
    return new IndexStore(projectRoot, manifest, vectors);
  }

  async save(): Promise<void> {
    const base = path.join(this.projectRoot, DIR);
    await fs.mkdir(base, { recursive: true });

    const tmpManifest = path.join(base, MANIFEST_FILE + '.tmp');
    const tmpVectors = path.join(base, VECTORS_FILE + '.tmp');

    this.manifest.updatedAt = new Date().toISOString();

    // Pack vectors into one contiguous buffer.
    const total = this.manifest.chunks.length * this.manifest.dim;
    const flat = new Float32Array(total);
    for (let i = 0; i < this.vectors.length; i++) {
      flat.set(this.vectors[i], i * this.manifest.dim);
    }
    await fs.writeFile(tmpVectors, Buffer.from(flat.buffer));
    await fs.writeFile(tmpManifest, JSON.stringify(this.manifest, null, 2));

    await fs.rename(tmpVectors, path.join(base, VECTORS_FILE));
    await fs.rename(tmpManifest, path.join(base, MANIFEST_FILE));
  }

  size(): { files: number; chunks: number; bytes: number } {
    const bytes = this.manifest.chunks.length * this.manifest.dim * 4;
    return { files: Object.keys(this.manifest.files).length, chunks: this.manifest.chunks.length, bytes };
  }
}
