#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_PERSONAL_MEMORY_SMOKE_DIR:-/tmp/phenom-personal-memory-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'personal-memory-flow: sqlite3 CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

sql_count() {
  sqlite3 "$DB" "select count(*) from $1 where $2;"
}

(
  cd "$WORK"
  "$BIN" chat \
    --offline \
    --session personal-memory-seed \
    --prompt "seed personal memory db" \
    --no-color
) >"$WORK/seed.out"

test -f "$DB" || { printf 'personal-memory-flow: missing sqlite db\n' >&2; exit 1; }
sqlite3 "$DB" "insert or ignore into personal_memory(kind, key, value, entities, confidence, source_session, hash) values ('preference', 'response_style', 'respostas curtas em portugues', 'portugues', 'confirmed', 'personal-memory-seed', 'offline-seed-response-style');"
test "$(sql_count personal_memory "active = 1 and kind = 'preference' and value like '%respostas curtas em portugues%'")" -ge 1 || {
  printf 'personal-memory-flow: missing stored personal preference\n' >&2
  exit 1
}

(
  cd "$WORK"
  PHENOM_MODEL_CONTEXT_V1=1 "$BIN" chat \
    --backend llamacpp \
    --host 127.0.0.1:1 \
    --model unavailable \
    --session personal-memory-recall \
    --prompt "como devo responder?" \
    --fail-on-model-error \
    --no-color
) >"$WORK/recall.out" 2>"$WORK/recall.err" || true

test "$(sql_count events "session = 'personal-memory-recall' and kind = 'model_context' and body like '%[PERSONAL_MEMORY]%'")" -ge 1 || {
  printf 'personal-memory-flow: PERSONAL_MEMORY missing from model context\n' >&2
  exit 1
}
test "$(sql_count events "session = 'personal-memory-recall' and kind = 'model_context' and body like '%respostas curtas em portugues%'")" -ge 1 || {
  printf 'personal-memory-flow: stored preference missing from model context\n' >&2
  exit 1
}
test "$(sql_count events "session = 'personal-memory-recall' and kind = 'model_context' and body like '%assistant_delta%'")" -eq 0 || {
  printf 'personal-memory-flow: raw transcript leaked into personal memory context\n' >&2
  exit 1
}

sqlite3 "$DB" "update personal_memory set active = 0 where value like '%respostas curtas em portugues%';"
(
  cd "$WORK"
  PHENOM_MODEL_CONTEXT_V1=1 "$BIN" chat \
    --backend llamacpp \
    --host 127.0.0.1:1 \
    --model unavailable \
    --session personal-memory-after-forget \
    --prompt "como devo responder?" \
    --fail-on-model-error \
    --no-color
) >"$WORK/after_forget.out" 2>"$WORK/after_forget.err" || true

test "$(sql_count events "session = 'personal-memory-after-forget' and kind = 'model_context' and body like '%respostas curtas em portugues%'")" -eq 0 || {
  printf 'personal-memory-flow: inactive preference leaked after forget\n' >&2
  exit 1
}

printf 'personal-memory-flow: ok db=%s\n' "$DB"
