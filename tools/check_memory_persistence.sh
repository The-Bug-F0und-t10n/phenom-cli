#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_MEMORY_SMOKE_DIR:-/tmp/phenom-memory-persistence-smoke}
DB="$WORK/.phenom-zig/phenom.db"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'memory-persistence: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"

sql_count() {
  sqlite3 "$DB" "select count(*) from $1 where session = '$2' and $3;"
}

COMPLETED_SESSION=memory-persistence-completed
(
  cd "$WORK"
  "$BIN" chat \
    --offline \
    --session "$COMPLETED_SESSION" \
    --prompt "implemente memoria conversacional persistente integrada ao session_focus e mantenha detalhes recuperaveis via search_session" \
    --no-color
) >"$WORK/completed.out"

test -f "$DB" || { printf 'memory-persistence: missing sqlite db\n' >&2; exit 1; }
test "$(sql_count events "$COMPLETED_SESSION" "kind = 'turn_checkpoint'")" -ge 1 || { printf 'memory-persistence: completed turn missing checkpoint event\n' >&2; exit 1; }
test "$(sql_count events "$COMPLETED_SESSION" "kind = 'turn_done'")" -ge 1 || { printf 'memory-persistence: completed turn missing turn_done\n' >&2; exit 1; }
test "$(sql_count session_focus "$COMPLETED_SESSION" "user_intent = 'turn_checkpoint' and useful_facts like '%source=turn_checkpoint_v1%'")" -ge 1 || { printf 'memory-persistence: completed turn missing checkpoint focus\n' >&2; exit 1; }
test "$(sql_count session_focus "$COMPLETED_SESSION" "user_intent = 'turn_memory' and useful_facts like '%source=turn_memory_v1%' and useful_facts like '%detail_available: assistant_delta event%'")" -ge 1 || { printf 'memory-persistence: completed turn missing structured memory focus\n' >&2; exit 1; }

PORT_FILE="$WORK/port"
sh "$ROOT/tools/start_scripted_backend.sh" memory_blocking "$PORT_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'memory-persistence: local blocking server did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

INTERRUPTED_SESSION=memory-persistence-interrupted
(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model blocked \
    --session "$INTERRUPTED_SESSION" \
    --prompt "continue a melhoria estrutural de memoria conversacional depois de uma queda abrupta" \
    --no-color
) >"$WORK/interrupted.out" 2>"$WORK/interrupted.err" &
CLIENT_PID=$!

i=0
while [ "$i" -lt 80 ]; do
  if [ -f "$DB" ] && [ "$(sql_count session_focus "$INTERRUPTED_SESSION" "user_intent = 'turn_checkpoint' and useful_facts like '%active_task:%'")" -ge 1 ]; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done

kill "$CLIENT_PID" 2>/dev/null || true
wait "$CLIENT_PID" 2>/dev/null || true
kill "$SERVER_PID" 2>/dev/null || true
trap - EXIT

test "$(sql_count events "$INTERRUPTED_SESSION" "kind = 'turn_start'")" -ge 1 || { printf 'memory-persistence: interrupted turn missing turn_start\n' >&2; exit 1; }
test "$(sql_count events "$INTERRUPTED_SESSION" "kind = 'turn_checkpoint'")" -ge 1 || { printf 'memory-persistence: interrupted turn missing checkpoint event\n' >&2; exit 1; }
test "$(sql_count session_focus "$INTERRUPTED_SESSION" "user_intent = 'turn_checkpoint' and quality = 'in_progress'")" -ge 1 || { printf 'memory-persistence: interrupted turn missing resumable focus\n' >&2; exit 1; }
test "$(sql_count session_focus "$INTERRUPTED_SESSION" "user_intent = 'turn_memory'")" -eq 0 || { printf 'memory-persistence: interrupted turn should not have completed memory\n' >&2; exit 1; }
test "$(sql_count events "$INTERRUPTED_SESSION" "kind = 'turn_done'")" -eq 0 || { printf 'memory-persistence: interrupted turn should not have turn_done\n' >&2; exit 1; }

printf 'memory-persistence: ok db=%s\n' "$DB"
