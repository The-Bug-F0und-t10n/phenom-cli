#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_REQUIRED_TOOL_REPAIR_SMOKE_DIR:-/tmp/phenom-required-tool-repair-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=required-tool-repair-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'required-tool-repair-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK/src"
cat >"$WORK/src/math.zig" <<'ZIG'
pub fn add(a: i32, b: i32) i32 {
    return a - b;
}
ZIG

PORT_FILE="$WORK/port"
LOG_FILE="$WORK/backend.log"
sh "$ROOT/tools/start_scripted_backend.sh" required_tool_repair "$PORT_FILE" "$LOG_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'required-tool-repair-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "A soma esta errada. Corrija o bug no projeto." \
    --max-tokens 900 \
    --fail-on-model-error \
    --no-color
) >"$WORK/agent.out" 2>"$WORK/agent.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

! grep -q 'return a + b;' "$WORK/src/math.zig" || {
  printf 'required-tool-repair-flow: patch was applied even though apply_patch was never emitted\n' >&2
  exit 1
}
grep -q 'return a - b;' "$WORK/src/math.zig" || {
  printf 'required-tool-repair-flow: original file unexpectedly changed\n' >&2
  exit 1
}
grep -q '\[MODEL_FINALIZATION_BLOCKED\]' "$WORK/agent.out" || {
  printf 'required-tool-repair-flow: missing controlled finalization block in transcript\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/agent.out" || {
  printf 'required-tool-repair-flow: protocol error surfaced to user\n' >&2
  exit 1
}
! grep -q 'required follow-up tool_call missing' "$WORK/agent.out" || {
  printf 'required-tool-repair-flow: internal repair detail surfaced to user\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'contract_selected' and body like '%contract=mutate_file%'")" -ge 1 || { printf 'required-tool-repair-flow: missing mutate_file contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || { printf 'required-tool-repair-flow: missing collect_evidence tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'apply_patch%'")" -eq 0 || { printf 'required-tool-repair-flow: apply_patch should not have run\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body = 'required follow-up tool call missing'")" -ge 1 || { printf 'required-tool-repair-flow: missing first repair audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_loop_stop' and body like '%required follow-up tool call missing after repair%'")" -ge 1 || { printf 'required-tool-repair-flow: missing controlled stop audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%class=model_protocol%source=required_tool_repair%'")" -ge 1 || { printf 'required-tool-repair-flow: missing model_protocol audit error\n' >&2; exit 1; }
test "$(sql_count "kind = 'assistant_delta' and body like '%[MODEL_FINALIZATION_BLOCKED]%'")" -ge 1 || { printf 'required-tool-repair-flow: missing visible controlled assistant event\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=uncertain%turn_error=true%low_confidence=true%'")" -ge 1 || { printf 'required-tool-repair-flow: missing uncertain turn_done quality\n' >&2; exit 1; }

focus_count() {
  sqlite3 "$DB" "select count(*) from session_focus where session = '$SESSION' and $1;"
}

test "$(focus_count "user_intent = 'turn_memory' and quality = 'uncertain' and flags like '%turn_error=true%'")" -ge 1 || { printf 'required-tool-repair-flow: blocked turn memory should be uncertain\n' >&2; exit 1; }

printf 'required-tool-repair-flow: ok work=%s db=%s\n' "$WORK" "$DB"
