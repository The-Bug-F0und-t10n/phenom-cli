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
}
