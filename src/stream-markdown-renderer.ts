import chalk from 'chalk';

/**
 * Incremental markdown renderer for streaming output.
 *
 * Processes incoming text chunks line by line. Complete lines are rendered
 * immediately with ANSI colours. The last incomplete line is held as pending
 * and only rendered when flushPending() is called (stream end).
 *
 * No redraws, no cursor movement — output is strictly append-only, so it
 * works safely inside the cli-renderer's streamLineOpen path.
 */
export class StreamMarkdownRenderer {
  private pending = '';
  private inCodeBlock = false;
  private codeLang = '';

  /**
   * Feed a raw text chunk. Returns the rendered complete lines (may be empty
   * string if the chunk didn't complete any line). The caller writes this
   * directly to stdout.
   */
  processChunk(chunk: string): string {
    const combined = this.pending + chunk;
    const lines = combined.split('\n');
    // Last element is the new (possibly incomplete) pending line.
    this.pending = lines.pop() ?? '';
    if (lines.length === 0) return '';
    return lines.map(l => this.renderLine(l)).join('\n') + '\n';
  }

  /**
   * Flush the accumulated pending (incomplete) line. Call at stream end.
   * Returns the rendered text (without trailing newline unless the line
   * itself contained one).
   */
  flushPending(): string {
    const line = this.pending;
    this.pending = '';
    if (!line) return '';
    return this.renderLine(line);
  }

  /** Reset all state (call when a new inference starts). */
  reset(): void {
    this.pending = '';
    this.inCodeBlock = false;
    this.codeLang = '';
  }

  // ── Line-level rendering ──────────────────────────────────────────────

  private renderLine(raw: string): string {
    // ── Code fence boundary ──────────────────────────────────────────
    const fence = raw.match(/^(```+)(\w*)(.*)$/);
    if (fence) {
      if (!this.inCodeBlock) {
        this.inCodeBlock = true;
        this.codeLang = fence[2].toLowerCase();
        return chalk.gray(raw);
      } else {
        this.inCodeBlock = false;
        this.codeLang = '';
        return chalk.gray(raw);
      }
    }

    // ── Inside code block ────────────────────────────────────────────
    if (this.inCodeBlock) {
      return highlightCode(raw, this.codeLang);
    }

    // ── Diff / patch markers ─────────────────────────────────────────
    if (raw.startsWith('--- ') || raw.startsWith('+++ ')) return chalk.gray(raw);
    if (raw.startsWith('@@'))                               return chalk.cyan(raw);
    if (raw.startsWith('+'))                               return chalk.green(raw);
    if (raw.startsWith('-'))                               return chalk.red(raw);

    // ── Headings ─────────────────────────────────────────────────────
    const h6 = raw.match(/^#{6}\s+(.+)$/); if (h6) return chalk.white.bold(raw);
    const h5 = raw.match(/^#{5}\s+(.+)$/); if (h5) return chalk.white.bold(raw);
    const h4 = raw.match(/^#{4}\s+(.+)$/); if (h4) return chalk.yellow.bold(raw);
    const h3 = raw.match(/^###\s+(.+)$/);  if (h3) return chalk.green.bold(raw);
    const h2 = raw.match(/^##\s+(.+)$/);   if (h2) return chalk.cyan.bold(raw);
    const h1 = raw.match(/^#\s+(.+)$/);    if (h1) return chalk.magenta.bold(raw);

    // ── Horizontal rule ───────────────────────────────────────────────
    if (/^[-*_]{3,}\s*$/.test(raw)) return chalk.gray('─'.repeat(48));

    // ── Blockquote ────────────────────────────────────────────────────
    const bq = raw.match(/^>\s?(.*)$/);
    if (bq) return chalk.gray('│ ') + chalk.italic(renderInline(bq[1]));

    // ── Bullets and numbered lists ────────────────────────────────────
    const ul = raw.match(/^(\s*)([-*+])\s(.+)$/);
    if (ul) return ul[1] + chalk.cyan('•') + ' ' + renderInline(ul[3]);

    const ol = raw.match(/^(\s*)(\d+\.)\s(.+)$/);
    if (ol) return ol[1] + chalk.cyan(ol[2]) + ' ' + renderInline(ol[3]);

    // ── Plain paragraph ───────────────────────────────────────────────
    return renderInline(raw);
  }
}

// ── Inline markdown (bold, italic, code spans) ────────────────────────────

function renderInline(text: string): string {
  if (!text) return text;
  return text
    // bold+italic
    .replace(/\*\*\*(.+?)\*\*\*/g, (_, m) => chalk.bold.italic(m))
    // bold
    .replace(/\*\*(.+?)\*\*/g, (_, m) => chalk.bold(m))
    .replace(/__(.+?)__/g,     (_, m) => chalk.bold(m))
    // italic
    .replace(/\*(.+?)\*/g,  (_, m) => chalk.italic(m))
    .replace(/_(.+?)_/g,    (_, m) => chalk.italic(m))
    // strikethrough
    .replace(/~~(.+?)~~/g, (_, m) => chalk.strikethrough(m))
    // inline code
    .replace(/`(.+?)`/g, (_, m) => chalk.yellow(m));
}

// ── Syntax highlighting for code blocks ───────────────────────────────────

function highlightCode(line: string, lang: string): string {
  if (lang === 'ts' || lang === 'typescript' || lang === 'js' || lang === 'javascript') {
    return line
      .replace(/\b(const|let|var|function|class|interface|type|enum|namespace|abstract)\b/g, m => chalk.magenta(m))
      .replace(/\b(import|export|from|as|default)\b/g, m => chalk.blue(m))
      .replace(/\b(async|await|return|new|typeof|instanceof|void|null|undefined|true|false)\b/g, m => chalk.cyan(m))
      .replace(/\b(if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw)\b/g, m => chalk.yellow(m))
      .replace(/(\/\/[^\n]*)/g, m => chalk.gray(m))
      .replace(/(['"`])(?:(?=(\\?))\2.)*?\1/g, m => chalk.green(m))
      .replace(/\b(\d+(\.\d+)?)\b/g, m => chalk.yellow(m));
  }

  if (lang === 'py' || lang === 'python') {
    return line
      .replace(/\b(def|class|import|from|as|return|lambda|yield|async|await)\b/g, m => chalk.magenta(m))
      .replace(/\b(if|elif|else|for|while|with|try|except|finally|raise|pass|break|continue|in|not|and|or|is)\b/g, m => chalk.yellow(m))
      .replace(/\b(True|False|None)\b/g, m => chalk.cyan(m))
      .replace(/#[^\n]*/g, m => chalk.gray(m))
      .replace(/(['"`]{1,3})(?:(?=(\\?))\2.)*?\1/g, m => chalk.green(m));
  }

  if (lang === 'sh' || lang === 'bash' || lang === 'shell') {
    return line
      .replace(/^(\s*)(#[^\n]*)/g, (_, sp, c) => sp + chalk.gray(c))
      .replace(/\b(echo|cd|ls|mkdir|rm|cp|mv|cat|grep|sed|awk|curl|git|npm|npx|node)\b/g, m => chalk.cyan(m))
      .replace(/(['"])(?:(?=(\\?))\2.)*?\1/g, m => chalk.green(m))
      .replace(/\$\{?[\w]+\}?/g, m => chalk.yellow(m));
  }

  // Fallback: dim to distinguish from prose
  return chalk.dim(line);
}
