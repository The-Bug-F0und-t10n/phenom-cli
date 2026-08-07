#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_PERSONAL_MEMORY_100_DIR:-/tmp/phenom-personal-memory-ambiguity-100}
DB="$WORK/.phenom-zig/phenom.db"
EXPECTED_MEMORY="prefiro respostas curtas em portugues"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'personal-memory-ambiguity-100: sqlite3 CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

sql_count() {
  sqlite3 "$DB" "select count(*) from $1 where $2;"
}

seed_memory() {
  session=$1
  (
    cd "$WORK"
    "$BIN" chat \
      --offline \
      --session "$session" \
      --prompt "seed personal memory db" \
      --no-color
  ) >"$WORK/$session.out"
  sqlite3 "$DB" "insert or ignore into personal_memory(kind, key, value, entities, confidence, source_session, hash) values ('preference', 'response_style', '$EXPECTED_MEMORY', 'portugues', 'confirmed', '$session', 'offline-seed-response-style');"
}

ambiguous_prompt() {
  slot=$(( ($1 - 1) % 10 ))
  case "$slot" in
    0) printf 'como devo agir agora?' ;;
    1) printf 'qual formato voce prefere usar comigo?' ;;
    2) printf 'siga o combinado' ;;
    3) printf 'continue do jeito certo' ;;
    4) printf 'manda do seu modo padrao' ;;
    5) printf 'esta ambiguidade usa qual estilo?' ;;
    6) printf 'sem contexto novo, qual postura?' ;;
    7) printf 'o que fica mais adequado aqui?' ;;
    8) printf 'aplique minha preferencia geral' ;;
    9) printf 'resolva de forma adequada' ;;
  esac
}

seed_memory personal-memory-seed-a
seed_memory personal-memory-seed-b

test -f "$DB" || { printf 'personal-memory-ambiguity-100: missing sqlite db\n' >&2; exit 1; }
test "$(sql_count personal_memory "active = 1 and kind = 'preference' and value = '$EXPECTED_MEMORY'")" -eq 1 || {
  printf 'personal-memory-ambiguity-100: dedupe failed for seeded preference\n' >&2
  exit 1
}

turn=1
while [ "$turn" -le 100 ]; do
  session=$(printf 'personal-memory-ambiguous-%03d' "$turn")
  prompt=$(ambiguous_prompt "$turn")
  case "$prompt" in
    *respostas*|*curtas*|*portugues*)
      printf 'personal-memory-ambiguity-100: prompt is not ambiguous: %s\n' "$prompt" >&2
      exit 1
      ;;
  esac
  (
    cd "$WORK"
    PHENOM_MODEL_CONTEXT_V1=1 "$BIN" chat \
      --backend llamacpp \
      --host 127.0.0.1:1 \
      --model unavailable \
      --session "$session" \
      --prompt "$prompt" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/$session.out" 2>"$WORK/$session.err" || true

  test "$(sql_count events "session = '$session' and kind = 'model_context' and body like '%[PERSONAL_MEMORY]%'")" -ge 1 || {
    printf 'personal-memory-ambiguity-100: PERSONAL_MEMORY missing at turn %s\n' "$turn" >&2
    exit 1
  }
  test "$(sql_count events "session = '$session' and kind = 'model_context' and body like '%$EXPECTED_MEMORY%'")" -ge 1 || {
    printf 'personal-memory-ambiguity-100: stored memory missing at turn %s\n' "$turn" >&2
    exit 1
  }
  test "$(sql_count events "session = '$session' and kind = 'model_context' and body like '%assistant_delta%'")" -eq 0 || {
    printf 'personal-memory-ambiguity-100: raw transcript leaked at turn %s\n' "$turn" >&2
    exit 1
  }
  turn=$((turn + 1))
done

contexts=$(sql_count events "session like 'personal-memory-ambiguous-%' and kind = 'model_context' and body like '%[PERSONAL_MEMORY]%'")
memory_hits=$(sql_count events "session like 'personal-memory-ambiguous-%' and kind = 'model_context' and body like '%$EXPECTED_MEMORY%'")
raw_leaks=$(sql_count events "session like 'personal-memory-ambiguous-%' and kind = 'model_context' and body like '%assistant_delta%'")
deduped=$(sql_count personal_memory "active = 1 and value = '$EXPECTED_MEMORY'")

test "$contexts" -eq 100 || { printf 'personal-memory-ambiguity-100: expected 100 contexts, got %s\n' "$contexts" >&2; exit 1; }
test "$memory_hits" -eq 100 || { printf 'personal-memory-ambiguity-100: expected 100 memory hits, got %s\n' "$memory_hits" >&2; exit 1; }
test "$raw_leaks" -eq 0 || { printf 'personal-memory-ambiguity-100: expected 0 raw leaks, got %s\n' "$raw_leaks" >&2; exit 1; }
test "$deduped" -eq 1 || { printf 'personal-memory-ambiguity-100: expected 1 deduped memory, got %s\n' "$deduped" >&2; exit 1; }

printf 'personal-memory-ambiguity-100: ok contexts=%s memory_hits=%s raw_leaks=%s deduped=%s db=%s\n' "$contexts" "$memory_hits" "$raw_leaks" "$deduped" "$DB"
