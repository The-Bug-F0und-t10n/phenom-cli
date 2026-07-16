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
 * Each holds a specific kind of durable, project-scoped knowledge:
 *
 *   description  — short but precise project documentation (what this
 *                  project is, what it does, key modules, how things
 *                  connect). The model writes this once it understands the
 *                  project; later refinements use mode=replace.
 *
 *   custom_rules — permanent rules the user has stated, project-scoped.
 *                  These are BINDING with the same weight as the Modelfile
 *                  base rules. Examples: "always use snake_case here",
 *                  "no semicolons in this codebase".
 *
 *   behaviors    — patterns the user has requested REPEATEDLY (3+ times)
 *                  that should become default. Distinguishes from a one-off
 *                  preference. Example: "user keeps asking me to run tests
 *                  after edits — make it default".
 *
 *   tasks        — active work the model is doing, with project annotations
 *                  (architecture decisions made during the task, gotchas
 *                  found, deferred work). NOT an auto-log of past prompts.
 *                  The model writes here intentionally as it works.
 *
 *   insights     — non-obvious technical observations worth keeping.
 *                  Pre-discovered gotchas, hidden coupling, "this code does
 *                  X because Y" notes.
 */
export type ModelMemorySection =
  | 'description'
  | 'custom_rules'
  | 'behaviors'
  | 'tasks'
  | 'insights';

const SECTION_HARD_CAP_CHARS = 5000;
const PRESERVE_TAG = '<!-- phenom:preserve -->';

/**
 * One focused distillation pass. Each pass asks the LLM ONE question
 * about the chunk being dropped, and writes the result to a single
 * memory section. Passes are independent and run in parallel.
 */
export interface CompactionPass {
  name: string;
  section: ModelMemorySection;
  question: string;
}

export const DEFAULT_COMPACTION_PASSES: CompactionPass[] = [
  {
    name: 'decisions',
    section: 'insights',
    question:
      'List durable technical decisions made in this excerpt. Keep only ' +
      'project-level choices worth reusing later. NOT: step-by-step logs, ' +
      'tool output, or temporary task chatter.'
  },
  {
    name: 'constraints',
    section: 'custom_rules',
    question:
      'List explicit constraints, rules, or preferences the user stated in ' +
      'this excerpt. Format: "<rule> — <why if mentioned>". NOT: greetings, ' +
      'casual remarks, what the model decided on its own.'
  },
  {
    name: 'failed_paths',
    section: 'insights',
    question:
      'List approaches that were tried and did NOT work in this excerpt. ' +
      'Format: "<what was tried> — <why it failed>". One line per attempt. ' +
      'NOT: tool errors caused by typos; only genuine dead ends worth ' +
      'remembering.'
  },
  {
    name: 'deferred',
    section: 'insights',
    question:
      'List deferred work ONLY if it is a durable project caveat or known ' +
      'limitation worth remembering across sessions. Format: "<what> — <why>".'
  },
  {
    name: 'behavior_patterns',
    section: 'behaviors',
    question:
      'List repeated user interaction patterns in this excerpt that should ' +
      'become default behavior. Include only strong/recurrent signals, not ' +
      'one-off preferences.'
  }
];

/**
 * Structural shape for messages handed to compaction. Kept loose to avoid
 * importing InferenceMessage from use-cases/ (which would create a cycle).
 */
export interface CompactableMessage {
  role: string;
  content: string | Array<{ type?: string; text?: string }>;
}

export interface CompactionResult {
  pass: string;
  section: ModelMemorySection;
  items: string[];
  wroteChars: number;
}

const DISTILL_MAX_ITEMS = 8;
const DISTILL_MAX_LINE_CHARS = 200;

export const SECTION_HEADERS: Record<ModelMemorySection, string> = {
  description:  '## Project description',
  custom_rules: '## Custom rules',
  behaviors:    '## Specific behaviors',
  tasks:        '## Active tasks & notes',
  insights:     '## Insights'
};

interface ParsedMemory {
  /**
   * Tracks total tasks completed across all sessions — purely for the
   * "> Updated: X | Tasks: N" header at the top of the file. Not injected.
   */
  taskCount: number;
  /** Model-curated section bodies. */
  modelSections: Record<ModelMemorySection, string>;
  /** Preserve block content (human-editable, never touched by regeneration). */
  preserved: string;
}

