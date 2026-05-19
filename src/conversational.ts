import chalk from 'chalk';
import { OllamaClient, OfflineError, OllamaNotFoundError, OllamaResourceError } from './ollama-client.js';
import { MarkdownRenderer } from './markdown-renderer.js';
import { DiffRenderer } from './diff-renderer.js';

export class ConversationalLayer {
  private markdownRenderer: MarkdownRenderer;
  private diffRenderer: DiffRenderer;

  constructor(
    private llm: OllamaClient
  ) {
    this.markdownRenderer = new MarkdownRenderer();
    this.diffRenderer = new DiffRenderer('github');
  }

  async greet(): Promise<string> {
    return chalk.cyan('👋 Olá! Sou seu assistente de código. Como posso ajudar?');
  }

  async beforeStep(stepAction: string): Promise<string> {
    // Mensagem consistente e clara
    return chalk.yellow(`\n→ Trabalhando em: ${stepAction.toLowerCase()}`);
  }

  async duringStep(_stepAction: string, progress: string): Promise<string> {
    // Progresso inline, não repetir o step
    return chalk.gray(`  ${progress}`);
  }

  async afterStep(stepAction: string, success: boolean, result?: string): Promise<string> {
    if (success) {
      return chalk.green(`✓ ${stepAction} - concluído`);
    } else {
      return chalk.red(`✗ ${stepAction} - erro: ${result}`);
    }
  }

  async askConfirmation(question: string): Promise<string> {
    return chalk.yellow(`❓ ${question} (sim/não)`);
  }

  async showProgress(current: number, total: number): Promise<string> {
    const percentage = Math.round((current / total) * 100);
    const bar = '█'.repeat(Math.floor(percentage / 5)) + '░'.repeat(20 - Math.floor(percentage / 5));
    return chalk.blue(`[${bar}] ${percentage}% (${current}/${total})`);
  }

  async summarize(goal: string, results: string[]): Promise<string> {
    const prompt = `Summarize what was done concisely.

Goal: ${goal}

Results:
${results.join('\n')}

Rules:
- 2-3 short sentences
- Focus on what was achieved
- Use the same language as the user's goal when possible`;

    try {
      const summary = await this.llm.generate(prompt);
      return chalk.green('\n✓ Concluído!\n') + chalk.white(summary.trim());
    } catch (error) {
      if (error instanceof OfflineError || error instanceof OllamaNotFoundError || error instanceof OllamaResourceError) {
        throw error;
      }
      return chalk.green('\n✓ Tarefa concluída!');
    }
  }

  async explainThinking(thought: string): Promise<string> {
    return chalk.gray(`💭 ${thought}`);
  }

  async showError(error: string): Promise<string> {
    return chalk.red(`❌ Erro: ${error}`);
  }

  async progressiveDisclosure(context: string, step: number, total: number): Promise<string> {
    // Libera contexto em etapas
    const lines = context.split('\n');
    const chunkSize = Math.ceil(lines.length / total);
    const start = step * chunkSize;
    const end = Math.min(start + chunkSize, lines.length);
    
    return lines.slice(start, end).join('\n');
  }

  async reaffirmContext(goal: string, currentStep: string): Promise<string> {
    return chalk.cyan(`\n📍 Contexto: Trabalhando em "${goal}"\n   Passo atual: ${currentStep}\n`);
  }

  formatCode(code: string, language: string = ''): string {
    return this.markdownRenderer.renderCode(code, language);
  }

  formatDiff(diff: string): string {
    // Se for um diff git completo, usar DiffRenderer
    if (diff.includes('diff --git') || diff.includes('@@')) {
      return diff; // Já formatado
    }
    
    // Caso contrário, usar formatação simples
    return diff
      .split('\n')
      .map(line => {
        if (line.startsWith('+')) return chalk.green(line);
        if (line.startsWith('-')) return chalk.red(line);
        return chalk.gray(line);
      })
      .join('\n');
  }

  renderMarkdown(markdown: string): string {
    return this.markdownRenderer.render(markdown);
  }

  renderDiff(oldText: string, newText: string, options?: any): string {
    return this.diffRenderer.renderDiff(oldText, newText, options);
  }

  renderFileDiff(oldPath: string, newPath: string, oldContent: string, newContent: string): string {
    return this.diffRenderer.renderFileDiff(oldPath, newPath, oldContent, newContent);
  }

  renderSplitDiff(oldText: string, newText: string): string {
    return this.diffRenderer.renderSplitDiff(oldText, newText);
  }
}
