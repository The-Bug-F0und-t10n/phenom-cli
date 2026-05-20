/**
 * Visualizer Renderer - Integra o visualizer.py com o Phenom CLI
 */

import { CliRenderer } from './cli-renderer.js';
import { VisualizerAdapter, VisualizerEvent } from './visualizer-adapter.js';
import { VisualizerConfig, shouldEnableVisualizer } from '../config/visualizer-config.js';

// ============================================================================
// Interface de Integração
// ============================================================================

export interface VisualizerRendererConfig {
  /** Configuração do visualizer */
  config?: VisualizerConfig;
  
  /** CliRenderer instância */
  renderer?: CliRenderer;
  
  /** Se true, ativa o visualizador automaticamente */
  autoStart?: boolean;
}

// ============================================================================
// Classe VisualizerRenderer
// ============================================================================

export class VisualizerRenderer {
  private adapter: VisualizerAdapter;
  private config: VisualizerConfig;
  private enabled: boolean = false;
  private listeners: Set<() => void> = new Set();
  
  constructor(config: VisualizerRendererConfig = {}) {
    const { config: visualizerConfig, renderer, autoStart = true } = config;
    
    // Create adapter with config
    this.adapter = new VisualizerAdapter(visualizerConfig || {});
    
    // Set default config
    this.config = {
      ...DEFAULT_CONFIG,
      ...visualizerConfig,
    };
    
    // Attach to CliRenderer events
    if (renderer) {
      this.attachToRenderer(renderer);
    }
    
    // Auto-start if enabled
    if (autoStart && shouldEnableVisualizer()) {
      this.start();
    }
  }
  
  /**
   * Inicia o visualizer
   */
  start(): void {
    if (this.enabled) {
      console.log('[Visualizer] Já está ativo');
      return;
    }
    
    console.log('[Visualizer] Iniciando...');
    this.adapter.start();
    this.enabled = true;
    
    // Register event handlers
    this.registerHandlers();
  }
  
  /**
   * Para o visualizer
   */
  stop(): void {
    if (!this.enabled) {
      console.log('[Visualizer] Já está desativado');
      return;
    }
    
    console.log('[Visualizer] Parando...');
    this.adapter.stop();
    this.enabled = false;
    
    // Unregister event handlers
    this.unregisterHandlers();
  }
  
  /**
   * Torna o visualizador ativo/inativo
   */
  toggle(): void {
    if (this.enabled) {
      this.stop();
    } else {
      this.start();
    }
  }
  
  /**
   * Registra handlers de eventos
   */
  private registerHandlers(): void {
    // State change handler
    this.adapter.on('state:change', (event) => {
      console.log(`[Visualizer] Estado: ${event.payload.state}`, event.payload.label);
    });
    
    // Debug handler
    this.adapter.on('debug', (event) => {
      console.log(`[Visualizer] Debug: ${event.payload.level} - ${event.payload.from} -> ${event.payload.to}`);
    });
    
    // Info handler
    this.adapter.on('info', (event) => {
      console.log(`[Visualizer] Info: ${event.payload.message}`);
    });
    
    // Warning handler
    this.adapter.on('warn', (event) => {
      console.warn(`[Visualizer] Aviso: ${event.payload.message}`);
    });
    
    // Error handler
    this.adapter.on('error', (event) => {
      console.error(`[Visualizer] Erro: ${event.payload.message}`);
    });
    
    // Close handler
    this.adapter.on('close', (event) => {
      console.log(`[Visualizer] Fechado: ${event.code}, ${event.signal}`);
    });
    
    // Cleanup handler
    this.adapter.on('cleanup', (event) => {
      console.log(`[Visualizer] Limpeza: ${event.signal}`);
    });
    
    // Stop handler
    this.adapter.on('stop', () => {
      console.log('[Visualizer] Parado');
    });
  }
  
  /**
   * Desregistra handlers de eventos
   */
  private unregisterHandlers(): void {
    // Remove all listeners
    this.adapter.removeAllListeners();
  }
  
