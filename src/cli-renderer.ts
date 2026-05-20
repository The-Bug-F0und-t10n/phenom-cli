import chalk from 'chalk';
import readline from 'readline';
import { eventBus, EventType } from './tui/event-bus.js';
import { StreamMarkdownRenderer } from './stream-markdown-renderer.js';

interface PendingFileDiff {
  path: string;
  lineCount: number;
  byteSize: number;
  action: 'created' | 'updated' | 'replaced' | 'patched' | 'deleted';
  content: string;
}

export class CliRenderer {
  // Tone helpers — kept separate so each visual register has its own meaning:
  //   thinkingTone   — italic light-gray for chain-of-thought CONTENT only.
  //   thinkingMarker — cyan bar prefixed to every thinking line.
  //   thinkingHeader — cyan bold "│ thinking" header that opens the block.
  //                    Uses the SAME glyph as the marker so the left edge of
  //                    the block forms a continuous vertical line.
  //   toolTone       — plain dim gray for tool start/result/error labels.
  private readonly thinkingTone = chalk.hex('#888888').italic;
  private readonly thinkingMarker = chalk.cyan('│ ');
  private readonly thinkingHeader = chalk.cyan('│ ') + chalk.cyan.bold('thinking');
  private readonly toolTone = chalk.hex('#666666').dim;

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
  private tokensPerSecond: number | null = null;
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
  private streamMode: 'none' | 'thinking' | 'content' = 'none';
  private reasoningStreamed: boolean = false;
  private committedAssistantByInference: string = '';
  /**
   * True once any MESSAGE_CHUNK has actually been rendered to the terminal
   * (TTY interactive path, non-suppressed). When true, AGENT_MESSAGE and
   * THINK_END MUST NOT re-display the same response via writeBlock — that
   * was the source of the triplicated output we fixed earlier.
   */
  private assistantStreamedDisplayed: boolean = false;
  private suppressingToolCallStream: boolean = false;
  private attached: boolean = false;
  private unsubscribers: Array<() => void> = [];
  private pendingFileDiffs: Map<string, PendingFileDiff> = new Map();
  private streamMarkdown = new StreamMarkdownRenderer();
  private currentToolName: string = '';
  /**
   * Tools whose TOOL_RESULT is suppressed in the inline log. write_file /
   * create_file / apply_patch / delete_file used to be here too, but that
   * made long mutations look like the agent had frozen — only "[assistant]"
   * was visible while the tool ran. Their diffs now render inline via the
   * FILE_DIFF handler in real time.
   */
  private readonly SILENT_TOOLS = new Set<string>([]);

  /** True when we have entered the terminal's alternate screen buffer. */
  private altScreenActive: boolean = false;
  /** Bound cleanup handler, registered on multiple process signals. */
  private readonly cleanupAltScreen = () => this.exitAltScreen();

  /**
   * Number of terminal lines the dynamic area occupies (content ABOVE the prompt).
   * Prompt is NOT counted — it is always the last line.
   */
  private activeLines: number = 0;
  /** Current user input text (preserved across active-area redraws). */
  private promptBuffer: string = '';
  /** Debounce timer for SIGWINCH / resize events. */
  private reflowTimer: ReturnType<typeof setTimeout> | null = null;
  /**
   * When true, a DECSTBM scroll region is active reserving the bottom 2 rows
   * (status + prompt) so they don't collide with append-only streaming output.
   */
  private streamScrollRegionActive: boolean = false;

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
        // Sync our promptBuffer with readline's internal line buffer AFTER
        // readline has processed the key. Without this, the next
        // drawFixedPrompt would clear the input row and overwrite the chars
        // the user has typed since the last paint. setImmediate defers until
        // after readline's keypress handler ran.
        setImmediate(() => {
          if (!this.rl) return;
          const line = ((this.rl as any).line ?? '') as string;
          if (line !== this.promptBuffer) {
            this.promptBuffer = line;
          }
        });
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

