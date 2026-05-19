/**
 * Tool Block Renderer - Renderiza blocos de ferramentas com estados
 */

import chalk from 'chalk';
import { ToolBlock } from './state-store.js';

export class ToolBlockRenderer {
  /**
   * Renderiza um tool block baseado no estado
   */
  render(tool: ToolBlock): string {
    const lines: string[] = [];
    
    // Header do tool
    const icon = tool.expanded ? '▼' : '▶';
    const status = this.getStatusIcon(tool.status);
    const argsStr = this.formatArgs(tool.args);
    
    lines.push(
      chalk.bold(`${icon} ${tool.name}${argsStr}`) + ' ' + status
    );

    // Se expandido, mostrar resultado
    if (tool.expanded) {
      if (tool.status === 'success' && tool.result) {
        lines.push(chalk.gray('─'.repeat(60)));
        lines.push(this.formatResult(tool.name, tool.result));
        lines.push(chalk.gray('─'.repeat(60)));
      } else if (tool.status === 'error' && tool.error) {
        lines.push(chalk.red(`  ✖ ${tool.error}`));
      }
    }

    return lines.join('\n');
  }

  /**
   * Retorna ícone de status
   */
  private getStatusIcon(status: ToolBlock['status']): string {
    switch (status) {
      case 'running':
        return chalk.yellow('...');
      case 'success':
        return chalk.green('✓');
      case 'error':
        return chalk.red('✖');
    }
  }

  /**
   * Formata argumentos do tool
   */
  private formatArgs(args: Record<string, any>): string {
    const keys = Object.keys(args);
    if (keys.length === 0) return '()';
    
    const preview = keys.slice(0, 2).map(k => {
      const val = args[k];
      if (typeof val === 'string' && val.length > 20) {
        return `${k}="${val.slice(0, 20)}..."`;
      }
      return `${k}=${JSON.stringify(val)}`;
    }).join(', ');
    
    return `(${preview}${keys.length > 2 ? ', ...' : ''})`;
  }

  /**
   * Formata resultado baseado no tipo de tool
   */
  private formatResult(toolName: string, result: any): string {
    // RAG results
    if (toolName === 'semantic_search' || toolName === 'search_code') {
      return this.formatRAGResult(result);
    }

    // Exec results
    if (toolName === 'run_code' || toolName === 'run_command') {
      return this.formatExecResult(result);
    }

    // Git results
    if (toolName.startsWith('git_')) {
      return this.formatGitResult(result);
    }

    // Default: JSON
    return chalk.gray(JSON.stringify(result, null, 2));
  }

  /**
   * Formata resultado de RAG
   */
  private formatRAGResult(result: any): string {
    if (Array.isArray(result)) {
      return result.slice(0, 5).map((item, i) => {
        const file = item.file || item.filePath || 'unknown';
        const line = item.line || item.start_line || '?';
        return chalk.cyan(`  ${i + 1}. ${file}:${line}`);
      }).join('\n');
    }
    return chalk.gray(String(result));
  }

  /**
   * Formata resultado de execução
   */
  private formatExecResult(result: any): string {
    const lines: string[] = [];
    
    if (result.success) {
      lines.push(chalk.green('  ✔ Sucesso'));
    } else {
      lines.push(chalk.red('  ✖ Erro'));
    }
    
    if (result.output) {
      const output = String(result.output).trim();
      const preview = output.split('\n').slice(0, 10).join('\n');
      lines.push(chalk.gray(preview));
      if (output.split('\n').length > 10) {
        lines.push(chalk.gray('  ... (truncado)'));
      }
    }
    
    return lines.join('\n');
  }

  /**
   * Formata resultado de git
   */
  private formatGitResult(result: any): string {
    if (typeof result === 'string') {
      return chalk.gray(result.split('\n').slice(0, 20).join('\n'));
    }
    return chalk.gray(JSON.stringify(result, null, 2));
  }
}

export const toolBlockRenderer = new ToolBlockRenderer();
