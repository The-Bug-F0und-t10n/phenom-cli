import type { Message } from '../types.js';
import type { ApiContentPart } from '../api-client.js';
import type { InferenceMessage } from './run-tool-loop.js';

interface BuildInferenceMessagesDeps {
  systemPrompt: string;
  recentMessages: Message[];
  currentQuery: string;
  currentUserContent?: ApiContentPart[];
  maxContextTokens: number;
  summarizeConversation(messages: InferenceMessage[]): Promise<string>;
}

export async function buildInferenceMessagesUseCase(
  deps: BuildInferenceMessagesDeps
): Promise<InferenceMessage[]> {
  const {
    systemPrompt,
    recentMessages,
    currentQuery,
    currentUserContent,
    maxContextTokens,
    summarizeConversation
  } = deps;

  const messages: InferenceMessage[] = [
    { role: 'system', content: systemPrompt },
    ...recentMessages.map(msg => {
      const m: InferenceMessage = { role: msg.role, content: msg.content };
      if (msg.tool_calls && msg.tool_calls.length > 0) {
        m.tool_calls = msg.tool_calls.map((tc: any) => ({
          id: tc.id,
          type: tc.type || 'function',
          function: {
            name: tc.function?.name || '',
            arguments: typeof tc.function?.arguments === 'string'
              ? tc.function.arguments
              : JSON.stringify(tc.function?.arguments || {})
          }
        }));
      }
      if (msg.tool_call_id) m.tool_call_id = msg.tool_call_id;
      return m;
    })
  ];

  const lastUserIndex = (() => {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === 'user') return i;
    }
    return -1;
  })();

  if (Array.isArray(currentUserContent) && currentUserContent.length > 0) {
    if (
      lastUserIndex >= 0 &&
      typeof messages[lastUserIndex].content === 'string' &&
      messages[lastUserIndex].content === currentQuery
    ) {
      messages[lastUserIndex] = { ...messages[lastUserIndex], content: currentUserContent };
    } else {
      messages.push({ role: 'user', content: currentUserContent });
    }
  } else {
    const lastUserMsg = lastUserIndex >= 0 ? messages[lastUserIndex] : null;
    if (!lastUserMsg || lastUserMsg.content !== currentQuery) {
      messages.push({ role: 'user', content: currentQuery });
    }
  }

  return compactMessagesIfNeeded(messages, currentQuery, maxContextTokens, summarizeConversation);
}

async function compactMessagesIfNeeded(
  messages: InferenceMessage[],
  currentQuery: string,
  maxContextTokens: number,
  summarizeConversation: (messages: InferenceMessage[]) => Promise<string>
): Promise<InferenceMessage[]> {
  const threshold = Math.floor(maxContextTokens * 0.85);
  let compacted = messages.map(msg => ({ ...msg }));

  if (estimateMessagesTokens(compacted) <= threshold) return compacted;

  const currentUserIndex = findCurrentUserMessageIndex(compacted, currentQuery);
  const historyMessages = compacted.slice(1, currentUserIndex);
  const recentMessages = compacted.slice(currentUserIndex);

  if (historyMessages.length < 3) return compacted;

  try {
    const summary = await summarizeConversation(historyMessages);
    if (summary) {
      compacted = [
        {
          role: compacted[0].role,
          content: compacted[0].content + `\n\n## Conversation History (summarized)\n${summary}`
        },
        ...recentMessages
      ];
    }
  } catch {
    // Keep original on failure.
  }

  if (estimateMessagesTokens(compacted) <= threshold) return compacted;
  return [compacted[0], ...recentMessages.slice(-4)];
}

function findCurrentUserMessageIndex(messages: InferenceMessage[], currentQuery: string): number {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (
      messages[i].role === 'user' &&
      typeof messages[i].content === 'string' &&
      messages[i].content === currentQuery
    ) return i;
  }
  return messages.length;
}

function estimateMessagesTokens(messages: InferenceMessage[]): number {
  return messages.reduce((total, msg) => {
    let chars = 0;
    if (typeof msg.content === 'string') {
      chars += msg.content.length;
    } else if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        chars += (part.text || '').length;
        chars += (part.image_url?.url || '').length;
      }
    }
    if (msg.tool_calls?.length) {
      chars += JSON.stringify(msg.tool_calls).length;
    }
    return total + Math.ceil(chars / 4) + 24;
  }, 0);
}
