import chalk from 'chalk';
import { createTwoFilesPatch } from 'diff';
import { DiffRenderer } from './diff-renderer.js';

export class OutputFormatter {
  private static diffRenderer = new DiffRenderer('github');
  // Símbolos visuais para diferentes tipos de operações
  static readonly SYMBOLS = {
    GLOB: '✱',
    READ: '→',
    WRITE: '✎',
    EDIT: '✏',
    DELETE: '✗',
    EXECUTE: '⚡',
    SUCCESS: '✓',
    ERROR: '✗',
    WARNING: '⚠',
    INFO: 'ℹ',
    SEARCH: '🔍',
    GIT: '⎇',
    THINKING: '💭',
    WORKING: '⚙'
  };

  /**
   * Formata output de ferramentas com símbolos visuais
   */
  static formatToolOutput(toolName: string, args: any, result: any): string {
    const lines: string[] = [];

    switch (toolName) {
      case 'read_file':
        lines.push(chalk.cyan(`${this.SYMBOLS.READ} Read ${args.path}`));
        if (result.success) {
          const lineCount = result.output.split('\n').length;
          lines.push(chalk.gray(`  ${lineCount} lines`));
        }
        break;

      case 'write_file':
        lines.push(chalk.green(`${this.SYMBOLS.WRITE} Write ${args.path}`));
        if (result.success) {
          const size = Buffer.byteLength(args.content, 'utf-8');
          lines.push(chalk.gray(`  ${size} bytes written`));
        } else {
          lines.push(chalk.red(`  Error: ${result.error}`));
        }
        break;

      case 'list_dir':
        const files = result.output.split('\n').filter((f: string) => f.trim());
        lines.push(chalk.cyan(`${this.SYMBOLS.GLOB} Glob "${args.path}" (${files.length} matches)`));
        break;

      case 'search_code': {
        const needle = args.query || args.pattern || '';
        lines.push(chalk.cyan(`${this.SYMBOLS.SEARCH} Grep "${needle}"`));
        if (result.success && result.output !== 'Nenhum resultado encontrado') {
          const matches = result.output.split('\n').filter((l: string) => l.trim()).length;
          lines.push(chalk.gray(`  ${matches} matches`));
        }
        break;
      }

      case 'path_exists':
        lines.push(chalk.cyan(`${this.SYMBOLS.INFO} Check path ${args.path}`));
        if (result.success) {
          lines.push(chalk.gray(`  ${result.output}`));
        }
        break;

      case 'git_status':
      case 'git_diff':
      case 'git_log':
      case 'git_add':
      case 'git_commit':
        lines.push(chalk.magenta(`${this.SYMBOLS.GIT} ${toolName.replace('git_', 'git ')}`));
        break;

      case 'run_code':
        lines.push(chalk.yellow(`${this.SYMBOLS.EXECUTE} Execute: ${args.command}`));
        break;

      default:
        lines.push(chalk.white(`${this.SYMBOLS.WORKING} ${toolName}`));
    }

    return lines.join('\n');
  }

  /**
   * Formata diff de arquivo com cores
   */
  static formatFileDiff(filePath: string, oldContent: string, newContent: string): string {
    const header = chalk.bold(`\n📝 ${filePath}`);
    const diff = this.diffRenderer.renderFileDiff(
      filePath,
      filePath,
      oldContent,
      newContent,
      { theme: 'github', showLineNumbers: true, context: 3 }
    );
    const stats = this.diffRenderer.renderStats(oldContent, newContent);
    return `${header}\n${stats}\n${diff}`;
  }

  /**
   * Formata criação de arquivo com cores
   */
  static formatFileCreation(filePath: string, content: string): string {
    const header = chalk.bold(`\n✨ Criado: ${filePath}`);
    const diff = this.diffRenderer.renderFileDiff(
      '/dev/null',
      filePath,
      '',
      content,
      { theme: 'github', showLineNumbers: true, context: 3 }
    );
    const lineCount = content.split('\n').length;
    const stats = chalk.green(`+${lineCount} linhas`);
    return `${header}\n${stats}\n${diff}`;
  }

  /**
   * Formata progresso de tarefa
   */
  static formatProgress(current: number, total: number, currentTask: string): string {
    const percentage = Math.round((current / total) * 100);
    const filled = Math.floor(percentage / 5);
    const bar = '█'.repeat(filled) + '░'.repeat(20 - filled);
    
    return [
      chalk.blue(`[${bar}] ${percentage}% (${current}/${total})`),
      chalk.gray(`  ${currentTask}`)
    ].join('\n');
  }

  /**
   * Formata mensagem de contexto
   */
  static formatContext(goal: string, currentStep: string): string {
    return [
      chalk.cyan(`\n📍 Objetivo: ${goal}`),
      chalk.gray(`   Passo: ${currentStep}`)
    ].join('\n');
  }

  /**
   * Formata erro
   */
  static formatError(error: string, context?: string): string {
    const lines = [chalk.red(`${this.SYMBOLS.ERROR} Erro: ${error}`)];
    if (context) {
      lines.push(chalk.gray(`   Contexto: ${context}`));
    }
    return lines.join('\n');
  }

  /**
   * Formata sucesso
   */
  static formatSuccess(message: string): string {
    return chalk.green(`${this.SYMBOLS.SUCCESS} ${message}`);
  }

  /**
   * Formata aviso
   */
  static formatWarning(message: string): string {
    return chalk.yellow(`${this.SYMBOLS.WARNING} ${message}`);
  }
}
