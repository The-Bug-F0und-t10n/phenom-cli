#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_SIMPLE_GREETING_SMOKE_DIR:-/tmp/phenom-simple-greeting-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=simple-greeting-flow
EXPECT=PHENOM_SIMPLE_GREETING_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'simple-greeting-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'simple-greeting-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"
PORT_FILE="$WORK/port"
python3 - "$PORT_FILE" "$EXPECT" <<'PY' &
import json
import socket
import sys

port_file, expect = sys.argv[1:3]
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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-simple-greeting-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
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
    "O usuario apenas cumprimentou. Responder curto.\n</think>\n\n",
    f"Olá! Como posso ajudar?\n{expect}",
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
            send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4]}')
        elif method == "POST" and path == "/v1/chat/completions":
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
test -s "$PORT_FILE" || { printf 'simple-greeting-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "ola" \
    --max-tokens 128 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'simple-greeting-flow: missing final answer marker\n' >&2; exit 1; }
test "$(grep -c "$EXPECT" "$WORK/out.txt")" -eq 1 || { printf 'simple-greeting-flow: final answer emitted more than once\n' >&2; exit 1; }
! grep -q 'O usuario apenas cumprimentou' "$WORK/out.txt" || { printf 'simple-greeting-flow: hidden reasoning leaked to visible output\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'simple-greeting-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'answer_repair_done'")" -ge 1 || { printf 'simple-greeting-flow: missing think-only answer repair\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -eq 0 || { printf 'simple-greeting-flow: greeting unexpectedly collected evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence'")" -eq 0 || { printf 'simple-greeting-flow: greeting unexpectedly stored evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%collect_evidence%'")" -eq 0 || { printf 'simple-greeting-flow: greeting unexpectedly selected collect_evidence contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'simple-greeting-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'simple-greeting-flow: ok work=%s db=%s\n' "$WORK" "$DB"
