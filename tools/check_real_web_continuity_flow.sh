#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
BACKEND=${2:-${PHENOM_REAL_WEB_BACKEND:-llamacpp}}
HOST=${3:-${PHENOM_REAL_WEB_HOST:-127.0.0.1:8080}}
MODEL=${4:-${PHENOM_REAL_WEB_MODEL:-local}}
WORK=${PHENOM_REAL_WEB_WORK_DIR:-/tmp/phenom-real-web-continuity}
SESSION=${PHENOM_REAL_WEB_SESSION:-real-web-continuity-flow}
SEARCH_URL=${PHENOM_REAL_WEB_SEARCH_URL:-"http://wttr.in/{query}?format=3"}
DB="$WORK/.phenom-zig/phenom.db"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'real-web-continuity-flow: sqlite3 CLI is required\n' >&2
  exit 1
}

case "$SESSION" in
  *"'"*) printf 'real-web-continuity-flow: session must not contain single quotes\n' >&2; exit 1 ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"

run_turn() {
  prompt=$1
  out=$2
  (
    cd "$WORK"
    PHENOM_WEB_SEARCH_URL="$SEARCH_URL" "$BIN" chat \
      --backend "$BACKEND" \
      --host "$HOST" \
      --model "$MODEL" \
      --session "$SESSION" \
      --prompt "$prompt" \
      --max-tokens "${PHENOM_REAL_WEB_MAX_TOKENS:-768}" \
      --thinking "${PHENOM_REAL_WEB_THINKING:-on}" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/$out.out" 2>"$WORK/$out.err"
}

run_turn \
  "Atualiza o clima agora para a cidade alvo Sao_Paulo e cite a evidencia usada." \
  turn1

run_turn \
  "Agora declarativamente use ragweb para conferir o clima atual da cidade alvo Brasilia. Use query=Brasilia se acionar web. Conecte com a resposta anterior." \
  turn2

run_turn \
  "Sem pesquisar de novo, resuma em ordem as duas consultas reais que voce fez e mantenha continuidade da sessao." \
  turn3

cat "$WORK"/turn*.out >"$WORK/all.out"
cat "$WORK"/turn*.err >"$WORK/all.err"

! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/all.out" || { printf 'real-web-continuity-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_start'")" -eq 3 || { printf 'real-web-continuity-flow: expected three user turns\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -eq 3 || { printf 'real-web-continuity-flow: not all turns confirmed\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=set_operational_contract%' and body like '%state=accepted%'")" -ge 2 || { printf 'real-web-continuity-flow: model did not declare web contracts\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=search_web%'")" -ge 2 || { printf 'real-web-continuity-flow: search_web contract was not selected twice\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_executor' and body like '%executor=web_search%'")" -ge 2 || { printf 'real-web-continuity-flow: search_web contract did not execute web_search\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%' and body like '%wttr.in%' and (body like '%Sao_Paulo%' or body like '%S%C3%A3o%20Paulo%' or body like '%Sao%20Paulo%')")" -ge 1 || { printf 'real-web-continuity-flow: missing real Sao_Paulo internet request\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%' and body like '%wttr.in%' and (body like '%Brasilia%' or body like '%Brasília%' or body like '%Bras%C3%ADlia%')")" -ge 1 || { printf 'real-web-continuity-flow: missing real Brasilia internet request\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 2 || { printf 'real-web-continuity-flow: missing successful real web distillations\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%[WEB_EVIDENCE]%' and (body like '%Sao_Paulo%' or body like '%São Paulo%' or body like '%S%C3%A3o%20Paulo%' or body like '%Sao%20Paulo%')")" -ge 1 || { printf 'real-web-continuity-flow: missing Sao_Paulo WEB_EVIDENCE\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%[WEB_EVIDENCE]%' and (body like '%Brasilia%' or body like '%Brasília%' or body like '%Bras%C3%ADlia%')")" -ge 1 || { printf 'real-web-continuity-flow: missing Brasilia WEB_EVIDENCE\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic%'")" -eq 0 || { printf 'real-web-continuity-flow: synthetic repair was used\n' >&2; exit 1; }

test "$(sql_count "kind = 'model_context' and body like '%[RECENT_DIALOGUE]%'")" -ge 1 || { printf 'real-web-continuity-flow: RECENT_DIALOGUE was not sent to the model\n' >&2; exit 1; }
test "$(sql_count "kind = 'model_context' and body like '%Sao_Paulo%'")" -ge 1 || { printf 'real-web-continuity-flow: first turn not present in later context\n' >&2; exit 1; }
test "$(sql_count "kind = 'model_context' and body like '%Brasilia%'")" -ge 1 || { printf 'real-web-continuity-flow: second turn not present in later context\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 2 || { printf 'real-web-continuity-flow: missing real web_search executions\n' >&2; exit 1; }

printf 'real-web-continuity-flow: ok work=%s db=%s backend=%s host=%s model=%s search_url=%s\n' "$WORK" "$DB" "$BACKEND" "$HOST" "$MODEL" "$SEARCH_URL"
