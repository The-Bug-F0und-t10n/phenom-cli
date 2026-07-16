import { promises as fs } from 'fs';
import * as path from 'path';
import type { Tool } from '../../tools.js';

/**
 * Project-awareness tools designed specifically to compensate for the
 * 7B-class ceiling on holding a project's mental model.
 *
 * Background: a 7B coder model edits well at the function level but loses
 * the architectural picture quickly — it forgets which file owns what,
 * invents import paths, and breaks conventions it can't see. These tools
 * externalise that knowledge as cheap lookups so the model consults instead
 * of guessing.
 *
 *   project_map  — compact tree + per-file public exports + auto-detected
 *                  conventions. Refreshed via a short TTL cache so the
 *                  model can call it freely without re-walking the FS.
 *   who_calls    — find callers of a symbol, with snippets. Lets the model
 *                  reason about the blast-radius of a rename or signature
 *                  change before committing the edit.
 *
 * Both tools are READ-ONLY. They never mutate the FS and never shell out
 * beyond `ripgrep`. Safe to expose to the model without further gating.
 *
 * Budget discipline: project_map output is hard-capped so it never blows
 * the context window. The cap is generous but firm — a project with 500
 * source files will get a truncated tree, not a 50 KB dump.
 */

interface RegisterProjectToolsDeps {
  register: (tool: Tool) => void;
  execFileAsync: (
    file: string,
    args: string[],
    options?: { maxBuffer?: number }
  ) => Promise<{ stdout: string; stderr: string }>;
}

const MAP_CACHE_TTL_MS = 30_000;
const MAP_MAX_OUTPUT_CHARS = 6000;
const MAP_MAX_FILES_LISTED = 80;
const WHO_CALLS_MAX_HITS = 25;

const SOURCE_EXTENSIONS = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
  '.py', '.go', '.rs', '.java', '.kt',
  '.rb', '.php', '.cs', '.swift', '.lua'
]);

const SKIP_DIR_NAMES = new Set([
  'node_modules', 'dist', 'build', 'out', '.git', '.next', '.nuxt',
  'target', '__pycache__', '.venv', 'venv', '.pytest_cache',
  'coverage', '.cache', '.turbo', 'vendor', '.mypy_cache',
  '.phenom-context', '.phenom-skills', '.phenom-sessions',
  // Read-only vendored source clones the project keeps for reference. Per
  // project convention these are NOT user code — listing them dominates
  // the tree and drowns the actual project shape.
  '.reference'
]);

interface ProjectMapCacheEntry {
  root: string;
  builtAt: number;
  output: string;
}

let mapCache: ProjectMapCacheEntry | null = null;

