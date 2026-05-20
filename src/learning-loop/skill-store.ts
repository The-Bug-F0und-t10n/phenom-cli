import { promises as fs } from 'fs';
import { readFileSync, existsSync } from 'fs';
import path from 'path';
import crypto from 'crypto';

export interface Skill {
  id: string;
  name: string;
  domain: string;
  description: string;
  toolSequence: string[];
  triggerKeywords: string[];
  usageCount: number;
  createdAt: number;
  lastUsed: number;
  expiresAt?: number;
}

export interface LearningStats {
  totalTasksCompleted: number;
  lastNudgeTaskCount: number;
}

export class SkillStore {
  private dir: string;
  private skillsPath: string;
  private statsPath: string;
  private skillsMdPath: string;
  private skills: Skill[] = [];
  private stats: LearningStats = { totalTasksCompleted: 0, lastNudgeTaskCount: 0 };

  constructor(baseDir = '.phenom-skills') {
    this.dir = path.join(process.cwd(), baseDir);
    this.skillsPath = path.join(this.dir, 'skills.json');
    this.statsPath = path.join(this.dir, 'stats.json');
    this.skillsMdPath = path.join(process.cwd(), '.SKILL.md');
  }

  async init(): Promise<void> {
    await fs.mkdir(this.dir, { recursive: true });
    try {
      this.skills = JSON.parse(await fs.readFile(this.skillsPath, 'utf-8'));
    } catch { this.skills = []; }
    try {
      this.stats = JSON.parse(await fs.readFile(this.statsPath, 'utf-8'));
    } catch { this.stats = { totalTasksCompleted: 0, lastNudgeTaskCount: 0 }; }
  }

  async save(): Promise<void> {
    await fs.writeFile(this.skillsPath, JSON.stringify(this.skills, null, 2));
    await fs.writeFile(this.statsPath, JSON.stringify(this.stats, null, 2));
    await fs.writeFile(this.skillsMdPath, this.renderSkillsMd(), 'utf-8');
  }

  private renderSkillsMd(): string {
    const today = new Date().toISOString().slice(0, 10);
    const active = this.skills.filter(s => !s.expiresAt || s.expiresAt > Date.now());
    const sorted = [...active].sort((a, b) => b.usageCount - a.usageCount);

    const sections = sorted.map(s => {
      const ttl = s.expiresAt
        ? `expires: ${new Date(s.expiresAt).toISOString().slice(0, 10)}`
        : 'permanent';
      const lastUsed = new Date(s.lastUsed).toISOString().slice(0, 10);
      return [
        `## ${s.name} · ${s.usageCount}x · ${ttl}`,
        `> ${s.description}`,
        `> Tools: ${s.toolSequence.join(' → ')}`,
        `> Keywords: ${s.triggerKeywords.slice(0, 6).join(', ')}`,
        `> Last used: ${lastUsed}`,
      ].join('\n');
    });

    return [
      `# Skills`,
      `> Updated: ${today} | Tasks: ${this.stats.totalTasksCompleted} | Skills: ${active.length}`,
      ``,
      sections.length ? sections.join('\n\n') : '_No skills recorded yet._',
    ].join('\n');
  }

  /**
   * Returns compact skill context read directly from .SKILL.md (sync).
   * Used by LearningLoop.getSkillsContext() as a fallback when the store
   * hasn't been initialized yet (e.g. first call before init()).
   */
  static readSkillsMdCompact(cwd = process.cwd(), maxChars = 500): string {
    const p = path.join(cwd, '.SKILL.md');
    if (!existsSync(p)) return '';
    try {
      const raw = readFileSync(p, 'utf-8');
      return raw.length <= maxChars ? raw : raw.slice(0, raw.lastIndexOf('\n', maxChars)) + '\n…';
    } catch {
      return '';
    }
  }

  getStats(): LearningStats { return { ...this.stats }; }
  incrementTaskCount(): void { this.stats.totalTasksCompleted++; }
  setLastNudgeTaskCount(n: number): void { this.stats.lastNudgeTaskCount = n; }

  addOrRefine(candidate: Omit<Skill, 'id' | 'usageCount' | 'createdAt' | 'lastUsed'>): void {
    const existing = this.findSimilar(candidate.name, candidate.domain);
    if (existing) {
      existing.usageCount++;
      existing.lastUsed = Date.now();
      existing.description = candidate.description;
      if (candidate.toolSequence.length > 0) {
        existing.toolSequence = candidate.toolSequence;
      }
      existing.triggerKeywords = dedupe([...existing.triggerKeywords, ...candidate.triggerKeywords]);
    } else {
      this.skills.push({
        ...candidate,
        id: crypto.randomBytes(4).toString('hex'),
        usageCount: 1,
        createdAt: Date.now(),
        lastUsed: Date.now()
      });
    }
  }

  private findSimilar(name: string, domain: string): Skill | undefined {
    const n = name.toLowerCase();
    return this.skills.find(s =>
      s.domain === domain &&
      (s.name.toLowerCase() === n ||
       s.name.toLowerCase().startsWith(n.split(' ')[0]) && n.split(' ')[0].length > 4)
    );
  }

  getRelevant(domain: string, keywords: string[], limit = 3): Skill[] {
    const now = Date.now();
    const active = this.skills.filter(s => !s.expiresAt || s.expiresAt > now);
    return active
      .filter(s => s.domain === domain || s.domain === 'general')
      .map(s => {
        const hits = keywords.filter(k =>
          s.triggerKeywords.some(tk => tk.includes(k) || k.includes(tk))
        ).length;
        return { skill: s, score: s.usageCount + hits * 2 };
      })
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map(e => e.skill);
  }

  /** Periodic nudge: prune skills used only once that are older than 7 days. */
  pruneStaleSkills(): number {
    const before = this.skills.length;
    const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const now = Date.now();
    this.skills = this.skills.filter(s =>
      s.usageCount > 1 || s.createdAt > cutoff
    ).filter(s => !s.expiresAt || s.expiresAt > now);
    return before - this.skills.length;
  }
}

function dedupe(arr: string[]): string[] {
  return Array.from(new Set(arr));
}
