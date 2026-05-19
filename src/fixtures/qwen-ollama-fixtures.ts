export const QWEN35_NATIVE_TOOLCALL_RESPONSE = {
  model: 'qwen3.5-coder:14b',
  created_at: '2026-05-19T00:00:00Z',
  message: {
    role: 'assistant',
    content: '',
    tool_calls: [
      {
        id: 'call_write_1',
        type: 'function',
        function: {
          name: 'write_file',
          arguments: {
            path: 'hello-world.html',
            content: '<html><body>Hello</body></html>'
          }
        }
      }
    ]
  },
  done: true,
  prompt_eval_count: 211,
  eval_count: 28
} as const;

export const QWEN35_OPENAI_COMPAT_TOOLCALL_RESPONSE = {
  choices: [
    {
      index: 0,
      message: {
        role: 'assistant',
        content: '',
        tool_calls: [
          {
            id: 'call_patch_1',
            type: 'function',
            function: {
              name: 'apply_patch',
              arguments: '{"path":"hello-world.html","operations":[{"search":"body","replace":"main"}]}'
            }
          }
        ]
      },
      finish_reason: 'tool_calls'
    }
  ],
  usage: {
    prompt_tokens: 173,
    completion_tokens: 18,
    total_tokens: 191
  }
} as const;

export const QWEN35_REASONING_TEXT_RESPONSE =
  'Vou atualizar o arquivo agora.\n' +
  '{"type":"tool","toolName":"write_file","args":{"path":"hello-world.html","content":"<html>updated</html>"}}';

export const QWEN35_VISION_MODEL_NAME = 'qwen3.5-vision:latest';
export const QWEN35_REASONING_MODEL_NAME = 'qwen3.5-thinking:32b';
