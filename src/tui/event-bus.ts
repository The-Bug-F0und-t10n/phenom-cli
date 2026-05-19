/**
 * Event Bus - Sistema pub/sub para comunicação assíncrona
 */

export enum EventType {
  USER_MESSAGE = 'USER_MESSAGE',
  AGENT_MESSAGE = 'AGENT_MESSAGE',
  MESSAGE_CHUNK = 'MESSAGE_CHUNK',
  TOOL_START = 'TOOL_START',
  TOOL_RESULT = 'TOOL_RESULT',
  TOOL_ERROR = 'TOOL_ERROR',
  THINK_START = 'THINK_START',
  THINK_END = 'THINK_END',
  STATE_UPDATE = 'STATE_UPDATE',
  TOKEN_UPDATE = 'TOKEN_UPDATE',
  TODO_UPDATE = 'TODO_UPDATE',
  THINKING_MESSAGE = 'THINKING_MESSAGE',
  FILE_DIFF = 'FILE_DIFF',
  INSIGHT = 'INSIGHT',
  INFERENCE_CANCEL = 'INFERENCE_CANCEL',
  WELCOME_MESSAGE = 'WELCOME_MESSAGE',
  PROGRESS_UPDATE = 'PROGRESS_UPDATE',
  DELIBERATION_UPDATE = 'DELIBERATION_UPDATE',
  SEARCH_START = 'SEARCH_START',
  SEARCH_RESULTS = 'SEARCH_RESULTS',
  SEARCH_ERROR = 'SEARCH_ERROR',
  AGENT_NARRATION = 'AGENT_NARRATION',
  SESSION_UPDATE = 'SESSION_UPDATE',
  CLEAR_STREAMING = 'CLEAR_STREAMING',
  REASONING_CHUNK = 'REASONING_CHUNK',
}

export interface Event {
  type: EventType;
  payload: any;
  timestamp: number;
}

type EventHandler = (event: Event) => void;

export class EventBus {
  private handlers: Map<EventType, Set<EventHandler>> = new Map();

  /**
   * Registra um handler para um tipo de evento
   */
  on(type: EventType, handler: EventHandler): () => void {
    if (!this.handlers.has(type)) {
      this.handlers.set(type, new Set());
    }
    
    this.handlers.get(type)!.add(handler);
    
    // Retorna função para unsubscribe
    return () => {
      this.handlers.get(type)?.delete(handler);
    };
  }

  /**
   * Emite um evento para todos os handlers registrados
   */
  emit(type: EventType, payload: any): void {
    const event: Event = {
      type,
      payload,
      timestamp: Date.now(),
    };
    const handlers = this.handlers.get(type);
    if (handlers) {
      handlers.forEach(handler => {
        try {
          handler(event);
        } catch (error) {
          console.error(`Error in event handler for ${type}:`, error);
        }
      });
    }
  }

  /**
   * Remove todos os handlers de um tipo
   */
  off(type: EventType): void {
    this.handlers.delete(type);
  }

  /**
   * Remove todos os handlers
   */
  clear(): void {
    this.handlers.clear();
  }
}

// Singleton global
export const eventBus = new EventBus();
