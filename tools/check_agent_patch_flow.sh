#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_AGENT_PATCH_SMOKE_DIR:-/tmp/phenom-agent-patch-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=agent-patch-flow
EXPECT=PHENOM_AGENT_PATCH_OK
EXPECT_TEXT="Patch aplicado em src/math.zig."

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'agent-patch-flow: sqlite3 CLI is required\n' >&2
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
sh "$ROOT/tools/start_scripted_backend.sh" agent_patch "$PORT_FILE" "$LOG_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'agent-patch-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "A soma esta errada. Corrija o bug no projeto." \
    --expect-contains "$EXPECT_TEXT" \
    --show-expect-status \
    --fail-on-model-error \
    --no-color
) >"$WORK/agent.out" 2>"$WORK/agent.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q 'return a + b;' "$WORK/src/math.zig" || {
  printf 'agent-patch-flow: patch did not update src/math.zig\n' >&2
  exit 1
}
grep -q "$EXPECT" "$WORK/agent.out" || {
  printf 'agent-patch-flow: missing final marker\n' >&2
  exit 1
}
! grep -q 'return a - b;' "$WORK/src/math.zig" || {
  printf 'agent-patch-flow: stale buggy code remains\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/agent.out" || {
  printf 'agent-patch-flow: unexpected model protocol error in transcript\n' >&2
  exit 1
}
! grep -q 'required follow-up tool_call missing' "$WORK/agent.out" || {
  printf 'agent-patch-flow: required follow-up tool call missing surfaced to user\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}
focus_count() {
  sqlite3 "$DB" "select count(*) from session_focus where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_checkpoint'")" -ge 1 || { printf 'agent-patch-flow: missing checkpoint event\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=mutate_file%'")" -ge 1 || { printf 'agent-patch-flow: missing mutate_file contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || { printf 'agent-patch-flow: missing collect_evidence tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'apply_patch%'")" -ge 1 || { printf 'agent-patch-flow: missing apply_patch tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'patch_result' and body like '%status=applied%'")" -ge 1 || { printf 'agent-patch-flow: missing applied patch result\n' >&2; exit 1; }
test "$(sql_count "kind = 'expectation_passed' and body = '$EXPECT_TEXT'")" -ge 1 || { printf 'agent-patch-flow: missing expectation_passed\n' >&2; exit 1; }
test "$(focus_count "user_intent = 'turn_memory' and useful_facts like '%source=turn_memory_v1%'")" -ge 1 || { printf 'agent-patch-flow: missing completed turn memory\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%'")" -ge 1 || { printf 'agent-patch-flow: missing successful turn_done\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%class=model_protocol%'")" -eq 0 || { printf 'agent-patch-flow: unexpected model_protocol turn_error\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_loop_stop' and body like '%required follow-up tool call missing%'")" -eq 0 || { printf 'agent-patch-flow: unexpected required follow-up stop\n' >&2; exit 1; }
test "$(sql_count "kind = 'finalization_blocked'")" -eq 0 || { printf 'agent-patch-flow: unexpected finalization_blocked\n' >&2; exit 1; }

printf 'agent-patch-flow: ok work=%s db=%s\n' "$WORK" "$DB"
