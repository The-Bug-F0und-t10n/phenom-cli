/**
 * Test script to verify visualizer wrapper integration
 */

import { start, stop, isActive, getPid } from './src/visualizer-wrapper.js';

async function testVisualizer() {
  console.log('=== Testing Visualizer Wrapper ===\n');
  
  // Test 1: Check if visualizer path is found
  const wrapper = await import('./src/visualizer-wrapper.js');
  console.log('1. Wrapper initialized:', wrapper.wrapper !== undefined);
  
  // Test 2: Try to start visualizer
  console.log('\n2. Attempting to start visualizer...');
  const result = await start();
  console.log('   Start result:', result);
  
  // Test 3: Check if active
  console.log('\n3. Is visualizer active?', isActive());
  console.log('   Process ID:', getPid());
  
  // Test 4: Try starting again (should return already running)
  console.log('\n4. Attempting to start again...');
  const result2 = await start();
  console.log('   Second start result:', result2);
  
  // Test 5: Stop visualizer
  console.log('\n5. Stopping visualizer...');
  await stop();
  console.log('   Stop completed');
  
  // Test 6: Check after stop
  console.log('\n6. Is visualizer active after stop?', isActive());
  
  console.log('\n=== Test Complete ===');
}

testVisualizer().catch(console.error);
