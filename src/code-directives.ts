/**
 * Code generation directives for modern patterns and clean code.
 *
 * These directives are injected into LLM prompts when generating code
 * to enforce best practices and modern patterns.
 */

export const CODE_GENERATION_DIRECTIVES = {
  general: `
## Code Quality Standards

- Use clean code principles: meaningful names, single responsibility, DRY
- Prefer composition over inheritance
- Keep functions small and focused (max 20 lines)
- Use early returns to reduce nesting
- Avoid magic numbers and strings (use constants)
- Write self-documenting code (minimize comments)
`,

  typescript: `
## TypeScript/JavaScript Modern Patterns

- Use TypeScript strict mode types
- Prefer const over let, never use var
- Use arrow functions for callbacks
- Destructure objects and arrays
- Use optional chaining (?.) and nullish coalescing (??)
- Prefer async/await over .then() chains
- Use template literals over string concatenation
- Prefer functional patterns (map, filter, reduce) over loops
- Use ES modules (import/export) not CommonJS
`,

  react: `
## React Modern Patterns

- Use functional components with hooks (no class components)
- Use custom hooks for reusable logic
- Keep components small and focused
- Lift state up when needed
- Use React.memo() for expensive renders
- Prefer controlled components
- Use proper key props in lists
- Handle loading and error states
`,

  architecture: `
## Architecture Patterns

- Separate concerns: UI, business logic, data access
- Use dependency injection for testability
- Prefer interfaces over concrete types
- Use factory pattern for complex object creation
- Apply SOLID principles
- Keep modules loosely coupled
- Use repository pattern for data access
`,

  security: `
## Security Best Practices

- Validate all user input
- Sanitize data before rendering (prevent XSS)
- Use parameterized queries (prevent SQL injection)
- Never store secrets in code
- Use environment variables for config
- Implement proper error handling (don't leak stack traces)
- Use HTTPS for all external requests
`,

  performance: `
## Performance Considerations

- Avoid premature optimization
- Use lazy loading for large modules
- Implement pagination for large datasets
- Cache expensive computations
- Debounce/throttle frequent events
- Use web workers for heavy computation
- Minimize bundle size
`,

  testing: `
## Testing Guidelines

- Write testable code (pure functions, dependency injection)
- Test behavior, not implementation
- Use descriptive test names
- Follow AAA pattern (Arrange, Act, Assert)
- Mock external dependencies
- Aim for high coverage on critical paths
`
};

/**
 * Get directives for a specific language/framework.
 */
export function getDirectivesForLanguage(language: string): string {
  const lang = language.toLowerCase();

  let directives = CODE_GENERATION_DIRECTIVES.general;

  if (['javascript', 'typescript', 'js', 'ts', 'jsx', 'tsx'].includes(lang)) {
    directives += CODE_GENERATION_DIRECTIVES.typescript;
  }

  if (['jsx', 'tsx', 'react'].includes(lang)) {
    directives += CODE_GENERATION_DIRECTIVES.react;
  }

  directives += CODE_GENERATION_DIRECTIVES.architecture;
  directives += CODE_GENERATION_DIRECTIVES.security;

  return directives;
}

/**
 * Get compact directives for 7B models (shorter version).
 */
export function getCompactDirectives(language: string): string {
  const lang = language.toLowerCase();

  let compact = `Code quality rules:
- Clean code: meaningful names, small functions, DRY
- Modern patterns: const/let, arrow functions, async/await, destructuring
- Security: validate input, sanitize output, no secrets in code`;

  if (['jsx', 'tsx', 'react'].includes(lang)) {
    compact += `
- React: functional components + hooks, small focused components`;
  }

  if (['python', 'py'].includes(lang)) {
    compact += `
- Python: type hints, list comprehensions, context managers, PEP 8`;
  }

  return compact;
}

/**
 * Inject directives into a code generation prompt.
 */
export function injectDirectives(
  basePrompt: string,
  language: string,
  isSmallModel: boolean
): string {
  const directives = isSmallModel
    ? getCompactDirectives(language)
    : getDirectivesForLanguage(language);

  // Insert directives before the final "Return ONLY JSON" instruction
  const parts = basePrompt.split('Return ONLY JSON');
  if (parts.length === 2) {
    return `${parts[0]}

${directives}

Return ONLY JSON${parts[1]}`;
  }

  // Fallback: append at the end
  return `${basePrompt}

${directives}`;
}
