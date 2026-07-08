#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASKS="$ROOT/TASKS.md"
ALIGN="$ROOT/alinhamento.md"

fail() {
  printf 'alignment-check: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

require_text() {
  file=$1
  text=$2
  grep -Fq -- "$text" "$file" || fail "missing text in $(basename "$file"): $text"
}

task_block() {
  task=$1
  awk -v task="## $task " '
    index($0, task) == 1 { in_block = 1 }
    in_block && /^## T[0-9]+ / && index($0, task) != 1 { exit }
    in_block { print }
  ' "$TASKS"
}

require_task_field() {
  task=$1
  field=$2
  block=$(task_block "$task")
  [ -n "$block" ] || fail "missing task: $task"
  printf '%s\n' "$block" | grep -Fq -- "$field" || fail "$task missing field: $field"
}

require_task_status() {
  task=$1
  block=$(task_block "$task")
  [ -n "$block" ] || fail "missing task: $task"
  printf '%s\n' "$block" | grep -Eq '^Status: (pending-urgent|in-progress|partial|done|completed)\.$' ||
    fail "$task has invalid urgent status"
  printf '%s\n' "$block" | grep -Fq 'Prioridade: urgente.' ||
    fail "$task missing urgent priority"
}

require_file "$TASKS"
require_file "$ALIGN"

for section in \
  "A0 - Contrato central model-driven" \
  "A1 - Tool surface e ferramentas reais" \
  "A2 - Tool loop" \
  "A3 - Contexto, evidencia e micro-contexto" \
  "A4 - Ranking e busca" \
  "A5 - Historico, sessao, memoria e SKILLS" \
  "A6 - System prompt e output para modelo" \
  "A7 - Renderer/TUI" \
  "A8 - HTTP/backend/model protocol" \
  "A9 - News e context profiles" \
  "A10 - Patch/mutation/validacao" \
  "A11 - Testes reais e criterio de confiabilidade" \
  "Mapa de alinhamento por eixo" \
  "Problemas novos introduzidos pelo Zig" \
  "Acertos do Zig que devem ser preservados" \
  "Criterio para dizer \"alinhado\""
do
  require_text "$ALIGN" "## $section"
done

for mapping in \
  "A0 Contrato central model-driven: \`T282\`, \`T291\`." \
  "A1 Tool surface e ferramentas reais: \`T297\`." \
  "A2 Tool loop: \`T293\`." \
  "A3 Contexto, evidencia e micro-contexto: \`T283\`, \`T284\`, \`T285\`." \
  "A4 Ranking e busca: \`T298\`." \
  "A5 Historico, sessao, memoria e SKILLS: \`T294\`, \`T295\`." \
  "A6 System prompt e output para modelo: \`T296\`." \
  "A7 Renderer/TUI: \`T292\`." \
  "A8 HTTP/backend/model protocol: \`T299\`." \
  "A9 News e context profiles: \`T288\`, \`T289\`." \
  "A10 Patch/mutation/validacao: \`T285\`, \`T286\`." \
  "A11 Testes reais e criterio de confiabilidade: \`T290\`, \`T300\`." \
  "Problemas novos introduzidos pelo Zig: \`T291\`, \`T293\`, \`T296\`, \`T298\`, \`T300\`." \
  "Acertos do Zig que devem ser preservados: \`T301\`." \
  "Criterio para dizer \"alinhado\": \`T300\`."
do
  require_text "$TASKS" "$mapping"
done

for task_num in $(seq 281 301); do
  task="T$task_num"
  require_task_status "$task"
  require_task_field "$task" "Alinhamento AUDIT/TASKS/phenom-cli-ts:"
  require_task_field "$task" "Referencia TS consultada:"
  require_task_field "$task" "Falha apontada no AUDIT/TASKS:"
  require_task_field "$task" "O que sera preservado do TS:"
  require_task_field "$task" "O que sera corrigido no Zig:"
  require_task_field "$task" "O que nao sera portado agora e por que:"
  require_task_field "$task" "Invariantes afetadas:"
  require_task_field "$task" "Teste unitario obrigatorio:"
  require_task_field "$task" "Smoke real obrigatorio, se envolver modelo/servidor/tool loop:"
  require_task_field "$task" "Revisao baixo nivel Zig antes do commit:"
done

printf 'alignment-check: ok\n'
