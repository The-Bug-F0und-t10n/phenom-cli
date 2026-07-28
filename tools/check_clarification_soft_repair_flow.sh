#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$PWD/$BIN" ;;
esac
WORK=${PHENOM_CLARIFICATION_SOFT_REPAIR_SMOKE_DIR:-/tmp/phenom-clarification-soft-repair-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=clarification-soft-repair-flow
EXPECT=PHENOM_CLARIFICATION_SOFT_REPAIR_OK
EXPECT_LINE="A resposta inicial era prematura. Usei exploracao somente leitura do workspace e agora posso responder com contexto. $EXPECT"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'clarification-soft-repair-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'clarification-soft-repair-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"
cat > "$WORK/README.md" <<'EOF'
# Phenom Test Workspace

Este workspace exercita comandos locais, tool loop e reparo suave de clarificacao.
EOF

PORT_FILE="$WORK/port"
python3 - "$PORT_FILE" "$EXPECT_LINE" <<'PY' &
import json
import socket
import sys

port_file, expect_line = sys.argv[1:3]
completion_count = 0

def recv_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None, b""
        data += chunk
    head, body = data.split(b"\r\n\r\n", 1)
    headers = head.decode("iso-8859-1").split("\r\n")
    length = 0
    for line in headers[1:]:
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    while len(body) < length:
        body += conn.recv(length - len(body))
    return headers[0], body[:length]

def send(conn, status, content_type, body):
    raw = body.encode("utf-8")
    conn.sendall(
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-clarification-soft-repair-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(16)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(sock.getsockname()[1]))

responses = [
    "raciocinio inicial\n</think>\nDesculpe pela confusao. O que voce gostaria de fazer com /create_custom_prompt?",
    "reparo leve\n</think>\n<tool_call>\n<function=set_operational_contract>\n<parameter=contract>collect_evidence</parameter>\n<parameter=reason>reduzir incerteza com contexto local de comandos e agente</parameter>\n</function>\n</tool_call>",
    "contrato ativo\n</think>\n<tool_call>\n<function=collect_evidence>\n<parameter=stage>overview</parameter>\n<parameter=intent>entender comandos locais e comportamento do agente</parameter>\n<parameter=terms>create_custom_prompt comandos locais Phenom.md tool loop</parameter>\n</function>\n</tool_call>",
    f"sintese final\n</think>\n{expect_line}",
]
while True:
    conn, _ = sock.accept()
    with conn:
        request_line, body = recv_request(conn)
        if request_line is None:
            continue
        method, path, *_ = request_line.split()
        if method == "GET" and path == "/props":
            send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
        elif method == "POST" and path == "/tokenize":
            send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4,5,6,7,8]}')
        elif method == "POST" and path == "/completion":
            text = responses[completion_count] if completion_count < len(responses) else responses[-1]
            completion_count += 1
            send(conn, "200 OK", "text/event-stream", completion_payload(text))
            if completion_count >= len(responses):
                break
        else:
            send(conn, "404 Not Found", "text/plain", "not found")
sock.close()
PY
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'clarification-soft-repair-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "modelo nao entende /create_custom_prompt e responde como se nao soubesse do agente" \
    --max-tokens 256 \
    --thinking on \
    --expect-contains "$EXPECT_LINE" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'clarification-soft-repair-flow: missing repaired answer marker\n' >&2; exit 1; }
! grep -q 'O que voce gostaria de fazer' "$WORK/out.txt" || { printf 'clarification-soft-repair-flow: premature clarification surfaced\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'clarification-soft-repair-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'answer_repair' and body = 'clarification soft repair'")" -ge 1 || { printf 'clarification-soft-repair-flow: missing soft repair audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=collect_evidence%'")" -ge 1 || { printf 'clarification-soft-repair-flow: collect_evidence contract not selected\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || { printf 'clarification-soft-repair-flow: collect_evidence did not run\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%Phenom Test Workspace%'")" -ge 1 || { printf 'clarification-soft-repair-flow: workspace evidence missing\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'clarification-soft-repair-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'clarification-soft-repair-flow: ok work=%s db=%s\n' "$WORK" "$DB"
