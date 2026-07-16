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
  tokenCount?: (text: string) => Promise<number | null>;
  /**
   * Optional session id — was used by a context-store integration that is
   * currently not wired (deferred from the minimal-recovery scope). Accepted
   * here so callers/tests can still pass it without a type error; ignored by
   * the implementation until the context-store path is restored.
   */
  sessionId?: string;
  /** Same rationale as sessionId — accepted but unused in this minimal build. */
  contextStore?: unknown;
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
    summarizeConversation,
    tokenCount
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

  return compactMessagesIfNeeded(messages, currentQuery, maxContextTokens, summarizeConversation, tokenCount);
}

async function compactMessagesIfNeeded(
  messages: InferenceMessage[],
  currentQuery: string,
  maxContextTokens: number,
  summarizeConversation: (messages: InferenceMessage[]) => Promise<string>,
  tokenCount?: (text: string) => Promise<number | null>
): Promise<InferenceMessage[]> {
  // BUG-A1: aligned with run-tool-loop.ts compaction threshold (0.9) — was 0.85.
  const threshold = Math.floor(maxContextTokens * 0.9);
  let compacted = messages.map(msg => ({ ...msg }));

  if (estimateMessagesTokens(compacted) <= threshold) return compacted;

  const currentUserIndex = findCurrentUserMessageIndex(compacted, currentQuery);
  const historyMessages = compacted.slice(1, currentUserIndex);
  const recentMessages = compacted.slice(currentUserIndex);

  if (historyMessages.length < 3) return compacted;

  try {
    const summary = await summarizeConversation(historyMessages);
    if (summary) {
      // FIX-01: Inject summary as a separate message instead of modifying
      // the system prompt. This keeps the system message byte-identical across
      // turns, enabling llama.cpp's prompt-cache to reuse the KV cache.
      compacted = [
        { ...compacted[0] },  // Keep original system message unchanged
        { role: 'system', content: `## Conversation History (summarized)\n${summary}` },
        ...recentMessages
      ];
    }
  } catch {
    // Keep original on failure.
  }

  if (estimateMessagesTokens(compacted) <= threshold) return compacted;

  // BUG-A4: On hard-trim, ALWAYS preserve currentQuery as the last user
  // message. Without this, the current turn was droppable when recentMessages
  // was empty (BUG-A3 path) or when the trim window omitted it.
  const trimmed: InferenceMessage[] = [compacted[0], ...recentMessages.slice(-4)];
  let lastUserMsg: InferenceMessage | null = null;
  for (let i = trimmed.length - 1; i >= 0; i--) {
    if (trimmed[i].role === 'user') { lastUserMsg = trimmed[i]; break; }
  }
  const lastUserIsCurrent =
    lastUserMsg !== null &&
    typeof lastUserMsg.content === 'string' &&
    lastUserMsg.content === currentQuery;
  if (!lastUserIsCurrent) {
    trimmed.push({ role: 'user', content: currentQuery });
  }
  return trimmed;
}

function findCurrentUserMessageIndex(messages: InferenceMessage[], currentQuery: string): number {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (
      messages[i].role === 'user' &&
      typeof messages[i].content === 'string' &&
      messages[i].content === currentQuery
    ) return i;
  }
  // BUG-A3: When currentQuery doesn't match any message (e.g., the user-turn
  // content was replaced by multimodal `currentUserContent` parts at line 69),
  // the previous fallback of `messages.length` caused
  // `slice(currentUserIndex) === []` → recentMessages was empty → ALL history
  // (including the live turn) got summarized away. Fall back to the LAST
  // user message instead so the current turn is preserved.
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'user') return i;
  }
  return messages.length;
}

// FIX-03: Detect content type for accurate token estimation
function getCharsPerToken(text: string): number {
  // CJK (Chinese/Japanese/Korean) characters - typically 1-2 chars per token
  if (/[\u4e00-\u9fff\u3040-\u30ff]/.test(text)) {
    return 1.5;
  }
  // Code-like content - typically 3-4 chars per token
  if (text.includes('```') || /(?:function|const|let|import|def|class|var|return|if|for)\s+/.test(text)) {
    return 3.5;
  }
  // English prose - typically 4-5 chars per token
  if (/^[A-Za-z\s.,!?;:'''"()-]+$/.test(text)) {
    return 4.5;
  }
  // Mixed content - conservative estimate
  return 4.0;
}

function estimateMessagesTokens(messages: InferenceMessage[]): number {
  return messages.reduce((total, msg) => {
    let chars = 0;
    let contentText = '';

    if (typeof msg.content === 'string') {
      chars += msg.content.length;
      contentText = msg.content;
    } else if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        const text = part.text || '';
        chars += text.length;
        contentText += text;
        chars += (part.image_url?.url || '').length;
      }
    }
    if (msg.tool_calls?.length) {
      chars += JSON.stringify(msg.tool_calls).length;
    }

    // FIX-03: Use content-type-aware estimation
    const ratio = getCharsPerToken(contentText);
    return total + Math.ceil(chars / ratio) + 6;
  }, 0);
}
