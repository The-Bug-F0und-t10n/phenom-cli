import { ReflectionResult, ToolResult } from './types.js';
import { OllamaClient, OfflineError, OllamaNotFoundError, OllamaResourceError } from './ollama-client.js';
import { extractBalancedJson, safeJsonParse } from './json-utils.js';

// Reflector — analyzes tool results and determines next action.
//
// FIXES applied:
//  1. looksLikeFileWrite replaced: was checking hardcoded Portuguese strings
//     tied to tool output format. Now uses the toolName parameter directly —
//     if it was a write/patch tool and it succeeded, reflection is not needed.
//  2. validateCompletion: was returning true on LLM error (silently reporting
//     completion). Now returns false — unknown state is not success.
//  3. deepReflect fallback: no longer returns done:true blindly on parse error.
//     Returns done:false with a diagnostic issue instead.
//  4. reflect() signature: accepts optional toolName for structural decisions.
//  5. Prompt optimized for Qwen 2.5 14B — shorter context, explicit JSON-only
//     instruction at prompt end.

export class Reflector {
  constructor(private llm: OllamaClient) {}

  async reflect(
    stepAction: string,
    toolResult: ToolResult | null,
    goal: string,
    toolName?: string
  ): Promise<ReflectionResult> {
    // Fast path 1: tool failed — no LLM needed, error is self-explanatory
    if (toolResult && !toolResult.success) {
      return {
        done: false,
        nextAction: `Fix error: ${toolResult.error}`,
        issues: [toolResult.error || 'Unknown tool error']
      };
    }

    // Fast path 2: no tool result — it was a direct LLM response step
    if (!toolResult) {
      return { done: true, nextAction: null, issues: [] };
    }

    // FIX: use toolName for structural detection instead of parsing output strings.
    // write_file and apply_patch success is terminal — no LLM reflection needed.
    if (toolResult.success && this.isFileWriteTool(toolName)) {
      return { done: true, nextAction: null, issues: [] };
    }

    // Fast path 3: read-only tools that succeeded
    if (toolResult.success && this.isReadOnlyTool(toolName)) {
      return { done: true, nextAction: null, issues: [] };
    }

    // Deep reflection via LLM only for ambiguous cases (e.g. run_code output,
    // search results that may or may not satisfy the goal)
    return this.deepReflect(stepAction, toolResult, goal, toolName);
  }

  private isFileWriteTool(toolName?: string): boolean {
    return toolName === 'write_file' || toolName === 'apply_patch';
  }

  private isReadOnlyTool(toolName?: string): boolean {
    return (
      toolName === 'read_file' ||
      toolName === 'list_dir' ||
      toolName === 'path_exists' ||
      toolName === 'git_status' ||
      toolName === 'git_diff' ||
      toolName === 'git_log'
    );
  }

  private async deepReflect(
    stepAction: string,
    toolResult: ToolResult,
    goal: string,
    toolName?: string
  ): Promise<ReflectionResult> {
    // Truncate output: 14B works best with focused context under 600 tokens
    const outputSnippet = String(toolResult.output || '').slice(0, 500);
    const toolLabel     = toolName ? `Tool: ${toolName}` : '';

    // Prompt optimized for Qwen 2.5 14B:
    // - JSON instruction at the end (model attends strongly to end of prompt)
    // - No nested structure explanation
    // - Explicit field names with types
    const prompt = `Analyze this action result.

Goal: ${goal}
Action: ${stepAction}
${toolLabel}
Success: ${toolResult.success}
Output: ${outputSnippet}

Answer:
- done: true if this step fully resolved the action, false otherwise
- nextAction: string with the next step, or null if done
- issues: array of problem strings (empty if done)

Output ONLY valid JSON:
{"done":true,"nextAction":null,"issues":[]}`;

    try {
      const response = await this.llm.generate(prompt);
      const parsed   = safeJsonParse(extractBalancedJson(response));

      if (!parsed) {
        return {
          done: false,
          nextAction: 'Retry step — reflection parse failed',
          issues: ['Reflection LLM response was not valid JSON']
        };
      }

      return {
        done: Boolean(parsed.done),
        nextAction: parsed.nextAction ?? null,
        issues: Array.isArray(parsed.issues) ? parsed.issues : []
      };
    } catch (error) {
      if (
        error instanceof OfflineError ||
        error instanceof OllamaNotFoundError ||
        error instanceof OllamaResourceError
      ) {
        throw error;
      }
      // FIX: on parse/network error, do NOT assume success.
      // Return a diagnostic that lets the agent decide whether to retry.
      return {
        done: false,
        nextAction: 'Retry step — reflection parse failed',
        issues: ['Reflection LLM response was not valid JSON']
      };
    }
  }

  async validateCompletion(goal: string, results: string[]): Promise<boolean> {
    const prompt = `Was the overall goal achieved?

Goal: ${goal}

Results:
${results.map((r, i) => `${i + 1}. ${r.slice(0, 200)}`).join('\n')}

Answer only YES or NO (nothing else):`;

    try {
      const response = await this.llm.generate(prompt);
      return /^\s*yes\s*$/i.test(response.trim());
    } catch (error) {
      if (
        error instanceof OfflineError ||
        error instanceof OllamaNotFoundError ||
        error instanceof OllamaResourceError
      ) {
        throw error;
      }
      // FIX: return false, not true. Completion unknown ≠ completion confirmed.
      return false;
    }
  }

}
