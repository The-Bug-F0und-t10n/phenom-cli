#!/usr/bin/env node
/**
 * Teste direto do ToolRouter
 */

import { ToolRouter } from './dist/tool-router.js';
import { ToolSystem } from './dist/tools.js';
import { OllamaClient } from './dist/ollama-client.js';

console.log('='.repeat(80));
console.log('TESTE DIRETO DO TOOL ROUTER');
console.log('='.repeat(80));

async function test() {
  const llm = new OllamaClient();
  const toolSystem = new ToolSystem();
  const router = new ToolRouter(llm, toolSystem);
  
  const intent = {
    type: 'code',
    query: 'Crie um arquivo styles.css com reset básico',
    files: [],
    language: 'css'
  };
  
  const stepAction = 'Crie um novo arquivo chamado styles.css';
  
  console.log('\nIntent:', JSON.stringify(intent, null, 2));
  console.log('\nStep Action:', stepAction);
  console.log('\nChamando router.decide()...\n');
  
  const startTime = Date.now();
  
  try {
    const decision = await router.decide(intent, stepAction);
    
    const duration = ((Date.now() - startTime) / 1000).toFixed(1);
    
    console.log('\n' + '='.repeat(80));
    console.log('DECISÃO DO ROUTER');
    console.log('='.repeat(80));
    console.log('Tempo:', duration + 's');
    console.log('Use Tool:', decision.useTool);
    console.log('Tool Name:', decision.toolName);
    console.log('Args:', JSON.stringify(decision.args, null, 2));
    console.log('='.repeat(80));
    
  } catch (error) {
    console.error('\n[ERRO]:', error);
  }
  
  process.exit(0);
}

setTimeout(() => {
  console.log('\n[TIMEOUT] Router demorou mais de 30 segundos');
  process.exit(1);
}, 30000);

test().catch(err => {
  console.error('Erro fatal:', err);
  process.exit(1);
});
