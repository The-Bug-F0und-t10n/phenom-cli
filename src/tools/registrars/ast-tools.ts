import path from 'path';
import { promises as fs } from 'fs';
import type { Tool } from '../../tools.js';
import { parseFile, parseSource, formatSummary, detectLanguage, type SupportedLanguage } from '../../ast-parser.js';

interface RegisterAstToolsDeps {
  register: (tool: Tool) => void;
}

const PROJECT_ROOT = path.resolve(process.cwd());

function validatePath(rawPath: string): { ok: true; abs: string } | { ok: false; error: string } {
  const abs = path.resolve(PROJECT_ROOT, rawPath);
  if (abs !== PROJECT_ROOT && !abs.startsWith(PROJECT_ROOT + path.sep)) {
    return { ok: false, error: `path fora do projeto: ${abs}` };
  }
  return { ok: true, abs };
}

export function registerAstTools(deps: RegisterAstToolsDeps): void {
  const { register } = deps;

  register({
    name: 'parse_ast',
    description:
      'Parse a source file with tree-sitter and return a compact structural summary: imports, top-level classes/types (with their methods), top-level functions, and exports — each with line numbers. ' +
      'Use this BEFORE editing an unfamiliar file to know its shape without reading the whole content. Cheaper than read_file for orientation. ' +
      'Supported languages: TypeScript (.ts/.tsx/.mts/.cts), JavaScript (.js/.mjs/.cjs/.jsx — parsed via TS grammar), Python (.py/.pyi), Go (.go), Rust (.rs), Java (.java), C (.c/.h), C++ (.cpp/.hpp). ' +
      'Output is plain text, line-stable, and safe to grep. Errors count is reported if the file has parse errors.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho do arquivo (relativo à raiz do projeto ou absoluto dentro dela)'
        },
        code: {
          type: 'string',
          description: 'Alternativa a `path`: parsear código inline. Requer também `language`.'
        },
        language: {
          type: 'string',
          description: 'Linguagem quando `code` é usado: typescript | tsx | javascript | python | go | rust | java | c | cpp'
        }
      },
      required: []
    },
    execute: async (args) => {
      const rawPath = args.path ? String(args.path).trim() : '';
      const rawCode = args.code != null ? String(args.code) : '';
      const rawLang = args.language ? String(args.language).trim().toLowerCase() : '';

      try {
        if (rawCode) {
          if (!rawLang) return { success: false, output: '', error: '`language` é obrigatório quando `code` é informado.' };
          const lang = rawLang as SupportedLanguage;
          const sum = parseSource(rawCode, lang);
          return { success: true, output: formatSummary('<inline>', sum), error: null };
        }
        if (!rawPath) return { success: false, output: '', error: 'Informe `path` ou (`code` + `language`).' };

        const guard = validatePath(rawPath);
        if (!guard.ok) return { success: false, output: '', error: guard.error };

        const stats = await fs.stat(guard.abs).catch(() => null);
        if (!stats || !stats.isFile()) return { success: false, output: '', error: `arquivo não encontrado: ${guard.abs}` };

        const lang = detectLanguage(guard.abs);
        if (!lang) {
          return {
            success: false,
            output: '',
            error: `extensão não suportada: ${path.extname(guard.abs)} (suportadas: .ts/.tsx/.js/.jsx/.py/.pyi/.go/.rs/.java/.c/.h/.cpp/.hpp)`
          };
        }

        const sum = await parseFile(guard.abs);
        const rel = path.relative(PROJECT_ROOT, guard.abs) || '.';
        return { success: true, output: formatSummary(rel, sum), error: null };
      } catch (e: any) {
        return { success: false, output: '', error: `parse_ast falhou: ${e.message}` };
      }
    }
  });
}
