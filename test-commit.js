#!/usr/bin/env node
/**
 * Teste de git commit
 */

import { Agent } from './dist/agent.js';
import { eventBus, EventType } from './dist/tui/event-bus.js';

console.log('='.repeat(80));
console.log('TESTE 3: GIT COMMIT');
console.log('='.repeat(80));

eventBus.on(EventType.AGENT_MESSAGE, (event) => {
  console.log('[AGENT]:', event.payload.content);
});

eventBus.on(EventType.TOOL_START, (event) => {
  console.log(`[TOOL] ${event.payload.name}`);
});

eventBus.on(EventType.TOOL_RESULT, (event) => {
  console.log(`[RESULT] ${event.payload.result.output}`);
});

async function test() {
  process.chdir('./test-website-real');
  
  const agent = new Agent();
  await agent.initialize();
  
  console.log('\nPedindo para fazer commit...\n');
  
  await agent.processInput('Adicione todos os arquivos ao git e faça um commit com a mensagem "Add initial HTML file"');
  
  console.log('\nTeste de commit concluído!');
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
