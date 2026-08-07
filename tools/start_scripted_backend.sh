#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${PHENOM_SCRIPTED_BACKEND_BIN:-}" ]; then
  exec "$PHENOM_SCRIPTED_BACKEND_BIN" "$@"
fi

BACKEND_BIN=${PHENOM_SCRIPTED_BACKEND_CACHE_BIN:-/tmp/phenom_scripted_backend}
"${ZIG:-zig}" build-exe "$ROOT/tools/scripted_backend.zig" -lc -femit-bin="$BACKEND_BIN"
exec "$BACKEND_BIN" "$@"
