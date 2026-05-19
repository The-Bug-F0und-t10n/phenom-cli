import 'dotenv/config';
import { Agent } from './src/agent.js';
import { eventBus, EventType } from './src/tui/event-bus.js';

async function main() {
  const agent = new Agent();
  const sessionId = await agent.initialize();

  console.log('\n=== TESTE COMPLEXO - CRIAR 3 ARQUIVOS ===\n');
  console.log('Session:', sessionId);

  let toolCount = 0;
  let iteration = 0;

  eventBus.on(EventType.MESSAGE_CHUNK, (event) => {
    const chunk = event?.payload?.chunk || '';
    if (chunk && chunk.length > 0) {
      process.stdout.write(chunk);
    }
  });

  eventBus.on(EventType.THINK_START, (event) => {
    iteration++;
    console.log('\n\n' + '='.repeat(50));
    console.log(`[ITERATION ${iteration}]`);
  });

  eventBus.on(EventType.TOOL_START, (event) => {
    toolCount++;
    console.log('\n[TOOL CALL #' + toolCount + ']', event?.payload?.name);
  });

  eventBus.on(EventType.TOOL_RESULT, (event) => {
    const r = event?.payload?.result;
    console.log('[RESULT]', r?.success ? '✅' : '❌', r?.output?.substring(0, 80));
  });

  eventBus.on(EventType.TOOL_ERROR, (event) => {
    console.log('[ERROR]', event?.payload?.error);
  });

  eventBus.on(EventType.AGENT_MESSAGE, (event) => {
    const content = event?.payload?.content || '';
    console.log('\n[FINAL RESPONSE]', content.substring(0, 300));
  });

  await agent.processInput('Crie 3 arquivos: index.html (HTML básico), src/App.tsx (componente React), src/styles.css (estilo body). Use write_file para cada um, um por vez, verificando depois de cada um.');

  console.log('\n\n=== RESUMO ===');
  console.log('Total de tool calls:', toolCount);
  console.log('Iterations:', iteration);
  console.log('Session ID:', sessionId);
}

main().catch(console.error);
