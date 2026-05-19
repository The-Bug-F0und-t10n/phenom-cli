/**
 * State Store - Single source of truth imutável
 */

export interface Message {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number;
  chunks?: string[];
}

export interface ToolBlock {
  id: string;
  name: string;
  args: Record<string, any>;
  status: 'running' | 'success' | 'error';
  result?: any;
  error?: string;
  expanded: boolean;
  timestamp: number;
}

export interface AppState {
  messages: Message[];
  toolBlocks: ToolBlock[];
  currentInput: string;
  isThinking: boolean;
  tokenUsage: {
    input: number;
    output: number;
    total: number;
  };
  modelInfo: {
    name: string;
    mode: 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis';
  };
  gitStatus: {
    branch: string;
    modified: number;
    untracked: number;
  } | null;
  layoutState: {
    width: number;
    height: number;
    scrollOffset: number;
  };
  latency: number;
  todos: Array<{ action: string; status: 'pending' | 'in_progress' | 'done' | 'failed' }>;
  thinkingMessage: string;
  currentStep: number;
  totalSteps: number;
  globalReasoning: string;
}

export class StateStore {
  private state: AppState;
  private listeners: Set<(state: AppState) => void> = new Set();

  constructor() {
    this.state = this.getInitialState();
  }

  private getInitialState(): AppState {
    return {
      messages: [],
      toolBlocks: [],
      currentInput: '',
      isThinking: false,
      tokenUsage: {
        input: 0,
        output: 0,
        total: 0,
      },
      modelInfo: {
        name: 'qwen2.5-coder:latest',
        mode: 'reasoning',
      },
      gitStatus: null,
      layoutState: {
        width: 80,
        height: 24,
        scrollOffset: 0,
      },
      latency: 0,
      todos: [],
      thinkingMessage: '',
      currentStep: 0,
      totalSteps: 0,
      globalReasoning: '',
    };
  }

  /**
   * Retorna o estado atual (imutável)
   */
  getState(): Readonly<AppState> {
    return this.state;
  }

  /**
   * Atualiza o estado de forma imutável
   */
  update(updater: (state: AppState) => Partial<AppState>): void {
    const updates = updater(this.state);
    this.state = { ...this.state, ...updates };
    this.notify();
  }

  /**
   * Adiciona uma mensagem
   */
  addMessage(message: Omit<Message, 'timestamp'>): void {
    this.update(state => ({
      messages: [...state.messages, { ...message, timestamp: Date.now() }],
    }));
  }

  /**
   * Adiciona chunk a última mensagem do assistant
   */
  addChunk(chunk: string): void {
    this.update(state => {
      const messages = [...state.messages];
      const lastMsg = messages[messages.length - 1];
      
      if (lastMsg && lastMsg.role === 'assistant') {
        lastMsg.content += chunk;
        lastMsg.chunks = lastMsg.chunks || [];
        lastMsg.chunks.push(chunk);
      } else {
        messages.push({
          role: 'assistant',
          content: chunk,
          chunks: [chunk],
          timestamp: Date.now(),
        });
      }
      
      return { messages };
    });
  }

  /**
   * Adiciona ou atualiza tool block
   */
  updateToolBlock(id: string, updates: Partial<ToolBlock>): void {
    this.update(state => {
      const toolBlocks = [...state.toolBlocks];
      const index = toolBlocks.findIndex(t => t.id === id);
      
      if (index >= 0) {
        toolBlocks[index] = { ...toolBlocks[index], ...updates };
      } else {
        toolBlocks.push({
          id,
          name: updates.name || 'unknown',
          args: updates.args || {},
          status: updates.status || 'running',
          expanded: updates.expanded || false,
          timestamp: Date.now(),
          ...updates,
        });
      }
      
      return { toolBlocks };
    });
  }

  /**
   * Atualiza token usage
   */
  updateTokens(input: number, output: number): void {
    this.update(state => ({
      tokenUsage: {
        input: state.tokenUsage.input + input,
        output: state.tokenUsage.output + output,
        total: state.tokenUsage.total + input + output,
      },
    }));
  }

  /**
   * Define token usage diretamente (não soma)
   */
  setTokens(usage: { input: number; output: number; total: number }): void {
    this.update(() => ({
      tokenUsage: usage,
    }));
  }

  /**
   * Atualiza latência
   */
  setLatency(ms: number): void {
    this.update(() => ({ latency: ms }));
  }

  /**
   * Atualiza informações do modelo
   */
  setModelInfo(name: string, mode: 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis'): void {
    this.update(() => ({
      modelInfo: { name, mode },
    }));
  }

  /**
   * Atualiza a lista de todos
   */
  setTodos(todos: Array<{ action: string; status: 'pending' | 'in_progress' | 'done' | 'failed' }>): void {
    this.update(() => ({ todos }));
  }

  /**
   * Atualiza o status de um todo específico
   */
  updateTodoStatus(index: number, status: 'pending' | 'in_progress' | 'done' | 'failed'): void {
    this.update(state => {
      const todos = [...state.todos];
      if (todos[index]) {
        todos[index] = { ...todos[index], status };
      }
      return { todos };
    });
  }

  /**
   * Define a mensagem de thinking atual
   */
  setThinkingMessage(message: string): void {
    this.update(() => ({ thinkingMessage: message }));
  }

  setGlobalReasoning(reasoning: string): void {
    this.update(() => ({ globalReasoning: reasoning }));
  }

  /**
   * Atualiza o progresso do step atual
   */
  setStepProgress(current: number, total: number): void {
    this.update(() => ({ currentStep: current, totalSteps: total }));
  }

  /**
   * Registra listener para mudanças de estado
   */
  subscribe(listener: (state: AppState) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /**
   * Notifica todos os listeners
   */
  private notify(): void {
    this.listeners.forEach(listener => {
      try {
        listener(this.state);
      } catch (error) {
        console.error('Error in state listener:', error);
      }
    });
  }

  /**
   * Reseta o estado
   */
  reset(): void {
    this.state = this.getInitialState();
    this.notify();
  }
}

// Singleton global
export const stateStore = new StateStore();
