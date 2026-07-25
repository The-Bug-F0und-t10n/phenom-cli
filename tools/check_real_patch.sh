#!/usr/bin/env sh
set -eu

BIN=$1
BACKEND=${2:-llamacpp}
HOST=${3:-127.0.0.1:11434}
MODEL=${4:-phenom:latest}
SESSION=${5:-real-patch-smoke}

case "$SESSION" in
  *"'"*) printf 'real-patch: session must not contain single quotes\n' >&2; exit 1 ;;
esac

BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
WORKDIR=$(mktemp -d /tmp/phenom-real-patch-XXXXXX)
trap 'status=$?; if [ "$status" -eq 0 ]; then rm -rf "$WORKDIR"; else printf "real-patch: failed; kept workdir=%s\n" "$WORKDIR" >&2; fi' EXIT

mkdir -p "$WORKDIR/src"
cat > "$WORKDIR/src/math.zig" <<'EOF'
pub fn add(a: i32, b: i32) i32 {
    return a - b;
}
EOF

cd "$WORKDIR"
"$BIN_ABS" chat \
  --backend "$BACKEND" \
  --host "$HOST" \
  --model "$MODEL" \
  --session "$SESSION" \
  --prompt 'Neste projeto em cwd existe src/math.zig. A funcao add esta errada: ela deve somar, mas retorna subtracao. Corrija usando collect_evidence e apply_patch com contextId fresco, valide com validate_syntax e responda contendo exatamente PHENOM_REAL_PATCH_OK.' \
  --max-tokens 2200 \
  --expect-contains PHENOM_REAL_PATCH_OK \
  --show-expect-status \
  --fail-on-model-error \
  --no-color

grep -q 'return a + b;' src/math.zig || {
  printf 'real-patch: src/math.zig was not patched to addition\n' >&2
  exit 1
}

DB=.phenom-zig/phenom.db
test -f "$DB" || { printf 'real-patch: missing sqlite audit db\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'contract_selected' and body like '%contract=mutate_file%'")" -ge 1 || { printf 'real-patch: missing mutate_file contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || { printf 'real-patch: missing collect_evidence tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'apply_patch%'")" -ge 1 || { printf 'real-patch: missing apply_patch tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'validation'")" -ge 1 || { printf 'real-patch: missing validation evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'expectation_passed' and body = 'PHENOM_REAL_PATCH_OK'")" -ge 1 || { printf 'real-patch: missing expectation_passed audit\n' >&2; exit 1; }

printf 'real-patch: ok session=%s workdir=%s\n' "$SESSION" "$WORKDIR"
