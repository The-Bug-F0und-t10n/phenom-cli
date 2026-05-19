import { promises as fs } from 'fs';
import path from 'path';
import crypto from 'crypto';
import { Message } from './types.js';

export type PlanStatus = 'pending' | 'in_progress' | 'completed' | 'failed';

export interface PlanStep {
  id: string;
  title: string;
  description?: string;
  status: PlanStatus;
  order: number;
}

export interface SessionNote {
  id: string;
  type: 'user_request' | 'insight' | 'observation' | 'correction' | 'progress' | 'error';
  content: string;
  timestamp: number;
  metadata?: Record<string, any>;
}

export interface SessionData {
  sessionId: string;
  createdAt: number;
  updatedAt: number;
  userRequest: string;
  notes: SessionNote[];
  createdFiles: string[];
  failedOperations: string[];
  insights: string[];
  pendingTasks: string[];
  planSteps: PlanStep[];
  messages: Message[];
}

export class SessionBrain {
  private sessionPath: string;
  private data: SessionData;
  private dirty: boolean = false;

  constructor(sessionDir: string, sessionId: string) {
    this.sessionPath = path.join(sessionDir, `${sessionId}.json`);
    this.data = this.createEmpty();
    this.data.sessionId = sessionId;
  }

  private createEmpty(): SessionData {
    return {
      sessionId: '',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      userRequest: '',
      notes: [],
      createdFiles: [],
      failedOperations: [],
      insights: [],
      pendingTasks: [],
      planSteps: [],
      messages: []
    };
  }

  async load(): Promise<boolean> {
    try {
      const content = await fs.readFile(this.sessionPath, 'utf-8');
      this.data = JSON.parse(content);
      return true;
    } catch {
      return false;
    }
  }

  async save(): Promise<void> {
    if (!this.dirty) return;
    this.data.updatedAt = Date.now();
    await fs.writeFile(this.sessionPath, JSON.stringify(this.data, null, 2), 'utf-8');
    this.dirty = false;
  }

  setUserRequest(request: string): void {
    this.data.userRequest = request;
    this.dirty = true;
  }

  /** Clear per-request ephemeral context so it doesn't pollute new requests */
  clearRequestContext(): void {
    this.data.notes = [];
    this.data.insights = [];
    this.data.createdFiles = [];
    this.data.failedOperations = [];
    this.data.pendingTasks = [];
    this.data.planSteps = [];
    this.dirty = true;
  }

  /**
   * Prepare brain for a new user request.
   * Clears stale per-request noise but preserves session continuity:
   * - Active plan steps (pending/in_progress) are kept so multi-step work continues
   * - Created files are kept (session-level context, avoids re-creating)
   * - Notes, insights, failedOps and pendingTasks are cleared (they accumulate noise)
   */
  refreshForNewRequest(): void {
    this.data.notes = [];
    this.data.insights = [];
    this.data.failedOperations = [];
    this.data.pendingTasks = [];
    // Keep active plan steps so an ongoing multi-step task can continue
    const hasActiveWork = this.data.planSteps.some(
      s => s.status === 'pending' || s.status === 'in_progress'
    );
    if (!hasActiveWork) {
      this.data.planSteps = [];
    }
    // createdFiles intentionally kept — session-level context
    this.dirty = true;
  }

  addNote(type: SessionNote['type'], content: string, metadata?: Record<string, any>): string {
    const note: SessionNote = {
      id: crypto.randomBytes(4).toString('hex'),
      type,
      content,
      timestamp: Date.now(),
      metadata
    };
    this.data.notes.push(note);
    this.dirty = true;
    return note.id;
  }

  addInsight(insight: string): void {
    if (!this.data.insights.includes(insight)) {
      this.data.insights.push(insight);
      this.dirty = true;
    }
  }

  addCreatedFile(filePath: string): void {
    const normalized = path.normalize(filePath);
    if (!this.data.createdFiles.includes(normalized)) {
      this.data.createdFiles.push(normalized);
      this.dirty = true;
    }
  }

  addFailedOperation(operation: string): void {
    this.data.failedOperations.push(operation);
    this.dirty = true;
  }

  addPendingTask(task: string): void {
    if (!this.data.pendingTasks.includes(task)) {
      this.data.pendingTasks.push(task);
      this.dirty = true;
    }
  }

  removePendingTask(task: string): void {
    this.data.pendingTasks = this.data.pendingTasks.filter(t => t !== task);
    this.dirty = true;
  }

  // ── Plan Steps ─────────────────────────────────────────────────────

  setPlanSteps(steps: Omit<PlanStep, 'id'>[]): void {
    this.data.planSteps = steps.map((s, i) => ({
      ...s,
      id: crypto.randomBytes(4).toString('hex'),
      order: s.order ?? i
    }));
    this.dirty = true;
  }