export function registerProjectTools(deps: RegisterProjectToolsDeps): void {
  const { register, execFileAsync } = deps;

  register({
    name: 'project_map',
    description:
      'High-level project map: directory tree (top-level), main config files detected, ' +
      'and the public exports of each source file. Use this FIRST when you need to find ' +
      'what file owns a feature, choose where to add new code, or understand the codebase ' +
      'shape. Output is compact (~1.5k tokens) and cached for 30 seconds. Always prefer ' +
      'this over walking the filesystem with list_dir.',
    parameters: {
      type: 'object',
      properties: {
        root: {
          type: 'string',
          description: 'Diretório raiz (padrão: cwd). Use o padrão a menos que você precise mapear um subprojeto específico.'
        },
        refresh: {
          type: 'boolean',
          description: 'Se true, ignora cache e remapeia. Use somente após edições estruturais grandes.'
        }
      }
    },
    execute: async (args) => {
      try {
        const root = path.resolve(String(args.root || process.cwd()));
        const refresh = args.refresh === true;

        // Cache hit: same root, within TTL, not forced refresh. The cache
        // is deliberately a single slot — the agent almost always works in
        // one project at a time, so the simpler invalidation wins.
        if (
          !refresh &&
          mapCache &&
          mapCache.root === root &&
          Date.now() - mapCache.builtAt < MAP_CACHE_TTL_MS
        ) {
          return {
            success: true,
            output: mapCache.output + '\n\n[cache hit; pass refresh=true to rebuild]',
            error: null
          };
        }

        const exists = await fs.stat(root).then(s => s.isDirectory()).catch(() => false);
        if (!exists) {
          return { success: false, output: '', error: `Não é um diretório: ${root}` };
        }

        const output = await buildProjectMap(root, execFileAsync);
        mapCache = { root, builtAt: Date.now(), output };
        return { success: true, output, error: null };
      } catch (error: any) {
        return { success: false, output: '', error: String(error?.message || error) };
      }
    }
  });

  register({
    name: 'who_calls',
    description:
      'Find callers / references of a symbol (function, class, const) across the project. ' +
      'Returns up to 25 hits with file:line and a short snippet. Use this BEFORE renaming or ' +
      'changing the signature of any exported symbol — it tells you the blast radius of the edit. ' +
      'Excludes the definition site itself when possible.',
    parameters: {
      type: 'object',
      properties: {
        symbol: {
          type: 'string',
          description: 'Nome exato do símbolo a procurar (case-sensitive, word boundary).'
        },
        root: {
          type: 'string',
          description: 'Raiz da busca (padrão: cwd).'
        }
      },
      required: ['symbol']
    },
    execute: async (args) => {
      try {
        const symbol = String(args.symbol || '').trim();
        if (!symbol) {
          return { success: false, output: '', error: 'Símbolo não fornecido' };
        }
        if (!/^[A-Za-z_$][\w$]*$/.test(symbol)) {
          return { success: false, output: '', error: `Símbolo inválido (esperado identificador): ${symbol}` };
        }

        const root = path.resolve(String(args.root || process.cwd()));
        const output = await findCallers(symbol, root, execFileAsync);
        return { success: true, output, error: null };
      } catch (error: any) {
        if (error?.code === 'ENOENT') {
          return { success: false, output: '', error: 'rg (ripgrep) não encontrado no PATH' };
        }
        return { success: false, output: '', error: String(error?.message || error) };
      }
    }
  });
}

async function buildProjectMap(
  root: string,
  execFileAsync: RegisterProjectToolsDeps['execFileAsync']
): Promise<string> {
  const sections: string[] = [];

  sections.push(`# Project map`);
  sections.push(`root: ${root}`);

  // 1) Detected project type / tooling. Reading 4-5 known config files is
  //    cheaper than parsing the full tree and gives the model the single
  //    most useful signal: what stack are we in.
  const detected = await detectProjectKind(root);
  if (detected.length > 0) {
    sections.push('\n## Stack');
    for (const line of detected) sections.push(`- ${line}`);
  }

  // Section order favours the most useful, smallest-first so the hard cap
  // (MAP_MAX_OUTPUT_CHARS) only ever truncates the tree, which is the
  // section the model can recover from cheapest (it can list_dir on demand).

  // 2) Recent activity. Tiny (~300 chars) and high-signal — usually
  //    relevant context for whatever the user is about to ask about.
  const recent = await listRecentChanges(root, execFileAsync, 6);
  if (recent.length > 0) {
    sections.push('\n## Recent commits');
    for (const line of recent) sections.push(`- ${line}`);
  }

  // 3) Per-file public exports. The single most useful piece for "where do
  //    I add X" — the model sees the surface area of each file without
  //    reading it. Bounded by MAP_MAX_FILES_LISTED to stay predictable.
  const exportsByFile = await collectExports(root, execFileAsync);
  if (exportsByFile.size > 0) {
    sections.push('\n## Public exports');
    let listed = 0;
    let truncated = 0;
    for (const [file, exps] of exportsByFile) {
      if (listed >= MAP_MAX_FILES_LISTED) {
        truncated++;
        continue;
      }
      const relPath = path.relative(root, file) || file;
      sections.push(`- ${relPath}: ${exps.slice(0, 8).join(', ')}${exps.length > 8 ? ` (+${exps.length - 8})` : ''}`);
      listed++;
    }
    if (truncated > 0) {
      sections.push(`- … +${truncated} more files (use list_dir or find_function to drill in)`);
    }
  }

  // 4) Top-level layout (depth 2). Last because it's the most expendable
  //    section — the model can always call list_dir if the tree was cut.
  const tree = await buildShallowTree(root, 2);
  if (tree.length > 0) {
    sections.push('\n## Top-level layout');
    for (const line of tree) sections.push(line);
  }

  // Hard cap so even a pathological project can't blow the window.
  let output = sections.join('\n');
  if (output.length > MAP_MAX_OUTPUT_CHARS) {
    output = output.slice(0, MAP_MAX_OUTPUT_CHARS) + '\n\n[truncated to ' + MAP_MAX_OUTPUT_CHARS + ' chars]';
  }
  return output;
}

