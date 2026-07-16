import { promises as fs } from 'fs';
import path from 'path';
import { config } from '../../config.js';
import type { Tool } from '../../tools.js';

interface RegisterFilesystemToolsDeps {
  register: (tool: Tool) => void;
  validateSyntax: (filePath: string) => Promise<{ valid: boolean; output: string; error: string | null }>;
}

const SKIP_DIRS_FOR_SUGGEST = new Set([
  'node_modules', 'dist', 'build', 'out', '.git', '.next', '.nuxt', 'target',
  '__pycache__', '.venv', 'venv', '.pytest_cache', 'coverage', '.cache',
  '.turbo', 'vendor', '.mypy_cache', '.phenom-context', '.phenom-skills',
  '.phenom-sessions', '.reference'
]);
const SUGGEST_MAX_FILES_SCANNED = 4000;
const SUGGEST_MAX_RESULTS = 5;

/**
 * BUG-B-01 / B-04: snapshot the current content of `target` into
 * `.phenom-trash/<session>/...` BEFORE every destructive write
 * (write_file overwrite, create_file overwrite, apply_patch).
 *
 * The calculadora post-mortem (C5) recurred because backups were only
 * written when the caller explicitly passed `overwrite=false`. The default
 * `overwrite=true` path went straight to fs.writeFile with no recoverable
 * copy. This helper makes the snapshot unconditional, scoped to the
 * project tree (so we never escape it — see feedback_stay_in_project_dir),
 * and bounded (best-effort: failure to snapshot does NOT block the write,
 * but it IS surfaced in the result so the model knows).
 *
 * Returns the absolute snapshot path, or null when nothing was snapshotted
 * (file didn't exist / snapshot failed).
 */
async function snapshotBeforeWrite(target: string, content: string): Promise<string | null> {
  try {
    const cwd = process.cwd();
    const session = process.env.PHENOM_SESSION_ID || 'default';
    const baseDir = path.join(cwd, '.phenom-trash', String(session).slice(0, 16));
    // Mirror the relative path under baseDir; absolute paths are flattened.
    const abs = path.isAbsolute(target) ? target : path.resolve(cwd, target);
    const rel = path.relative(cwd, abs);
    const safeRel = rel.startsWith('..') ? path.basename(abs) : rel;
    const stamped = `${safeRel}.${Date.now()}.bak`;
    const snapPath = path.join(baseDir, stamped);
    await fs.mkdir(path.dirname(snapPath), { recursive: true });
    await fs.writeFile(snapPath, content, 'utf-8');
    return snapPath;
  } catch {
    return null;
  }
}

/**
 * Walk the project tree (bounded) and return paths whose basename matches the
 * missing path's basename. Used to enrich ENOENT errors so models that
 * hallucinate path segments (e.g. "src/components/calculator/Calculator.tsx"
 * when the real file is "src/components/Calculator.tsx") see the correction
 * inline and stop looping on the same wrong path. The "calculadora" session
 * looped 3× ENOENT on a single bad path before giving up.
 */
async function suggestSimilarPaths(missingPath: string, projectRoot: string): Promise<string[]> {
  const baseTarget = path.basename(missingPath).toLowerCase();
  if (!baseTarget) return [];
  const results: Array<{ rel: string; depthDelta: number }> = [];
  const wantedDepth = missingPath.split(path.sep).length;
  let scanned = 0;

  async function walk(dir: string): Promise<void> {
    if (scanned >= SUGGEST_MAX_FILES_SCANNED) return;
    let entries: import('fs').Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      if (scanned >= SUGGEST_MAX_FILES_SCANNED) return;
      if (SKIP_DIRS_FOR_SUGGEST.has(ent.name) || ent.name.startsWith('.')) continue;
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        await walk(full);
      } else if (ent.isFile()) {
        scanned++;
        if (ent.name.toLowerCase() === baseTarget) {
          const rel = path.relative(projectRoot, full);
          const depth = rel.split(path.sep).length;
          results.push({ rel, depthDelta: Math.abs(depth - wantedDepth) });
        }
      }
    }
  }
  try {
    await walk(projectRoot);
  } catch {
    return [];
  }
  results.sort((a, b) => a.depthDelta - b.depthDelta);
  return results.slice(0, SUGGEST_MAX_RESULTS).map(r => r.rel);
}

function formatEnoentError(tool: string, missingPath: string, suggestions: string[]): string {
  const head = `PATH_NOT_FOUND (${tool}): '${missingPath}' não existe.`;
  if (suggestions.length === 0) {
    return `${head} Nenhum arquivo com basename similar foi encontrado. Use list_dir no diretório pai antes de tentar de novo. NÃO repita essa chamada com o mesmo path.`;
  }
  const lines = suggestions.map(s => `  - ${s}`).join('\n');
  return `${head} NÃO repita esse path. Candidatos com basename igual:\n${lines}\nEscolha um dos acima OU use list_dir / path_exists pra confirmar antes de chamar ${tool} de novo.`;
}

