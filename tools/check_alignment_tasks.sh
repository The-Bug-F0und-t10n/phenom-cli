#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASKS="$ROOT/TASKS.md"
ALIGN="$ROOT/alinhamento.md"

test -f "$TASKS" || { printf 'missing TASKS.md in current directory\n' >&2; exit 1; }
test -f "$ALIGN" || { printf 'missing alinhamento.md in current directory\n' >&2; exit 1; }

for task in T287 T290 T292 T293 T299; do
  awk -v task="## $task " '
    $0 ~ "^" task { found=1; section=1 }
    section && /^## T[0-9]+ / && $0 !~ "^" task { section=0 }
    section && /Alinhamento AUDIT\/TASKS\/phenom-cli-ts:/ { alignment=1 }
    section && /Criterio de aceite:/ { criteria=1 }
    END { exit !(found && alignment && criteria) }
  ' "$TASKS" || {
    printf 'task %s missing required alignment/criteria structure\n' "$task" >&2
    exit 1
  }
done

printf 'alignment-tasks: ok\n'
