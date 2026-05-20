import { promises as fs } from 'fs';
import { readFileSync, existsSync } from 'fs';
import path from 'path';

/**
 * Auto-recorded entry per completed task (machine-managed).
 */
export interface MemoryEntry {
  request: string;
  files: string[];        // files touched this session (kept for audit, not injected)
  insights: string[];     // insights from SessionBrain
  timestamp: number;
}

/**
 * Model-managed sections that the LLM writes into via the update_memory tool.
 * These hold semantic knowledge about the project that survives across
 * sessions: how the codebase is structured, what conventions to respect, what
 * rules the user has stated. The model builds this over time as it learns.
 */
export type ModelMemorySection = 'context' | 'conventions' | 'rules' | 'insights';

const MAX_TASKS    = 10;
const MAX_INSIGHTS = 20;
const MAX_FILES    = 15;
const SECTION_HARD_CAP_CHARS = 4000;
const PRESERVE_TAG = '<!-- phenom:preserve -->';

const SECTION_HEADERS: Record<ModelMemorySection, string> = {
  context:     '## Project context',
  conventions: '## Conventions',
  rules:       '## Custom rules',
  insights:    '## Insights'
};

interface ParsedMemory {
  taskCount: number;
  tasks:     Array<{ date: string; request: string; files: string[] }>;
  // Model-managed sections, stored as raw markdown content (each one is whatever
  // the model wrote — usually a bulleted list, sometimes prose).
  modelSections: Record<ModelMemorySection, string>;
  // Auto-recorded file-touch counts (kept on disk for audit, NOT injected).
  files:     Map<string, number>;
  preserved: string;
}

/**
 * Reads and writes .MEMORY.md in the project root.
 *
 * The file has THREE kinds of content:
 *   1. Machine-managed task log + file counts (auto-recorded after every task).
 *   2. Model-managed sections — Project context, Conventions, Custom rules,
 *      Insights — that the LLM writes into via update_memory(). These hold
 *      durable knowledge about the project; they ARE injected into the system
 *      prompt on subsequent inferences.
 *   3. An optional human-editable preserve block (everything after the
 *      <!-- phenom:preserve --> marker) — never touched by regeneration.
 *
 * Why model-managed sections matter: a 9B model loses context fast in long
 * sessions. By having the model deposit durable observations ("the agent uses
 * X pattern", "the user prefers Y") into stable sections, subsequent
 * inferences carry that knowledge forward without re-deriving it from code.
 */
export class MemoryWriter {
  private memPath: string;

  constructor(cwd = process.cwd()) {
    this.memPath = path.join(cwd, '.MEMORY.md');
  }

  /**
   * Auto-record a completed task: append to "Recent tasks" + accumulate
   * insights and file-touch counts. Called by the LearningLoop after every
   * task completion (regardless of model action).
   */
  async update(entry: MemoryEntry, taskCount: number): Promise<void> {
    const mem = this.parse();
    mem.taskCount = taskCount;

    const date = new Date(entry.timestamp).toISOString().slice(0, 16).replace('T', ' ');
    const shortReq = entry.request.replace(/\n/g, ' ').slice(0, 80);
    mem.tasks.unshift({ date, request: shortReq, files: [] });
    if (mem.tasks.length > MAX_TASKS) mem.tasks = mem.tasks.slice(0, MAX_TASKS);

    // Insights from brain — deduped, capped.
    const existing = new Set(this.parseInsightLines(mem.modelSections.insights));
    for (const ins of entry.insights) {
      if (!existing.has(ins)) {
        existing.add(ins);
      }
    }
    const merged = Array.from(existing).slice(-MAX_INSIGHTS);
    mem.modelSections.insights = merged.map(l => `- ${l}`).join('\n');

    for (const f of entry.files) {
      mem.files.set(f, (mem.files.get(f) ?? 0) + 1);
    }

    await fs.writeFile(this.memPath, this.render(mem), 'utf-8');
  }

  /**
   * Model-driven section update. Called via the update_memory tool. The
   * model passes a section name + content + mode ('append' | 'replace').
   *
   * Append mode: new content is added below the existing section content
   * (good for accumulating insights, rules, conventions as the project grows).
   *
   * Replace mode: section is overwritten entirely (good for re-architecting
   * the project context section when the model has a better understanding).
   *
   * Returns the resulting section body length so the caller (the tool) can
   * confirm the write to the model.
   */
  async updateSection(
    section: ModelMemorySection,
    content: string,
    mode: 'append' | 'replace' = 'append'
  ): Promise<number> {
    const mem = this.parse();
    const incoming = String(content || '').trim();
    if (!incoming) return mem.modelSections[section].length;

    const existing = mem.modelSections[section] || '';
    let next: string;
    if (mode === 'replace' || !existing) {
      next = incoming;
    } else {
      next = (existing.trim() + '\n' + incoming).trim();
    }
    if (next.length > SECTION_HARD_CAP_CHARS) {
      next = next.slice(-SECTION_HARD_CAP_CHARS);
    }
    mem.modelSections[section] = next;
    await fs.writeFile(this.memPath, this.render(mem), 'utf-8');
    return next.length;
  }

