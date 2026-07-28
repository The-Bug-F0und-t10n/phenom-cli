#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$PWD/$BIN" ;;
esac
WORK=${PHENOM_UNKNOWN_SLASH_SMOKE_DIR:-/tmp/phenom-unknown-slash-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=unknown-slash-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'unknown-slash-flow: sqlite3 CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:9" \
    --model unavailable \
    --session "$SESSION" \
    --prompt "/does_not_exist" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

grep -q 'Comando local desconhecido: /does_not_exist' "$WORK/out.txt" || { printf 'unknown-slash-flow: missing local unknown command answer\n' >&2; exit 1; }
grep -q '/create_custom_prompt' "$WORK/out.txt" || { printf 'unknown-slash-flow: missing local command help\n' >&2; exit 1; }
! grep -q 'model connection failed' "$WORK/out.txt" || { printf 'unknown-slash-flow: backend was called\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'local_command_unknown' and body = '/does_not_exist'")" -ge 1 || { printf 'unknown-slash-flow: missing local command audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'model_backend'")" -eq 0 || { printf 'unknown-slash-flow: backend metadata recorded for local command\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%'")" -ge 1 || { printf 'unknown-slash-flow: turn was not completed ok\n' >&2; exit 1; }

printf 'unknown-slash-flow: ok work=%s db=%s\n' "$WORK" "$DB"
