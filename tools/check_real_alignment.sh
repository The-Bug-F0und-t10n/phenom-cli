#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
BACKEND=${2:-llamacpp}
HOST=${3:-127.0.0.1:11434}
MODEL=${4:-phenom:latest}
SESSION=${5:-real-alignment-smoke}
PROMPT=${6:-Complete: PHENOM_REAL_ALIGNMENT_290}
EXPECT=${7:-PHENOM_REAL_ALIGNMENT_290}
DB="$ROOT/.phenom-zig/phenom.db"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'real-alignment: sqlite3 CLI is required for audit validation\n' >&2
  exit 1
}

case "$SESSION$EXPECT" in
  *"'"*) printf 'real-alignment: session/expect must not contain single quotes\n' >&2; exit 1 ;;
esac

"$BIN" chat \
  --backend "$BACKEND" \
  --host "$HOST" \
  --model "$MODEL" \
  --session "$SESSION" \
  --prompt "$PROMPT" \
  --max-tokens 128 \
  --expect-contains "$EXPECT" \
  --show-expect-status \
  --fail-on-model-error \
  --no-color

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'model_backend'")" -ge 1 || { printf 'real-alignment: missing model_backend audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'backend_metadata' and body like '%tokenizer=%' and body like '%context_window=%'")" -ge 1 || { printf 'real-alignment: missing backend_metadata audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_phase' and body like 'phase=intent%'")" -ge 1 || { printf 'real-alignment: missing intent phase audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_phase' and body like 'phase=final%'")" -ge 1 || { printf 'real-alignment: missing final phase audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'expectation_passed' and body = '$EXPECT'")" -ge 1 || { printf 'real-alignment: missing expectation_passed audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'assistant_offline_stub'")" -eq 0 || { printf 'real-alignment: real smoke used offline stub\n' >&2; exit 1; }

printf 'real-alignment: ok session=%s\n' "$SESSION"