export function registerFilesystemTools(deps: RegisterFilesystemToolsDeps): void {
  const { register, validateSyntax } = deps;

  register({
    name: 'read_file',
    description: 'Read a file with bounded context by default. If no range is provided, returns the first window (default 160 lines, configurable by env). Pass startLine/endLine for precise slices; pass wholeFile=true only when full-file read is truly required. Out-of-range startLine auto-clamps safely. Prefer grep_file/find_function when you only need to locate a symbol; use read_file for surrounding context.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho do arquivo a ser lido'
        },
        startLine: {
          type: 'number',
          description: 'Linha inicial (1-based, opcional). Default: 1.'
        },
        endLine: {
          type: 'number',
          description: 'Linha final (1-based, inclusiva). Se omitida, retorna uma janela de até 160 linhas a partir de startLine (ou total quando paginação default estiver desativada).'
        },
        wholeFile: {
          type: 'boolean',
          description: 'Se true, força leitura do arquivo inteiro (use com parcimônia).'
        },
        maxChars: {
          type: 'number',
          description: 'Hard char cap (default 40000). Independent from line cap.'
        },
        numberLines: {
          type: 'boolean',
          description: 'Se true, prefixa linhas com número (útil pra apply_patch posterior)'
        }
      },
      required: ['path']
    },
    execute: async (args) => {
      try {
        const readPath = String(args.path || '').trim();
        if (!readPath) {
          return { success: false, output: '', error: 'Caminho do arquivo não fornecido' };
        }

        const stats = await fs.stat(readPath);
        if (!stats.isFile()) {
          return { success: false, output: '', error: `Caminho não é arquivo: ${readPath}` };
        }

        const content = await fs.readFile(readPath, 'utf-8');
        const eol = content.includes('\r\n') ? '\r\n' : '\n';
        const lines = content.split(/\r?\n/);
        const totalLines = lines.length;
        const totalBytes = Buffer.byteLength(content, 'utf-8');

        // Safer default: bounded windows to keep context stable and reduce
        // tool-loop hallucinations after oversized reads.
        const paginatedDefault = process.env.PHENOM_READ_FILE_PAGINATED_DEFAULT !== '0';
        // Matches the read_file context-packing line budget (config base
        // maxLines). A larger window just gets packed back down before the
        // model sees it, so the model would "read" lines it never retains.
        const defaultWindowLines = 160;
        const startRaw = Number(args.startLine);
        const endRaw = Number(args.endLine);
        const hasStartLine = Number.isFinite(startRaw);
        const hasEndLine = Number.isFinite(endRaw);
        const hasRange = hasStartLine || hasEndLine;
        const wholeFile = Boolean(args.wholeFile);

        let rangeStart = 1;
        let rangeEnd = totalLines;

        if (wholeFile) {
          rangeStart = 1;
          rangeEnd = totalLines;
        } else if (!hasRange) {
          rangeStart = 1;
          rangeEnd = paginatedDefault ? Math.min(totalLines, defaultWindowLines) : totalLines;
        } else {
          rangeStart = hasStartLine ? Math.max(1, Math.floor(startRaw)) : 1;
          if (hasEndLine) {
            rangeEnd = Math.max(rangeStart, Math.floor(endRaw));
          } else {
            rangeEnd = paginatedDefault
              ? Math.min(totalLines, rangeStart + defaultWindowLines - 1)
              : totalLines;
          }
        }

        // Auto-clamp out-of-range requests instead of failing.
        const requestedStart = rangeStart;
        const requestedEnd = rangeEnd;
        let rangeReclamped: 'start_past_eof' | 'end_past_eof' | null = null;
        if (rangeStart > totalLines) {
          // Asked past the file entirely — return from the top so the model
          // sees real bounds and can recover deterministically.
          rangeStart = 1;
          rangeEnd = wholeFile
            ? totalLines
            : (paginatedDefault ? Math.min(totalLines, defaultWindowLines) : totalLines);
          rangeReclamped = 'start_past_eof';
        } else if (rangeEnd > totalLines) {
          rangeEnd = totalLines;
          rangeReclamped = 'end_past_eof';
        }


        const selectedLines = lines.slice(rangeStart - 1, rangeEnd);
        const numberLines = Boolean(args.numberLines);
        const numbered = numberLines
          ? selectedLines.map((line, index) => {
              const lineNo = String(rangeStart + index).padStart(4, ' ');
              return `${lineNo} │ ${line}`;
            }).join('\n')
          : selectedLines.join(eol);

        const maxCharsRaw = Number(args.maxChars);
        const maxChars = Number.isFinite(maxCharsRaw)
          ? Math.max(1000, Math.min(Math.floor(maxCharsRaw), 200000))
          : 40000;

        // BUG-B-07: truncate at the last full line boundary so a subsequent
        // apply_patch against the visible content doesn't fail with "not
        // found" on a half-line. Falls back to a hard cut only when no
        // newline fits in maxChars (single very long line).
        const truncated = numbered.length > maxChars;
        let body: string;
        if (truncated) {
          const cut = numbered.slice(0, maxChars);
          const lastNl = cut.lastIndexOf('\n');
          const safeEnd = lastNl > Math.floor(maxChars * 0.5) ? lastNl : maxChars;
          const droppedChars = numbered.length - safeEnd;
          body = numbered.slice(0, safeEnd) + `\n...[truncated: ${droppedChars} chars omitted at line-boundary]`;
        } else {
          body = numbered;
        }

        const remainingLines = totalLines - rangeEnd;
        const hints: string[] = [];
        if (rangeReclamped === 'start_past_eof') {
          hints.push(`hint: requested startLine ${requestedStart} é além do fim do arquivo (total=${totalLines}). Retornei a última janela disponível ${rangeStart}-${rangeEnd}. Não chame de novo com startLine > ${totalLines}.`);
        } else if (rangeReclamped === 'end_past_eof') {
          hints.push(`hint: requested endLine ${requestedEnd} > total (${totalLines}); clamp para ${rangeEnd}.`);
        }
        if (remainingLines > 0) {
          hints.push(`hint: ${remainingLines} more lines available (${rangeEnd + 1}..${totalLines}). Call read_file again with startLine=${rangeEnd + 1} for the next window, OR grep_file to jump to a specific region.`);
        }

        const meta = [
          '[READ_FILE]',
          `path: ${readPath}`,
          `lines: ${totalLines}`,
          `bytes: ${totalBytes}`,
          `whole_file: ${wholeFile ? 'true' : 'false'}`,
          `range: ${rangeStart}-${rangeEnd}`,
          `numbered: ${numberLines ? 'true' : 'false'}`,
          `truncated: ${truncated ? 'true' : 'false'}`
        ];
        if (hints.length > 0) {
          for (const h of hints) meta.push(h);
        }

        return {
          success: true,
          output: `${meta.join('\n')}\n---BEGIN CONTENT---\n${body}\n---END CONTENT---`,
          error: null
        };
      } catch (error: any) {
        if (error?.code === 'ENOENT') {
          const target = String(args.path || '').trim();
          const suggestions = await suggestSimilarPaths(target, process.cwd());
          return { success: false, output: '', error: formatEnoentError('read_file', target, suggestions) };
        }
        // BUG-B-10: surface error.code so the model can distinguish ENOENT
        // / EACCES / EISDIR / EPERM programmatically instead of substring
        // matching the message.
        const code = error?.code ? `[${error.code}] ` : '';
        return { success: false, output: '', error: `${code}${error.message}` };
      }
    }
  });

  register({
    name: 'path_exists',
    description: 'Verifica se um caminho existe e retorna tipo (arquivo/diretório)',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho a ser verificado'
        }
      },
      required: ['path']
    },
    execute: async (args) => {
      const target = String(args.path || '').trim();
      if (!target) {
        return { success: false, output: '', error: 'Caminho não fornecido' };
      }
      try {
        const stats = await fs.stat(target);
        const payload = {
          path: target,
          exists: true,
          isFile: stats.isFile(),
          isDirectory: stats.isDirectory()
        };
        return { success: true, output: JSON.stringify(payload), error: null };
      } catch (error: any) {
        if (error?.code === 'ENOENT') {
          const payload = {
            path: target,
            exists: false,
            isFile: false,
            isDirectory: false
          };
          return { success: true, output: JSON.stringify(payload), error: null };
        }
        return { success: false, output: '', error: error.message || 'Falha ao verificar caminho' };
      }
    }
  });

  register({
    name: 'write_file',
    description: 'Write the FULL content of a file. Replaces the file entirely if it exists. Appropriate when (a) the file does not exist and the task is to create it, or (b) the change rewrites the whole file. For partial edits to an existing file, use apply_patch — it preserves untouched lines and is the correct tool for refactor/edit/change requests on existing content. If content is identical, reports success without writing. Use overwrite=false to create a .bak backup.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho do arquivo'
        },
        content: {
          type: 'string',
          description: 'Conteúdo completo do arquivo'
        },
        append: {
          type: 'boolean',
          description: 'Se true, adiciona ao final do arquivo existente'
        },
        overwrite: {
          type: 'boolean',
          description: '(padrão true) Se false, cria backup (.bak) antes de sobrescrever. O modelo deve verificar contexto antes de escrever.'
        },
        dryRun: {
          type: 'boolean',
          description: 'Se true, simula sem escrever'
        }
      },
      required: ['path', 'content']
    },
    execute: async (args) => {
      const writePath = String(args.path || '').trim();
      const content = args.content;
      const append = Boolean(args.append);
      const dryRun = Boolean(args.dryRun);

      try {
        const missingPath = !writePath;
        const missingContent = content === undefined || content === null;
        if (missingPath || missingContent) {
          const missing = [missingPath && 'path', missingContent && 'content'].filter(Boolean).join(', ');
          return {
            success: false,
            output: '',
            error: `write_file requer "path" e "content" na MESMA chamada. Faltando: ${missing}. Schema: {"path":"<caminho do arquivo>","content":"<conteudo completo do arquivo>"}. Reenvie a chamada com ambos os campos preenchidos.`
          };
        }

        const dangerousExtensions = [
          '.exe', '.dll', '.so', '.dylib', '.bin',
          '.jar', '.war', '.ear'
        ];
        const ext = writePath.toLowerCase().split('.').pop() || '';
        const fullExt = '.' + ext;
        if (dangerousExtensions.includes(fullExt)) {
          return { success: false, output: '', error: `Extensão ${fullExt} bloqueada por segurança` };
        }

        const contentStr = String(content);
        if (contentStr.length > config.edit.fullReplaceMaxBytes) {
          return { success: false, output: '', error: `Conteúdo muito grande (max ${config.edit.fullReplaceMaxBytes} bytes)` };
        }

        const pathModule = await import('path');
        const dir = pathModule.dirname(writePath);

        try {
          const dirStats = await fs.stat(dir);
          if (!dirStats.isDirectory()) {
            return { success: false, output: '', error: `Path pai não é diretório: ${dir}` };
          }
        } catch {
          await fs.mkdir(dir, { recursive: true });
        }

        let existingContent: string | null = null;
        let isNew = true;
        try {
          const existingStats = await fs.stat(writePath);
          if (existingStats.isFile()) {
            isNew = false;
            if (!append) {
              existingContent = await fs.readFile(writePath, 'utf-8');
            }
          }
        } catch {}

        if (!append && existingContent !== null) {
          if (existingContent === contentStr) {
            // BUG-B-03: surface the no-op explicitly. The model often
            // re-emits the original content thinking it had patched, and
            // a bare "[OK] already updated" reads like success. Use the
            // [NO_OP] tag so the model can branch on it.
            return {
              success: true,
              output: `[NO_OP] ${writePath} unchanged — content you sent is byte-identical to the existing file (${contentStr.split('\n').length} lines). If you intended to edit, RE-READ the file (read_file) and resend only the changed lines via apply_patch.`,
              error: null
            };
          }

          // BUG-B-02: shrink guard. The ratio gate alone allowed truncating
          // a 50-line file to 11 (22%) silently. Add an absolute line-delta
          // check: when overwrite removes >30 lines AND keeps <50%, demand
          // an explicit confirmShrink=true.
          const existingLines = existingContent.split('\n').length;
          const newLines = contentStr.split('\n').length;
          const linesRemoved = existingLines - newLines;
          const ratio = newLines / Math.max(1, existingLines);
          const confirmShrink = Boolean(args.confirmShrink);
          if (!confirmShrink && linesRemoved > 30 && ratio < 0.5) {
            return {
              success: false,
              output: '',
              error: `[SHRINK_GUARD] write_file would remove ${linesRemoved} lines (${existingLines} → ${newLines}, ${Math.round(ratio * 100)}% of original). If intentional, re-call with confirmShrink=true. Otherwise use apply_patch for targeted edits.`
            };
          }

          // BUG-B-01: snapshot unconditionally (default `overwrite=true`
          // used to skip the .bak entirely). The explicit `overwrite=false`
          // path keeps its visible [BAK <path>] message; the default path
          // gets a silent snapshot under .phenom-trash/ that is mentioned
          // in the result so the model knows recovery is possible.
          const hasOverwrite = 'overwrite' in args ? Boolean(args.overwrite) : true;
          if (hasOverwrite === false) {
            const bakPath = writePath + '.bak';
            await fs.writeFile(bakPath, existingContent, 'utf-8');
            await fs.writeFile(writePath, contentStr, 'utf-8');
            const stats = await fs.stat(writePath);
            const lineCount = contentStr.split('\n').length;
            const syntaxResult = await validateSyntax(writePath);
            const baseMsg = `[BAK] ${bakPath}\n[OK] ${writePath} (${lineCount} lines, ${stats.size} bytes)`;
            if (syntaxResult.valid) {
              return { success: true, output: baseMsg, error: null };
            }
            return {
              success: true,
              output: `${baseMsg}\n${syntaxResult.output}`,
              error: syntaxResult.error
            };
          }
        }

        if (dryRun) {
          const action = append ? (isNew ? '[NOVO] append' : '[APPEND]') : '[NOVO]';
          return {
            success: true,
            output: `DRY-RUN: ${writePath} - ${action} ${contentStr.split('\n').length} linhas`,
            error: null
          };
        }

        // BUG-B-01: snapshot non-append overwrites silently before writing.
        let silentSnapshot: string | null = null;
        if (!append && existingContent !== null) {
          silentSnapshot = await snapshotBeforeWrite(writePath, existingContent);
        }

        if (append && existingContent !== null) {
          await fs.appendFile(writePath, contentStr, 'utf-8');
        } else {
          await fs.writeFile(writePath, contentStr, 'utf-8');
        }

        const stats = await fs.stat(writePath);
        const lineCount = contentStr.split('\n').length;
        const action = append && !isNew ? 'Appended' : 'Created';
        const snapshotNote = silentSnapshot ? `\n[SNAPSHOT] previous content saved at ${silentSnapshot}` : '';

        const syntaxResult = await validateSyntax(writePath);

        const baseMsg = `${action}: ${writePath} (${lineCount} lines, ${stats.size} bytes)${snapshotNote}`;
        if (syntaxResult.valid) {
          return { success: true, output: baseMsg, error: null };
        }
        return {
          success: true,
          output: `${baseMsg}\n${syntaxResult.output}`,
          error: syntaxResult.error
        };
      } catch (error: any) {
        const code = error?.code ? `[${error.code}] ` : '';
        return { success: false, output: '', error: `${code}${error.message}` };
      }
    }
  });

  register({
    name: 'create_file',
    description: 'Create a NEW file with complete content. Verify the file does not exist (path_exists) before calling. If the file already exists this call will replace it — for partial edits to an existing file, use apply_patch instead. Use overwrite=false to create a .bak backup before replacement.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'File path to create'
        },
        content: {
          type: 'string',
          description: 'Full file content to write'
        },
        overwrite: {
          type: 'boolean',
          description: '(padrão true) Se false, cria backup (.bak) antes de sobrescrever'
        }
      },
      required: ['path', 'content']
    },
    execute: async (args) => {
      const writePath = String(args.path || '').trim();
      const content = args.content;
      const contentStr = String(content ?? '');
      const overwrite = 'overwrite' in args ? Boolean(args.overwrite) : true;

      try {
        const missingPath = !writePath;
        const missingContent = !content && content !== '';
        if (missingPath || missingContent) {
          const missing = [missingPath && 'path', missingContent && 'content'].filter(Boolean).join(', ');
          return {
            success: false,
            output: '',
            error: `create_file requer "path" e "content" na MESMA chamada. Faltando: ${missing}. Schema: {"path":"<caminho do arquivo>","content":"<conteudo completo do arquivo>"}. Reenvie com ambos os campos preenchidos.`
          };
        }

        const dangerousExtensions = ['.exe', '.dll', '.so', '.dylib', '.bin', '.jar', '.war', '.ear'];
        const ext = writePath.toLowerCase().split('.').pop() || '';
        if (dangerousExtensions.includes('.' + ext)) {
          return { success: false, output: '', error: `Extension .${ext} blocked for security` };
        }

        if (contentStr.length > config.edit.fullReplaceMaxBytes) {
          return { success: false, output: '', error: `Content too large (max ${config.edit.fullReplaceMaxBytes} bytes)` };
        }

        const pathModule = await import('path');
        const dir = pathModule.dirname(writePath);
        try {
          const dirStats = await fs.stat(dir);
          if (!dirStats.isDirectory()) {
            return { success: false, output: '', error: `Parent path is not a directory: ${dir}` };
          }
        } catch {
          await fs.mkdir(dir, { recursive: true });
        }

        let existed = false;
        let existingContent: string | null = null;
        try {
          const st = await fs.stat(writePath);
          if (st.isFile()) {
            existed = true;
            existingContent = await fs.readFile(writePath, 'utf-8');
          }
        } catch {}

        let silentCreateSnap: string | null = null;
        if (existed) {
          if (existingContent === contentStr) {
            const lines = contentStr.split('\n');
            // BUG-B-03: identical content → explicit NO_OP, not bare OK.
            return {
              success: true,
              output: `[NO_OP] ${writePath} unchanged — content you sent is byte-identical to the existing file (${lines.length} lines).`,
              error: null
            };
          }
          if (overwrite === false) {
            const bakPath = writePath + '.bak';
            await fs.writeFile(bakPath, existingContent!, 'utf-8');
          } else {
            // BUG-B-01: silent snapshot on default overwrite path.
            silentCreateSnap = await snapshotBeforeWrite(writePath, existingContent!);
          }
        }

        await fs.writeFile(writePath, contentStr, 'utf-8');
        const stats = await fs.stat(writePath);
        const lines = contentStr.split('\n');
        const lineCount = lines.length;

        const syntaxResult = await validateSyntax(writePath);

        const numbered = lines.map((l, i) => `${String(i + 1).padStart(4, ' ')} │ ${l}`).join('\n');
        const snapNote = silentCreateSnap ? `\n[SNAPSHOT] previous content saved at ${silentCreateSnap}` : '';
        let diffBlock: string;
        if (!existed) {
          diffBlock = `[CREATED] ${writePath} (${lineCount} lines, ${stats.size} bytes)\n${numbered}`;
        } else if (existingContent === contentStr) {
          diffBlock = `[NO_OP] ${writePath} unchanged`;
        } else if (overwrite) {
          diffBlock = `[OVERWROTE] ${writePath} (${lineCount} lines, ${stats.size} bytes)${snapNote}\n${numbered}`;
        } else {
          const bakPath = writePath + '.bak';
          diffBlock = `[BAK] ${bakPath}\n[CREATED] ${writePath} (${lineCount} lines, ${stats.size} bytes)\n${numbered}`;
        }

        let resultOutput = diffBlock;
        if (!syntaxResult.valid && syntaxResult.error) {
          resultOutput += `\n⚠ Syntax: ${syntaxResult.error}`;
        }

        return { success: true, output: resultOutput, error: syntaxResult.error };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'apply_patch',
    description: 'Edit EXISTING file with minimal targeted changes. Supports either operations[] (search/replace) or line-range mode (startLine/endLine + replace). Must read_file first to see current content.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho do arquivo a ser editado'
        },
        startLine: {
          type: 'number',
          description: 'Linha inicial (1-based) para edição por faixa'
        },
        endLine: {
          type: 'number',
          description: 'Linha final (1-based, inclusiva) para edição por faixa'
        },
        replace: {
          type: 'string',
          description: 'Novo conteúdo para substituir a faixa startLine..endLine'
        },
        operations: {
          type: 'array',
          description: 'Lista de operações de edição',
          items: {
            type: 'object',
            properties: {
              search: {
                type: 'string',
                description: 'Texto exato a ser substituído'
              },
              replace: {
                type: 'string',
                description: 'Novo texto'
              }
            },
            required: ['search', 'replace']
          }
        }
      },
      required: ['path']
    },
    execute: async (args) => {
      try {
        const path = String(args.path || '').trim();

        if (!path) {
          return { success: false, output: '', error: 'Caminho do arquivo não fornecido' };
        }

        const rangeStart = Number(args.startLine);
        const rangeEnd = Number(args.endLine);
        const rangeReplace = typeof args.replace === 'string' ? args.replace : '';

        const rawOps = Array.isArray(args.operations)
          ? args.operations
          : (Array.isArray(args.ops) ? args.ops : []);

        try {
          const stats = await fs.stat(path);
          if (!stats.isFile()) {
            return { success: false, output: '', error: `Caminho não é arquivo: ${path}` };
          }
        } catch (error: any) {
          if (error?.code === 'ENOENT') {
            const suggestions = await suggestSimilarPaths(path, process.cwd());
            return { success: false, output: '', error: formatEnoentError('apply_patch', path, suggestions) };
          }
          throw error;
        }

        const original = await fs.readFile(path, 'utf-8');

        // Line-range mode: deterministic editing based on 1-based line positions.
        if (
          Number.isFinite(rangeStart) &&
          Number.isFinite(rangeEnd) &&
          rangeStart >= 1 &&
          rangeEnd >= rangeStart &&
          typeof args.replace === 'string'
        ) {
          const eol = original.includes('\r\n') ? '\r\n' : '\n';
          const lines = original.split(/\r?\n/);

          if (rangeEnd > lines.length) {
            return {
              success: false,
              output: '',
              error: `Faixa inválida: endLine ${rangeEnd} > total de linhas ${lines.length}`
            };
          }

          const before = lines.slice(0, rangeStart - 1);
          const after = lines.slice(rangeEnd);
          const replacementLines = rangeReplace.split(/\r?\n/);
          const updated = [...before, ...replacementLines, ...after].join(eol);

          if (updated === original) {
            return {
              success: false,
              output: '',
              error: `Patch sem alterações em ${path}. Revise a faixa ${rangeStart}-${rangeEnd}.`
            };
          }

          // BUG-B-02: absolute line-delta guard on top of the ratio.
          const origLineCount = original.split('\n').length;
          const newLineCount = updated.split('\n').length;
          const linesRemoved = origLineCount - newLineCount;
          const shrinkRatio = updated.length / Math.max(1, original.length);
          const confirmShrink = Boolean((args as any).confirmShrink);
          if (shrinkRatio < 0.2) {
            return {
              success: false,
              output: '',
              error: `Patch suspeito: resultado seria ${Math.round(shrinkRatio * 100)}% do original.`
            };
          }
          if (!confirmShrink && linesRemoved > 30 && shrinkRatio < 0.5) {
            return {
              success: false,
              output: '',
              error: `[SHRINK_GUARD] range patch removeria ${linesRemoved} linhas (${origLineCount} → ${newLineCount}). Se intencional, re-emita com confirmShrink=true.`
            };
          }

          // BUG-B-04: snapshot before destructive write.
          const rangeSnap = await snapshotBeforeWrite(path, original);
          await fs.writeFile(path, updated, 'utf-8');
          const syntaxResult = await validateSyntax(path);
          const baseMsg = `Patch aplicado em ${path} (linhas ${rangeStart}-${rangeEnd})`;
          const snapNote = rangeSnap ? `\n[SNAPSHOT] ${rangeSnap}` : '';
          const syntaxNote = (!syntaxResult.valid && syntaxResult.error)
            ? `\n⚠ Sintaxe: ${syntaxResult.error}`
            : (syntaxResult.output ? `\n${syntaxResult.output}` : '');
          return {
            success: true,
            output: baseMsg + snapNote + syntaxNote,
            error: null
          };
        }

        if (rawOps.length === 0) {
          return {
            success: false,
            output: '',
            error: 'Nenhuma operação de patch fornecida (use operations[] ou startLine/endLine + replace)'
          };
        }

        const maxOps = 10;
        if (rawOps.length > maxOps) {
          return { success: false, output: '', error: `Muitas operações (max ${maxOps}): reduza o patch` };
        }

        let updated = original;
        let applied = 0;
        const errors: string[] = [];
        // BUG-B-11: collect EOL normalization events so we surface them
        // instead of silently rewriting CRLF → LF.
        let eolNormalized = false;
        // BUG-B-05: track ambiguity rejections so the model knows to narrow
        // its search with more context lines.
        const ambiguities: string[] = [];

        for (const rawOp of rawOps) {
          const find = String(rawOp?.find ?? rawOp?.search ?? '');
          const replace = String(rawOp?.replace ?? '');
          const replaceAll = Boolean(rawOp?.replaceAll);

          if (!find) {
            errors.push('Operação sem "search"');
            continue;
          }

          const normalizedFind = find.trim();

          if (normalizedFind && normalizedFind === original.trim()) {
            return { success: false, output: '', error: 'Patch rejeitado: tentativa de reescrita total do arquivo' };
          }

          // BUG-B-05: when replaceAll=false, count occurrences first. If
          // the search appears in multiple places, refuse rather than
          // silently mutating only the first one — the model often emits
          // a snippet that legitimately occurs N times and the wrong site
          // gets edited. The "narrow your search with more context" hint
          // teaches the model the fix.
          const escapedFind = find.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          if (!replaceAll) {
            const matches = updated.match(new RegExp(escapedFind, 'g'));
            if (matches && matches.length > 1) {
              ambiguities.push(
                `apply_patch AMBIGUOUS — "${find.slice(0, 60).replace(/\n/g, '\\n')}" appears ${matches.length} times in ${path}. ` +
                `Include surrounding lines in "search" to make the match unique, OR set replaceAll=true if every occurrence should change.`
              );
              continue;
            }
          }
          const regex = new RegExp(escapedFind);
          let testReplace = replaceAll
            ? updated.replace(new RegExp(escapedFind, 'g'), replace)
            : updated.replace(regex, replace);

          // Fallback pragmático: muitos modelos geram LF enquanto o arquivo está em CRLF.
          // Se não houver match literal, tentamos patch em versão LF normalizada.
          if (testReplace === updated) {
            const updatedLf = updated.replace(/\r\n/g, '\n');
            const findLf = find.replace(/\r\n/g, '\n');
            const replaceLf = replace.replace(/\r\n/g, '\n');
            const escapedFindLf = findLf.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            const regexLf = new RegExp(escapedFindLf);
            const testReplaceLf = replaceAll
              ? updatedLf.replace(new RegExp(escapedFindLf, 'g'), replaceLf)
              : updatedLf.replace(regexLf, replaceLf);

            if (testReplaceLf !== updatedLf) {
              // BUG-B-11: file was CRLF, fallback worked on LF — flag it so
              // the result message says so; do NOT silently rewrite EOLs.
              if (original.includes('\r\n')) {
                eolNormalized = true;
              }
              testReplace = testReplaceLf;
            }
          }

          if (testReplace === updated) {
            const preview = find.slice(0, 80).replace(/\n/g, '\\n');
            const hint = buildPatchHint(updated, find);
            // Make the failure explicit so the model doesn't claim success in
            // its prose response while the patch silently failed. The directive
            // points to read_file as the corrective action — most "not found"
            // failures are the model inventing content it never read.
            const directive = hint
              ? ` | ${hint} — abra o arquivo (read_file) para copiar o texto literal antes de re-emitir apply_patch.`
              : ` | O texto não existe nesse caminho. NÃO conclua que o patch funcionou: chame read_file(path) primeiro, depois apply_patch com o texto exato (incluindo indentação, aspas, espaços).`;
            errors.push(`apply_patch FAILED — "Não encontrado" em ${path}: "${preview}"${directive}`);
            continue;
          }

          updated = testReplace;
          applied += 1;
        }

        // BUG-B-05: ambiguity rejections short-circuit before any write.
        // If every op was ambiguous, return as a clean failure with the hint.
        const allErrors = [...errors, ...ambiguities];
        if (applied === 0 && allErrors.length > 0) {
          return { success: false, output: '', error: allErrors.join('; ') };
        }

        if (applied === 0) {
          return {
            success: false,
            output: '',
            error: `Patch sem alterações em ${path}. Revise "search" para match exato (incluindo espaços/linhas).`
          };
        }

        const shrinkRatio = updated.length / Math.max(1, original.length);
        if (shrinkRatio < 0.2) {
          return {
            success: false,
            output: '',
            error: `Patch suspeito: resultado seria ${Math.round(shrinkRatio * 100)}% do original. Use apply_patch com edições menores.`
          };
        }

        // BUG-B-02: absolute line-delta guard.
        const origLineCount2 = original.split('\n').length;
        const newLineCount2 = updated.split('\n').length;
        const linesRemoved2 = origLineCount2 - newLineCount2;
        const confirmShrink2 = Boolean((args as any).confirmShrink);
        if (!confirmShrink2 && linesRemoved2 > 30 && shrinkRatio < 0.5) {
          return {
            success: false,
            output: '',
            error: `[SHRINK_GUARD] ops patch removeria ${linesRemoved2} linhas (${origLineCount2} → ${newLineCount2}). Se intencional, re-emita com confirmShrink=true.`
          };
        }

        // BUG-B-04: snapshot before destructive write.
        const opsSnap = await snapshotBeforeWrite(path, original);
        await fs.writeFile(path, updated, 'utf-8');

        const syntaxResult = await validateSyntax(path);
        // BUG-B-06: surface partial-error info even when applied > 0 so the
        // model knows some ops didn't land.
        const partialNote = allErrors.length > 0
          ? `\n[PARTIAL] ${applied}/${rawOps.length} ops applied; ${allErrors.length} skipped: ${allErrors.slice(0, 3).join(' | ')}`
          : '';
        const snapNote = opsSnap ? `\n[SNAPSHOT] ${opsSnap}` : '';
        const eolNote = eolNormalized
          ? `\n[EOL_NORMALIZED] file was CRLF; the LF-fallback rewrote it as LF. If line endings must be preserved, re-save with CRLF or use the range-mode apply_patch.`
          : '';
        const baseMsg = `Patch aplicado em ${path} (${applied}/${rawOps.length} operações)`;
        const syntaxNote = (!syntaxResult.valid && syntaxResult.error)
          ? `\n⚠ Sintaxe: ${syntaxResult.error}`
          : (syntaxResult.output ? `\n${syntaxResult.output}` : '');
        return {
          success: true,
          output: baseMsg + snapNote + eolNote + partialNote + syntaxNote,
          error: null
        };
      } catch (error: any) {
        const code = error?.code ? `[${error.code}] ` : '';
        return { success: false, output: '', error: `${code}${error.message}` };
      }
    }
  });

  register({
    name: 'list_dir',
    description: 'List directory entries with path context',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho do diretório a listar'
        }
      },
      required: ['path']
    },
    execute: async (args) => {
      try {
        const targetPath = String(args.path || '').trim();
        if (!targetPath) {
          return { success: false, output: '', error: 'Caminho do diretório não fornecido' };
        }
        const entries = await fs.readdir(targetPath, { withFileTypes: true });
        const formatted = entries
          .map((entry) => entry.isDirectory() ? `${entry.name}/` : entry.name)
          .sort((a, b) => a.localeCompare(b));
        const output = [
          '[LIST_DIR]',
          `path: ${targetPath}`,
          `entries: ${formatted.length}`,
          '---BEGIN ENTRIES---',
          ...formatted,
          '---END ENTRIES---'
        ].join('\n');
        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });
}

function buildPatchHint(fileContent: string, search: string): string {
  const firstNeedleLine = search
    .split('\n')
    .map(l => l.trim())
    .find(l => l.length > 0);

  if (!firstNeedleLine) return '';

  const lines = fileContent.split('\n');
  const idx = lines.findIndex(l => l.includes(firstNeedleLine));
  if (idx < 0) return '';

  const start = Math.max(0, idx - 1);
  const end = Math.min(lines.length, idx + 2);
  const snippet = lines.slice(start, end)
    .map((l, i) => `${start + i + 1}: ${l.trimEnd()}`)
    .join(' | ');

  return `Contexto aproximado: ${snippet}`;
}
