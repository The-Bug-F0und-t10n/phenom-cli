/**
 * Visualizer Adapter - Conecta o Phenom CLI com o visualizer.py
 */

import { spawn, SpawnOptions, ChildProcess } from 'child_process';
import { EventEmitter } from 'events';
import { VisualizerConfig, VisualizerState, EVENT_TO_STATE_MAP } from '../config/visualizer-config.js';
import { EventType } from './event-bus.js';

// ============================================================================
// Interface de Eventos do Visualizer
// ============================================================================

export interface VisualizerEvent {
  type: string;
  payload: {
    state?: string;
    progress?: number;
    label?: string;
    timestamp?: number;
  };
  timestamp: number;
}

export type VisualizerEventHandler = (event: VisualizerEvent) => void;

// ============================================================================
// Classe Adapter
// ============================================================================

export class VisualizerAdapter extends EventEmitter {
  private process: ChildProcess | null = null;
  private config: VisualizerConfig;
  private currentVisualizerState: string = 'idle';
  private stateHistory: string[] = [];
  private transitionTimeout: NodeJS.Timeout | null = null;
  private isTransitioning: boolean = false;
  private transitionStartTime: number = 0;
  private transitionDuration: number = 500; // ms
  private maxHistoryLength: number = 100;
  
  constructor(config: Partial<VisualizerConfig> = {}) {
    super();
    this.config = {
      ...DEFAULT_CONFIG,
      ...config,
    };
  }
  
  /**
   * Inicia o visualizer.py como subprocess
   */
  start(): void {
    if (this.process) {
      console.error('[Visualizer] Já está em execução');
      return;
    }
    
    const args = ['visualizer.py'];
    
    // Spawn options
    const options: SpawnOptions = {
      cwd: process.cwd(),
      stdio: ['ignore', 'pipe', 'pipe'], // ignore stdin, pipe stdout/stderr
      shell: true,
    };
    
    console.log(`[Visualizer] Inicializando...`);
    console.log(`[Visualizer] Comando: ${args.join(' ')}`);
    
    try {
      this.process = spawn('python3', args, options);
      
      // Handle stdout
      this.process.stdout.on('data', (data: Buffer) => {
        const output = data.toString();
        this.handleVisualizerOutput(output);
      });
      
      // Handle stderr (debug info)
      this.process.stderr.on('data', (data: Buffer) => {
        const output = data.toString();
        console.log(`[Visualizer] ${output.trim()}`);
      });
      
      // Handle exit
      this.process.on('error', (error: Error) => {
        console.error(`[Visualizer] Erro no processo: ${error.message}`);
        this.onVisualizerExit(error);
      });
      
      this.process.on('exit', (code: number, signal: string) => {
        this.onVisualizerExit(new Error(`Exit: ${code}, Signal: ${signal}`));
      });
      
      this.process.on('close', (code: number | null, signal: string) => {
        this.onVisualizerClose(code, signal);
      });
      
      // Handle SIGINT/SIGTERM
      const handleSignal = (signal: string) => {
        console.log(`\n[Visualizer] Recebido sinal ${signal}. Limpando...`);
        this.cleanup(signal);
      };
      
      process.on('SIGINT', () => handleSignal('SIGINT'));
      process.on('SIGTERM', () => handleSignal('SIGTERM'));
      
      // Start the visualizer
      this.process.stdin.write('\n'); // Initialize
      
      console.log(`[Visualizer] Pronto para receber eventos`);
      
    } catch (error) {
      console.error(`[Visualizer] Falha ao iniciar: ${error}`);
    }
  }
  
  /**
   * Envia um evento para o visualizer
   */
  emitVisualizerEvent(type: string, payload: Partial<VisualizerEvent['payload']>): void {
    if (!this.process) {
      console.error('[Visualizer] Visualizer não está em execução');
      return;
    }
    
    const event: VisualizerEvent = {
      type,
      payload,
      timestamp: Date.now(),
    };
    
    // Log para debug
    console.log(`[Visualizer] Emitindo evento: ${type}`, payload);
    
    // Send to visualizer via stdin (if needed)
    // For now, we just log and update our internal state
    
    // Emit to Phenom's event bus
    this.emit('visualizer:event', event);
  }
  
