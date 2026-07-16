/**
 * Professional TUI - Layout exato conforme especificação
 */

import blessed from 'blessed';
import { eventBus, EventType } from './event-bus.js';
import { stateStore } from './state-store.js';
import { markdownRenderer } from './markdown-renderer.js';
import type { Agent } from '../agent.js';
import { config } from '../config.js';

interface ToolExecution {
  id: string;
  name: string;
  args: any;
  status: 'running' | 'done' | 'error';
  startTime: number;
  endTime?: number;
  results?: string[];
}

export class ProfessionalTUI {
  private screen: blessed.Widgets.Screen;
  private reasoningBox: blessed.Widgets.BoxElement;
  private chatArea: blessed.Widgets.BoxElement;
  private progressLine: blessed.Widgets.BoxElement;
  private inputBar: blessed.Widgets.BoxElement;
  private promptIcon: blessed.Widgets.BoxElement;
  private inputBox: blessed.Widgets.TextboxElement;
  private separator: blessed.Widgets.LineElement;

  private toolExecutions: Map<string, ToolExecution> = new Map();
  private currentAction: string = '';
  private actionStartTime: number = 0;
  private streamBuffer: string = '';
  private renderTimer: NodeJS.Timeout | null = null;
  private streamTimer: NodeJS.Timeout | null = null;
  private lastChatLines: string[] = [];
  private lastReasoningContent: string = '';
  private lastProgressContent: string = '';
  private reasoningHeight: number = config.tui.reasoningHeight;
  private tokenDirection: 'up' | 'down' = 'down';
  private startTokens: number = 0;
  private inferenceStartTime: number = 0;
  private inferenceStartTokens: number = 0;
  private agent: Agent;
  private isProcessing: boolean = false;
  private inputHeight: number = 1;
  private maxInputHeight: number = 10;

  constructor(agent: Agent) {
    this.agent = agent;
    this.screen = blessed.screen({
      smartCSR: true,
      title: 'Phenom CLI',
      fullUnicode: true,
      autoPadding: false,
      sendFocus: true,
    });

    this.reasoningBox = this.createReasoningBox();
    this.chatArea = this.createChatArea();
    this.progressLine = this.createProgressLine();
    this.separator = this.createSeparator();
    this.inputBar = this.createInputBar();
    this.promptIcon = this.createPromptIcon();
    this.inputBox = this.createInputBox();

    this.screen.append(this.reasoningBox);
    this.screen.append(this.chatArea);
    this.screen.append(this.progressLine);
    this.screen.append(this.separator);
    this.screen.append(this.inputBar);
    this.screen.append(this.promptIcon);
    this.screen.append(this.inputBox);

    this.applyLayout();

    this.setupKeyBindings();
    this.setupEventListeners();
    
    stateStore.subscribe(() => this.requestRender());
    
    // Start live update interval for timer/tokens
    this.startLiveUpdates();

    this.screen.on('resize', () => this.applyLayout());
  }

  private startLiveUpdates(): void {
    setInterval(() => {
      if (this.currentAction) {
        this.requestRender();
      }
    }, 1000); // Update every second
  }

  private createReasoningBox(): blessed.Widgets.BoxElement {
    return blessed.box({
      top: 0,
      left: 0,
      width: '100%',
      height: this.reasoningHeight,
      tags: true,
      content: '',
      style: {
        fg: 'yellow',
        bg: 'black',
      },
    });
  }

  private createChatArea(): blessed.Widgets.BoxElement {
    return blessed.box({
      top: this.reasoningHeight,
      left: 0,
      width: '100%',
      height: '100%-5',
      scrollable: true,
      alwaysScroll: true,
      scrollbar: {
        ch: '│',
        style: { fg: 'cyan' },
      },
      keys: true,
      vi: true,
      mouse: true,
      tags: true,
      content: '',
      style: {
        fg: 'white',
        bg: 'black',
      },
    });
  }

  private createProgressLine(): blessed.Widgets.BoxElement {
    return blessed.box({
      bottom: 4,
      left: 0,
      width: '100%',
      height: 1,
      tags: true,
      content: '',
      style: {
        fg: 'yellow',
        bg: 'black',
      },
    });
  }

  private createSeparator(): blessed.Widgets.LineElement {
    return blessed.line({
      bottom: 3,
      left: 0,
      width: '100%',
      orientation: 'horizontal',
      type: 'line',
      style: {
        fg: 'cyan',
      },
    });
  }

