export interface ToolExecutionResult {
  success: boolean;
  output: string;
  error: string | null;
}

const TOOL_ALIASES: Record<string, string> = {
  read: 'read_file',
  readfile: 'read_file',
  create: 'create_file',
  createfile: 'create_file',
  write: 'write_file',
  writefile: 'write_file',
  patch: 'apply_patch',
  edit: 'apply_patch',
  ls: 'list_dir',
  list: 'list_dir',
  search: 'search_code',
  grep: 'search_code',
  shell: 'run_code',
  run: 'run_code',
  exec: 'run_code',
  runcommand: 'run_code',
  gitstatus: 'git_status',
  gitdiff: 'git_diff',
  gitlog: 'git_log',
  web: 'web_search'
};

export function normalizeToolNameWithAliases(
  toolName: string,
  hasTool: (name: string) => boolean
): string {
  const normalized = String(toolName || '').trim();
  if (hasTool(normalized)) return normalized;

  const compact = normalized.toLowerCase().replace(/[^a-z]/g, '');
  const alias = TOOL_ALIASES[compact];
  return (alias && hasTool(alias)) ? alias : normalized;
}

export function formatToolResultForModelPolicy(
  toolName: string,
  result: ToolExecutionResult
): string {
  const maxChars = 40_000;
  const raw = String(result.output || '');
  const output = raw.length > maxChars
    ? raw.slice(0, maxChars) + `\n...[truncated: ${raw.length - maxChars} chars omitted]`
    : raw;

  if (result.success) {
    return output || `${toolName}: success`;
  }
  // Failure: keep the error tag AND surface the captured output (stdout +
  // stderr for run_code, etc). Without this the model only sees "Exit code 1"
  // and has no evidence to diagnose, so it retries the same command or gives
  // up with [done].
  const head = `Error (${toolName}): ${result.error || 'failed'}`;
  return output ? `${head}\n--- output ---\n${output}` : head;
}
