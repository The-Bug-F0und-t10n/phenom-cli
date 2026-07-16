import type { Tool } from '../../tools.js';
import { MemoryWriter, SECTION_HEADERS, type ModelMemorySection } from '../../learning-loop/memory-writer.js';
import { SkillStore } from '../../learning-loop/skill-store.js';

interface RegisterMemoryToolsDeps {
  register: (tool: Tool) => void;
}

/**
 * Memory + skill tools — durable, project-scoped knowledge consulted
 * ON-DEMAND by the model. Never auto-injected into the system prompt:
 * injection mutated the prompt every turn (learning-loop writes), forcing
 * the server slot to re-prefill from token 0. Read paths are tools the
 * model calls when it needs the data; write paths are tools the model
 * calls when it has something durable to record.
 *
 * Lifecycle:
 *   - .MEMORY.md: written on new-session repo analysis (model calls
 *     `update_memory section=description`) and on context compaction
 *     (memory-writer.distillBySection runs server-side). Read via
 *     `read_memory` when the model needs project context.
 *   - .SKILL.md: written only when the model decides a skill is worth
 *     keeping — explicit user rule, or implicit behavior the user has
 *     corrected ≥2×. Read via `read_skills` inside the tool loop when
 *     the model is choosing an approach.
 */
export function registerMemoryTools(deps: RegisterMemoryToolsDeps): void {
  const { register } = deps;
  // Both writers are stateless wrappers around the disk files, so we
  // instantiate fresh per call (no shared state to mismanage).
  const memoryWriter = new MemoryWriter();
  const skillStore = new SkillStore();

  // ── update_memory ────────────────────────────────────────────────
  // Sections of .MEMORY.md:
  //   description  — short documentation of THIS project
  //   custom_rules — permanent project-scoped rules the user has stated
  //   behaviors    — patterns the user has requested repeatedly
  //   tasks        — active work + project annotations / decisions
  //   insights     — non-obvious technical observations
  register({
    name: 'update_memory',
    description: 'Write durable project knowledge into .MEMORY.md. Consulted on-demand via read_memory — NOT auto-injected. Call when (a) the session is new and you have explored the repo enough to write a description, (b) the user states a permanent rule, (c) you finish a context compaction. Sections: "description" (what this project IS), "custom_rules" (permanent rules the user stated), "behaviors" (patterns the user has asked for 3+ times), "tasks" (active work + architecture decisions), "insights" (non-obvious technical observations). Default mode "append". Use "replace" when refining supersedes prior content. Sections cap at ~5KB.',
    parameters: {
      type: 'object',
      properties: {
        section: {
          type: 'string',
          description: 'Section to update. EXACT keys: "description" (project doc), "custom_rules" (user-stated permanent rules), "behaviors" (repeatedly-requested behaviors), "tasks" (active work + notes), "insights" (technical observations).'
        },
        content: {
          type: 'string',
          description: 'Markdown content. Use short bullet points (one observation per line) for "custom_rules", "behaviors", "insights". Prose acceptable for "description" and "tasks" annotations.'
        },
        mode: {
          type: 'string',
          description: '"append" (default) adds below existing. "replace" overwrites the section entirely — use when refining understanding (e.g. project description changed after deeper exploration).'
        }
      },
      required: ['section', 'content']
    },
    execute: async (args) => {
      const sectionRaw = String(args.section || '').toLowerCase().trim();
      const content = String(args.content || '').trim();
      const modeRaw = String(args.mode || 'append').toLowerCase().trim();
      const normalizedSection = sectionRaw
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .replace(/[\s-]+/g, '_')
        .replace(/__+/g, '_');

      const validSections: ModelMemorySection[] = ['description', 'custom_rules', 'behaviors', 'tasks', 'insights'];
      // Soft alias for legacy keys (in case the model trained on prior
      // schema names emits "context"/"rules"/"conventions"):
      const aliased = ({
        context:             'description',
        project_context:     'description',
        project_description: 'description',
        description:         'description',
        conventions:         'custom_rules',
        rules:               'custom_rules',
        custom_rules:        'custom_rules',
        specific_behaviors:  'behaviors',
        behaviors:           'behaviors',
        active_tasks:        'tasks',
        tasks:               'tasks',
        notes:               'tasks',
        insights:            'insights',
      } as Record<string, ModelMemorySection>)[normalizedSection];
      const sectionKey = (aliased ?? normalizedSection) as ModelMemorySection;

      if (!validSections.includes(sectionKey)) {
        return {
          success: false,
          output: '',
          error: `update_memory rejected: section must be one of ${validSections.join(', ')}. Got "${sectionRaw}".`
        };
      }
      if (!content) {
        return { success: false, output: '', error: 'update_memory rejected: content is empty.' };
      }
      if (modeRaw !== 'append' && modeRaw !== 'replace') {
        return {
          success: false,
          output: '',
          error: `update_memory rejected: mode must be "append" or "replace". Got "${modeRaw}".`
        };
      }

      try {
        const finalSize = await memoryWriter.updateSection(sectionKey, content, modeRaw as 'append' | 'replace');
        return {
          success: true,
          output: `[MEMORY_UPDATED] section=${sectionKey} mode=${modeRaw} → ${finalSize} chars in section.`,
          error: null
        };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'update_memory failed' };
      }
    }
  });

  // ── record_skill ─────────────────────────────────────────────────
  // Persist a reusable tool sequence as a "skill" the model can recall on
  // similar future tasks. Read on-demand via `read_skills`.
  register({
    name: 'record_skill',
    description: 'Persist a reusable pattern into .SKILL.md. Call ONLY when (a) the user states an explicit instruction worth keeping ("always do X", "never do Y"), or (b) the user has corrected the same indirect behavior ≥2× — record the corrected pattern so it stops happening. Do NOT record routine tool sequences that worked once. Read on-demand via read_skills inside the tool loop — NOT auto-injected. triggerKeywords drive matching at read time.',
    parameters: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: 'Short skill name (≤60 chars). E.g. "refactor TS file with apply_patch + tests"'
        },
        description: {
          type: 'string',
          description: 'One-sentence description of WHEN to apply this skill.'
        },
        toolSequence: {
          type: 'array',
          description: 'Ordered list of tool names that constitute the pattern.',
          items: { type: 'string' }
        },
        triggerKeywords: {
          type: 'array',
          description: 'Lowercase keywords that, if present in a user request, suggest this skill applies. 3-8 keywords ideal.',
          items: { type: 'string' }
        },
        domain: {
          type: 'string',
          description: 'Optional domain tag — typescript, python, debug, refactor, etc.'
        }
      },
      required: ['name', 'description', 'toolSequence']
    },
    execute: async (args) => {
      const name = String(args.name || '').trim().slice(0, 80);
      const description = String(args.description || '').trim();
      const toolSequence = Array.isArray(args.toolSequence)
        ? args.toolSequence.map((t: any) => String(t)).filter((t: string) => t.length > 0)
        : [];
      const triggerKeywords = Array.isArray(args.triggerKeywords)
        ? args.triggerKeywords.map((t: any) => String(t).toLowerCase()).filter((t: string) => t.length > 0)
        : [];
      const domain = String(args.domain || 'general').toLowerCase().trim();

      if (!name) return { success: false, output: '', error: 'record_skill rejected: name is required.' };
      if (!description) return { success: false, output: '', error: 'record_skill rejected: description is required.' };
      if (toolSequence.length === 0) {
        return { success: false, output: '', error: 'record_skill rejected: toolSequence must contain at least one tool name.' };
      }

      try {
        await skillStore.init();
        skillStore.addOrRefine({
          name,
          domain,
          description,
          toolSequence,
          triggerKeywords
        });
        await skillStore.save();
        return {
          success: true,
          output: `[SKILL_RECORDED] "${name}" (domain=${domain}, ${toolSequence.length} steps, ${triggerKeywords.length} triggers)`,
          error: null
        };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'record_skill failed' };
      }
    }
  });

  // ── read_memory ──────────────────────────────────────────────────
  // On-demand read of .MEMORY.md. Replaces the prior auto-injection in the
  // system prompt — the model now pulls memory exactly when it needs to.
  register({
    name: 'read_memory',
    description: 'Read durable project knowledge from .MEMORY.md. Call when you need (a) project description / conventions on a new session, (b) custom rules the user previously stated, (c) prior insights about this codebase, (d) compaction summaries of past context. Optional "section" narrows the read; omit to get all populated sections. Returns empty when the file does not exist yet (new session) — populate it via update_memory.',
    parameters: {
      type: 'object',
      properties: {
        section: {
          type: 'string',
          description: 'Optional. One of "description", "custom_rules", "behaviors", "tasks", "insights". Omit to read all populated sections.'
        }
      }
    },
    execute: async (args) => {
      try {
        const sectionRaw = String(args.section || '').toLowerCase().trim();
        const all = memoryWriter.readCompactForPrompt(8000, []);
        if (!all) {
          return { success: true, output: '[MEMORY_EMPTY] .MEMORY.md has no content yet. Use update_memory to seed it (start with section=description after exploring the repo).', error: null };
        }
        if (!sectionRaw) {
          return { success: true, output: all, error: null };
        }
        const header = SECTION_HEADERS[sectionRaw as ModelMemorySection];
        if (!header) {
          return { success: false, output: '', error: `read_memory rejected: unknown section "${sectionRaw}". Valid: description, custom_rules, behaviors, tasks, insights.` };
        }
        const idx = all.indexOf(header);
        if (idx < 0) {
          return { success: true, output: `[SECTION_EMPTY] ${sectionRaw}`, error: null };
        }
        const nextHeaderIdx = Object.values(SECTION_HEADERS)
          .map(h => all.indexOf(h, idx + header.length))
          .filter(i => i > 0)
          .sort((a, b) => a - b)[0] ?? all.length;
        return { success: true, output: all.slice(idx, nextHeaderIdx).trim(), error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'read_memory failed' };
      }
    }
  });

  // ── read_skills ──────────────────────────────────────────────────
  // On-demand read of .SKILL.md inside the tool loop. The model calls this
  // when choosing an approach — to recall prior corrections and user rules.
  register({
    name: 'read_skills',
    description: 'Read recorded skills from .SKILL.md. Call inside the tool loop when deciding how to approach a task — surfaces explicit user rules and patterns the user has previously corrected. Optional "keywords" filters to skills whose triggerKeywords overlap. Returns empty when the file does not exist yet.',
    parameters: {
      type: 'object',
      properties: {
        keywords: {
          type: 'array',
          description: 'Optional. Lowercase keywords from the current task; returns only skills whose triggerKeywords overlap. Omit to read all.',
          items: { type: 'string' }
        }
      }
    },
    execute: async (args) => {
      try {
        const raw = SkillStore.readSkillsMdCompact(process.cwd(), 8000);
        if (!raw) {
          return { success: true, output: '[SKILLS_EMPTY] .SKILL.md has no content yet.', error: null };
        }
        const keywords = Array.isArray(args.keywords)
          ? args.keywords.map((k: any) => String(k).toLowerCase()).filter((k: string) => k.length > 0)
          : [];
        if (keywords.length === 0) {
          return { success: true, output: raw, error: null };
        }
        const blocks = raw.split(/\n(?=##\s)/).filter(b => b.trim());
        const matched = blocks.filter(b => {
          const low = b.toLowerCase();
          return keywords.some(k => low.includes(k));
        });
        if (matched.length === 0) {
          return { success: true, output: `[NO_SKILL_MATCH] none of ${JSON.stringify(keywords)} matched recorded skills.`, error: null };
        }
        return { success: true, output: matched.join('\n\n'), error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'read_skills failed' };
      }
    }
  });
}
