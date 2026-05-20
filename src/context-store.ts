import Database from 'better-sqlite3';
import { existsSync, mkdirSync } from 'fs';
import path from 'path';

export interface StoredChunk {
  rowid: number;
  sessionId: string;
  summary: string;
  originalTokens: number;
  createdAt: number;
}

/**
 * Persistent FTS5 store for compressed conversation summaries.
 *
 * Each chunk represents a batch of original messages that were too old to
 * keep verbatim. The LLM-generated summary is indexed with FTS5 (porter
 * stemmer + unicode61) so that future queries can retrieve the most
 * relevant historical context instead of blindly keeping the most recent.
 *
 * Schema:
 *   context_fts — FTS5 virtual table
 *     session_id     UNINDEXED   (filter-only, not full-text indexed)
 *     summary        indexed     (full-text searchable)
 *     original_tokens UNINDEXED
 *     created_at     UNINDEXED
 */
export class ContextStore {
  private db: Database.Database;

  constructor(dbPath: string) {
    const dir = path.dirname(dbPath);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

    this.db = new Database(dbPath);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('synchronous = NORMAL');
    this.db.exec(`
      CREATE VIRTUAL TABLE IF NOT EXISTS context_fts USING fts5(
        session_id UNINDEXED,
        summary,
        original_tokens UNINDEXED,
        created_at UNINDEXED,
        tokenize='porter unicode61'
      );
    `);
  }

  insert(sessionId: string, summary: string, originalTokens: number): void {
    this.db.prepare(
      'INSERT INTO context_fts(session_id, summary, original_tokens, created_at) VALUES (?,?,?,?)'
    ).run(sessionId, summary, originalTokens, Date.now());
  }

  /**
   * FTS5 full-text search scoped to the given session.
   * Falls back to most-recent entries if the query produces no hits.
   */
  search(query: string, sessionId: string, limit = 3): StoredChunk[] {
    const ftsQuery = buildFtsQuery(query);
    if (ftsQuery) {
      try {
        const rows = this.db.prepare(`
          SELECT rowid, session_id, summary, original_tokens, created_at
          FROM context_fts
          WHERE context_fts MATCH ?
            AND session_id = ?
          ORDER BY rank
          LIMIT ?
        `).all(ftsQuery, sessionId, limit) as RawRow[];
        if (rows.length > 0) return rows.map(toChunk);
      } catch {
        // Malformed query — fall through to recency fallback
      }
    }
    return this.getRecent(sessionId, limit);
  }

  /** Returns the N most recently inserted chunks for a session. */
  getRecent(sessionId: string, limit = 3): StoredChunk[] {
    const rows = this.db.prepare(`
      SELECT rowid, session_id, summary, original_tokens, created_at
      FROM context_fts
      WHERE session_id = ?
      ORDER BY created_at DESC
      LIMIT ?
    `).all(sessionId, limit) as RawRow[];
    return rows.map(toChunk);
  }

  /** Total number of compressed chunks for a session. */
  count(sessionId: string): number {
    const row = this.db.prepare(
      'SELECT COUNT(*) AS n FROM context_fts WHERE session_id = ?'
    ).get(sessionId) as { n: number };
    return row.n;
  }

  close(): void {
    this.db.close();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

interface RawRow {
  rowid: number;
  session_id: string;
  summary: string;
  original_tokens: number;
  created_at: number;
}

function toChunk(r: RawRow): StoredChunk {
  return {
    rowid: r.rowid,
    sessionId: r.session_id,
    summary: r.summary,
    originalTokens: r.original_tokens,
    createdAt: r.created_at
  };
}

/**
 * Converts a natural-language query into a safe FTS5 match expression.
 * Words are joined with OR so any match is returned; FTS5 ranks by
 * relevance (BM25) via ORDER BY rank.
 */
function buildFtsQuery(raw: string): string {
  const words = raw
    .replace(/[^\w\s]/g, ' ')
    .trim()
    .split(/\s+/)
    .filter(w => w.length > 2)
    .slice(0, 10);
  return words.join(' OR ');
}
