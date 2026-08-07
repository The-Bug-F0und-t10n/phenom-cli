#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_RULE_PROMOTION_DIR:-/tmp/phenom-rule-promotion-flow}
DB="$WORK/.phenom-zig/phenom.db"
PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'rule-promotion-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"

sh "$ROOT/tools/start_scripted_backend.sh" rule_promotion "$PORT_FILE" "$PROMPTS_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 200 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'rule-promotion-flow: fake model did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")
SESSION=rule-promotion-flow

(
  cd "$WORK"
  "$BIN" chat --backend llamacpp --host "127.0.0.1:$PORT" --model fake --session "$SESSION" --prompt "daqui pra frente, nao faca comite sem rodar testes" --no-color
) >"$WORK/turn1.out" 2>"$WORK/turn1.err"

grep -q 'Nao commitar sem rodar testes' "$WORK/SKILLS.md" || {
  printf 'rule-promotion-flow: SKILLS.md missing promoted interpreted rule\n' >&2
  exit 1
}
grep -q 'PHENOM_MEMORY_CONTEXT_BEGIN' "$WORK/MEMORY.md" || {
  printf 'rule-promotion-flow: MEMORY.md missing managed context section\n' >&2
  exit 1
}

(
  cd "$WORK"
  "$BIN" chat --backend llamacpp --host "127.0.0.1:$PORT" --model fake --session "$SESSION" --prompt "qual regra local devo seguir antes de commitar?" --no-color
) >"$WORK/turn2.out" 2>"$WORK/turn2.err"

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'contract_selected' and body like '%contract=memory%'")" -ge 2 || {
  printf 'rule-promotion-flow: memory contract was not selected in both turns\n' >&2
  exit 1
}
test "$(sql_count "kind = 'persistent_promotion' and body like '%target=skills%' and body like '%status=promoted%'")" -ge 1 || {
  printf 'rule-promotion-flow: missing persistent_promotion audit\n' >&2
  exit 1
}
test "$(sql_count "kind = 'persistent_context' and body like '%Nao commitar sem rodar testes%'")" -ge 1 || {
  printf 'rule-promotion-flow: second turn did not retrieve SKILLS.md\n' >&2
  exit 1
}
test "$(sql_count "kind = 'persistent_context_distillation' and body like '%status=distilled_context%'")" -ge 2 || {
  printf 'rule-promotion-flow: missing MEMORY.md context distillation audit\n' >&2
  exit 1
}
test "$(sql_count "kind = 'answer_repair' and body = 'retrieved skills contradiction'")" -ge 1 || {
  printf 'rule-promotion-flow: retrieved SKILLS contradiction did not trigger answer repair\n' >&2
  exit 1
}
grep -q 'nao commitar sem rodar testes' "$WORK/turn2.out" || {
  printf 'rule-promotion-flow: final answer did not apply retrieved rule\n' >&2
  exit 1
}
! grep -q 'Nao tenho nenhuma regra local persistida' "$WORK/turn2.out" || {
  printf 'rule-promotion-flow: contradicted SKILLS answer leaked to user\n' >&2
  exit 1
}
grep -q 'requiresMemoryPromotion' "$PROMPTS_FILE" || {
  printf 'rule-promotion-flow: prompt did not expose memory promotion contract\n' >&2
  exit 1
}
grep -q 'generic best practices' "$PROMPTS_FILE" || {
  printf 'rule-promotion-flow: prompt did not constrain retrieved SKILLS answers\n' >&2
  exit 1
}

kill "$SERVER_PID" 2>/dev/null || true
trap - EXIT
printf 'rule-promotion-flow: ok workdir=%s\n' "$WORK"
