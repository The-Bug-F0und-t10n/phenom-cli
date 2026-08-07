#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_ARTIFACT_CREATE_SMOKE_DIR:-/tmp/phenom-artifact-create-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=artifact-create-flow
EXPECT=Salvo

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'artifact-create-flow: sqlite3 CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
LOG_FILE="$WORK/backend.log"
sh "$ROOT/tools/start_scripted_backend.sh" artifact_create "$PORT_FILE" "$LOG_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 200 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'artifact-create-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  PHENOM_MODEL_CONTEXT_V1=1 "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "Crie um HTML e diga o nome sugerido do arquivo." \
    --expect-contains "Save as space.html" \
    --show-expect-status \
    --fail-on-model-error \
    --no-color
) >"$WORK/generate.out" 2>"$WORK/generate.err"

(
  cd "$WORK"
  PHENOM_MODEL_CONTEXT_V1=1 "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "salva o codigo em um arquivo" \
    --expect-contains "$EXPECT" \
    --show-expect-status \
    --fail-on-model-error \
    --no-color
) >"$WORK/create.out" 2>"$WORK/create.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q 'PHENOM_ARTIFACT_TAIL' "$WORK/space.html" || {
  printf 'artifact-create-flow: space.html was not created from the full generated artifact\n' >&2
  exit 1
}
! grep -q '\[MODEL_FINALIZATION_BLOCKED\]' "$WORK/create.out" || {
  printf 'artifact-create-flow: finalization was blocked after create\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/create.out" || {
  printf 'artifact-create-flow: protocol error surfaced to user\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sqlite3 "$DB" "select count(*) from artifacts where session = '$SESSION' and path_hint = 'space.html' and language = 'html' and content like '%PHENOM_ARTIFACT_TAIL%';")" -ge 1 || { printf 'artifact-create-flow: full artifact was not stored losslessly\n' >&2; exit 1; }
test "$(sql_count "kind = 'artifact' and body like '%content_lossless=true%' and body like '%path_hint=space.html%'")" -ge 1 || { printf 'artifact-create-flow: missing artifact audit event\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=mutate_file%' and body like '%requestedContract=artifact_create%' and body like '%source=controller%'")" -ge 1 || { printf 'artifact-create-flow: missing controller mutate_file contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'apply_patch operation=create path=space.html%'")" -ge 1 || { printf 'artifact-create-flow: missing create apply_patch\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -eq 0 || { printf 'artifact-create-flow: create path unexpectedly collected workspace evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'patch_result' and body like '%operation=create%' and body like '%status=applied%'")" -ge 1 || { printf 'artifact-create-flow: missing create patch result\n' >&2; exit 1; }
test "$(sql_count "kind = 'artifact_saved' and body like '%path=space.html%' and body like '%bytes=%'")" -ge 1 || { printf 'artifact-create-flow: missing artifact_saved audit event\n' >&2; exit 1; }
test "$(sql_count "kind = 'finalization_blocked'")" -eq 0 || { printf 'artifact-create-flow: unexpected finalization_blocked event\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%'")" -ge 2 || { printf 'artifact-create-flow: missing successful turn_done events\n' >&2; exit 1; }

printf 'artifact-create-flow: ok work=%s db=%s\n' "$WORK" "$DB"
