/**
 * Anti-hallucination utilities for 7B models.
 *
 * Small models (7B/8B) have high hallucination rates in:
 * 1. Multi-step JSON generation chains
 * 2. Code content embedded in JSON strings
 * 3. Long prompts with multiple instructions
 * 4. Retry loops without validation
 *
 * This module provides validation and circuit-breaker patterns.
 */

export interface ValidationResult {
  valid: boolean;
  reason?: string;
}

/**
 * Validate that JSON response contains expected fields with correct types.
 */
export function validateJsonSchema(
  parsed: any,
  schema: Record<string, 'string' | 'array' | 'object' | 'boolean'>
): ValidationResult {
  if (!parsed || typeof parsed !== 'object') {
    return { valid: false, reason: 'Response is not an object' };
  }

  for (const [key, expectedType] of Object.entries(schema)) {
    const value = parsed[key];

    if (expectedType === 'string' && typeof value !== 'string') {
      return { valid: false, reason: `Field "${key}" must be string, got ${typeof value}` };
    }

    if (expectedType === 'array' && !Array.isArray(value)) {
      return { valid: false, reason: `Field "${key}" must be array, got ${typeof value}` };
    }

    if (expectedType === 'object' && (typeof value !== 'object' || Array.isArray(value))) {
      return { valid: false, reason: `Field "${key}" must be object, got ${typeof value}` };
    }

    if (expectedType === 'boolean' && typeof value !== 'boolean') {
      return { valid: false, reason: `Field "${key}" must be boolean, got ${typeof value}` };
    }
  }

  return { valid: true };
}

/**
 * Validate that string content is not placeholder/template text.
 * 7B models often return template strings instead of actual content.
 */
export function isPlaceholderContent(content: string): boolean {
  const lower = content.toLowerCase().trim();

  const placeholders = [
    'todo',
    'implement',
    'add your code here',
    'your code here',
    'placeholder',
    'example',
    '...',
    'etc',
    'and so on',
    '[insert',
    '[add',
    'fill in',
    'complete this'
  ];

  // Check if content is mostly placeholder text
  const words = lower.split(/\s+/);
  if (words.length < 5) {
    return placeholders.some(p => lower.includes(p));
  }

  // For longer content, check if >30% is placeholder
  const placeholderCount = words.filter(w =>
    placeholders.some(p => w.includes(p))
  ).length;

  return placeholderCount / words.length > 0.3;
}

/**
 * Validate that code content has minimum structural complexity.
 * Prevents accepting trivial/incomplete code from 7B models.
 */
export function hasMinimumCodeComplexity(content: string, language: string): boolean {
  const lines = content.split('\n').filter(l => l.trim().length > 0);

  // Minimum line count
  if (lines.length < 3) return false;

  // Language-specific structural checks
  if (language === 'javascript' || language === 'typescript') {
    // Must have at least one function/class/const/let/var
    const hasDeclaration = /\b(function|class|const|let|var|export|import)\b/.test(content);
    if (!hasDeclaration) return false;
  }

  if (language === 'python') {
    // Must have at least one def/class/import
    const hasDeclaration = /\b(def|class|import|from)\b/.test(content);
    if (!hasDeclaration) return false;
  }

  if (language === 'html') {
    // Must have opening and closing tags
    const hasStructure = /<[a-z]+[^>]*>[\s\S]*<\/[a-z]+>/i.test(content);
    if (!hasStructure) return false;
  }

  return true;
}

/**
 * Circuit breaker for retry loops.
 * Prevents infinite retry on systematic model failures.
 */
export class RetryCircuitBreaker {
  private failures: number = 0;
  private readonly maxFailures: number;
  private readonly resetAfterMs: number;
  private lastFailureTime: number = 0;

  constructor(maxFailures: number = 3, resetAfterMs: number = 60000) {
    this.maxFailures = maxFailures;
    this.resetAfterMs = resetAfterMs;
  }

  recordFailure(): void {
    const now = Date.now();

    // Reset if enough time has passed
    if (now - this.lastFailureTime > this.resetAfterMs) {
      this.failures = 0;
    }

    this.failures++;
    this.lastFailureTime = now;
  }

  recordSuccess(): void {
    this.failures = 0;
  }

  isOpen(): boolean {
    return this.failures >= this.maxFailures;
  }

  getFailureCount(): number {
    return this.failures;
  }
}

/**
 * Truncate prompt to safe length for 7B models.
 * Long prompts cause attention dilution and hallucination.
 */
export function truncatePromptFor7B(prompt: string, maxChars: number = 2000): string {
  if (prompt.length <= maxChars) return prompt;

  // Try to truncate at sentence boundary
  const truncated = prompt.slice(0, maxChars);
  const lastPeriod = truncated.lastIndexOf('.');
  const lastNewline = truncated.lastIndexOf('\n');
  const cutPoint = Math.max(lastPeriod, lastNewline);

  if (cutPoint > maxChars * 0.8) {
    return truncated.slice(0, cutPoint + 1);
  }

  return truncated + '...';
}