    // Enter alt-screen (TUI mode) + activate DECSTBM region for permanent
    // pinning of status + prompt at the bottom. The alt-screen keeps the
    // user's prior terminal contents safe and provides its own scrollback
    // for stream content scrolled past the top of the region.
    this.enterAltScreen();

    this.unsubscribers.push(eventBus.on(EventType.USER_MESSAGE, (event) => {
      const content = String(event.payload?.content || '').trim();
      if (content && !content.startsWith('/')) {
        this.writeBlock('[user] ' + content);
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.AGENT_MESSAGE, (event) => {
      const content = String(event.payload.content || '');
      const normalized = content.trim();

      // Stream already rendered the response in this inference — just record
      // it to history, do NOT writeBlock again (that was the triplication).
      if (this.assistantStreamedDisplayed) {
        if (normalized) {
          this.history.push('[assistant] ' + content);
          if (this.history.length > this.maxHistory) this.history.shift();
          this.committedAssistantByInference = normalized;
        }
        return;
      }

      if (normalized && normalized === this.committedAssistantByInference) {
        return;
      }

      // Plain mode / stream disabled — display via writeBlock once.
      if (normalized) {
        this.writeBlock('[assistant] ' + content);
        this.committedAssistantByInference = normalized;
      } else if (this.streamBuffer.trim()) {
        this.writeBlock('[assistant] ' + this.streamBuffer);
        this.committedAssistantByInference = this.streamBuffer.trim();
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.MESSAGE_CHUNK, (event) => {
      const chunk = this.normalizeChunk(event.payload.chunk || '');
      if (!chunk) return;
      this.streaming = true;
      this.streamBuffer += chunk;
      this.streamingContent = this.streamBuffer;
      this.ensureStreamingBlock();

      // Detect JSON tool-call protocol early — suppress raw JSON display.
      const trimmed = this.streamBuffer.trimStart();
      const isJsonToolCall =
        trimmed.startsWith('{"type":"tool"') ||
        trimmed.startsWith('{"type": "tool"') ||
        (trimmed.startsWith('{') && trimmed.includes('"toolName"'));
      if (isJsonToolCall) {
        this.suppressingToolCallStream = true;
        if (!this.statusVisible && this.thinkStarted) this.showStatusLine();
        return;
      }

      if (!this.plain && this.rl) {
        if (this.streamMode !== 'content') {
          this.openStreamLine('[assistant]\n');
          this.streamMode = 'content';
          // Header was written — stream owns the visual display now.
          this.assistantStreamedDisplayed = true;
        }
        const rendered = this.streamMarkdown.processChunk(chunk);
        if (rendered) this.output.write(rendered);
        return;
      }
      this.scheduleRender();
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_START, (event) => {
      const { name, args } = event.payload;
      this.currentToolName = name || '';
      const label = this.toolLabel(name);
      let detail = '';
      if (name === 'run_code' && args.command) {
        detail = ': ' + String(args.command).slice(0, 60);
      } else if (args.path) {
        detail = ' ' + args.path;
      } else if (args.pattern) {
        detail = ' ' + args.pattern;
      }
      this.writeBlock(this.toolTone('  ' + label + detail));
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_RESULT, (event) => {
      const { result } = event.payload;
      if (this.SILENT_TOOLS.has(this.currentToolName)) return;
      if (this.currentToolName === 'run_code' && result?.success) {
        const output = result.output
          ? String(result.output).split('\n').slice(0, 3).join(' | ').slice(0, 120)
          : 'OK';
        this.writeBlock(this.toolTone('    -> ' + output));
      } else if (!result?.success) {
        const summary = result?.error ? String(result.error).split('\n')[0].slice(0, 120) : 'failed';
        this.writeBlock('  ' + chalk.red('->') + ' ' + summary);
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_ERROR, (event) => {
      this.writeBlock('  ' + chalk.red('->') + ' ' + (event.payload.error || event.payload.message || 'failed'));
    }));

    this.unsubscribers.push(eventBus.on(EventType.FILE_DIFF, (event) => {
      const { path, lineCount, byteSize, action, content } = event.payload;
      if (!path) return;
      const normalizedAction = action === 'created' || action === 'deleted' || action === 'patched' || action === 'replaced'
        ? action
        : 'updated';
      const diff: PendingFileDiff = {
        path: String(path),
        lineCount: Number(lineCount || 0),
        byteSize: Number(byteSize || 0),
        action: normalizedAction,
        content: String(content || '')
      };
      // Render immediately so the user sees the mutation in real time.
      this.renderFileDiff(diff);
    }));

    this.unsubscribers.push(eventBus.on(EventType.INFERENCE_CANCEL, (event) => {
      if (this.streamLineOpen) {
        this.output.write('\n');
        this.streamLineOpen = false;
      }
      this.streamMode = 'none';
      this.reasoningStreamed = false;
      this.clearStreamingBlock();
      this.clearStatusLine();
      this.writeBlock(chalk.red('[cancelled] ' + (event?.payload?.reason || 'cancelled')));
      this.streaming = false;
      this.streamBuffer = '';
      this.assistantStreamedDisplayed = false;
    }));

    this.unsubscribers.push(eventBus.on(EventType.CLEAR_STREAMING, () => {
      if (this.streamLineOpen) {
        if (this.streamMode === 'content') {
          const pending = this.streamMarkdown.flushPending();
          if (pending) this.output.write(pending);
        }
        this.output.write('\n\n');
        this.streamLineOpen = false;
      }
      this.streamMode = 'none';
      this.streamMarkdown.reset();
      this.clearStreamingBlock();
      this.streamBuffer = '';
      this.suppressingToolCallStream = false;
      this.renderActive();
    }));

    this.unsubscribers.push(eventBus.on(EventType.THINK_END, () => {
      if (this.streamLineOpen) {
        if (this.streamMode === 'content') {
          const pending = this.streamMarkdown.flushPending();
          if (pending) this.output.write(pending);
          this.streamMarkdown.reset();
        }
        this.output.write('\n\n');
        this.streamLineOpen = false;
      }
      this.streamMode = 'none';

      // Plain-mode reasoning fallback: if reasoning was buffered but not
      // streamed inline, emit it now with the visual marker.
      if (!this.reasoningStreamed && this.reasoningBuffer.trim()) {
        const lines = this.reasoningBuffer.split('\n').filter(l => l.length > 0);
        this.writeBlock(this.thinkingHeader);
        for (const line of lines) {
          this.writeBlock(this.thinkingMarker + this.thinkingTone(line));
        }
      }
      this.reasoningBuffer = '';
      this.reasoningStreamed = false;
      if (this.renderTimer) { clearTimeout(this.renderTimer); this.renderTimer = null; }

      // Capture stats BEFORE clearing status so they survive into the [done] line.
      const elapsed = this.actionStartTime > 0
        ? this.formatDuration(Date.now() - this.actionStartTime)
        : '';
      const arrow = this.tokenDirection === 'down' ? '↓' : '↑';
      const tokenStr = this.tokenTotal > 0
        ? ' · ' + arrow + ' ' + this.formatTokenCount(this.tokenTotal) + ' tokens'
        : '';
      const tpsStr = this.tokensPerSecond && this.tokensPerSecond > 0
        ? ' · ' + this.formatTokensPerSecond(this.tokensPerSecond)
        : '';
      const statsStr = elapsed ? ' ' + elapsed + tokenStr + tpsStr : '';

      this.clearStatusLine();

      // Single source of truth for assistant display:
      //   - chunks already on screen → just persist to history.
      //   - otherwise → emit once via writeBlock.
      const streamed = this.streamBuffer.trim();
      if (streamed && streamed !== this.committedAssistantByInference) {
        if (this.assistantStreamedDisplayed) {
          this.history.push('[assistant] ' + this.streamBuffer);
          if (this.history.length > this.maxHistory) this.history.shift();
        } else {
          this.writeBlock('[assistant] ' + this.streamBuffer);
        }
        this.committedAssistantByInference = streamed;
      }

      this.streamBuffer = '';
      this.streamingBlockId = null;
      this.streamingContent = '';
      this.streaming = false;
      this.assistantStreamedDisplayed = false;
      this.suppressingToolCallStream = false;
      this.writeBlock(chalk.green('[done]') + chalk.dim(statsStr));
    }));

    this.unsubscribers.push(eventBus.on(EventType.THINK_START, (event) => {
      this.committedAssistantByInference = '';
      this.assistantStreamedDisplayed = false;
      this.reasoningBuffer = '';
      this.pendingFileDiffs.clear();
      this.streamMarkdown.reset();
      this.suppressingToolCallStream = false;
      this.startThink(event?.payload?.message || 'Thinking');
    }));

    this.unsubscribers.push(eventBus.on(EventType.REASONING_CHUNK, (event) => {
      const chunk = this.normalizeChunk(event.payload?.chunk || '');
      if (!chunk) return;
      this.reasoningBuffer += chunk;

      if (!this.plain && this.rl) {
        if (this.streamMode !== 'thinking') {
          this.openStreamLine(this.thinkingHeader + '\n');
          this.output.write(this.thinkingMarker);
          this.streamMode = 'thinking';
        }
        this.reasoningStreamed = true;
        // Newlines inside chunk need the marker prefix to keep the left edge
        // consistent. Marker is written outside the italic tone so it stays
        // cyan and is not styled with the content.
        const segments = chunk.split('\n');
        for (let i = 0; i < segments.length; i++) {
          if (i > 0) this.output.write('\n' + this.thinkingMarker);
          if (segments[i]) this.output.write(this.thinkingTone(segments[i]));
        }
        return;
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
        if (typeof event.payload.tokensPerSecond === 'number' && Number.isFinite(event.payload.tokensPerSecond)) {
          this.tokensPerSecond = event.payload.tokensPerSecond;
        } else if (event.payload.tokensPerSecond === null) {
          this.tokensPerSecond = null;
        }
        if (!this.statusVisible && this.thinkStarted) {
          this.showStatusLine();
        }
        this.refreshStatus();
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
   * Idle-state repaint of the pinned bottom bar. With alt-screen + DECSTBM
   * permanently active, the bottom two rows are reserved for status + prompt.
   * The previous "active area" (transient reasoning preview, streaming
   * preview block above the prompt) was removed: previews now flow directly
   * through the scroll region via the REASONING_CHUNK / MESSAGE_CHUNK paths.
   */
  private renderActive(): void {
    if (this.plain) return;
    if (this.streamLineOpen) return;
    this.activeLines = 0;
    this.drawFixedPrompt({ preserveCursor: false });
  }

  private scheduleRender(): void {
    if (this.streamLineOpen) return;
    if (this.renderTimer) return;
    this.renderTimer = setTimeout(() => {
      this.renderTimer = null;
      this.renderActive();
    }, 40);
  }

  private writeBlock(text: string, record: boolean = true): void {
    if (record) {
      this.history.push(text);
      if (this.history.length > this.maxHistory) this.history.shift();
    }
    if (this.streamLineOpen) {
      this.output.write('\n');
      this.streamLineOpen = false;
    }
    const isAssistant = text.startsWith('[assistant]');
    if (this.plain) {
      if (isAssistant) console.log('');
      console.log(text);
      if (isAssistant) console.log('');
      return;
    }

    // Move cursor INTO the scroll region before writing — otherwise it might
    // still be parked at the prompt input row from the previous
    // drawFixedPrompt, and we'd write block text on top of the pinned prompt.
    this.positionAtContentRegion();
    this.clearActive();
    readline.cursorTo(this.output, 0);
    this.output.write('\x1b[K');
    if (isAssistant) this.output.write('\n');
    this.output.write(text + '\n');
    if (isAssistant) this.output.write('\n');
    this.firstRender = false;
    this.activeLines = 0;
    this.renderActive();
  }

  // ── Streaming ───────────────────────────────────────────────────────

  /**
   * Open a new append-only stream line (`[assistant] ` or `│ thinking `).
   * Positions cursor inside the scroll region before writing to avoid landing
   * on top of the pinned prompt.
   */
  private openStreamLine(label: string): void {
    if (this.renderTimer) {
      clearTimeout(this.renderTimer);
      this.renderTimer = null;
    }
    if (this.streamLineOpen) {
      // Switching mode (e.g. thinking → content): close the previous block
      // with a blank line separator so blocks read as `[label]\n<out>\n`.
      this.output.write('\n\n');
    } else {
      this.positionAtContentRegion();
      this.clearActive();
      readline.cursorTo(this.output, 0);
      this.output.write('\x1b[K');
      this.output.write('\n');
    }
    this.output.write(label);
    this.streamLineOpen = true;
    this.activeLines = 0;
    // DECSTBM region is already active (set permanently at enterAltScreen).
  }

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

      if (this.suppressingToolCallStream) {
        return;
      }

      if (streamedText.trim()) {
        if (this.plain || !this.rl) {
          this.writeBlock('[assistant] ' + streamedText);
        } else {
          this.history.push('[assistant] ' + streamedText);
          if (this.history.length > this.maxHistory) this.history.shift();
        }
        this.committedAssistantByInference = streamedText.trim();
      }

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
    this.currentAction = message || 'Thinking';
    this.actionStartTime = Date.now();
    this.inferenceStart = Date.now();
    this.tokenTotal = 0;
    this.startTokens = 0;
    this.tokenDirection = 'down';
    this.tokensPerSecond = null;
    this.streamMode = 'none';
    this.reasoningStreamed = false;
    this.opLabel = this.deriveOpLabel(this.currentAction, '');
    this.thinkStarted = true;
    this.statusVisible = false;
    this.scheduleRender();
  }

  private showStatusLine(): void {
    if (this.statusInterval) clearInterval(this.statusInterval);
    this.statusVisible = true;
    this.statusInterval = setInterval(() => this.refreshStatus(), 1000);
    this.refreshStatus();
  }

  /**
   * Redraw the status line. The bottom bar is pinned permanently (alt-screen
   * + DECSTBM), so either branch paints it via drawFixedPrompt:
   *   - During stream: preserveCursor=true so the content cursor stays put.
   *   - Idle: preserveCursor=false so the cursor lands on the prompt input
   *     column for readline to echo the next keystroke there.
   */
  private refreshStatus(): void {
    if (this.streamLineOpen) {
      this.drawFixedPrompt({ preserveCursor: true });
      return;
    }
    this.drawFixedPrompt({ preserveCursor: false });
  }

  private clearStatusLine(): void {
    this.statusVisible = false;
    this.lastStatusLine = '';
    this.thinkStarted = false;
    if (this.statusInterval) {
      clearInterval(this.statusInterval);
      this.statusInterval = null;
    }
    // Wipe status row text left by drawFixedPrompt so it doesn't linger.
    if (!this.plain && this.rl) {
      const rows = this.output.rows || process.stdout.rows;
      if (rows && rows >= 2) {
        this.output.write('\x1b7' + `\x1b[${rows - 1};1H\x1b[K` + '\x1b8');
      }
    }
  }

  private getStatusLine(): string | null {
    if (!this.statusVisible || !this.thinkStarted) return null;
    const elapsed = this.formatDuration(Date.now() - this.actionStartTime);
    const arrow = this.tokenDirection === 'down' ? '↓' : '↑';
    const deltaTokens = Math.max(0, this.tokenTotal - this.startTokens);
    const tokenStr = ' ' + arrow + ' ' + this.formatTokenCount(deltaTokens) + ' tokens';
    const tpsStr = this.tokensPerSecond && this.tokensPerSecond > 0
      ? ' · ' + this.formatTokensPerSecond(this.tokensPerSecond)
      : '';
    const label = this.opLabel || 'Thinking';
    const spinner = this.getSpinnerFrame();
    return label + ' ' + spinner + ' (' + elapsed + tokenStr + tpsStr + ' · esc to interrupt)';
  }

  private getSpinnerFrame(): string {
    const now = Date.now();
    if (now - this.statusSpinnerLast > 300) {
      this.statusSpinnerIndex = (this.statusSpinnerIndex + 1) % this.statusSpinnerFrames.length;
      this.statusSpinnerLast = now;
    }
    return this.statusSpinnerFrames[this.statusSpinnerIndex] || '...';
  }

  private toolLabel(name: string): string {
    switch (name) {
      case 'write_file':
      case 'create_file': return 'Writing';
      case 'read_file': return 'Reading';
      case 'apply_patch':
      case 'patch_file': return 'Patching';
      case 'delete_file': return 'Deleting';
      case 'grep_file': return 'Searching';
      case 'list_dir': return 'Exploring';
      case 'run_code': return 'Running';
      case 'glob': return 'Globbing';
      case 'find_function': return 'Searching';
      case 'path_exists': return 'Checking';
      case 'set_plan': return 'Planning';
      case 'complete_step': return 'Step done';
      case 'validate_syntax': return 'Validating';
      case 'run_tests': return 'Testing';
      case 'list_session_files': return 'Session files';
      case 'date': return 'Getting date';
      default: return name.replace(/_/g, ' ');
    }
  }

  private deriveOpLabel(message: string, fallback: string): string {
    const text = String(message || '').toLowerCase();
    if (text.includes('thinking') || text.includes('work')) return 'Thinking';
    if (text.includes('write') || text.includes('create') || text.includes('criar')) return 'Writing';
    if (text.includes('patch') || text.includes('alter')) return 'Patching';
    if (text.includes('edit')) return 'Editing';
    if (text.includes('search') || text.includes('busca') || text.includes('grep')) return 'Searching';
    if (text.includes('read') || text.includes('ler')) return 'Reading';
    if (text.includes('run') || text.includes('exec')) return 'Running';
    if (text.includes('list') || text.includes('dir') || text.includes('explor')) return 'Exploring';
    return fallback || 'Thinking';
  }

  /**
   * Render a single file diff inline (called from the FILE_DIFF handler the
   * moment a mutation completes). Previously diffs were buffered in
   * pendingFileDiffs and rendered at THINK_END, which made multi-step tool
   * runs look like the agent had frozen between TOOL_START and end-of-turn.
   */
  private renderFileDiff(diff: PendingFileDiff): void {
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

  private flushPendingFileDiffs(): void {
    if (this.pendingFileDiffs.size === 0) return;
    for (const diff of this.pendingFileDiffs.values()) {
      this.renderFileDiff(diff);
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

  // ── DECSTBM scroll region + bottom-bar paint ────────────────────────

  private enterStreamScrollRegion(): void {
    if (this.plain || this.streamScrollRegionActive) return;
    const rows = this.output.rows || process.stdout.rows;
    if (!rows || rows < 4) return;
    // DECSTBM \x1b[T;Br moves cursor to (1,1); wrap in save/restore so we
    // resume from wherever we were before setting the region.
    this.output.write('\x1b7' + `\x1b[1;${rows - 2}r` + '\x1b8');
    this.streamScrollRegionActive = true;
  }

  private exitStreamScrollRegion(): void {
    if (this.plain || !this.streamScrollRegionActive) return;
    const rows = this.output.rows || process.stdout.rows;
    this.output.write(
      '\x1b7' +
      '\x1b[r' +
      (rows && rows >= 2
        ? `\x1b[${rows - 1};1H\x1b[K\x1b[${rows};1H\x1b[K`
        : '') +
      '\x1b8'
    );
    this.streamScrollRegionActive = false;
  }

  /**
   * Paint the pinned bottom bar — status on row (rows - 1), prompt on row
   * (rows). The DECSTBM region keeps these two rows outside any content
   * scrolling, so this paint is stable.
   */
  private drawFixedPrompt(opts?: { preserveCursor?: boolean }): void {
    if (this.plain) return;
    const rows = this.output.rows || process.stdout.rows;
    if (!rows || rows < 2) return;
    const cols = this.output.columns || process.stdout.columns || 80;
    const preserveCursor = opts?.preserveCursor === true;

    const statusLine = (this.statusVisible && this.thinkStarted) ? this.getStatusLine() : null;
    const statusPainted = statusLine
      ? chalk.gray(this.clampToWidth(statusLine, cols))
      : '';

    let out = '';
    if (preserveCursor) out += '\x1b7';
    out += `\x1b[${rows - 1};1H\x1b[K`;
    if (statusPainted) out += statusPainted;
    out += `\x1b[${rows};1H\x1b[K` + chalk.dim('> ') + this.promptBuffer;
    if (preserveCursor) {
      out += '\x1b8';
    } else {
      // Park cursor at the prompt input column so readline echoes typed chars
      // exactly where the user sees the cursor.
      const inputCol = 3 + this.stripAnsi(this.promptBuffer).length;
      out += `\x1b[${rows};${inputCol}H`;
    }
    this.output.write(out);
  }

  /**
   * Move the cursor to the bottom of the scroll region (the natural "next
   * content line" position). Called before any content write so we never
   * write while the cursor is parked over the pinned status or prompt.
   */
  private positionAtContentRegion(): void {
    if (this.plain || !this.altScreenActive) return;
    const rows = this.output.rows || process.stdout.rows;
    if (!rows || rows < 4) return;
    this.output.write(`\x1b[${rows - 2};1H`);
  }

  // ── Alt-screen lifecycle ────────────────────────────────────────────

  private enterAltScreen(): void {
    if (this.plain || this.altScreenActive) return;
    this.output.write('\x1b[?1049h\x1b[H');
    this.altScreenActive = true;
    // Activate DECSTBM region 1..rows-2 once, here. The bottom two rows are
    // now permanently reserved for the pinned status + prompt.
    this.enterStreamScrollRegion();

    process.on('exit', this.cleanupAltScreen);
    process.on('SIGINT', this.cleanupAltScreen);
    process.on('SIGTERM', this.cleanupAltScreen);
    process.on('SIGHUP', this.cleanupAltScreen);
    process.on('uncaughtException', (err) => {
      this.exitAltScreen();
      console.error(err);
      process.exit(1);
    });
  }

  private exitAltScreen(): void {
    if (!this.altScreenActive) return;
    this.exitStreamScrollRegion();
    this.output.write('\x1b[?1049l');
    this.altScreenActive = false;
  }

  /**
   * Public clean-shutdown entry point. Callers should invoke this BEFORE
   * printing any final farewell text so that text lands on the user's main
   * terminal rather than getting wiped together with the alt-screen.
   */
  detach(): void {
    this.exitAltScreen();
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

  private formatTokensPerSecond(tps: number): string {
    if (tps >= 100) return tps.toFixed(0) + ' tok/s';
    if (tps >= 10) return tps.toFixed(1) + ' tok/s';
    return tps.toFixed(2) + ' tok/s';
  }

  // ── Public API ──────────────────────────────────────────────────────

  renderPrompt(): void {
    if (this.plain) return;
    this.firstRender = false;
    this.promptBuffer = '';
    this.drawFixedPrompt({ preserveCursor: false });
  }

  /**
   * Handle a terminal resize event. Called from output.on('resize') and from
   * SIGWINCH. Debounced (~80 ms) because window managers fire SIGWINCH many
   * times per second during a drag.
   */
  private reflow(): void {
    if (this.reflowTimer) clearTimeout(this.reflowTimer);
    this.reflowTimer = setTimeout(() => {
      this.reflowTimer = null;
      if (this.altScreenActive) {
        this.streamScrollRegionActive = false;
        this.enterStreamScrollRegion();
      }
      if (this.streamLineOpen) {
        this.drawFixedPrompt({ preserveCursor: true });
      } else {
        this.renderActive();
      }
    }, 80);
  }
}
