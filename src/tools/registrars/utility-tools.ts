import { promises as fs } from 'fs';
import { spawn } from 'child_process';
import path from 'path';
import type { Tool } from '../../tools.js';
import type { ToolResult } from '../../types.js';

interface RegisterUtilityToolsDeps {
  register: (tool: Tool) => void;
  openBrowser: (url: string, devtools: boolean) => void;
}

const PROJECT_ROOT = path.resolve(process.cwd());

const REFUSE_PATTERNS: Array<{ rx: RegExp; reason: string }> = [
  { rx: /\brm\s+(?:-[A-Za-z]*[rf][A-Za-z]*)\s+(?:\/|~|\$HOME)(?:\s|$)/, reason: 'rm -rf em raiz / $HOME' },
  { rx: /:\(\)\s*\{\s*:\|\s*:&\s*\}\s*;\s*:/,                            reason: 'fork bomb' },
  { rx: /\bmkfs\b|\bdd\s+if=/,                                           reason: 'format / raw-device write' },
  { rx: />\s*\/dev\/(?:sd|nvme|hd)[a-z]\d*/,                             reason: 'redirect para block device' },
  { rx: /\b(?:shutdown|reboot|halt|poweroff)\b/,                         reason: 'comando de power do sistema' }
];

const INTERACTIVE_BINS = new Set([
  'vim','vi','nvim','nano','emacs','pico',
  'less','more','man','info',
  'top','htop','btop','atop',
  'tig','lazygit','ranger','mc',
  'mysql','psql','sqlite3','redis-cli','mongo','mongosh'
]);

function firstBinary(command: string): string | null {
  let s = command.trim();
  while (/^[A-Za-z_][A-Za-z0-9_]*=\S+\s+/.test(s)) s = s.replace(/^[A-Za-z_][A-Za-z0-9_]*=\S+\s+/, '');
  if (/^sudo\s+/.test(s)) s = s.replace(/^sudo\s+/, '');
  const m = s.match(/^([A-Za-z0-9_./-]+)/);
  return m ? path.basename(m[1]) : null;
}

function validateCwd(rawCwd: string): { ok: true; cwd: string } | { ok: false; error: string } {
  const resolved = path.resolve(rawCwd);
  if (resolved !== PROJECT_ROOT && !resolved.startsWith(PROJECT_ROOT + path.sep)) {
    return { ok: false, error: `cwd fora do projeto: ${resolved} (raiz: ${PROJECT_ROOT})` };
  }
  return { ok: true, cwd: resolved };
}

const HEAD_LINES = 200;
const TAIL_LINES = 200;

function truncateByLines(text: string): { text: string; truncated: boolean; droppedLines: number; droppedBytes: number } {
  if (!text) return { text: '', truncated: false, droppedLines: 0, droppedBytes: 0 };
  const lines = text.split('\n');
  if (lines.length <= HEAD_LINES + TAIL_LINES + 1) {
    return { text, truncated: false, droppedLines: 0, droppedBytes: 0 };
  }
  const head = lines.slice(0, HEAD_LINES);
  const tail = lines.slice(lines.length - TAIL_LINES);
  const middle = lines.slice(HEAD_LINES, lines.length - TAIL_LINES);
  const droppedBytes = Buffer.byteLength(middle.join('\n'), 'utf-8');
  return {
    text: [...head, `[... truncated ${middle.length} lines (${droppedBytes} bytes) ...]`, ...tail].join('\n'),
    truncated: true,
    droppedLines: middle.length,
    droppedBytes
  };
}

