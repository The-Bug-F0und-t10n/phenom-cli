// Real AST parser backed by tree-sitter. Loads grammars lazily so a missing
// language module never breaks startup. Returns a compact, model-friendly
// summary (classes, functions, methods, imports, exports) — never the raw
// tree, which is too verbose for an LLM context.

import { promises as fs } from 'fs';
import path from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);

type ParserLike = {
  setLanguage(lang: unknown): void;
  parse(code: string): { rootNode: TSNode };
};

interface TSNode {
  type: string;
  text: string;
  startPosition: { row: number; column: number };
  endPosition: { row: number; column: number };
  childCount: number;
  namedChildCount: number;
  children: TSNode[];
  namedChildren: TSNode[];
  child(i: number): TSNode | null;
  namedChild(i: number): TSNode | null;
  childForFieldName(name: string): TSNode | null;
  descendantsOfType(type: string | string[]): TSNode[];
  parent: TSNode | null;
}

export type SupportedLanguage =
  | 'typescript' | 'tsx' | 'javascript'
  | 'rust' | 'java' | 'c' | 'cpp'
  | 'python' | 'go';

const EXT_TO_LANG: Record<string, SupportedLanguage> = {
  '.ts':   'typescript',
  '.tsx':  'tsx',
  '.mts':  'typescript',
  '.cts':  'typescript',
  '.js':   'javascript',
  '.mjs':  'javascript',
  '.cjs':  'javascript',
  '.jsx':  'tsx',
  '.rs':   'rust',
  '.java': 'java',
  '.c':    'c',
  '.h':    'c',
  '.cpp':  'cpp',
  '.cc':   'cpp',
  '.cxx':  'cpp',
  '.hpp':  'cpp',
  '.hh':   'cpp',
  '.py':   'python',
  '.pyi':  'python',
  '.go':   'go'
};

export function detectLanguage(filePath: string): SupportedLanguage | null {
  const ext = path.extname(filePath).toLowerCase();
  return EXT_TO_LANG[ext] ?? null;
}

let cachedParser: ParserLike | null = null;
const cachedLanguages: Partial<Record<SupportedLanguage, unknown>> = {};
const failedLanguages: Partial<Record<SupportedLanguage, string>> = {};

function getParser(): ParserLike {
  if (cachedParser) return cachedParser;
  const Parser = require('tree-sitter');
  cachedParser = new Parser() as ParserLike;
  return cachedParser;
}

function loadLanguage(lang: SupportedLanguage): unknown {
  if (cachedLanguages[lang]) return cachedLanguages[lang];
  if (failedLanguages[lang]) {
    throw new Error(`grammar para "${lang}" indisponível: ${failedLanguages[lang]}`);
  }
  let mod: any;
  switch (lang) {
    case 'typescript':
    case 'tsx': {
      mod = require('tree-sitter-typescript');
      cachedLanguages[lang] = lang === 'tsx' ? mod.tsx : mod.typescript;
      break;
    }
    case 'javascript':
      // JS grammar's NAPI ABI conflicts with tree-sitter@0.21.x in our setup;
      // route .js through the TypeScript grammar, which is a strict superset.
      mod = require('tree-sitter-typescript');
      cachedLanguages[lang] = mod.typescript;
      break;
    case 'rust':
      cachedLanguages[lang] = require('tree-sitter-rust');
      break;
    case 'java':
      cachedLanguages[lang] = require('tree-sitter-java');
      break;
    case 'c':
      cachedLanguages[lang] = require('tree-sitter-c');
      break;
    case 'cpp':
      cachedLanguages[lang] = require('tree-sitter-cpp');
      break;
    case 'python':
      cachedLanguages[lang] = require('tree-sitter-python');
      break;
    case 'go':
      cachedLanguages[lang] = require('tree-sitter-go');
      break;
  }
  return cachedLanguages[lang];
}

export interface AstSymbol {
  kind: string;
  name: string;
  line: number;          // 1-based start line
  endLine?: number;      // 1-based end line, inclusive (when known from AST)
  signature?: string;
  children?: AstSymbol[];
}

