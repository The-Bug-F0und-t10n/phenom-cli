#!/usr/bin/env node

/**
 * TUI Entry Point - Professional layout
 */

import { ProfessionalTUI } from './tui/professional-tui.js';
import { Agent } from './agent.js';

async function main() {
  // Mostrar diretório de trabalho
  console.log('Diretório de trabalho:', process.cwd());
  console.log('Arquivos serão criados em:', process.cwd());
  console.log('');
  
  // Criar Agent
  const agent = new Agent();
  await agent.initialize();

  // Criar TUI profissional e passar o agent
  const tui = new ProfessionalTUI(agent);

  // Start TUI
  tui.start();
}

main().catch(console.error);
