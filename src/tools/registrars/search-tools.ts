import type { SemanticSearch } from '../../semantic-search.js';
import type { Tool } from '../../tools.js';

interface RegisterSearchToolsDeps {
  register: (tool: Tool) => void;
  search: SemanticSearch;
  execFileAsync: (file: string, args: string[], options?: { maxBuffer?: number }) => Promise<{ stdout: string; stderr: string }>;
}

export function registerSearchTools(deps: RegisterSearchToolsDeps): void {
  const { register, search, execFileAsync } = deps;

  register({
    name: 'search_code',
    description: 'Search code by SPECIFIC terms (function/class names). Use exact identifiers, not generic words like "error" or "data".',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Termo específico de busca (nome de função, classe, etc)'
        },
        pattern: {
          type: 'string',
          description: 'Padrão alternativo de busca'
        },
        path: {
          type: 'string',
          description: 'Caminho onde buscar (padrão: diretório atual)'
        },
        maxResults: {
          type: 'number',
          description: 'Número máximo de resultados (padrão: 15)'
        }
      },
      required: ['query']
    },
    execute: async (args) => {
      try {
        const query = args.pattern || args.query || '';
        const results = await search.search(query, args.path || '.', args.maxResults);
        const output = search.formatResults(results);
        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'grep_file',
    description: 'FIRST-RESORT search tool. Use BEFORE read_file whenever you want to locate something specific (a symbol, a function name, a string, an error message). Returns line numbers — feed those into read_file with startLine/endLine for a focused micro-read instead of reading entire files. Add context:N for surrounding lines.',
    parameters: {
      type: 'object',
      properties: {
        pattern: {
          type: 'string',
          description: 'Padrão regex para buscar'
        },
        path: {
          type: 'string',
          description: 'Caminho do arquivo ou diretório'
        },
        context: {
          type: 'number',
          description: 'Número de linhas de contexto ao redor (0-5)'
        },
        maxResults: {
          type: 'number',
          description: 'Número máximo de resultados (1-100)'
        }
      },
      required: ['pattern']
    },
    execute: async (args) => {
      try {
        const pattern = String(args.pattern || args.q || '').trim();
        const searchPath = String(args.path || '.').trim();
        const contextRaw = Number.parseInt(String(args.context || 0), 10);
        const context = Number.isFinite(contextRaw) ? Math.max(0, Math.min(contextRaw, 5)) : 0;
        const maxResultsRaw = Number.parseInt(String(args.maxResults || 20), 10);
        const maxResults = Number.isFinite(maxResultsRaw) ? Math.max(1, Math.min(maxResultsRaw, 100)) : 20;

        if (!pattern) {
          return { success: false, output: '', error: 'Pattern não fornecido' };
        }

        try {
          new RegExp(pattern);
        } catch (error: any) {
          return { success: false, output: '', error: `Regex inválido: ${error.message}` };
        }

        const rgArgs = [
          '--json',
          '--context', String(context),
          '--max-count', String(maxResults),
          '--glob', '!**/node_modules/**',
          '--glob', '!**/dist/**',
          '--glob', '!**/data/**',
          '--glob', '!**/.git/**',
          pattern,
          searchPath
        ];

        const { stdout } = await execFileAsync('rg', rgArgs, { maxBuffer: 10 * 1024 * 1024 });

        if (!stdout.trim()) {
          return { success: true, output: 'Nenhum resultado', error: null };
        }

        const results: Array<{file: string; lineNum: number; match: string; contextBefore: string[]; contextAfter: string[]}> = [];
        let currentMatch: any = null;
        let contextBefore: string[] = [];
        let contextAfter: string[] = [];
        let inContextAfter = false;

        for (const line of stdout.split('\n')) {
          if (!line.trim()) continue;
          try {
            const event = JSON.parse(line);

            if (event.type === 'context') {
              const text = String(event.data.lines?.text ?? '');
              const lineNum = event.data.line_number ?? 0;

              if (currentMatch && inContextAfter) {
                contextAfter.push(`  ${lineNum.toString().padStart(4)} | ${text}`);
              } else {
                contextBefore.push(`  ${lineNum.toString().padStart(4)} | ${text}`);
              }
            }

            if (event.type === 'match') {
              if (currentMatch) {
                results.push({
                  file: currentMatch.file,
                  lineNum: currentMatch.lineNum,
                  match: currentMatch.match,
                  contextBefore: [...contextBefore],
                  contextAfter: [...contextAfter]
                });
                if (results.length >= maxResults) break;
              }

              const text = String(event.data.lines?.text ?? '');
              const file = String(event.data.path?.text ?? 'unknown');
              const lineNum = event.data.line_number ?? 0;

              currentMatch = { file, lineNum, match: text };
              contextBefore = contextBefore.slice(-context);
              contextAfter = [];
              inContextAfter = true;
            }

            if (event.type === 'end') {
              if (currentMatch) {
                results.push({
                  file: currentMatch.file,
                  lineNum: currentMatch.lineNum,
                  match: currentMatch.match,
                  contextBefore: [...contextBefore],
                  contextAfter: [...contextAfter]
                });
              }
              currentMatch = null;
              contextBefore = [];
              contextAfter = [];
              inContextAfter = false;
            }
          } catch {
            continue;
          }
        }

        if (currentMatch) {
          results.push({
            file: currentMatch.file,
            lineNum: currentMatch.lineNum,
            match: currentMatch.match,
            contextBefore: [...contextBefore],
            contextAfter: [...contextAfter]
          });
        }

        if (results.length === 0) {
          return { success: true, output: 'Nenhum resultado', error: null };
        }

        const formatted = results.map(r => {
          const lines: string[] = [];
          lines.push(`\n${r.file}:${r.lineNum}`);

          if (r.contextBefore.length > 0) {
            lines.push(...r.contextBefore);
          }

          lines.push(`\x1b[32m>\x1b[0m ${r.lineNum.toString().padStart(4)} | ${r.match}`);

          if (r.contextAfter.length > 0) {
            lines.push(...r.contextAfter);
          }

          return lines.join('\n');
        }).join('\n');

        return { success: true, output: formatted, error: null };
      } catch (error: any) {
        if (error.code === 'ENOENT') {
          return { success: false, output: '', error: 'rg não encontrado' };
        }
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'web_search',
    description: 'Busca contexto web via SearxNG e DuckDuckGo HTML para RAG factual',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Consulta de busca'
        },
        maxResults: {
          type: 'number',
          description: 'Número máximo de resultados (padrão: 4)'
        }
      },
      required: ['query']
    },
    execute: async (args) => {
      const query = String(args.query || args.q || '').trim();
      const maxResultsRaw = Number.parseInt(String(args.maxResults || args.limit || 4), 10);
      const maxResults = Number.isFinite(maxResultsRaw) ? Math.min(Math.max(maxResultsRaw, 1), 8) : 4;

      if (!query) {
        return { success: false, output: '', error: 'Query não fornecida para web_search' };
      }

      type WebHit = { title: string; summary: string; source: string; engine: string };

      const stripHtml = (input: string): string => {
        return input
          .replace(/<[^>]*>/g, ' ')
          .replace(/&nbsp;/g, ' ')
          .replace(/&quot;/g, '"')
          .replace(/&#39;/g, "'")
          .replace(/&amp;/g, '&')
          .replace(/\s+/g, ' ')
          .trim();
      };

      const normalizeQuery = (raw: string): string => {
        return raw
          .replace(/[\n\r\t]+/g, ' ')
          .replace(/["'`]/g, ' ')
          .replace(/\s+/g, ' ')
          .trim();
      };

      const buildQueryVariants = (raw: string): string[] => {
        const base = normalizeQuery(raw);
        const variants = new Set<string>();
        if (base) variants.add(base);

        const noPunctuation = base.replace(/[?!.,;:()\[\]{}]+/g, ' ').replace(/\s+/g, ' ').trim();
        if (noPunctuation && noPunctuation !== base) variants.add(noPunctuation);

        const words = noPunctuation.split(' ').filter(Boolean);
        if (words.length > 9) {
          variants.add(words.slice(0, 9).join(' '));
        }

        return Array.from(variants).slice(0, 3);
      };

      const fetchJson = async (url: string): Promise<any> => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 10000);
        try {
          const response = await fetch(url, { signal: controller.signal });
          if (!response.ok) {
            const statusText = response.statusText ? ` ${response.statusText}` : '';
            throw new Error(`HTTP ${response.status}${statusText} (${url})`);
          }
          return await response.json();
        } finally {
          clearTimeout(timer);
        }
      };

      const fetchText = async (url: string): Promise<string> => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 10000);
        try {
          const response = await fetch(url, { signal: controller.signal });
          if (!response.ok) {
            const statusText = response.statusText ? ` ${response.statusText}` : '';
            throw new Error(`HTTP ${response.status}${statusText} (${url})`);
          }
          return await response.text();
        } finally {
          clearTimeout(timer);
        }
      };

      const decodeHtml = (input: string): string => {
        return input
          .replace(/&quot;/g, '"')
          .replace(/&#39;/g, "'")
          .replace(/&amp;/g, '&')
          .replace(/&lt;/g, '<')
          .replace(/&gt;/g, '>');
      };

      const dedupeHits = (items: WebHit[]): WebHit[] => {
        const seen = new Set<string>();
        const out: WebHit[] = [];
        for (const item of items) {
          const key = `${item.source.toLowerCase()}|${item.title.toLowerCase()}`;
          if (seen.has(key)) continue;
          seen.add(key);
          out.push(item);
        }
        return out;
      };

      const fetchSearxng = async (q: string): Promise<WebHit[]> => {
        const searxBase = String(process.env.SEARXNG_BASE_URL || '').replace(/\/+$/, '');
        if (!searxBase) return [];
        const endpoint = `${searxBase}/search?q=${encodeURIComponent(q)}&format=json`;
        const data = await fetchJson(endpoint);
        const rawItems = Array.isArray(data?.results) ? data.results : [];
        const hits: WebHit[] = rawItems.map((item: any) => {
          const title = String(item?.title || '').trim();
          const source = String(item?.url || '').trim();
          const summary = stripHtml(String(item?.content || item?.snippet || '')).trim();
          return {
            title,
            summary,
            source,
            engine: 'SearxNG'
          };
        }).filter((item: WebHit) => item.title && item.summary && item.source);
        return dedupeHits(hits).slice(0, maxResults);
      };

      const fetchDuckDuckGoHtml = async (q: string): Promise<WebHit[]> => {
        const url = `https://duckduckgo.com/html/?q=${encodeURIComponent(q)}`;
        const html = await fetchText(url);
        const hits: WebHit[] = [];

        const blocks = html.split('result__body').slice(1);
        for (const block of blocks) {
          if (hits.length >= maxResults) break;
          const linkMatch = block.match(/class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i);
          if (!linkMatch) continue;
          const rawUrl = linkMatch[1];
          const rawTitle = linkMatch[2];
          const snippetMatch = block.match(/class="result__snippet"[^>]*>([\s\S]*?)<\/a>|class="result__snippet"[^>]*>([\s\S]*?)<\/div>/i);
          const rawSnippet = snippetMatch ? (snippetMatch[1] || snippetMatch[2] || '') : '';

          const title = stripHtml(decodeHtml(rawTitle)).trim();
          const summary = stripHtml(decodeHtml(rawSnippet)).trim();
          const source = stripHtml(decodeHtml(rawUrl)).trim();

          if (!title || !summary || !source) continue;
          hits.push({
            title,
            summary,
            source,
            engine: 'DuckDuckGoHTML'
          });
        }

        return dedupeHits(hits).slice(0, maxResults);
      };

      try {
        let lastError = '';
        const variants = buildQueryVariants(query);
        const collected: WebHit[] = [];

        for (const q of variants) {
          if (collected.length >= maxResults) break;
          const [searx, duck] = await Promise.all([
            fetchSearxng(q).catch((error: any) => {
              lastError = String(error?.message || error || '');
              return [];
            }),
            fetchDuckDuckGoHtml(q).catch((error: any) => {
              lastError = String(error?.message || error || '');
              return [];
            })
          ]);

          const merged = dedupeHits([...searx, ...duck]);
          for (const item of merged) {
            if (collected.length >= maxResults) break;
            const duplicate = collected.some(existing => existing.source.toLowerCase() === item.source.toLowerCase());
            if (duplicate) continue;
            collected.push(item);
          }
        }

        if (collected.length === 0) {
          return {
            success: false,
            output: '',
            error: lastError
              ? `Falha na busca web (${query}): ${lastError}`
              : `Sem resultados web para: ${query}`
          };
        }

        const output = [
          `Web context for: ${query}`,
          ...collected.map((item, index) => `${index + 1}. ${item.title}\n${item.summary}\nSource: ${item.source}\nEngine: ${item.engine}`)
        ].join('\n\n');

        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message || 'Falha na busca web' };
      }
    }
  });
}
