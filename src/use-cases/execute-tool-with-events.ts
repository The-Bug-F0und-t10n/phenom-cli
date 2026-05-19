import { EventType } from '../tui/event-bus.js';
import type { ToolCall, ToolResult } from '../types.js';

type BrainLike = {
  addCreatedFile(filePath: string): void;
  addNote(type: 'progress' | 'error' | 'observation', content: string): string;
  addFailedOperation(operation: string): void;
  addInsight(insight: string): void;
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
      const opSummary = ops
        .map((op, i) => {
          const rec = (op && typeof op === 'object') ? op as Record<string, unknown> : {};
          const search = String(rec.search || rec.find || '').slice(0, 80);
          const replace = String(rec.replace || '').slice(0, 80);
          return `${String(i + 1).padStart(4, ' ')} │ - ${search}\n${' '.repeat(4)} │ + ${replace}`;
        })
        .join('\n');
      deps.emit(EventType.FILE_DIFF, {
        path: args.path,
        lineCount: 0,
        content: opSummary || '   1 │ [patch applied]',
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
    deps.emit(EventType.TOOL_ERROR, { id: toolId, error: result.error || 'tool failed', toolName });
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
