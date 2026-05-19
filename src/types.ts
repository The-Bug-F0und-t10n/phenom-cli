export interface AgentState {
  goal: string;
  workingFiles: string[];
  files: Record<string, {
    exists: boolean;
    lastAction: string;
    validated: boolean;
    updatedAt: number;
    lastError?: string;
  }>;
  memory: Message[];
  repoContext: Map<string, string>;
  toolHistory: ToolCall[];
  errors: string[];
  userPreferences: Record<string, unknown>;
  mode: 'fast' | 'reasoning' | 'assistant' | 'plan' | 'code_assistant' | 'jarvis';
}

export interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp: number;
  tool_call_id?: string;
  name?: string;
  tool_calls?: Array<{
    id?: string;
    type?: 'function';
    function: {
      name: string;
      arguments: Record<string, unknown> | string;
    };
  }>;
}

export interface ToolCall {
  tool: string;
  args: Record<string, unknown>;
  result: ToolResult;
  timestamp: number;
}

export interface ToolResult {
  success: boolean;
  output: string;
  error: string | null;
}

export interface ReflectionResult {
  done: boolean;
  nextAction: string | null;
  issues: string[];
}

export interface SearchHit {
  file: string;
  line: number;
  snippet: string;
  score: number;
}
