/**
 * Test file for the simple hello world agent
 */

import { helloAgent, ShellCommandAgent } from "./src/simple-hello-agent";

async function main() {
  console.log(`=== Testing ${helloAgent.name} ===`);
  console.log(`Description: ${helloAgent.description}`);
  console.log("");
  
  // Test 1: List available commands
  console.log("1. Available commands:");
  const commands = helloAgent.listCommands();
  console.log(`   Total commands: ${commands.length}`);
  console.log(`   Commands: ${commands.join(", ")}`);
  console.log("");
  
  // Test 2: Run a simple echo command
  console.log("2. Running 'echo Hello, World!':");
  const result1 = await helloAgent.runCommand("echo Hello, World!");
  console.log(`   Output: "${result1.stdout.trim()}"`);
  console.log(`   Exit code: ${result1.exitCode}`);
  console.log("");
  
  // Test 3: Run pwd
  console.log("3. Running 'pwd':");
  const result2 = await helloAgent.runCommand("pwd");
  console.log(`   Output: "${result2.stdout.trim()}"`);
  console.log("");
  
  // Test 4: Run date
  console.log("4. Running 'date':");
  const result3 = await helloAgent.runCommand("date");
  console.log(`   Output: "${result3.stdout.trim()}"`);
  console.log("");
  
  // Test 5: Run whoami
  console.log("5. Running 'whoami':");
  const result4 = await helloAgent.runCommand("whoami");
  console.log(`   Output: "${result4.stdout.trim()}"`);
  console.log("");
  
  // Test 6: Run a more complex command (ls -la)
  console.log("6. Running 'ls -la':");
  const result5 = await helloAgent.runCommand("ls -la");
  console.log(`   Output:\n${result5.stdout}`);
  console.log("");
  
  // Test 7: Run a command with error (invalid command)
  console.log("7. Running 'nonexistent_command_xyz':");
  const result6 = await helloAgent.runCommand("nonexistent_command_xyz");
  console.log(`   Output: "${result6.stdout.trim()}"`);
  console.log(`   Stderr: "${result6.stderr.trim()}"`);
  console.log(`   Exit code: ${result6.exitCode}`);
  console.log("");
  
  console.log("=== All tests completed successfully! ===");
}

main().catch(console.error);
