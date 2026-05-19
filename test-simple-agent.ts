import { Agent } from './src/agent.js';
import { eventBus, EventType } from './src/tui/event-bus.js';
import { promises as fs } from 'fs';
import path from 'path';

const testDir = path.join(process.cwd(), '.test-simple-agent');

async function main() {
  console.log('=== Test Simples ===');
  
  await fs.mkdir(testDir, { recursive: true });
  process.chdir(testDir);

  const agent = new Agent();
  await agent.initialize();
  
  console.log('\n--- Creating package.json ---');
  await agent.processInput('Crie um arquivo package.json com nome "test" e versão "1.0.0"');
  
  console.log('\n--- Checking file ---');
  try {
    const content = await fs.readFile('package.json', 'utf-8');
    console.log('Content:', content);
  } catch (e) {
    console.log('File not found');
  }
  
  await fs.rm(testDir, { recursive: true, force: true });
  console.log('\n--- Done ---');
}

main().catch(e => {
  console.error('Error:', e.message);
  process.exit(1);
});