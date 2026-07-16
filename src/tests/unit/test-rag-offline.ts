// Offline RAG smoke test: chunker on a real source file + IndexStore round-trip.
// Skips the embeddings/search path — that one needs OLLAMA_HOST and is exercised
// by an online E2E run of `rag_index` + `rag_search`.
//
// Run: tsx src/tests/unit/test-rag-offline.ts

import path from 'path';
import os from 'os';
import { promises as fs } from 'fs';

import { chunkFile } from '../../rag/chunker.js';
import { IndexStore } from '../../rag/index-store.js';

function expect(cond: boolean, msg: string): void {
  if (!cond) { console.error('FAIL:', msg); process.exit(1); }
}

(async () => {
  const projectRoot = path.resolve(process.cwd());

  // 1) Chunker on a TS file (TS grammar is known-good).
  const target = path.join(projectRoot, 'src/rag/chunker.ts');
  const chunks = await chunkFile(target, projectRoot);
  expect(chunks.length > 0, 'chunker: expected at least one chunk from chunker.ts');
  expect(chunks.every(c => c.startLine >= 1 && c.endLine >= c.startLine), 'chunker: line ranges invalid');
  expect(chunks.every(c => c.embedText.includes('file:')), 'chunker: embedText missing header');
  expect(chunks.some(c => c.kind === 'function' || c.kind === 'class_declaration' || c.kind === 'interface_declaration'), 'chunker: expected AST chunks (function/class/interface), got only window?');
  console.log(`chunker: ${chunks.length} chunks from chunker.ts (kinds: ${[...new Set(chunks.map(c => c.kind))].join(', ')})`);

  // 2) IndexStore round-trip in a temp dir.
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-rag-'));
  try {
    const dim = 8;
    const store = IndexStore.empty(tmp, 'mock-model', dim);
    const vecs: Float32Array[] = [];
    for (let i = 0; i < 3; i++) {
      const v = new Float32Array(dim);
      for (let j = 0; j < dim; j++) v[j] = (i + 1) * 0.1 + j * 0.01;
      vecs.push(v);
    }
    store.vectors = vecs;
    store.manifest.chunks = vecs.map((_, i) => ({
      id: i,
      filePath: `fake/file-${i}.ts`,
      startLine: 1,
      endLine: 10,
      kind: 'function',
      name: `f${i}`,
      language: 'typescript'
    }));
    store.manifest.files['fake/file-0.ts'] = { sha: 'aaa', chunkIds: [0, 1] };
    store.manifest.files['fake/file-1.ts'] = { sha: 'bbb', chunkIds: [2] };
    await store.save();

    const reloaded = await IndexStore.load(tmp);
    expect(!!reloaded, 'index-store: failed to reload');
    expect(reloaded!.manifest.model === 'mock-model', 'index-store: model mismatch after reload');
    expect(reloaded!.manifest.dim === dim, 'index-store: dim mismatch');
    expect(reloaded!.vectors.length === 3, 'index-store: vector count mismatch');
    expect(reloaded!.manifest.chunks.length === 3, 'index-store: chunk records lost');
    // bit-for-bit vector equality
    for (let i = 0; i < 3; i++) {
      for (let j = 0; j < dim; j++) {
        expect(reloaded!.vectors[i][j] === vecs[i][j], `index-store: vector[${i}][${j}] altered`);
      }
    }
    const sz = reloaded!.size();
    expect(sz.files === 2 && sz.chunks === 3, `index-store: size mismatch ${JSON.stringify(sz)}`);
    console.log(`index-store: round-trip OK (files=${sz.files}, chunks=${sz.chunks}, bytes=${sz.bytes})`);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }

  console.log('\n✅ RAG offline smoke OK');
})();
