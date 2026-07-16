import chalk from 'chalk';
import readline from 'readline';
import { execSync } from 'node:child_process';
import os from 'node:os';
import { eventBus, EventType } from './tui/event-bus.js';
import { StreamMarkdownRenderer } from './stream-markdown-renderer.js';
import { MiniVisualizer } from './visualizer-mini.js';

// chalk auto-detects the colour level from stdout's TTY state at import
// time. In some terminal setups (notably anything that wraps stdin in a
// pipe before chalk runs its probe — e.g. some IDE-integrated terminals
// or when raw-mode bracketed-paste re-config races the probe), it lands
// on level 0 and silently emits plain text. The diff renderer relies on
// ANSI green/red to communicate +/-/~ lines, so if level 0 sneaks in,
// every diff comes out monochrome. Force a 16-colour floor whenever
// stdout is a TTY and not explicitly opted out of colour.
if (process.stdout.isTTY && !process.env.NO_COLOR && chalk.level === 0) {
  chalk.level = 1;
}

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
  // toolTone is the tool-action announcement line (TOOL_START / TOOL_RESULT).
  // Was dim hex#666 which disappeared on dark terminals — bumped to bright
  // cyan + bold so write/read/run/patch announcements are clearly visible
  // BEFORE the diff or output materializes.
  private readonly toolTone = chalk.cyan.bold;
  /** Glyph prefix on tool announcements — small triangle for "starting". */
  private readonly toolGlyph = chalk.cyan.bold('▸ ');

  private streaming: boolean = false;
  private streamBuffer: string = '';
  private streamingBlockId: string | null = null;
  private streamingContent: string = '';
  private rl: readline.Interface | null = null;
  private history: string[] = [];
  /**
   * Logical, width-agnostic history used for resize reflow. User messages are
   * stored as `[user] ...` and re-bubbled at current terminal width.
   */
  private layoutHistory: string[] = [];
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
  private tokenInput: number = 0;
  private tokenOutput: number = 0;
  private tokenDirection: 'up' | 'down' = 'down';
  private tokensPerSecond: number | null = null;
  private opLabel: string = '';
  /**
   * Snapshot of opLabel before the current tool took it over. Restored on
   * TOOL_RESULT so the status row goes back to "Thinking" (or whatever
   * progress label was active) instead of getting stuck on "Reading".
   */
  private prevOpLabel: string = '';
  /**
   * Timer that schedules the post-tool restoration. Held until the tool's
   * mode cascade has had time to complete (~1.85s), so very fast tools
   * still show a visible transition on the visualizer.
   */
  private toolRestoreTimer: ReturnType<typeof setTimeout> | null = null;
  private thinkStarted: boolean = false;
  private statusInterval: NodeJS.Timeout | null = null;
  private statusSpinnerIndex: number = 0;
  private statusSpinnerLast: number = 0;
  private readonly statusSpinnerFrames = ['.  ', '.. ', '...'];
  private lastStatusLine: string = '';
  private reasoningBuffer: string = '';
  /** True once current inference thinking block was persisted to history. */
  private reasoningPersistedThisInference: boolean = false;
  /**
   * Visible content columns already written on the CURRENT thinking line
   * (excludes gutter + "│ " marker). Reasoning streams in chunks; the first
   * segment of a new chunk continues this line, so wrapping must subtract
   * this offset — otherwise concatenated fragments overflow maxContentWidth
   * and the terminal hard-wraps them with no "│ " marker, leaking text to
   * column 0 outside the thinking block (visible on non-fullscreen widths).
   */
  private thinkingContentCol: number = 0;
  private renderTimer: ReturnType<typeof setTimeout> | null = null;
  private streamLineOpen: boolean = false;
  private streamMode: 'none' | 'thinking' | 'content' = 'none';
  private reasoningStreamed: boolean = false;
  private committedAssistantByInference: string = '';
  /** True when next streamed byte starts a new visual line (needs gutter). */
  private streamNeedsGutterPrefix: boolean = true;
  /**
   * Trailing '\n' chars held back from emission. Every '\n' written at the
   * bottom of the scroll region triggers a scroll, pushing the visible
   * content up and leaving a blank row at the bottom. If a stream ends with
   * "Ola\n\n\n\n\n...", emitting those trailing newlines stacks 10+ blank
   * rows below the response. We buffer them here and only flush if MORE
   * non-newline content arrives (proving they were inter-line, not trailing).
   * THINK_END discards whatever is left.
   */
  private pendingTrailingNewlines: string = '';
  /**
   * True once any MESSAGE_CHUNK has actually been rendered to the terminal
   * (TTY interactive path, non-suppressed). When true, AGENT_MESSAGE and
   * THINK_END MUST NOT re-display the same response via writeBlock — that
   * was the source of the triplicated output we fixed earlier.
   */
  private assistantStreamedDisplayed: boolean = false;
  private suppressingToolCallStream: boolean = false;
  /**
   * Index into streamBuffer marking how much has been forwarded to the
   * markdown stream renderer. The chunk handler holds back trailing bytes
   * that could still complete into a suppress-marker prefix (envelope JSON
   * or <tool_call> tag), so partial wrappers never leak to the terminal.
   */
  private streamPushedUpTo: number = 0;
  /**
   * When set, the bottom status bar shows this "[done] elapsed · tokens · tps"
   * line in place of the active-inference prose. Persists until the next
   * THINK_START clears it. Replaces the prior writeBlock chat-log line so
   * the [done] marker stays pinned alongside the (then-frozen) visualizer
   * instead of scrolling away with the conversation.
   */
  private doneStatus: string = '';
  /**
   * Timer that stops the wave animation a short window after THINK_END.
   * The window covers CASCADE_SEC + EASE_SEC so the cascade INTO idle
   * paints smoothly to baseline before we freeze the visualizer.
   */
  private idleFreezeTimer: ReturnType<typeof setTimeout> | null = null;
  private attached: boolean = false;
  private unsubscribers: Array<() => void> = [];
  private pendingFileDiffs: Map<string, PendingFileDiff> = new Map();
  private streamMarkdown = new StreamMarkdownRenderer();
  private currentToolName: string = '';
  private readonly userLabel: string = this.resolveUserLabel();
  /**
   * Last rendered content kind. Used for spacing transitions such as
   * assistant -> first tool call (needs one blank row), while keeping tool
   * chains tight (no blank rows between tools).
   */
  private lastRenderedKind: 'none' | 'user' | 'assistant' | 'thinking' | 'tool' | 'other' = 'none';
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
   * Mini wave visualizer rendered as a prefix in the status line. State
   * (idle/thinking/working/...) is updated on THINK_START / PROGRESS_UPDATE
   * / THINK_END so the wave matches what the agent is doing.
   * Default 10 columns — minimum size that still shows a meaningful wave.
   */
  private visualizer = new MiniVisualizer(10);

  /**
   * Number of terminal lines the dynamic area occupies (content ABOVE the prompt).
   * Prompt is NOT counted — it is always the last line.
   */
  private activeLines: number = 0;
  /** Current user input text (multi-line, '\n' separates rows). */
  private promptBuffer: string = '';
  /** Cursor offset (UTF-16 code units) into promptBuffer. */
  private cursorOffset: number = 0;
  /**
   * Bracketed-paste state: when the terminal sends ESC [ 200 ~ we accumulate
   * bytes into pasteBuffer until ESC [ 201 ~. The full paste is then either
   * inlined (single-line, short) or registered as a `[ Paste N lines ]`
   * placeholder whose real content is held in pasteMap until submit.
   */
  private inPaste: boolean = false;
  private pasteBuffer: string = '';
  // Escape sequences (Esc alone, CSI like ↑/↓/Home/End/Delete) can be split
  // across stdin reads under load — common over SSH or under high event rate.
  // We accumulate any trailing incomplete `\x1b...` prefix and glue it to the
  // next chunk so the parser always sees a complete sequence. The timer flushes
  // a lone Esc that never got a tail — meaning the user really did press Esc.
  // 100 ms is conservative: long enough to absorb network jitter, short enough
  // that Esc-to-cancel still feels instant.
  private pendingEsc: string = '';
  private pendingEscTimer: NodeJS.Timeout | null = null;
  private static readonly ESC_FLUSH_MS = 100;
  /** Maps a placeholder token rendered in the input to its expanded text. */
  private pasteMap: Map<string, string> = new Map();
  /** Submitted lines, most-recent first. */
  private inputHistory: string[] = [];
  /** -1 = current draft; >= 0 = browsing inputHistory[historyIndex]. */
  private historyIndex: number = -1;
  /** Draft saved when user starts browsing history (restored on cancel). */
  private historyDraft: string = '';
  /** How many rows the prompt area currently occupies (≥ 1). */
  private promptRowsRendered: number = 1;
  /** Callbacks installed by bindInput. */
  private onLineSubmit: ((line: string) => void) | null = null;
  private onInputClose: (() => void) | null = null;
  /**
   * Optional hook invoked from the uncaughtException handler before exit.
   * Lets the app flush brain/history when a crash bypasses the normal
   * onClose path. Set via setFatalErrorHook(); awaited with a 1.5s cap.
   */
  private onFatalError: (() => Promise<void> | void) | null = null;
  /** Raw-data listener installed on stdin (for cleanup on detach). */
  private stdinDataListener: ((chunk: Buffer | string) => void) | null = null;
  /** Debounce timer for SIGWINCH / resize events. */
  private reflowTimer: ReturnType<typeof setTimeout> | null = null;
  /** Resize happened while stream was open; flush reflow after stream closes. */
  private pendingReflowAfterStream: boolean = false;
  /**
   * Full canonical repaint after non-stream block writes. Prevents stale
   * on-screen artefacts ("ghost" remnants) from surviving incremental paints.
   * Can be disabled for perf experiments via PHENOM_TUI_CANONICAL_REPAINT=0.
   */
  private readonly canonicalRepaint: boolean = process.env.PHENOM_TUI_CANONICAL_REPAINT !== '0';
  /**
   * When true, a DECSTBM scroll region is active reserving the bottom 2 rows
   * (status + prompt) so they don't collide with append-only streaming output.
   */
  private streamScrollRegionActive: boolean = false;

  /** True once bindInput has wired up our raw-stdin handler. */
  private interactive: boolean = false;

  private get output(): NodeJS.WriteStream {
    // Tests inject a fake stream via renderer.rl = { output: fake }; production
    // code never sets this.rl (raw-stdin path lives in bindInput), so the
    // fallback to process.stdout is the live path.
    return ((this.rl as any)?.output ?? process.stdout) as NodeJS.WriteStream;
  }

  /**
   * Wire up the renderer's custom input handler. Replaces the previous
   * readline-based path so the renderer owns ALL prompt rendering, fixing:
   *   - `> ` getting eaten by backspace (readline's echo fought our paint)
   *   - paste of multi-line text auto-submitting (readline emitted one
   *     'line' per row)
   *   - cursor stuck on a single row (no multi-line nav)
   * The Interface is no longer created by the consumer; we read stdin in
   * raw mode directly and parse keys + bracketed paste ourselves.
   */
  bindInput(opts: {
    onLine: (line: string) => void;
    onClose?: () => void;
    onFatalError?: () => Promise<void> | void;
    history?: string[];
  }): void {
    this.onLineSubmit = opts.onLine;
    this.onInputClose = opts.onClose || null;
    this.onFatalError = opts.onFatalError || null;
    if (opts.history && opts.history.length) {
      this.inputHistory = opts.history.slice(0, 200);
    }
    if (this.output.on) {
      this.output.on('resize', () => this.reflow());
    }
    process.on('SIGWINCH', () => this.reflow());

    if (!process.stdin.isTTY) return;
    this.interactive = true;
    // Sentinel so existing `!this.plain && this.rl` truthy checks in the
    // streaming/render paths recognise interactive TTY mode. Tests use the
    // same shape ({ output }) — the field is only consulted via .output.
    this.rl = { output: process.stdout } as unknown as readline.Interface;
    try { process.stdin.setRawMode(true); } catch {}
    process.stdin.setEncoding('utf8');
    // Keep the wave animation always running once we're in interactive
    // mode. Without a continuous paint loop, every keystroke triggers a
    // single isolated refreshStatus that advances the wave by exactly
    // one frame, which the user perceives as the visualizer "jumping" on
    // each character typed. Always-on at 30 FPS dissolves that jump into
    // the regular animation.
    this.startWaveAnimation();
    // Enable terminal bracketed-paste mode (DEC private mode 2004). Pasted
    // text is wrapped in ESC[200~ … ESC[201~ so we can distinguish it from
    // typed input and never split it on '\r' / '\n' boundaries.
    this.output.write('\x1b[?2004h');

    this.stdinDataListener = (chunk: Buffer | string) => {
      this.consumeInputData(typeof chunk === 'string' ? chunk : chunk.toString('utf8'));
    };
    process.stdin.on('data', this.stdinDataListener);
  }

  /** Current input history, newest first. Caller persists it on shutdown. */
  getInputHistory(): string[] {
    return this.inputHistory.slice();
  }

  // ── Custom raw-stdin input parser ──────────────────────────────────

  private consumeInputData(data: string): void {
    // If a previous chunk ended with an incomplete escape sequence (`\x1b`,
    // `\x1b[`, `\x1b[3`, …) glue it back to the front of this chunk so a split
    // CSI like ↑ = ESC [ A parses as one sequence regardless of where the
    // boundary fell.
    if (this.pendingEsc) {
      data = this.pendingEsc + data;
      this.pendingEsc = '';
      if (this.pendingEscTimer) { clearTimeout(this.pendingEscTimer); this.pendingEscTimer = null; }
    }
    let i = 0;
    let changed = false;
    while (i < data.length) {
      // Bracketed paste — start
      if (data.startsWith('\x1b[200~', i)) {
        this.inPaste = true;
        this.pasteBuffer = '';
        i += 6;
        continue;
      }
      // Bracketed paste — end
      if (data.startsWith('\x1b[201~', i)) {
        if (this.inPaste) {
          this.inPaste = false;
          this.commitPaste(this.pasteBuffer);
          this.pasteBuffer = '';
          changed = true;
        }
        i += 6;
        continue;
      }
      if (this.inPaste) {
        // Inside paste: take bytes verbatim. Normalize CR → LF so pasted
        // code blocks consistently use '\n' as the line separator.
        const ch = data[i];
        this.pasteBuffer += ch === '\r' ? '\n' : ch;
        i += 1;
        continue;
      }

      const c = data[i];

      // Ctrl+C: cancel active inference if one is running; otherwise exit.
      if (c === '\x03') {
        if (this.thinkStarted) {
          eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'cancelled by user' });
        } else if (this.onInputClose) {
          this.onInputClose();
        }
        i += 1;
        continue;
      }
      // Ctrl+D: exit when the buffer is empty.
      if (c === '\x04') {
        if (this.promptBuffer.length === 0 && this.onInputClose) {
          this.onInputClose();
        }
        i += 1;
        continue;
      }
      // Enter: submit. Use Alt+Enter (ESC + \r) or Shift+Enter for newline.
      if (c === '\r' || c === '\n') {
        this.submitInput();
        changed = true;
        i += 1;
        continue;
      }
      // Backspace (DEL 0x7F or BS 0x08): bounded delete; never crosses the
      // start of the buffer, so the `> ` prefix can no longer be eaten.
      if (c === '\x7f' || c === '\x08') {
        if (this.cursorOffset > 0) {
          this.promptBuffer =
            this.promptBuffer.slice(0, this.cursorOffset - 1) +
            this.promptBuffer.slice(this.cursorOffset);
          this.cursorOffset -= 1;
          this.historyIndex = -1;
          changed = true;
        }
        i += 1;
        continue;
      }
      // ESC followed by '[' — CSI sequence (arrows, Home/End, Delete, …).
      // If the final byte ([A-Za-z~]) hasn't arrived yet, buffer the partial
      // sequence and stop processing this chunk; the next chunk will deliver
      // the tail and the prepend at function entry stitches them together.
      if (c === '\x1b' && data[i + 1] === '[') {
        let j = i + 2;
        while (j < data.length && !/[A-Za-z~]/.test(data[j])) j += 1;
        if (j >= data.length) {
          this.bufferIncompleteEsc(data.substring(i));
          break;
        }
        const seq = data.substring(i, j + 1);
        if (this.handleCsi(seq)) changed = true;
        i = j + 1;
        continue;
      }
      // ESC followed by 'O' — SS3 sequence. Terminals in DECCKM (Application
      // Cursor Keys) mode emit arrows as `ESC O A` / `ESC O B` / `ESC O C` /
      // `ESC O D` instead of `ESC [ A` …. xterm, gnome-terminal, kitty,
      // alacritty, st all use this mode when the application requests it
      // (Node's readline does so implicitly on many setups). Without this
      // branch the lone-ESC handler fired a spurious cancel and `OA`/`OB`
      // leaked into the prompt buffer.
      if (c === '\x1b' && data[i + 1] === 'O') {
        if (i + 2 >= data.length) {
          // Tail (final letter) hasn't arrived yet — buffer and wait.
          this.bufferIncompleteEsc(data.substring(i));
          break;
        }
        // Translate to the equivalent CSI form and dispatch through handleCsi
        // so we don't duplicate the navigation/cursor switch logic.
        const final = data[i + 2];
        if (this.handleCsi('\x1b[' + final)) changed = true;
        i += 3;
        continue;
      }
      // Alt+Enter (ESC + \r or ESC + \n) — insert a newline instead of submit.
      if (c === '\x1b' && (data[i + 1] === '\r' || data[i + 1] === '\n')) {
        this.insertText('\n');
        changed = true;
        i += 2;
        continue;
      }
      // Lone ESC — could be a real Esc press OR the start of an escape
      // sequence whose tail bytes have not arrived yet. If it's the last byte
      // of this chunk, defer the decision: buffer it and let the next chunk
      // decide (split-CSI / split Alt+key), or let the timer flush it as Esc.
      if (c === '\x1b') {
        if (i === data.length - 1) {
          this.bufferIncompleteEsc('\x1b');
          break;
        }
        // ESC followed by something we don't recognize — fire cancel immediately
        // (matches prior readline behaviour for unhandled ESC + X).
        eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'cancelled by user' });
        i += 1;
        continue;
      }
      // Printable byte: insert at cursor. Anything below space and not
      // already handled above is dropped.
      if (c >= ' ') {
        this.insertText(c);
        changed = true;
        i += 1;
        continue;
      }
      i += 1;
    }

    if (changed) this.refreshStatus();
  }

  /**
   * Hold an incomplete escape prefix (e.g. `\x1b`, `\x1b[`, `\x1b[3`) until the
   * rest of the sequence arrives in the next chunk. The flush timer only fires
   * for a bare `\x1b` — that genuinely was an Esc keypress; if the buffer has
   * anything more, it's a corrupted/abandoned sequence and we discard it
   * silently rather than firing a spurious INFERENCE_CANCEL.
   */
  private bufferIncompleteEsc(partial: string): void {
    this.pendingEsc = partial;
    if (this.pendingEscTimer) clearTimeout(this.pendingEscTimer);
    this.pendingEscTimer = setTimeout(() => {
      this.pendingEscTimer = null;
      const buffered = this.pendingEsc;
      this.pendingEsc = '';
      if (buffered === '\x1b') {
        eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'cancelled by user' });
      }
      // Else: incomplete CSI / unknown prefix — drop quietly; don't cancel.
    }, CliRenderer.ESC_FLUSH_MS);
  }

  /** Returns true if the sequence moved the cursor or changed history state. */
  private handleCsi(seq: string): boolean {
    const lines = this.promptBuffer.split('\n');
    const { row, col } = this.cursorRowCol();
    const canNavigateHistory = (): boolean => {
      // History must start only on an empty prompt. Once browsing has
      // started (historyIndex >= 0), allow up/down to keep navigating even
      // though the buffer is now populated by historic content.
      return this.historyIndex !== -1 || this.promptBuffer.length === 0;
    };
    const tryNavigateHistory = (direction: 1 | -1): boolean => {
      const prevIndex = this.historyIndex;
      const prevBuffer = this.promptBuffer;
      const prevCursor = this.cursorOffset;
      this.navigateHistory(direction);
      return (
        this.historyIndex !== prevIndex ||
        this.promptBuffer !== prevBuffer ||
        this.cursorOffset !== prevCursor
      );
    };
    const offsetForRow = (r: number): number => {
      let off = 0;
      for (let k = 0; k < r; k++) off += lines[k].length + 1;
      return off;
    };
    switch (seq) {
      case '\x1b[A': // Up
        if (row > 0) {
          const target = Math.min(col, lines[row - 1].length);
          this.cursorOffset = offsetForRow(row - 1) + target;
          return true;
        }
        if (canNavigateHistory()) {
          return tryNavigateHistory(+1);
        } else {
          return false;
        }
      case '\x1b[B': // Down
        if (row < lines.length - 1) {
          const target = Math.min(col, lines[row + 1].length);
          this.cursorOffset = offsetForRow(row + 1) + target;
          return true;
        }
        if (canNavigateHistory()) {
          return tryNavigateHistory(-1);
        } else {
          return false;
        }
      case '\x1b[C': // Right
        this.cursorOffset = Math.min(this.promptBuffer.length, this.cursorOffset + 1);
        return true;
      case '\x1b[D': // Left
        this.cursorOffset = Math.max(0, this.cursorOffset - 1);
        return true;
      case '\x1b[H': // Home (start of line)
        this.cursorOffset = offsetForRow(row);
        return true;
      case '\x1b[F': // End (end of line)
        this.cursorOffset = offsetForRow(row) + lines[row].length;
        return true;
      case '\x1b[3~': // Delete (forward delete)
        if (this.cursorOffset < this.promptBuffer.length) {
          this.promptBuffer =
            this.promptBuffer.slice(0, this.cursorOffset) +
            this.promptBuffer.slice(this.cursorOffset + 1);
          this.historyIndex = -1;
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  private cursorRowCol(): { row: number; col: number } {
    let row = 0;
    let col = 0;
    for (let i = 0; i < this.cursorOffset; i++) {
      if (this.promptBuffer[i] === '\n') { row += 1; col = 0; }
      else col += 1;
    }
    return { row, col };
  }

  private insertText(text: string): void {
    this.promptBuffer =
      this.promptBuffer.slice(0, this.cursorOffset) +
      text +
      this.promptBuffer.slice(this.cursorOffset);
    this.cursorOffset += text.length;
    this.historyIndex = -1;
  }

  private navigateHistory(direction: 1 | -1): void {
    if (this.inputHistory.length === 0) return;
    if (this.historyIndex === -1 && direction === 1) {
      // First step into history: stash the current draft so the user can
      // come back to it by pressing Down past the newest entry.
      this.historyDraft = this.promptBuffer;
    }
    const next = Math.max(-1, Math.min(this.inputHistory.length - 1, this.historyIndex + direction));
    if (next === this.historyIndex) return;
    this.historyIndex = next;
    this.promptBuffer = next === -1 ? this.historyDraft : this.inputHistory[next];
    this.cursorOffset = this.promptBuffer.length;
  }

  private submitInput(): void {
    // Expand `[ Paste N lines #token ]` placeholders back to their real
    // content before handing off to the consumer.
    let line = this.promptBuffer;
    if (this.pasteMap.size > 0) {
      for (const [token, content] of this.pasteMap.entries()) {
        if (line.includes(token)) line = line.split(token).join(content);
      }
    }
    const trimmed = line.trim();
    if (trimmed) {
      this.inputHistory = [trimmed, ...this.inputHistory.filter(h => h !== trimmed)].slice(0, 200);
    }
    this.promptBuffer = '';
    this.cursorOffset = 0;
    this.historyIndex = -1;
    this.historyDraft = '';
    this.pasteMap.clear();
    if (this.onLineSubmit) this.onLineSubmit(line);
  }

  /**
   * Remove protocol wrapper artefacts that should never reach the chat:
   *   - `<tool_call>…</tool_call>` blocks (native-tools-as-text format)
   *   - `{"type":"final","content":"…"}` envelopes (text-protocol final)
   *   - `{"type":"tool",…}` standalone envelopes
   * Used by the AGENT_MESSAGE handler as a defence in depth — the streaming
   * path also suppresses these, but non-streaming code paths emit the full
   * assistant content in one go and would otherwise leak the wrapper.
   */
  private stripProtocolEnvelopes(text: string): string {
    if (!text) return '';
    let out = text;
    // <tool_call>...</tool_call> — strip the entire block (greedy with
    // non-greedy content). Multiple blocks possible in one message.
    out = out.replace(/<tool_call>[\s\S]*?<\/tool_call>\s*/gi, '');
    // {"type":"final","content":"..."} — extract the content field.
    out = out.replace(
      /\{"type"\s*:\s*"final"\s*,\s*"content"\s*:\s*"((?:[^"\\]|\\.)*)"\s*\}/g,
      (_match, captured: string) => {
        try {
          return JSON.parse('"' + captured + '"');
        } catch {
          return captured;
        }
      }
    );
    // {"type":"tool",...} — drop entire envelope (call is handled separately).
    out = out.replace(/\{"type"\s*:\s*"tool"[\s\S]*?\}\s*/g, '');
    return out;
  }

  private commitPaste(text: string): void {
    if (!text) return;
    const lineCount = text.split('\n').length;
    // Short single-line pastes inline as-is. Multi-line pastes (or very
    // long single-line ones) become a `[ Paste N lines ]` placeholder so
    // the input row stays legible; the real content is held in pasteMap
    // and re-expanded at submit time.
    if (lineCount === 1 && text.length <= 80) {
      this.insertText(text);
      return;
    }
    const token = 'pst-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 6);
    const label = `[ Paste ${lineCount} line${lineCount === 1 ? '' : 's'} #${token} ]`;
    this.pasteMap.set(label, text);
    this.insertText(label);
  }

  private formatUserMessageBubble(content: string): string {
    const cols = this.output.columns || process.stdout.columns || 80;
    const bubbleWidth = Math.max(12, this.contentWrapWidth(cols));
    const innerWidth = Math.max(8, bubbleWidth - 1);
    const wrapped = this.wrapMultilinePreserveBreaks(`[${this.userLabel}] ${content}`, innerWidth);
    const gutter = this.contentGutter();
    const painted = wrapped.map((line) => {
      const clipped = this.truncatePlain(line, innerWidth);
      const padded = clipped + ' '.repeat(Math.max(0, innerWidth - clipped.length));
      return `${gutter}${CliRenderer.USER_BG}${CliRenderer.USER_FG}${padded} ${CliRenderer.ANSI_RESET}`;
    });
    // No gray spacer rows above/below: render only the user content lines.
    return painted.join('\n');
  }

  private wrapMultilinePreserveBreaks(text: string, width: number): string[] {
    const logical = String(text || '').split('\n');
    const out: string[] = [];
    for (const line of logical) {
      const chunks = this.wrapHardByWidth(line, width);
      if (chunks.length === 0) out.push('');
      else out.push(...chunks);
    }
    return out.length > 0 ? out : [''];
  }

  private resolveUserLabel(): string {
    try {
      const fromWhoami = String(
        execSync('whoami', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) || ''
      ).trim();
      if (fromWhoami) return fromWhoami;
    } catch {
      // Fall through to os.userInfo if whoami is unavailable.
    }
    try {
      const fromOs = String(os.userInfo().username || '').trim();
      if (fromOs) return fromOs;
    } catch {
      // Final fallback below.
    }
    return 'user';
  }

  private formatAssistantMessageBlock(content: string): string {
    // The leading '\n' IS the divider above the assistant block. If the model
    // opens the stream with "\n\n\n..." (common qwen/llama chat-template
    // artifact) and we only trimEnd, those newlines persist into history;
    // rebuildViewportFromHistory then replays them on every subsequent
    // submit, stacking 3-4 blank rows between the user bubble and the
    // response. trimStart of '\n' collapses that to the single divider.
    return '\n' + String(content || '').replace(/^\n+/, '').trimEnd();
  }

  private formatThinkingBlock(content: string): string {
    const maxContentWidth = this.thinkingContentWrapWidth();
    const lines = String(content || '')
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    if (lines.length === 0) return '';
    const wrapped: string[] = [];
    for (const line of lines) {
      const chunks = this.wrapHardByWidth(line, maxContentWidth);
      wrapped.push(...(chunks.length > 0 ? chunks : ['']));
    }
    return '\n' + this.thinkingHeader + '\n' + wrapped.map((line) => this.thinkingMarker + this.thinkingTone(line)).join('\n');
  }

  private persistThinkingIfNeeded(): void {
    // Persist the streamed thinking for the CURRENT segment so the viewport
    // rebuild (resize, or the THINK_END repaint) keeps it in the chat instead
    // of dropping it. The [thinking] layout marker lets renderLayoutEntry
    // re-wrap it at the live width (resize-safe). We flush the buffer right
    // after persisting so the next segment's reasoning (e.g. the next
    // tool-loop iteration) is captured as its own block and the same text is
    // never persisted twice — the empty-buffer check is the dedup guard, so
    // the multiple call sites (content transition, AGENT_MESSAGE, THINK_END)
    // are all safe to call. Plain/non-streamed mode persists via the THINK_END
    // writeBlock fallback instead (reasoningStreamed stays false here).
    if (!this.reasoningStreamed) return;
    const raw = this.reasoningBuffer;
    if (!raw.trim()) {
      this.reasoningStreamed = false;
      return;
    }
    const block = this.formatThinkingBlock(raw);
    if (block) {
      this.pushHistory(block, '\n[thinking] ' + raw);
    }
    this.reasoningBuffer = '';
    this.reasoningStreamed = false;
    this.reasoningPersistedThisInference = true;
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
        const block = this.formatUserMessageBubble(content);
        const layoutEntry = '\n[user] ' + content;
        this.writeBlock('\n' + block, true, layoutEntry);
        this.lastRenderedKind = 'user';
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.AGENT_MESSAGE, (event) => {
      const raw = String(event.payload.content || '');
      // Defensive cleanup: in text-protocol mode the model can emit the
      // tool call as a literal `<tool_call>{...}</tool_call>` block in the
      // assistant content. The streaming path suppresses those chunks, but
      // when AGENT_MESSAGE arrives via a non-streaming path the wrapper
      // leaks to writeBlock. Strip it here so the user never sees the raw
      // protocol envelope regardless of which path emitted it.
      const content = this.stripProtocolEnvelopes(raw);
      const normalized = content.trim();

      // Stream already rendered the response in this inference — just record
      // it to history, do NOT writeBlock again (that was the triplication).
      if (this.assistantStreamedDisplayed) {
        if (normalized) {
          this.persistThinkingIfNeeded();
          const assistantBlock = this.formatAssistantMessageBlock(content);
          this.pushHistory(assistantBlock, assistantBlock);
          this.committedAssistantByInference = normalized;
          this.lastRenderedKind = 'assistant';
        }
        return;
      }

      if (normalized && normalized === this.committedAssistantByInference) {
        return;
      }

      // Plain mode / stream disabled — display via writeBlock once. If the
      // cleanup stripped everything (model emitted a pure tool call with
      // no prose), skip the empty assistant block entirely.
      if (normalized) {
        this.persistThinkingIfNeeded();
        this.writeBlock(this.formatAssistantMessageBlock(content));
        this.committedAssistantByInference = normalized;
        this.lastRenderedKind = 'assistant';
      } else if (this.streamBuffer.trim()) {
        const cleanedBuffer = this.stripProtocolEnvelopes(this.streamBuffer).trim();
        if (cleanedBuffer) {
          this.persistThinkingIfNeeded();
          this.writeBlock(this.formatAssistantMessageBlock(cleanedBuffer));
          this.committedAssistantByInference = cleanedBuffer;
          this.lastRenderedKind = 'assistant';
        }
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.MESSAGE_CHUNK, (event) => {
      const chunk = this.normalizeChunk(event.payload.chunk || '');
      if (!chunk) return;
      this.streaming = true;
      this.streamBuffer += chunk;
      this.streamingContent = this.streamBuffer;
      this.ensureStreamingBlock();

      // Once a wrapper marker has been observed in this stream, every
      // remaining byte belongs to the wrapper — never re-render.
      if (this.suppressingToolCallStream) {
        if (!this.statusVisible && this.thinkStarted) this.showStatusLine();
        return;
      }

      // Wrapper markers that uniquely identify a tool-call/final envelope
      // emitted as text. We deliberately keep this list TIGHT: only patterns
      // that cannot reasonably appear in prose. The prior list included
      // markdown-wrapped JSON like ```json{"name":"read_file"  — but the
      // model legitimately writes those in explanations, which then
      // permanently suppressed the rest of the stream and produced the
      // "tokens emitted but nothing in CLI" symptom. The strict envelopes
      // below are the only formats the project's protocol actually emits.
      const SUPPRESS_MARKERS = [
        '<tool_call>',
        '<tool_call ',
        '<tool_call\n',
        '{"type":"tool"',
        '{"type": "tool"',
        '{"type":"final"',
        '{"type": "final"',
      ];

      // Scan only the trailing region of the buffer: the chunk that just
      // arrived plus a safety margin equal to the longest marker. Anything
      // earlier in the buffer was already scanned on a prior chunk. With a
      // long stream the old code did indexOf over the full buffer for every
      // marker on every chunk (~40-marker * O(buffer) per chunk) which
      // backpressured the reader and dropped effective tok/s.
      const maxMarkerLen = 16; // longest marker is '{"type": "final"' (16)
      const scanStart = Math.max(0, this.streamPushedUpTo - maxMarkerLen);
      const tail = this.streamBuffer.slice(scanStart);
      let markerAt = -1;
      for (const m of SUPPRESS_MARKERS) {
        const idx = tail.indexOf(m);
        if (idx !== -1) {
          const absoluteIdx = scanStart + idx;
          if (markerAt === -1 || absoluteIdx < markerAt) markerAt = absoluteIdx;
        }
      }

      // Decide how much of the buffer is SAFE to forward right now:
      //   - If a marker is present: forward everything before it, then
      //     enter permanent suppression for this stream.
      //   - Else: forward everything except a trailing tail that could
      //     still grow into a marker prefix on the next chunk. Holding
      //     that tail is what prevents the `{"type":"final` leak we saw.
      let safeEnd: number;
      if (markerAt !== -1) {
        safeEnd = markerAt;
      } else {
        safeEnd = this.streamBuffer.length;
        for (const m of SUPPRESS_MARKERS) {
          const max = Math.min(m.length - 1, this.streamBuffer.length);
          for (let n = max; n > 0; n--) {
            if (m.startsWith(this.streamBuffer.slice(-n))) {
              safeEnd = Math.min(safeEnd, this.streamBuffer.length - n);
              break;
            }
          }
        }
      }

      const pending = this.streamBuffer.slice(this.streamPushedUpTo, safeEnd);
      if (pending) {
        if (!this.plain && this.rl) {
          // First content transition: drop leading newlines emitted by the
          // model's chat template (e.g. "\n\n\nHello..."). openStreamLine
          // already writes one '\n' as the divider above the assistant
          // block, so forwarding the model's leading blanks stacks 3-4+
          // extra empty rows between the user bubble and the response.
          // Once we've entered 'content' mode we forward chunks verbatim
          // so genuine paragraph breaks mid-reply are preserved.
          let forwarded = pending;
          let shouldOpen = false;
          if (this.streamMode !== 'content') {
            forwarded = forwarded.replace(/^\n+/, '');
            shouldOpen = forwarded.length > 0;
          }
          if (forwarded) {
            if (shouldOpen) {
              this.persistThinkingIfNeeded();
              this.openStreamLine('');
              this.streamMode = 'content';
              // A response line is already on screen — AGENT_MESSAGE
              // must NOT writeBlock the same content again (duplication).
              // If the buffer turns out to be a pure wrapper that never
              // emits non-wrapper bytes, `pending` stays empty and this
              // branch never runs, so the flag stays false and the
              // unwrapped AGENT_MESSAGE content is free to render.
              this.assistantStreamedDisplayed = true;
              this.visualizer.setMode('responding');
            }
            const rendered = this.streamMarkdown.processChunk(forwarded);
            if (rendered) {
              // Hold trailing '\n's back: if the stream ends here they would
              // scroll the response off the visible region, stacking blank
              // rows below. Flush any previously-held trailing '\n's first
              // (we now know they were inter-line, not terminal).
              const trailMatch = rendered.match(/\n+$/);
              const body = trailMatch ? rendered.slice(0, -trailMatch[0].length) : rendered;
              const toWrite = this.pendingTrailingNewlines + body;
              this.pendingTrailingNewlines = trailMatch ? trailMatch[0] : '';
              if (toWrite) {
                this.writeStreamContent(toWrite);
                this.lastRenderedKind = 'assistant';
              }
            }
          }
        } else {
          this.scheduleRender();
        }
        this.streamPushedUpTo = safeEnd;
      }

      if (markerAt !== -1) {
        this.suppressingToolCallStream = true;
        if (!this.statusVisible && this.thinkStarted) this.showStatusLine();
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_START, (event) => {
      const { name, args } = event.payload;
      this.currentToolName = name || '';
      this.visualizer.setMode(MiniVisualizer.modeFromToolName(name));
      const label = this.toolLabel(name);
      // Surface what the agent is actually doing on the status bar prose.
      // Without this, the line stayed at "Thinking" while tools ran and
      // the user had no signal that the agent had moved on to Reading /
      // Writing / Patching. Snapshot the prior label so TOOL_RESULT can
      // restore it (or fall back to "Thinking").
      if (!this.toolRestoreTimer) this.prevOpLabel = this.opLabel;
      else { clearTimeout(this.toolRestoreTimer); this.toolRestoreTimer = null; }
      this.opLabel = label;
      let detail = '';
      if (name === 'run_code' && args.command) {
        // Full command — no slice. Terminal wraps if it's long; user sees
        // the entire pipeline (cd foo && npm run build && cat results), not
        // a truncated "cd foo &&" with the rest missing after the &&.
        detail = chalk.dim(': ') + chalk.white(String(args.command));
      } else if (args.path) {
        detail = ' ' + chalk.white(String(args.path));
      } else if (args.pattern) {
        detail = ' ' + chalk.white(String(args.pattern));
      } else if (args.query) {
        detail = ' ' + chalk.white(String(args.query));
      }
      const needsAssistantGap = this.lastRenderedKind === 'assistant';
      this.writeBlock((needsAssistantGap ? '\n' : '') + this.toolGlyph + this.toolTone(label) + detail);
      this.lastRenderedKind = 'tool';
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_RESULT, (event) => {
      const { result } = event.payload;
      // Schedule the visualizer + opLabel restoration AFTER the tool's
      // cascade has had time to play (CASCADE_SEC + EASE_SEC ≈ 1.85s).
      // Resetting immediately on fast tools made the wave snap back to
      // "thinking" before the user could perceive the working / listening
      // transition. Another TOOL_START before the timeout cancels this.
      if (this.toolRestoreTimer) clearTimeout(this.toolRestoreTimer);
      this.toolRestoreTimer = setTimeout(() => {
        this.toolRestoreTimer = null;
        if (this.thinkStarted) {
          this.opLabel = this.prevOpLabel || 'Thinking';
          this.visualizer.setMode('thinking');
        }
      }, 1850);
      if (this.SILENT_TOOLS.has(this.currentToolName)) return;
      if (this.currentToolName === 'run_code' && result?.success) {
        // Show first 20 lines of run_code output (was 3 × 120 char join).
        // Each line printed independently so the user reads it like real
        // shell output. Lines truncated to terminal width by the terminal.
        const raw = String(result.output || '').replace(/\r/g, '').trimEnd();
        if (!raw) {
          this.writeBlock(chalk.dim('    └─ (no output, exit 0)'));
        } else {
          const allLines = raw.split('\n');
          const MAX_OUTPUT_LINES = 20;
          const shown = allLines.slice(0, MAX_OUTPUT_LINES);
          for (const line of shown) {
            this.writeBlock(chalk.dim('    │ ') + line);
          }
          if (allLines.length > MAX_OUTPUT_LINES) {
            this.writeBlock(chalk.dim(`    └─ (${allLines.length - MAX_OUTPUT_LINES} more line${allLines.length - MAX_OUTPUT_LINES === 1 ? '' : 's'} truncated)`));
          }
        }
      } else if (!result?.success) {
        const summary = result?.error ? String(result.error).split('\n')[0].slice(0, 200) : 'failed';
        this.writeBlock('  ' + chalk.red('✗ ') + summary);
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOOL_ERROR, (event) => {
      // Same delayed-restore as TOOL_RESULT — the user should still see
      // the cascade transition into the failed tool's mode before we
      // switch back to thinking.
      if (this.toolRestoreTimer) clearTimeout(this.toolRestoreTimer);
      this.toolRestoreTimer = setTimeout(() => {
        this.toolRestoreTimer = null;
        if (this.thinkStarted) {
          this.opLabel = this.prevOpLabel || 'Thinking';
          this.visualizer.setMode('thinking');
        }
      }, 1850);
      const toolName = String(event?.payload?.toolName || this.currentToolName || '').trim();
      this.writeBlock('  ' + chalk.red('->') + ' ' + (event.payload.error || event.payload.message || 'failed'));

      // Surface stdout/stderr for failed shell commands. Before this, users
      // only saw "Exit code 1" while the useful diagnostics were present in
      // result.output but dropped from the TOOL_ERROR render path.
      const output = String(event?.payload?.output || '').replace(/\r/g, '').trim();
      if (toolName === 'run_code' && output) {
        const allLines = output.split('\n');
        const MAX_OUTPUT_LINES = 24;
        const shown = allLines.slice(0, MAX_OUTPUT_LINES);
        for (const line of shown) {
          this.writeBlock(chalk.dim('    │ ') + line);
        }
        if (allLines.length > MAX_OUTPUT_LINES) {
          this.writeBlock(
            chalk.dim(`    └─ (${allLines.length - MAX_OUTPUT_LINES} more line${allLines.length - MAX_OUTPUT_LINES === 1 ? '' : 's'} truncated)`)
          );
        }
      }
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
      // A cancellation aborts the inference outright — no [done] marker
      // should linger on the status bar from a prior completed turn.
      this.doneStatus = '';
      if (this.idleFreezeTimer) {
        clearTimeout(this.idleFreezeTimer);
        this.idleFreezeTimer = null;
      }
      this.writeBlock(chalk.red('[cancelled] ' + (event?.payload?.reason || 'cancelled')));
      this.streaming = false;
      this.streamBuffer = '';
      this.streamPushedUpTo = 0;
      this.assistantStreamedDisplayed = false;
    }));

    this.unsubscribers.push(eventBus.on(EventType.CLEAR_STREAMING, () => {
      if (this.streamLineOpen) {
        if (this.streamMode === 'content') {
          const pending = this.streamMarkdown.flushPending();
          // A non-empty final line proves the held newlines were inter-line,
          // not trailing — emit them before the line. If empty, they were
          // truly trailing and we drop them.
          if (pending) this.writeStreamContent(this.pendingTrailingNewlines + pending);
          this.pendingTrailingNewlines = '';
        }
        this.output.write('\n\n');
        this.streamLineOpen = false;
      }
      this.streamMode = 'none';
      this.streamMarkdown.reset();
      this.clearStreamingBlock();
      this.streamBuffer = '';
      this.streamPushedUpTo = 0;
      this.suppressingToolCallStream = false;
      if (this.pendingReflowAfterStream) {
        this.pendingReflowAfterStream = false;
        this.reflow();
        return;
      }
      if (!this.repaintViewportIfNeeded()) {
        this.renderActive();
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.THINK_END, () => {
      const hadReasoningStreamed = this.reasoningStreamed;
      const hadAssistantStreamedDisplayed = this.assistantStreamedDisplayed;
      if (this.streamLineOpen) {
        if (this.streamMode === 'content') {
          const pending = this.streamMarkdown.flushPending();
          // A non-empty final line means the held newlines were inter-line —
          // emit them before it. If empty, they were trailing: dropping them
          // avoids scrolling the response off with blank rows below.
          if (pending) this.writeStreamContent(this.pendingTrailingNewlines + pending);
          this.streamMarkdown.reset();
        }
        this.pendingTrailingNewlines = '';
        this.output.write('\n');
        this.streamLineOpen = false;
      }
      this.streamMode = 'none';

      // Trivial-prompt models (e.g. phenom on "olá") emit <think>X</think>X
      // — the thinking block ends up byte-for-byte equal to the final answer.
      // Showing both is redundant; suppress thinking ONLY when it is exactly
      // equal to the answer after whitespace/case normalization. The previous
      // implementation also suppressed on substring overlap (len ≥ 20 + one
      // contains the other), which fired any time the model paraphrased its
      // reasoning into the visible reply — the common case — and erased the
      // thinking block the user wanted to see. Keep exact-equality only.
      const norm = (s: string) => s.replace(/\s+/g, ' ').trim().toLowerCase();
      const answerSource = this.streamBuffer || this.committedAssistantByInference;
      const contentNorm = norm(answerSource);
      const isDuplicateOfAnswer = (reasoningRaw: string): boolean => {
        const r = norm(reasoningRaw);
        if (!r || !contentNorm) return false;
        return r === contentNorm;
      };

      // Case A: reasoning still buffered (no MESSAGE_CHUNK transition flushed
      // it yet). Drop it without persisting.
      if (isDuplicateOfAnswer(this.reasoningBuffer)) {
        this.reasoningBuffer = '';
        this.reasoningStreamed = false;
      } else {
        const thinkingBlock = this.formatThinkingBlock(this.reasoningBuffer);
        // In TTY stream mode the thinking block is already visible, but it
        // must still be persisted to history so reflow/repaint keeps it on
        // screen after THINK_END.
        if (this.reasoningStreamed) {
          this.persistThinkingIfNeeded();
        } else if (thinkingBlock) {
          // Plain-mode fallback: if reasoning was buffered but not streamed
          // inline, emit it now once. Pass the raw reasoning as layoutText so a
          // resize re-wraps it instead of replaying the baked-in width.
          this.writeBlock(thinkingBlock, true, '\n[thinking] ' + this.reasoningBuffer);
        }
        this.reasoningBuffer = '';
        this.reasoningStreamed = false;
      }

      // Case B: reasoning was already persisted by the MESSAGE_CHUNK transition
      // (cli-renderer's thinking-to-content switch calls persistThinkingIfNeeded
      // before reasoningBuffer is cleared). Walk back from the end of
      // layoutHistory; if the most recent [thinking] entry duplicates the
      // answer, splice it out of both arrays so rebuildViewportFromHistory
      // erases it from screen.
      if (contentNorm) {
        for (let i = this.layoutHistory.length - 1; i >= 0; i--) {
          const entry = this.layoutHistory[i];
          const m = entry.match(/^\n?\[thinking\] ([\s\S]*)$/);
          if (m) {
            if (isDuplicateOfAnswer(m[1])) {
              this.layoutHistory.splice(i, 1);
              if (i < this.history.length) this.history.splice(i, 1);
            }
            break;
          }
        }
      }
      if (this.renderTimer) { clearTimeout(this.renderTimer); this.renderTimer = null; }

      // Capture stats BEFORE clearing status so they survive into the [done] line.
      const elapsed = this.actionStartTime > 0
        ? this.formatDuration(Date.now() - this.actionStartTime)
        : '';
      const tokenStr = this.formatTokenStats();
      const tpsStr = this.tokensPerSecond && this.tokensPerSecond > 0
        ? ' · ' + this.formatTokensPerSecond(this.tokensPerSecond)
        : '';
      const statsStr = elapsed ? ' ' + elapsed + tokenStr + tpsStr : '';
      const doneLine = chalk.green('[done]') + chalk.dim(statsStr);

      // Single source of truth for assistant display:
      //   - chunks already on screen → just persist to history.
      //   - otherwise → emit once via writeBlock.
      // When suppressingToolCallStream is set, streamBuffer holds raw
      // protocol wrapper bytes (JSON envelope or <tool_call> tag). It
      // must NEVER be written or persisted — the unwrapped content
      // arrives separately via AGENT_MESSAGE.
      const streamed = this.streamBuffer.trim();
      if (
        streamed &&
        streamed !== this.committedAssistantByInference &&
        !this.suppressingToolCallStream
      ) {
        const assistantBlock = this.formatAssistantMessageBlock(this.streamBuffer);
        if (this.assistantStreamedDisplayed) {
          this.pushHistory(assistantBlock, assistantBlock);
        } else {
          this.writeBlock(assistantBlock);
        }
        this.committedAssistantByInference = streamed;
        this.lastRenderedKind = 'assistant';
      }

      this.streamBuffer = '';
      this.streamPushedUpTo = 0;
      this.streamingBlockId = null;
      this.streamingContent = '';
      this.streaming = false;
      this.assistantStreamedDisplayed = false;
      this.suppressingToolCallStream = false;

      // [done] stays pinned to the status bar only (not in chat history).
      this.doneStatus = doneLine;
      this.thinkStarted = false;
      this.statusVisible = true;
      this.lastStatusLine = '';

      // Cascade smoothly down to the (very low energy) idle state. The
      // wave animation stays on permanently — a frozen visualizer would
      // jump by exactly one frame on every keystroke that triggers a
      // refreshStatus, which read as visible micro-stutter. Idle's energy
      // is tiny enough that the always-on breath is barely perceptible.
      this.visualizer.setMode('idle');
      if (this.idleFreezeTimer) { clearTimeout(this.idleFreezeTimer); this.idleFreezeTimer = null; }
      this.refreshStatus();
      if (this.pendingReflowAfterStream) {
        this.pendingReflowAfterStream = false;
        this.reflow();
      } else if (hadReasoningStreamed && this.altScreenActive && !this.plain) {
        // Thinking was streamed live and is now persisted to history (see
        // persistThinkingIfNeeded). Rebuild from history so the on-screen
        // thinking is replaced by the canonical, resize-safe [thinking] block
        // — keeping thinking AND the answer instead of dropping thinking.
        this.rebuildViewportFromHistory();
      } else if (hadAssistantStreamedDisplayed) {
        // No thinking to drop — keep the streamed answer exactly where it is
        // (rebuilding would make it "jump").
        this.renderActive();
      } else {
        this.repaintViewportIfNeeded();
      }
    }));

    this.unsubscribers.push(eventBus.on(EventType.THINK_START, (event) => {
      this.committedAssistantByInference = '';
      this.assistantStreamedDisplayed = false;
      this.reasoningBuffer = '';
      this.reasoningPersistedThisInference = false;
      this.pendingFileDiffs.clear();
      this.streamMarkdown.reset();
      this.suppressingToolCallStream = false;
      this.pendingTrailingNewlines = '';
      this.thinkingContentCol = 0;
      // A new inference reclaims the status bar — the previous [done]
      // marker (and any pending freeze) must clear so the bar shows the
      // live "Thinking ..." prose with an animated wave again.
      this.doneStatus = '';
      if (this.idleFreezeTimer) {
        clearTimeout(this.idleFreezeTimer);
        this.idleFreezeTimer = null;
      }
      this.startThink(event?.payload?.message || 'Thinking');
    }));

    this.unsubscribers.push(eventBus.on(EventType.REASONING_CHUNK, (event) => {
      const chunk = this.normalizeChunk(event.payload?.chunk || '');
      if (!chunk) return;
      this.reasoningBuffer += chunk;

      if (!this.plain && this.rl) {
        if (this.streamMode !== 'thinking') {
          this.openStreamLine(this.thinkingHeader + '\n');
          this.writeStreamContent(this.thinkingMarker);
          this.streamMode = 'thinking';
          this.thinkingContentCol = 0;
        }
        this.reasoningStreamed = true;
        const maxContentWidth = this.thinkingContentWrapWidth();
        // Newlines inside chunk need the marker prefix to keep the left edge
        // consistent. Marker is written outside the italic tone so it stays
        // cyan and is not styled with the content. Wrapping subtracts the
        // running column (thinkingContentCol) so fragments split across chunks
        // never exceed maxContentWidth and leak past the "│ " gutter.
        const segments = chunk.split('\n');
        for (let i = 0; i < segments.length; i++) {
          const segment = segments[i] || '';
          const trailingEmpty = i === segments.length - 1 && segment.length === 0;
          if (i > 0 && !trailingEmpty) {
            this.writeStreamContent('\n' + this.thinkingMarker);
            this.thinkingContentCol = 0;
          }
          if (!segment) continue;
          const wrapped = this.wrapHardByWidthFromOffset(segment, maxContentWidth, this.thinkingContentCol);
          for (let j = 0; j < wrapped.length; j++) {
            const piece = wrapped[j] || '';
            if (piece) this.writeStreamContent(this.thinkingTone(piece));
            if (j < wrapped.length - 1) {
              this.writeStreamContent('\n' + this.thinkingMarker);
              this.thinkingContentCol = 0;
            } else {
              this.thinkingContentCol += piece.length;
            }
          }
        }
        this.lastRenderedKind = 'thinking';
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
      this.visualizer.setMode(MiniVisualizer.modeFromOpLabel(this.opLabel));
      this.showStatusLine();
    }));

    this.unsubscribers.push(eventBus.on(EventType.TOKEN_UPDATE, (event) => {
      if (event?.payload) {
        if (typeof event.payload.total === 'number' && Number.isFinite(event.payload.total)) {
          this.tokenTotal = Math.max(0, event.payload.total);
        }
        if (typeof event.payload.input === 'number' && Number.isFinite(event.payload.input)) {
          this.tokenInput = Math.max(0, event.payload.input);
        }
        if (typeof event.payload.output === 'number' && Number.isFinite(event.payload.output)) {
          this.tokenOutput = Math.max(0, event.payload.output);
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

  private contentGutter(): string {
    return ' '.repeat(Math.max(0, CliRenderer.CONTENT_GUTTER_COLS));
  }

  private contentWrapWidth(cols?: number): number {
    const terminalCols = cols ?? this.output.columns ?? process.stdout.columns ?? 80;
    // Match prompt/status safety rule: never paint the last column.
    const paintCols = Math.max(1, terminalCols - 1);
    return Math.max(1, paintCols - CliRenderer.CONTENT_GUTTER_COLS);
  }

  private applyContentGutterBlock(text: string): string {
    const gutter = this.contentGutter();
    const lines = String(text || '').split('\n');
    return lines.map((line) => gutter + line).join('\n');
  }

  private thinkingContentWrapWidth(cols?: number): number {
    const markerWidth = Math.max(0, this.stripAnsi(this.thinkingMarker).length);
    return Math.max(1, this.contentWrapWidth(cols) - markerWidth);
  }

  private writeStreamContent(chunk: string): void {
    if (!chunk) return;
    const gutter = this.contentGutter();
    let out = '';
    for (let i = 0; i < chunk.length; i++) {
      if (this.streamNeedsGutterPrefix) out += gutter;
      const ch = chunk[i]!;
      out += ch;
      this.streamNeedsGutterPrefix = ch === '\n';
    }
    this.output.write(out);
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
    const w = Math.max(1, width ?? this.contentWrapWidth());
    let n = 0;
    for (const item of items) n += this.countVisualLines(item, w);
    return n;
  }

  private clampToWidth(line: string, width: number): string {
    const visible = this.stripAnsi(line);
    if (visible.length <= width) return line;
    // Silent truncation — never inject "..." into the status row, since the
    // overflow falls on the visualizer's trailing columns and the dots
    // visually replace the wave glyphs. ANSI codes are dropped in this
    // path; upstream width calculation in getStatusLine targets total =
    // cols exactly, so this branch should rarely trigger.
    return visible.slice(0, width);
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

  /**
   * Full viewport rebuild from in-memory history. Used after terminal resize
   * so the visible screen reflects current width constraints (web-like
   * responsive reflow) instead of leaving stale wrapped artifacts behind.
   */
  private rebuildViewportFromHistory(): void {
    if (this.plain) return;
    const rows = this.output.rows || process.stdout.rows;
    const cols = this.output.columns || process.stdout.columns || 80;
    if (!rows || rows < 3) return;

    const contentRows = Math.max(1, rows - this.bottomBarRows());
    const entries: string[] = [];
    let used = 0;

    // Pick the newest history entries that fit the content region.
    // Count against the ACTUAL paint width (cols - 1, the column the renderer
    // never writes to avoid autowrap). The old code counted against
    // contentWrapWidth (cols - 2), so every full-width rendered line — the
    // user bubble is padded to exactly cols - 1 — was counted as 2 rows
    // instead of 1. That inflated `used`, pushed `startRow` up, and left the
    // newest entry ending well above the bottom; the gap (1 phantom row per
    // history entry) showed as blank lines below the freshly submitted bubble
    // and grew with every turn.
    const countWidth = Math.max(1, cols - 1);
    for (let i = this.layoutHistory.length - 1; i >= 0; i--) {
      const item = this.renderLayoutEntry(this.layoutHistory[i]);
      const cost = this.countVisualLines(item, countWidth);
      if (entries.length > 0 && used + cost > contentRows) break;
      entries.push(item);
      used += cost;
      if (used >= contentRows) break;
    }
    entries.reverse();

    // Clear alt-screen and redraw content region anchored to the bottom of
    // the content area so ending an inference doesn't make the chat "jump"
    // to the top when canonical repaint runs.
    this.output.write('\x1b[2J\x1b[H');
    this.streamScrollRegionActive = false;
    this.enterStreamScrollRegion();
    const startRow = Math.max(1, contentRows - used + 1);
    this.output.write(`\x1b[${startRow};1H`);
    for (const entry of entries) {
      this.output.write(entry);
      if (!entry.endsWith('\n')) this.output.write('\n');
    }

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

  private repaintViewportIfNeeded(): boolean {
    if (!this.canonicalRepaint) return false;
    if (!this.altScreenActive) return false;
    if (this.streamLineOpen) return false;
    this.rebuildViewportFromHistory();
    return true;
  }

  private pushHistory(text: string, layoutText?: string): void {
    this.history.push(text);
    if (this.history.length > this.maxHistory) this.history.shift();
    this.layoutHistory.push(layoutText ?? text);
    if (this.layoutHistory.length > this.maxHistory) this.layoutHistory.shift();
  }

  private renderLayoutEntry(entry: string): string {
    if (entry.startsWith('\n[user] ')) {
      return '\n' + this.formatUserMessageBubble(entry.slice('\n[user] '.length));
    }
    if (entry.startsWith('[user] ')) {
      return this.formatUserMessageBubble(entry.slice('[user] '.length));
    }
    // Re-wrap the thinking block at the CURRENT width (resize-safe). The gutter
    // is applied here to match the live-streamed " │ ..." left edge.
    if (entry.startsWith('\n[thinking] ')) {
      return this.applyContentGutterBlock(
        this.formatThinkingBlock(entry.slice('\n[thinking] '.length))
      );
    }
    return this.applyContentGutterBlock(entry);
  }

  private writeBlock(text: string, record: boolean = true, layoutText?: string): void {
    if (record) {
      this.pushHistory(text, layoutText);
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
    const isUserBubble = layoutText?.startsWith('[user] ') === true || layoutText?.startsWith('\n[user] ') === true;
    const renderedText = isUserBubble
      ? text
      : this.applyContentGutterBlock(text);

    // Move cursor INTO the scroll region before writing — otherwise it might
    // still be parked at the prompt input row from the previous
    // drawFixedPrompt, and we'd write block text on top of the pinned prompt.
    this.positionAtContentRegion();
    this.clearActive();
    readline.cursorTo(this.output, 0);
    this.output.write('\x1b[K');
    if (isAssistant) this.output.write('\n');
    this.output.write(renderedText + '\n');
    if (isAssistant) this.output.write('\n');
    this.firstRender = false;
    this.activeLines = 0;
    const shouldCanonicalRepaint =
      this.canonicalRepaint &&
      this.altScreenActive &&
      !this.thinkStarted &&
      !this.streaming &&
      !this.streamLineOpen;
    if (shouldCanonicalRepaint) {
      this.rebuildViewportFromHistory();
    } else {
      this.renderActive();
    }
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
      const thinkingToContent = this.streamMode === 'thinking' && label === '';
      this.output.write(thinkingToContent ? '\n\n' : '\n');
      this.streamNeedsGutterPrefix = true;
    } else {
      this.positionAtContentRegion();
      this.clearActive();
      readline.cursorTo(this.output, 0);
      this.output.write('\x1b[K');
      this.output.write('\n');
      this.streamNeedsGutterPrefix = true;
    }
    this.writeStreamContent(label);
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
        const assistantBlock = this.formatAssistantMessageBlock(streamedText);
        if (this.plain || !this.rl) {
          this.writeBlock(assistantBlock);
        } else {
          this.pushHistory(assistantBlock, assistantBlock);
        }
        this.committedAssistantByInference = streamedText.trim();
      }

      if (incomingText.trim() && incomingText.trim() !== streamedText.trim()) {
        this.writeBlock(this.formatAssistantMessageBlock(incomingText));
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
    this.tokenInput = 0;
    this.tokenOutput = 0;
    this.streamMode = 'none';
    this.reasoningStreamed = false;
    this.reasoningPersistedThisInference = false;
    this.opLabel = this.deriveOpLabel(this.currentAction, '');
    this.visualizer.setMode(MiniVisualizer.modeFromOpLabel(this.opLabel));
    this.thinkStarted = true;
    this.statusVisible = false;
    this.scheduleRender();
  }

  private showStatusLine(): void {
    this.statusVisible = true;
    // Start the wave animation timer ONLY during active inference. Outside
    // inference the bottom bar must stay idle so the terminal scrollback
    // works — constant repaints fight any user scroll attempt and make
    // mouse-wheel "stuck".
    this.startWaveAnimation();
    this.refreshStatus();
  }

  /**
   * Start the per-frame wave repaint timer. 33 ms ≈ 30 fps — required for
   * the smootherstep cascade transitions and per-mode chaos to read as
   * fluid motion. The timer runs ONLY during active inference (and for the
   * ~2 s cascade-to-idle freeze after THINK_END), so terminal scrollback
   * stays usable in the idle period when no paints are firing.
   */
  private startWaveAnimation(): void {
    if (this.statusInterval) return; // already running
    this.statusInterval = setInterval(() => this.refreshStatus(), 33);
  }

  private stopWaveAnimation(): void {
    if (!this.statusInterval) return;
    clearInterval(this.statusInterval);
    this.statusInterval = null;
  }

  /**
   * Redraw the status line. The bottom bar is pinned permanently (alt-screen
   * + DECSTBM), so either branch paints it via drawFixedPrompt:
   *   - During stream: preserveCursor=true so the content cursor stays put.
   *   - Idle: preserveCursor=false so the cursor lands on the prompt input
   *     column for readline to echo the next keystroke there.
   */
  private refreshStatus(): void {
    // Avoid repainting bottom bars while stream writes are active. On some
    // terminals/tmux this interleaves status redraw with chunk output and
    // corrupts the visible content (duplicated "Thinking ..." lines).
    if (this.streamLineOpen) return;
    this.drawFixedPrompt({ preserveCursor: false });
  }

  private clearStatusLine(): void {
    this.statusVisible = false;
    this.lastStatusLine = '';
    this.thinkStarted = false;
    this.visualizer.setMode('idle');
    // Wave animation stays on permanently (started in bindInput). A frozen
    // visualizer jumps one frame per keystroke when refreshStatus fires
    // from input events — continuous 30 FPS dissolves that into the
    // animation itself.
    this.refreshStatus();
  }

  /**
   * Compose the bottom status row. Two parts:
   *   - Left: prose status (label + counters) — present only during active
   *     inference (statusVisible + thinkStarted).
   *   - Right: visualizer wave — always painted, even at idle. Width adapts
   *     to whatever space is left on the row, so on terminal resize the wave
   *     grows or shrinks to fill the remaining edge.
   *
   * Returns `null` only when there is literally nothing to paint (alt-screen
   * not active OR cols unknown). drawFixedPrompt handles the null case.
   */
  private getStatusLine(): string | null {
    if (this.plain) return null;
    const cols = this.output.columns || process.stdout.columns || 80;
    if (cols < 12) return null;
    const safeCols = Math.max(4, cols - 1);

    // Compose the prose section. Three states:
    //   - Active inference (statusVisible && thinkStarted): live op label
    //     plus running elapsed/token counters.
    //   - Just-completed inference (doneStatus set): the pinned [done]
    //     line with final stats, kept until the next THINK_START.
    //   - Otherwise: no prose, only the wave.
    let prose = '';
    let proseVisibleLen = 0;
    if (this.statusVisible && this.thinkStarted) {
      const elapsed = this.formatDuration(Date.now() - this.actionStartTime);
      const tokenStr = this.formatTokenStats();
      const tpsStr = this.tokensPerSecond && this.tokensPerSecond > 0
        ? ' · ' + this.formatTokensPerSecond(this.tokensPerSecond)
        : '';
      const label = this.opLabel || 'Thinking';
      prose = chalk.gray(label + ' (' + elapsed + tokenStr + tpsStr + ' · esc to interrupt)');
      proseVisibleLen = this.stripAnsi(prose).length;
    } else if (this.doneStatus) {
      prose = this.doneStatus;
      proseVisibleLen = this.stripAnsi(prose).length;
    }

    // Compute visualizer width = whatever space is left on the row after the
    // prose, minus a 1-col margin. Resizing the terminal automatically
    // changes `cols`, so the wave grows/shrinks on every paint.
    const margin = 1;
    const available = safeCols - proseVisibleLen - margin;
    if (available < 4) {
      // Terminal too narrow for the wave AND the prose: drop the wave so the
      // prose stays legible.
      return prose || null;
    }
    this.visualizer.setWidth(available);
    const wave = chalk.cyan(this.visualizer.render());

    // Left-pad with the prose and a single space, then right-align the wave.
    if (proseVisibleLen === 0) {
      // Idle: only the wave, right-aligned.
      return ' '.repeat(margin) + wave;
    }
    return prose + ' '.repeat(margin) + wave;
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
    // Per-action header palette so the eye can tell at a glance what kind
    // of mutation happened without parsing the verb.
    const headerStyle = diff.action === 'created' ? chalk.green.bold
      : diff.action === 'deleted' ? chalk.red.bold
        : diff.action === 'patched' ? chalk.yellow.bold
          : chalk.cyan.bold;
    const label = diff.action === 'created' ? 'created'
      : diff.action === 'deleted' ? 'deleted'
        : diff.action === 'patched' ? 'patched'
          : 'updated';

    const headerInfo = diff.action === 'patched'
      ? `${diff.lineCount} op${diff.lineCount === 1 ? '' : 's'}`
      : `${diff.lineCount} lines, ${diff.byteSize} B`;
    this.writeBlock(
      headerStyle(`  ◆ ${diff.path}`) +
      chalk.dim(' (') +
      headerStyle(label) +
      chalk.dim(`, ${headerInfo})`)
    );

    if (!diff.content) return;

    // Single rendering path for ALL diff actions (created, updated, patched,
    // deleted). Each line is "<N> <marker?> │ <text>" or a section header
    // ("── op N/M ──"). If the line carries an explicit marker (+/-/~), use
    // that for colour; otherwise fall back to the action's marker.
    const fallbackMarker = this.markerForAction(diff.action);
    const lines = diff.content.replace(/\n$/, '').split('\n');

    for (const line of lines) {
      if (line.startsWith('── op ')) {
        this.writeBlock('  ' + chalk.yellow.italic(line));
        continue;
      }
      if (line === '') {
        this.writeBlock('  ');
        continue;
      }
      // Match: "   N <marker?> │ <text>" — marker is optional.
      const m = line.match(/^(\s*\d+)\s*([+\-~]?)\s*│\s?(.*)$/);
      if (m) {
        const [, lineNoRaw, explicitMarker, text] = m;
        const marker = (explicitMarker || fallbackMarker) as '+' | '-' | '~';
        const lineNo = chalk.dim(lineNoRaw.padStart(4, ' '));
        const pipe = chalk.dim('│');
        // Marker glyph: bold + saturated to draw the eye; text body uses a
        // softer green/red so unchanged context tokens inside a line don't
        // compete with the marker for attention.
        const markerStyled = marker === '+' ? chalk.green.bold(marker)
          : marker === '-' ? chalk.red.bold(marker)
            : chalk.dim(marker);
        const textStyled = marker === '+' ? chalk.green(text)
          : marker === '-' ? chalk.red(text)
            : chalk.gray(text);
        this.writeBlock(`  ${lineNo} ${markerStyled} ${pipe} ${textStyled}`);
      } else {
        // Doesn't fit "<N> <marker?> │ <text>" — render as plain dim text.
        this.writeBlock('  ' + chalk.gray(line));
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

  /**
   * Visual gap (blank rows) between the end of the content scroll region
   * and the status bar. Keeps streamed output from butting directly against
   * the visualizer / [done] line.
   */
  private static readonly BOTTOM_GAP_ROWS = 1;
  private static readonly INPUT_GAP_TOP_ROWS = 1;
  private static readonly INPUT_GAP_BOTTOM_ROWS = 1;
  private static readonly MAX_PROMPT_ROWS = 10;
  private static readonly INPUT_FIRST_PREFIX = '> ';
  private static readonly INPUT_CONT_PREFIX = '  ';
  private static readonly USER_BG = '\x1b[48;5;236m';
  private static readonly USER_FG = '\x1b[38;5;252m';
  private static readonly ANSI_RESET = '\x1b[0m';
  private static readonly CONTENT_GUTTER_COLS = 1;

  /**
   * Rows reserved at the bottom of the screen:
   *   GAP + 1 (status) + INPUT_GAP_TOP + N(prompt) + INPUT_GAP_BOTTOM.
   * The fixed gaps keep the input area from feeling cramped and remain
   * outside the scroll region, so streamed content never overwrites them.
   */
  private bottomBarRows(): number {
    return (
      CliRenderer.BOTTOM_GAP_ROWS +
      1 +
      CliRenderer.INPUT_GAP_TOP_ROWS +
      Math.max(1, Math.min(CliRenderer.MAX_PROMPT_ROWS, this.promptRowsRendered)) +
      CliRenderer.INPUT_GAP_BOTTOM_ROWS
    );
  }

  private enterStreamScrollRegion(): void {
    if (this.plain || this.streamScrollRegionActive) return;
    const rows = this.output.rows || process.stdout.rows;
    if (!rows || rows < 4) return;
    // DECSTBM \x1b[T;Br moves cursor to (1,1); wrap in save/restore so we
    // resume from wherever we were before setting the region. The region
    // ends just above the bottom bar (status + prompt rows).
    const last = Math.max(1, rows - this.bottomBarRows());
    this.output.write(this.saveCursorSeq() + `\x1b[1;${last}r` + this.restoreCursorSeq());
    this.streamScrollRegionActive = true;
  }

  /**
   * Resize DECSTBM so the scroll region accounts for the current prompt
   * height. Called whenever the number of prompt rows changes (paste, Alt+
   * Enter, etc.) so streaming output never overlaps the input area.
   */
  private resyncScrollRegion(): void {
    if (this.plain || !this.altScreenActive) return;
    const rows = this.output.rows || process.stdout.rows;
    if (!rows || rows < 4) return;
    const last = Math.max(1, rows - this.bottomBarRows());
    this.output.write(this.saveCursorSeq() + `\x1b[1;${last}r` + this.restoreCursorSeq());
    this.streamScrollRegionActive = true;
  }

  private exitStreamScrollRegion(): void {
    if (this.plain || !this.streamScrollRegionActive) return;
    const rows = this.output.rows || process.stdout.rows;
    const bar = this.bottomBarRows();
    let clear = '';
    if (rows && rows >= bar) {
      for (let r = rows - bar + 1; r <= rows; r++) clear += `\x1b[${r};1H\x1b[K`;
    }
    this.output.write(this.saveCursorSeq() + '\x1b[r' + clear + this.restoreCursorSeq());
    this.streamScrollRegionActive = false;
  }

  /**
   * Paint the pinned bottom bar — one status row plus N prompt rows. With
   * multi-line input (paste, Alt+Enter, soft-wrap by terminal width), N grows
   * up to MAX_PROMPT_ROWS and the DECSTBM scroll region resizes to keep content
   * above. The first prompt row gets the `> ` prefix; continuation rows get two
   * spaces so the input column stays aligned with the cursor.
   */
  private drawFixedPrompt(opts?: { preserveCursor?: boolean }): void {
    if (this.plain) return;
    const rows = this.output.rows || process.stdout.rows;
    if (!rows || rows < 2) return;
    const cols = this.output.columns || process.stdout.columns || 80;
    const preserveCursor = opts?.preserveCursor === true;
    const prompt = this.computePromptViewport(cols);
    const visibleLineCount = prompt.visibleLines.length;

    // Resize the bottom bar (status + prompt) if the prompt height changed.
    if (visibleLineCount !== this.promptRowsRendered) {
      this.promptRowsRendered = visibleLineCount;
      this.resyncScrollRegion();
    }

    const statusLine = this.getStatusLine();
    // Never paint the very last terminal column: some terminals/tmux panes
    // trigger autowrap when the last cell is written, leaking status text
    // into the chat region.
    const paintCols = Math.max(1, cols - 1);
    const statusPainted = statusLine ? this.clampToWidth(statusLine, paintCols) : '';
    const statusRow = rows - (
      CliRenderer.INPUT_GAP_TOP_ROWS +
      visibleLineCount +
      CliRenderer.INPUT_GAP_BOTTOM_ROWS
    );
    const promptFirstRow = statusRow + 1 + CliRenderer.INPUT_GAP_TOP_ROWS;

    let out = '';
    if (preserveCursor) out += this.saveCursorSeq();

    // Status row
    out += `\x1b[${statusRow};1H\x1b[K`;
    if (statusPainted) out += statusPainted;

    // Blank gap between status and input.
    for (let i = 0; i < CliRenderer.INPUT_GAP_TOP_ROWS; i++) {
      out += `\x1b[${statusRow + 1 + i};1H\x1b[K` + this.paintInputGapRow(paintCols);
    }

    // Prompt rows
    for (let i = 0; i < visibleLineCount; i++) {
      const lineText = prompt.visibleLines[i] ?? '';
      const prefix = prompt.prefixes[i] ?? CliRenderer.INPUT_CONT_PREFIX;
      out += `\x1b[${promptFirstRow + i};1H\x1b[K` + this.paintInputRow(prefix, lineText, paintCols);
    }

    // Blank gap below input.
    for (let i = 0; i < CliRenderer.INPUT_GAP_BOTTOM_ROWS; i++) {
      out += `\x1b[${promptFirstRow + visibleLineCount + i};1H\x1b[K` + this.paintInputGapRow(paintCols);
    }

    if (preserveCursor) {
      out += this.restoreCursorSeq();
    } else {
      // Park terminal cursor at the offset inside the visible window.
      if (prompt.cursorRow >= 0 && prompt.cursorRow < visibleLineCount) {
        // Prefix takes 2 cols; cursor column is offset by 2 plus the typed
        // column in the current wrapped row.
        const screenCol = 3 + prompt.cursorCol;
        out += `\x1b[${promptFirstRow + prompt.cursorRow};${screenCol}H`;
      }
    }
    this.output.write(out);
  }

  private computePromptViewport(cols: number): {
    visibleLines: string[];
    prefixes: string[];
    cursorRow: number;
    cursorCol: number;
  } {
    const logicalLines = this.promptBuffer.length === 0 ? [''] : this.promptBuffer.split('\n');
    // drawFixedPrompt paints at most (cols - 1) to avoid last-column autowrap.
    // Input wrapping must use the exact same paint width; otherwise the final
    // character of a full row is wrapped in the viewport math but clipped on
    // actual paint (the "last char disappears" bug).
    const paintCols = Math.max(1, cols - 1);
    const contentWidth = Math.max(1, paintCols - CliRenderer.INPUT_FIRST_PREFIX.length);
    const wrapped: Array<{ text: string; logicalRow: number; wrapIndex: number }> = [];

    for (let row = 0; row < logicalLines.length; row++) {
      const chunks = this.wrapHardByWidth(logicalLines[row] || '', contentWidth);
      if (chunks.length === 0) {
        wrapped.push({ text: '', logicalRow: row, wrapIndex: 0 });
        continue;
      }
      for (let i = 0; i < chunks.length; i++) {
        wrapped.push({ text: chunks[i], logicalRow: row, wrapIndex: i });
      }
    }

    const cursor = this.cursorRowCol();
    let cursorWrappedRow = 0;
    for (const item of wrapped) {
      if (item.logicalRow < cursor.row) {
        cursorWrappedRow++;
        continue;
      }
      if (item.logicalRow === cursor.row) {
        const target = Math.floor(cursor.col / contentWidth);
        if (item.wrapIndex < target) {
          cursorWrappedRow++;
          continue;
        }
      }
      break;
    }

    const maxRows = CliRenderer.MAX_PROMPT_ROWS;
    const totalRows = Math.max(1, wrapped.length);
    let firstVisible = 0;
    if (totalRows > maxRows) {
      firstVisible = Math.max(0, Math.min(
        totalRows - maxRows,
        cursorWrappedRow - (maxRows - 1)
      ));
    }

    const visibleWrapped = wrapped.slice(firstVisible, firstVisible + maxRows);
    const visibleLines = visibleWrapped.map(v => v.text);
    const prefixes = visibleWrapped.map((v, idx) =>
      idx === 0 && firstVisible === 0 && v.logicalRow === 0 && v.wrapIndex === 0
        ? CliRenderer.INPUT_FIRST_PREFIX
        : CliRenderer.INPUT_CONT_PREFIX
    );
    const cursorRow = cursorWrappedRow - firstVisible;
    const cursorCol = Math.max(0, cursor.col % contentWidth);

    return {
      visibleLines: visibleLines.length > 0 ? visibleLines : [''],
      prefixes: prefixes.length > 0 ? prefixes : [CliRenderer.INPUT_FIRST_PREFIX],
      cursorRow,
      cursorCol,
    };
  }

  private wrapHardByWidth(text: string, width: number): string[] {
    if (width <= 0) return [text];
    if (text.length === 0) return [''];
    const out: string[] = [];
    for (let i = 0; i < text.length; i += width) {
      out.push(text.slice(i, i + width));
    }
    return out.length > 0 ? out : [''];
  }

  /**
   * Wrap `text` to a line of `width` content columns, given `offset` columns
   * already used on the current line. The first returned piece fills the
   * remaining space (width - offset); later pieces use the full width. The
   * caller inserts a newline + marker between pieces. When the line is already
   * full (offset >= width) the first piece is empty, forcing an immediate wrap.
   */
  private wrapHardByWidthFromOffset(text: string, width: number, offset: number): string[] {
    if (width <= 0) return [text];
    if (text.length === 0) return [''];
    const out: string[] = [];
    const firstWidth = width - offset;
    let i = 0;
    if (firstWidth <= 0) {
      out.push(''); // line full → emit nothing, caller wraps before content
    } else {
      out.push(text.slice(0, firstWidth));
      i = firstWidth;
    }
    for (; i < text.length; i += width) {
      out.push(text.slice(i, i + width));
    }
    return out;
  }

  private paintInputRow(prefix: string, content: string, cols: number): string {
    const raw = `${prefix}${content}`;
    const clipped = this.truncatePlain(raw, cols);
    const padded = clipped + ' '.repeat(Math.max(0, cols - clipped.length));
    return `${CliRenderer.USER_BG}${CliRenderer.USER_FG}${padded}${CliRenderer.ANSI_RESET}`;
  }

  private paintInputGapRow(cols: number): string {
    return `${CliRenderer.USER_BG}${CliRenderer.USER_FG}${' '.repeat(Math.max(0, cols))}${CliRenderer.ANSI_RESET}`;
  }

  private truncatePlain(text: string, maxChars: number): string {
    if (maxChars <= 0) return '';
    return text.length <= maxChars ? text : text.slice(0, maxChars);
  }

  private saveCursorSeq(): string {
    // ESC 7 / ESC 8 (DECSC/DECRC) are more widely supported across
    // terminals and multiplexers (tmux/screen) than CSI s/u.
    return '\x1b7';
  }

  private restoreCursorSeq(): string {
    return '\x1b8';
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
    // Park just above the bottom bar (status + prompt rows). With a
    // multi-line prompt this row shifts upward dynamically.
    const targetRow = Math.max(1, rows - this.bottomBarRows());
    this.output.write(`\x1b[${targetRow};1H`);
  }

  // ── Alt-screen lifecycle ────────────────────────────────────────────

  private enterAltScreen(): void {
    if (this.plain || this.altScreenActive) return;
    // \x1b[?1049h  enter alt-screen + save cursor + clear it
    // \x1b[H        cursor home (1,1)
    //
    // NOTE: we deliberately do NOT set \x1b[?1007h (Alternate Scroll Mode).
    // That mode tells the terminal to translate mouse wheel events into ↑/↓
    // arrow sequences and forward them to the app — useful for navigating
    // prompt history with the wheel, but it hijacks the terminal's native
    // scrollback during inference. The user lost the ability to scroll up
    // through streamed output. Without ?1007h the wheel behaves per terminal
    // default (scrolls the alt-screen / pager buffer); keyboard ↑/↓ still
    // navigates prompt history. The cleanup still emits ?1007l to be safe in
    // case some earlier code path enabled it.
    this.output.write('\x1b[?1049h\x1b[H');
    this.altScreenActive = true;
    this.enterStreamScrollRegion();

    // NO permanent animation tick anymore. Constant repainting at 33ms
    // made terminal scrollback unusable — every paint scrolled the
    // viewport back to "now". The wave is now event-driven:
    //   - During inference: startWaveAnimation() runs a 100ms tick.
    //   - Outside inference: zero repaints, so mouse wheel / PgUp work.
    // See startWaveAnimation / stopWaveAnimation.

    // One initial paint so the user sees the prompt right away. After
    // this, paints only fire on real events (inference start, token
    // update, stream chunk, user typing → on next state-change paint).
    this.drawFixedPrompt({ preserveCursor: false });

    process.on('exit', this.cleanupAltScreen);
    process.on('SIGINT', this.cleanupAltScreen);
    process.on('SIGTERM', this.cleanupAltScreen);
    process.on('SIGHUP', this.cleanupAltScreen);
    process.on('uncaughtException', (err) => {
      // Best-effort graceful shutdown: leave alt-screen, log the error, run
      // any registered fatal-error hook (typically index.ts onClose which
      // saves history + brain), then exit. Without the hook we used to drop
      // straight to process.exit(1) and the session state would be lost —
      // user saw it as "context cleared after a crash".
      this.exitAltScreen();
      console.error(err);
      const hook = this.onFatalError;
      const done = (): never => process.exit(1);
      if (!hook) return done();
      // Cap the hook at 1500 ms — if it hangs, we still exit.
      let timer: NodeJS.Timeout | null = setTimeout(() => {
        timer = null;
        done();
      }, 1500);
      Promise.resolve()
        .then(() => hook())
        .catch(e => console.error('[fatal-hook]', e?.message || e))
        .finally(() => {
          if (timer) { clearTimeout(timer); done(); }
        });
    });
  }

  private exitAltScreen(): void {
    if (!this.altScreenActive) return;
    if (this.statusInterval) {
      clearInterval(this.statusInterval);
      this.statusInterval = null;
    }
    this.exitStreamScrollRegion();
    // \x1b[?2004l  disable bracketed-paste mode
    // \x1b[?1007l   disable alternate scroll mode
    // \x1b[?1049l   leave alt-screen + restore prior main-screen contents
    this.output.write('\x1b[?2004l\x1b[?1007l\x1b[?1049l');
    if (this.stdinDataListener) {
      process.stdin.off('data', this.stdinDataListener);
      this.stdinDataListener = null;
    }
    if (this.pendingEscTimer) {
      clearTimeout(this.pendingEscTimer);
      this.pendingEscTimer = null;
    }
    this.pendingEsc = '';
    if (process.stdin.isTTY) {
      try { process.stdin.setRawMode(false); } catch {}
    }
    this.interactive = false;
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

  private formatTokenStats(): string {
    const input = Math.max(0, this.tokenInput);
    const output = Math.max(0, this.tokenOutput);
    if (input <= 0 && output <= 0) {
      const total = Math.max(0, this.tokenTotal);
      return total > 0 ? ' · ' + this.formatTokenCount(total) + ' tokens' : '';
    }
    const inStr = '↓ ' + this.formatTokenCount(input) + ' in';
    const outStr = '↑ ' + this.formatTokenCount(output) + ' out';
    return ' · ' + inStr + ' · ' + outStr;
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
        this.pendingReflowAfterStream = true;
        return;
      } else {
        this.rebuildViewportFromHistory();
      }
    }, 80);
  }
}
