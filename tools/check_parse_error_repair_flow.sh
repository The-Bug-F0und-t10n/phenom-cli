#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$PWD/$BIN" ;;
esac
WORK=${PHENOM_PARSE_ERROR_REPAIR_SMOKE_DIR:-/tmp/phenom-parse-error-repair-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=parse-error-repair-flow
EXPECT=PHENOM_PARSE_ERROR_REPAIRED

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'parse-error-repair-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"
PORT_FILE="$WORK/port"
sh "$ROOT/tools/start_scripted_backend.sh" parse_error "$PORT_FILE" - "$EXPECT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'parse-error-repair-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "use uma ferramenta se precisar" \
    --max-tokens 128 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'parse-error-repair-flow: missing repaired final answer\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'parse-error-repair-flow: protocol error surfaced\n' >&2; exit 1; }
! grep -q '<parse_error>' "$WORK/out.txt" || { printf 'parse-error-repair-flow: pseudo parse tool surfaced\n' >&2; exit 1; }
! grep -q 'rejected by the active contract' "$WORK/out.txt" || { printf 'parse-error-repair-flow: parse error rendered as contract rejection\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_parse_error'")" -ge 1 || { printf 'parse-error-repair-flow: missing tool_parse_error audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_rejected' and body like '%parse_error%'")" -eq 0 || { printf 'parse-error-repair-flow: parse error stored as rejected tool\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%parse_error%'")" -eq 0 || { printf 'parse-error-repair-flow: recoverable parse error stored as turn error\n' >&2; exit 1; }
test "$(sql_count "kind = 'assistant_delta' and body like '%$EXPECT%'")" -ge 1 || { printf 'parse-error-repair-flow: repaired answer was not emitted\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%'")" -ge 1 || { printf 'parse-error-repair-flow: turn was not completed ok\n' >&2; exit 1; }

printf 'parse-error-repair-flow: ok work=%s db=%s\n' "$WORK" "$DB"