export interface AstSummary {
  language: SupportedLanguage;
  totalLines: number;
  classes: AstSymbol[];
  functions: AstSymbol[];
  imports: string[];
  exports: string[];
  errors: number;
}

function textOfFirstChild(node: TSNode, type: string): string | null {
  for (const c of node.namedChildren) if (c.type === type) return c.text;
  return null;
}

function nameOf(node: TSNode): string | null {
  const name = node.childForFieldName('name');
  if (name) return name.text;
  for (const c of node.namedChildren) {
    if (c.type === 'identifier' || c.type === 'type_identifier' || c.type === 'property_identifier' || c.type === 'field_identifier') {
      return c.text;
    }
  }
  return null;
}

function signatureOf(node: TSNode, lang: SupportedLanguage): string {
  // For functions/methods, pull parameters and return type when available.
  const params = node.childForFieldName('parameters');
  const returnType = node.childForFieldName('return_type');
  let sig = '';
  if (params) sig += params.text;
  if (returnType) sig += ` ${returnType.text}`;
  // Fall back to a single trimmed line of the declaration.
  if (!sig) {
    const head = node.text.split('\n', 1)[0];
    sig = head.length > 120 ? head.slice(0, 117) + '...' : head;
  }
  return sig.replace(/\s+/g, ' ').trim();
}

const FN_KINDS: Record<SupportedLanguage, Set<string>> = {
  typescript: new Set(['function_declaration', 'method_definition', 'function_signature']),
  tsx:        new Set(['function_declaration', 'method_definition', 'function_signature']),
  javascript: new Set(['function_declaration', 'method_definition', 'function_signature']),
  rust:       new Set(['function_item']),
  java:       new Set(['method_declaration', 'constructor_declaration']),
  c:          new Set(['function_definition']),
  cpp:        new Set(['function_definition']),
  python:     new Set(['function_definition']),
  go:         new Set(['function_declaration', 'method_declaration'])
};

const CLASS_KINDS: Record<SupportedLanguage, Set<string>> = {
  typescript: new Set(['class_declaration', 'interface_declaration', 'type_alias_declaration', 'enum_declaration']),
  tsx:        new Set(['class_declaration', 'interface_declaration', 'type_alias_declaration', 'enum_declaration']),
  javascript: new Set(['class_declaration']),
  rust:       new Set(['struct_item', 'enum_item', 'trait_item', 'impl_item']),
  java:       new Set(['class_declaration', 'interface_declaration', 'enum_declaration', 'record_declaration']),
  c:          new Set(['struct_specifier', 'enum_specifier', 'union_specifier']),
  cpp:        new Set(['class_specifier', 'struct_specifier', 'enum_specifier', 'union_specifier']),
  python:     new Set(['class_definition']),
  // Go declares structs/interfaces wrapped in `type_declaration` → `type_spec`.
  // We catch type_declaration here and unwrap below where it matters.
  go:         new Set(['type_declaration'])
};

const IMPORT_KINDS: Record<SupportedLanguage, Set<string>> = {
  typescript: new Set(['import_statement']),
  tsx:        new Set(['import_statement']),
  javascript: new Set(['import_statement']),
  rust:       new Set(['use_declaration']),
  java:       new Set(['import_declaration']),
  c:          new Set(['preproc_include']),
  cpp:        new Set(['preproc_include']),
  python:     new Set(['import_statement', 'import_from_statement']),
  go:         new Set(['import_declaration'])
};

const EXPORT_KINDS: Record<SupportedLanguage, Set<string>> = {
  typescript: new Set(['export_statement']),
  tsx:        new Set(['export_statement']),
  javascript: new Set(['export_statement']),
  rust:       new Set([]), // Rust uses `pub` modifier on items, not a top-level node
  java:       new Set([]),
  c:          new Set([]),
  cpp:        new Set([]),
  // Python/Go don't have a syntactic "export" statement — visibility is by name (Go: PascalCase, Python: leading underscore convention).
  python:     new Set([]),
  go:         new Set([])
};

function symbolFromNode(node: TSNode, lang: SupportedLanguage, kind: string): AstSymbol {
  const name = nameOf(node) || '<anonymous>';
  return {
    kind,
    name,
    line: node.startPosition.row + 1,
    endLine: node.endPosition.row + 1,
    signature: FN_KINDS[lang].has(node.type) ? signatureOf(node, lang) : undefined
  };
}

