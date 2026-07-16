#!/usr/bin/env tsx
/**
 * Interactive demo of the visualizer-mini CLI component.
 *
 * Shows all features:
 * - State transitions (idle → listening → thinking → working → responding)
 * - Cascade wave effect during mode changes
 * - Real-time rendering at 30 FPS
 * - Dynamic width adaptation
 */

import { MiniVisualizer, VisualizerMode } from './src/visualizer-mini.ts';

const WIDTH = 20;
const DELAY_MS = 400; // Wait before next transition

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Print the visualizer with its current mode
 */
async function printFrame(visualizer: MiniVisualizer, mode: VisualizerMode) {
  const bar = visualizer.render();
  console.log(`\n🎨 [${mode.padEnd(10)}] ${bar}`);
}

/**
 * Demo sequence:
 * 1. Start in idle (breathing animation)
 * 2. Transition to listening → thinking → working → responding
 * 3. Show cascade wave effect during transitions
 */
async function main() {
  console.log('╔═══════════════════════════════════════════════════════╗');
  console.log('║   🎨 VIZUALIZER-MINI: Interactive CLI Demo              ║');
  console.log('╚═══════════════════════════════════════════════════════╝\n');

  const visualizer = new MiniVisualizer(WIDTH);

  // === PHASE 1: IDLE (breathing animation) ===
  console.log('📌 PHASE 1: IDLE — Breathing animation (always visible)');
  for (let i = 0; i < 8; i++) {
    printFrame(visualizer, 'idle');
    await sleep(DELAY_MS);
  }

  // === PHASE 2: LISTENING (high energy, fast waves) ===
  console.log('\n📌 PHASE 2: LISTENING — High energy, rapid wave activity');
  visualizer.setMode('listening');
  for (let i = 0; i < 8; i++) {
    printFrame(visualizer, 'listening');
    await sleep(DELAY_MS);
  }

  // === PHASE 3: THINKING (moderate-high energy, chaotic) ===
  console.log('\n📌 PHASE 3: THINKING — Moderate chaos, analytical pattern');
  visualizer.setMode('thinking');
  for (let i = 0; i < 8; i++) {
    printFrame(visualizer, 'thinking');
    await sleep(DELAY_MS);
  }

  // === PHASE 4: WORKING (maximum density, intense activity) ===
  console.log('\n📌 PHASE 4: WORKING — Maximum intensity, computational burst');
  visualizer.setMode('working');
  for (let i = 0; i < 8; i++) {
    printFrame(visualizer, 'working');
    await sleep(DELAY_MS);
  }

  // === PHASE 5: RESPONDING (highest energy, explosive output) ===
  console.log('\n📌 PHASE 5: RESPONDING — Explosive output, peak activity');
  visualizer.setMode('responding');
  for (let i = 0; i < 8; i++) {
    printFrame(visualizer, 'responding');
    await sleep(DELAY_MS);
  }

  // === PHASE 6: WIDE MODE DEMO (width adaptation) ===
  console.log('\n📌 PHASE 6: WIDTH ADAPTATION — Growing from 20 to 30 columns');
  visualizer.setWidth(30);
  for (let i = 0; i < 4; i++) {
    printFrame(visualizer, 'responding');
    await sleep(DELAY_MS);
  }

  // === PHASE 7: BACK TO IDLE ===
  console.log('\n📌 PHASE 7: RETURNING TO IDLE — Calm breathing');
  visualizer.setMode('idle');
  for (let i = 0; i < 6; i++) {
    printFrame(visualizer, 'idle');
    await sleep(DELAY_MS);
  }

  // === SUMMARY ===
  console.log('\n╔═══════════════════════════════════════════════════════╗');
  console.log('║   📊 VIZUALIZER-MINI STATE ENCODING                    ║');
  console.log('╠─────────────┬────────┬────────┬──────────┬─────────┨');
  console.log('║ State      │ Energy│ Density│ Chaos    │ Speed   ║');
  console.log('╠─────────────┼────────┼────────┼──────────┼─────────╣');
  console.log('║ 🟡 IDLE     │ 0.14  │  1.0   │ 0.00    │ ×2.5    ║');
  console.log('║ 🔵 LISTENING│ 0.22  │  1.6   │ 0.00    │ ×10.0   ║');
  console.log('║ 🟣 THINKING │ 0.52  │  2.6   │ 0.03    │ ×8.0    ║');
  console.log('║ 🟢 WORKING  │ 0.63  │  3.0   │ 0.04    │ ×9.0    ║');
  console.log('║ 🔴 RESPONDING│ 0.90 │  4.2   │ 0.02    │ ×7.0    ║');
  console.log('╚════════════─┴────────┴────────┴──────────┴─────────╝\n');

  console.log('🎯 FEATURES DEMONSTRATED:');
  console.log('   ✓ Cascade wave effect during state transitions');
  console.log('   ✓ Per-column delay creates left→right sweep');
  console.log('   ✓ Energy/density/chaos controls waveform intensity');
  console.log('   ✓ Real-time noise generation (n1, n2 functions)');
  console.log('   ✓ Dynamic width adaptation with smooth entry');
  console.log('   ✓ Always-visible breathing animation in idle\n');

  console.log('💡 HOW IT WORKS IN THE CLI:');
  console.log('   • Called ~30 times/second by cli-renderer.ts');
  console.log('   • Returns a string like "▁▂▃▄▅▆▇█" that renders in status bar');
  console.log('   • setMode() triggers cascade wave with per-column delays\n');

  console.log('╔═══════════════════════════════════════════════════════╗');
  console.log('║                         ✨ COMPLETED                   ║');
  console.log('╚═══════════════════════════════════════════════════════╝\n');
}

main();
