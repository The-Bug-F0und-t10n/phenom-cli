import { promises as fs } from 'fs';
import { readFileSync, existsSync } from 'fs';
import path from 'path';

export interface MemoryEntry {
  request: string;
  files: string[];        // files touched this session
  insights: string[];     // insights from SessionBrain
  timestamp: number;
}

const MAX_TASKS    = 10;
const MAX_INSIGHTS = 15;
const MAX_FILES    = 15;
const PRESERVE_TAG = '<!-- phenom:preserve -->';

interface ParsedMemory {
  taskCount: number;
  tasks:    Array<{ date: string; request: string; files: string[] }>;
  insights: string[];
  files:    Map<string, number>;
  preserved: string;
}

/**
 * Reads and writes .MEMORY.md in the project root.
 *
 * The file has machine-managed sections (tasks, insights, files) and an
 * optional human-editable block after <!-- phenom:preserve --> that is
 * preserved verbatim across every regeneration.
 */
export class MemoryWriter {
  private memPath: string;

  constructor(cwd = process.cwd()) {
    this.memPath = path.join(cwd, '.MEMORY.md');
  }

  async update(entry: MemoryEntry, taskCount: number): Promise<void> {
    const mem = this.parse();
    mem.taskCount = taskCount;

    // Prepend new task entry
    const date = new Date(entry.timestamp).toISOString().slice(0, 16).replace('T', ' ');
    const shortReq = entry.request.replace(/\n/g, ' ').slice(0, 80);
    const topFiles = entry.files.slice(0, 3);
    mem.tasks.unshift({ date, request: shortReq, files: topFiles });
    if (mem.tasks.length > MAX_TASKS) mem.tasks = mem.tasks.slice(0, MAX_TASKS);

    // Merge insights (deduplicated)
    for (const ins of entry.insights) {
      if (!mem.insights.includes(ins)) mem.insights.push(ins);
    }
    if (mem.insights.length > MAX_INSIGHTS) mem.insights = mem.insights.slice(-MAX_INSIGHTS);

    // Accumulate file touch counts
    for (const f of entry.files) {
      mem.files.set(f, (mem.files.get(f) ?? 0) + 1);
    }

    await fs.writeFile(this.memPath, this.render(mem), 'utf-8');
  }

  /**
   * Returns a compact excerpt of .MEMORY.md suitable for injection into
   * the system prompt (max ~600 chars). Empty string if the file doesn't exist.
   *
   * The "## Modified files" section is intentionally EXCLUDED from the
   * injection. The file count list (e.g. "hello-world-matrix.html (1x)") was
   * surfacing past-output paths as if they were canonical project artifacts,
   * priming the model to reproduce sibling/variant naming. The section still
   * exists on disk for human audit — only the injection is filtered.
   */
  readCompact(maxChars = 600): string {
    if (!existsSync(this.memPath)) return '';
    try {
      const raw = readFileSync(this.memPath, 'utf-8');
      // Strip preserve block and horizontal rule — keep only machine sections
      const idx = raw.indexOf(PRESERVE_TAG);
      let trimmed = (idx === -1 ? raw : raw.slice(0, idx))
        .replace(/^---\s*$/m, '')
        .trim();

      // Drop the "## Modified files" section entirely (and anything after it,
      // up to the next top-level section or end of the machine block).
      const filesIdx = trimmed.indexOf('## Modified files');
      if (filesIdx !== -1) {
        const after = trimmed.indexOf('\n## ', filesIdx + 1);
        trimmed = (after === -1
          ? trimmed.slice(0, filesIdx)
          : trimmed.slice(0, filesIdx) + trimmed.slice(after + 1)
        ).trim();
      }

      if (trimmed.length <= maxChars) return trimmed;
      // Truncate at last complete line within limit
      const cut = trimmed.lastIndexOf('\n', maxChars);
      return trimmed.slice(0, cut > 0 ? cut : maxChars) + '\n…';
    } catch {
      return '';
    }
  }

  // ── Private ─────────────────────────────────────────────────────────

  private parse(): ParsedMemory {
    const empty: ParsedMemory = {
      taskCount: 0,
      tasks: [],
      insights: [],
      files: new Map(),
      preserved: ''
    };

    if (!existsSync(this.memPath)) return empty;

    try {
      const raw = readFileSync(this.memPath, 'utf-8');
      const mem: ParsedMemory = { ...empty, files: new Map() };

      // Preserve block
      const pi = raw.indexOf(PRESERVE_TAG);
      if (pi !== -1) mem.preserved = raw.slice(pi + PRESERVE_TAG.length).trim();

      // Task count from header
      const cm = raw.match(/Tasks:\s*(\d+)/);
      if (cm) mem.taskCount = parseInt(cm[1], 10);

      // Tasks section
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

      // Insights section
      const insSec = extractSection(raw, '## Insights');
      for (const line of insSec.split('\n')) {
        const m = line.match(/^-\s+(.+)$/);
        if (m) mem.insights.push(m[1]);
      }

      // Files section
      const filesSec = extractSection(raw, '## Modified files');
      for (const line of filesSec.split('\n')) {
        const m = line.match(/^-\s+(.+?)\s+\((\d+)x\)$/);
        if (m) mem.files.set(m[1], parseInt(m[2], 10));
      }

      return mem;
    } catch {
      return empty;
    }
  }

  private render(mem: ParsedMemory): string {
    const today = new Date().toISOString().slice(0, 10);

    // The file list per task was removed from the rendered line because it was
    // leaking output patterns from past failures back into the system prompt as
    // pseudo-examples. The agent would then pattern-match its own past mistakes
    // (e.g. "refatore X.html (X-matrix.html)") as the canonical project style.
    // The file counts in "## Modified files" still exist for human audit.
    const taskLines = mem.tasks.length
      ? mem.tasks.map(t => `- [${t.date}] ${t.request}`).join('\n')
      : '_none yet_';

    const insightLines = mem.insights.length
      ? mem.insights.map(i => `- ${i}`).join('\n')
      : '_none yet_';

    const sortedFiles = Array.from(mem.files.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, MAX_FILES)
      .map(([f, n]) => `- ${f} (${n}x)`)
      .join('\n') || '_none yet_';

    const preservedSection = mem.preserved
      ? `\n${mem.preserved}\n`
      : '';

    return [
      `# Phenom Memory`,
      `> Updated: ${today} | Tasks: ${mem.taskCount}`,
      ``,
      `## Recent tasks`,
      taskLines,
      ``,
      `## Insights`,
      insightLines,
      ``,
      `## Modified files`,
      sortedFiles,
      ``,
      `---`,
      PRESERVE_TAG,
      preservedSection,
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