  /**
   * Compact excerpt for system-prompt injection. Includes the model-managed
   * sections (Project context, Conventions, Custom rules, Insights) plus the
   * Recent tasks log. The "## Modified files" file-count list is intentionally
   * EXCLUDED: it leaks past output paths as pseudo-examples and biases the
   * model toward reproducing those exact paths.
   */
  readCompact(maxChars = 1500): string {
    if (!existsSync(this.memPath)) return '';
    try {
      const raw = readFileSync(this.memPath, 'utf-8');
      const idx = raw.indexOf(PRESERVE_TAG);
      let trimmed = (idx === -1 ? raw : raw.slice(0, idx))
        .replace(/^---\s*$/m, '')
        .trim();

      // Drop "## Modified files" from the injected excerpt.
      const filesIdx = trimmed.indexOf('## Modified files');
      if (filesIdx !== -1) {
        const after = trimmed.indexOf('\n## ', filesIdx + 1);
        trimmed = (after === -1
          ? trimmed.slice(0, filesIdx)
          : trimmed.slice(0, filesIdx) + trimmed.slice(after + 1)
        ).trim();
      }

      if (trimmed.length <= maxChars) return trimmed;
      const cut = trimmed.lastIndexOf('\n', maxChars);
      return trimmed.slice(0, cut > 0 ? cut : maxChars) + '\n…';
    } catch {
      return '';
    }
  }

  // ── Private ─────────────────────────────────────────────────────────

  private emptyMem(): ParsedMemory {
    return {
      taskCount: 0,
      tasks: [],
      modelSections: {
        context: '',
        conventions: '',
        rules: '',
        insights: ''
      },
      files: new Map(),
      preserved: ''
    };
  }

  private parse(): ParsedMemory {
    const mem = this.emptyMem();
    if (!existsSync(this.memPath)) return mem;

    try {
      const raw = readFileSync(this.memPath, 'utf-8');

      const pi = raw.indexOf(PRESERVE_TAG);
      if (pi !== -1) mem.preserved = raw.slice(pi + PRESERVE_TAG.length).trim();

      const cm = raw.match(/Tasks:\s*(\d+)/);
      if (cm) mem.taskCount = parseInt(cm[1], 10);

      const tasksSec = extractSection(raw, '## Recent tasks');
      for (const line of tasksSec.split('\n')) {
        const m = line.match(/^-\s+\[([^\]]+)\]\s+(.+?)(?:\s+\(([^)]+)\))?$/);
        if (m) {
          mem.tasks.push({
            date: m[1],
            request: m[2],
            files: m[3] ? m[3].split(', ') : []
          });
        }
      }

      for (const key of Object.keys(SECTION_HEADERS) as ModelMemorySection[]) {
        const body = extractSection(raw, SECTION_HEADERS[key]);
        if (body && body !== '_none yet_') {
          mem.modelSections[key] = body;
        }
      }

      const filesSec = extractSection(raw, '## Modified files');
      for (const line of filesSec.split('\n')) {
        const m = line.match(/^-\s+(.+?)\s+\((\d+)x\)$/);
        if (m) mem.files.set(m[1], parseInt(m[2], 10));
      }

      return mem;
    } catch {
      return this.emptyMem();
    }
  }

  private parseInsightLines(body: string): string[] {
    if (!body) return [];
    return body
      .split('\n')
      .map(l => l.replace(/^-\s+/, '').trim())
      .filter(l => l.length > 0 && l !== '_none yet_');
  }

  private renderSection(key: ModelMemorySection, body: string): string {
    const trimmed = (body || '').trim();
    return [SECTION_HEADERS[key], trimmed || '_none yet_'].join('\n');
  }

  private render(mem: ParsedMemory): string {
    const today = new Date().toISOString().slice(0, 10);

    const taskLines = mem.tasks.length
      ? mem.tasks.map(t => `- [${t.date}] ${t.request}`).join('\n')
      : '_none yet_';

    const sortedFiles = Array.from(mem.files.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, MAX_FILES)
      .map(([f, n]) => `- ${f} (${n}x)`)
      .join('\n') || '_none yet_';

    const preservedSection = mem.preserved ? `\n${mem.preserved}\n` : '';

    return [
      `# Phenom Memory`,
      `> Updated: ${today} | Tasks: ${mem.taskCount}`,
      ``,
      this.renderSection('context', mem.modelSections.context),
      ``,
      this.renderSection('conventions', mem.modelSections.conventions),
      ``,
      this.renderSection('rules', mem.modelSections.rules),
      ``,
      this.renderSection('insights', mem.modelSections.insights),
      ``,
      `## Recent tasks`,
      taskLines,
      ``,
      `## Modified files`,
      sortedFiles,
      ``,
      `---`,
      PRESERVE_TAG,
      preservedSection
    ].join('\n');
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function extractSection(content: string, header: string): string {
  const start = content.indexOf(header);
  if (start === -1) return '';
  const lineStart = content.indexOf('\n', start) + 1;
  const nextHeader = content.indexOf('\n## ', lineStart);
  const sep = content.indexOf('\n---', lineStart);
  let end = content.length;
  if (nextHeader !== -1) end = Math.min(end, nextHeader);
  if (sep !== -1) end = Math.min(end, sep);
  return content.slice(lineStart, end).trim();
}
