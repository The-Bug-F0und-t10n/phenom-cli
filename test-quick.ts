import { Agent } from './src/agent.js';
import { promises as fs } from 'fs';
import path from 'path';

const testDir = path.join(process.cwd(), '.test-quick');

async function main() {
  await fs.mkdir(testDir, { recursive: true });
  process.chdir(testDir);

  const agent = new Agent();
  await agent.initialize();
  
  console.log('--- Creating package.json ---');
  const t0 = Date.now();
  await agent.processInput('Crie arquivo package.json com name=test e version=1.0.0');
  const t1 = Date.now();
  console.log('Time:', t1 - t0, 'ms');
  
  try {
    const content = await fs.readFile('package.json', 'utf-8');
    console.log('✅ File created:', content);
  } catch (e) {
    console.log('❌ File NOT created');
  }
  
  await fs.rm(testDir, { recursive: true, force: true });
}

main().catch(console.error);