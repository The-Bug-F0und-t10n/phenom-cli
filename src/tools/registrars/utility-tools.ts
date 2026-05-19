import { promises as fs } from 'fs';
import { spawn } from 'child_process';
import type { Tool } from '../../tools.js';
import type { ToolResult } from '../../types.js';

interface RegisterUtilityToolsDeps {
  register: (tool: Tool) => void;
  openBrowser: (url: string, devtools: boolean) => void;
}

export function registerUtilityTools(deps: RegisterUtilityToolsDeps): void {
  const { register, openBrowser } = deps;

  register({
    name: 'date',
    description: 'Retorna data/hora atual',
    parameters: {
      type: 'object',
      properties: {},
      required: []
    },
    execute: async () => {
      const now = new Date().toISOString();
      return { success: true, output: now, error: null };
    }
  });

  register({
    name: 'run_code',
    description: 'Executa comando shell com suporte a pipes, redirecionamento e cwd',
    parameters: {
      type: 'object',
      properties: {
        command: {
          type: 'string',
          description: 'Comando shell a executar'
        },
        cwd: {
          type: 'string',
          description: 'Diretório de trabalho (padrão: diretório atual)'
        },
        timeoutMs: {
          type: 'number',
          description: 'Timeout em milissegundos (1000-300000, padrão: 30000)'
        },
        env: {
          type: 'object',
          description: 'Variáveis de ambiente adicionais'
        },
        browserUrl: {
          type: 'string',
          description: 'Se fornecido, abre o navegador padrão nesta URL após iniciar o servidor. Ex: http://localhost:5173'
        },
        devtools: {
          type: 'boolean',
          description: 'Abrir DevTools no navegador (padrão: true, usado apenas com browserUrl)'
        }
      },
      required: ['command']
    },
    execute: async (args) => {
      const command = String(args.command || '').trim();
      if (!command) {
        return { success: false, output: '', error: 'Comando vazio' };
      }

      const cwd = String(args.cwd || process.cwd()).trim() || process.cwd();
      const timeoutMsRaw = Number.parseInt(String(args.timeoutMs || 30000), 10);
      const timeoutMs = Number.isFinite(timeoutMsRaw) ? Math.min(Math.max(timeoutMsRaw, 1000), 300000) : 30000;
      const extraEnv = args.env && typeof args.env === 'object' ? args.env : {};
      const browserUrl = args.browserUrl ? String(args.browserUrl).trim() : '';
      const devtools = args.devtools !== false;

      try {
        const stats = await fs.stat(cwd);
        if (!stats.isDirectory()) {
          return { success: false, output: '', error: `cwd não é diretório: ${cwd}` };
        }
      } catch (error: any) {
        return { success: false, output: '', error: `cwd inválido: ${error.message}` };
      }

      const env = {
        ...process.env,
        ...Object.fromEntries(
          Object.entries(extraEnv)
            .filter(([key]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(key))
            .map(([key, value]) => [key, String(value)])
        )
      };

      return await new Promise<ToolResult>((resolve) => {
        const child = spawn('bash', ['-lc', command], {
          cwd,
          env,
          shell: false,
          stdio: ['ignore', 'pipe', 'pipe']
        });

        let stdout = '';
        let stderr = '';
        let settled = false;

        const maxOutputBytes = 5 * 1024 * 1024;
        const finish = (result: ToolResult) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(result);
        };

        const timer = setTimeout(() => {
          child.kill('SIGTERM');
          finish({
            success: false,
            output: stdout,
            error: `Timeout após ${timeoutMs}ms`
          });
        }, timeoutMs);

        child.stdout.on('data', (chunk) => {
          stdout += String(chunk);
          if (Buffer.byteLength(stdout, 'utf-8') > maxOutputBytes) {
            child.kill('SIGTERM');
            finish({
              success: false,
              output: stdout,
              error: 'Saída excedeu limite de 5MB'
            });
          }
        });

        child.stderr.on('data', (chunk) => {
          stderr += String(chunk);
          if (Buffer.byteLength(stderr, 'utf-8') > maxOutputBytes) {
            child.kill('SIGTERM');
            finish({
              success: false,
              output: `${stdout}${stderr}`,
              error: 'Saída de erro excedeu limite de 5MB'
            });
          }
        });

        child.on('error', (error) => {
          finish({ success: false, output: stdout, error: error.message });
        });

        child.on('close', (code, signal) => {
          const combined = [stdout.trimEnd(), stderr.trimEnd()].filter(Boolean).join('\n');
          if (code === 0) {
            finish({ success: true, output: combined, error: null });
            return;
          }
          finish({
            success: false,
            output: combined,
            error: signal ? `Comando interrompido por sinal ${signal}` : `Comando falhou com exit code ${code}`
          });
        });
      }).then(result => {
        if (browserUrl && result.success) {
          openBrowser(browserUrl, devtools);
        }
        return result;
      });
    }
  });
}
