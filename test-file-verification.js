#!/usr/bin/env node
/**
 * Teste com verificação de arquivo
 */

import { Agent } from './dist/agent.js';
import { eventBus, EventType } from './dist/tui/event-bus.js';
import { promises as fs } from 'fs';

console.log('='.repeat(80));
console.log('TESTE COM VERIFICAÇÃO DE ARQUIVO');
console.log('='.repeat(80));

let toolCalls = [];

eventBus.on(EventType.TOOL_START, (event) => {
  console.log(`\n[TOOL START] ${event.payload.name}`);
  console.log('Args:', JSON.stringify(event.payload.args, null, 2));
  toolCalls.push({
    name: event.payload.name,
    args: event.payload.args,
    time: new Date().toISOString()
  });
});

eventBus.on(EventType.TOOL_RESULT, (event) => {
  console.log(`[TOOL RESULT] Success: ${event.payload.result.success}`);
  console.log('Output:', event.payload.result.output);
});

eventBus.on(EventType.TOOL_ERROR, (event) => {
  console.error(`[TOOL ERROR]`, event.payload.error);
});

async function test() {
  const testDir = './test-website-real';
  process.chdir(testDir);
  
  console.log(`\nDiretório de trabalho: ${process.cwd()}`);
  console.log('Arquivos antes:', await fs.readdir('.'));
  
  const agent = new Agent();
  await agent.initialize();
  
  console.log('\n' + '='.repeat(80));
  console.log('Pedindo para criar index.html');
  console.log('='.repeat(80));
  
  await agent.processInput('Crie um arquivo index.html com apenas <h1>Test</h1>');
  
  console.log('\n' + '='.repeat(80));
  console.log('VERIFICAÇÃO FINAL');
  console.log('='.repeat(80));
  
  const filesAfter = await fs.readdir('.');
  console.log('Arquivos depois:', filesAfter);
  
  console.log('\nFerramentas chamadas:', toolCalls.length);
  toolCalls.forEach((call, i) => {
    console.log(`\n${i+1}. ${call.name}`);
    console.log('   Path:', call.args.path);
    console.log('   Time:', call.time);
  });
  
  // Verificar se arquivo existe
  if (toolCalls.length > 0) {
    const lastCall = toolCalls[toolCalls.length - 1];
    if (lastCall.args.path) {
      try {
        const exists = await fs.access(lastCall.args.path).then(() => true).catch(() => false);
        console.log(`\nArquivo ${lastCall.args.path} existe: ${exists}`);
        
        if (exists) {
          const content = await fs.readFile(lastCall.args.path, 'utf-8');
          console.log('Conteúdo:', content);
        }
      } catch (err) {
        console.log('Erro ao verificar:', err.message);
      }
    }
  }
  
  process.exit(0);
}

setTimeout(() => {
  console.log('\n[TIMEOUT]');
  process.exit(1);
}, 60000);

test().catch(err => {
  console.error('Erro:', err);
  process.exit(1);
});