async function detectProjectKind(root: string): Promise<string[]> {
  const lines: string[] = [];

  // package.json — also captures workspaces / scripts. Read shape is best
  //   effort: a malformed package.json shouldn't break the whole map.
  const pkgPath = path.join(root, 'package.json');
  const pkg = await readJsonSafe<Record<string, any>>(pkgPath);
  if (pkg) {
    const name = pkg.name ? `name=${pkg.name}` : null;
    const type = pkg.type ? `type=${pkg.type}` : null;
    lines.push(`node: package.json present${name ? ` (${name}${type ? ', ' + type : ''})` : ''}`);
    if (pkg.scripts && typeof pkg.scripts === 'object') {
      const scripts = Object.keys(pkg.scripts).slice(0, 8);
      if (scripts.length > 0) {
        lines.push(`  scripts: ${scripts.join(', ')}`);
      }
    }
    if (pkg.dependencies || pkg.devDependencies) {
      const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
      const hints: string[] = [];
      if (deps['typescript']) hints.push('typescript');
      if (deps['react']) hints.push('react');
      if (deps['next']) hints.push('next');
      if (deps['vue']) hints.push('vue');
      if (deps['svelte']) hints.push('svelte');
      if (deps['express']) hints.push('express');
      if (deps['fastify']) hints.push('fastify');
      if (deps['vitest']) hints.push('vitest');
      if (deps['jest']) hints.push('jest');
      if (deps['mocha']) hints.push('mocha');
      if (hints.length > 0) lines.push(`  stack: ${hints.join(', ')}`);
    }
  }

  // tsconfig — strict mode and target are the bits the model needs to
  //   match when generating code. Everything else is noise.
  const tsconfigPath = path.join(root, 'tsconfig.json');
  const tsconfig = await readJsonSafe<Record<string, any>>(tsconfigPath);
  if (tsconfig?.compilerOptions) {
    const opts = tsconfig.compilerOptions as Record<string, unknown>;
    const bits: string[] = [];
    if (opts.strict) bits.push('strict');
    if (opts.target) bits.push(`target=${opts.target}`);
    if (opts.module) bits.push(`module=${opts.module}`);
    lines.push(`typescript: ${bits.length > 0 ? bits.join(', ') : 'tsconfig present'}`);
  }

  // Python project markers.
  const pyMarkers = ['pyproject.toml', 'requirements.txt', 'setup.py', 'Pipfile'];
  for (const marker of pyMarkers) {
    const found = await pathExists(path.join(root, marker));
    if (found) {
      lines.push(`python: ${marker} present`);
      break;
    }
  }

  // Go / Rust / Java / Ruby markers — single-line, no deep parsing.
  if (await pathExists(path.join(root, 'go.mod'))) lines.push('go: go.mod present');
  if (await pathExists(path.join(root, 'Cargo.toml'))) lines.push('rust: Cargo.toml present');
  if (await pathExists(path.join(root, 'pom.xml'))) lines.push('java: pom.xml present');
  if (await pathExists(path.join(root, 'build.gradle'))) lines.push('java/kotlin: build.gradle present');
  if (await pathExists(path.join(root, 'Gemfile'))) lines.push('ruby: Gemfile present');

  return lines;
}

async function buildShallowTree(root: string, maxDepth: number): Promise<string[]> {
  const lines: string[] = [];
  await walkShallow(root, root, 0, maxDepth, lines);
  return lines;
}

