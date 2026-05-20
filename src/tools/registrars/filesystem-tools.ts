import { promises as fs } from 'fs';
import { config } from '../../config.js';
import type { Tool } from '../../tools.js';

interface RegisterFilesystemToolsDeps {
  register: (tool: Tool) => void;
  validateSyntax: (filePath: string) => Promise<{ valid: boolean; output: string; error: string | null }>;
}

export function registerFilesystemTools(deps: RegisterFilesystemToolsDeps): void {
  const { register, validateSyntax } = deps;

  register({
    name: 'read_file',
    description: 'Read a slice of a file. Default behavior is MICRO-CONTEXT: at most 200 lines per call. Use grep_file or find_function FIRST to locate the relevant lines, then call read_file with startLine/endLine for the targeted range. Reading entire large files wastes context — only do that for short files (<200 lines) or when whole-file reasoning is genuinely required (pass wholeFile=true).',
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
          description: 'Linha final (1-based, inclusiva). Default: min(startLine + 199, total). Limite máximo de 200 linhas por leitura sem wholeFile=true.'
        },
        wholeFile: {
          type: 'boolean',
          description: 'Force reading the entire file regardless of size. Use sparingly — only for files <500 lines or when whole-file analysis is genuinely needed.'
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

        const MICRO_LINE_CAP = 200;
        const wholeFile = Boolean(args.wholeFile);
        const startRaw = Number(args.startLine);
        const endRaw = Number(args.endLine);
        const hasStartLine = Number.isFinite(startRaw);
        const hasEndLine = Number.isFinite(endRaw);
        const hasRange = hasStartLine || hasEndLine;

        let rangeStart = hasStartLine ? Math.max(1, Math.floor(startRaw)) : 1;
        let rangeEnd: number;
        if (hasEndLine) {
          rangeEnd = Math.max(rangeStart, Math.floor(endRaw));
        } else if (wholeFile) {
          rangeEnd = totalLines;
        } else {
          // Micro-context default: cap window at MICRO_LINE_CAP lines from start.
          rangeEnd = Math.min(totalLines, rangeStart + MICRO_LINE_CAP - 1);
        }

        if (hasRange && (rangeStart > totalLines || rangeEnd > totalLines)) {
          return {
            success: false,
            output: '',
            error: `Faixa inválida: ${rangeStart}-${rangeEnd}. Total de linhas: ${totalLines}`
          };
        }

        // Soft enforcement of MICRO_LINE_CAP unless wholeFile.
        let rangeClipped = false;
        if (!wholeFile && (rangeEnd - rangeStart + 1) > MICRO_LINE_CAP) {
          rangeEnd = rangeStart + MICRO_LINE_CAP - 1;
          rangeClipped = true;
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

        const truncated = numbered.length > maxChars;
        const body = truncated
          ? numbered.slice(0, maxChars) + `\n...[truncated: ${numbered.length - maxChars} chars omitted]`
          : numbered;

        const remainingLines = totalLines - rangeEnd;
        const hints: string[] = [];
        if (rangeClipped) {
          hints.push(`hint: requested range exceeded ${MICRO_LINE_CAP}-line micro-context cap; clipped to ${rangeStart}-${rangeEnd}. Use grep_file/find_function to target the section you need.`);
        }
        if (remainingLines > 0) {
          hints.push(`hint: ${remainingLines} more lines available (${rangeEnd + 1}..${totalLines}). Call read_file again with startLine=${rangeEnd + 1} for the next window, OR grep_file to jump to a specific region.`);
        }

        const meta = [
          '[READ_FILE]',
          `path: ${readPath}`,
          `lines: ${totalLines}`,
          `bytes: ${totalBytes}`,
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
        return { success: false, output: '', error: error.message };
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
            return {
              success: true,
              output: `[OK] ${writePath} ja atualizado (${contentStr.split('\n').length} lines)`,
              error: null
            };
          }

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

        if (append && existingContent !== null) {
          await fs.appendFile(writePath, contentStr, 'utf-8');
        } else {
          await fs.writeFile(writePath, contentStr, 'utf-8');
        }

        const stats = await fs.stat(writePath);
        const lineCount = contentStr.split('\n').length;
        const action = append && !isNew ? 'Appended' : 'Created';

        const syntaxResult = await validateSyntax(writePath);

        const baseMsg = `${action}: ${writePath} (${lineCount} lines, ${stats.size} bytes)`;
        if (syntaxResult.valid) {
          return { success: true, output: baseMsg, error: null };
        }
        return {
          success: true,
          output: `${baseMsg}\n${syntaxResult.output}`,
          error: syntaxResult.error
        };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
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

        if (existed) {
          if (existingContent === contentStr) {
            const lines = contentStr.split('\n');
            return {
              success: true,
              output: `[OK] ${writePath} ja atualizado (${lines.length} lines)`,
              error: null
            };
          }
          if (overwrite === false) {
            const bakPath = writePath + '.bak';
            await fs.writeFile(bakPath, existingContent!, 'utf-8');
          }
        }

        await fs.writeFile(writePath, contentStr, 'utf-8');
        const stats = await fs.stat(writePath);
        const lines = contentStr.split('\n');
        const lineCount = lines.length;

        const syntaxResult = await validateSyntax(writePath);

        const numbered = lines.map((l, i) => `${String(i + 1).padStart(4, ' ')} │ ${l}`).join('\n');
        let diffBlock: string;
        if (!existed) {
          diffBlock = `[CREATED] ${writePath} (${lineCount} lines, ${stats.size} bytes)\n${numbered}`;
        } else if (existingContent === contentStr) {
          diffBlock = `[OK] ${writePath} unchanged`;
        } else if (overwrite) {
          diffBlock = `[OVERWROTE] ${writePath} (${lineCount} lines, ${stats.size} bytes)\n${numbered}`;
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
            return { success: false, output: '', error: `Arquivo não existe para apply_patch: ${path}` };
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

          const shrinkRatio = updated.length / Math.max(1, original.length);
          if (shrinkRatio < 0.2) {
            return {
              success: false,
              output: '',
              error: `Patch suspeito: resultado seria ${Math.round(shrinkRatio * 100)}% do original.`
            };
          }

          await fs.writeFile(path, updated, 'utf-8');
          const syntaxResult = await validateSyntax(path);
          const baseMsg = `Patch aplicado em ${path} (linhas ${rangeStart}-${rangeEnd})`;
          const syntaxNote = (!syntaxResult.valid && syntaxResult.error)
            ? `\n⚠ Sintaxe: ${syntaxResult.error}`
            : (syntaxResult.output ? `\n${syntaxResult.output}` : '');
          return {
            success: true,
            output: baseMsg + syntaxNote,
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

          const escapedFind = find.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
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
              // Mantemos LF no arquivo atualizado quando esta estratégia é usada.
              testReplace = testReplaceLf;
            }
          }

          if (testReplace === updated) {
            const preview = find.slice(0, 60).replace(/\n/g, '\\n');
            const hint = buildPatchHint(updated, find);
            errors.push(`Não encontrado: "${preview}"${hint ? ` | Dica: ${hint}` : ''}`);
            continue;
          }

          updated = testReplace;
          applied += 1;
        }

        if (errors.length > 0 && applied === 0) {
          return { success: false, output: '', error: errors.join('; ') };
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

        await fs.writeFile(path, updated, 'utf-8');

        const syntaxResult = await validateSyntax(path);
        const baseMsg = `Patch aplicado em ${path} (${applied} operações)`;
        const syntaxNote = (!syntaxResult.valid && syntaxResult.error)
          ? `\n⚠ Sintaxe: ${syntaxResult.error}`
          : (syntaxResult.output ? `\n${syntaxResult.output}` : '');
        return {
          success: true,
          output: baseMsg + syntaxNote,
          error: null
        };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
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
