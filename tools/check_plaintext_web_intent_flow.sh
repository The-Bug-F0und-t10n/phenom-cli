#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK_ROOT=${PHENOM_PLAINTEXT_WEB_INTENT_SMOKE_DIR:-/tmp/phenom-plaintext-web-intent-flow}
EXPECT=PHENOM_PLAINTEXT_WEB_OK
EXPECT_TEXT="Aurora Vela e uma pesquisadora ficticia do fixture local"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'plaintext-web-intent-flow: sqlite3 CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

run_backend() {
  backend=$1
  work="$WORK_ROOT/$backend"
  db="$work/.phenom-zig/phenom.db"
  session="plaintext-web-intent-$backend"
  port_file="$work/port"
  prompts_file="$work/prompts.log"

  rm -rf "$work"
  mkdir -p "$work"

  ZIG=${ZIG:-"$ROOT/bin/zig-x86_64-linux-0.16.0/zig"} sh "$ROOT/tools/start_scripted_backend.sh" plaintext_web "$port_file" "$prompts_file" &
  server_pid=$!
  trap 'kill "$server_pid" 2>/dev/null || true' EXIT

  i=0
  while [ ! -s "$port_file" ] && [ "$i" -lt 50 ]; do
    i=$((i + 1))
    sleep 0.1
  done
  test -s "$port_file" || { printf 'plaintext-web-intent-flow:%s: scripted backend did not start\n' "$backend" >&2; exit 1; }
  port=$(cat "$port_file")

  (
    cd "$work"
    PHENOM_WEB_SEARCH_URL="http://127.0.0.1:$port/search?q={query}" "$BIN" chat \
      --backend "$backend" \
      --host "127.0.0.1:$port" \
      --model scripted \
      --session "$session" \
      --prompt "quem e Aurora Vela?" \
      --max-tokens 900 \
      --thinking on \
      --expect-contains "$EXPECT_TEXT" \
      --fail-on-model-error \
      --no-color
  ) >"$work/out.txt" 2>"$work/err.txt"

  wait "$server_pid" 2>/dev/null || true
  trap - EXIT

  grep -q "$EXPECT" "$work/out.txt" || { printf 'plaintext-web-intent-flow:%s: missing final marker\n' "$backend" >&2; exit 1; }
  grep -q "$EXPECT_TEXT" "$work/out.txt" || { printf 'plaintext-web-intent-flow:%s: missing neutral answer text\n' "$backend" >&2; exit 1; }
  ! grep -q 'Preciso pesquisar na web' "$work/out.txt" || { printf 'plaintext-web-intent-flow:%s: plaintext web intent leaked to user\n' "$backend" >&2; exit 1; }
  ! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$work/out.txt" || { printf 'plaintext-web-intent-flow:%s: protocol error surfaced\n' "$backend" >&2; exit 1; }

  sql_count() {
    sqlite3 "$db" "select count(*) from events where session = '$session' and $1;"
  }

  test "$(sql_count "kind = 'tool_repair' and body = 'initial router repaired plaintext web intent'")" -eq 1 || { printf 'plaintext-web-intent-flow:%s: missing plaintext web repair audit\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=set_operational_contract%' and body like '%state=accepted%'")" -ge 1 || { printf 'plaintext-web-intent-flow:%s: repaired contract envelope was not accepted\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'contract_selected' and body like '%contract=search_web%' and body like '%query_bytes=%'")" -ge 1 || { printf 'plaintext-web-intent-flow:%s: search_web contract was not selected\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'contract_executor' and body like '%executor=web_search%'")" -ge 1 || { printf 'plaintext-web-intent-flow:%s: search_web contract did not execute web_search\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'tool_start' and body like 'web_search%' and body like '%Aurora%'")" -ge 1 || { printf 'plaintext-web-intent-flow:%s: web_search did not run with model-declared query\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 1 || { printf 'plaintext-web-intent-flow:%s: web distillation missing\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'evidence' and body like '%Aurora Vela e uma pesquisadora ficticia%' and body not like '%<html>%'")" -ge 1 || { printf 'plaintext-web-intent-flow:%s: distilled web evidence missing or raw\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'assistant_delta' and body like '%Preciso pesquisar na web%'")" -eq 0 || { printf 'plaintext-web-intent-flow:%s: discarded web intent was emitted\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'tool_rejected'")" -eq 0 || { printf 'plaintext-web-intent-flow:%s: unexpected rejected tool\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'turn_error'")" -eq 0 || { printf 'plaintext-web-intent-flow:%s: unexpected turn_error\n' "$backend" >&2; exit 1; }
  grep -q 'The controller will not infer query/terms from that prose' "$prompts_file" || { printf 'plaintext-web-intent-flow:%s: repair prompt did not forbid query inference\n' "$backend" >&2; exit 1; }
}

run_backend llamacpp
run_backend ollama

printf 'plaintext-web-intent-flow: ok work=%s\n' "$WORK_ROOT"
