#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_AMBIGUOUS_WEB_CONTINUITY_SMOKE_DIR:-/tmp/phenom-ambiguous-web-continuity-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=ambiguous-web-continuity-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'ambiguous-web-continuity-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
sh "$ROOT/tools/start_scripted_backend.sh" ambiguous_web "$PORT_FILE" "$PROMPTS_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'ambiguous-web-continuity-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

run_turn() {
  marker=$1
  prompt=$2
  out=$3
  (
    cd "$WORK"
    PHENOM_WEB_SEARCH_URL="http://127.0.0.1:$PORT/search?q={query}" "$BIN" chat \
      --backend llamacpp \
      --host "127.0.0.1:$PORT" \
      --model scripted \
      --session "$SESSION" \
      --prompt "$prompt" \
      --max-tokens 512 \
      --thinking on \
      --expect-contains "$marker" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/$out.out" 2>"$WORK/$out.err"
}

run_turn PHENOM_TEMPORAL_DATE_OK "moço, que dia é hoje?" temporal-date
run_turn PHENOM_TEMPORAL_WEEKDAY_OK "e hoje cai em que dia da semana?" temporal-weekday
run_turn PHENOM_AMBIG_T1 "vi falar que o horário mudou, como ficou isso em Brasília?" turn1
run_turn PHENOM_AMBIG_T2 "e aquele valor em real que o pessoal olha, como está agora?" turn2
run_turn PHENOM_DECL_T3 "confere também esse negócio do euro em real pra mim hoje" turn3
run_turn PHENOM_CONTINUITY_FINAL "sem olhar de novo, me explica rapidinho o que você conferiu" turn4

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

cat "$WORK"/turn*.out >"$WORK/all.out"
cat "$WORK"/turn*.err >"$WORK/all.err"

grep -q 'PHENOM_CONTINUITY_FINAL' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: missing final continuity marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_start'")" -eq 6 || { printf 'ambiguous-web-continuity-flow: expected six user turns\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -eq 6 || { printf 'ambiguous-web-continuity-flow: not all turns confirmed\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=set_operational_contract%' and body like '%state=accepted%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing accepted model contract declarations\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=search_web%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing search_web contract selections\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%external fact from ambiguous user wording%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing non-declarative ambiguous web contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%ambiguous follow-up needs current external evidence%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing ambiguous follow-up web contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%user explicitly requested ragweb%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing declarative ragweb contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_executor' and body like '%executor=web_search%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: search_web contract did not execute web_search repeatedly\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing web_search executions\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing web distillations\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_AMBIG_BRASILIA_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing distilled Brasilia evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_AMBIG_DOLAR_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing distilled dolar evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_DECL_EURO_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing distilled euro evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=web_search%'")" -eq 0 || { printf 'ambiguous-web-continuity-flow: model bypassed contract with direct web_search\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic%'")" -eq 0 || { printf 'ambiguous-web-continuity-flow: synthetic repair was used\n' >&2; exit 1; }

grep -q '\[RECENT_DIALOGUE\]' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: recent dialogue was not sent to model\n' >&2; exit 1; }
grep -q 'current_date=' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: current_date missing from model context\n' >&2; exit 1; }
grep -q 'current_weekday=' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: current_weekday missing from model context\n' >&2; exit 1; }
! grep -q 'TEMPORAL_CONTEXT_MISSING' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: temporal context was unavailable\n' >&2; exit 1; }
grep -q 'PHENOM_AMBIG_T1' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 1 marker not present in later context\n' >&2; exit 1; }
grep -q 'PHENOM_AMBIG_T2' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 2 marker not present in later context\n' >&2; exit 1; }
grep -q 'PHENOM_DECL_T3' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 3 marker not present in later context\n' >&2; exit 1; }
grep -q 'set_operational_contract(contract=answer_only|' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: operational contract schema missing\n' >&2; exit 1; }
grep -q '|search_web|rag_web|' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: web contracts missing from schema\n' >&2; exit 1; }
! grep -q 'required_tool_calls' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: required_tool_calls leaked into model prompt\n' >&2; exit 1; }

printf 'ambiguous-web-continuity-flow: ok work=%s db=%s\n' "$WORK" "$DB"
