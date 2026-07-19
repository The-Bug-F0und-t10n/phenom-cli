#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIG="${ZIG:-$ROOT/bin/zig-x86_64-linux-0.16.0/zig}"
CACHE="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-cache-test}"

run() {
  printf 'guardrail: %s\n' "$*"
  ZIG_GLOBAL_CACHE_DIR="$CACHE" "$@"
}

if [ -x "$ROOT/tools/check_alignment_tasks.sh" ]; then
  sh "$ROOT/tools/check_alignment_tasks.sh"
elif [ -x "$ROOT/../tools/check_alignment_tasks.sh" ]; then
  sh "$ROOT/../tools/check_alignment_tasks.sh"
elif [ -f "$ROOT/TASKS.md" ]; then
  printf 'guardrail: missing tools/check_alignment_tasks.sh\n' >&2
  exit 1
fi
run "$ZIG" test "$ROOT/src/contracts.zig"
run "$ZIG" test "$ROOT/src/context_profile.zig"
run "$ZIG" test "$ROOT/src/model_context.zig" -lc -lsqlite3
run "$ZIG" test "$ROOT/src/persistent_context.zig" -lc -lsqlite3
run "$ZIG" test "$ROOT/src/apply_patch_tool.zig" -lc -lsqlite3
run "$ZIG" test "$ROOT/src/collect_evidence.zig" -lc -lsqlite3
run "$ZIG" test "$ROOT/src/product_guardrails.zig" -lc -lsqlite3

printf 'guardrail: ok\n'