  /**
   * Anexa ao CliRenderer
   */
  private attachToRenderer(renderer: CliRenderer): void {
    // Listen to THINK_START event
    renderer.unsubscribers.push(
      renderer.eventBus.on('THINK_START', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('thinking', 0);
        }
      })
    );
    
    // Listen to PROGRESS_UPDATE event
    renderer.unsubscribers.push(
      renderer.eventBus.on('PROGRESS_UPDATE', (event) => {
        if (this.enabled) {
          const stateName = 'thinking';
          this.adapter.updateVisualizerState(stateName, 0);
        }
      })
    );
    
    // Listen to SEARCH_START event
    renderer.unsubscribers.push(
      renderer.eventBus.on('SEARCH_START', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('thinking', 0);
        }
      })
    );
    
    // Listen to SEARCH_RESULTS event
    renderer.unsubscribers.push(
      renderer.eventBus.on('SEARCH_RESULTS', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('solving', 0);
        }
      })
    );
    
    // Listen to THINK_END event
    renderer.unsubscribers.push(
      renderer.eventBus.on('THINK_END', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('responding', 0);
        }
      })
    );
    
    // Listen to AGENT_MESSAGE event
    renderer.unsubscribers.push(
      renderer.eventBus.on('AGENT_MESSAGE', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('responding', 0);
        }
      })
    );
    
    // Listen to CLEAR_STREAMING event
    renderer.unsubscribers.push(
      renderer.eventBus.on('CLEAR_STREAMING', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('idle', 0);
        }
      })
    );
    
    // Listen to INFERENCE_CANCEL event
    renderer.unsubscribers.push(
      renderer.eventBus.on('INFERENCE_CANCEL', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('idle', 0);
        }
      })
    );
    
    // Listen to TOOL_ERROR event
    renderer.unsubscribers.push(
      renderer.eventBus.on('TOOL_ERROR', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('confused', 0);
        }
      })
    );
    
    // Listen to SEARCH_ERROR event
    renderer.unsubscribers.push(
      renderer.eventBus.on('SEARCH_ERROR', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('confused', 0);
        }
      })
    );
    
    // Listen to USER_MESSAGE event
    renderer.unsubscribers.push(
      renderer.eventBus.on('USER_MESSAGE', () => {
        if (this.enabled) {
          this.adapter.updateVisualizerState('listening', 0);
        }
      })
    );
  }
  
  /**
   * Desanexa do CliRenderer
   */
  detachFromRenderer(renderer: CliRenderer): void {
    // Remove all listeners
    renderer.eventBus.off('THINK_START');
    renderer.eventBus.off('PROGRESS_UPDATE');
    renderer.eventBus.off('SEARCH_START');
    renderer.eventBus.off('SEARCH_RESULTS');
    renderer.eventBus.off('THINK_END');
    renderer.eventBus.off('AGENT_MESSAGE');
    renderer.eventBus.off('CLEAR_STREAMING');
    renderer.eventBus.off('INFERENCE_CANCEL');
    renderer.eventBus.off('TOOL_ERROR');
    renderer.eventBus.off('SEARCH_ERROR');
    renderer.eventBus.off('USER_MESSAGE');
  }
  
  /**
   * Verifica se o visualizer está ativo
   */
  isEnabled(): boolean {
    return this.enabled;
  }
  
  /**
   * Obtém o estado atual do visualizer
   */
  getCurrentState(): string {
    return this.adapter.getCurrentState();
  }
  
  /**
   * Obtém a configuração atual
   */
  getConfig(): VisualizerConfig {
    return { ...this.config };
  }
  
  /**
   * Atualiza a configuração
   */
  updateConfig(config: Partial<VisualizerConfig>): void {
    this.config = { ...this.config, ...config };
    this.adapter.updateConfig(config);
  }
  
  /**
   * Obtém o adapter
   */
  getAdapter(): VisualizerAdapter {
    return this.adapter;
  }
}

// ============================================================================
// Configurações Padrão
// ============================================================================

export const DEFAULT_CONFIG: VisualizerConfig = {
  path: '../visualizer.py',
  terminalWidth: 80,
  refreshRate: 33, // ~30 FPS
  background: true,
  showStatus: true,
  autoResize: true,
  prefix: '  ',
};

// ============================================================================
// Singleton Instance
// ============================================================================

let visualizerRendererInstance: VisualizerRenderer | null = null;

export function getVisualizerRenderer(): VisualizerRenderer {
  if (!visualizerRendererInstance) {
    visualizerRendererInstance = new VisualizerRenderer();
  }
  return visualizerRendererInstance;
}

export function startVisualizerRenderer(): VisualizerRenderer {
  const renderer = getVisualizerRenderer();
  renderer.start();
  return renderer;
}

export function stopVisualizerRenderer(): void {
  const renderer = getVisualizerRenderer();
  renderer.stop();
}
