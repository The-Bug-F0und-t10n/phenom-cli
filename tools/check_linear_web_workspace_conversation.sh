#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_LINEAR_WEB_WORKSPACE_SMOKE_DIR:-/tmp/phenom-linear-web-workspace-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=linear-web-workspace-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'linear-web-workspace-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/docs"
cat >"$WORK/README.md" <<'EOF'
# Linear Workspace Fixture

The local project implements a terminal agent with persistent dialogue, Web RAG, and workspace evidence.
Local marker: PHENOM_LOCAL_README_FACT.
EOF
cat >"$WORK/src/config.zig" <<'EOF'
pub const conversation_mode = "linear";
pub const workspace_marker = "PHENOM_LOCAL_CONFIG_FACT";
EOF
cat >"$WORK/docs/notes.md" <<'EOF'
The user wants active conversation continuity while the model switches between web evidence and local evidence.
EOF

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
"${ZIG:-zig}" run "$ROOT/tools/scripted_backend.zig" -lc -- linear_web_workspace "$PORT_FILE" "$PROMPTS_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'linear-web-workspace-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")
DOC1="http://127.0.0.1:$PORT/doc-alpha.html"
DOC2="http://127.0.0.1:$PORT/doc-beta.html"

run_turn() {
  marker=$1
  prompt=$2
  out=$3
  (
    cd "$WORK"
    "$BIN" chat \
      --backend llamacpp \
      --host "127.0.0.1:$PORT" \
      --model scripted \
      --session "$SESSION" \
      --prompt "$prompt" \
      --max-tokens 512 \
      --thinking on \
      --expect-contains "$marker" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/$out.out" 2>"$WORK/$out.err"
}

run_turn PHENOM_LINEAR_T1 "Ola. Vamos manter conversa linear sobre RAG Web e evidencia local." turn1
run_turn PHENOM_LINEAR_T2 "Agora use Web RAG para consultar $DOC1 e mantenha o assunto anterior." turn2
run_turn PHENOM_LINEAR_T3 "Agora leia o README local e conecte com a evidencia web anterior." turn3
run_turn PHENOM_LINEAR_FINAL "Agora consulte $DOC2, leia src/config.zig e compare tudo com o que ja conversamos." turn4

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

cat "$WORK"/turn*.out >"$WORK/all.out"
cat "$WORK"/turn*.err >"$WORK/all.err"

grep -q 'PHENOM_LINEAR_FINAL' "$WORK/all.out" || { printf 'linear-web-workspace-flow: missing final marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/all.out" || { printf 'linear-web-workspace-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_start'")" -eq 4 || { printf 'linear-web-workspace-flow: expected four user turns\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -eq 4 || { printf 'linear-web-workspace-flow: not all turns confirmed\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 2 || { printf 'linear-web-workspace-flow: missing repeated web_search calls\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 2 || { printf 'linear-web-workspace-flow: missing repeated web distillation\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 2 || { printf 'linear-web-workspace-flow: missing repeated workspace collection\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_ALPHA_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing distilled alpha web evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_BETA_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing distilled beta web evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_LOCAL_README_FACT%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing README evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_LOCAL_CONFIG_FACT%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing config evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic collect_evidence%'")" -eq 0 || { printf 'linear-web-workspace-flow: synthetic collect_evidence was used\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic search_session%'")" -eq 0 || { printf 'linear-web-workspace-flow: synthetic search_session was used\n' >&2; exit 1; }

grep -q '\[RECENT_DIALOGUE\]' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: recent dialogue was not sent to model\n' >&2; exit 1; }
grep -q 'PHENOM_LINEAR_T1' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: turn 1 marker not present in later model context\n' >&2; exit 1; }
grep -q 'PHENOM_LINEAR_T2' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: turn 2 marker not present in later model context\n' >&2; exit 1; }
grep -q 'PHENOM_LINEAR_T3' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: turn 3 marker not present in later model context\n' >&2; exit 1; }
! grep -q 'required_tool_calls' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: required_tool_calls leaked into model prompt\n' >&2; exit 1; }

printf 'linear-web-workspace-flow: ok work=%s db=%s\n' "$WORK" "$DB"
