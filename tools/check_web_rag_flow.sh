#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_WEB_RAG_SMOKE_DIR:-/tmp/phenom-web-rag-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
WEB_SESSION=web-rag-tool-flow
COLLECT_SESSION=web-rag-collect-flow
EXPECT_WEB=PHENOM_WEB_RAG_OK
EXPECT_COLLECT=PHENOM_COLLECT_WEB_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'web-rag-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
"${ZIG:-zig}" run "$ROOT/tools/scripted_backend.zig" -lc -- web_rag "$PORT_FILE" "$PROMPTS_FILE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'web-rag-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")
TARGET="http://127.0.0.1:$PORT/doc.html"

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$WEB_SESSION" \
    --prompt "Use evidencia web contratual para resumir $TARGET e responda contendo $EXPECT_WEB." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT_WEB" \
    --fail-on-model-error \
    --no-color
) >"$WORK/web.out" 2>"$WORK/web.err"

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$COLLECT_SESSION" \
    --prompt "Use collect_evidence com target URL para coletar $TARGET e responda contendo $EXPECT_COLLECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT_COLLECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/collect.out" 2>"$WORK/collect.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT_WEB" "$WORK/web.out" || { printf 'web-rag-flow: missing web_search final answer\n' >&2; exit 1; }
grep -q "$EXPECT_COLLECT" "$WORK/collect.out" || { printf 'web-rag-flow: missing collect_evidence final answer\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/web.out" || { printf 'web-rag-flow: protocol error surfaced in web_search flow\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/collect.out" || { printf 'web-rag-flow: protocol error surfaced in collect_evidence flow\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$1' and $2;"
}

test "$(sql_count "$WEB_SESSION" "kind = 'contract_selected' and body like '%contract=collect_evidence%' and body like '%web_search%'")" -ge 1 || { printf 'web-rag-flow: web_search contract not selected\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'tool_start' and body like 'web_search%' and body like '%$TARGET%'")" -ge 1 || { printf 'web-rag-flow: missing web_search tool_start\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'tool_event' and body like '%tool=web_search%' and body like '%status=200%'")" -ge 1 || { printf 'web-rag-flow: missing web_search successful tool_event\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'web_distillation' and body like '%success=true%' and body like '%output_bytes=%'")" -ge 1 || { printf 'web-rag-flow: missing web_search model distillation audit\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'evidence' and body like '%[WEB_EVIDENCE]%' and body like '%Phenom Web RAG%' and body not like '%<html>%'")" -ge 1 || { printf 'web-rag-flow: missing distilled WEB_EVIDENCE\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'web-rag-flow: web_search turn was not confirmed\n' >&2; exit 1; }

test "$(sql_count "$COLLECT_SESSION" "kind = 'tool_start' and body like 'collect_evidence%' and body like '%$TARGET%'")" -ge 1 || { printf 'web-rag-flow: missing collect_evidence URL tool_start\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'tool_event' and body like '%tool=web_search%' and body like '%status=200%'")" -ge 1 || { printf 'web-rag-flow: collect_evidence did not reuse web executor\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'web_distillation' and body like '%success=true%' and body like '%output_bytes=%'")" -ge 1 || { printf 'web-rag-flow: missing collect_evidence model distillation audit\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'evidence' and body like '%[WEB_EVIDENCE]%' and body like '%collect_evidence%' and body not like '%<html>%'")" -ge 1 || { printf 'web-rag-flow: collect_evidence URL evidence missing or raw\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'web-rag-flow: collect_evidence turn was not confirmed\n' >&2; exit 1; }

printf 'web-rag-flow: ok work=%s db=%s\n' "$WORK" "$DB"
