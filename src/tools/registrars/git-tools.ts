import type { SimpleGit } from 'simple-git';
import { promises as fs } from 'fs';
import path from 'path';
import type { Tool, } from '../../tools.js';
import type { ToolResult } from '../../types.js';

interface RegisterGitToolsDeps {
  register: (tool: Tool) => void;
  git: SimpleGit;
}

// "not a git repository" message we keep seeing in non-git workspaces. The
// model would loop on git_* tools because each one returned the raw fatal
// message and the model couldn't tell it was a workspace-wide condition. We
// memoise the verdict once per process so the second call costs nothing and
// returns a directive that tells the model to stop trying git tools.
let nonGitWorkspaceCached: boolean | null = null;

function isNotARepoError(message: string): boolean {
  return /not a git repository|fatal:.+git/i.test(message);
}

async function ensureGitRepoOrSkip(git: SimpleGit): Promise<ToolResult | null> {
  if (nonGitWorkspaceCached === true) {
    return {
      success: false,
      output: '',
      error:
        'WORKSPACE_NOT_GIT: este diretório não é um repositório git. NÃO chame git_* (git_status, git_diff, git_log, git_*) novamente nesta sessão — eles vão falhar idênticos. Use list_dir, grep_file, find_function, read_file. Se precisar inicializar git, peça ao usuário ou use run_code com `git init` explicitamente.'
    };
  }
  if (nonGitWorkspaceCached === false) return null;
  // First call: probe. checkIsRepo() is one fs.stat, no shell-out.
  try {
    const isRepo = await git.checkIsRepo();
    nonGitWorkspaceCached = !isRepo;
    if (isRepo) return null;
    return {
      success: false,
      output: '',
      error:
        'WORKSPACE_NOT_GIT: este diretório não é um repositório git. NÃO chame git_* novamente nesta sessão. Use list_dir / grep_file / find_function / read_file.'
    };
  } catch {
    // Probe itself failed — assume not a repo, cache, and surface clearly.
    nonGitWorkspaceCached = true;
    return {
      success: false,
      output: '',
      error: 'WORKSPACE_NOT_GIT: probe falhou. Trate como não-git e use list_dir / grep_file no lugar.'
    };
  }
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
      const skip = await ensureGitRepoOrSkip(git);
      if (skip) return skip;
      try {
        const status = await git.status();
        const output = `Branch: ${status.current}\nModificados: ${status.modified.length}\nNão rastreados: ${status.not_added.length}`;
        return { success: true, output, error: null };
      } catch (error: any) {
        if (isNotARepoError(error?.message || '')) {
          nonGitWorkspaceCached = true;
          return (await ensureGitRepoOrSkip(git))!;
        }
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
      const skip = await ensureGitRepoOrSkip(git);
      if (skip) return skip;
      try {
        const diff = await git.diff(args.files || []);
        return { success: true, output: diff || 'Sem mudanças', error: null };
      } catch (error: any) {
        if (isNotARepoError(error?.message || '')) {
          nonGitWorkspaceCached = true;
          return (await ensureGitRepoOrSkip(git))!;
        }
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
      const skip = await ensureGitRepoOrSkip(git);
      if (skip) return skip;
      try {
        const log = await git.log({ maxCount: args.count || 10 });
        const output = log.all.map(c => `${c.hash.substring(0, 7)} - ${c.message}`).join('\n');
        return { success: true, output, error: null };
      } catch (error: any) {
        if (isNotARepoError(error?.message || '')) {
          nonGitWorkspaceCached = true;
          return (await ensureGitRepoOrSkip(git))!;
        }
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
      const skip = await ensureGitRepoOrSkip(git);
      if (skip) return skip;
      try {
        await git.add(args.files || '.');
        return { success: true, output: 'Arquivos adicionados', error: null };
      } catch (error: any) {
        if (isNotARepoError(error?.message || '')) {
          nonGitWorkspaceCached = true;
          return (await ensureGitRepoOrSkip(git))!;
        }
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
      const skip = await ensureGitRepoOrSkip(git);
      if (skip) return skip;
      try {
        await git.commit(args.message);
        return { success: true, output: `Commit criado: ${args.message}`, error: null };
      } catch (error: any) {
        if (isNotARepoError(error?.message || '')) {
          nonGitWorkspaceCached = true;
          return (await ensureGitRepoOrSkip(git))!;
        }
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
