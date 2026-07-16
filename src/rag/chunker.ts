// File → semantic chunks. Uses parse_ast when the language is supported
// (chunks = top-level symbols, which are conceptually coherent units),
// falls back to a fixed-size sliding window otherwise.

import { promises as fs } from 'fs';
import path from 'path';
import { detectLanguage, parseSource, type SupportedLanguage } from '../ast-parser.js';

export interface Chunk {
  filePath: string;       // project-relative
  startLine: number;      // 1-based, inclusive
  endLine: number;        // 1-based, inclusive
  kind: string;           // 'function' | 'class' | 'window' | etc.
  name: string;           // symbol name, or "block-N" for window chunks
  language: string;
  text: string;           // raw source for the chunk
  embedText: string;      // text actually sent to the embedder (incl. header)
}

const WINDOW_LINES = 60;
const WINDOW_OVERLAP = 10;
const MAX_FILE_BYTES = 1_000_000;
const MAX_CHUNK_CHARS = 8_000;  // hard cap on embedText length

function looksBinary(buf: Buffer): boolean {
  const sample = buf.subarray(0, Math.min(buf.length, 4096));
  for (const b of sample) if (b === 0) return true;
  return false;
}

function sliceLines(allLines: string[], start1: number, end1: number): string {
  // 1-based inclusive → 0-based slice end-exclusive
  const s = Math.max(0, start1 - 1);
  const e = Math.min(allLines.length, end1);
  return allLines.slice(s, e).join('\n');
}

function buildEmbedText(filePath: string, lang: string, kind: string, name: string, code: string): string {
  // Header gives the embedder identifier + structural context cheaply;
  // nomic-embed-text scores much better on retrieval when the chunk
  // includes "file: X / kind: Y / name: Z" alongside the code.
  const truncatedCode = code.length > MAX_CHUNK_CHARS - 200
    ? code.slice(0, MAX_CHUNK_CHARS - 200) + '\n…[truncated]'
    : code;
  return `file: ${filePath}\nlanguage: ${lang}\nkind: ${kind}\nname: ${name}\n---\n${truncatedCode}`;
}

function chunksFromAst(
  filePath: string,
  source: string,
  lang: SupportedLanguage,
  allLines: string[]
): Chunk[] {
  let summary;
  try {
    summary = parseSource(source, lang);
  } catch {
    return [];
  }
  const chunks: Chunk[] = [];

  // Classes/types — emit one chunk per class (with all its methods inside),
  // since splitting per-method tends to over-fragment and loses class context.
  for (const c of summary.classes) {
    const endLine = c.endLine ?? guessSymbolEnd(allLines, c.line, c.children?.length ? 200 : 80);
    const code = sliceLines(allLines, c.line, endLine);
    chunks.push({
      filePath,
      startLine: c.line,
      endLine,
      kind: c.kind,
      name: c.name,
      language: lang,
      text: code,
      embedText: buildEmbedText(filePath, lang, c.kind, c.name, code)
    });
  }
  for (const f of summary.functions) {
    const endLine = f.endLine ?? guessSymbolEnd(allLines, f.line, 60);
    const code = sliceLines(allLines, f.line, endLine);
    chunks.push({
      filePath,
      startLine: f.line,
      endLine,
      kind: 'function',
      name: f.name,
      language: lang,
      text: code,
      embedText: buildEmbedText(filePath, lang, 'function', f.name, code)
    });
  }
  // Imports as one combined chunk — they're high-signal for "what does this
  // file depend on?" queries without paying per-import cost.
  if (summary.imports.length) {
    const joined = summary.imports.join('\n');
    chunks.push({
      filePath,
      startLine: 1,
      endLine: 1,
      kind: 'imports',
      name: '<imports>',
      language: lang,
      text: joined,
      embedText: buildEmbedText(filePath, lang, 'imports', '<imports>', joined)
    });
  }
  return chunks;
}

// Without semantic ranges, estimate where a symbol ends by counting braces
// (works for { }-languages we currently support). Caps growth at maxLines.
function guessSymbolEnd(allLines: string[], startLine: number, maxLines: number): number {
  const startIdx = Math.max(0, startLine - 1);
  let depth = 0;
  let opened = false;
  const limit = Math.min(allLines.length, startIdx + maxLines);
  for (let i = startIdx; i < limit; i++) {
    const line = allLines[i];
    for (const ch of line) {
      if (ch === '{') { depth++; opened = true; }
      else if (ch === '}') {
        depth--;
        if (opened && depth <= 0) return i + 1;
      }
    }
  }
  return Math.min(allLines.length, startIdx + maxLines);
}

function chunksFromWindow(filePath: string, allLines: string[], lang: string): Chunk[] {
  const chunks: Chunk[] = [];
  let block = 1;
  for (let i = 0; i < allLines.length; i += (WINDOW_LINES - WINDOW_OVERLAP)) {
    const start1 = i + 1;
    const end1 = Math.min(allLines.length, i + WINDOW_LINES);
    const code = sliceLines(allLines, start1, end1);
    if (!code.trim()) continue;
    const name = `block-${block++}`;
    chunks.push({
      filePath,
      startLine: start1,
      endLine: end1,
      kind: 'window',
      name,
      language: lang,
      text: code,
      embedText: buildEmbedText(filePath, lang, 'window', name, code)
    });
    if (end1 >= allLines.length) break;
  }
  return chunks;
}

export async function chunkFile(absPath: string, projectRoot: string): Promise<Chunk[]> {
  const rel = path.relative(projectRoot, absPath) || path.basename(absPath);
  let buf: Buffer;
  try {
    buf = await fs.readFile(absPath);
  } catch {
    return [];
  }
  if (buf.length === 0 || buf.length > MAX_FILE_BYTES) return [];
  if (looksBinary(buf)) return [];

  const source = buf.toString('utf-8');
  const allLines = source.split('\n');
  const lang = detectLanguage(absPath);

  if (lang) {
    const astChunks = chunksFromAst(rel, source, lang, allLines);
    if (astChunks.length) return astChunks;
  }
  // Fallback: language we can't AST-parse, or file with no top-level symbols.
  // Use the extension if known, else 'text'.
  const fallbackLang = lang ?? path.extname(absPath).replace('.', '') ?? 'text';
  return chunksFromWindow(rel, allLines, fallbackLang || 'text');
}
