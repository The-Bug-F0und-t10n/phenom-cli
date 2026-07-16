import type { Tool } from '../../tools.js';
import type { SessionBrain } from '../../session-brain.js';

interface RegisterSessionToolsDeps {
  register: (tool: Tool) => void;
  /**
   * Late-bound brain accessor. The Agent calls this registrar AFTER initialize()
   * sets up the brain, but we still pass a getter so tools observe the current
   * brain on every call (handles session swaps, refresh, etc.).
   */
  brainProvider: () => SessionBrain | null;
}

/**
 * Session-scoped tools. These expose the SessionBrain state to the model so it
 * can reason about what already happened in the current conversation without
 * having to re-walk the filesystem via list_dir + read_file.
 *
 * Why this matters for small models: every list_dir / read_file call burns
 * context window. If the model already created file X in this session, it
 * should be able to ask "what have I touched?" cheaply instead of rediscovering.
 */
export function registerSessionTools(deps: RegisterSessionToolsDeps): void {
  const { register, brainProvider } = deps;

  register({
    name: 'list_session_files',
    description: 'Return the files YOU have created, modified, read, or otherwise observed in the current session. Use this BEFORE list_dir whenever you want to know "what have I been doing" — it answers without filesystem walks and without burning context. Returns categorised lists: created, insights (read history), failures.',
    parameters: {
      type: 'object',
      properties: {
        category: {
          type: 'string',
          description: 'Optional filter: "created" | "read" | "failures" | "all" (default: "all").'
        }
      }
    },
    execute: async (args) => {
      const brain = brainProvider();
      if (!brain) {
        return {
          success: false,
          output: '',
          error: 'Session brain not available (agent not initialised yet).'
        };
      }

      const category = String(args.category || 'all').toLowerCase().trim();
      const created = brain.getCreatedFiles();
      const insights = brain.getInsights();
      // Read history is captured as insights like "Read file <path> (N lines)".
      // Parse them back into a clean path list for the model.
      const readPaths: string[] = [];
      const otherInsights: string[] = [];
      for (const ins of insights) {
        const m = ins.match(/^Read file (.+?) \(\d+ lines\)$/i);
        if (m) {
          if (!readPaths.includes(m[1])) readPaths.push(m[1]);
        } else {
          otherInsights.push(ins);
        }
      }
      const data = brain.getData();
      const failures = (data.failedOperations || []).slice(-10);

      const want = (k: string) =>
        category === 'all' || category === k || category === k + 's';

      const sections: string[] = ['[SESSION_FILES]'];
      if (want('created')) {
        sections.push(`created (${created.length}):`);
        if (created.length === 0) sections.push('  (none)');
        else for (const p of created) sections.push(`  ${p}`);
      }
      if (want('read')) {
        sections.push(`read (${readPaths.length}):`);
        if (readPaths.length === 0) sections.push('  (none)');
        else for (const p of readPaths) sections.push(`  ${p}`);
      }
      if (want('failure') || want('failures') || category === 'all') {
        sections.push(`failures (${failures.length}):`);
        if (failures.length === 0) sections.push('  (none)');
        else for (const f of failures) sections.push(`  ${f}`);
      }
      if (category === 'all' && otherInsights.length > 0) {
        sections.push(`other_insights (${otherInsights.length}):`);
        for (const i of otherInsights.slice(-10)) sections.push(`  ${i}`);
      }

      return {
        success: true,
        output: sections.join('\n'),
        error: null
      };
    }
  });

  // ── get_session_context ──────────────────────────────────────────
  // Returns the active plan / focused step / user request on demand.
  // Previously this content was glued onto the last user message at
  // build time (appendCurrentTurnContext). That mutated the cached
  // prefix between turns — the next turn rebuilt the user message
  // WITHOUT the appended context, diverging from the slot's KV and
  // triggering "erased invalidated context checkpoint" + full prompt
  // re-processing on SWA/hybrid models. By moving it to a tool the
  // model calls when needed, the conversation prefix becomes truly
  // append-only and the slot cache survives across turns.
  register({
    name: 'get_session_context',
    description: 'Return the active plan, focused step, and original user request for this session. Call this at the start of a turn when you need to know what plan you are following and which step is current. Returns "[NO_PLAN]" when no plan is set — in that case proceed without it. Cheap and pure (no filesystem access).',
    parameters: { type: 'object', properties: {} },
    execute: async () => {
      const brain = brainProvider();
      if (!brain) {
        return { success: true, output: '[NO_PLAN] session brain not available.', error: null };
      }
      const all = brain.getPlanSteps();
      const pending = all
        .filter(s => s.status === 'pending' || s.status === 'in_progress')
        .sort((a, b) => a.order - b.order);
      if (pending.length === 0) {
        return { success: true, output: '[NO_PLAN] no active plan steps. Set one via set_plan if the task warrants it.', error: null };
      }
      const current = pending.find(s => s.status === 'in_progress') || pending[0];
      const totalSteps = all.length;
      const completedCount = totalSteps - pending.length;
      const request = String(brain.getUserRequest() || '').trim();
      const focusHints = [
        current.file ? `file=${current.file}` : null,
        current.tool ? `tool=${current.tool}` : null
      ].filter(Boolean).join(', ');
      const focusLine = focusHints
        ? `- Focused step ${current.order}/${totalSteps}: ${current.title}  (${focusHints})`
        : `- Focused step ${current.order}/${totalSteps}: ${current.title}`;
      const lines = [
        '## Active plan',
        '- Plan is binding for this turn. Do the focused step, then call complete_step(order) before moving on.',
        '- If the focused step no longer makes sense (scope changed, blocker discovered), call set_plan with a revised plan instead of improvising.',
        request ? `- Task: ${request.slice(0, 180)}` : '',
        focusLine,
        `- Progress: ${completedCount}/${totalSteps} complete, ${pending.length} remaining`,
        '',
        'Use list_pending_tasks if you need the full remaining list.'
      ].filter(Boolean);
      return { success: true, output: lines.join('\n'), error: null };
    }
  });
}
