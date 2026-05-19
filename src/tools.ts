import { execFile, spawn } from 'child_process';
import { promisify } from 'util';
import simpleGit, { SimpleGit } from 'simple-git';
import { ToolResult } from './types.js';
import { SemanticSearch } from './semantic-search.js';
import { SyntaxValidator } from './syntax-validator.js';
import { registerFilesystemTools } from './tools/registrars/filesystem-tools.js';
import { registerGitTools } from './tools/registrars/git-tools.js';
import { registerNavigationTools } from './tools/registrars/navigation-tools.js';
import { registerSearchTools } from './tools/registrars/search-tools.js';
import { registerUtilityTools } from './tools/registrars/utility-tools.js';

const execFileAsync = promisify(execFile);

export interface Tool {
  name: string;
  description: string;
  parameters?: {
    type: 'object';
    properties: Record<string, any>;
    required?: string[];
  };
  execute: (args: Record<string, any>) => Promise<ToolResult>;
}

export class ToolSystem {
  private tools: Map<string, Tool>;
  private git: SimpleGit;
  private search: SemanticSearch;
  private syntaxValidator: SyntaxValidator;

  constructor() {
    this.tools = new Map();
    this.git = simpleGit();
    this.search = new SemanticSearch();
    this.syntaxValidator = new SyntaxValidator();
    this.registerTools();
  }

  private async validateSyntax(filePath: string): Promise<{ valid: boolean; output: string; error: string | null }> {
    const result = await this.syntaxValidator.validate(filePath);
    
    return {
      valid: result.valid,
      output: result.output,
      error: result.valid ? null : result.errors.map(e => `${e.line}:${e.column} - ${e.message}`).join('\n')
    };
  }

  private registerTools(): void {
    registerFilesystemTools({
      register: this.register.bind(this),
      validateSyntax: this.validateSyntax.bind(this)
    });

    registerSearchTools({
      register: this.register.bind(this),
      search: this.search,
      execFileAsync
    });

    registerNavigationTools({
      register: this.register.bind(this),
      execFileAsync
    });

    registerGitTools({
      register: this.register.bind(this),
      git: this.git
    });

    registerUtilityTools({
      register: this.register.bind(this),
      openBrowser: this.openBrowser.bind(this)
    });
  }
  private openBrowser(url: string, devtools: boolean): void {
    const urlStr = url.startsWith('http') ? url : `http://${url}`;
    const plat = process.platform;
    const isChrome = plat === 'linux' && (process.env.BROWSER?.includes('chrome') || process.env.BROWSER?.includes('chromium'));

    let cmd = '';
    let args: string[] = [];
    if (plat === 'linux') {
      if (devtools && isChrome && process.env.BROWSER) {
        cmd = 'bash';
        args = ['-lc', `$BROWSER --auto-open-devtools-for-tabs '${urlStr}' >/dev/null 2>&1 &`];
      } else if (devtools) {
        cmd = 'bash';
        args = ['-lc', `chromium --auto-open-devtools-for-tabs '${urlStr}' 2>/dev/null || google-chrome --auto-open-devtools-for-tabs '${urlStr}' 2>/dev/null || xdg-open '${urlStr}' &`];
      } else {
        cmd = 'xdg-open';
        args = [urlStr];
      }
    } else if (plat === 'darwin') {
      if (devtools) {
        cmd = 'bash';
        args = ['-lc', `open -a 'Google Chrome' --args --auto-open-devtools-for-tabs '${urlStr}' 2>/dev/null || open '${urlStr}'`];
      } else {
        cmd = 'open';
        args = [urlStr];
      }
    } else if (plat === 'win32') {
      cmd = 'cmd';
      args = ['/c', `start "" msedge --auto-open-devtools-for-tabs "${urlStr}" 2>nul || start "" "${urlStr}"`];
    }

    if (cmd) {
      spawn(cmd, args, { detached: true, stdio: 'ignore' }).unref();
    }
  }

  register(tool: Tool): void {
    this.tools.set(tool.name, tool);
  }

