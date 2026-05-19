import chalk from 'chalk';
import readline from 'readline';
import { eventBus, EventType } from './tui/event-bus.js';

interface PendingFileDiff {
  path: string;
  lineCount: number;
  byteSize: number;
  action: 'created' | 'updated' | 'replaced' | 'patched' | 'deleted';
  content: string;
}

export class CliRenderer {
  private streaming: boolean = false;
  private streamBuffer: string = '';
  private streamingBlockId: string | null = null;
  private streamingContent: string = '';
  private rl: readline.Interface | null = null;
  private history: string[] = [];
  private maxHistory: number = 500;
  private firstRender: boolean = true;
  /** When stdout is not a TTY (pipe mode), use plain console.log instead of ANSI cursor control. */
  private plain: boolean = !process.stdout.isTTY;

  private statusVisible: boolean = false;
  private currentAction: string = '';
  private actionStartTime: number = 0;
  private inferenceStart: number = 0;
  private startTokens: number = 0;
  private tokenTotal: number = 0;
  private tokenDirection: 'up' | 'down' = 'down';
  private opLabel: string = '';
  private thinkStarted: boolean = false;
  private statusInterval: NodeJS.Timeout | null = null;
  private statusSpinnerIndex: number = 0;
  private statusSpinnerLast: number = 0;
  private readonly statusSpinnerFrames = ['.  ', '.. ', '...'];
  private lastStatusLine: string = '';
  private reasoningBuffer: string = '';
  private renderTimer: ReturnType<typeof setTimeout> | null = null;
  private streamLineOpen: boolean = false;
  private committedAssistantByInference: string = '';
  private attached: boolean = false;
  private unsubscribers: Array<() => void> = [];
  private pendingFileDiffs: Map<string, PendingFileDiff> = new Map();

  /**
   * Number of terminal lines the dynamic area occupies (content ABOVE the prompt).
   * Prompt is NOT counted — it is always the last line.
   */
  private activeLines: number = 0;
  /** Current user input text (preserved across active-area redraws). */
  private promptBuffer: string = '';

  private get output(): NodeJS.WriteStream {
    return ((this.rl as any)?.output ?? process.stdout) as NodeJS.WriteStream;
  }

