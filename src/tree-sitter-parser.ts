import Parser from 'tree-sitter';
import TypeScript from 'tree-sitter-typescript';
import JavaScript from 'tree-sitter-javascript';
import Python from 'tree-sitter-python';
import Rust from 'tree-sitter-rust';
import Go from 'tree-sitter-go';
import Java from 'tree-sitter-java';
import Cpp from 'tree-sitter-cpp';
import { promises as fs } from 'fs';
import path from 'path';

export interface ParsedNode {
  type: string;
  name?: string;
  startPosition: { row: number; column: number };
  endPosition: { row: number; column: number };
  text: string;
  children?: ParsedNode[];
}

export interface CodeSymbol {
  name: string;
  type: 'function' | 'class' | 'method' | 'variable' | 'interface' | 'type';
  startLine: number;
  endLine: number;
  code: string;
  docstring?: string;
}

export class TreeSitterParser {
  private parsers: Map<string, Parser>;

  constructor() {
    this.parsers = new Map();
    this.initializeParsers();
  }

  private initializeParsers(): void {
    // TypeScript
    const tsParser = new Parser();
    tsParser.setLanguage(TypeScript.typescript);
    this.parsers.set('typescript', tsParser);
    this.parsers.set('ts', tsParser);

    // JavaScript
    const jsParser = new Parser();
    jsParser.setLanguage(JavaScript);
    this.parsers.set('javascript', jsParser);
    this.parsers.set('js', jsParser);

    // Python
    const pyParser = new Parser();
    pyParser.setLanguage(Python);
    this.parsers.set('python', pyParser);
    this.parsers.set('py', pyParser);

    // Rust
    const rsParser = new Parser();
    rsParser.setLanguage(Rust);
    this.parsers.set('rust', rsParser);
    this.parsers.set('rs', rsParser);

    // Go
    const goParser = new Parser();
    goParser.setLanguage(Go);
    this.parsers.set('go', goParser);

    // Java
    const javaParser = new Parser();
    javaParser.setLanguage(Java);
    this.parsers.set('java', javaParser);

    // C++
    const cppParser = new Parser();
    cppParser.setLanguage(Cpp);
    this.parsers.set('cpp', cppParser);
    this.parsers.set('cc', cppParser);
    this.parsers.set('cxx', cppParser);
  }

  async parseFile(filePath: string): Promise<CodeSymbol[]> {
    const ext = path.extname(filePath).slice(1);
    const parser = this.parsers.get(ext);

    if (!parser) {
      return [];
    }

    const code = await fs.readFile(filePath, 'utf-8');
    const tree = parser.parse(code);

    return this.extractSymbols(tree.rootNode, code);
  }

  parseCode(code: string, language: string): CodeSymbol[] {
    const parser = this.parsers.get(language);

    if (!parser) {
      return [];
    }

    const tree = parser.parse(code);
    return this.extractSymbols(tree.rootNode, code);
  }

  private extractSymbols(node: any, code: string): CodeSymbol[] {
    const symbols: CodeSymbol[] = [];

    const traverse = (n: any) => {
      // Funções
      if (n.type === 'function_declaration' || 
          n.type === 'function_definition' ||
          n.type === 'method_definition') {
        const nameNode = n.childForFieldName('name');
        if (nameNode) {
          symbols.push({
            name: nameNode.text,
            type: n.type.includes('method') ? 'method' : 'function',
            startLine: n.startPosition.row,
            endLine: n.endPosition.row,
            code: n.text,
            docstring: this.extractDocstring(n, code)
          });
        }
      }

      // Classes
      if (n.type === 'class_declaration' || n.type === 'class_definition') {
        const nameNode = n.childForFieldName('name');
        if (nameNode) {
          symbols.push({
            name: nameNode.text,
            type: 'class',
            startLine: n.startPosition.row,
            endLine: n.endPosition.row,
            code: n.text,
            docstring: this.extractDocstring(n, code)
          });
        }
      }

      // Interfaces (TypeScript)
      if (n.type === 'interface_declaration') {
        const nameNode = n.childForFieldName('name');
        if (nameNode) {
          symbols.push({
            name: nameNode.text,
            type: 'interface',
            startLine: n.startPosition.row,
            endLine: n.endPosition.row,
            code: n.text
          });
        }
      }

      // Type aliases (TypeScript)
      if (n.type === 'type_alias_declaration') {
        const nameNode = n.childForFieldName('name');
        if (nameNode) {
          symbols.push({
            name: nameNode.text,
            type: 'type',
            startLine: n.startPosition.row,
            endLine: n.endPosition.row,
            code: n.text
          });
        }
      }

      // Variáveis exportadas
      if (n.type === 'variable_declaration' || n.type === 'lexical_declaration') {
        const parent = n.parent;
        if (parent && parent.type === 'export_statement') {
          const declarator = n.child(1);
          if (declarator) {
            const nameNode = declarator.childForFieldName('name');
            if (nameNode) {
              symbols.push({
                name: nameNode.text,
                type: 'variable',
                startLine: n.startPosition.row,
                endLine: n.endPosition.row,
                code: n.text
              });
            }
          }
        }
      }

      // Recursão
      for (let i = 0; i < n.childCount; i++) {
        traverse(n.child(i));
      }
    };

    traverse(node);
    return symbols;
  }

  private extractDocstring(node: any, code: string): string | undefined {
    // Procurar comentário antes do nó
    const startLine = node.startPosition.row;
    const lines = code.split('\n');
    
    let docLines: string[] = [];
    let i = startLine - 1;

    // Procurar comentários acima
    while (i >= 0) {
      const line = lines[i].trim();
      
      if (line.startsWith('//') || line.startsWith('*') || line.startsWith('/*')) {
        docLines.unshift(line);
        i--;
      } else if (line === '') {
        i--;
      } else {
        break;
      }
    }

    if (docLines.length > 0) {
      return docLines.join('\n').replace(/^\/\*\*?|\*\/|^\s*\*\s?|^\/\//gm, '').trim();
    }

    return undefined;
  }

  getSupportedLanguages(): string[] {
    return Array.from(this.parsers.keys());
  }
}
