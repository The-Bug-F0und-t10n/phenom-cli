/**
 * Lightweight TTL cache for civic-briefing data, persisted to JSON on disk.
 *
 * Ported from CivicCacheManager (news_pipeline_hybrid.py) but without the
 * SQLite dependency — civic data is small (a few KB per city), so a JSON
 * file is simpler and avoids pulling in better-sqlite3 or similar.
 *
 * Cache directory layout:
 *   .phenom-data/civic-cache.json   ← one file holds all city entries
 *
 * Entries expire by absolute timestamp comparison; the file is rewritten
 * atomically on every set() (write tmp + rename) so a crash mid-write can't
 * corrupt the cache.
 */

import { promises as fs } from 'fs';
import path from 'path';

interface CacheEntry<T> {
  data: T;
  /** Epoch ms when this entry was written. */
  writtenAt: number;
  /** TTL in seconds — written here so each entry carries its own freshness. */
  ttlSec: number;
}

interface CacheFile {
  version: 1;
  entries: Record<string, CacheEntry<unknown>>;
}

const DEFAULT_TTL_SEC = 3600; // 1 hour

export class TtlCache<T = unknown> {
  private readonly filePath: string;
  /**
   * In-memory mirror of the file. Loaded lazily on first read; written
   * back to disk on every set(). This avoids re-parsing JSON on every
   * cache hit during a single session.
   */
  private memory: CacheFile | null = null;

  constructor(filePath: string = path.join(process.cwd(), '.phenom-data', 'civic-cache.json')) {
    this.filePath = filePath;
  }

  async get(key: string, now: number = Date.now()): Promise<T | null> {
    const mem = await this.load();
    const entry = mem.entries[key] as CacheEntry<T> | undefined;
    if (!entry) return null;
    if (now - entry.writtenAt > entry.ttlSec * 1000) {
      // Stale — leave it on disk (cleanup is cheap; rewriting on every get
      // would be wasteful). Next set() compacts.
      return null;
    }
    return entry.data;
  }

  async set(key: string, data: T, ttlSec: number = DEFAULT_TTL_SEC, now: number = Date.now()): Promise<void> {
    const mem = await this.load();
    mem.entries[key] = { data, writtenAt: now, ttlSec };
    // Compact: drop expired entries on every write so the file doesn't grow.
    for (const k of Object.keys(mem.entries)) {
      const e = mem.entries[k];
      if (now - e.writtenAt > e.ttlSec * 1000) delete mem.entries[k];
    }
    await this.persist(mem);
  }

  async clear(): Promise<void> {
    this.memory = { version: 1, entries: {} };
    await this.persist(this.memory);
  }

  private async load(): Promise<CacheFile> {
    if (this.memory) return this.memory;
    try {
      const raw = await fs.readFile(this.filePath, 'utf-8');
      const parsed = JSON.parse(raw) as CacheFile;
      if (parsed.version === 1 && parsed.entries && typeof parsed.entries === 'object') {
        this.memory = parsed;
        return parsed;
      }
    } catch {
      // File missing or corrupted — start fresh. We don't surface the
      // error because the cache is best-effort.
    }
    this.memory = { version: 1, entries: {} };
    return this.memory;
  }

  private async persist(mem: CacheFile): Promise<void> {
    this.memory = mem;
    const dir = path.dirname(this.filePath);
    await fs.mkdir(dir, { recursive: true });
    const tmp = this.filePath + '.tmp';
    await fs.writeFile(tmp, JSON.stringify(mem), 'utf-8');
    await fs.rename(tmp, this.filePath);
  }
}
