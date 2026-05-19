import { Agent } from './src/agent.js';
import { eventBus, EventType } from './src/tui/event-bus.js';
import { promises as fs } from 'fs';
import path from 'path';

const testDir = path.join(process.cwd(), '.test-tasks');

async function main() {
  console.log('=== Test Tarefas Individuais ===');
  
  await fs.mkdir(testDir, { recursive: true });
  process.chdir(testDir);

  const agent = new Agent();
  await agent.initialize();

  console.log('\n--- Task 1: Criar estrutura ---');
  await agent.processInput('Crie a pasta src/ e um arquivo src/calculator.js com função sum(a,b) { return a + b; }');
  
  console.log('\n--- Files created: ---');
  const files = await fs.readdir('.', { recursive: true });
  console.log(files);
  
  try {
    const content = await fs.readFile('src/calculator.js', 'utf-8');
    console.log('calculator.js:', content);
  } catch (e) {}

  console.log('\n--- Task 2: Apply patch ---');
  await agent.processInput('Adicione função subtract(a,b) no arquivo src/calculator.js usando apply_patch. A função deve retornar a - b');
  
  try {
    const content = await fs.readFile('src/calculator.js', 'utf-8');
    console.log('calculator.js after patch:', content);
  } catch (e) {}

  await fs.rm(testDir, { recursive: true, force: true });
  console.log('\n--- Done ---');
}

main().catch(e => {
  console.error('Error:', e.message);
  process.exit(1);
});