#!/usr/bin/env node
/**
 * Debug do shouldUseTool
 */

const stepAction = 'Crie um novo arquivo chamado styles.css';
const action = stepAction.toLowerCase();

console.log('Step Action:', stepAction);
console.log('Action (lowercase):', action);

const toolKeywords = [
  'ler', 'read', 'buscar', 'search', 'listar', 'list',
  'escrever', 'write', 'criar', 'create',
  'git', 'commit', 'diff', 'status',
  'executar', 'run', 'testar', 'test'
];

console.log('\nTestando keywords:');
toolKeywords.forEach(keyword => {
  const includes = action.includes(keyword);
  console.log(`  "${keyword}": ${includes}`);
});

const shouldUse = toolKeywords.some(keyword => action.includes(keyword));
console.log('\nshouldUseTool:', shouldUse);

// Testar selectTool
console.log('\nTestando selectTool conditions:');
console.log('  action.includes("criar"):', action.includes('criar'));
console.log('  action.includes("create"):', action.includes('create'));
console.log('  action.includes("escrever"):', action.includes('escrever'));
console.log('  action.includes("write"):', action.includes('write'));
