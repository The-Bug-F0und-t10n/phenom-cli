import type { Tool } from '../../tools.js';
import { MemoryWriter, type ModelMemorySection } from '../../learning-loop/memory-writer.js';
import { SkillStore } from '../../learning-loop/skill-store.js';

interface RegisterMemoryToolsDeps {
  register: (tool: Tool) => void;
}

/**
 * Memory + skill tools — let the model deposit durable, project-scoped
 * knowledge that survives across sessions.
 *
 * Why this matters for a small (9B) model: every session starts from a
 * relatively blank slate. Without these tools, the model has to re-derive
 * "how is this codebase structured", "what conventions apply", "what rules
 * has the user given me" every time. With them, the model writes those
 * findings ONCE into .MEMORY.md / .SKILL.md, and they are auto-injected into
 * subsequent system prompts — preserving context budget for actual work.
 */
export function registerMemoryTools(deps: RegisterMemoryToolsDeps): void {
  const { register } = deps;
  // Both writers are stateless wrappers around the disk files, so we
  // instantiate fresh per call (no shared state to mismanage).
  const memoryWriter = new MemoryWriter();
  const skillStore = new SkillStore();

  // ── update_memory ────────────────────────────────────────────────
  // Model-managed sections of .MEMORY.md.
  //   context     — what kind of project this is, architecture, key modules
  //   conventions — naming, code style, observed patterns
  //   rules       — explicit user-stated rules / preferences
  //   insights    — technical observations worth keeping
  register({
    name: 'update_memory',
    description: 'Write durable project knowledge into .MEMORY.md so it survives across sessions. Use this to record (a) project architecture once you have understood it, (b) coding conventions you have observed, (c) custom rules the user has stated, (d) non-obvious insights. The named section is updated in place and auto-injected into future system prompts. Default mode is "append" (add to existing); use "replace" when you have a better understanding that supersedes prior content.',
    parameters: {
      type: 'object',
      properties: {
        section: {
          type: 'string',
          description: 'Which memory section to update. One of: "context" (architecture/structure), "conventions" (code style/patterns), "rules" (user-stated preferences), "insights" (technical observations).'
        },
        content: {
          type: 'string',
          description: 'Markdown content to write. Use short bullet points (one observation per line) for searchability. Prose is acceptable for "context" when describing architecture.'
        },
        mode: {
          type: 'string',
          description: '"append" (default) adds to existing section. "replace" overwrites the section entirely — use only when you have a better understanding superseding prior content.'
        }
      },
      required: ['section', 'content']
    },
    execute: async (args) => {
      const sectionRaw = String(args.section || '').toLowerCase().trim();
      const content = String(args.content || '').trim();
      const modeRaw = String(args.mode || 'append').toLowerCase().trim();

      const validSections: ModelMemorySection[] = ['context', 'conventions', 'rules', 'insights'];
      if (!validSections.includes(sectionRaw as ModelMemorySection)) {
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
        const sectionKey = sectionRaw as ModelMemorySection;
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
  // similar future tasks. Skills are injected into the system prompt when the
  // current request matches the trigger keywords + domain.
  register({
    name: 'record_skill',
    description: 'Persist a reusable pattern: a tool sequence that worked well for a class of task. Use this AFTER completing a task whose approach generalises (e.g. "edit-and-test loop", "grep-then-patch flow"). The skill is stored in .SKILL.md and auto-injected into the system prompt when future requests match its trigger keywords.',
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
}