  private createInputBar(): blessed.Widgets.BoxElement {
    return blessed.box({
      bottom: 0,
      left: 0,
      width: '100%',
      height: 1,
      style: {
        fg: 'white',
        bg: 'gray',
      },
    });
  }

  private createPromptIcon(): blessed.Widgets.BoxElement {
    return blessed.box({
      bottom: 0,
      left: 1,
      width: 2,
      height: 1,
      content: '>',
      tags: true,
      style: {
        fg: 'cyan',
        bg: 'gray',
      },
    });
  }

  private applyLayout(): void {
    const totalHeight = Number(this.screen.height) || 24;
    const inputHeight = 5;
    const reasoningHeight = Math.min(this.reasoningHeight, Math.max(3, Math.floor(totalHeight / 4)));
    const chatHeight = Math.max(3, totalHeight - inputHeight - reasoningHeight);

    this.reasoningBox.top = 0;
    this.reasoningBox.height = reasoningHeight;

    this.chatArea.top = reasoningHeight;
    this.chatArea.height = chatHeight;
  }

  private createInputBox(): blessed.Widgets.TextboxElement {
    const input = blessed.textbox({
      bottom: 0,
      left: 3,
      width: '100%-4',
      height: 1,
      inputOnFocus: false,
      keys: true,
      mouse: false,
      multiline: true,
      style: {
        fg: 'white',
        bg: 'gray',
      },
    });

    // Monitor input changes to adjust height
    input.on('keypress', () => {
      this.adjustInputHeight();
    });

    return input;
  }

  private adjustInputHeight(): void {
    const content = this.inputBox.getValue() || '';
    const lines = content.split('\n');
    const newHeight = Math.min(Math.max(1, lines.length), this.maxInputHeight);

    if (newHeight !== this.inputHeight) {
      this.inputHeight = newHeight;
      this.inputBox.height = newHeight;
      this.inputBar.height = newHeight;
      this.promptIcon.height = newHeight;

      // Adjust other components
      this.separator.bottom = newHeight + 3;
      this.progressLine.bottom = newHeight + 4;

      this.screen.render();
    }
  }

  private setupKeyBindings(): void {
    this.screen.key(['C-c'], () => process.exit(0));
    this.screen.key(['escape'], () => {
      if (this.currentAction) {
        eventBus.emit(EventType.INFERENCE_CANCEL, { reason: 'Inferencia cancelada pelo usuario' });
        this.currentAction = '';
        this.requestRender();
      }
    });

    // Textbox submit event
    this.inputBox.on('submit', (value: string) => {
      const text = value.trim();
      if (text) {
        eventBus.emit(EventType.USER_MESSAGE, { content: text });
        this.inputBox.clearValue();

        // Reset input height to 1 line
        this.inputHeight = 1;
        this.inputBox.height = 1;
        this.inputBar.height = 1;
        this.promptIcon.height = 1;
        this.separator.bottom = 3;
        this.progressLine.bottom = 4;

        this.inputBox.focus();
        this.screen.render();
      }
    });

    this.inputBox.focus();
  }

