#!/bin/sh
set -eu

template=$1
target=$2
dir=$(dirname "$target")

mkdir -p "$dir"
if [ ! -f "$target" ]; then
  install -m 644 "$template" "$target"
  exit 0
fi

tmp="${target}.tmp.$$"
trap 'rm -f "$tmp"' EXIT
awk '
function trim(s) {
  sub(/^[ \t\r]+/, "", s)
  sub(/[ \t\r]+$/, "", s)
  return s
}

function active_key(line, cleaned, eq, key) {
  cleaned = trim(line)
  if (cleaned == "" || cleaned ~ /^#/) return ""
  eq = index(cleaned, "=")
  if (eq == 0) return ""
  key = trim(substr(cleaned, 1, eq - 1))
  if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/) return key
  return ""
}

FNR == NR {
  key = active_key($0)
  if (key != "") {
    user_value[key] = $0
    if (!(key in user_seen)) {
      user_seen[key] = 1
      user_order[++user_count] = key
    }
  }
  next
}

{
  key = active_key($0)
  if (key != "") {
    template_seen[key] = 1
    if (key in user_value) {
      print user_value[key]
      next
    }
  }
  print
}

END {
  wrote_header = 0
  for (i = 1; i <= user_count; i++) {
    key = user_order[i]
    if (!(key in template_seen)) {
      if (!wrote_header) {
        print ""
        print "# User custom values preserved from the previous config."
        wrote_header = 1
      }
      print user_value[key]
    }
  }
}
' "$target" "$template" > "$tmp"

if cmp -s "$tmp" "$target"; then
  exit 0
fi

mv "$tmp" "$target"
trap - EXIT