  /**
   * Atualiza o estado do visualizer
   */
  updateVisualizerState(stateName: string, progress: number = 0): void {
    if (this.isTransitioning && stateName === this.currentVisualizerState) {
      return; // Same state, no need to update
    }
    
    const visualizerState = VISUALIZER_STATES[stateName];
    if (!visualizerState) {
      console.warn(`[Visualizer] Estado desconhecido: ${stateName}`);
      return;
    }
    
    // Update current state
    this.currentVisualizerState = stateName;
    this.stateHistory.push(stateName);
    
    // Limit history length
    if (this.stateHistory.length > this.maxHistoryLength) {
      this.stateHistory.shift();
    }
    
    // Emit event
    this.emitVisualizerEvent('state:change', {
      state: stateName,
      progress,
      label: visualizerState.label,
    });
    
    // Schedule next state transition
    if (this.transitionTimeout) {
      clearTimeout(this.transitionTimeout);
    }
    
    this.transitionTimeout = setTimeout(() => {
      this.isTransitioning = false;
      this.transitionStartTime = 0;
      this.updateVisualizerState(stateName, progress);
    }, this.transitionDuration);
  }
  
  /**
   * Processa output do visualizer.py
   */
  private handleVisualizerOutput(output: string): void {
    // Parse visualizer output
    // The visualizer outputs to stderr for debug/info
    
    // Example output format:
    // [INFO] Starting visualization
    // [DEBUG] State: idle -> listening
    // [WARN] Low memory usage
    
    const lines = output.split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      
      // Parse different types of output
      if (trimmed.startsWith('[DEBUG]')) {
        // Debug message
        const match = trimmed.match(/\[(\w+)\]\s*(.+)\s*->\s*(\w+)/);
        if (match) {
          const [, level, from, to] = match;
          this.emitVisualizerEvent('debug', {
            level,
            from,
            to,
          });
        }
      } else if (trimmed.startsWith('[INFO]')) {
        // Info message
        this.emitVisualizerEvent('info', { message: trimmed });
      } else if (trimmed.startsWith('[WARN]')) {
        // Warning
        this.emitVisualizerEvent('warn', { message: trimmed });
      } else if (trimmed.startsWith('[ERROR]')) {
        // Error
        this.emitVisualizerEvent('error', { message: trimmed });
      }
    }
  }
  
  /**
   * Handle visualizer process exit
   */
  private onVisualizerExit(error: Error): void {
    console.error(`[Visualizer] Erro: ${error.message}`);
    this.emit('visualizer:error', error);
  }
  
  /**
   * Handle visualizer process close
   */
  private onVisualizerClose(code: number | null, signal: string): void {
    console.log(`[Visualizer] Processo fechado: ${code}, ${signal}`);
    this.emit('visualizer:close', { code, signal });
  }
  
  /**
   * Cleanup on exit
   */
  private cleanup(signal: string): void {
    if (this.process) {
      this.process.kill();
      this.process = null;
    }
    
    if (this.transitionTimeout) {
      clearTimeout(this.transitionTimeout);
    }
    
    console.log(`[Visualizer] Limpado pelo sinal ${signal}`);
    this.emit('visualizer:cleanup', { signal });
  }
  
  /**
   * Stop the visualizer
   */
  stop(): void {
    console.log('[Visualizer] Parando...');
    
    if (this.process) {
      this.process.kill();
      this.process = null;
    }
    
    if (this.transitionTimeout) {
      clearTimeout(this.transitionTimeout);
    }
    
    this.emit('visualizer:stop');
  }
  
  /**
   * Get current visualizer state
   */
  getCurrentState(): string {
    return this.currentVisualizerState;
  }
  
  /**
   * Get state history
   */
  getStateHistory(): string[] {
    return [...this.stateHistory];
  }
  
  /**
   * Check if visualizer is running
   */
  isRunning(): boolean {
    return this.process !== null;
  }
  
  /**
   * Get config
   */
  getConfig(): VisualizerConfig {
    return { ...this.config };
  }
  
  /**
   * Update config
   */
  updateConfig(config: Partial<VisualizerConfig>): void {
    this.config = { ...this.config, ...config };
  }
}

// ============================================================================
// Singleton Instance
// ============================================================================

let visualizerAdapterInstance: VisualizerAdapter | null = null;

export function getVisualizerAdapter(): VisualizerAdapter {
  if (!visualizerAdapterInstance) {
    visualizerAdapterInstance = new VisualizerAdapter();
  }
  return visualizerAdapterInstance;
}

export function startVisualizer(): VisualizerAdapter {
  const adapter = getVisualizerAdapter();
  adapter.start();
  return adapter;
}

export function stopVisualizer(): void {
  const adapter = getVisualizerAdapter();
  adapter.stop();
}