  private setupEventListeners(): void {
    eventBus.on(EventType.USER_MESSAGE, async (event) => {
      if (this.isProcessing) return;
      
      const userInput = event.payload.content;
      this.isProcessing = true;
      
      stateStore.addMessage({
        role: 'user',
        content: userInput,
      });
      
      // Start tracking inference
      this.inferenceStartTime = Date.now();
      this.inferenceStartTokens = stateStore.getState().tokenUsage.total;
      this.startTokens = this.inferenceStartTokens;
      this.tokenDirection = 'down';
      
      try {
        await this.agent.processInput(userInput);
      } catch (error: any) {
        stateStore.addMessage({
          role: 'assistant',
          content: `Erro: ${error.message}`,
        });
      } finally {
        this.isProcessing = false;
      }
    });

    eventBus.on(EventType.AGENT_MESSAGE, (event) => {
      // Match llama.cpp webui pattern (chat.svelte.ts onComplete):
      //   const content = streamedContent || finalContent || '';
      // The streamed bytes are canonical — the payload at end-of-turn is the
      // same answer post-processed. Writing both produces a visible duplicate.
      const buffered = this.streamBuffer;
      const payload = event.payload.content || '';
      this.streamBuffer = '';

      const content = buffered.trim() ? buffered : payload;
      if (!content) return;

      stateStore.addMessage({
        role: 'assistant',
        content,
      });
    });

    // Stream chunks
    eventBus.on(EventType.MESSAGE_CHUNK, (event) => {
      this.streamBuffer += event.payload.chunk;
      this.tokenDirection = 'up';
      this.requestRender('stream');
    });

    eventBus.on(EventType.TOOL_START, (event) => {
      const { id, name, args } = event.payload;
      this.toolExecutions.set(id, {
        id,
        name,
        args,
        status: 'running',
        startTime: Date.now(),
      });
      this.requestRender();
    });

    eventBus.on(EventType.TOOL_RESULT, (event) => {
      const { id, result, name, args } = event.payload;
      let tool = this.toolExecutions.get(id);
      if (!tool) {
        tool = {
          id,
          name: name || 'tool',
          args: args || {},
          status: 'done',
          startTime: Date.now()
        };
        this.toolExecutions.set(id, tool);
      }
      tool.status = 'done';
      tool.endTime = Date.now();
      tool.results = result.output ? [result.output] : [];
      this.requestRender();
    });

    eventBus.on(EventType.TOOL_ERROR, (event) => {
      const { id, error, output, name, args, toolName } = event.payload;
      let tool = this.toolExecutions.get(id);
      if (!tool) {
        tool = {
          id,
          name: name || toolName || 'tool',
          args: args || {},
          status: 'error',
          startTime: Date.now()
        };
        this.toolExecutions.set(id, tool);
      }
      tool.status = 'error';
      tool.endTime = Date.now();
      const err = error ? [String(error)] : [];
      const out = output ? [String(output)] : [];
      tool.results = [...err, ...out];
      this.requestRender();
    });

    eventBus.on(EventType.PROGRESS_UPDATE, (event) => {
      this.currentAction = event.payload.message;
      this.actionStartTime = Date.now();
      this.requestRender();
    });

    // Token update
    eventBus.on(EventType.TOKEN_UPDATE, (event) => {
      const input = Number(event.payload?.input ?? 0);
      const output = Number(event.payload?.output ?? 0);
      const total = Number(event.payload?.total ?? NaN);

      if (Number.isFinite(total)) {
        stateStore.setTokens({
          input: Number.isFinite(input) ? Math.max(0, input) : 0,
          output: Number.isFinite(output) ? Math.max(0, output) : 0,
          total: Math.max(0, total),
        });
        return;
      }

      if (Number.isFinite(input) || Number.isFinite(output)) {
        stateStore.updateTokens(
          Number.isFinite(input) ? input : 0,
          Number.isFinite(output) ? output : 0
        );
      }
    });

    eventBus.on(EventType.THINK_START, (event) => {
      if (event?.payload?.message) {
        this.currentAction = event.payload.message;
      }
      this.actionStartTime = Date.now();
      this.startTokens = stateStore.getState().tokenUsage.total;
      this.tokenDirection = 'down';
      this.requestRender();
    });

    eventBus.on(EventType.CLEAR_STREAMING, () => {
      this.streamBuffer = '';
      this.requestRender();
    });

    eventBus.on(EventType.INFERENCE_CANCEL, (event) => {
      this.currentAction = '';
      this.streamBuffer = '';
      const reason = String(event?.payload?.reason || 'Inferencia cancelada').trim();
      stateStore.addMessage({
        role: 'assistant',
        content: `{red-fg}✗ ${reason}{/red-fg}`,
      });
      this.requestRender();
    });

    eventBus.on(EventType.DELIBERATION_UPDATE, (event) => {
      if (event.payload?.globalReasoning !== undefined) {
        stateStore.setGlobalReasoning(event.payload.globalReasoning);
        this.requestRender();
      }
    });

    eventBus.on(EventType.THINK_END, () => {
      this.currentAction = '';

      // Flush stream buffer to messages before adding stats
      if (this.streamBuffer.trim()) {
        stateStore.addMessage({
          role: 'assistant',
          content: this.streamBuffer,
        });
        this.streamBuffer = '';
      }

      // Add inference stats to last assistant message
      if (this.inferenceStartTime > 0) {
        const duration = ((Date.now() - this.inferenceStartTime) / 1000).toFixed(1);
        const state = stateStore.getState();
        const tokensUsed = Math.max(0, state.tokenUsage.total - this.inferenceStartTokens);

        const messages = [...state.messages];

        // Find last assistant message and append stats
        for (let i = messages.length - 1; i >= 0; i--) {
          if (messages[i].role === 'assistant' && !messages[i].content.includes('done (')) {
            messages[i] = {
              ...messages[i],
              content: messages[i].content + `\n\n{white-fg}done (${tokensUsed.toLocaleString()} tokens · ${duration}s){/white-fg}`,
            };

            // Update state with modified messages
            stateStore.update(() => ({ messages }));
            break;
          }
        }

        this.inferenceStartTime = 0;
        this.inferenceStartTokens = 0;
      }

      this.requestRender();
    });
  }

