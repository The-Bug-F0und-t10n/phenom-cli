#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$PWD/$BIN" ;;
esac
WORK=${PHENOM_MD_PROMPT_SMOKE_DIR:-$(mktemp -d /tmp/phenom-md-prompt-flow.XXXXXX)}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=phenom-md-prompt-flow
EXPECT=PHENOM_MD_PROMPT_USED_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'phenom-md-prompt-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'phenom-md-prompt-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

mkdir -p "$WORK"
PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
python3 - "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT" <<'PY' &
import json
import socket
import sys

port_file, prompts_file, expect = sys.argv[1:4]
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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-md-prompt-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(32)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(sock.getsockname()[1]))

responses = [
    "# Phenom\n\nCUSTOM_PROJECT_RULE: keep durable project rules from Phenom.md.",
    f"Phenom.md carregado no system prompt. {expect}",
]

with open(prompts_file, "w", encoding="utf-8") as prompts:
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
                payload = json.loads(body.decode("utf-8"))
                prompts.write(f"---REQUEST {completion_count + 1}---\n")
                prompts.write(payload.get("prompt", ""))
                prompts.write("\n")
                prompts.flush()
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
test -s "$PORT_FILE" || { printf 'phenom-md-prompt-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

cat > "$WORK/README.md" <<'EOF'
# Projeto Teste

Este workspace testa prompt permanente Phenom.md.
EOF

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "/create_custom_prompt" \
    --max-tokens 512 \
    --thinking off \
    --fail-on-model-error \
    --no-color

  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "ola" \
    --max-tokens 128 \
    --thinking off \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q 'CUSTOM_PROJECT_RULE' "$WORK/Phenom.md" || { printf 'phenom-md-prompt-flow: Phenom.md was not generated from model output\n' >&2; exit 1; }
grep -q "$EXPECT" "$WORK/out.txt" || { printf 'phenom-md-prompt-flow: custom prompt chat did not finish\n' >&2; exit 1; }

python3 - "$PROMPTS_FILE" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
parts = text.split("---REQUEST ")
requests = {}
for part in parts[1:]:
    header, _, body = part.partition("---\n")
    requests[int(header)] = body

first = requests.get(1, "")
second = requests.get(2, "")
if "[CREATE_PHENOM_MD]" not in first:
    raise SystemExit("phenom-md-prompt-flow: generator request did not receive create prompt")
if "The model decides when contracts/tools are needed" not in first:
    raise SystemExit("phenom-md-prompt-flow: generator request did not use stock prompt fallback")
if "CUSTOM_PROJECT_RULE" not in second:
    raise SystemExit("phenom-md-prompt-flow: second request did not load Phenom.md")
if "The model decides when contracts/tools are needed" in second:
    raise SystemExit("phenom-md-prompt-flow: custom Phenom.md request still used stock prompt")
PY

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'custom_prompt_created' and body like '%path=Phenom.md%'")" -ge 1 || { printf 'phenom-md-prompt-flow: missing custom_prompt_created audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%stage=overview%create_custom_prompt%'")" -ge 1 || { printf 'phenom-md-prompt-flow: create_custom_prompt did not collect project overview\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_event' and body like '%workspace_overview%'")" -ge 1 || { printf 'phenom-md-prompt-flow: overview collection did not use workspace_overview\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'phenom-md-prompt-flow: final turn was not confirmed\n' >&2; exit 1; }

printf 'phenom-md-prompt-flow: ok work=%s db=%s\n' "$WORK" "$DB"