async function walkShallow(
  root: string,
  current: string,
  depth: number,
  maxDepth: number,
  out: string[]
): Promise<void> {
  if (depth > maxDepth) return;

  let entries: { name: string; isDir: boolean }[];
  try {
    const raw = await fs.readdir(current, { withFileTypes: true });
    entries = raw
      .filter(e => !e.name.startsWith('.') || depth === 0)
      .filter(e => !SKIP_DIR_NAMES.has(e.name))
      .map(e => ({ name: e.name, isDir: e.isDirectory() }))
      .sort((a, b) => {
        if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
  } catch {
    return;
  }

  for (const entry of entries) {
    const fullPath = path.join(current, entry.name);
    const rel = path.relative(root, fullPath);
    const indent = '  '.repeat(depth);
    out.push(`${indent}${entry.isDir ? entry.name + '/' : entry.name}`);
    if (entry.isDir && depth < maxDepth) {
      await walkShallow(root, fullPath, depth + 1, maxDepth, out);
    }
    // Safety: tree alone shouldn't dominate the output. If we're past 60
    // entries at the top of the walk, the rest goes into the truncation
    // notice instead of bloating the map.
    if (out.length > 60) {
      out.push(`${indent}…`);
      return;
    }
  }
}

async function collectExports(
  root: string,
  execFileAsync: RegisterProjectToolsDeps['execFileAsync']
): Promise<Map<string, string[]>> {
  // We use a deliberately broad regex so it covers JS/TS/Python/Go in one
  // shot. False positives in comments are fine — the model treats this as
  // a hint, not a contract.
  const pattern =
    // TS/JS: export {function|const|class|interface|type|default}
    `^(\\s*export\\s+(?:default\\s+)?(?:async\\s+)?(?:function|const|let|var|class|interface|type|enum)\\s+\\w+)` +
    // Python: def / class at module level
    `|^(def\\s+\\w+\\s*\\()` +
    `|^(class\\s+\\w+(?:\\([^)]*\\))?:)` +
    // Go: capitalized func / type at package level
    `|^(func\\s+(?:\\([^)]+\\)\\s+)?[A-Z]\\w*)` +
    `|^(type\\s+[A-Z]\\w*\\s+)`;

  const ignoreArgs: string[] = [];
  for (const dir of SKIP_DIR_NAMES) {
    ignoreArgs.push('--glob', `!**/${dir}/**`);
  }

  let stdout = '';
  try {
    const result = await execFileAsync(
      'rg',
      [
        '--line-number',
        '--no-heading',
        '--max-count', '12',
        ...ignoreArgs,
        pattern,
        root
      ],
      { maxBuffer: 4 * 1024 * 1024 }
    );
    stdout = result.stdout;
  } catch (error: any) {
    if (error?.code === 'ENOENT') {
      // No ripgrep — skip this section gracefully rather than failing the
      // whole map. The tree + stack detection still give value.
      return new Map();
    }
    // rg exits 1 when no matches; that's fine and we get empty stdout.
  }

  const byFile = new Map<string, string[]>();
  for (const line of stdout.split('\n')) {
    if (!line.trim()) continue;
    const match = line.match(/^([^:]+):\d+:(.*)$/);
    if (!match) continue;
    const [, file, body] = match;
    if (!isInterestingSource(file)) continue;

    const name = extractExportedName(body);
    if (!name) continue;

    const list = byFile.get(file) || [];
    if (!list.includes(name)) list.push(name);
    byFile.set(file, list);
  }

  return byFile;
}

function extractExportedName(body: string): string | null {
  // Try several patterns in order. The regex is intentionally simple — we
  // accept false negatives on edge cases (default exports without a name,
  // re-exports) because over-fitting here costs more than it pays.
  const patterns: RegExp[] = [
    /export\s+(?:default\s+)?(?:async\s+)?(?:function|const|let|var|class|interface|type|enum)\s+(\w+)/,
    /def\s+(\w+)\s*\(/,
    /class\s+(\w+)/,
    /func\s+(?:\([^)]+\)\s+)?([A-Z]\w*)/,
    /type\s+([A-Z]\w*)\s+/,
  ];
  for (const re of patterns) {
    const m = body.match(re);
    if (m) return m[1];
  }
  return null;
}

function isInterestingSource(filePath: string): boolean {
  const ext = path.extname(filePath).toLowerCase();
  if (!SOURCE_EXTENSIONS.has(ext)) return false;
  const lower = filePath.toLowerCase();
  // Skip test files in the high-level map — the model rarely needs them
  // listed here, and they double the output on test-heavy projects.
  if (lower.includes('/test/') || lower.includes('/tests/') || lower.includes('/__tests__/')) return false;
  if (/\.(test|spec)\.[a-z]+$/.test(lower)) return false;
  return true;
}

async function listRecentChanges(
  root: string,
  execFileAsync: RegisterProjectToolsDeps['execFileAsync'],
  n: number
): Promise<string[]> {
  try {
    const { stdout } = await execFileAsync(
      'git',
      ['-C', root, 'log', `-n`, String(n), '--pretty=format:%h %s'],
      { maxBuffer: 64 * 1024 }
    );
    return stdout
      .split('\n')
      .map(s => s.trim())
      .filter(Boolean)
      .slice(0, n);
  } catch {
    return [];
  }
}

async function findCallers(
  symbol: string,
  root: string,
  execFileAsync: RegisterProjectToolsDeps['execFileAsync']
): Promise<string> {
  const ignoreArgs: string[] = [];
  for (const dir of SKIP_DIR_NAMES) {
    ignoreArgs.push('--glob', `!**/${dir}/**`);
  }

  let stdout = '';
  try {
    const result = await execFileAsync(
      'rg',
      [
        '--word-regexp',
        '--line-number',
        '--no-heading',
        '--max-count', '40',
        ...ignoreArgs,
        symbol,
        root
      ],
      { maxBuffer: 4 * 1024 * 1024 }
    );
    stdout = result.stdout;
  } catch (error: any) {
    if (error?.code === 'ENOENT') throw error;
    // No matches → rg exits 1 → stdout empty.
  }

  // Classify each hit: definition vs reference. We can't be perfectly
  // accurate without a real parser, but a few lexical hints catch the
  // common cases — and the model handles ambiguity gracefully.
  interface Hit { file: string; line: number; text: string; kind: 'def' | 'ref'; }
  const hits: Hit[] = [];
  for (const line of stdout.split('\n')) {
    if (!line.trim()) continue;
    const match = line.match(/^([^:]+):(\d+):(.*)$/);
    if (!match) continue;
    const [, file, lineStr, text] = match;
    if (!isInterestingSource(file)) continue;
    const trimmed = text.trim();
    const isDef =
      new RegExp(`\\b(function|class|interface|type|const|let|var|def|func|enum)\\s+${symbol}\\b`).test(trimmed) ||
      new RegExp(`\\bexport\\s+(default\\s+)?(async\\s+)?(function|class|const|let|var)\\s+${symbol}\\b`).test(trimmed) ||
      // Class methods: `private foo(`, `public static foo(`, `protected async foo(`. We require the
      // visibility/modifier keyword to avoid false-positives on call sites like `obj.foo(`.
      new RegExp(`\\b(private|public|protected|static|readonly|async)(\\s+(private|public|protected|static|readonly|async))*\\s+${symbol}\\s*\\(`).test(trimmed);
    hits.push({
      file: path.relative(root, file) || file,
      line: Number(lineStr),
      text: trimmed.length > 140 ? trimmed.slice(0, 140) + '…' : trimmed,
      kind: isDef ? 'def' : 'ref'
    });
  }

  const definitions = hits.filter(h => h.kind === 'def');
  const references = hits.filter(h => h.kind === 'ref').slice(0, WHO_CALLS_MAX_HITS);

  const sections: string[] = [];
  sections.push(`who_calls("${symbol}") — ${references.length} reference(s), ${definitions.length} definition(s)`);

  if (definitions.length > 0) {
    sections.push('\nDefinitions:');
    for (const d of definitions.slice(0, 5)) {
      sections.push(`  ${d.file}:${d.line}  ${d.text}`);
    }
  }

  if (references.length === 0) {
    sections.push('\nNo references found (other than definitions). Symbol may be unused or only referenced dynamically.');
  } else {
    sections.push('\nReferences:');
    for (const r of references) {
      sections.push(`  ${r.file}:${r.line}  ${r.text}`);
    }
    if (hits.filter(h => h.kind === 'ref').length > references.length) {
      sections.push(`  … +${hits.filter(h => h.kind === 'ref').length - references.length} more (truncated)`);
    }
  }

  return sections.join('\n');
}

async function readJsonSafe<T>(filePath: string): Promise<T | null> {
  try {
    const raw = await fs.readFile(filePath, 'utf-8');
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}