  private formatToolBlock(tool: ToolExecution): string[] {
    const lines: string[] = [];
    
    // Tool header
    lines.push('');
    if (tool.status === 'running') {
      lines.push(`{yellow-fg}[tool: ${tool.name}]{/yellow-fg}`);
    } else if (tool.status === 'done') {
      lines.push(`{green-fg}[tool: ${tool.name}]{/green-fg}`);
    } else {
      lines.push(`{red-fg}[tool: ${tool.name}]{/red-fg}`);
    }

    // Args
    if (tool.name === 'grep') {
      if (tool.args.query) lines.push(`query: "${tool.args.query}"`);
      if (tool.args.path) lines.push(`path: ${tool.args.path}`);
    } else if (tool.name === 'write_file' || tool.name === 'read_file') {
      if (tool.args.path) lines.push(`path: ${tool.args.path}`);
    }

    // Status
    if (tool.status === 'running') {
      lines.push(`{yellow-fg}status: running…{/yellow-fg}`);
    } else if (tool.status === 'done') {
      const duration = tool.endTime ? ((tool.endTime - tool.startTime) / 1000).toFixed(1) : '0';
      const scanned = tool.results && tool.results.length > 0 ? ` · scanned ${tool.results.length} files` : '';
      lines.push(`{green-fg}status: done (${duration}s${scanned}){/green-fg}`);
    } else {
      lines.push(`{red-fg}status: error{/red-fg}`);
    }

    // Results / Error details
    if (tool.status === 'done' && tool.name === 'web_search') {
      lines.push('');
      lines.push(`{cyan-fg}results:{/cyan-fg}`);
      lines.push('  (processed by model)');
    } else if ((tool.status === 'done' || tool.status === 'error') && tool.results && tool.results.length > 0) {
      const hideResultsForAssistantRendered = new Set(['list_dir']);
      if (!hideResultsForAssistantRendered.has(tool.name)) {
        lines.push('');
        lines.push(tool.status === 'error'
          ? `{red-fg}error:{/red-fg}`
          : `{cyan-fg}results:{/cyan-fg}`);
        tool.results.slice(0, 5).forEach(r => {
          lines.push(`  ${r}`);
        });
      }
    }

    lines.push('');
    return lines;
  }

