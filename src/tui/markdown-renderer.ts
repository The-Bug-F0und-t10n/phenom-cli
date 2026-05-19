/**
 * Markdown Renderer - Renderiza markdown completo para terminal
 * com suporte a diff colorido estilo GitHub.
 */

import chalk from 'chalk';
import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal';

export class MarkdownRenderer {
  constructor() {
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
      return marked(markdown || '') as string;
    } catch {
      return markdown || '';
    }
  }

  renderDiff(diff: string): string {
    const lines = String(diff || '').split('\n');
    const out = lines.map(line => this.colorDiffLine(line));
    return out.join('\n');
  }

  private colorDiffLine(line: string): string {
    if (line.startsWith('diff --git') || line.startsWith('index ')) {
      return chalk.gray(line);
    }
    if (line.startsWith('new file mode') || line.startsWith('deleted file mode')) {
      return chalk.gray(line);
    }
    if (line.startsWith('---') || line.startsWith('+++')) {
      return chalk.whiteBright(line);
    }
    if (line.startsWith('@@')) {
      return chalk.cyan.bold(line);
    }
    if (line.startsWith('+')) {
      return chalk.green(line);
    }
    if (line.startsWith('-')) {
      return chalk.red(line);
    }
    return chalk.gray(line);
  }
}

export const markdownRenderer = new MarkdownRenderer();
