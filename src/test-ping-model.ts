import { OllamaClient } from './ollama-client.js';

process.env.OLLAMA_HOST = 'http://192.168.1.122:11434';
process.env.OLLAMA_NUM_CTX = '4096';
process.env.OLLAMA_CODER_MODEL = 'qwen2.5-coder:1.5b-instruct-q4_K_M';
process.env.OLLAMA_CHAT_MODEL = 'qwen2.5-coder:1.5b-instruct-q4_K_M';

async function main() {
  const client = new OllamaClient();
  console.log(`Modelo ativo: ${(client as any).activeModel}\n`);

  const msg = [{ role: 'user', content: 'Say hello in one word' }];
  console.time('chat');
  try {
    const res = await client.chat(msg as any);
    console.timeEnd('chat');
    const content = res?.message?.content || JSON.stringify(res).slice(0, 300);
    console.log('Resposta:', content);
  } catch (err: any) {
    console.timeEnd('chat');
    console.error('Erro:', err.message);
    if ('response' in err) console.error('Status:', (err as any).response?.status);
  }
}
main();
