import { ToolSystem } from './tools.js';
import { ToolResult } from './types.js';
import { TreeSitterParser } from './tree-sitter-parser.js';

export function registerAdvancedTools(toolSystem: ToolSystem): void {
  const parser = new TreeSitterParser();

  // Tool para análise de código com Tree-sitter
  toolSystem.register({
    name: 'parse_code',
    description: 'Analisa código usando Tree-sitter e extrai símbolos (funções, classes, etc)',
    execute: async (args): Promise<ToolResult> => {
      try {
        const code = args.code as string;
        const language = args.language as string;

        if (!code || !language) {
          return {
            success: false,
            output: '',
            error: 'Parâmetros code e language são obrigatórios'
          };
        }

        const symbols = parser.parseCode(code, language);

        if (symbols.length === 0) {
          return {
            success: true,
            output: 'Nenhum símbolo encontrado ou linguagem não suportada',
            error: null
          };
        }

        const output = symbols.map(s => 
          `${s.type}: ${s.name} (linhas ${s.startLine}-${s.endLine})`
        ).join('\n');

        return {
          success: true,
          output,
          error: null
        };
      } catch (error: any) {
        return {
          success: false,
          output: '',
          error: error.message
        };
      }
    }
  });

  // Tool para extrair funções de um arquivo
  toolSystem.register({
    name: 'extract_functions',
    description: 'Extrai todas as funções de um arquivo usando Tree-sitter',
    execute: async (args): Promise<ToolResult> => {
      try {
        const filePath = args.path as string;

        if (!filePath) {
          return {
            success: false,
            output: '',
            error: 'Parâmetro path é obrigatório'
          };
        }

        const symbols = await parser.parseFile(filePath);
        const functions = symbols.filter(s => s.type === 'function' || s.type === 'method');

        if (functions.length === 0) {
          return {
            success: true,
            output: 'Nenhuma função encontrada',
            error: null
          };
        }

        const output = functions.map(f => {
          let result = `\n${f.type}: ${f.name} (linhas ${f.startLine}-${f.endLine})`;
          if (f.docstring) {
            result += `\nDoc: ${f.docstring}`;
          }
          return result;
        }).join('\n');

        return {
          success: true,
          output,
          error: null
        };
      } catch (error: any) {
        return {
          success: false,
          output: '',
          error: error.message
        };
      }
    }
  });

  // Tool para extrair classes
  toolSystem.register({
    name: 'extract_classes',
    description: 'Extrai todas as classes de um arquivo usando Tree-sitter',
    execute: async (args): Promise<ToolResult> => {
      try {
        const filePath = args.path as string;

        if (!filePath) {
          return {
            success: false,
            output: '',
            error: 'Parâmetro path é obrigatório'
          };
        }

        const symbols = await parser.parseFile(filePath);
        const classes = symbols.filter(s => s.type === 'class');

        if (classes.length === 0) {
          return {
            success: true,
            output: 'Nenhuma classe encontrada',
            error: null
          };
        }

        const output = classes.map(c => {
          let result = `\nclass: ${c.name} (linhas ${c.startLine}-${c.endLine})`;
          if (c.docstring) {
            result += `\nDoc: ${c.docstring}`;
          }
          return result;
        }).join('\n');

        return {
          success: true,
          output,
          error: null
        };
      } catch (error: any) {
        return {
          success: false,
          output: '',
          error: error.message
        };
      }
    }
  });

  // Tool para buscar símbolo específico
  toolSystem.register({
    name: 'find_symbol',
    description: 'Busca um símbolo específico (função, classe, etc) em um arquivo',
    execute: async (args): Promise<ToolResult> => {
      try {
        const filePath = args.path as string;
        const symbolName = args.name as string;

        if (!filePath || !symbolName) {
          return {
            success: false,
            output: '',
            error: 'Parâmetros path e name são obrigatórios'
          };
        }

        const symbols = await parser.parseFile(filePath);
        const found = symbols.find(s => s.name === symbolName);

        if (!found) {
          return {
            success: false,
            output: '',
            error: `Símbolo '${symbolName}' não encontrado`
          };
        }

        let output = `${found.type}: ${found.name}\n`;
        output += `Linhas: ${found.startLine}-${found.endLine}\n`;
        if (found.docstring) {
          output += `\nDocumentação:\n${found.docstring}\n`;
        }
        output += `\nCódigo:\n${found.code}`;

        return {
          success: true,
          output,
          error: null
        };
      } catch (error: any) {
        return {
          success: false,
          output: '',
          error: error.message
        };
      }
    }
  });

  // Tool para listar linguagens suportadas
  toolSystem.register({
    name: 'supported_languages',
    description: 'Lista linguagens suportadas pelo parser Tree-sitter',
    execute: async (): Promise<ToolResult> => {
      const languages = parser.getSupportedLanguages();
      return {
        success: true,
        output: `Linguagens suportadas:\n${languages.join(', ')}`,
        error: null
      };
    }
  });
}
