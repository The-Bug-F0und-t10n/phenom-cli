/**
 * Visualizer Wrapper - Bridges Python visualizer.py with the Phenom CLI
 * 
 * This module provides a simple API to start/stop the visualizer and manage
 * its lifecycle within the CLI session.
 */

import { exec } from 'child_process';
import { promisify } from 'util';
import { existsSync, readFileSync } from 'fs';
import { join, dirname} from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

const execAsync = promisify(exec);

let visualizerProcess = null;
let visualizerPath = null;
let visualizerPid = null;
let visualizerStarted = false;

// Default path to visualizer.py (relative to this file)
const DEFAULT_VISUALIZER_PATH = join(__dirname, '..', 'visualizer.py');

/**
 * Initialize the visualizer wrapper
 */
export function initVisualizerWrapper() {
  // Determine visualizer path
  if (existsSync(DEFAULT_VISUALIZER_PATH)) {
    visualizerPath = DEFAULT_VISUALIZER_PATH;
  } else {
    // Try to find visualizer.py in parent directories
    const possiblePaths = [
      join(process.cwd(), 'visualizer.py'),
      join(process.cwd(), 'src', 'visualizer.py'),
      join(process.cwd(), 'phenom-cli', 'visualizer.py'),
      join(process.cwd(), 'cli-ai', 'visualizer.py'),
    ];
    
    for (const path of possiblePaths) {
      if (existsSync(path)) {
        visualizerPath = path;
        break;
      }
    }
  }
  
  return {
    visualizerPath,
    start,
    stop,
    isActive,
    getPid
  };
}

/**
 * Start the visualizer process
 * @returns {Promise<{pid: number, stdout: string, stderr: string}>}
 */
export async function start() {
  if (!visualizerPath) {
    console.error('[Visualizer] visualizer.py not found. Cannot start.');
    return null;
  }

  if (visualizerStarted) {
    console.log('[Visualizer] Visualizer already running (PID: ' + visualizerPid + ')');
    return { pid: visualizerPid };
  }

  try {
    // Start the visualizer as a background process
    const { pid } = await execAsync(`python3 ${visualizerPath}`);
    
    visualizerProcess = { pid, stdout: '', stderr: '' };
    visualizerPid = pid;
    visualizerStarted = true;
    
    console.log(`[Visualizer] Started (PID: ${pid})`);
    console.log(`[Visualizer] Path: ${visualizerPath}`);
    
    // Monitor stdout/stderr in real-time
    const monitorStream = async () => {
      if (!visualizerStarted) return;
      
      // In a real implementation, we'd use child_process.spawn with proper stream handling
      // For now, just acknowledge that the process is running
    };
    
    monitorStream();
    
    return { pid, stdout: '', stderr: '' };
  } catch (error) {
    console.error('[Visualizer] Failed to start:', error.message);
    return null;
  }
}

/**
 * Stop the visualizer process gracefully
 */
export async function stop() {
  if (!visualizerStarted || !visualizerPid) {
    console.log('[Visualizer] No visualizer running');
    return;
  }

  try {
    // Send SIGTERM for graceful shutdown
    await execAsync(`kill -TERM ${visualizerPid}`);
    
    // Wait a bit for graceful shutdown
    await new Promise(resolve => setTimeout(resolve, 500));
    
    // Force kill if still running
    await execAsync(`kill -9 ${visualizerPid}`);
    
    visualizerStarted = false;
    visualizerPid = null;
    console.log(`[Visualizer] Stopped (was PID: ${visualizerPid})`);
  } catch (error) {
    console.error('[Visualizer] Error stopping:', error.message);
  }
}

/**
 * Check if visualizer is currently running
 * @returns {boolean}
 */
export function isActive() {
  return visualizerStarted && visualizerPid !== null;
}

/**
 * Get the visualizer process ID
 * @returns {number|null}
 */
export function getPid() {
  return visualizerPid;
}

/**
 * Get wrapper instance for direct access
 */
export const wrapper = initVisualizerWrapper();

export default wrapper;
