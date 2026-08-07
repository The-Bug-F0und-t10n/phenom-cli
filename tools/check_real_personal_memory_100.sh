#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_REAL_PERSONAL_MEMORY_100_DIR:-/tmp/phenom-real-personal-memory-100}
BACKEND=${PHENOM_REAL_PERSONAL_MEMORY_BACKEND:-llamacpp}
HOST=${PHENOM_REAL_PERSONAL_MEMORY_HOST:-inference.local:11434}
MODEL=${PHENOM_REAL_PERSONAL_MEMORY_MODEL:-phenom:latest}
TIMEOUT=${PHENOM_REAL_PERSONAL_MEMORY_TIMEOUT:-90}
EXPECTED=${PHENOM_REAL_PERSONAL_MEMORY_EXPECTED:-PMEM100}
THINKING=${PHENOM_REAL_PERSONAL_MEMORY_THINKING:-off}
SEED_PROMPT=${PHENOM_REAL_PERSONAL_MEMORY_SEED_PROMPT:-"Merke dir: Mein persönlicher Validierungscode ist $EXPECTED."}
DB="$WORK/.phenom-zig/phenom.db"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'real-personal-memory-100: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v timeout >/dev/null 2>&1 || {
  printf 'real-personal-memory-100: timeout CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

sql_count() {
  sqlite3 "$DB" "select count(*) from $1 where $2;"
}

run_chat() {
  session=$1
  prompt=$2
  expected=$3
  output=$4
  error=$5
  (
    cd "$WORK"
    timeout "$TIMEOUT" "$BIN" chat \
      --backend "$BACKEND" \
      --host "$HOST" \
      --model "$MODEL" \
      --session "$session" \
      --prompt "$prompt" \
      --max-tokens 256 \
      --thinking "$THINKING" \
      --expect-contains "$expected" \
      --show-expect-status \
      --fail-on-model-error \
      --no-color
  ) >"$output" 2>"$error"
}

seed_memory() {
  (
    cd "$WORK"
    timeout "$TIMEOUT" "$BIN" chat \
      --backend "$BACKEND" \
      --host "$HOST" \
      --model "$MODEL" \
      --session real-personal-memory-seed \
      --prompt "$SEED_PROMPT" \
      --max-tokens 256 \
      --thinking "$THINKING" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/seed.out" 2>"$WORK/seed.err"
}

prompt_for() {
  slot=$(( ($1 - 1) % 10 ))
  case "$slot" in
    0) printf 'Use a memoria pessoal armazenada. Qual e meu codigo pessoal salvo? Responda apenas o codigo.' ;;
    1) printf 'Pelo que voce sabe sobre mim, qual e o codigo combinado? Responda apenas o codigo.' ;;
    2) printf 'Sem usar historico bruto, consulte sua memoria pessoal e responda meu identificador de validacao.' ;;
    3) printf 'Pergunta ambigua: qual e aquele valor pessoal que eu pedi para voce lembrar? Responda so o valor.' ;;
    4) printf 'Aplique a memoria pessoal persistente: qual token identifica minha preferencia de validacao?' ;;
    5) printf 'Qual codigo curto voce lembra sobre mim? Responda somente o codigo.' ;;
    6) printf 'Sem repetir explicacoes: o que esta salvo como meu codigo pessoal?' ;;
    7) printf 'Use PERSONAL_MEMORY se existir. Qual e meu token salvo?' ;;
    8) printf 'Recupere o valor pessoal persistido para validacao. Responda so o token.' ;;
    9) printf 'O usuario pergunta de forma vaga: qual e o codigo? Use a memoria pessoal e responda apenas o valor.' ;;
  esac
}

seed_memory

test -f "$DB" || { printf 'real-personal-memory-100: missing sqlite db\n' >&2; exit 1; }
test "$(sql_count personal_memory "active = 1 and value like '%$EXPECTED%'")" -eq 1 || {
  printf 'real-personal-memory-100: seed memory was not persisted once\n' >&2
  exit 1
}

failures=0
retries=0
turn=1
while [ "$turn" -le 100 ]; do
  session=$(printf 'real-personal-memory-ambiguous-%03d' "$turn")
  prompt=$(prompt_for "$turn")
  case "$prompt" in
    *"$EXPECTED"*)
      printf 'real-personal-memory-100: prompt leaks expected token at turn %s\n' "$turn" >&2
      exit 1
      ;;
  esac
  attempt=1
  passed=0
  while [ "$attempt" -le 3 ]; do
    output="$WORK/$session-attempt-$attempt.out"
    error="$WORK/$session-attempt-$attempt.err"
    if run_chat "$session" "$prompt" "$EXPECTED" "$output" "$error"; then
      passed=1
      break
    fi
    retries=$((retries + 1))
    attempt=$((attempt + 1))
    sleep 1
  done
  if [ "$passed" -ne 1 ]; then
    printf 'real-personal-memory-100: turn %s failed prompt="%s"\n' "$turn" "$prompt" >>"$WORK/failures.log"
    failures=$((failures + 1))
  fi
  turn=$((turn + 1))
done

contexts=$(sql_count events "session like 'real-personal-memory-ambiguous-%' and kind = 'model_context' and body like '%[PERSONAL_MEMORY]%'")
memory_hits=$(sql_count events "session like 'real-personal-memory-ambiguous-%' and kind = 'model_context' and body like '%$EXPECTED%'")
assistant_hits=$(sql_count events "session like 'real-personal-memory-ambiguous-%' and kind = 'assistant_delta' and body like '%$EXPECTED%'")
raw_leaks=$(sql_count events "session like 'real-personal-memory-ambiguous-%' and kind = 'model_context' and body like '%assistant_delta%'")
stored=$(sql_count personal_memory "active = 1 and value like '%$EXPECTED%'")

test "$failures" -eq 0 || { printf 'real-personal-memory-100: failures=%s retries=%s work=%s\n' "$failures" "$retries" "$WORK" >&2; exit 1; }
test "$contexts" -ge 100 || { printf 'real-personal-memory-100: expected at least 100 contexts, got %s\n' "$contexts" >&2; exit 1; }
test "$memory_hits" -ge 100 || { printf 'real-personal-memory-100: expected at least 100 memory contexts, got %s\n' "$memory_hits" >&2; exit 1; }
test "$assistant_hits" -ge 100 || { printf 'real-personal-memory-100: expected at least 100 model recalls, got %s\n' "$assistant_hits" >&2; exit 1; }
test "$raw_leaks" -eq 0 || { printf 'real-personal-memory-100: expected 0 raw leaks, got %s\n' "$raw_leaks" >&2; exit 1; }
test "$stored" -eq 1 || { printf 'real-personal-memory-100: expected 1 active stored memory, got %s\n' "$stored" >&2; exit 1; }

printf 'real-personal-memory-100: ok model=%s host=%s thinking=%s contexts=%s memory_hits=%s assistant_hits=%s raw_leaks=%s stored=%s retries=%s db=%s\n' "$MODEL" "$HOST" "$THINKING" "$contexts" "$memory_hits" "$assistant_hits" "$raw_leaks" "$stored" "$retries" "$DB"
