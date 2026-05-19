import { execFile } from 'child_process';
import { promisify } from 'util';
import path from 'path';
import { config } from './config.js';
import { SearchHit } from './types.js';

const execFileAsync = promisify(execFile);

const SYNONYMS: Record<string, string[]> = {
  error:   ['err', 'exception', 'fail', 'throw'],
  config:  ['settings', 'opts', 'options', 'cfg'],
  handler: ['controller', 'route', 'middleware'],
  user:    ['account', 'profile', 'member'],
  test:    ['spec', 'fixture', 'mock', 'stub'],
  service: ['svc', 'provider', 'client'],
  type:    ['interface', 'schema', 'model']
};

// Maximum alternative terms injected into the ripgrep pattern.
// Uncapped expansion causes regex backtracking issues on large codebases.
const MAX_PATTERN_ALTERNATIVES = 20;

export class SemanticSearch {
  async search(
    query: string,
    searchPath: string = '.',
    maxResults: number = config.search.maxResults
  ): Promise<SearchHit[]> {
    const trimmed = query.trim();
    if (!trimmed) return [];

    const terms   = this.extractTerms(trimmed).map(t => t.toLowerCase());
    const pattern = this.buildPattern(trimmed, terms);
    const hits    = await this.runRg(pattern, searchPath, maxResults, terms);

    return hits.slice(0, maxResults);
  }

  formatResults(hits: SearchHit[]): string {
    if (hits.length === 0) return 'No results found';
    return hits
      .map(hit => `${hit.file}:${hit.line}  ${hit.snippet.trim()}`)
      .join('\n');
  }

  // ---------------------------------------------------------------------------
  // Pattern builder
  // ---------------------------------------------------------------------------

  private buildPattern(query: string, terms: string[]): string {
    const alternatives = new Set<string>();

    for (const term of terms) {
      alternatives.add(term);
      alternatives.add(this.toSnake(term));
      alternatives.add(this.toCamel(term));

      const syns = SYNONYMS[term.toLowerCase()];
      if (syns) syns.forEach(s => alternatives.add(s));

      // Limit early to avoid pattern explosion on multi-word queries
      if (alternatives.size >= MAX_PATTERN_ALTERNATIVES) break;
    }

    const parts = Array.from(alternatives)
      .filter(p => p.length >= 2)
      .map(p => this.escapeRegex(p))
      .slice(0, MAX_PATTERN_ALTERNATIVES);

    if (parts.length === 0) return this.escapeRegex(query.slice(0, 60));
    if (parts.length === 1) return parts[0];
    return `(${parts.join('|')})`;
  }

  private extractTerms(query: string): string[] {
    return query
      .split(/[^A-Za-z0-9_]+/)
      .map(t => t.trim())
      .filter(t => t.length >= 3);
  }

  private toSnake(term: string): string {
    return term.replace(/([a-z])([A-Z])/g, '$1_$2').replace(/-+/g, '_').toLowerCase();
  }

  private toCamel(term: string): string {
    return term.toLowerCase().replace(/[_-]+([a-z0-9])/g, (_, c) => c.toUpperCase());
  }

  private escapeRegex(input: string): string {
    return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  // ---------------------------------------------------------------------------
  // Runner
  // ---------------------------------------------------------------------------

  private async runRg(
    pattern: string,
    searchPath: string,
    maxResults: number,
    terms: string[]
  ): Promise<SearchHit[]> {
    try {
      const { stdout } = await execFileAsync('rg', [
        '--json',
        '--smart-case',
        '--glob', '!**/node_modules/**',
        '--glob', '!**/dist/**',
        '--glob', '!**/data/**',
        '--glob', '!**/.git/**',
        '--glob', '!**/*.lock',
        '--glob', '!**/*.map',
        pattern,
        searchPath
      ], { maxBuffer: 10 * 1024 * 1024 });

      return this.parseRgJson(stdout, maxResults, terms);
    } catch (error: any) {
      if (error.code === 'ENOENT') return this.runGrepFallback(pattern, searchPath, maxResults, terms);
      if (error.stdout)            return this.parseRgJson(error.stdout, maxResults, terms);
      return [];
    }
  }

  private parseRgJson(output: string, maxResults: number, terms: string[]): SearchHit[] {
    const hits: SearchHit[] = [];

    for (const line of output.split('\n')) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line);
        if (event.type !== 'match') continue;

        const text     = String(event.data.lines?.text ?? '');
        const filePath = String(event.data.path?.text ?? 'unknown');
        const lineNum  = Number(event.data.line_number ?? 0);

        hits.push({
          file:    filePath,
          line:    lineNum,
          snippet: text.replace(/\s+/g, ' ').trim(),
          score:   this.scoreHit(text, filePath, terms)
        });

        if (hits.length >= maxResults) break;
      } catch {
        continue;
      }
    }

    return hits.sort((a, b) => b.score - a.score);
  }

  private async runGrepFallback(
    pattern: string,
    searchPath: string,
    maxResults: number,
    terms: string[]
  ): Promise<SearchHit[]> {
    try {
      const { stdout } = await execFileAsync('grep', [
        '-R', '-n', '-E',
        '--include=*.ts', '--include=*.js', '--include=*.tsx', '--include=*.jsx',
        '--include=*.py', '--include=*.go', '--include=*.rs',
        '--exclude-dir=node_modules', '--exclude-dir=dist', '--exclude-dir=.git',
        pattern,
        searchPath
      ], { maxBuffer: 5 * 1024 * 1024 });

      const hits: SearchHit[] = [];
      for (const line of stdout.split('\n')) {
        if (!line.trim()) continue;
        const match = line.match(/^(.*?):(\d+):(.*)$/);
        if (!match) continue;
        hits.push({
          file:    match[1],
          line:    parseInt(match[2], 10),
          snippet: match[3].trim(),
          score:   this.scoreHit(match[3], match[1], terms)
        });
      }

      return hits.sort((a, b) => b.score - a.score).slice(0, maxResults);
    } catch {
      return [];
    }
  }

  private scoreHit(text: string, filePath: string, terms: string[]): number {
    const lowerText = text.toLowerCase();
    const fileName  = path.basename(filePath).toLowerCase();
    let score = 0;
    for (const t of terms) {
      if (lowerText.includes(t)) score += 1.0;
      if (fileName.includes(t))  score += 0.5;
    }
    // Prefer source files over test files slightly
    if (/\.(test|spec)\.[jt]sx?$/.test(filePath)) score *= 0.85;
    return score;
  }
}
