import { promises as fs } from 'fs';
import type { Tool } from '../../tools.js';

interface RegisterNavigationToolsDeps {
  register: (tool: Tool) => void;
  execFileAsync: (file: string, args: string[], options?: { maxBuffer?: number }) => Promise<{ stdout: string; stderr: string }>;
}

export function registerNavigationTools(deps: RegisterNavigationToolsDeps): void {
  const { register, execFileAsync } = deps;

  register({
    name: 'find_function',
    description: 'Find function/class/const definitions with full signature and body. Returns complete code blocks.',
    parameters: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: 'Nome da função, classe ou constante a buscar'
        },
        path: {
          type: 'string',
          description: 'Caminho onde buscar (padrão: diretório atual)'
        },
        extractBody: {
          type: 'boolean',
          description: 'Se true, extrai corpo completo da função (padrão: true)'
        }
      },
      required: ['name']
    },
    execute: async (args) => {
      try {
        const name = String(args.name || '').trim();
        const searchPath = String(args.path || '.').trim();
        const extractBody = args.extractBody !== false;

        if (!name) {
          return { success: false, output: '', error: 'Nome não fornecido' };
        }

        const patterns = [
          `^\\s*function\\s+${name}\\s*\\(`,
          `^\\s*const\\s+${name}\\s*=`,
          `^\\s*let\\s+${name}\\s*=`,
          `^\\s*var\\s+${name}\\s*=`,
          `^\\s*class\\s+${name}\\s*`,
          `^\\s*interface\\s+${name}\\s*`,
          `^\\s*type\\s+${name}\\s*=`,
          `^\\s*export\\s+(function|const|let|var|class|interface|type)\\s+${name}`
        ];

        const pattern = `(${patterns.join('|')})`;

        const rgArgs = [
          '--line-number',
          '--no-heading',
          '--glob', '!**/node_modules/**',
          '--glob', '!**/dist/**',
          '--glob', '!**/.git/**',
          pattern,
          searchPath
        ];

        const { stdout } = await execFileAsync('rg', rgArgs, { maxBuffer: 10 * 1024 * 1024 });

        if (!stdout.trim()) {
          return { success: true, output: `Nenhuma definição encontrada para: ${name}`, error: null };
        }

        const results: string[] = [];

        for (const line of stdout.split('\n')) {
          if (!line.trim()) continue;

          const match = line.match(/^([^:]+):(\d+):(.*)$/);
          if (!match) continue;

          const [, file, lineNumStr, signature] = match;
          const lineNum = parseInt(lineNumStr, 10);

          if (!extractBody) {
            results.push(`${file}:${lineNum}\n${signature.trim()}`);
            continue;
          }

          try {
            const content = await fs.readFile(file, 'utf-8');
            const lines = content.split('\n');

            let braceCount = 0;
            let endLine = lineNum;
            let started = false;

            for (let i = lineNum - 1; i < lines.length; i++) {
              const currentLine = lines[i];
              for (const char of currentLine) {
                if (char === '{') {
                  braceCount++;
                  started = true;
                }
                if (char === '}') braceCount--;
              }
              if (started && braceCount === 0) {
                endLine = i + 1;
                break;
              }
              if (i - lineNum > 500) {
                endLine = i + 1;
                break;
              }
            }

            const block = lines.slice(lineNum - 1, endLine).join('\n');
            const lineCount = endLine - lineNum + 1;

            results.push(
              `${file}:${lineNum}-${endLine} (${lineCount} lines)\n` +
              `\x1b[36m${'─'.repeat(60)}\x1b[0m\n` +
              block +
              `\n\x1b[36m${'─'.repeat(60)}\x1b[0m`
            );
          } catch (error: any) {
            results.push(`${file}:${lineNum}\n${signature.trim()}\n(Erro ao extrair corpo: ${error.message})`);
          }
        }

        if (results.length === 0) {
          return { success: true, output: `Nenhuma definição encontrada para: ${name}`, error: null };
        }

        return { success: true, output: results.join('\n\n'), error: null };
      } catch (error: any) {
        if (error.code === 'ENOENT') {
          return { success: false, output: '', error: 'rg não encontrado' };
        }
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'extract_block',
    description: 'Extract complete code block from file starting at specific line (function, class, if, loop, etc). Uses brace matching.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Caminho do arquivo'
        },
        startLine: {
          type: 'number',
          description: 'Linha inicial do bloco'
        },
        endLine: {
          type: 'number',
          description: 'Linha final (opcional, se não fornecido usa matching de chaves)'
        }
      },
      required: ['path', 'startLine']
    },
    execute: async (args) => {
      try {
        const filePath = String(args.path || '').trim();
        const startLine = Number.parseInt(String(args.startLine || 0), 10);
        const endLineArg = args.endLine ? Number.parseInt(String(args.endLine), 10) : null;

        if (!filePath) {
          return { success: false, output: '', error: 'Caminho não fornecido' };
        }

        if (!startLine || startLine < 1) {
          return { success: false, output: '', error: 'startLine inválido' };
        }

        const content = await fs.readFile(filePath, 'utf-8');
        const lines = content.split('\n');

        if (startLine > lines.length) {
          return { success: false, output: '', error: `startLine ${startLine} maior que total de linhas ${lines.length}` };
        }

        let endLine: number;

        if (endLineArg) {
          endLine = Math.min(endLineArg, lines.length);
        } else {
          let braceCount = 0;
          let started = false;
          endLine = startLine;

          for (let i = startLine - 1; i < lines.length; i++) {
            const line = lines[i];
            for (const char of line) {
              if (char === '{') {
                braceCount++;
                started = true;
              }
              if (char === '}') braceCount--;
            }
            if (started && braceCount === 0) {
              endLine = i + 1;
              break;
            }
            if (i - startLine > 1000) {
              endLine = i + 1;
              break;
            }
          }

          if (!started) {
            endLine = startLine;
          }
        }

        const block = lines.slice(startLine - 1, endLine).join('\n');
        const lineCount = endLine - startLine + 1;

        const output = [
          `${filePath}:${startLine}-${endLine} (${lineCount} lines)`,
          `\x1b[36m${'─'.repeat(60)}\x1b[0m`,
          block,
          `\x1b[36m${'─'.repeat(60)}\x1b[0m`
        ].join('\n');

        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });
}