  private convertChalkToBlessedTags(text: string): string {
    // Simple conversion - strip ANSI codes and use plain text
    // Blessed will handle its own tags
    return text.replace(/\u001b\[[0-9;]*m/g, '');
  }

  private requestRender(kind: 'normal' | 'stream' = 'normal'): void {
    const delay = kind === 'stream' ? config.tui.streamDebounceMs : config.tui.renderDebounceMs;
    if (kind === 'stream') {
      if (this.streamTimer) return;
      this.streamTimer = setTimeout(() => {
        this.streamTimer = null;
        this.render();
      }, delay);
      return;
    }

    if (this.renderTimer) return;
    this.renderTimer = setTimeout(() => {
      this.renderTimer = null;
      this.render();
    }, delay);
  }

  private render(): void {
    const state = stateStore.getState();

    this.renderReasoning(state.globalReasoning);

    const lines = this.buildChatLines(state);
    this.applyChatDiff(lines);

    this.renderProgressLine(state);
    this.screen.render();
  }

  private renderReasoning(reasoning: string): void {
    const header = '{yellow-fg}[Reasoning Global]{/yellow-fg}';
    const content = reasoning ? reasoning.trim() : 'Aguardando contexto deliberativo...';
    const width = Math.max(20, (Number(this.screen.width) || 80) - 2);
    const maxLines = Number(this.reasoningBox.height) || this.reasoningHeight;
    const lines = [header, ...this.wrapText(content, width, maxLines)];
    const newContent = lines.slice(0, maxLines).join('\n');

    if (newContent !== this.lastReasoningContent) {
      this.reasoningBox.setContent(newContent);
      this.lastReasoningContent = newContent;
    }
  }

  private renderProgressLine(state: ReturnType<typeof stateStore.getState>): void {
    let content = '';
    if (this.currentAction) {
      const elapsed = ((Date.now() - this.actionStartTime) / 1000).toFixed(0);
      const tokens = Math.max(0, state.tokenUsage.total - this.startTokens);
      const arrow = this.tokenDirection === 'down' ? '↓' : '↑';
      const tokenStr = tokens > 0 ? ` · ${arrow} ${tokens.toLocaleString()} tokens` : '';
      content = `{yellow-fg}* ${this.currentAction}… (${elapsed}s${tokenStr} · esc to interrupt){/yellow-fg}`;
    }

    if (content !== this.lastProgressContent) {
      this.progressLine.setContent(content);
      this.lastProgressContent = content;
    }
  }

  private buildChatLines(state: ReturnType<typeof stateStore.getState>): string[] {
    const lines: string[] = [];

    // Render tool executions
    for (const tool of this.toolExecutions.values()) {
      lines.push(...this.formatToolBlock(tool));
    }

    for (const msg of state.messages) {
      if (msg.role === 'user') {
        lines.push('');
        lines.push(`{gray-bg}{cyan-fg} > {/cyan-fg}{/gray-bg} {white-fg}${msg.content}{/white-fg}`);
      } else if (msg.role === 'assistant') {
        lines.push('');
        if (msg.content.includes('[reasoning]')) {
          const reasoningContent = msg.content.replace('[reasoning]', '').trim();
          lines.push('{yellow-fg}[reasoning]{/yellow-fg}');
          reasoningContent.split('\n').forEach(line => {
            lines.push(`{gray-fg}${line}{/gray-fg}`);
          });
        } else {
          const rendered = this.looksLikeDiff(msg.content)
            ? markdownRenderer.renderDiff(msg.content)
            : markdownRenderer.render(msg.content);
          const blessedContent = this.convertChalkToBlessedTags(rendered);
          blessedContent.split('\n').forEach(line => lines.push(line));
        }
      }
    }

    if (this.streamBuffer) {
      lines.push('');
      lines.push(`{green-fg}[assistant]{/green-fg}`);
      const rendered = markdownRenderer.render(this.streamBuffer);
      const blessedContent = this.convertChalkToBlessedTags(rendered);
      blessedContent.split('\n').forEach(line => lines.push(line));
    }

    return lines;
  }

  private applyChatDiff(lines: string[]): void {
    const prev = this.lastChatLines;
    const diffIndex = this.findFirstDiff(prev, lines);

    if (diffIndex === -1) {
      return;
    }

    if (prev.length === 0) {
      this.chatArea.setContent(lines.join('\n'));
      this.lastChatLines = lines;
      this.chatArea.setScrollPerc(100);
      return;
    }

    if (lines.length >= prev.length && diffIndex === prev.length) {
      const toAppend = lines.slice(prev.length);
      toAppend.forEach(line => this.chatArea.pushLine(line));
      this.lastChatLines = lines;
      this.chatArea.setScrollPerc(100);
      return;
    }

    if (lines.length === prev.length && diffIndex >= prev.length - 6) {
      for (let i = diffIndex; i < lines.length; i++) {
        this.chatArea.setLine(i, lines[i]);
      }
      this.lastChatLines = lines;
      this.chatArea.setScrollPerc(100);
      return;
    }

    this.chatArea.setContent(lines.join('\n'));
    this.lastChatLines = lines;
    this.chatArea.setScrollPerc(100);
  }

  private findFirstDiff(prev: string[], next: string[]): number {
    const minLen = Math.min(prev.length, next.length);
    for (let i = 0; i < minLen; i++) {
      if (prev[i] !== next[i]) return i;
    }
    if (prev.length === next.length) return -1;
    return minLen;
  }

  private looksLikeDiff(text: string): boolean {
    if (!text) return false;
    if (/^diff --git/m.test(text)) return true;
    if (text.includes('---') && text.includes('+++')) return true;
    if (/^@@/m.test(text)) return true;
    return false;
  }

  private wrapText(text: string, width: number, maxLines: number): string[] {
    if (width <= 0) return [text];
    const words = text.split(/\s+/);
    const lines: string[] = [];
    let current = '';

    for (const word of words) {
      const next = current ? `${current} ${word}` : word;
      if (next.length > width) {
        lines.push(current);
        current = word;
        if (lines.length >= maxLines - 1) break;
      } else {
        current = next;
      }
    }
    if (current && lines.length < maxLines) lines.push(current);
    return lines;
  }

  start(): void {
    this.inputBox.focus();
    this.screen.render();
  }
}
