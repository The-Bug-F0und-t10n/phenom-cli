#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_THINK_ONLY_SMOKE_DIR:-/tmp/phenom-think-only-finalization-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=think-only-finalization
EXPECT=CMUS_HISTORY_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'think-only-finalization: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'think-only-finalization: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
python3 - "$PORT_FILE" "$PROMPTS_FILE" <<'PY' &
import json
import socket
import sys

port_file, prompts_file = sys.argv[1], sys.argv[2]
responses = [
    "<think>The user says there is no cmus history in .config. I need to explain cmus state files and avoid claiming a history file exists.</think>",
    "Voce esta certo: cmus nao grava um historico de reproducao em ~/.config por padrao.\nCMUS_HISTORY_OK",
]
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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: llama.cpp\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(16)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(sock.getsockname()[1]))

with open(prompts_file, "w", encoding="utf-8") as prompts:
    while True:
        conn, _ = sock.accept()
        with conn:
            request_line, body = recv_request(conn)
            if request_line is None:
                continue
            parts = request_line.split()
            method = parts[0]
            path = parts[1]
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":8192}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[' + ','.join(['123456'] * 2048) + ']}')
            elif method == "POST" and path == "/v1/chat/completions":
                payload = json.loads(body.decode("utf-8"))
                prompts.write(f"---REQUEST {completion_count + 1}---\n")
                prompts.write(json.dumps(payload, ensure_ascii=False))
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
test -s "$PORT_FILE" || { printf 'think-only-finalization: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "analise: nao existe nenhum history no cmus em .config" \
    --max-tokens 64 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --show-expect-status \
    --fail-on-model-error \
    --no-color
) >"$WORK/agent.out" 2>"$WORK/agent.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/agent.out" || {
  printf 'think-only-finalization: final visible answer missing\n' >&2
  exit 1
}
! grep -q '\[MODEL_EMPTY_ANSWER\]' "$WORK/agent.out" || {
  printf 'think-only-finalization: empty answer diagnostic surfaced despite repair\n' >&2
  exit 1
}
! grep -q '\[MODEL_STOP\]' "$WORK/agent.out" || {
  printf 'think-only-finalization: stop diagnostic surfaced despite repair\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/agent.out" || {
  printf 'think-only-finalization: protocol error surfaced to user\n' >&2
  exit 1
}
grep -Eq '"max_tokens"[[:space:]]*:[[:space:]]*64' "$PROMPTS_FILE" || {
  printf 'think-only-finalization: llama.cpp request did not receive max token budget\n' >&2
  exit 1
}
grep -Eq '"enable_thinking"[[:space:]]*:[[:space:]]*true' "$PROMPTS_FILE" || {
  printf 'think-only-finalization: initial native thinking mode was not sent\n' >&2
  exit 1
}
grep -Eq '"enable_thinking"[[:space:]]*:[[:space:]]*false' "$PROMPTS_FILE" || {
  printf 'think-only-finalization: repair did not disable native thinking mode\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'assistant_thinking_delta' and body like '%cmus history%'")" -ge 1 || { printf 'think-only-finalization: missing thinking audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'model_context_budget' and body like '%tokenizer=backend%' and body like '%context_limit_tokens=8192%' and body like '%context_used_percent=%'")" -ge 1 || { printf 'think-only-finalization: context budget did not use backend tokenizer/window\n' >&2; exit 1; }
test "$(sql_count "kind = 'answer_repair' and body like '%think-only generation%'")" -ge 1 || { printf 'think-only-finalization: missing answer_repair audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'answer_repair_done'")" -ge 1 || { printf 'think-only-finalization: missing answer_repair_done audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'assistant_delta' and body like '%$EXPECT%'")" -ge 1 || { printf 'think-only-finalization: missing final assistant_delta\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%class=model_protocol%'")" -eq 0 || { printf 'think-only-finalization: repaired flow should not record model_protocol turn_error\n' >&2; exit 1; }
test "$(sql_count "kind = 'expectation_passed' and body = '$EXPECT'")" -ge 1 || { printf 'think-only-finalization: missing expectation_passed\n' >&2; exit 1; }

printf 'think-only-finalization: ok work=%s db=%s\n' "$WORK" "$DB"