  private normalizeToolArgs(toolName: string, args: Record<string, any>): Record<string, any> {
    // BUG-08 fix: single authoritative normalization point (Agent's version removed).
    let normalized = args && typeof args === 'object' ? { ...args } : {};

    // Unwrap LLM wrapper patterns: {"arguments": {...}} or {"args": {...}}
    if (normalized.arguments && typeof normalized.arguments === 'object' && !Array.isArray(normalized.arguments)) {
      normalized = { ...normalized.arguments };
    } else if (normalized.args && typeof normalized.args === 'object' && !Array.isArray(normalized.args)) {
      normalized = { ...normalized.args };
    }

    const pathTools = ['read_file', 'write_file', 'create_file', 'apply_patch', 'path_exists', 'list_dir'];
    const pathAliases = ['file_path', 'filepath', 'filePath', 'target', 'filename', 'file_name', 'fileName', 'file', 'source', 'src', 'dest', 'destination', 'location', 'output', 'output_path', 'outputPath', 'pathname', 'path_name', 'pathName'];
    if (pathTools.includes(toolName)) {
      for (const alias of pathAliases) {
        if (normalized[alias] && !normalized.path) {
          normalized.path = normalized[alias];
        }
      }
    }

    const contentAliases = ['data', 'text', 'code', 'body', 'source', 'contents', 'input'];
    if (toolName === 'write_file' || toolName === 'create_file') {
      for (const alias of contentAliases) {
        if (normalized[alias] && !normalized.content) {
          normalized.content = normalized[alias];
        }
      }
    }

    if (toolName === 'run_code' && normalized.cmd && !normalized.command) {
      normalized.command = normalized.cmd;
    }

    if (toolName === 'search_code' && normalized.pattern && !normalized.query) {
      normalized.query = normalized.pattern;
    }

    if (toolName === 'web_search' && normalized.q && !normalized.query) {
      normalized.query = normalized.q;
    }

    if (toolName === 'apply_patch') {
      // Unified diff in `patch` field → convert to operations
      if (normalized.patch && typeof normalized.patch === 'string') {
        if (normalized.patch.includes('--- ') || normalized.patch.includes('@@ ')) {
          const parsed = this.parseUnifiedDiff(normalized.patch);
          if (parsed) {
            if (parsed.path && !normalized.path) normalized.path = parsed.path;
            if (parsed.operations.length > 0 && !normalized.operations) {
              normalized.operations = parsed.operations;
            }
          }
        } else if (!normalized.patch.includes('\n') && !normalized.path) {
          normalized.path = normalized.patch;
        }
        delete normalized.patch;
      }

      // `ops` alias for `operations`
      if (Array.isArray(normalized.ops) && !Array.isArray(normalized.operations)) {
        normalized.operations = normalized.ops;
        delete normalized.ops;
      }

      // Line-range aliases
      if (normalized.start_line && !normalized.startLine) normalized.startLine = normalized.start_line;
      if (normalized.end_line && !normalized.endLine) normalized.endLine = normalized.end_line;
      if (normalized.start && !normalized.startLine) normalized.startLine = normalized.start;
      if (normalized.end && !normalized.endLine) normalized.endLine = normalized.end;

      // BUG-F fix: normalize operation field name. Schema exposes `search`; execute reads
      // `find ?? search`. Keep `search` as the canonical name, also set `find` for compat.
      if (Array.isArray(normalized.operations)) {
        normalized.operations = normalized.operations.map((op: any) => {
          if (!op) return op;
          // Both names accepted; if only `find` is present, mirror it to `search` too.
          if (op.find && !op.search) return { ...op, search: op.find };
          return op;
        });
      }
    }

    return normalized;
  }

