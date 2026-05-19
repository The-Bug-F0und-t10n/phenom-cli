import { Agent } from './src/agent.js';
import { eventBus, EventType } from './src/tui/event-bus.js';

async function main() {
  const agent = new Agent();
  await agent.initialize();

  console.log('\n=== TESTE SIMPLES ===\n');

  eventBus.on(EventType.MESSAGE_CHUNK, (event) => {
    const chunk = event?.payload?.chunk || '';
    if (chunk && chunk.length > 0) {
      process.stdout.write(chunk);
    }
  });

  eventBus.on(EventType.TOOL_START, (event) => {
    console.log('\n\n[TOOL START]', event?.payload?.name);
  });

  eventBus.on(EventType.TOOL_RESULT, (event) => {
    const r = event?.payload?.result;
    console.log('\n[TOOL RESULT]', r?.success ? 'OK' : 'FAIL');
    if (r?.output) console.log('  Output:', r.output.substring(0, 150));
    if (r?.error) console.log('  Error:', r.error);
  });

  eventBus.on(EventType.TOOL_ERROR, (event) => {
    console.log('\n[TOOL ERROR]', event?.payload?.error);
  });

  eventBus.on(EventType.AGENT_MESSAGE, (event) => {
    const content = event?.payload?.content || '';
    console.log('\n[AGENT MESSAGE]', content.substring(0, 200));
  });

  await agent.processInput('Crie apenas o arquivo test.txt com conteudo "Hello World" usando write_file');
  
  console.log('\n\n=== FIM ===');
}

main().catch(console.error);
