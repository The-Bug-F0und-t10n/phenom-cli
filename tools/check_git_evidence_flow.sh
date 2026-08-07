#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_GIT_EVIDENCE_SMOKE_DIR:-/tmp/phenom-git-evidence-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=git-evidence-reflog-flow
EXPECT=PHENOM_GIT_REFLOG_OK

command -v git >/dev/null 2>&1 || {
  printf 'git-evidence-flow: git is required\n' >&2
  exit 1
}
command -v sqlite3 >/dev/null 2>&1 || {
  printf 'git-evidence-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"
(
  cd "$WORK"
  git init -q
  git config user.email phenom@example.invalid
  git config user.name Phenom
  printf 'initial\n' > collect_evidence.txt
  git add collect_evidence.txt
  git commit -q -m 'initial collect_evidence baseline'
  printf 'web_distillation deleted commit marker\n' >> collect_evidence.txt
  git add collect_evidence.txt
  git commit -q -m 'deleted commit touching collect_evidence web_distillation'
  git reset --hard HEAD~1 >/dev/null
)

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
sh "$ROOT/tools/start_scripted_backend.sh" git_evidence "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'git-evidence-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "Use collect_evidence source=git strategy=reflog para recuperar o commit removido que tocou collect_evidence web_distillation e responda contendo $EXPECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'git-evidence-flow: missing final answer marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'git-evidence-flow: protocol error surfaced\n' >&2; exit 1; }
grep -q 'strategyId>collect_git_reflog' "$PROMPTS_FILE" || { printf 'git-evidence-flow: collect_git_reflog strategy id was not requested by model\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%' and body like '%reflog%'")" -ge 1 || { printf 'git-evidence-flow: missing collect_evidence reflog tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like '%strategy_id=collect_git_reflog%'")" -ge 1 || { printf 'git-evidence-flow: missing strategy id audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_event' and body like '%source=git%' and body like '%strategy=reflog%'")" -ge 1 || { printf 'git-evidence-flow: missing git reflog tool_event\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%[GIT_REFLOG]%' and body like '%deleted commit touching collect_evidence web_distillation%'")" -ge 1 || { printf 'git-evidence-flow: missing reflog evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body not like '%git reflog --all%'")" -ge 1 || { printf 'git-evidence-flow: raw command leaked into model evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%required follow-up%'")" -eq 0 || { printf 'git-evidence-flow: unexpected required follow-up repair\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%answer deferred available workspace evidence collection%'")" -eq 0 || { printf 'git-evidence-flow: cited git answer was incorrectly deferred\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'git-evidence-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'git-evidence-flow: ok work=%s db=%s\n' "$WORK" "$DB"
