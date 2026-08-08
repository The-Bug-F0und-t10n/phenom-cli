#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK_ROOT=${PHENOM_PLAINTEXT_SESSION_SMOKE_DIR:-/tmp/phenom-plaintext-session-flow}

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'plaintext-session-flow: sqlite3 CLI is required\n' >&2
  exit 1
}

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

run_backend() {
  backend=$1
  work="$WORK_ROOT/$backend"
  db="$work/.phenom-zig/phenom.db"
  session="plaintext-session-$backend"
  port_file="$work/port"
  prompts_file="$work/prompts.log"

  rm -rf "$work"
  mkdir -p "$work"

  ZIG=${ZIG:-"$ROOT/bin/zig-x86_64-linux-0.16.0/zig"} sh "$ROOT/tools/start_scripted_backend.sh" plaintext_session "$port_file" "$prompts_file" &
  server_pid=$!
  trap 'kill "$server_pid" 2>/dev/null || true' EXIT

  i=0
  while [ ! -s "$port_file" ] && [ "$i" -lt 50 ]; do
    i=$((i + 1))
    sleep 0.1
  done
  test -s "$port_file" || { printf 'plaintext-session-flow:%s: scripted backend did not start\n' "$backend" >&2; exit 1; }
  port=$(cat "$port_file")

  (
    cd "$work"
    "$BIN" chat \
      --backend "$backend" \
      --host "127.0.0.1:$port" \
      --model scripted \
      --session "$session" \
      --prompt "Nesta sessao, registre a pesquisa anterior sobre R36S." \
      --max-tokens 700 \
      --thinking on \
      --expect-contains "R36S registrado nesta sessao" \
      --fail-on-model-error \
      --no-color
  ) >"$work/seed.out" 2>"$work/seed.err"

  (
    cd "$work"
    "$BIN" chat \
      --backend "$backend" \
      --host "127.0.0.1:$port" \
      --model scripted \
      --session "$session" \
      --prompt "o que um r36s" \
      --max-tokens 900 \
      --thinking on \
      --expect-contains "S1 recupera" \
      --fail-on-model-error \
      --no-color
  ) >"$work/recall.out" 2>"$work/recall.err"

  wait "$server_pid" 2>/dev/null || true
  trap - EXIT

  grep -q 'R36S registrado nesta sessao' "$work/seed.out" || { printf 'plaintext-session-flow:%s: missing seed answer\n' "$backend" >&2; exit 1; }
  grep -q 'S1 recupera' "$work/recall.out" || { printf 'plaintext-session-flow:%s: missing recall answer\n' "$backend" >&2; exit 1; }
  ! grep -q 'Vou usar a ferramenta search_session' "$work/recall.out" || { printf 'plaintext-session-flow:%s: plaintext tool announcement leaked to user\n' "$backend" >&2; exit 1; }
  ! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$work/recall.out" || { printf 'plaintext-session-flow:%s: protocol error surfaced\n' "$backend" >&2; exit 1; }

  sql_count() {
    sqlite3 "$db" "select count(*) from events where session = '$session' and $1;"
  }

  test "$(sql_count "kind = 'tool_repair' and body = 'plaintext search_session intent normalized'")" -eq 1 || { printf 'plaintext-session-flow:%s: missing plaintext normalization audit\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'tool_start' and body like 'search_session%'")" -ge 1 || { printf 'plaintext-session-flow:%s: search_session did not execute\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'session_context' and body like '%PHENOM_R36S_FACT%'")" -ge 1 || { printf 'plaintext-session-flow:%s: session_context did not recover R36S fact\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'assistant_delta' and body like '%PHENOM_R36S_SEEDED%'")" -ge 1 || { printf 'plaintext-session-flow:%s: seed marker missing from assistant event\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'assistant_delta' and body like '%PHENOM_R36S_RECALL_OK%'")" -ge 1 || { printf 'plaintext-session-flow:%s: recall marker missing from assistant event\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'assistant_delta' and body like '%Vou usar a ferramenta search_session%'")" -eq 0 || { printf 'plaintext-session-flow:%s: discarded plaintext announcement was emitted\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'tool_repair' and body like '%synthetic search_session%'")" -eq 0 || { printf 'plaintext-session-flow:%s: synthetic session search was used\n' "$backend" >&2; exit 1; }
  test "$(sql_count "kind = 'turn_error'")" -eq 0 || { printf 'plaintext-session-flow:%s: unexpected turn_error\n' "$backend" >&2; exit 1; }
}

run_backend llamacpp
run_backend ollama

printf 'plaintext-session-flow: ok work=%s\n' "$WORK_ROOT"
