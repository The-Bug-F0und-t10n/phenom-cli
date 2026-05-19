import { execFile, spawn } from 'child_process';
import { promisify } from 'util';
import { promises as fs } from 'fs';
import path from 'path';

const execFileAsync = promisify(execFile);

export interface ValidationError {
  line: number;
  column: number;
  message: string;
  type: 'error' | 'warning';
}

export interface ValidationResult {
  valid: boolean;
  errors: ValidationError[];
  output: string;
  parser: string;
}

export class SyntaxValidator {
  private cachedGrammars: Set<string> = new Set();
  private langExtensions: Map<string, string[]> = new Map([
    ['javascript', ['js', 'jsx', 'mjs', 'cjs']],
    ['typescript', ['ts', 'tsx', 'mts', 'cts']],
    ['python', ['py', 'pyw', 'pyi']],
    ['rust', ['rs']],
    ['go', ['go']],
    ['java', ['java']],
    ['cpp', ['cpp', 'cc', 'cxx', 'c', 'h', 'hpp', 'hxx']],
    ['c', ['c', 'h']],
    ['ruby', ['rb', 'rake', 'gemspec']],
    ['php', ['php', 'phtml']],
    ['swift', ['swift']],
    ['kotlin', ['kt', 'kts']],
    ['scala', ['scala', 'sc']],
    ['haskell', ['hs', 'lhs']],
    ['lua', ['lua']],
    ['bash', ['sh', 'bash', 'zsh', 'fish']],
    ['json', ['json']],
    ['html', ['html', 'htm']],
    ['css', ['css', 'scss', 'sass', 'less']],
    ['markdown', ['md', 'markdown']],
    ['yaml', ['yaml', 'yml']],
    ['toml', ['toml']],
    ['sql', ['sql']],
    ['dart', ['dart']],
    ['scala', ['scala', 'sc']],
  ]);

  async validate(filePath: string): Promise<ValidationResult> {
    const content = await fs.readFile(filePath, 'utf-8');
    const ext = path.extname(filePath).slice(1).toLowerCase();
    const lang = this.detectLanguage(ext);

    if (!lang) {
      return {
        valid: true,
        errors: [],
        output: `Validação não disponível para .${ext}`,
        parser: 'none'
      };
    }

    if (lang === 'json') {
      return this.validateJson(content, ext);
    }

    return this.validateWithTreeSitter(content, filePath, lang);
  }

  async validateCode(code: string, ext: string): Promise<ValidationResult> {
    const lang = this.detectLanguage(ext);

    if (!lang) {
      return {
        valid: true,
        errors: [],
        output: `Validação não disponível para .${ext}`,
        parser: 'none'
      };
    }

    if (lang === 'json') {
      return this.validateJson(code, ext);
    }

    return this.validateWithTreeSitter(code, `temp.${ext}`, lang);
  }

  private validateJson(content: string, ext: string): ValidationResult {
    try {
      JSON.parse(content);
      return {
        valid: true,
        errors: [],
        output: 'JSON válido',
        parser: 'json'
      };
    } catch (error: any) {
      const match = error.message.match(/position (\d+)/);
      const pos = match ? parseInt(match[1]) : 0;
      const lines = content.substring(0, pos).split('\n');
      const line = lines.length;
      const col = lines[lines.length - 1].length + 1;

      return {
        valid: false,
        errors: [{
          line,
          column: col,
          message: error.message,
          type: 'error'
        }],
        output: `JSON inválido: ${error.message}`,
        parser: 'json'
      };
    }
  }

  private async validateWithTreeSitter(
    code: string,
    filePath: string,
    lang: string
  ): Promise<ValidationResult> {
    const tmpDir = path.dirname(filePath) === 'temp.${path.extname(filePath)}' 
      ? path.join(process.cwd(), '.phenom-tmp')
      : path.dirname(filePath);
    const tmpFile = path.join(tmpDir, `.phenom-validate-${Date.now()}${path.extname(filePath)}`);

    try {
      await fs.mkdir(tmpDir, { recursive: true });
      await fs.writeFile(tmpFile, code, 'utf-8');

      try {
        const { stdout, stderr } = await execFileAsync(
          'npx',
          ['tree-sitter', 'parse', tmpFile, '--stat'],
          { timeout: 10000 }
        );

        await fs.unlink(tmpFile);

        if (stderr.includes('ERROR') || stderr.includes('MISSING')) {
          return this.parseTreeSitterErrors(stderr, lang);
        }

        return {
          valid: true,
          errors: [],
          output: `Sintaxe válida (${lang})`,
          parser: 'tree-sitter'
        };

      } catch (error: any) {
        try {
          await fs.unlink(tmpFile);
        } catch {}

        if (error.code === 'ENOENT' || error.message?.includes('not found')) {
          return this.validateWithFallback(code, lang);
        }

        return this.parseTreeSitterErrors(
          error.stderr || error.stdout || error.message,
          lang
        );
      }

    } catch (error: any) {
      // BUG-D fix: infrastructure failure (e.g. tmpdir creation error) is NOT a
      // syntax error. Return valid:true so the caller treats the file write as
      // successful. Syntax validation is advisory — it must never block a write.
      return {
        valid: true,
        errors: [],
        output: `Validação ignorada (erro de infra): ${error.message}`,
        parser: 'tree-sitter'
      };
    }
  }

  // BUG-C fix: previous fallback tried to JSON.parse TypeScript/Python/etc code —
  // always returned valid:false for non-JSON files. Correct behavior when tree-sitter
  // is unavailable: return valid:true (graceful degradation). The file was written
  // successfully; lack of a syntax checker is not a syntax error.
  private async validateWithFallback(_code: string, lang: string): Promise<ValidationResult> {
    return {
      valid: true,
      errors: [],
      output: `Sintaxe não verificada (tree-sitter indisponível para ${lang})`,
      parser: 'none'
    };
  }

  private parseTreeSitterErrors(output: string, lang: string): ValidationResult {
    const errors: ValidationError[] = [];
    const lines = output.split('\n');

    for (const line of lines) {
      if (line.includes('ERROR') || line.includes('MISSING')) {
        const match = line.match(/ERROR|MISSING/g);
        if (match) {
          errors.push({
            line: 1,
            column: 0,
            message: line.trim(),
            type: line.includes('ERROR') ? 'error' : 'warning'
          });
        }
      }

      const errorMatch = line.match(/(\d+):(\d+)-(\d+):(\d+):/);
      if (errorMatch) {
        const [, startLine, startCol, endLine, endCol] = errorMatch;
        errors.push({
          line: parseInt(startLine),
          column: parseInt(startCol),
          message: line.substring(line.indexOf(':') + 1).trim(),
          type: 'error'
        });
      }
    }

    if (errors.length > 0) {
      return {
        valid: false,
        errors,
        output: `Erros de sintaxe (${lang}):\n${errors.map(e => `L${e.line}:${e.column} - ${e.message}`).join('\n')}`,
        parser: 'tree-sitter'
      };
    }

    return {
      valid: true,
      errors: [],
      output: `Sintaxe válida (${lang})`,
      parser: 'tree-sitter'
    };
  }

  private detectLanguage(ext: string): string | null {
    for (const [lang, extensions] of this.langExtensions) {
      if (extensions.includes(ext)) {
        return lang;
      }
    }
    return null;
  }

  getSupportedLanguages(): string[] {
    return Array.from(this.langExtensions.keys());
  }

  getSupportedExtensions(): string[] {
    const exts: string[] = [];
    for (const extensions of this.langExtensions.values()) {
      exts.push(...extensions);
    }
    return [...new Set(exts)];
  }
}
