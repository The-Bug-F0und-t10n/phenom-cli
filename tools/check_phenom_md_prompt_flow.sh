#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$PWD/$BIN" ;;
esac
WORK=${PHENOM_MD_PROMPT_SMOKE_DIR:-$(mktemp -d /tmp/phenom-md-prompt-flow.XXXXXX)}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=phenom-md-prompt-flow
EXPECT=PHENOM_MD_PROMPT_USED_OK
EXPECT_TEXT="Phenom.md carregado no system prompt"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'phenom-md-prompt-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
mkdir -p "$WORK"
PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
sh "$ROOT/tools/start_scripted_backend.sh" phenom_md "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'phenom-md-prompt-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

cat > "$WORK/README.md" <<'EOF'
# Projeto Teste

Este workspace testa prompt permanente Phenom.md.
EOF

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "/create_custom_prompt" \
    --max-tokens 512 \
    --thinking off \
    --fail-on-model-error \
    --no-color

  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "ola" \
    --max-tokens 128 \
    --thinking off \
    --expect-contains "$EXPECT_TEXT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q '# Phenom Behavioral System Prompt' "$WORK/Phenom.md" || { printf 'phenom-md-prompt-flow: Phenom.md heading was not canonicalized\n' >&2; exit 1; }
grep -q 'system prompt behavior override' "$WORK/Phenom.md" || { printf 'phenom-md-prompt-flow: Phenom.md fallback was not generated\n' >&2; exit 1; }
grep -q "$EXPECT" "$WORK/out.txt" || { printf 'phenom-md-prompt-flow: custom prompt chat did not finish\n' >&2; exit 1; }

FIRST_REQUEST=$(awk '/---REQUEST 1---/{flag=1;next}/---REQUEST 2---/{flag=0}flag' "$PROMPTS_FILE")
SECOND_REQUEST=$(awk '/---REQUEST 2---/{flag=1;next}flag' "$PROMPTS_FILE")
printf '%s' "$FIRST_REQUEST" | grep -q '\[CREATE_PHENOM_MD\]' || { printf 'phenom-md-prompt-flow: generator request did not receive create prompt\n' >&2; exit 1; }
printf '%s' "$FIRST_REQUEST" | grep -q 'Model decides when contracts/tools are needed' || { printf 'phenom-md-prompt-flow: generator request did not use stock prompt fallback\n' >&2; exit 1; }
printf '%s' "$SECOND_REQUEST" | grep -q 'system prompt behavior override' || { printf 'phenom-md-prompt-flow: second request did not load Phenom.md\n' >&2; exit 1; }
! printf '%s' "$SECOND_REQUEST" | grep -q 'Model decides when contracts/tools are needed' || { printf 'phenom-md-prompt-flow: custom Phenom.md request still used stock prompt\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'custom_prompt_created' and body like '%Phenom.md%'")" -ge 1 || { printf 'phenom-md-prompt-flow: missing custom_prompt_created audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'custom_prompt_fallback' and body like '%InvalidGeneratedPrompt%'")" -ge 1 || { printf 'phenom-md-prompt-flow: missing custom_prompt_fallback audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%stage=overview%create_custom_prompt%'")" -ge 1 || { printf 'phenom-md-prompt-flow: create_custom_prompt did not collect project overview\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_event' and body like '%workspace_overview%'")" -ge 1 || { printf 'phenom-md-prompt-flow: overview collection did not use workspace_overview\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'phenom-md-prompt-flow: final turn was not confirmed\n' >&2; exit 1; }

printf 'phenom-md-prompt-flow: ok work=%s db=%s\n' "$WORK" "$DB"