function composeOutput(
  stdout: string,
  stderr: string,
  exitCode: number | null,
  signal: NodeJS.Signals | null,
  command: string,
  cwd: string,
  durMs: number,
  status: 'ok' | 'fail' | 'timeout' | 'overflow'
): string {
  const out = truncateByLines(stdout.replace(/\s+$/, ''));
  const err = truncateByLines(stderr.replace(/\s+$/, ''));
  const cwdRel = path.relative(PROJECT_ROOT, cwd) || '.';
  const tag =
    status === 'timeout'  ? 'TIMEOUT' :
    status === 'overflow' ? 'OVERFLOW' :
    exitCode === 0        ? 'exit 0'  :
    signal                ? `signal ${signal}` :
                            `exit ${exitCode ?? '?'}`;

  const banner = `$ ${command}    [cwd=${cwdRel} ${tag} ${durMs}ms]`;
  const lines: string[] = [banner];

  if (!out.text && !err.text) {
    lines.push('(no output)');
  } else {
    if (out.text) lines.push(out.text);
    if (err.text) lines.push(out.text ? `--- stderr ---\n${err.text}` : err.text);
  }
  return lines.join('\n');
}

export function registerUtilityTools(deps: RegisterUtilityToolsDeps): void {
  const { register, openBrowser } = deps;

  register({
    name: 'date',
    description: 'Retorna data/hora atual em ISO 8601.',
    parameters: { type: 'object', properties: {}, required: [] },
    execute: async () => ({ success: true, output: new Date().toISOString(), error: null })
  });

  register({
    name: 'run_code',
    description:
      'Execute a shell command via `bash -lc`. Use for: build/test/lint, listing files (ls/find/du), running scripts, inspecting runtime state. ' +
      'NEVER use to read/edit source files — call read_file / apply_patch instead. Prefer git_status / git_diff / git_log over raw `git` here. ' +
      'Constraints: `cwd` MUST be inside the project root (cwd outside it is rejected); interactive TUIs (vim, less, top, psql, ...) are rejected up front because they would hang; output is line-truncated head+tail when long. ' +
      'Pass `stdin` for commands that need piped input. Always exit non-zero to signal failure — the result.success mirrors the exit code. ' +
      'Output is prefixed with a one-line banner `$ <cmd>  [cwd=… exit=… Nms]` and includes a separate `--- stderr ---` block when stderr was non-empty.',
    parameters: {
      type: 'object',
      properties: {
        command:    { type: 'string',  description: 'Comando bash (pipes, &&, redirects suportados)' },
        cwd:        { type: 'string',  description: 'Diretório de trabalho — DEVE estar dentro da raiz do projeto. Padrão: raiz.' },
        stdin:      { type: 'string',  description: 'Texto enviado ao stdin do processo' },
        timeoutMs:  { type: 'number',  description: 'Timeout em ms (1000–300000, padrão 30000)' },
        env:        { type: 'object',  description: 'Variáveis de ambiente extras (chaves devem casar /^[A-Z_][A-Z0-9_]*$/i)' },
        browserUrl: { type: 'string',  description: 'Se informado, abre o navegador nesta URL após o comando bem-sucedido' },
        devtools:   { type: 'boolean', description: 'Abrir devtools com browserUrl (padrão true)' }
      },
      required: ['command']
    },
    execute: async (args) => {
      const command = String(args.command || '').trim();
      if (!command) return { success: false, output: '', error: 'Comando vazio.' };

      for (const { rx, reason } of REFUSE_PATTERNS) {
        if (rx.test(command)) {
          return {
            success: false,
            output: '',
            error: `Recusado (${reason}). Reformule o comando ou execute manualmente fora do agente se realmente necessário.`
          };
        }
      }

      const bin = firstBinary(command);
      if (bin && INTERACTIVE_BINS.has(bin)) {
        return {
          success: false,
          output: '',
          error:
            `Comando '${bin}' é interativo (requer TTY) e travaria o agente. ` +
            `Use o equivalente não-interativo (ex.: vim/nano → apply_patch ou write_file; less/more → cat/head; psql/mysql → adicione -c "<sql>"; top → ps).`
        };
      }

      const rawCwd = args.cwd ? String(args.cwd).trim() : PROJECT_ROOT;
      const guard = validateCwd(rawCwd);
      if (!guard.ok) return { success: false, output: '', error: guard.error };
      const cwd = guard.cwd;

      try {
        const stats = await fs.stat(cwd);
        if (!stats.isDirectory()) return { success: false, output: '', error: `cwd não é diretório: ${cwd}` };
      } catch (e: any) {
        return { success: false, output: '', error: `cwd inválido: ${e.message}` };
      }

      const timeoutMsRaw = Number.parseInt(String(args.timeoutMs ?? 30000), 10);
      const timeoutMs = Number.isFinite(timeoutMsRaw) ? Math.min(Math.max(timeoutMsRaw, 1000), 300000) : 30000;

      const extraEnv = args.env && typeof args.env === 'object' ? args.env : {};
      const env = {
        ...process.env,
        ...Object.fromEntries(
          Object.entries(extraEnv)
            .filter(([k]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(k))
            .map(([k, v]) => [k, String(v)])
        )
      };

      const stdinPayload = args.stdin != null ? String(args.stdin) : null;
      const browserUrl = args.browserUrl ? String(args.browserUrl).trim() : '';
      const devtools = args.devtools !== false;

      const MAX_BYTES_PER_STREAM = 5 * 1024 * 1024;

      const finalResult: ToolResult = await new Promise<ToolResult>((resolve) => {
        const child = spawn('bash', ['-c', command], {
          cwd, env, shell: false,
          stdio: [stdinPayload != null ? 'pipe' : 'ignore', 'pipe', 'pipe']
        });

        let stdout = '';
        let stderr = '';
        let killedForOverflow = false;
        let timedOut = false;
        let settled = false;
        const start = Date.now();

        const finish = (r: ToolResult) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          clearTimeout(killTimer);
          resolve(r);
        };

        const timer = setTimeout(() => {
          timedOut = true;
          child.kill('SIGTERM');
        }, timeoutMs);

        const killTimer = setTimeout(() => {
          if (!settled && (timedOut || killedForOverflow)) child.kill('SIGKILL');
        }, timeoutMs + 1000);

        const onChunk = (which: 'stdout' | 'stderr') => (chunk: Buffer | string) => {
          const text = String(chunk);
          if (which === 'stdout') stdout += text; else stderr += text;
          const cur = which === 'stdout' ? stdout : stderr;
          if (!killedForOverflow && Buffer.byteLength(cur, 'utf-8') > MAX_BYTES_PER_STREAM) {
            killedForOverflow = true;
            child.kill('SIGTERM');
          }
        };

        child.stdout?.on('data', onChunk('stdout'));
        child.stderr?.on('data', onChunk('stderr'));

        if (stdinPayload != null && child.stdin) {
          child.stdin.write(stdinPayload);
          child.stdin.end();
        }

        child.on('error', (e) => {
          finish({ success: false, output: stdout, error: `spawn falhou: ${e.message}` });
        });

        child.on('close', (code, signal) => {
          const durMs = Date.now() - start;
          const status: 'ok' | 'fail' | 'timeout' | 'overflow' =
            timedOut ? 'timeout' :
            killedForOverflow ? 'overflow' :
            code === 0 ? 'ok' : 'fail';
          const combined = composeOutput(stdout, stderr, code, signal, command, cwd, durMs, status);

          if (status === 'timeout') {
            finish({ success: false, output: combined, error: `Timeout após ${timeoutMs}ms.` });
            return;
          }
          if (status === 'overflow') {
            finish({ success: false, output: combined, error: `Saída excedeu ${MAX_BYTES_PER_STREAM} bytes em um stream — comando abortado.` });
            return;
          }
          if (status === 'ok') {
            finish({ success: true, output: combined, error: null });
            return;
          }
          finish({
            success: false,
            output: combined,
            error: signal ? `Comando interrompido por sinal ${signal}` : `Exit code ${code}.`
          });
        });
      });

      if (browserUrl && finalResult.success) {
        openBrowser(browserUrl, devtools);
      }
      return finalResult;
    }
  });
}