  bindReadline(rl: readline.Interface): void {
    this.rl = rl;
    if (this.output.on) {
      this.output.on('resize', () => this.reflow());
    }
    process.on('SIGWINCH', () => this.reflow());

    if (process.stdin.isTTY) {
      readline.emitKeypressEvents(process.stdin, this.rl as any);
      process.stdin.setRawMode(true);
      process.stdin.on('keypress', (_str, key) => {
        if (key?.name === 'escape') {
          eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'cancelled by user' });
        }
      });
    }
  }

  /** Set the current user input text and redraw everything. */
  showInput(buf: string): void {
    if (this.plain) return;
    this.promptBuffer = buf;
    this.renderActive();
  }

  attach(): void {
    if (this.attached) return;
    this.attached = true;

    this.unsubscribers.push(eventBus.on(EventType.USER_MESSAGE, (event) => {
      const content = String(event.payload?.content || '').trim();
      if (content && !content.startsWith('/')) {
        this.writeBlock('[user] ' + content);
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.AGENT_MESSAGE, (event) => {
      const content = String(event.payload.content || '');
      const normalized = content.trim();
      const fallback = this.streamBuffer;

      // If stream is still active and AGENT_MESSAGE matches streamed text,
      // defer finalization to THINK_END to avoid rendering the same output twice.
      if (this.streamingBlockId && normalized && normalized === this.streamBuffer.trim()) {
        return;
      }

      if (normalized && normalized === this.committedAssistantByInference) {
        return;
      }
      if (content) {
        this.finalizeStreaming('[assistant] ' + content);
      } else if (fallback) {
        this.finalizeStreaming('[assistant] ' + fallback);
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.MESSAGE_CHUNK, (event) => {
      const chunk = this.normalizeChunk(event.payload.chunk || '');
      if (!chunk) return;
      this.streaming = true;
      this.streamBuffer += chunk;
      this.streamingContent = this.streamBuffer;
      this.ensureStreamingBlock();
      // In interactive TTY, stream append-only to avoid redraw drift/scroll artifacts.
      if (!this.plain && this.rl) {
        this.clearActive();
        if (!this.streamLineOpen) {
          readline.cursorTo(this.output, 0);
          this.output.write('\x1b[K');
          this.output.write('[assistant] ');
          this.streamLineOpen = true;
        }
        this.output.write(chunk);
        return;
      }
      if (!this.statusVisible && this.thinkStarted) {
        this.showStatusLine();
      }
      this.scheduleRender();
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_START, (event) => {
      const { name, args } = event.payload;
      const parts: string[] = ['[tool:', name + ']'];
      if (args.path) parts.push(args.path);
      if (name === 'run_code' && args.command) {
        parts.push('`' + String(args.command).slice(0, 60) + '`');
      }
      this.writeBlock(parts.join(' '));
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_RESULT, (event) => {
      const { result } = event.payload;
      if (result?.success) {
        const summary = result.output
          ? String(result.output).split('\n')[0].slice(0, 120)
          : 'OK';
        this.writeBlock('  ' + chalk.green('->') + ' ' + summary);
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_ERROR, (event) => {
      this.writeBlock('  ' + chalk.red('->') + ' ' + (event.payload.error || 'failed'));
    }));

    this.unsubscribers.push(eventBus.on(EventType.FILE_DIFF, (event) => {
      const { path, lineCount, byteSize, action, content } = event.payload;
      if (!path) return;
      const normalizedAction = action === 'created' || action === 'deleted' || action === 'patched' || action === 'replaced'
        ? action
        : 'updated';
      this.pendingFileDiffs.set(String(path), {
        path: String(path),
        lineCount: Number(lineCount || 0),
        byteSize: Number(byteSize || 0),
        action: normalizedAction,
        content: String(content || '')
      });
    }));

    this.unsubscribers.push(eventBus.on(EventType.INFERENCE_CANCEL, (event) => {
      this.clearStreamingBlock();
      this.clearStatusLine();
      this.writeBlock(chalk.red('[cancelled] ' + (event?.payload?.reason || 'cancelled')));
      this.streaming = false;
      this.streamBuffer = '';
    }));

    this.unsubscribers.push(eventBus.on(EventType.CLEAR_STREAMING, () => {
      if (this.streamLineOpen) {
        this.output.write('\n');
        this.streamLineOpen = false;
      }
      this.clearStreamingBlock();
      this.streamBuffer = '';
      this.renderActive();
    }));

    this.unsubscribers.push(eventBus.on(EventType.THINK_END, () => {
      if (this.streamLineOpen) {
        this.output.write('\n');
        this.streamLineOpen = false;
      }
      if (this.reasoningBuffer.trim()) {
        this.writeBlock(chalk.cyan('[thinking] ') + this.reasoningBuffer);
      }
      this.reasoningBuffer = '';
      if (this.renderTimer) { clearTimeout(this.renderTimer); this.renderTimer = null; }
      this.clearStatusLine();
      if (this.streamBuffer.trim()) {
        this.streaming = false;
        this.finalizeStreaming('[assistant] ' + this.streamBuffer);
        this.streamBuffer = '';
      }
      this.flushPendingFileDiffs();
      this.streaming = false;
      this.writeBlock(chalk.green('[done]'));
    }));

    this.unsubscribers.push(eventBus.on(EventType.THINK_START, (event) => {
      this.committedAssistantByInference = '';
      this.reasoningBuffer = '';
      this.pendingFileDiffs.clear();
      this.startThink(event?.payload?.message || 'Thinking');
    }));

    this.unsubscribers.push(eventBus.on(EventType.REASONING_CHUNK, (event) => {
      const chunk = this.normalizeChunk(event.payload?.chunk || '');
      if (!chunk) return;
      this.reasoningBuffer += chunk;
      if (!this.statusVisible && this.thinkStarted) {
        this.showStatusLine();
      }
      this.scheduleRender();
    }));

    this.unsubscribers.push(eventBus.on(EventType.PROGRESS_UPDATE, (event) => {
      this.currentAction = event.payload.message || '';
      if (!this.thinkStarted) {
        this.actionStartTime = Date.now();
      }
      this.opLabel = this.deriveOpLabel(this.currentAction, this.opLabel);
      this.showStatusLine();
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOKEN_UPDATE, (event) => {
      if (event?.payload) {
        if (typeof event.payload.total === 'number' && Number.isFinite(event.payload.total)) {
          this.tokenTotal = Math.max(0, event.payload.total);
        }
        if (typeof event.payload.output === 'number' && event.payload.output > 0) {
          this.tokenDirection = 'up';
        } else if (typeof event.payload.input === 'number' && event.payload.input > 0) {
          this.tokenDirection = 'down';
        }
        if (!this.statusVisible && this.thinkStarted) {
          this.showStatusLine();
        }
        this.scheduleRender();
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.SEARCH_START, (event) => {
      this.writeBlock(chalk.cyan('[search] ' + event.payload.query));
    }));

    this.unsubscribers.push(eventBus.on(EventType.SEARCH_RESULTS, (event) => {
      this.writeBlock(chalk.gray('  -> ' + event.payload.resultsCount + ' results'));
    }));

    this.unsubscribers.push(eventBus.on(EventType.SEARCH_ERROR, (event) => {
      this.writeBlock(chalk.red('[search] error: ' + event.payload.error));
    }));
  }

  // ── Active area management ──────────────────────────────────────────

  /**
   * Remove the active area (content lines above the prompt).
   * Uses line-clearing (\x1b[K) instead of screen-clearing (\x1b[J)
   * to avoid viewport misalignment when user has scrolled up.
   */
  private clearActive(): void {
    if (this.activeLines <= 0) return;
    this.output.write(`\x1b[${this.activeLines}A`);
    readline.cursorTo(this.output, 0);
    for (let i = 0; i < this.activeLines; i++) {
      this.output.write('\x1b[K');
      if (i < this.activeLines - 1) this.output.write('\n');
    }
    readline.cursorTo(this.output, 0);
    this.activeLines = 0;
  }

  private stripAnsi(text: string): string {
    return text.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, '');
  }

  private countVisualLines(text: string, width: number): number {
    const lines = text.split('\n');
    let total = 0;
    for (const line of lines) {
      const visible = this.stripAnsi(line).length;
      total += visible > 0 ? Math.ceil(visible / Math.max(1, width)) : 1;
    }
    return total;
  }

  private countLines(items: string[], width?: number): number {
    const w = Math.max(1, width ?? this.output.columns ?? process.stdout.columns ?? 80);
    let n = 0;
    for (const item of items) n += this.countVisualLines(item, w);
    return n;
  }

  private clampToWidth(line: string, width: number): string {
    const max = Math.max(1, width - 1);
    const visible = this.stripAnsi(line);
    if (visible.length <= max) return line;
    return visible.slice(0, Math.max(0, max - 3)) + '...';
  }

  private normalizeChunk(chunk: string): string {
    return String(chunk || '').replace(/\r/g, '');
  }

  /**
   * Redraw the active area (reasoning + streaming + status) and the prompt.
   * Assumes cursor is on the prompt line (last line).
   */
  private renderActive(): void {
    if (this.plain) return;
    this.clearActive();

    const parts: string[] = [];
    const maxW = this.output.columns || process.stdout.columns || 80;

    // 1. Reasoning block (dimmed, only visible during thinking)
    if (this.thinkStarted && this.reasoningBuffer) {
      const lines = this.reasoningBuffer.split('\n').filter(l => l.trim());
      if (lines.length > 0) {
        const MAX_LOGICAL_LINES = 8;
        const shown = lines.length > MAX_LOGICAL_LINES
          ? lines.slice(-MAX_LOGICAL_LINES)
          : lines;
        for (const line of shown) {
          const truncated = this.clampToWidth(line, maxW);
          parts.push(chalk.gray('  ' + truncated));
        }
      }
    }

    // 2. Streaming assistant preview (non-direct mode only).
    if (!this.streamLineOpen && this.streamingBlockId && this.streamingContent) {
      const previewLines = this.streamingContent.split('\n');
      const MAX_PREVIEW_LINES = 12;
      const shown = previewLines.length > MAX_PREVIEW_LINES
        ? previewLines.slice(-MAX_PREVIEW_LINES)
        : previewLines;
      if (shown.length > 0) {
        parts.push(this.clampToWidth('[assistant] ' + shown[0], maxW));
        for (let i = 1; i < shown.length; i++) {
          parts.push(this.clampToWidth(shown[i], maxW));
        }
      }
    }

    // 3. Status line (counters)
    if (this.statusVisible && this.thinkStarted) {
      const s = this.getStatusLine();
      if (s) parts.push(chalk.gray(this.clampToWidth(s, maxW)));
    }

    const contentLines = this.countLines(parts, maxW);
    if (contentLines > 0) {
      this.output.write(parts.join('\n') + '\n');
    }
    this.activeLines = contentLines;

    // Write prompt at the bottom
    readline.cursorTo(this.output, 0);
    this.output.write('> ' + this.promptBuffer);
    if (!this.promptBuffer) {
      readline.cursorTo(this.output, 2);
    } else {
      readline.cursorTo(this.output, 2 + this.promptBuffer.length);
    }
  }

  private scheduleRender(): void {
    if (this.streamLineOpen) return;
    if (this.renderTimer) return;
    this.renderTimer = setTimeout(() => {
      this.renderTimer = null;
      this.renderActive();
    }, 40);
  }

  // ── Public API ──────────────────────────────────────────────────────

  private writeBlock(text: string, record: boolean = true): void {
    if (record) {
      this.history.push(text);
      if (this.history.length > this.maxHistory) this.history.shift();
    }
    if (this.streamLineOpen) {
      this.output.write('\n');
      this.streamLineOpen = false;
    }
    if (this.plain) {
      console.log(text);
      return;
    }

    this.clearActive();
    readline.cursorTo(this.output, 0);
    this.output.write('\x1b[K');
    this.output.write(text + '\n');
    this.firstRender = false;
    this.activeLines = 0;
    this.renderActive();
  }

  // ── Streaming ───────────────────────────────────────────────────────

  private ensureStreamingBlock(): void {
    if (this.streamingBlockId) return;
    this.streamingBlockId = Date.now() + '-' + Math.random().toString(16).slice(2, 8);
  }

  private finalizeStreaming(content: string): void {
    if (this.streamingBlockId) {
      const streamedText = this.streamBuffer;
      const incomingText = String(content || '').replace(/^\[assistant\]\s*/, '');

      if (this.streamLineOpen) {
        this.output.write('\n');
      }
      this.streamLineOpen = false;
      this.streamingBlockId = null;
      this.streamingContent = '';
      this.streaming = false;

      // Persist what was streamed exactly once.
      if (streamedText.trim()) {
        if (this.plain || !this.rl) {
          this.writeBlock('[assistant] ' + streamedText);
        } else {
          this.history.push('[assistant] ' + streamedText);
          if (this.history.length > this.maxHistory) this.history.shift();
        }
        this.committedAssistantByInference = streamedText.trim();
      }

      // If AGENT_MESSAGE differs from streamed content, emit it as a new block.
      if (incomingText.trim() && incomingText.trim() !== streamedText.trim()) {
        this.writeBlock('[assistant] ' + incomingText);
        this.committedAssistantByInference = incomingText.trim();
      }
      return;
    }
    const normalized = String(content || '').replace(/^\[assistant\]\s*/, '').trim();
    if (normalized && normalized === this.committedAssistantByInference) {
      return;
    }
    this.writeBlock(content);
    if (normalized) this.committedAssistantByInference = normalized;
  }

  private clearStreamingBlock(): void {
    this.streamingBlockId = null;
    this.streamingContent = '';
    this.streaming = false;
    this.streamLineOpen = false;
  }

  // ── Status line ─────────────────────────────────────────────────────

  private startThink(message: string): void {
    this.currentAction = message || 'Working';
    this.actionStartTime = Date.now();
    this.inferenceStart = Date.now();
    this.tokenTotal = 0;
    this.startTokens = 0;
    this.tokenDirection = 'down';
    this.opLabel = this.deriveOpLabel(this.currentAction, '');
    this.thinkStarted = true;
    this.statusVisible = false;
    this.scheduleRender();
  }

  private showStatusLine(): void {
    if (this.statusInterval) clearInterval(this.statusInterval);
    this.statusVisible = true;
    this.statusInterval = setInterval(() => this.scheduleRender(), 1000);
    this.scheduleRender();
  }

  private clearStatusLine(): void {
    this.statusVisible = false;
    this.lastStatusLine = '';
    this.thinkStarted = false;
    if (this.statusInterval) {
      clearInterval(this.statusInterval);
      this.statusInterval = null;
    }
  }

  private getStatusLine(): string | null {
    if (!this.statusVisible || !this.thinkStarted) return null;
    const elapsed = this.formatDuration(Date.now() - this.actionStartTime);
    const arrow = this.tokenDirection === 'down' ? '\u2193' : '\u2191';
    const deltaTokens = Math.max(0, this.tokenTotal - this.startTokens);
    const tokenStr = ' ' + arrow + ' ' + this.formatTokenCount(deltaTokens) + ' tokens';
    const label = this.opLabel || 'Working';
    const spinner = this.getSpinnerFrame();
    return label + ' ' + spinner + ' (' + elapsed + tokenStr + ' \u00B7 esc to interrupt)';
  }

  private getSpinnerFrame(): string {
    const now = Date.now();
    if (now - this.statusSpinnerLast > 300) {
      this.statusSpinnerIndex = (this.statusSpinnerIndex + 1) % this.statusSpinnerFrames.length;
      this.statusSpinnerLast = now;
    }
    return this.statusSpinnerFrames[this.statusSpinnerIndex] || '...';
  }

  private deriveOpLabel(message: string, fallback: string): string {
    const text = String(message || '').toLowerCase();
    if (text.includes('thinking') || text.includes('work')) return 'Working';
    if (text.includes('create') || text.includes('criar') || text.includes('write')) return 'Writing';
    if (text.includes('edit') || text.includes('alter') || text.includes('patch')) return 'Editing';
    if (text.includes('search') || text.includes('busca') || text.includes('grep')) return 'Searching';
    if (text.includes('read') || text.includes('ler')) return 'Reading';
    if (text.includes('list') || text.includes('dir')) return 'Exploring';
    return fallback || 'Working';
  }

  private flushPendingFileDiffs(): void {
    if (this.pendingFileDiffs.size === 0) return;
    for (const diff of this.pendingFileDiffs.values()) {
      const label = diff.action === 'created'
        ? 'created'
        : diff.action === 'deleted'
          ? 'deleted'
          : diff.action === 'patched'
            ? 'patched'
            : 'updated';

      this.writeBlock(chalk.cyan(`  [file] ${diff.path} — ${diff.lineCount} lines, ${diff.byteSize} B (${label})`));
      if (diff.content) {
        const marker = this.markerForAction(diff.action);
        const lines = diff.content.replace(/\n$/, '').split('\n');
        for (const line of lines) {
          this.writeBlock('  ' + this.decorateDiffLine(line, marker));
        }
      }
    }
    this.pendingFileDiffs.clear();
  }

  private markerForAction(action: PendingFileDiff['action']): '+' | '-' | '~' {
    if (action === 'created') return '+';
    if (action === 'deleted') return '-';
    return '~';
  }

  private decorateDiffLine(line: string, marker: '+' | '-' | '~'): string {
    const numbered = line.match(/^(\s*\d+)\s*│\s?(.*)$/);
    if (!numbered) return line;
    const lineNo = numbered[1].padStart(4, ' ');
    const text = numbered[2] || '';
    return `${lineNo} ${marker} │ ${text}`;
  }

  // ── Timing & Formatting ─────────────────────────────────────────────

  private formatDuration(ms: number): string {
    const totalSeconds = Math.max(0, Math.floor(ms / 1000));
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    if (minutes > 0) return minutes + 'm' + String(seconds).padStart(2, '0') + 's';
    return seconds + 's';
  }

  private formatTokenCount(tokens: number): string {
    if (tokens >= 1000) return (tokens / 1000).toFixed(1) + 'k';
    return String(tokens);
  }

  // ── Public API ──────────────────────────────────────────────────────

  renderPrompt(): void {
    if (this.plain) return;
    if (this.firstRender) {
      readline.cursorTo(this.output, 0);
      this.output.write('> ');
      this.firstRender = false;
      return;
    }
    this.promptBuffer = '';
    this.renderActive();
  }

  private reflow(): void {
    this.renderActive();
  }
}
