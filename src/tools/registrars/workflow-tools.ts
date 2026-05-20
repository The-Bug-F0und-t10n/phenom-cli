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
    description: 'Record a structured plan for the current task. Call this FIRST for any task involving multiple files or steps — before any read/write. Each step is a short imperative phrase ("read agent.ts", "patch run-tool-loop", "validate syntax", "run tests"). Subsequent turns see the plan and can mark steps complete via complete_step.',
    parameters: {
      type: 'object',
      properties: {
        steps: {
          type: 'array',
          description: 'Ordered list of steps. Each is a short imperative phrase.',
          items: {
            type: 'object',
            properties: {
              title: { type: 'string', description: 'Imperative phrase, ≤80 chars.' },
              description: { type: 'string', description: 'Optional clarifier.' }
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
      const steps = raw.map((s: any, i: number) => ({
        title: String(s?.title || '').trim().slice(0, 200),
        description: s?.description ? String(s.description).trim().slice(0, 500) : undefined,
        status: 'pending' as const,
        order: i + 1
      })).filter((s) => s.title.length > 0);

      if (steps.length === 0) {
        return { success: false, output: '', error: 'set_plan rejected: no steps had a usable title.' };
      }

      brain.setPlanSteps(steps);
      const summary = steps.map(s => `  ${s.order}. ${s.title}`).join('\n');
      return {
        success: true,
        output: `[PLAN_SET] ${steps.length} steps registered:\n${summary}`,
        error: null
      };
    }
  });

  // ── complete_step ─────────────────────────────────────────────────
  // Mark the current step done. Used together with set_plan so the model
  // shows visible progress as it works through the plan.
  register({
    name: 'complete_step',
    description: 'Mark a plan step complete by its order number (1-based) OR by title substring. Use after finishing the step\'s work (and after validate_syntax / run_tests if it was a mutation step).',
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

      try {
        const result = await execFileAsync(cmd, cmdArgs, {
          maxBuffer,
          cwd,
          ...(Number.isFinite(timeoutMs) && timeoutMs > 0 ? { timeout: Math.floor(timeoutMs) } : { timeout: 120000 })
        } as any);
        const stdoutShort = (result.stdout || '').slice(0, 8000);
        const stderrShort = (result.stderr || '').slice(0, 2000);
        return {
          success: true,
          output: `[TESTS_PASS] ${detected}: ${cmd} ${cmdArgs.join(' ')}\n${stdoutShort}${stderrShort ? '\n--- stderr ---\n' + stderrShort : ''}`,
          error: null
        };
      } catch (error: any) {
        const stdout = (error?.stdout || '').toString().slice(0, 8000);
        const stderr = (error?.stderr || '').toString().slice(0, 4000);
        return {
          success: false,
          output: `${stdout}${stderr ? '\n--- stderr ---\n' + stderr : ''}`,
          error: `[TESTS_FAIL] ${detected}: ${cmd} ${cmdArgs.join(' ')} exited ${error?.code ?? '?'}.`
        };
      }
    }
  });
}
