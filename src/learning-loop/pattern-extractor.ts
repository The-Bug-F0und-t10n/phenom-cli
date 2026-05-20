import { Message } from '../types.js';

export interface ExtractedPattern {
  name: string;
  domain: string;
  description: string;
  toolSequence: string[];
  triggerKeywords: string[];
}

export interface TaskSnapshot {
  request: string;
  messages: Message[];
  projectDomain: string;
}

/**
 * Extracts reusable patterns from a completed task.
 *
 * Returns an empty array when:
 * - No tools were called (pure text answer — nothing to learn).
 * - The intent can't be classified (avoids low-quality patterns).
 */
export function extractPatterns(task: TaskSnapshot): ExtractedPattern[] {
  const toolSequence = extractToolSequence(task.messages);
  if (toolSequence.length === 0) return [];

  const domain = detectDomain(task.request, task.projectDomain);
  const intent = detectIntent(task.request);
  if (!intent) return [];

  const keywords = extractKeywords(task.request);

  return [{
    name: `${intent} (${domain})`,
    domain,
    description: `${intent} in ${domain}: ${toolSequence.join(' → ')}`,
    toolSequence,
    triggerKeywords: keywords
  }];
}

// ── Helpers ───────────────────────────────────────────────────────────────

function extractToolSequence(messages: Message[]): string[] {
  const seen = new Set<string>();
  const ordered: string[] = [];
  for (const msg of messages) {
    if (!msg.tool_calls?.length) continue;
    for (const tc of msg.tool_calls) {
      const name = tc.function?.name;
      if (name && !seen.has(name)) {
        seen.add(name);
        ordered.push(name);
      }
    }
  }
  return ordered;
}

export function detectDomain(request: string, projectDomain: string): string {
  const t = request.toLowerCase();
  if (/\.(ts|tsx)\b|typescript/.test(t)) return 'typescript';
  if (/\.(js|jsx)\b|javascript/.test(t)) return 'javascript';
  if (/\.(py)\b|python/.test(t)) return 'python';
  if (/\.(sh)\b|bash|shell/.test(t)) return 'bash';
  if (/\.(rs)\b|rust/.test(t)) return 'rust';
  if (/\.(go)\b|golang/.test(t)) return 'go';
  if (/css|html|frontend|react|vue/.test(t)) return 'frontend';
  if (/sql|database|query|migration|prisma/.test(t)) return 'database';
  if (projectDomain) return projectDomain;
  return 'general';
}

export function detectIntent(request: string): string | null {
  const t = request.toLowerCase();
  if (/\b(debug|fix|bug|error|crash|broken|falha|corrig|resolve)\b/.test(t)) return 'debug';
  if (/\b(refactor|clean|reorganize|reorganizar|simplif)\b/.test(t)) return 'refactor';
  if (/\b(creat|add|implement|new|novo|criar|build|develop|escrever)\b/.test(t)) return 'implement';
  if (/\b(test|spec|jest|vitest|coverage)\b/.test(t)) return 'test';
  if (/\b(explain|understand|how|what|analise|analyze|review|entender)\b/.test(t)) return 'explain';
  if (/\b(read|view|show|list|listar|ler|ver)\b/.test(t)) return 'inspect';
  return null;
}

function extractKeywords(request: string): string[] {
  const stop = new Set([
    'the','a','an','and','or','in','at','for','to','of','is','are','this','that','with','from',
    'o','e','de','do','da','um','uma','em','para','com','que','se','na','no','por','ao','os','as',
    'das','dos','nao','não','mais','mas','seu','sua','meu','minha','por'
  ]);
  return request
    .toLowerCase()
    .replace(/[^\w\s]/g, ' ')
    .split(/\s+/)
    .filter(w => w.length > 3 && !stop.has(w))
    .slice(0, 8);
}