  private parseUnifiedDiff(patch: string): { path: string; operations: Array<{ search: string; replace: string }> } | null {
    const lines = patch.split('\n');
    let filePath = '';

    for (const line of lines) {
      const m = line.match(/^---\s+(?:a\/)?(.+)/);
      if (m) { filePath = m[1].trim(); break; }
    }
    if (!filePath) {
      for (const line of lines) {
        const m = line.match(/^\+\+\+\s+(?:b\/)?(.+)/);
        if (m) { filePath = m[1].trim(); break; }
      }
    }
    if (!filePath) return null;

    const operations: Array<{ search: string; replace: string }> = [];
    let i = 0;
    while (i < lines.length) {
      const hdr = lines[i].match(/^@@\s+-\d+(?:,\d+)?\s+\+\d+(?:,\d+)?\s+@@/);
      if (hdr) {
        i++;
        const searchLines: string[] = [];
        const replaceLines: string[] = [];
        while (i < lines.length && !lines[i].startsWith('@@ ')) {
          const line = lines[i];
          if (line.startsWith('\\ ')) { i++; continue; }
          if (line.startsWith('-')) { searchLines.push(line.slice(1)); }
          else if (line.startsWith('+')) { replaceLines.push(line.slice(1)); }
          else if (line.startsWith(' ')) {
            searchLines.push(line.slice(1));
            replaceLines.push(line.slice(1));
          }
          i++;
        }
        if (searchLines.length > 0 || replaceLines.length > 0) {
          operations.push({ search: searchLines.join('\n'), replace: replaceLines.join('\n') });
        }
      } else { i++; }
    }

    return { path: filePath, operations };
  }

  async execute(toolName: string, args: Record<string, any>): Promise<ToolResult> {
    const tool = this.tools.get(toolName);
    
    if (!tool) {
      return {
        success: false,
        output: '',
        error: `Tool '${toolName}' não encontrada`
      };
    }

    try {
      const normalizedArgs = this.normalizeToolArgs(toolName, args);
      return await tool.execute(normalizedArgs);
    } catch (error: any) {
      return {
        success: false,
        output: '',
        error: error.message
      };
    }
  }

  listTools(): Tool[] {
    return Array.from(this.tools.values());
  }

  getToolDefinitions(): any[] {
    return this.listTools().map(tool => ({
      type: 'function',
      function: {
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters || {
          type: 'object',
          properties: {},
          required: []
        }
      }
    }));
  }

  getTool(name: string): Tool | undefined {
    return this.tools.get(name);
  }

  generateUnifiedDiff(original: string, updated: string, filepath: string): string {
    const originalLines = original.split('\n');
    const updatedLines = updated.split('\n');
    const diff: string[] = [`--- ${filepath}`, `+++ ${filepath}`];
    let i = 0, j = 0;

    while (i < originalLines.length || j < updatedLines.length) {
      while (i < originalLines.length && j < updatedLines.length && originalLines[i] === updatedLines[j]) {
        i++; j++;
      }
      if (i >= originalLines.length && j >= updatedLines.length) break;

      const contextBefore = Math.max(0, i - 3);
      const contextBeforeLines = originalLines.slice(contextBefore, i);
      let endI = i, endJ = j;

      while (endI < originalLines.length && endJ < updatedLines.length) {
        if (originalLines[endI] === updatedLines[endJ]) {
          let match = true;
          for (let k = 1; k < 3 && endI + k < originalLines.length && endJ + k < updatedLines.length; k++) {
            if (originalLines[endI + k] !== updatedLines[endJ + k]) { match = false; break; }
          }
          if (match) break;
        }
        if (endI < originalLines.length) endI++;
        if (endJ < updatedLines.length) endJ++;
      }

      const contextAfterLines = originalLines.slice(endI, Math.min(originalLines.length, endI + 3));
      const oldCount = endI - contextBefore + contextAfterLines.length;
      const newCount = endJ - contextBefore + contextAfterLines.length;
      diff.push(`@@ -${contextBefore + 1},${oldCount} +${contextBefore + 1},${newCount} @@`);
      contextBeforeLines.forEach(l => diff.push(` ${l}`));
      for (let k = i; k < endI; k++) diff.push(`-${originalLines[k]}`);
      for (let k = j; k < endJ; k++) diff.push(`+${updatedLines[k]}`);
      contextAfterLines.forEach(l => diff.push(` ${l}`));
      i = endI; j = endJ;
    }

    return diff.join('\n');
  }
}
