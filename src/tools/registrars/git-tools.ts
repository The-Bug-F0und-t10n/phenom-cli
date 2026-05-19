import type { SimpleGit } from 'simple-git';
import { promises as fs } from 'fs';
import path from 'path';
import type { Tool } from '../../tools.js';

interface RegisterGitToolsDeps {
  register: (tool: Tool) => void;
  git: SimpleGit;
}

export function registerGitTools(deps: RegisterGitToolsDeps): void {
  const { register, git } = deps;
  const workspaceRoot = process.cwd();

  function resolveWorkspacePath(inputPath: string): { absolutePath: string } | { error: string } {
    const raw = String(inputPath || '').trim();
    if (!raw) return { error: 'Path not provided' };

    const absolutePath = path.resolve(workspaceRoot, raw);
    const rel = path.relative(workspaceRoot, absolutePath);
    const outsideWorkspace = rel.startsWith('..') || path.isAbsolute(rel);

    if (outsideWorkspace) {
      return { error: `Path outside workspace is blocked: ${raw}` };
    }
    return { absolutePath };
  }

  register({
    name: 'git_status',
    description: 'Mostra status do repositório',
    parameters: {
      type: 'object',
      properties: {},
      required: []
    },
    execute: async () => {
      try {
        const status = await git.status();
        const output = `Branch: ${status.current}\nModificados: ${status.modified.length}\nNão rastreados: ${status.not_added.length}`;
        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'git_diff',
    description: 'Mostra diferenças',
    parameters: {
      type: 'object',
      properties: {
        files: {
          type: 'array',
          description: 'Lista de arquivos para ver diff (opcional)',
          items: {
            type: 'string'
          }
        }
      },
      required: []
    },
    execute: async (args) => {
      try {
        const diff = await git.diff(args.files || []);
        return { success: true, output: diff || 'Sem mudanças', error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'git_log',
    description: 'Mostra histórico de commits',
    parameters: {
      type: 'object',
      properties: {
        count: {
          type: 'number',
          description: 'Número de commits a mostrar (padrão: 10)'
        }
      },
      required: []
    },
    execute: async (args) => {
      try {
        const log = await git.log({ maxCount: args.count || 10 });
        const output = log.all.map(c => `${c.hash.substring(0, 7)} - ${c.message}`).join('\n');
        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'git_add',
    description: 'Adiciona arquivos ao stage',
    parameters: {
      type: 'object',
      properties: {
        files: {
          type: 'string',
          description: 'Arquivos a adicionar (padrão: "." para todos)'
        }
      },
      required: []
    },
    execute: async (args) => {
      try {
        await git.add(args.files || '.');
        return { success: true, output: 'Arquivos adicionados', error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'git_commit',
    description: 'Cria commit',
    parameters: {
      type: 'object',
      properties: {
        message: {
          type: 'string',
          description: 'Mensagem do commit'
        }
      },
      required: ['message']
    },
    execute: async (args) => {
      try {
        await git.commit(args.message);
        return { success: true, output: `Commit criado: ${args.message}`, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'delete_file',
    description: 'Delete a file. Only works on files (not directories). Path must be relative or absolute within CWD.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Path of the file to delete' }
      },
      required: ['path']
    },
    execute: async (args) => {
      const safePath = resolveWorkspacePath(String(args.path || ''));
      if ('error' in safePath) return { success: false, output: '', error: safePath.error };
      const target = safePath.absolutePath;
      try {
        const stat = await fs.stat(target);
        if (!stat.isFile()) return { success: false, output: '', error: `Not a file: ${target}` };
        await fs.unlink(target);
        return { success: true, output: `Deleted: ${target}`, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });

  register({
    name: 'delete_dir',
    description: 'Delete a directory and all its contents recursively. Use with care.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Directory path to delete' }
      },
      required: ['path']
    },
    execute: async (args) => {
      const rawTarget = String(args.path || '').trim();
      const safePath = resolveWorkspacePath(rawTarget);
      if ('error' in safePath) return { success: false, output: '', error: safePath.error };
      const target = safePath.absolutePath;
      if (!rawTarget || rawTarget === '.' || rawTarget === '/' || target === workspaceRoot) {
        return { success: false, output: '', error: 'Unsafe path: ' + rawTarget };
      }
      try {
        const stat = await fs.stat(target);
        if (!stat.isDirectory()) return { success: false, output: '', error: `Not a directory: ${target}` };
        await fs.rm(target, { recursive: true, force: true });
        return { success: true, output: `Deleted directory: ${target}`, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: error.message };
      }
    }
  });
}