  updateStepStatus(stepId: string, status: PlanStatus): void {
    const step = this.data.planSteps.find(s => s.id === stepId);
    if (step) {
      step.status = status;
      this.dirty = true;
    }
  }

  completeStep(stepId: string): void {
    this.updateStepStatus(stepId, 'completed');
  }

  failStep(stepId: string): void {
    this.updateStepStatus(stepId, 'failed');
  }

  setCurrentStep(stepId: string): void {
    this.data.planSteps = this.data.planSteps.map(s => ({
      ...s,
      status: s.id === stepId ? 'in_progress' : s.status === 'in_progress' ? 'pending' : s.status
    }));
    this.dirty = true;
  }

  getPlanSteps(): PlanStep[] {
    return this.data.planSteps;
  }

  getPlanSummary(): string {
    return this.data.planSteps
      .sort((a, b) => a.order - b.order)
      .map(s => {
        const icon = s.status === 'completed' ? '[✓]' : s.status === 'in_progress' ? '[→]' : s.status === 'failed' ? '[✗]' : '[ ]';
        return `${icon} ${s.title}`;
      })
      .join('\n');
  }

  getContext(): string {
    const parts: string[] = [];

    if (this.data.userRequest) {
      parts.push(`CURRENT TASK: ${this.data.userRequest}`);
    }

    if (this.data.planSteps.length > 0) {
      parts.push('## PLAN\n' + this.getPlanSummary());
    }

    if (this.data.createdFiles.length > 0) {
      parts.push(`FILES_CREATED: ${this.data.createdFiles.join(' | ')}`);
    }

    if (this.data.pendingTasks.length > 0) {
      parts.push(`REMAINING: ${this.data.pendingTasks.join(' | ')}`);
    }

    if (this.data.insights.length > 0) {
      parts.push(`INSIGHTS: ${this.data.insights.join(' | ')}`);
    }

    if (this.data.failedOperations.length > 0) {
      parts.push(`FAILED: ${this.data.failedOperations.join(' | ')}`);
    }

    return parts.join('\n');
  }

  saveMessages(messages: Message[]): void {
    this.data.messages = messages;
    this.dirty = true;
  }

  loadMessages(): Message[] {
    return this.data.messages || [];
  }

  getRecentNotes(count: number = 10): SessionNote[] {
    return this.data.notes.slice(-count);
  }

  getNotes(): SessionNote[] {
    return this.data.notes;
  }

  getUserRequest(): string {
    return this.data.userRequest;
  }

  getCreatedFiles(): string[] {
    return this.data.createdFiles;
  }

  getInsights(): string[] {
    return this.data.insights;
  }

  getPendingTasks(): string[] {
    return this.data.pendingTasks;
  }

  getData(): SessionData {
    return this.data;
  }

  isDirty(): boolean {
    return this.dirty;
  }
}

export class SessionManager {
  private sessionsDir: string;

  constructor(baseDir: string = '.phenom-sessions') {
    this.sessionsDir = path.join(process.cwd(), baseDir);
  }

  async init(): Promise<void> {
    await fs.mkdir(this.sessionsDir, { recursive: true });
  }

  async createSession(request?: string): Promise<SessionBrain> {
    const id = crypto.randomBytes(8).toString('hex');
    const brain = new SessionBrain(this.sessionsDir, id);
    
    if (request) {
      brain.setUserRequest(request);
      brain.addNote('user_request', request);
    }
    
    await brain.save();
    return brain;
  }

  async loadSession(sessionId: string): Promise<SessionBrain | null> {
    const brain = new SessionBrain(this.sessionsDir, sessionId);
    const loaded = await brain.load();
    return loaded ? brain : null;
  }

  async listSessions(): Promise<Array<{ id: string; request: string; updatedAt: number }>> {
    try {
      const files = await fs.readdir(this.sessionsDir);
      const sessions: Array<{ id: string; request: string; updatedAt: number }> = [];

      for (const file of files) {
        if (file.endsWith('.json')) {
          try {
            const content = await fs.readFile(path.join(this.sessionsDir, file), 'utf-8');
            const data = JSON.parse(content);
            sessions.push({
              id: file.replace('.json', ''),
              request: data.userRequest || '',
              updatedAt: data.updatedAt || 0
            });
          } catch {}
        }
      }

      return sessions.sort((a, b) => b.updatedAt - a.updatedAt);
    } catch {
      return [];
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    const filePath = path.join(this.sessionsDir, `${sessionId}.json`);
    try {
      await fs.unlink(filePath);
    } catch {}
  }
}