const SECTION_HEADER_ALIASES: Record<ModelMemorySection, string[]> = {
  description: ['## Project Description', '## Project context', '## Project Context'],
  custom_rules: ['## Custom Rules', '## Rules', '## Conventions'],
  behaviors: ['## Specific Behaviors', '## Behaviors'],
  tasks: ['## Active Tasks & Notes', '## Active tasks', '## Notes'],
  insights: ['## Insight', '## Technical insights'],
};

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

  async ensureExists(): Promise<void> {
    if (existsSync(this.memPath)) return;
    const mem = this.parse();
    await fs.writeFile(this.memPath, this.render(mem), 'utf-8');
  }

  /**
   * Auto-record a completed task: append to "Recent tasks" + accumulate
   * insights and file-touch counts. Called by the LearningLoop after every
   * task completion (regardless of model action).
   */
  async update(_entry: MemoryEntry, taskCount: number): Promise<void> {
    // `update()` now ONLY refreshes the header task counter. Auto-recording
    // of prompts, file lists, and brain insights into .MEMORY.md has been
    // removed — those were session telemetry that contaminated future
    // sessions when injected into the system prompt.
    //
    // ALL content sections (description, custom_rules, behaviors, tasks,
    // insights) are now exclusively model-curated via the update_memory
    // tool. This is intentional: the model writes durable knowledge with
    // intent; the framework does not write on the model's behalf.
    //
    // entry.request / entry.files / entry.insights are kept in the
    // MemoryEntry type for API compatibility but ignored here.
    const mem = this.parse();
    mem.taskCount = taskCount;
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
  readCompact(maxChars = 2000): string {
    if (!existsSync(this.memPath)) return '';
    try {
      const raw = readFileSync(this.memPath, 'utf-8');
      const idx = raw.indexOf(PRESERVE_TAG);
      const trimmed = (idx === -1 ? raw : raw.slice(0, idx))
        .replace(/^---\s*$/m, '')
        .trim();

      // No more section filtering — every section in .MEMORY.md is now
      // model-curated and meant to be injected. The old "## Recent tasks"
      // and "## Modified files" sections are gone (removed from render()).

      if (trimmed.length <= maxChars) return trimmed;
      const cut = trimmed.lastIndexOf('\n', maxChars);
      return trimmed.slice(0, cut > 0 ? cut : maxChars) + '\n…';
    } catch {
      return '';
    }
  }

  /**
   * System-prompt injection variant. Renders ONLY the requested sections
   * (excluding ones the caller wants to keep out of the prompt). Returns
   * `''` when nothing usable remains.
   *
   * The default exclusion of `tasks` matches the prior author's hard-won
   * rule: the 9B model treats any plan steps in the system prompt as a
   * to-do list and goes autopilot ("ola" → starts executing the previous
   * session's pending step). description / custom_rules / behaviors /
   * insights are all safe — they describe how to behave, not what to do
   * right now.
   */
  readCompactForPrompt(
    maxChars = 2000,
    exclude: ModelMemorySection[] = ['tasks']
  ): string {
    if (!existsSync(this.memPath)) return '';
    try {
      const mem = this.parse();
      const order: ModelMemorySection[] = [
        'description', 'custom_rules', 'behaviors', 'tasks', 'insights'
      ];
      const blocks: string[] = [];
      for (const key of order) {
        if (exclude.includes(key)) continue;
        const body = mem.modelSections[key].trim();
        if (!body || body === '_none yet_') continue;
        blocks.push(`${SECTION_HEADERS[key]}\n${body}`);
      }
      const joined = blocks.join('\n\n').trim();
      if (!joined) return '';
      if (joined.length <= maxChars) return joined;
      const cut = joined.lastIndexOf('\n', maxChars);
      return joined.slice(0, cut > 0 ? cut : maxChars) + '\n…';
    } catch {
      return '';
    }
  }

  /**
   * Memory-as-compaction-point: when the loop is about to drop messages
   * to fit the context window, hand them here. We run N small focused
   * LLM passes in parallel — one per topic — so each call stays tiny and
   * the model doesn't need the full degraded history to do good work.
   *
   * For the user this is ONE compaction event. Internally it's N
   * independent passes; if any pass fails (timeout, bad JSON), it's
   * silently dropped and the other passes still land.
   *
   * Returns telemetry per-pass so the caller can emit a single summary
   * event. Empty array means nothing worth keeping was found.
   */
  async distillBySection(
    messages: CompactableMessage[],
    llmFn: (prompt: string) => Promise<string>,
    passes: CompactionPass[] = DEFAULT_COMPACTION_PASSES
  ): Promise<CompactionResult[]> {
    const excerpt = renderExcerpt(messages);
    if (!excerpt.trim()) return [];

    const mem = this.parse();

    const passResults = await Promise.all(
      passes.map(async (pass) => {
        const existing = mem.modelSections[pass.section] || '';
        const prompt = buildDistillPrompt(pass, excerpt, existing);
        try {
          const raw = await llmFn(prompt);
          const items = parseDistillResponse(raw);
          return { pass, items };
        } catch {
          return { pass, items: [] as string[] };
        }
      })
    );

    const results: CompactionResult[] = [];
    for (const { pass, items } of passResults) {
      if (items.length === 0) {
        results.push({ pass: pass.name, section: pass.section, items: [], wroteChars: 0 });
        continue;
      }
      const block = items.map(s => `- ${s}`).join('\n');
      const wroteChars = await this.updateSection(pass.section, block, 'append');
      results.push({ pass: pass.name, section: pass.section, items, wroteChars });
    }
    return results;
  }

  // ── Private ─────────────────────────────────────────────────────────

  private emptyMem(): ParsedMemory {
    return {
      taskCount: 0,
      modelSections: {
        description:  '',
        custom_rules: '',
        behaviors:    '',
        tasks:        '',
        insights:     ''
      },
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

      for (const key of Object.keys(SECTION_HEADERS) as ModelMemorySection[]) {
        const headers = [SECTION_HEADERS[key], ...(SECTION_HEADER_ALIASES[key] || [])];
        const body = extractSectionAny(raw, headers);
        if (body && body !== '_none yet_') {
          mem.modelSections[key] = body;
        }
      }

      return mem;
    } catch {
      return this.emptyMem();
    }
  }

  private renderSection(key: ModelMemorySection, body: string): string {
    const trimmed = (body || '').trim();
    return [SECTION_HEADERS[key], trimmed || '_none yet_'].join('\n');
  }

  private render(mem: ParsedMemory): string {
    const today = new Date().toISOString().slice(0, 10);
    const preservedSection = mem.preserved ? `\n${mem.preserved}\n` : '';

    return [
      `# Phenom Memory`,
      `> Updated: ${today} | Tasks: ${mem.taskCount}`,
      ``,
      this.renderSection('description',  mem.modelSections.description),
      ``,
      this.renderSection('custom_rules', mem.modelSections.custom_rules),
      ``,
      this.renderSection('behaviors',    mem.modelSections.behaviors),
      ``,
      this.renderSection('tasks',        mem.modelSections.tasks),
      ``,
      this.renderSection('insights',     mem.modelSections.insights),
      ``,
      `---`,
      PRESERVE_TAG,
      preservedSection
    ].join('\n');
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function extractSection(content: string, header: string): string {
  return extractSectionAny(content, [header]);
}

function extractSectionAny(content: string, headers: string[]): string {
  for (const header of headers) {
    const title = String(header || '').replace(/^##\s*/, '').trim();
    if (!title) continue;
    const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp(`^##\\s+${escaped}\\s*$`, 'im');
    const match = re.exec(content);
    if (!match) continue;
    const afterHeader = content.indexOf('\n', match.index + match[0].length);
    if (afterHeader === -1) return '';
    const bodyStart = afterHeader + 1;
    const rest = content.slice(bodyStart);
    const nextHeaderRel = rest.search(/^##\s+/m);
    const sepRel = rest.search(/^---\s*$/m);
    let bodyEndRel = rest.length;
    if (nextHeaderRel >= 0) bodyEndRel = Math.min(bodyEndRel, nextHeaderRel);
    if (sepRel >= 0) bodyEndRel = Math.min(bodyEndRel, sepRel);
    return rest.slice(0, bodyEndRel).trim();
  }
  return '';
}

function renderExcerpt(messages: CompactableMessage[]): string {
  const lines: string[] = [];
  for (const m of messages) {
    const role = String(m.role || '').toUpperCase();
    let text: string;
    if (typeof m.content === 'string') {
      text = m.content;
    } else if (Array.isArray(m.content)) {
      text = m.content.map(p => (p?.text || '')).filter(Boolean).join(' ');
    } else {
      text = '';
    }
    text = text.trim();
    if (!text) continue;
    lines.push(`${role}: ${text}`);
  }
  return lines.join('\n\n');
}

function buildDistillPrompt(pass: CompactionPass, excerpt: string, existing: string): string {
  const existingBlock = existing.trim()
    ? `Already in memory (do NOT duplicate):\n${existing.trim()}\n\n`
    : '';
  return [
    `You are compacting a session excerpt into durable memory.`,
    `Task: ${pass.question}`,
    ``,
    existingBlock + `Excerpt:`,
    excerpt,
    ``,
    `Reply with STRICT JSON only: {"items": ["...", "..."]}`,
    `- Empty array {"items": []} if nothing relevant found.`,
    `- Max ${DISTILL_MAX_ITEMS} items.`,
    `- Each item one short line, max ${DISTILL_MAX_LINE_CHARS} chars.`,
    `- No prose, no markdown, no commentary outside the JSON object.`
  ].join('\n');
}

function parseDistillResponse(raw: string): string[] {
  const text = String(raw || '').trim();
  if (!text) return [];
  // Locate the first {...} block (model may wrap in prose despite instructions).
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end <= start) return [];
  const slice = text.slice(start, end + 1);
  let parsed: unknown;
  try { parsed = JSON.parse(slice); } catch { return []; }
  const obj = parsed as { items?: unknown };
  if (!obj || !Array.isArray(obj.items)) return [];
  const out: string[] = [];
  for (const item of obj.items) {
    if (typeof item !== 'string') continue;
    const trimmed = item.trim().replace(/\s+/g, ' ');
    if (!trimmed) continue;
    out.push(trimmed.slice(0, DISTILL_MAX_LINE_CHARS));
    if (out.length >= DISTILL_MAX_ITEMS) break;
  }
  return out;
}
