import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal';
import chalk from 'chalk';

export class MarkdownRenderer {
  constructor() {
    // Configurar marked com terminal renderer
    marked.use(markedTerminal({
      code: chalk.yellow,
      blockquote: chalk.gray.italic,
      html: chalk.gray,
      heading: chalk.green.bold,
      firstHeading: chalk.magenta.underline.bold,
      hr: chalk.reset,
      listitem: chalk.reset,
      list: (body: string) => body,
      table: chalk.reset,
      paragraph: chalk.reset,
      strong: chalk.bold,
      em: chalk.italic,
      codespan: chalk.yellow,
      del: chalk.dim.gray.strikethrough,
      link: chalk.blue,
      href: chalk.blue.underline
    }) as any);
  }

  render(markdown: string): string {
    try {
      return marked(markdown) as string;
    } catch (error) {
      return markdown;
    }
  }

  renderInline(markdown: string): string {
    try {
      return marked.parseInline(markdown) as string;
    } catch (error) {
      return markdown;
    }
  }

  // Renderizar código com syntax highlighting básico
  renderCode(code: string, language: string = ''): string {
    const lines = code.split('\n');
    const numbered = lines.map((line, i) => {
      const lineNum = chalk.gray(`${(i + 1).toString().padStart(3)} │ `);
      return lineNum + this.highlightSyntax(line, language);
    });

    const header = chalk.gray(`┌─ ${language || 'code'} ─`);
    const footer = chalk.gray('└' + '─'.repeat(50));

    return `${header}\n${numbered.join('\n')}\n${footer}`;
  }

  private highlightSyntax(line: string, language: string): string {
    // Highlighting básico por linguagem
    if (language === 'typescript' || language === 'javascript') {
      return line
        .replace(/\b(const|let|var|function|class|interface|type|import|export|from|async|await|return)\b/g, chalk.magenta('$1'))
        .replace(/\b(if|else|for|while|switch|case|break|continue)\b/g, chalk.cyan('$1'))
        .replace(/(['"`])(?:(?=(\\?))\2.)*?\1/g, chalk.green('$&'))
        .replace(/\/\/.*/g, chalk.gray('$&'))
        .replace(/\b(\d+)\b/g, chalk.yellow('$1'));
    }

    if (language === 'python') {
      return line
        .replace(/\b(def|class|import|from|return|async|await|lambda)\b/g, chalk.magenta('$1'))
        .replace(/\b(if|elif|else|for|while|break|continue|pass|with|try|except|finally)\b/g, chalk.cyan('$1'))
        .replace(/(['"`])(?:(?=(\\?))\2.)*?\1/g, chalk.green('$&'))
        .replace(/#.*/g, chalk.gray('$&'))
        .replace(/\b(\d+)\b/g, chalk.yellow('$1'));
    }

    return line;
  }

  // Renderizar tabela
  renderTable(headers: string[], rows: string[][]): string {
    const colWidths = headers.map((h, i) => {
      const maxRowWidth = Math.max(...rows.map(r => (r[i] || '').length));
      return Math.max(h.length, maxRowWidth);
    });

    const renderRow = (cells: string[]) => {
      return '│ ' + cells.map((cell, i) => 
        cell.padEnd(colWidths[i])
      ).join(' │ ') + ' │';
    };

    const separator = '├─' + colWidths.map(w => '─'.repeat(w)).join('─┼─') + '─┤';
    const top = '┌─' + colWidths.map(w => '─'.repeat(w)).join('─┬─') + '─┐';
    const bottom = '└─' + colWidths.map(w => '─'.repeat(w)).join('─┴─') + '─┘';

    const lines = [
      chalk.gray(top),
      chalk.bold(renderRow(headers)),
      chalk.gray(separator),
      ...rows.map(row => renderRow(row)),
      chalk.gray(bottom)
    ];

    return lines.join('\n');
  }

  // Renderizar lista
  renderList(items: string[], ordered: boolean = false): string {
    return items.map((item, i) => {
      const bullet = ordered ? chalk.cyan(`${i + 1}.`) : chalk.cyan('•');
      return `  ${bullet} ${item}`;
    }).join('\n');
  }

  // Renderizar blockquote
  renderBlockquote(text: string): string {
    return text.split('\n').map(line => 
      chalk.gray('│ ') + chalk.italic(line)
    ).join('\n');
  }

  // Renderizar heading
  renderHeading(text: string, level: number): string {
    const colors = [
      chalk.magenta.bold.underline,
      chalk.cyan.bold,
      chalk.green.bold,
      chalk.yellow.bold,
      chalk.blue.bold,
      chalk.white.bold
    ];

    const color = colors[level - 1] || chalk.white.bold;
    const prefix = '#'.repeat(level);
    
    return color(`${prefix} ${text}`);
  }
}
