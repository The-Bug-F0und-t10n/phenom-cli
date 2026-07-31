#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_REQUIRED_TOOL_REPAIR_SMOKE_DIR:-/tmp/phenom-required-tool-repair-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=required-tool-repair-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'required-tool-repair-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'required-tool-repair-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/src"
cat >"$WORK/src/math.zig" <<'ZIG'
pub fn add(a: i32, b: i32) i32 {
    return a - b;
}
ZIG

PORT_FILE="$WORK/port"
LOG_FILE="$WORK/backend.log"
python3 - "$PORT_FILE" "$LOG_FILE" <<'PY' &
import json
import socket
import sys

port_file, log_file = sys.argv[1], sys.argv[2]
responses = [
    "selecionar contrato de mutacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>true</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>editar arquivo com evidencia local</parameter></function></tool_call>",
    "ler arquivo antes de editar\n</think>\n\n<tool_call><function=collect_evidence><parameter=intent>localizar funcao de soma quebrada</parameter><parameter=path>src/math.zig</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>20</parameter></function></tool_call>",
    "vou aplicar o patch agora, mas esta resposta nao tem chamada de ferramenta\n</think>\n\nPreciso aplicar o patch.",
    "segunda tentativa ainda falha como um modelo real desalinhado\n</think>\n\nNao consigo chamar a ferramenta agora.",
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

with open(log_file, "w", encoding="utf-8") as log:
    while True:
        conn, _ = sock.accept()
        with conn:
            request_line, body = recv_request(conn)
            if request_line is None:
                continue
            parts = request_line.split()
            method = parts[0]
            path = parts[1]
            log.write(f"{method} {path} body_bytes={len(body)}\n")
            log.flush()
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":8192}')
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
test -s "$PORT_FILE" || { printf 'required-tool-repair-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "A soma esta errada. Corrija o bug no projeto." \
    --max-tokens 900 \
    --fail-on-model-error \
    --no-color
) >"$WORK/agent.out" 2>"$WORK/agent.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

! grep -q 'return a + b;' "$WORK/src/math.zig" || {
  printf 'required-tool-repair-flow: patch was applied even though apply_patch was never emitted\n' >&2
  exit 1
}
grep -q 'return a - b;' "$WORK/src/math.zig" || {
  printf 'required-tool-repair-flow: original file unexpectedly changed\n' >&2
  exit 1
}
grep -q '\[MODEL_FINALIZATION_BLOCKED\]' "$WORK/agent.out" || {
  printf 'required-tool-repair-flow: missing controlled finalization block in transcript\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/agent.out" || {
  printf 'required-tool-repair-flow: protocol error surfaced to user\n' >&2
  exit 1
}
! grep -q 'required follow-up tool_call missing' "$WORK/agent.out" || {
  printf 'required-tool-repair-flow: internal repair detail surfaced to user\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'contract_selected' and body like '%contract=mutate_file%'")" -ge 1 || { printf 'required-tool-repair-flow: missing mutate_file contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || { printf 'required-tool-repair-flow: missing collect_evidence tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'apply_patch%'")" -eq 0 || { printf 'required-tool-repair-flow: apply_patch should not have run\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body = 'required follow-up tool call missing'")" -ge 1 || { printf 'required-tool-repair-flow: missing first repair audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_loop_stop' and body like '%required follow-up tool call missing after repair%'")" -ge 1 || { printf 'required-tool-repair-flow: missing controlled stop audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%class=model_protocol%source=required_tool_repair%'")" -ge 1 || { printf 'required-tool-repair-flow: missing model_protocol audit error\n' >&2; exit 1; }
test "$(sql_count "kind = 'assistant_delta' and body like '%[MODEL_FINALIZATION_BLOCKED]%'")" -ge 1 || { printf 'required-tool-repair-flow: missing visible controlled assistant event\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=uncertain%turn_error=true%low_confidence=true%'")" -ge 1 || { printf 'required-tool-repair-flow: missing uncertain turn_done quality\n' >&2; exit 1; }

focus_count() {
  sqlite3 "$DB" "select count(*) from session_focus where session = '$SESSION' and $1;"
}

test "$(focus_count "user_intent = 'turn_memory' and quality = 'uncertain' and flags like '%turn_error=true%'")" -ge 1 || { printf 'required-tool-repair-flow: blocked turn memory should be uncertain\n' >&2; exit 1; }

printf 'required-tool-repair-flow: ok work=%s db=%s\n' "$WORK" "$DB"
