#!/usr/bin/env sh
set -eu

BIN="${1:-zig-out/bin/phenom}"
case "$BIN" in
  /*) ;;
  *) BIN="$(pwd)/$BIN" ;;
esac
WORK="${PHENOM_LENGTH_STOP_SMOKE_DIR:-/tmp/phenom-length-stop-flow-smoke}"
PORT_FILE="$WORK/port"
OUT_FILE="$WORK/out.txt"
ERR_FILE="$WORK/err.txt"
SESSION="length-stop-flow"

rm -rf "$WORK"
mkdir -p "$WORK"

python3 - "$PORT_FILE" <<'PY' &
import json
import socket
import sys

port_file = sys.argv[1]
completion_count = 0

def recv_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None, b""
        data += chunk
    head, body = data.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.decode("iso-8859-1").split("\r\n")[1:]:
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    while len(body) < length:
        body += conn.recv(length - len(body))
    return head.decode("iso-8859-1").split("\r\n", 1)[0], body[:length]

def send(conn, status, content_type, body):
    raw = body.encode("utf-8")
    conn.sendall(
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-length-stop-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text, stopped_limit=False):
    payload = {"content": text, "stop": True}
    if stopped_limit:
        payload["stopped_limit"] = True
    return "data: " + json.dumps(payload, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(16)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(sock.getsockname()[1]))

responses = [
    completion_payload("raciocinio\n</think>\nA estimativa exige dimensionamento por consumo.\n\n## 1. Sistema", True),
    completion_payload(" residencial realista\nUse kWh/mes, baterias e inversor dimensionados. Resposta completa."),
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
            send(conn, "200 OK", "text/event-stream", text)
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
test -s "$PORT_FILE" || { printf 'length-stop-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model fake \
    --session "$SESSION" \
    --prompt "estime custo de casa autonoma off-grid" \
    --max-tokens 64 \
    --no-color \
    --expect-contains "Resposta completa."
) >"$OUT_FILE" 2>"$ERR_FILE" || {
  cat "$OUT_FILE" >&2
  cat "$ERR_FILE" >&2
  exit 1
}

grep -q "## 1. Sistema" "$OUT_FILE" || {
  printf 'length-stop-flow: missing partial answer before continuation\n' >&2
  cat "$OUT_FILE" >&2
  exit 1
}
grep -q "residencial realista" "$OUT_FILE" || {
  printf 'length-stop-flow: continuation did not append expected text\n' >&2
  cat "$OUT_FILE" >&2
  exit 1
}

DB="$WORK/.phenom-zig/phenom.db"
sql_count() {
  sqlite3 "$DB" "select count(*) from events where $1;"
}

test "$(sql_count "kind = 'answer_repair' and body = 'server length stop with partial visible answer'")" -ge 1 || {
  printf 'length-stop-flow: missing length answer_repair event\n' >&2
  exit 1
}
test "$(sql_count "kind = 'answer_repair_done' and body = 'server length continuation emitted visible answer'")" -ge 1 || {
  printf 'length-stop-flow: missing length answer_repair_done event\n' >&2
  exit 1
}
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%'")" -ge 1 || {
  printf 'length-stop-flow: turn was not completed ok\n' >&2
  exit 1
}

printf 'length-stop-flow: ok work=%s db=%s\n' "$WORK" "$DB"
