import { promises as fs } from 'fs';
import path from 'path';
import type { Tool } from '../../tools.js';
import type { SessionBrain } from '../../session-brain.js';
import type { SyntaxValidator } from '../../syntax-validator.js';

interface RegisterWorkflowToolsDeps {
  register: (tool: Tool) => void;
  brainProvider: () => SessionBrain | null;
  syntaxValidator: SyntaxValidator;
  execFileAsync: (file: string, args: string[], options?: { maxBuffer?: number; cwd?: string }) => Promise<{ stdout: string; stderr: string }>;
}

/**
 * Workflow tools: structure the model's work as plan → write → validate → test.
 * Each tool here is a node in that pipeline — calling them in order is how the
 * model proves it actually completed a task (not just emitted code in prose).
 *
 * Why these are surfaced as tools (not Modelfile rules alone): a tool call is
 * verifiable. A Modelfile rule like "always validate after writing" can be
 * ignored silently. A tool call leaves a trace in the conversation and the
 * brain — making the workflow auditable.
 */
export function registerWorkflowTools(deps: RegisterWorkflowToolsDeps): void {
  const { register, brainProvider, syntaxValidator, execFileAsync } = deps;

  // ── set_plan ────────────────────────────────────────────────────────
  // Records a structured plan in the SessionBrain. Replaces any prior plan.
  // The plan appears in the system prompt as "## Active Plan" on subsequent
  // turns, so the model can self-track progress.
  register({
    name: 'set_plan',
    description:
      'Record a structured plan for the current task. Call this FIRST for any task involving multiple files or steps — before any read/write. ' +
      'Each step is a short imperative phrase ("read agent.ts", "patch run-tool-loop", "validate syntax", "run tests"). ' +
      'Max 7 steps per plan — if the task needs more, group related steps or split into a second plan after the first finishes. ' +
      'Optional `file` and `tool` fields per step help you (and the next turn) execute precisely. ' +
      'Subsequent turns see the plan as "Active plan" in the system prompt; call complete_step(N) immediately after finishing step N.',
    parameters: {
      type: 'object',
      properties: {
        steps: {
          type: 'array',
          description: 'Ordered list of steps (1–7 items).',
          items: {
            type: 'object',
            properties: {
              title: { type: 'string', description: 'Imperative phrase, ≤80 chars. Be specific: "patch foo.ts: change signature of bar()" beats "fix bar".' },
              description: { type: 'string', description: 'Optional 1-line clarifier.' },
              file: { type: 'string', description: 'Optional: path of the file this step touches. Helps you remember which file when you get here.' },
              tool: { type: 'string', description: 'Optional: name of the tool you intend to call for this step (e.g. "apply_patch", "validate_syntax").' }
            },
            required: ['title']
          }
        }
      },
      required: ['steps']
    },
    execute: async (args) => {
      const brain = brainProvider();
      if (!brain) {
        return { success: false, output: '', error: 'Brain not available — agent not initialised.' };
      }
      const raw = Array.isArray(args.steps) ? args.steps : [];
      if (raw.length === 0) {
        return { success: false, output: '', error: 'set_plan requires steps (non-empty array).' };
      }

      // Cap at MAX_PLAN_STEPS. Going bigger is exactly the failure mode a
      // 7B can't recover from — it loses the thread halfway. Forcing the
      // model to group/decompose here is a structural fix, not a hint.
      const MAX_PLAN_STEPS = 7;
      if (raw.length > MAX_PLAN_STEPS) {
        return {
          success: false,
          output: '',
          error:
            `set_plan rejected: ${raw.length} steps exceeds max ${MAX_PLAN_STEPS}. ` +
            `Group related steps (e.g. "read+patch foo.ts" as one step) OR commit ` +
            `to the first ${MAX_PLAN_STEPS} now and call set_plan again with the ` +
            `next batch after they're complete.`
        };
      }

      const steps = raw.map((s: any, i: number) => ({
        title: String(s?.title || '').trim().slice(0, 200),
        description: s?.description ? String(s.description).trim().slice(0, 500) : undefined,
        // Optional granularity hints — stored on the step so the prompt
        // injection (Active plan section) can surface them on the focused
        // step. SessionBrain's PlanStep type accepts unknown fields; we
        // attach them via cast to avoid a schema migration for an
        // additive change.
        file: s?.file ? String(s.file).trim().slice(0, 240) : undefined,
        tool: s?.tool ? String(s.tool).trim().slice(0, 80) : undefined,
        status: 'pending' as const,
        order: i + 1
      })).filter((s) => s.title.length > 0);

      if (steps.length === 0) {
        return { success: false, output: '', error: 'set_plan rejected: no steps had a usable title.' };
      }

      brain.setPlanSteps(steps);
      const summary = steps.map(s => {
        const hint = [s.file && `file=${s.file}`, s.tool && `tool=${s.tool}`].filter(Boolean).join(' ');
        return `  ${s.order}. ${s.title}${hint ? `  (${hint})` : ''}`;
      }).join('\n');
      return {
        success: true,
        output:
          `[PLAN_SET] ${steps.length} step(s) registered:\n${summary}\n\n` +
          `Next: start step 1, then call complete_step(1) before moving to step 2.`,
        error: null
      };
    }
  });

  // ── list_pending_tasks ───────────────────────────────────────────
  // Compact read of the brain's plan steps that aren't done. Used by the
  // model on the first turn of a restored session to verify status of
  // prior work BEFORE acting on the user's current message. Returns the
  // smallest useful payload — just titles + status + file refs — so the
  // pending-tasks check doesn't eat the inference budget.
  register({
    name: 'list_pending_tasks',
    description: 'Return pending/in_progress plan steps from the SessionBrain in compact form. Use this on the first turn of a restored session to know what was unfinished, OR mid-session to refresh memory of what is still open. Output is short by design — pair it with grep_file/find_function (micro-context) to verify whether each task was actually completed in the codebase.',
    parameters: {
      type: 'object',
      properties: {},
      required: []
    },
    execute: async () => {
      const brain = brainProvider();
      if (!brain) {
        return { success: true, output: '[PENDING_TASKS] no brain attached', error: null };
      }
      const steps = brain.getPlanSteps();
      const pending = steps.filter(s => s.status === 'pending' || s.status === 'in_progress');
      if (pending.length === 0) {
        return { success: true, output: '[PENDING_TASKS] none', error: null };
      }
      const lines = pending.map((s, i) => {
        const files = (s as any).files && Array.isArray((s as any).files) && (s as any).files.length > 0
          ? ` · files: ${(s as any).files.slice(0, 4).join(', ')}`
          : '';
        return `${i + 1}. [${s.status}] ${s.title}${files}`;
      });
      return {
        success: true,
        output: `[PENDING_TASKS] ${pending.length}\n${lines.join('\n')}`,
        error: null
      };
    }
  });

  // ── complete_step ─────────────────────────────────────────────────
  // Mark the current step done. Used together with set_plan so the model
  // shows visible progress as it works through the plan.
  register({
    name: 'complete_step',
    description:
      'Mark a plan step complete by its order number (1-based) OR by title substring. ' +
      'Call this IMMEDIATELY after the step\'s last successful tool call (e.g. right after the validate_syntax that confirmed the edit). ' +
      'Do NOT batch multiple completions — one call per step. The Active plan section refreshes on the next turn to show the new focused step.',
    parameters: {
      type: 'object',
      properties: {
        order: { type: 'number', description: '1-based step index from set_plan.' },
        title: { type: 'string', description: 'Alternative: substring of the step title.' }
      }
    },
    execute: async (args) => {
      const brain = brainProvider();
      if (!brain) return { success: false, output: '', error: 'Brain not available.' };
      const steps = brain.getPlanSteps();
      if (steps.length === 0) return { success: false, output: '', error: 'No plan registered. Call set_plan first.' };

      const order = Number(args.order);
      const title = String(args.title || '').toLowerCase().trim();
      let target = null;
      if (Number.isFinite(order)) {
        target = steps.find(s => s.order === order) ?? null;
      }
      if (!target && title) {
        target = steps.find(s => s.title.toLowerCase().includes(title)) ?? null;
      }
      if (!target) {
        const list = steps.map(s => `  ${s.order}. [${s.status}] ${s.title}`).join('\n');
        return {
          success: false,
          output: '',
          error: `Step not found. Current plan:\n${list}`
        };
      }
      brain.completeStep(target.id);
      return {
        success: true,
        output: `[STEP_DONE] ${target.order}. ${target.title}`,
        error: null
      };
    }
  });

  // ── validate_syntax ───────────────────────────────────────────────
  // Run the project's tree-sitter / language-specific syntax validator on a
  // file. Language is auto-detected from the extension; supports TS/JS, Python,
  // Rust, Go, Java, C/C++, Ruby, PHP, Swift, Kotlin, Scala, Haskell, Lua,
  // Bash, JSON, HTML, CSS, Markdown, YAML, TOML, SQL, Dart.
  register({
    name: 'validate_syntax',
    description: 'Validate the syntax of a file using a language-aware parser. Call AFTER every write_file/create_file/apply_patch to confirm the result compiles/parses. Returns success:true + parser name on valid, or success:false + error locations.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'File path to validate. Language is auto-detected from the extension.' }
      },
      required: ['path']
    },
    execute: async (args) => {
      const filePath = String(args.path || '').trim();
      if (!filePath) {
        return { success: false, output: '', error: 'validate_syntax requires "path".' };
      }
      try {
        await fs.stat(filePath);
      } catch {
        return { success: false, output: '', error: `File not found: ${filePath}` };
      }
      try {
        const result = await syntaxValidator.validate(filePath);
        if (result.valid) {
          return {
            success: true,
            output: `[SYNTAX_OK] ${filePath} (parser: ${result.parser})${result.output ? '\n' + result.output : ''}`,
            error: null
          };
        }
        const errMsg = result.errors
          .map(e => `${e.line}:${e.column} [${e.type}] ${e.message}`)
          .join('\n');
        return {
          success: false,
          output: result.output || '',
          error: `[SYNTAX_FAIL] ${filePath} (parser: ${result.parser})\n${errMsg}`
        };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'validate_syntax failed' };
      }
    }
  });

  // ── run_tests ─────────────────────────────────────────────────────
  // Project-aware test runner. Detects the project type from the marker files
  // it finds at the cwd root and runs the matching test command. If no test
  // infrastructure is detected, returns an explicit "no tests configured"
  // result instead of failing silently — the model then knows to use run_code
  // with an explicit interpreter invocation as a fallback.
  register({
    name: 'run_tests',
    description: 'Run the project\'s test suite. Auto-detects project type (Node/TS, Python, Rust, Go, Ruby, etc.) and picks the matching test command. Use AFTER mutations + validate_syntax. If the project has no test infrastructure, returns a structured "no_tests" result so you can decide whether to fall back to run_code with a direct interpreter call.',
    parameters: {
      type: 'object',
      properties: {
        scope: { type: 'string', description: 'Optional sub-scope (e.g. file path or test name) to narrow what gets run.' },
        timeoutMs: { type: 'number', description: 'Max wall-clock for the test command. Default 120000 (2 min).' }
      }
    },
    execute: async (args) => {
      const cwd = process.cwd();
      const scope = String(args.scope || '').trim();
      const timeoutMs = Number(args.timeoutMs);
      const maxBuffer = 4 * 1024 * 1024;

      const has = async (rel: string): Promise<boolean> => {
        try { await fs.stat(path.join(cwd, rel)); return true; } catch { return false; }
      };

      let cmd: string | null = null;
      let cmdArgs: string[] = [];
      let detected = 'unknown';

      if (await has('package.json')) {
        detected = 'node';
        // Read package.json to find a test script.
        try {
          const pkg = JSON.parse(await fs.readFile(path.join(cwd, 'package.json'), 'utf-8'));
          const scripts = pkg.scripts || {};
          if (scripts['test:core'] || scripts['test:unit'] || scripts['test']) {
            cmd = 'npm';
            cmdArgs = ['run', scripts['test:core'] ? 'test:core' : scripts['test:unit'] ? 'test:unit' : 'test'];
            if (scope) cmdArgs.push('--', scope);
          }
        } catch { /* fall through */ }
      } else if (await has('pyproject.toml') || await has('pytest.ini') || await has('setup.py')) {
        detected = 'python';
        cmd = 'pytest';
        cmdArgs = scope ? [scope] : [];
      } else if (await has('Cargo.toml')) {
        detected = 'rust';
        cmd = 'cargo';
        cmdArgs = scope ? ['test', scope] : ['test'];
      } else if (await has('go.mod')) {
        detected = 'go';
        cmd = 'go';
        cmdArgs = scope ? ['test', scope] : ['test', './...'];
      } else if (await has('Gemfile')) {
        detected = 'ruby';
        cmd = 'bundle';
        cmdArgs = scope ? ['exec', 'rspec', scope] : ['exec', 'rspec'];
      } else if (await has('composer.json')) {
        detected = 'php';
        cmd = 'composer';
        cmdArgs = scope ? ['test', '--', scope] : ['test'];
      } else if (await has('pom.xml')) {
        detected = 'maven';
        cmd = 'mvn';
        cmdArgs = scope ? ['test', `-Dtest=${scope}`] : ['test'];
      } else if (await has('build.gradle') || await has('build.gradle.kts')) {
        detected = 'gradle';
        cmd = './gradlew';
        cmdArgs = scope ? ['test', '--tests', scope] : ['test'];
      }

      if (!cmd) {
        return {
          success: true,
          output: `[NO_TESTS] No test infrastructure detected at ${cwd}. Detected project type: ${detected}. Fall back to run_code with an explicit interpreter call (e.g. node <file>, python <file>) if you need to verify execution.`,
          error: null
        };
      }

      // BUG-B-08: explicit truncation markers on stdout/stderr so the model
      // knows when an assertion message or root-cause line was cut. Without
      // them the model treated truncated stderr as the full failure trace.
      const STDOUT_CAP = 8000;
      const STDERR_CAP_PASS = 2000;
      const STDERR_CAP_FAIL = 4000;
      const truncate = (raw: string, cap: number): string => {
        if (raw.length <= cap) return raw;
        // Keep both head and tail — the tail usually carries the failing
        // assertion / final summary which is the most diagnostic part.
        const headCap = Math.floor(cap * 0.6);
        const tailCap = cap - headCap - 80;
        const head = raw.slice(0, headCap);
        const tail = tailCap > 0 ? raw.slice(-tailCap) : '';
        const dropped = raw.length - head.length - tail.length;
        return `${head}\n…[truncated ${dropped} chars]…\n${tail}`;
      };

      try {
        const result = await execFileAsync(cmd, cmdArgs, {
          maxBuffer,
          cwd,
          ...(Number.isFinite(timeoutMs) && timeoutMs > 0 ? { timeout: Math.floor(timeoutMs) } : { timeout: 120000 })
        } as any);
        const stdoutShort = truncate(result.stdout || '', STDOUT_CAP);
        const stderrShort = truncate(result.stderr || '', STDERR_CAP_PASS);
        return {
          success: true,
          output: `[TESTS_PASS] ${detected}: ${cmd} ${cmdArgs.join(' ')}\n${stdoutShort}${stderrShort ? '\n--- stderr ---\n' + stderrShort : ''}`,
          error: null
        };
      } catch (error: any) {
        const stdout = truncate((error?.stdout || '').toString(), STDOUT_CAP);
        const stderr = truncate((error?.stderr || '').toString(), STDERR_CAP_FAIL);
        return {
          success: false,
          output: `${stdout}${stderr ? '\n--- stderr ---\n' + stderr : ''}`,
          error: `[TESTS_FAIL] ${detected}: ${cmd} ${cmdArgs.join(' ')} exited ${error?.code ?? '?'}.`
        };
      }
    }
  });
}
