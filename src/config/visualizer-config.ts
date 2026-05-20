/**
 * Configurações e mapeamento de estados entre Phenom CLI e visualizer.py
 */

import { EventType } from '../tui/event-bus.js';

// ============================================================================
// Mapeamento de Estados
// ============================================================================

/**
 * Estados do visualizer.py com seus parâmetros de animação
 */
export interface VisualizerState {
  name: string;
  label: string;
  energy: number;      // Intensidade das ondas
  density: number;     // Amplitude do ruído
  chaos: number;       // Variações aleatórias
  spd_factor: number;  // Velocidade de propagação
}

export const VISUALIZER_STATES: Record<string, VisualizerState> = {
  idle: {
    name: 'idle',
    label: 'em silêncio',
    energy: 0.00,
    density: 0.0,
    chaos: 0.00,
    spd_factor: 0.0,
  },
  listening: {
    name: 'listening',
    label: 'ouvindo você',
    energy: 0.22,
    density: 1.6,
    chaos: 0.00,
    spd_factor: 10.0,
  },
  thinking: {
    name: 'thinking',
    label: 'pensando',
    energy: 0.52,
    density: 2.6,
    chaos: 0.03,
    spd_factor: 8.0,
  },
  confused: {
    name: 'confused',
    label: 'com dúvidas',
    energy: 0.78,
    density: 3.4,
    chaos: 0.18,
    spd_factor: 11.0,
  },
  solving: {
    name: 'solving',
    label: 'resolvendo',
    energy: 0.63,
    density: 3.0,
    chaos: 0.04,
    spd_factor: 9.0,
  },
  responding: {
    name: 'responding',
    label: 'respondendo',
    energy: 0.90,
    density: 4.2,
    chaos: 0.02,
    spd_factor: 10.0,
  },
};

// ============================================================================
// Mapeamento de Eventos do Phenom
// ============================================================================

/**
 * Mapeia eventos do Phenom CLI para estados do visualizer
 */
export const EVENT_TO_STATE_MAP: Record<EventType | string, string> = {
  // Estados de espera/idle
  [EventType.USER_MESSAGE]: 'listening',
  [EventType.SEARCH_START]: 'thinking',
  
  // Estados de processamento
  [EventType.THINK_START]: 'thinking',
  [EventType.PROGRESS_UPDATE]: 'thinking',
  [EventType.SEARCH_RESULTS]: 'solving',
  
  // Estados de confusão/dúvida
  [EventType.TOOL_ERROR]: 'confused',
  [EventType.SEARCH_ERROR]: 'confused',
  
  // Estados de resposta
  [EventType.THINK_END]: 'responding',
  [EventType.AGENT_MESSAGE]: 'responding',
  
  // Estado de retorno ao idle
  [EventType.CLEAR_STREAMING]: 'idle',
  [EventType.INFERENCE_CANCEL]: 'idle',
};

// ============================================================================
// Configurações de Renderização
// ============================================================================

export interface VisualizerConfig {
  /** Caminho para o arquivo visualizer.py */
  path: string;
  
  /** Tamanho do terminal (em colunas) */
  terminalWidth: number;
  
  /** Intervalo de atualização (ms) */
  refreshRate: number;
  
  /** Se true, executa o visualizador em segundo plano */
  background: boolean;
  
  /** Se true, exibe o estado atual */
  showStatus: boolean;
  
  /** Se true, reinicia o visualizador quando o terminal mudar de tamanho */
  autoResize: boolean;
  
  /** Prefixo para o output do visualizador */
  prefix: string;
}

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
// Utilitários
// ============================================================================

/**
 * Obtém o estado do visualizer baseado em um evento
 */
export function getStateForEvent(eventType: EventType | string): VisualizerState {
  const stateName = EVENT_TO_STATE_MAP[eventType] || 'idle';
  return VISUALIZER_STATES[stateName] || VISUALIZER_STATES.idle;
}

/**
 * Obtém o estado atual do Phenom CLI
 */
export function getCurrentPhenomState(): string {
  // Retorna um estado baseado no contexto atual
  // Implementação real dependeria do estado interno do Phenom
  return 'thinking';
}

/**
 * Verifica se o visualizador deve ser ativado
 */
export function shouldEnableVisualizer(): boolean {
  const { stdout } = process;
  
  // Não ativa se não for um TTY
  if (!stdout.isTTY) {
    return false;
  }
  
  // Verifica se o visualizer.py existe
  const fs = require('fs');
  const path = require('path');
  const visualizerPath = path.join(process.cwd(), 'visualizer.py');
  
  if (!fs.existsSync(visualizerPath)) {
    console.error('[Visualizer] visualizer.py não encontrado');
    return false;
  }
  
  // Verifica se Python está disponível
  try {
    const { execSync } = require('child_process');
    execSync('python3 --version', { stdio: 'ignore' });
  } catch {
    console.error('[Visualizer] Python3 não encontrado');
    return false;
  }
  
  return true;
}
