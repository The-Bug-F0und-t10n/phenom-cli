#!/usr/bin/env node
/**
 * Teste de edição de arquivos
 */

import { Agent } from './dist/agent.js';
import { eventBus, EventType } from './dist/tui/event-bus.js';

console.log('='.repeat(80));
console.log('TESTE 2: EDIÇÃO DE ARQUIVO');
console.log('='.repeat(80));

eventBus.on(EventType.AGENT_MESSAGE, (event) => {
  console.log('[AGENT]:', event.payload.content);
});

eventBus.on(EventType.TOOL_START, (event) => {
  console.log(`[TOOL] ${event.payload.name}:`, JSON.stringify(event.payload.args).substring(0, 100));
});

eventBus.on(EventType.TOOL_RESULT, (event) => {
  console.log(`[RESULT] ${event.payload.result.output?.substring(0, 150)}`);
});

async function test() {
  process.chdir('./test-website-real');
  
  const agent = new Agent();
  await agent.initialize();
  
  console.log('\nEditando o arquivo index.html...\n');
  
  await agent.processInput('Edite o arquivo html/index.html e adicione um parágrafo com o texto "Este é um teste do agente Phenom" após o h1');
  
  console.log('\nTeste de edição concluído!');
  process.exit(0);
}

setTimeout(() => {
  console.log('\n[TIMEOUT] Forçando saída após 60 segundos');
  process.exit(0);
}, 60000);

test().catch(err => {
  console.error('Erro:', err);
  process.exit(1);
});
