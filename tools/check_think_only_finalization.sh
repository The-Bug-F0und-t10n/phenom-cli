#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_THINK_ONLY_SMOKE_DIR:-/tmp/phenom-think-only-finalization-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=think-only-finalization
EXPECT=CMUS_HISTORY_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'think-only-finalization: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
sh "$ROOT/tools/start_scripted_backend.sh" think_only "$PORT_FILE" "$PROMPTS_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'think-only-finalization: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "analise: nao existe nenhum history no cmus em .config" \
    --max-tokens 64 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --show-expect-status \
    --fail-on-model-error \
    --no-color
) >"$WORK/agent.out" 2>"$WORK/agent.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/agent.out" || {
  printf 'think-only-finalization: final visible answer missing\n' >&2
  exit 1
}
! grep -q '\[MODEL_EMPTY_ANSWER\]' "$WORK/agent.out" || {
  printf 'think-only-finalization: empty answer diagnostic surfaced despite repair\n' >&2
  exit 1
}
! grep -q '\[MODEL_STOP\]' "$WORK/agent.out" || {
  printf 'think-only-finalization: stop diagnostic surfaced despite repair\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/agent.out" || {
  printf 'think-only-finalization: protocol error surfaced to user\n' >&2
  exit 1
}
grep -Eq '"max_tokens"[[:space:]]*:[[:space:]]*64' "$PROMPTS_FILE" || {
  printf 'think-only-finalization: llama.cpp request did not receive max token budget\n' >&2
  exit 1
}
grep -Eq '"enable_thinking"[[:space:]]*:[[:space:]]*true' "$PROMPTS_FILE" || {
  printf 'think-only-finalization: initial native thinking mode was not sent\n' >&2
  exit 1
}
grep -Eq '"enable_thinking"[[:space:]]*:[[:space:]]*false' "$PROMPTS_FILE" || {
  printf 'think-only-finalization: repair did not disable native thinking mode\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'assistant_thinking_delta' and body like '%cmus history%'")" -ge 1 || { printf 'think-only-finalization: missing thinking audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'model_context_budget' and body like '%tokenizer=backend%' and body like '%context_limit_tokens=8192%' and body like '%context_used_percent=%'")" -ge 1 || { printf 'think-only-finalization: context budget did not use backend tokenizer/window\n' >&2; exit 1; }
test "$(sql_count "kind = 'answer_repair' and body like '%think-only generation%'")" -ge 1 || { printf 'think-only-finalization: missing answer_repair audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'answer_repair_done'")" -ge 1 || { printf 'think-only-finalization: missing answer_repair_done audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'assistant_delta' and body like '%$EXPECT%'")" -ge 1 || { printf 'think-only-finalization: missing final assistant_delta\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%class=model_protocol%'")" -eq 0 || { printf 'think-only-finalization: repaired flow should not record model_protocol turn_error\n' >&2; exit 1; }
test "$(sql_count "kind = 'expectation_passed' and body = '$EXPECT'")" -ge 1 || { printf 'think-only-finalization: missing expectation_passed\n' >&2; exit 1; }

printf 'think-only-finalization: ok work=%s db=%s\n' "$WORK" "$DB"
