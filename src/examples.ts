// Exemplo de uso do agente programaticamente

import { Agent } from './agent.js';

async function example1() {
  console.log('=== Exemplo 1: Modo Fast ===\n');
  
  const agent = new Agent();
  agent.setMode('fast');
  await agent.initialize();
  
  await agent.processInput('O que é TypeScript?');
}

async function example2() {
  console.log('\n=== Exemplo 2: Modo Deep - Criar Função ===\n');
  
  const agent = new Agent();
  agent.setMode('reasoning');
  await agent.initialize();
  
  await agent.processInput('Crie uma função em TypeScript para validar CPF');
}

async function example3() {
  console.log('\n=== Exemplo 3: Busca com RAG ===\n');
  
  const agent = new Agent();
  await agent.initialize();
  
  // Indexar código
  await agent.indexRepository('./src');
  
  // Buscar
  await agent.searchCode('função de validação');
}

async function example4() {
  console.log('\n=== Exemplo 4: Operações Git ===\n');
  
  const agent = new Agent();
  await agent.initialize();
  
  await agent.processInput('Mostre o status do git e os últimos 5 commits');
}

async function example5() {
  console.log('\n=== Exemplo 5: Debug de Código ===\n');
  
  const agent = new Agent();
  await agent.initialize();
  
  await agent.processInput('Encontre e corrija o bug no arquivo src/utils/validator.ts');
}

// Executar exemplos
async function main() {
  const exampleNumber = process.argv[2] || '1';
  
  switch (exampleNumber) {
    case '1':
      await example1();
      break;
    case '2':
      await example2();
      break;
    case '3':
      await example3();
      break;
    case '4':
      await example4();
      break;
    case '5':
      await example5();
      break;
    default:
      console.log('Uso: tsx examples.ts [1-5]');
  }
}

main().catch(console.error);
