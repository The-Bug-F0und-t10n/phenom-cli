#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_AGENT_PATCH_SMOKE_DIR:-/tmp/phenom-agent-patch-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=agent-patch-flow
EXPECT=PHENOM_AGENT_PATCH_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'agent-patch-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'agent-patch-flow: python3 is required for scripted backend\n' >&2
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
import re
import socket
import sys

port_file, log_file = sys.argv[1], sys.argv[2]
responses = [
    """preciso selecionar contrato de mutacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>true</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>editar arquivo com evidencia local</parameter></function></tool_call>""",
    """preciso ler o arquivo antes de editar\n</think>\n\n<tool_call><function=collect_evidence><parameter=intent>localizar funcao de soma quebrada</parameter><parameter=path>src/math.zig</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>20</parameter></function></tool_call>""",
    None,
    """patch aplicado, agora responder visivelmente\n</think>\n\nPatch aplicado em src/math.zig. PHENOM_AGENT_PATCH_OK""",
]
completion_count = 0

def recv_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None, None, b""
        data += chunk
    head, body = data.split(b"\r\n\r\n", 1)
    headers = head.decode("iso-8859-1").split("\r\n")
    request_line = headers[0]
    length = 0
    for line in headers[1:]:
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    while len(body) < length:
        body += conn.recv(length - len(body))
    return request_line, dict(), body[:length]

def send(conn, status, content_type, body):
    raw = body.encode("utf-8")
    conn.sendall(
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: llama.cpp\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

def prompt_from_body(body):
    try:
        payload = json.loads(body.decode("utf-8"))
        return payload.get("prompt") or "\n".join(message.get("content", "") for message in payload.get("messages", []))
    except Exception:
        return body.decode("utf-8", "replace")

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
            request_line, _, body = recv_request(conn)
            if request_line is None:
                continue
            parts = request_line.split()
            method = parts[0]
            path = parts[1]
            log.write(f"{method} {path}\n")
            log.flush()
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":8192}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4]}')
            elif method == "POST" and path == "/v1/chat/completions":
                prompt = prompt_from_body(body)
                if completion_count == 2:
                    match = re.search(r"ctx_[A-Za-z0-9_]+", prompt)
                    if not match:
                        send(conn, "500 Internal Server Error", "text/plain", "missing context id")
                        continue
                    text = f"""micro-contexto fresco encontrado\n</think>\n\n<tool_call><function=apply_patch><parameter=operation>edit</parameter><parameter=path>src/math.zig</parameter><parameter=contextId>{match.group(0)}</parameter><parameter=search>return a - b;</parameter><parameter=replace>return a + b;</parameter></function></tool_call>"""
                elif completion_count < len(responses):
                    text = responses[completion_count]
                else:
                    text = responses[-1]
                completion_count += 1
                send(conn, "200 OK", "text/event-stream", completion_payload(text))
                if completion_count >= 4:
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
test -s "$PORT_FILE" || { printf 'agent-patch-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "A soma esta errada. Corrija o bug no projeto." \
    --expect-contains "$EXPECT" \
    --show-expect-status \
    --fail-on-model-error \
    --no-color
) >"$WORK/agent.out" 2>"$WORK/agent.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q 'return a + b;' "$WORK/src/math.zig" || {
  printf 'agent-patch-flow: patch did not update src/math.zig\n' >&2
  exit 1
}
! grep -q 'return a - b;' "$WORK/src/math.zig" || {
  printf 'agent-patch-flow: stale buggy code remains\n' >&2
  exit 1
}
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/agent.out" || {
  printf 'agent-patch-flow: unexpected model protocol error in transcript\n' >&2
  exit 1
}
! grep -q 'required follow-up tool_call missing' "$WORK/agent.out" || {
  printf 'agent-patch-flow: required follow-up tool call missing surfaced to user\n' >&2
  exit 1
}

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}
focus_count() {
  sqlite3 "$DB" "select count(*) from session_focus where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_checkpoint'")" -ge 1 || { printf 'agent-patch-flow: missing checkpoint event\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=mutate_file%'")" -ge 1 || { printf 'agent-patch-flow: missing mutate_file contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 1 || { printf 'agent-patch-flow: missing collect_evidence tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'apply_patch%'")" -ge 1 || { printf 'agent-patch-flow: missing apply_patch tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'patch_result' and body like '%status=applied%'")" -ge 1 || { printf 'agent-patch-flow: missing applied patch result\n' >&2; exit 1; }
test "$(sql_count "kind = 'expectation_passed' and body = '$EXPECT'")" -ge 1 || { printf 'agent-patch-flow: missing expectation_passed\n' >&2; exit 1; }
test "$(focus_count "user_intent = 'turn_memory' and useful_facts like '%source=turn_memory_v1%'")" -ge 1 || { printf 'agent-patch-flow: missing completed turn memory\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%'")" -ge 1 || { printf 'agent-patch-flow: missing successful turn_done\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_error' and body like '%class=model_protocol%'")" -eq 0 || { printf 'agent-patch-flow: unexpected model_protocol turn_error\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_loop_stop' and body like '%required follow-up tool call missing%'")" -eq 0 || { printf 'agent-patch-flow: unexpected required follow-up stop\n' >&2; exit 1; }
test "$(sql_count "kind = 'finalization_blocked'")" -eq 0 || { printf 'agent-patch-flow: unexpected finalization_blocked\n' >&2; exit 1; }

printf 'agent-patch-flow: ok work=%s db=%s\n' "$WORK" "$DB"
