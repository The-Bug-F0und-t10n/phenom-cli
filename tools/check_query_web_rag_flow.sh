#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_QUERY_WEB_RAG_SMOKE_DIR:-/tmp/phenom-query-web-rag-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=query-web-rag-flow
EXPECT=PHENOM_QUERY_WEB_RAG_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'query-web-rag-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
"${ZIG:-zig}" run "$ROOT/tools/scripted_backend.zig" -lc -- query_web "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'query-web-rag-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  printf 'web_search_url = "http://127.0.0.1:%s/search?q={query}"\n' "$PORT" > config.toml
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "Qual e o horario de Brasilia agora? Responda contendo $EXPECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'query-web-rag-flow: missing final answer marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'query-web-rag-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_start' and body like 'web_search%' and body like '%/search?q=horario%20de%20brasilia%'")" -ge 1 || { printf 'query-web-rag-flow: missing query-resolved web_search tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 1 || { printf 'query-web-rag-flow: missing web distillation\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_QUERY_WEB_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'query-web-rag-flow: missing distilled query evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'query-web-rag-flow: turn was not confirmed\n' >&2; exit 1; }

test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=set_operational_contract%' and body like '%state=accepted%'")" -ge 1 || { printf 'query-web-rag-flow: model contract declaration was not accepted\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=search_web%' and body like '%strategyId=search_web_distilled%'")" -ge 1 || { printf 'query-web-rag-flow: rag_web contract was not selected\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_executor' and body like '%executor=web_search%'")" -ge 1 || { printf 'query-web-rag-flow: search_web contract did not execute web_search\n' >&2; exit 1; }
grep -q 'web_search_url/PHENOM_WEB_SEARCH_URL' "$PROMPTS_FILE" || { printf 'query-web-rag-flow: schema did not expose configured query search behavior\n' >&2; exit 1; }

printf 'query-web-rag-flow: ok work=%s db=%s\n' "$WORK" "$DB"
