import { diffLines, diffWords, Change } from 'diff';
import chalk from 'chalk';

export interface DiffOptions {
  theme?: 'github' | 'default';
  context?: number;
  showLineNumbers?: boolean;
}

export class DiffRenderer {
  private theme: 'github' | 'default';

  constructor(theme: 'github' | 'default' = 'github') {
    this.theme = theme;
  }

  renderDiff(oldText: string, newText: string, options: DiffOptions = {}): string {
    const theme = options.theme || this.theme;
    const showLineNumbers = options.showLineNumbers !== false;
    const context = options.context || 3;

    const changes = diffLines(oldText, newText);
    
    return this.formatChanges(changes, theme, showLineNumbers, context);
  }

  renderWordDiff(oldText: string, newText: string): string {
    const changes = diffWords(oldText, newText);
    
    return changes.map(change => {
      if (change.added) {
        return this.theme === 'github' 
          ? chalk.bgGreen.black(change.value)
          : chalk.green(change.value);
      }
      if (change.removed) {
        return this.theme === 'github'
          ? chalk.bgRed.black(change.value)
          : chalk.red(change.value);
      }
      return change.value;
    }).join('');
  }

  private formatChanges(
    changes: Change[], 
    theme: 'github' | 'default',
    showLineNumbers: boolean,
    _context: number
  ): string {
    const lines: string[] = [];
    let oldLineNum = 1;
    let newLineNum = 1;

    // Header
    if (theme === 'github') {
      lines.push(chalk.bold('diff --git'));
      lines.push(chalk.bold('--- a/file'));
      lines.push(chalk.bold('+++ b/file'));
    }

    for (const change of changes) {
      const changeLines = change.value.split('\n');
      
      // Remover última linha vazia
      if (changeLines[changeLines.length - 1] === '') {
        changeLines.pop();
      }

      for (const line of changeLines) {
        let formattedLine = '';

        if (change.added) {
          if (showLineNumbers) {
            formattedLine = this.formatLineNumber('', newLineNum, theme);
          }
          formattedLine += this.formatAddedLine(line, theme);
          newLineNum++;
        } else if (change.removed) {
          if (showLineNumbers) {
            formattedLine = this.formatLineNumber(oldLineNum, '', theme);
          }
          formattedLine += this.formatRemovedLine(line, theme);
          oldLineNum++;
        } else {
          if (showLineNumbers) {
            formattedLine = this.formatLineNumber(oldLineNum, newLineNum, theme);
          }
          formattedLine += this.formatContextLine(line, theme);
          oldLineNum++;
          newLineNum++;
        }

        lines.push(formattedLine);
      }
    }

    return lines.join('\n');
  }

  private formatLineNumber(
    oldNum: number | string, 
    newNum: number | string, 
    theme: 'github' | 'default'
  ): string {
    const oldStr = oldNum ? oldNum.toString().padStart(4) : '    ';
    const newStr = newNum ? newNum.toString().padStart(4) : '    ';
    
    if (theme === 'github') {
      return chalk.gray(`${oldStr} ${newStr} │ `);
    }
    return chalk.gray(`${oldStr} ${newStr} │ `);
  }

  private formatAddedLine(line: string, theme: 'github' | 'default'): string {
    if (theme === 'github') {
      return chalk.bgGreen.black('+') + chalk.green(line);
    }
    return chalk.green(`+ ${line}`);
  }

  private formatRemovedLine(line: string, theme: 'github' | 'default'): string {
    if (theme === 'github') {
      return chalk.bgRed.black('-') + chalk.red(line);
    }
    return chalk.red(`- ${line}`);
  }

  private formatContextLine(line: string, theme: 'github' | 'default'): string {
    if (theme === 'github') {
      return chalk.gray(' ') + line;
    }
    return `  ${line}`;
  }

  // Renderizar diff de arquivo completo
  renderFileDiff(
    oldPath: string,
    newPath: string,
    oldContent: string,
    newContent: string,
    options: DiffOptions = {}
  ): string {
    const theme = options.theme || this.theme;
    const lines: string[] = [];

    // Header estilo GitHub
    if (theme === 'github') {
      lines.push(chalk.bold(`diff --git a/${oldPath} b/${newPath}`));
      lines.push(chalk.bold(`--- a/${oldPath}`));
      lines.push(chalk.bold(`+++ b/${newPath}`));
      lines.push(chalk.cyan('@@ -1,1 +1,1 @@'));
    }

    lines.push(this.renderDiff(oldContent, newContent, options));

    return lines.join('\n');
  }

  // Renderizar estatísticas do diff
  renderStats(oldText: string, newText: string): string {
    const changes = diffLines(oldText, newText);
    
    let added = 0;
    let removed = 0;

    for (const change of changes) {
      const lineCount = change.value.split('\n').length - 1;
      if (change.added) added += lineCount;
      if (change.removed) removed += lineCount;
    }

    const addedStr = chalk.green(`+${added}`);
    const removedStr = chalk.red(`-${removed}`);

    return `${addedStr} ${removedStr}`;
  }

  // Renderizar diff lado a lado (split view)
  renderSplitDiff(oldText: string, newText: string, width: number = 80): string {
    const changes = diffLines(oldText, newText);
    const halfWidth = Math.floor(width / 2) - 2;
    const lines: string[] = [];

    // Header
    lines.push(
      chalk.bold('Old'.padEnd(halfWidth)) + 
      chalk.gray(' │ ') + 
      chalk.bold('New')
    );
    lines.push(chalk.gray('─'.repeat(halfWidth) + '─┼─' + '─'.repeat(halfWidth)));

    for (const change of changes) {
      const changeLines = change.value.split('\n').filter(l => l !== '');

      for (const line of changeLines) {
        const truncated = line.substring(0, halfWidth - 2);
        
        if (change.removed) {
          lines.push(
            chalk.bgRed.black(truncated.padEnd(halfWidth)) +
            chalk.gray(' │ ') +
            ' '.repeat(halfWidth)
          );
        } else if (change.added) {
          lines.push(
            ' '.repeat(halfWidth) +
            chalk.gray(' │ ') +
            chalk.bgGreen.black(truncated.padEnd(halfWidth))
          );
        } else {
          lines.push(
            truncated.padEnd(halfWidth) +
            chalk.gray(' │ ') +
            truncated.padEnd(halfWidth)
          );
        }
      }
    }

    return lines.join('\n');
  }
}
