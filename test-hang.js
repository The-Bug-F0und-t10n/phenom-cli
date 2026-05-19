// Test para identificar causa do travamento
import { OllamaClient } from './src/ollama-client.js';
import { eventBus, EventType } from './src/tui/event-bus.js';

console.log('=== TESTE DE TRAVAMENTO ===\n');

// Monitorar eventos
let eventCount = 0;
const events = [];

eventBus.on(EventType.TOKEN_UPDATE, (e) => {
  eventCount++;
  events.push({ type: 'TOKEN_UPDATE', payload: e.payload });
  console.log(`[${eventCount}] TOKEN_UPDATE:`, e.payload);
});

eventBus.on(EventType.PROGRESS_UPDATE, (e) => {
  eventCount++;
  events.push({ type: 'PROGRESS_UPDATE', payload: e.payload });
  console.log(`[${eventCount}] PROGRESS_UPDATE:`, e.payload?.message);
});

eventBus.on(EventType.MESSAGE_CHUNK, (e) => {
  eventCount++;
  events.push({ type: 'MESSAGE_CHUNK', chunk: e.payload?.chunk?.slice(0, 20) });
  console.log(`[${eventCount}] MESSAGE_CHUNK:`, e.payload?.chunk?.slice(0, 50));
});

const client = new OllamaClient();

console.log('Testando chat() com stream: false...\n');

const messages = [
  { role: 'system', content: 'You are a helpful assistant.' },
  { role: 'user', content: 'Say "hello" in JSON: {"type":"final","content":"hello"}' }
];

console.log('Chamando client.chat()...');
const startTime = Date.now();

client.chat(messages)
  .then(response => {
    const elapsed = Date.now() - startTime;
    console.log(`\n✓ Resposta recebida em ${elapsed}ms`);
    console.log('Response:', JSON.stringify(response, null, 2));
    console.log(`\nTotal de eventos emitidos: ${eventCount}`);
    console.log('Eventos:', events);
  })
  .catch(error => {
    const elapsed = Date.now() - startTime;
    console.error(`\n✗ Erro após ${elapsed}ms:`, error.message);
  });

// Timeout de segurança
setTimeout(() => {
  console.error('\n✗ TIMEOUT - chat() não retornou em 30s');
  console.log(`Eventos emitidos até agora: ${eventCount}`);
  console.log('Últimos eventos:', events.slice(-5));
  process.exit(1);
}, 30000);
