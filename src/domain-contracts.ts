export type ToolLoopResponse =
  | { type: 'final'; content: string }
  | { type: 'tool'; toolName: string; args: Record<string, unknown> };

export type ToolCallParseStrategy =
  | 'tagged_tool_call'
  | 'primary_json'
  | 'embedded_json_scan'
  | 'cleaned_retry'
  | 'plain_text_final'
  | 'invalid_broken_tool_json'
  | 'empty';

export interface ToolLoopParseResult {
  response: ToolLoopResponse | null;
  strategy: ToolCallParseStrategy;
}
