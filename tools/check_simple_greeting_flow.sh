#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_SIMPLE_GREETING_SMOKE_DIR:-/tmp/phenom-simple-greeting-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=simple-greeting-flow
EXPECT=PHENOM_SIMPLE_GREETING_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'simple-greeting-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"
PORT_FILE="$WORK/port"
"${ZIG:-zig}" run "$ROOT/tools/scripted_backend.zig" -lc -- simple_greeting "$PORT_FILE" - "$EXPECT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'simple-greeting-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "ola" \
    --max-tokens 128 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'simple-greeting-flow: missing final answer marker\n' >&2; exit 1; }
test "$(grep -c "$EXPECT" "$WORK/out.txt")" -eq 1 || { printf 'simple-greeting-flow: final answer emitted more than once\n' >&2; exit 1; }
! grep -q 'O usuario apenas cumprimentou' "$WORK/out.txt" || { printf 'simple-greeting-flow: hidden reasoning leaked to visible output\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'simple-greeting-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'answer_repair_done'")" -ge 1 || { printf 'simple-greeting-flow: missing think-only answer repair\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -eq 0 || { printf 'simple-greeting-flow: greeting unexpectedly collected evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence'")" -eq 0 || { printf 'simple-greeting-flow: greeting unexpectedly stored evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%collect_evidence%'")" -eq 0 || { printf 'simple-greeting-flow: greeting unexpectedly selected collect_evidence contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'simple-greeting-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'simple-greeting-flow: ok work=%s db=%s\n' "$WORK" "$DB"
