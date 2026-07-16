import path from 'path';
import type { Tool } from '../../tools.js';
import { RagEngine } from '../../rag/rag-engine.js';
import { EmbeddingsClient } from '../../rag/embeddings.js';

interface RegisterRagToolsDeps {
  register: (tool: Tool) => void;
}

/**
 * Local-RAG tools — semantic retrieval over the project's own source tree.
 *
 * Why a separate stack from `search_files` (ripgrep):
 *   ripgrep finds occurrences of literal tokens; RAG finds *semantically*
 *   related code regardless of the words used in the query. The two are
 *   complementary — the model should reach for ripgrep when it already
 *   knows the identifier, and for rag_search when it's asking a concept
 *   question ("where is auth handled?", "find the embedding pipeline").
 *
 * Lifecycle:
 *   - rag_index builds (or updates) the index under .phenom-context/rag/.
 *   - rag_search reuses the persisted index — refuses to run if it's missing
 *     or the embedding model has changed (we don't silently mix dims).
 *   - rag_status is cheap; safe to call without a prior index pass.
 *
 * Cost discipline:
 *   indexing calls the remote embeddings endpoint (Ollama at OLLAMA_HOST),
 *   so it's not free. The index is incremental — only files whose SHA-256
 *   changed are re-embedded. A subsequent `rag_index` after small edits is
 *   essentially free.
 */
export function registerRagTools(deps: RegisterRagToolsDeps): void {
  const { register } = deps;

  // Lazy-built engine. We don't construct EmbeddingsClient at import time
  // because it throws when OLLAMA_HOST is missing — and config-less imports
  // shouldn't crash the agent boot.
  let engine: RagEngine | null = null;
  function getEngine(): RagEngine {
    if (engine) return engine;
    const client = new EmbeddingsClient();
    engine = new RagEngine(process.cwd(), client);
    return engine;
  }

  register({
    name: 'rag_status',
    description:
      'Report whether a local RAG index exists for this project, and if so, summarise it (embedding model, file count, chunk count, on-disk size, last update). Cheap — no network, no embeddings. Always call this before deciding whether to run rag_index.',
    parameters: { type: 'object', properties: {} },
    execute: async () => {
      try {
        const st = await getEngine().status();
        if (!st.present) {
          return { success: true, output: `RAG index ausente. Modelo configurado: ${st.model}. Rode \`rag_index\` para construir.`, error: null };
        }
        const mb = (st.bytes / (1024 * 1024)).toFixed(2);
        return {
          success: true,
          output: `RAG index presente — modelo=${st.model}, arquivos=${st.files}, chunks=${st.chunks}, tamanho=${mb} MB, atualizado=${st.updatedAt}`,
          error: null
        };
      } catch (e: any) {
        return { success: false, output: '', error: `rag_status falhou: ${e.message}` };
      }
    }
  });

  register({
    name: 'rag_index',
    description:
      'Build or update the local RAG index for this project. Walks tracked files (honors .gitignore), chunks each via AST when supported (falls back to a 60-line window), embeds chunks via OLLAMA_HOST, and persists to .phenom-context/rag/. Incremental: only re-embeds files whose SHA changed since the last run. Set `force` to rebuild from scratch (use after upgrading the embedding model or major refactors).',
    parameters: {
      type: 'object',
      properties: {
        force: {
          type: 'boolean',
          description: 'Se true, descarta o índice existente e reindexa do zero. Default false.'
        }
      }
    },
    execute: async (args) => {
      try {
        const force = args.force === true;
        const progress: string[] = [];
        const stats = await getEngine().index({
          force,
          onProgress: (msg) => {
            if (progress.length < 12) progress.push(msg);
          }
        });
        const lines: string[] = [];
        lines.push(`RAG index OK — modelo=${getEngine().client.model}, dim=${getEngine().client.dim ?? '?'}`);
        lines.push(`arquivos: scan=${stats.filesScanned}, reused=${stats.filesReused}, reindexed=${stats.filesReindexed}, removed=${stats.filesRemoved}`);
        lines.push(`chunks: ${stats.chunksTotal} · duração: ${stats.durationMs} ms`);
        if (progress.length) {
          lines.push('--- amostra de progresso:');
          for (const p of progress.slice(0, 8)) lines.push(`  ${p}`);
          if (progress.length > 8) lines.push(`  ...${progress.length - 8} more`);
        }
        return { success: true, output: lines.join('\n'), error: null };
      } catch (e: any) {
        return { success: false, output: '', error: `rag_index falhou: ${e.message}` };
      }
    }
  });

  register({
    name: 'rag_search',
    description:
      'Semantic search over the project source. Returns the top-k chunks most similar to the natural-language query, with file path, line range, kind/name, cosine score, and a short snippet. Use for "where is X handled?" or "find the part that does Y" questions where you do not yet know the identifier. Prefer ripgrep (`search_files`) when you already know an exact token. Fails with an explicit error if the index is missing — call rag_status / rag_index first.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Consulta em linguagem natural ou trecho de código exemplo. Pode descrever conceito, função, ou padrão.'
        },
        k: {
          type: 'number',
          description: 'Número máximo de hits (default 8, recomendado 5-15).'
        }
      },
      required: ['query']
    },
    execute: async (args) => {
      try {
        const query = String(args.query || '').trim();
        if (!query) return { success: false, output: '', error: 'rag_search requer `query`.' };
        const k = Math.min(50, Math.max(1, Number(args.k) || 8));

        const hits = await getEngine().search(query, k);
        if (hits.length === 0) {
          return { success: true, output: '(nenhum resultado — índice vazio ou query muito distante)', error: null };
        }
        const lines: string[] = [];
        lines.push(`top ${hits.length} hits para: ${query.slice(0, 120)}`);
        for (let i = 0; i < hits.length; i++) {
          const h = hits[i];
          const score = h.score.toFixed(3);
          const head = `${i + 1}. [${score}] ${h.filePath}:${h.startLine}-${h.endLine} (${h.kind} ${h.name})`;
          lines.push(head);
          if (h.snippet) {
            for (const sl of h.snippet.split('\n')) {
              lines.push(`     ${sl}`);
            }
          }
        }
        return { success: true, output: lines.join('\n'), error: null };
      } catch (e: any) {
        return { success: false, output: '', error: `rag_search falhou: ${e.message}` };
      }
    }
  });
}