function collectChildrenOfTypes(node: TSNode, types: Set<string>): TSNode[] {
  const out: TSNode[] = [];
  for (const c of node.namedChildren) {
    if (types.has(c.type)) out.push(c);
  }
  return out;
}

// Find the body block of a class-like node and collect its methods.
function methodsOf(classNode: TSNode, lang: SupportedLanguage): AstSymbol[] {
  const fnTypes = FN_KINDS[lang];
  const body = classNode.childForFieldName('body');
  if (!body) return [];
  const out: AstSymbol[] = [];
  for (const c of body.namedChildren) {
    if (fnTypes.has(c.type)) {
      out.push(symbolFromNode(c, lang, 'method'));
    }
    // C++/Java sometimes wraps decls; recurse one level.
    if (c.type === 'field_declaration' || c.type === 'declaration') {
      for (const cc of c.namedChildren) if (fnTypes.has(cc.type)) out.push(symbolFromNode(cc, lang, 'method'));
    }
  }
  return out;
}

function countErrors(root: TSNode): number {
  // tree-sitter marks parse failures with `type === 'ERROR'`.
  return root.descendantsOfType('ERROR').length;
}

export function parseSource(code: string, lang: SupportedLanguage): AstSummary {
  const parser = getParser();
  // NAPI ABI between tree-sitter and a grammar can mismatch (e.g. 0.21 host +
  // 0.25 grammar throws "Cannot read properties of undefined" inside
  // setLanguage). Remember the failure so we don't retry hot per-file, and
  // surface a clear error message to the caller (chunker falls back to window).
  try {
    parser.setLanguage(loadLanguage(lang));
  } catch (e: any) {
    failedLanguages[lang] = e?.message || String(e);
    throw new Error(`tree-sitter não conseguiu carregar a gramática "${lang}" (ABI/NAPI mismatch?): ${failedLanguages[lang]}`);
  }
  const tree = parser.parse(code);
  const root = tree.rootNode;

  const classKinds = CLASS_KINDS[lang];
  const fnKinds = FN_KINDS[lang];
  const importKinds = IMPORT_KINDS[lang];
  const exportKinds = EXPORT_KINDS[lang];

  const classes: AstSymbol[] = [];
  const functions: AstSymbol[] = [];
  const imports: string[] = [];
  const exports: string[] = [];

  // Top-level only — keeps the summary compact. Methods are nested inside class entries.
  for (const node of root.namedChildren) {
    // Go declares structs/interfaces via `type T struct { ... }` or grouped
    // `type ( ... )`. Both produce `type_declaration` wrapping one or more
    // `type_spec` children. Unwrap to surface real type names instead of <anonymous>.
    if (lang === 'go' && node.type === 'type_declaration') {
      for (const spec of node.namedChildren) {
        if (spec.type !== 'type_spec') continue;
        const inner = spec.namedChildren.find(c => c.type === 'struct_type' || c.type === 'interface_type');
        const innerKind = inner?.type ?? 'type_alias';
        const sym = symbolFromNode(spec, lang, innerKind);
        // Collect interface methods as children for nicer summaries.
        if (inner?.type === 'interface_type') {
          const ms: AstSymbol[] = [];
          for (const m of inner.namedChildren) {
            if (m.type === 'method_spec' || m.type === 'method_elem') {
              ms.push({ kind: 'method', name: nameOf(m) || '<anonymous>', line: m.startPosition.row + 1, endLine: m.endPosition.row + 1 });
            }
          }
          if (ms.length) sym.children = ms;
        }
        classes.push(sym);
      }
      continue;
    }
    if (classKinds.has(node.type)) {
      const sym = symbolFromNode(node, lang, node.type);
      const ms = methodsOf(node, lang);
      if (ms.length) sym.children = ms;
      classes.push(sym);
      continue;
    }
    if (fnKinds.has(node.type)) {
      functions.push(symbolFromNode(node, lang, node.type));
      continue;
    }
    // `export function foo()` / `export class Foo` — descend into the export.
    if (exportKinds.has(node.type)) {
      const inner = node.namedChildren[0];
      if (inner && classKinds.has(inner.type)) {
        const sym = symbolFromNode(inner, lang, inner.type);
        const ms = methodsOf(inner, lang);
        if (ms.length) sym.children = ms;
        classes.push(sym);
        exports.push(`export ${inner.type} ${sym.name}`);
        continue;
      }
      if (inner && fnKinds.has(inner.type)) {
        functions.push(symbolFromNode(inner, lang, inner.type));
        exports.push(`export ${inner.type} ${nameOf(inner) || '<anonymous>'}`);
        continue;
      }
      exports.push(node.text.split('\n', 1)[0].slice(0, 120));
      continue;
    }
    if (importKinds.has(node.type)) {
      imports.push(node.text.replace(/\s+/g, ' ').trim().slice(0, 160));
      continue;
    }
    // const foo = (x) => { ... }  /  const Foo = class { ... }
    if (node.type === 'lexical_declaration' || node.type === 'variable_declaration') {
      for (const decl of node.namedChildren) {
        if (decl.type !== 'variable_declarator') continue;
        const valueNode = decl.childForFieldName('value');
        const name = nameOf(decl) || '<anonymous>';
        if (valueNode && (valueNode.type === 'arrow_function' || valueNode.type === 'function_expression')) {
          functions.push({
            kind: 'arrow_function',
            name,
            line: decl.startPosition.row + 1,
            signature: signatureOf(valueNode, lang)
          });
        } else if (valueNode && (valueNode.type === 'class' || valueNode.type === 'class_expression')) {
          classes.push({ kind: 'class_expression', name, line: decl.startPosition.row + 1 });
        }
      }
    }
  }

  return {
    language: lang,
    totalLines: code.split('\n').length,
    classes,
    functions,
    imports,
    exports,
    errors: countErrors(root)
  };
}

