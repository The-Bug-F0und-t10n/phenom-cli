// Exemplos de uso das novas funcionalidades

import { TreeSitterParser } from './tree-sitter-parser.js';
import { MarkdownRenderer } from './markdown-renderer.js';
import { DiffRenderer } from './diff-renderer.js';

async function exampleTreeSitter() {
  console.log('=== Exemplo: Tree-sitter Parser ===\n');

  const parser = new TreeSitterParser();

  const code = `
export class Calculator {
  /**
   * Adiciona dois números
   */
  add(a: number, b: number): number {
    return a + b;
  }

  /**
   * Subtrai dois números
   */
  subtract(a: number, b: number): number {
    return a - b;
  }
}

export function multiply(a: number, b: number): number {
  return a * b;
}
`;

  const symbols = parser.parseCode(code, 'typescript');

  console.log('Símbolos encontrados:');
  symbols.forEach(s => {
    console.log(`\n${s.type}: ${s.name}`);
    console.log(`  Linhas: ${s.startLine}-${s.endLine}`);
    if (s.docstring) {
      console.log(`  Doc: ${s.docstring}`);
    }
  });

  console.log('\n\nLinguagens suportadas:');
  console.log(parser.getSupportedLanguages().join(', '));
}

async function exampleMarkdownRenderer() {
  console.log('\n\n=== Exemplo: Markdown Renderer ===\n');

  const renderer = new MarkdownRenderer();

  const markdown = `
# Título Principal

Este é um parágrafo com **negrito** e *itálico*.

## Lista

- Item 1
- Item 2
- Item 3

## Código

\`\`\`typescript
function hello(name: string) {
  console.log(\`Hello, \${name}!\`);
}
\`\`\`

> Isso é uma citação
> em múltiplas linhas

## Tabela

| Nome | Idade | Cidade |
|------|-------|--------|
| João | 25    | SP     |
| Maria| 30    | RJ     |
`;

  console.log(renderer.render(markdown));

  // Exemplo de código com syntax highlighting
  console.log('\n\nCódigo com highlighting:');
  const code = `
const greeting = "Hello, World!";
function greet(name) {
  return \`Hello, \${name}!\`;
}
`;
  console.log(renderer.renderCode(code, 'javascript'));

  // Exemplo de tabela
  console.log('\n\nTabela:');
  console.log(renderer.renderTable(
    ['Nome', 'Tipo', 'Descrição'],
    [
      ['parse_code', 'tool', 'Analisa código com Tree-sitter'],
      ['extract_functions', 'tool', 'Extrai funções'],
      ['find_symbol', 'tool', 'Busca símbolo específico']
    ]
  ));
}

async function exampleDiffRenderer() {
  console.log('\n\n=== Exemplo: Diff Renderer (GitHub Theme) ===\n');

  const diffRenderer = new DiffRenderer('github');

  const oldCode = `function calculate(a, b) {
  const result = a + b;
  console.log(result);
  return result;
}`;

  const newCode = `function calculate(a, b) {
  const sum = a + b;
  console.log('Result:', sum);
  return sum;
}`;

  // Diff normal
  console.log('Diff com números de linha:');
  console.log(diffRenderer.renderDiff(oldCode, newCode, { 
    showLineNumbers: true,
    theme: 'github'
  }));

  // Diff de arquivo completo
  console.log('\n\nDiff de arquivo:');
  console.log(diffRenderer.renderFileDiff(
    'src/calculator.js',
    'src/calculator.js',
    oldCode,
    newCode
  ));

  // Estatísticas
  console.log('\n\nEstatísticas:');
  console.log(diffRenderer.renderStats(oldCode, newCode));

  // Split view
  console.log('\n\nSplit view (lado a lado):');
  console.log(diffRenderer.renderSplitDiff(oldCode, newCode, 100));

  // Word diff
  console.log('\n\nWord diff:');
  console.log(diffRenderer.renderWordDiff(
    'The quick brown fox',
    'The fast brown dog'
  ));
}

async function exampleIntegrated() {
  console.log('\n\n=== Exemplo: Integração Completa ===\n');

  const parser = new TreeSitterParser();
  const mdRenderer = new MarkdownRenderer();
  const diffRenderer = new DiffRenderer('github');

  // 1. Parse código
  const code = `
export class UserService {
  async getUser(id: string) {
    return await db.users.findById(id);
  }
}
`;

  const symbols = parser.parseCode(code, 'typescript');

  // 2. Gerar relatório em Markdown
  const report = `
# Análise de Código

## Símbolos Encontrados

${symbols.map(s => `- **${s.type}**: \`${s.name}\` (linhas ${s.startLine}-${s.endLine})`).join('\n')}

## Código Original

\`\`\`typescript
${code}
\`\`\`
`;

  console.log(mdRenderer.render(report));

  // 3. Mostrar diff de refatoração
  const refactoredCode = `
export class UserService {
  async getUser(id: string): Promise<User> {
    const user = await db.users.findById(id);
    if (!user) {
      throw new Error('User not found');
    }
    return user;
  }
}
`;

  console.log('\n## Refatoração Proposta\n');
  console.log(diffRenderer.renderDiff(code.trim(), refactoredCode.trim()));
}

// Executar exemplos
async function main() {
  const example = process.argv[2] || 'all';

  if (example === 'treesitter' || example === 'all') {
    await exampleTreeSitter();
  }

  if (example === 'markdown' || example === 'all') {
    await exampleMarkdownRenderer();
  }

  if (example === 'diff' || example === 'all') {
    await exampleDiffRenderer();
  }

  if (example === 'integrated' || example === 'all') {
    await exampleIntegrated();
  }
}

main().catch(console.error);
