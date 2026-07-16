import { EventType } from '../tui/event-bus.js';
import type { ToolCall, ToolResult } from '../types.js';

type BrainLike = {
  addCreatedFile(filePath: string): void;
  addNote(type: 'progress' | 'error' | 'observation', content: string): string;
  addFailedOperation(operation: string): void;
  addInsight(insight: string): void;
  getPlanSteps?: () => Array<{ status: 'pending' | 'in_progress' | 'completed' | 'failed' }>;
  getRequestMetrics?: () => { mutationFiles: string[]; searchCount: number };
  noteMutation?: (filePath: string) => void;
  noteSearchEvidence?: () => void;
  noteValidation?: () => void;
  noteTestsRun?: () => void;
  noteBuildRun?: () => void;
};

interface ExecuteToolWithEventsDeps {
  executeTool: (toolName: string, args: Record<string, unknown>) => Promise<ToolResult>;
  emit: (type: EventType, payload: unknown) => void;
  addToolCall: (call: ToolCall) => void;
  sessionId: string | null;
  brain: BrainLike | null;
}

export async function executeToolWithEventsUseCase(
  deps: ExecuteToolWithEventsDeps,
  toolName: string,
  args: Record<string, unknown>
): Promise<ToolResult> {
  const toolId = `${toolName}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
  deps.emit(EventType.TOOL_START, { id: toolId, name: toolName, args });

  let result: ToolResult;
  const mutationTools = new Set(['write_file', 'create_file', 'apply_patch', 'delete_file', 'delete_dir']);
  // These three run validate_syntax inline (see filesystem-tools), so a
  // successful call IS a validated change even without an explicit
  // validate_syntax tool call.
  const inlineValidatingTools = new Set(['write_file', 'create_file', 'apply_patch']);
  const mutationPath = typeof args.path === 'string' ? String(args.path) : '';
  // Plan gate removed — set_plan is a convention for weaker models. 9B+
  // models edit competently without a forced plan turn. The system prompt
  // still encourages set_plan for complex changes, but no longer blocks.
  if (mutationTools.has(toolName) && deps.brain?.getRequestMetrics) {
    const metrics = deps.brain.getRequestMetrics();
    const normalized = mutationPath.trim();
    const isNewMutationFile = normalized.length > 0 && !metrics.mutationFiles.includes(normalized);
    // Hard mutation budget aligned with the advisory in the system prompt
    // (~7 files per request). Above this, the model must finish current
    // scope before opening a new file.
    const HARD_MUTATION_BUDGET = 7;
    if (isNewMutationFile && metrics.mutationFiles.length >= HARD_MUTATION_BUDGET) {
      result = {
        success: false,
        output: '',
        error: `[CHANGE_BUDGET] Max ${HARD_MUTATION_BUDGET} mutation files per request reached (${metrics.mutationFiles.join(', ')}). Finish current scope first.`
      };
      deps.emit(EventType.TOOL_ERROR, { id: toolId, error: result.error, output: result.output, toolName });
      deps.addToolCall({ tool: toolName, args, result, timestamp: Date.now() });
      return result;
    }

    // Caller-matrix gate applies ONLY to apply_patch: it edits an EXISTING
    // symbol, so a signature change can break callers. write_file/create_file
    // are full-file ops that are usually creation — a brand-new file has no
    // callers, so demanding "find callers first" is impossible to satisfy and
    // just forces a spurious search.
    if (toolName === 'apply_patch' && isSignatureRiskChange(toolName, args) && metrics.searchCount <= 0) {
      result = {
        success: false,
        output: '',
        error: '[CALLER_MATRIX_REQUIRED] Signature-level change requires caller evidence first. Run grep_file/search_code for callers, then patch.'
      };
      deps.emit(EventType.TOOL_ERROR, { id: toolId, error: result.error, output: result.output, toolName });
      deps.addToolCall({ tool: toolName, args, result, timestamp: Date.now() });
      return result;
    }
  }

  try {
    result = await deps.executeTool(toolName, args);
  } catch (error: unknown) {
    result = { success: false, output: '', error: error instanceof Error ? error.message : 'tool failed' };
  }

  if (deps.brain) {
    if ((toolName === 'write_file' || toolName === 'create_file') && result.success && args.path) {
      deps.brain.addCreatedFile(String(args.path));
      deps.brain.addNote('progress', `Created: ${args.path}`);
    }
    if (!result.success && result.error) {
      deps.brain.addFailedOperation(`${toolName}: ${result.error}`);
      deps.brain.addNote('error', `${toolName} failed: ${result.error}`);
    }
    if (result.success && result.output) {
      if (toolName === 'read_file' && args.path) {
        const lineCount = String(result.output || '').split('\n').length;
        deps.brain.addInsight(`Read file ${args.path} (${lineCount} lines)`);
      }
      if (toolName === 'list_dir' && args.path) {
        const entryCount = String(result.output || '').split('\n').length;
        deps.brain.addNote('observation', `Listed ${args.path} (${entryCount} entries)`);
      }
      if (toolName === 'search_code' || toolName === 'grep_file') {
        const matchCount = String(result.output || '').split('\n').length;
        deps.brain.addInsight(`Search "${args.query || args.pattern}" found ${matchCount} matches`);
      }
    }
    if (result.success && deps.brain.noteMutation && mutationTools.has(toolName) && mutationPath) {
      deps.brain.noteMutation(mutationPath);
    }
    if (result.success && deps.brain.noteSearchEvidence && (toolName === 'search_code' || toolName === 'grep_file' || toolName === 'find_function')) {
      deps.brain.noteSearchEvidence();
    }
    if (result.success && deps.brain.noteValidation && toolName === 'validate_syntax') {
      deps.brain.noteValidation();
    }
    if (result.success && deps.brain.noteValidation && inlineValidatingTools.has(toolName)) {
      // The mutation tool already validated syntax inline; record it so the
      // verification gate doesn't push a redundant explicit validate_syntax.
      deps.brain.noteValidation();
    }
    if (result.success && deps.brain.noteTestsRun && toolName === 'run_tests') {
      deps.brain.noteTestsRun();
    }
    if (result.success && deps.brain.noteBuildRun && toolName === 'run_code') {
      const cmd = String(args.command || args.cmd || '').toLowerCase();
      if (
        cmd.includes('tsc') ||
        cmd.includes('go build') ||
        cmd.includes('cargo build') ||
        cmd.includes('mvn compile') ||
        cmd.includes('gradle build') ||
        cmd.includes('npm run build')
      ) {
        deps.brain.noteBuildRun();
      }
    }
  }

  if (result.success) {
    deps.emit(EventType.TOOL_RESULT, { id: toolId, result, toolName });

    if ((toolName === 'create_file' || toolName === 'write_file') && args.path) {
      const filePath = String(args.path);
      const content = String(args.content || '');
      const lines = content.split('\n');
      const numbered = lines.map((l, i) => `${String(i + 1).padStart(4, ' ')} │ ${l}`).join('\n');
      deps.emit(EventType.FILE_DIFF, {
        path: filePath,
        lineCount: lines.length,
        content: numbered,
        byteSize: Buffer.byteLength(content, 'utf-8'),
        action: result.output?.startsWith('[REPLACED]') ? 'replaced' : 'created'
      });
    }

    if (toolName === 'apply_patch' && typeof args.path === 'string') {
      const ops = Array.isArray(args.operations) ? args.operations : [];
      // Unified diff format — same shape as write_file/create_file. Each
      // line is "<N> <marker> │ <text>" so renderFileDiff colours both
      // tools with a single code path. Removed lines get "-", added get
      // "+". Multi-op patches get a "── op N/M ──" separator between ops.
      const lines: string[] = [];
      ops.forEach((op, i) => {
        const rec = (op && typeof op === 'object') ? op as Record<string, unknown> : {};
        const search = String(rec.search || rec.find || '');
        const replace = String(rec.replace || '');
        if (i > 0) lines.push('');
        if (ops.length > 1) lines.push(`── op ${i + 1}/${ops.length} ──`);
        search.split('\n').forEach((sl, idx) => {
          lines.push(`${String(idx + 1).padStart(4, ' ')} - │ ${sl}`);
        });
        replace.split('\n').forEach((rl, idx) => {
          lines.push(`${String(idx + 1).padStart(4, ' ')} + │ ${rl}`);
        });
      });
      deps.emit(EventType.FILE_DIFF, {
        path: args.path,
        lineCount: ops.length,
        content: lines.join('\n') || '   1   │ [patch applied]',
        byteSize: 0,
        action: 'patched'
      });
    }

    if ((toolName === 'delete_file' || toolName === 'delete_dir') && typeof args.path === 'string') {
      deps.emit(EventType.FILE_DIFF, {
        path: args.path,
        lineCount: 0,
        content: '',
        byteSize: 0,
        action: 'deleted'
      });
    }
  } else {
    deps.emit(EventType.TOOL_ERROR, {
      id: toolId,
      error: result.error || 'tool failed',
      output: result.output || '',
      toolName
    });
  }

  deps.emit(EventType.SESSION_UPDATE, {
    sessionId: deps.sessionId,
    toolName,
    toolResult: result.success,
    toolOutput: result.output?.substring(0, 100)
  });

  deps.addToolCall({ tool: toolName, args, result, timestamp: Date.now() });
  return result;
}

function isSignatureRiskChange(toolName: string, args: Record<string, unknown>): boolean {
  // Declaration keywords only — narrow on purpose. Bare `type` and access
  // modifiers (public/private/protected) matched member bodies and prose,
  // turning this into a near-universal gate. Only apply_patch reaches here.
  const signatureRe = /\b(function|class|interface|enum|def)\b/;

  if (toolName !== 'apply_patch') return false;

  const ops = Array.isArray(args.operations) ? args.operations : [];
  for (const op of ops) {
    if (!op || typeof op !== 'object') continue;
    const rec = op as Record<string, unknown>;
    const replace = String(rec.replace || '');
    if (signatureRe.test(replace)) return true;
  }
  return false;
}