export async function parseFile(filePath: string): Promise<AstSummary> {
  const lang = detectLanguage(filePath);
  if (!lang) throw new Error(`Linguagem não suportada para: ${filePath}`);
  const code = await fs.readFile(filePath, 'utf-8');
  return parseSource(code, lang);
}

export function formatSummary(filePath: string, sum: AstSummary): string {
  const lines: string[] = [];
  lines.push(`file: ${filePath} (${sum.language}, ${sum.totalLines} lines${sum.errors ? `, ${sum.errors} parse errors` : ''})`);
  if (sum.imports.length) {
    lines.push(`imports (${sum.imports.length}):`);
    for (const imp of sum.imports.slice(0, 30)) lines.push(`  ${imp}`);
    if (sum.imports.length > 30) lines.push(`  ...${sum.imports.length - 30} more`);
  }
  if (sum.classes.length) {
    lines.push(`classes/types (${sum.classes.length}):`);
    for (const c of sum.classes) {
      lines.push(`  ${c.kind} ${c.name} @L${c.line}`);
      if (c.children?.length) {
        for (const m of c.children.slice(0, 20)) {
          lines.push(`    - ${m.name}${m.signature ? ' ' + m.signature : ''} @L${m.line}`);
        }
        if (c.children.length > 20) lines.push(`    ...${c.children.length - 20} more methods`);
      }
    }
  }
  if (sum.functions.length) {
    lines.push(`functions (${sum.functions.length}):`);
    for (const f of sum.functions.slice(0, 60)) {
      lines.push(`  ${f.name}${f.signature ? ' ' + f.signature : ''} @L${f.line}`);
    }
    if (sum.functions.length > 60) lines.push(`  ...${sum.functions.length - 60} more`);
  }
  if (sum.exports.length) {
    lines.push(`exports (${sum.exports.length}):`);
    for (const e of sum.exports.slice(0, 30)) lines.push(`  ${e}`);
    if (sum.exports.length > 30) lines.push(`  ...${sum.exports.length - 30} more`);
  }
  if (!sum.classes.length && !sum.functions.length && !sum.imports.length && !sum.exports.length) {
    lines.push('(no top-level declarations found)');
  }
  return lines.join('\n');
}
