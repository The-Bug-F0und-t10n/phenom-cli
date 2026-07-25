#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
PROMPTS=${PHENOM_ACCEPTANCE_PROMPTS:?set PHENOM_ACCEPTANCE_PROMPTS to a user-provided prompt file}
WORK=${PHENOM_ACCEPTANCE_WORK_DIR:-/tmp/phenom-user-acceptance}
SESSION=${PHENOM_ACCEPTANCE_SESSION:-user-acceptance-flow}
BACKEND=${PHENOM_ACCEPTANCE_BACKEND:-llamacpp}
HOST=${PHENOM_ACCEPTANCE_HOST:?set PHENOM_ACCEPTANCE_HOST}
MODEL=${PHENOM_ACCEPTANCE_MODEL:?set PHENOM_ACCEPTANCE_MODEL}
REQUIRE_WEB=${PHENOM_ACCEPTANCE_REQUIRE_WEB:-0}
REQUIRE_WORKSPACE=${PHENOM_ACCEPTANCE_REQUIRE_WORKSPACE:-0}
REQUIRE_DIALOGUE=${PHENOM_ACCEPTANCE_REQUIRE_DIALOGUE:-0}
DB="$WORK/.phenom-zig/phenom.db"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'user-acceptance: sqlite3 CLI is required\n' >&2
  exit 1
}
test -s "$PROMPTS" || {
  printf 'user-acceptance: prompt file is empty or missing: %s\n' "$PROMPTS" >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

turn=0
while IFS= read -r prompt || [ -n "$prompt" ]; do
  case "$prompt" in
    ''|\#*) continue ;;
  esac
  turn=$((turn + 1))
  (
    cd "$WORK"
    "$BIN" chat \
      --backend "$BACKEND" \
      --host "$HOST" \
      --model "$MODEL" \
      --session "$SESSION" \
      --prompt "$prompt" \
      --max-tokens "${PHENOM_ACCEPTANCE_MAX_TOKENS:-768}" \
      --thinking "${PHENOM_ACCEPTANCE_THINKING:-on}" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/turn-$turn.out" 2>"$WORK/turn-$turn.err"
done <"$PROMPTS"

test "$turn" -gt 0 || {
  printf 'user-acceptance: no prompts executed\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

turn_done=$(sql_count "kind = 'turn_done' and body like 'status=ok%'")
test "$turn_done" -eq "$turn" || {
  printf 'user-acceptance: expected %s ok turns, got %s\n' "$turn" "$turn_done" >&2
  exit 1
}

if [ "$REQUIRE_WEB" = "1" ]; then
  test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 1 || {
    printf 'user-acceptance: expected at least one model-called web_search\n' >&2
    exit 1
  }
  test "$(sql_count "kind = 'evidence' and body like '%[WEB_EVIDENCE]%'")" -ge 1 || {
    printf 'user-acceptance: expected distilled WEB_EVIDENCE\n' >&2
    exit 1
  }
fi

if [ "$REQUIRE_WORKSPACE" = "1" ]; then
  test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || {
    printf 'user-acceptance: expected at least one model-called collect_evidence\n' >&2
    exit 1
  }
fi

if [ "$REQUIRE_DIALOGUE" = "1" ]; then
  test "$(sql_count "kind = 'model_context' and body like '%[RECENT_DIALOGUE]%'")" -ge 1 || {
    printf 'user-acceptance: expected RECENT_DIALOGUE in later model context\n' >&2
    exit 1
  }
fi

test "$(sql_count "kind = 'tool_repair' and body like '%synthetic collect_evidence%'")" -eq 0 || {
  printf 'user-acceptance: synthetic collect_evidence was used\n' >&2
  exit 1
}
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic search_session%'")" -eq 0 || {
  printf 'user-acceptance: synthetic search_session was used\n' >&2
  exit 1
}

printf 'user-acceptance: ok turns=%s work=%s db=%s\n' "$turn" "$WORK" "$DB"
