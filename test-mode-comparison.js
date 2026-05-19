#!/usr/bin/env node
/**
 * Teste comparativo: Fast Mode vs Deep Mode
 */

import { Agent } from './dist/agent.js';
import { eventBus, EventType } from './dist/tui/event-bus.js';
import { config } from './dist/config.js';

console.log('='.repeat(80));
console.log('TESTE COMPARATIVO: FAST MODE vs DEEP MODE');
console.log('='.repeat(80));
console.log(`Modo atual: ${config.system.mode}`);
console.log(`Modelo: ${config.ollama.model}`);
console.log(`Host: ${config.ollama.host}`);
console.log('='.repeat(80));

let toolsExecuted = [];
let messagesReceived = [];

eventBus.on(EventType.AGENT_MESSAGE, (event) => {
  console.log('\n[AGENT MESSAGE]:', event.payload.content.substring(0, 200));
  messagesReceived.push(event.payload.content);
});

eventBus.on(EventType.TOOL_START, (event) => {
  console.log(`\n[TOOL START] ${event.payload.name}`);
  console.log('Args:', JSON.stringify(event.payload.args, null, 2).substring(0, 300));
  toolsExecuted.push(event.payload.name);
});

eventBus.on(EventType.TOOL_RESULT, (event) => {
  console.log(`[TOOL RESULT] Success: ${event.payload.result.success}`);
  if (event.payload.result.output) {
    console.log('Output:', event.payload.result.output.substring(0, 150));
  }
});

eventBus.on(EventType.TOOL_ERROR, (event) => {
  console.error(`[TOOL ERROR]`, event.payload.error);
});

eventBus.on(EventType.PROGRESS_UPDATE, (event) => {
  console.log(`[PROGRESS] ${event.payload.message}`);
});

eventBus.on(EventType.TODO_UPDATE, (event) => {
  console.log(`[TODO UPDATE] ${event.payload.todos.length} todos`);
  event.payload.todos.forEach((todo, i) => {
    console.log(`  ${i+1}. [${todo.status}] ${todo.action}`);
  });
});

async function test() {
  process.chdir('./test-website-real');
  
  const agent = new Agent();
  await agent.initialize();
  
  console.log('\n' + '='.repeat(80));
  console.log('TESTE: Criar arquivo CSS simples');
  console.log('='.repeat(80));
  
  const startTime = Date.now();
  
  try {
    await agent.processInput('Crie um arquivo styles.css com apenas um reset básico: * { margin: 0; padding: 0; }');
    
    const duration = ((Date.now() - startTime) / 1000).toFixed(1);
    
    console.log('\n' + '='.repeat(80));
    console.log('RESULTADO DO TESTE');
    console.log('='.repeat(80));
    console.log(`Tempo total: ${duration}s`);
    console.log(`Ferramentas executadas: ${toolsExecuted.length}`);
    console.log(`Ferramentas: ${toolsExecuted.join(', ')}`);
    console.log(`Mensagens recebidas: ${messagesReceived.length}`);
    console.log('='.repeat(80));
    
  } catch (error) {
    console.error('\n[ERRO]:', error);
  }
  
  process.exit(0);
}

// Timeout de segurança
setTimeout(() => {
  console.log('\n[TIMEOUT] Forçando saída após 45 segundos');
  console.log(`Ferramentas executadas até agora: ${toolsExecuted.join(', ')}`);
  process.exit(1);
}, 45000);

test().catch(err => {
  console.error('Erro fatal:', err);
  process.exit(1);
});
