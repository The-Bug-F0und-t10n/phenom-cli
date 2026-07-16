import { AgentState, Message, ToolCall } from './types.js';
import { config } from './config.js';

export class SessionState {
  private state: AgentState;
  private readonly maxMemory: number;

  constructor() {
    this.maxMemory = Math.max(10, Number(config.system.maxHistory || 50));
    this.state = {
      goal: '',
      workingFiles: [],
      files: {},
      memory: [],
      repoContext: new Map(),
      toolHistory: [],
      errors: [],
      userPreferences: {},
      mode: 'reasoning'
    };
  }

  setGoal(goal: string): void {
    this.state.goal = goal;
  }

  getGoal(): string {
    return this.state.goal;
  }

  setWorkingFiles(files: string[]): void {
    const unique = Array.from(new Set((files || []).map(item => String(item || '').trim()).filter(Boolean)));
    this.state.workingFiles = unique;
  }

  addWorkingFile(filePath: string): void {
    const normalized = String(filePath || '').trim();
    if (!normalized) return;
    if (!this.state.workingFiles.includes(normalized)) {
      this.state.workingFiles.push(normalized);
    }
  }

  getWorkingFiles(): string[] {
    return [...this.state.workingFiles];
  }

  markFileState(filePath: string, update: {
    exists: boolean;
    lastAction: string;
    validated: boolean;
    lastError?: string;
  }): void {
    const normalized = String(filePath || '').trim();
    if (!normalized) return;
    this.state.files[normalized] = {
      exists: update.exists,
      lastAction: update.lastAction,
      validated: update.validated,
      updatedAt: Date.now(),
      lastError: update.lastError
    };
    this.addWorkingFile(normalized);
  }

  getFileState(filePath: string): {
    exists: boolean;
    lastAction: string;
    validated: boolean;
    updatedAt: number;
    lastError?: string;
  } | null {
    const normalized = String(filePath || '').trim();
    if (!normalized) return null;
    return this.state.files[normalized] || null;
  }

  getFilesMap(): Record<string, {
    exists: boolean;
    lastAction: string;
    validated: boolean;
    updatedAt: number;
    lastError?: string;
  }> {
    return { ...this.state.files };
  }

  addMessage(message: Message): void {
    this.state.memory.push(message);
    if (this.state.memory.length > this.maxMemory) {
      this.state.memory = this.state.memory.slice(-this.maxMemory);
    }
  }

  setMemory(messages: Message[]): void {
    const safe = Array.isArray(messages) ? messages : [];
    this.state.memory = safe.slice(-this.maxMemory);
  }

  getRecentMessages(count: number = this.maxMemory): Message[] {
    return this.state.memory.slice(-count);
  }

  addRepoContext(filePath: string, content: string): void {
    this.state.repoContext.set(filePath, content);
  }

  getRepoContext(): Map<string, string> {
    return this.state.repoContext;
  }

  clearRepoContext(): void {
    this.state.repoContext.clear();
  }

  addToolCall(call: ToolCall): void {
    this.state.toolHistory.push(call);
  }

  getToolHistory(): ToolCall[] {
    return this.state.toolHistory;
  }

  addError(error: string): void {
    this.state.errors.push(error);
  }

  getErrors(): string[] {
    return this.state.errors;
  }

  setMode(mode: 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis'): void {
    this.state.mode = mode;
  }

  getMode(): 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis' {
    return this.state.mode;
  }

  getState(): AgentState {
    return this.state;
  }

  reset(): void {
    this.state = {
      goal: '',
      workingFiles: [],
      files: {},
      memory: this.state.memory.slice(-5),
      repoContext: new Map(),
      toolHistory: [],
      errors: [],
      userPreferences: this.state.userPreferences,
      mode: this.state.mode
    };
  }
}
