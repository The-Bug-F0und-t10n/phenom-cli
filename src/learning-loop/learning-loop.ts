import { Message } from '../types.js';
import { SkillStore } from './skill-store.js';
import { MemoryWriter } from './memory-writer.js';
import { extractPatterns, detectDomain } from './pattern-extractor.js';

const NUDGE_INTERVAL = 5;

export interface BrainSnapshot {
  files: string[];
  insights: string[];
}

/**
 * Learning loop orchestrator.
 *
 * After every completed task runs five phases:
 *   1. Task completion  — increment global counter.
 *   2. Pattern extraction — identify reusable tool sequences.
 *   3. Skill creation   — record novel patterns as skills.
 *   4. Skill refinement — update usage stats on matching skills.
 *   5. Periodic nudge   — every 5 tasks, prune stale skills.
 *
 * Additionally persists knowledge to two human-readable project files:
 *   .SKILL.md  — generated from SkillStore after every save.
 *   .MEMORY.md — updated with task summary, insights, and file touches.
 *
 * Both files are injected into the system prompt at inference time so the
 * model carries cross-session context without loading full session histories.
 */
export class LearningLoop {
  private store: SkillStore;
  private memWriter: MemoryWriter;
  private initialized = false;

  constructor() {
    this.store = new SkillStore();
    this.memWriter = new MemoryWriter();
  }

  async init(): Promise<void> {
    if (this.initialized) return;
    await this.store.init();
    this.initialized = true;
  }

  // ── Phase runner ──────────────────────────────────────────────────────

  async onTaskCompleted(
    request: string,
    messages: Message[],
    projectDomain: string,
    brain: BrainSnapshot = { files: [], insights: [] }
  ): Promise<void> {
    if (!this.initialized) await this.init();

    // Phase 1: task completion
    this.store.incrementTaskCount();
    const stats = this.store.getStats();

    // Phase 2 + 3 + 4: pattern extraction → skill creation/refinement
    const patterns = extractPatterns({ request, messages, projectDomain });
    for (const pattern of patterns) {
      this.store.addOrRefine(pattern);
    }

    // Phase 5: periodic nudge
    if (stats.totalTasksCompleted - stats.lastNudgeTaskCount >= NUDGE_INTERVAL) {
      this.store.pruneStaleSkills();
      this.store.setLastNudgeTaskCount(stats.totalTasksCompleted);
    }

    // Persist skills.json + regenerate .SKILL.md
    await this.store.save();

    // Update .MEMORY.md with this session's data
    await this.memWriter.update(
      {
        request,
        files: brain.files,
        insights: brain.insights,
        timestamp: Date.now()
      },
      stats.totalTasksCompleted
    );
  }

  // ── Context injection ─────────────────────────────────────────────────

  /**
   * Returns ≤3 relevant skills as a compact Markdown block for the system prompt.
   * Reads from in-memory SkillStore (no I/O). Empty string when nothing relevant.
   */
  getSkillsContext(request: string, projectDomain: string): string {
    if (!this.initialized) return '';
    const domain = detectDomain(request, projectDomain);
    const keywords = request
      .toLowerCase()
      .replace(/[^\w\s]/g, ' ')
      .split(/\s+/)
      .filter(w => w.length > 3);

    const skills = this.store.getRelevant(domain, keywords, 3);
    if (skills.length === 0) return '';

    const lines = skills.map(s =>
      `- ${s.name}: ${s.toolSequence.join(' → ')} (${s.usageCount}x)`
    );
    return `## Skills\n${lines.join('\n')}`;
  }

  /**
   * Returns a compact excerpt of .MEMORY.md for injection into the system prompt.
   * Uses readFileSync — safe to call from a sync context.
   */
  getMemoryContext(): string {
    return this.memWriter.readCompact(600);
  }
}
