#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_GIT_EVIDENCE_SMOKE_DIR:-/tmp/phenom-git-evidence-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=git-evidence-reflog-flow
EXPECT=PHENOM_GIT_REFLOG_OK

command -v git >/dev/null 2>&1 || {
  printf 'git-evidence-flow: git is required\n' >&2
  exit 1
}
command -v sqlite3 >/dev/null 2>&1 || {
  printf 'git-evidence-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'git-evidence-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"
(
  cd "$WORK"
  git init -q
  git config user.email phenom@example.invalid
  git config user.name Phenom
  printf 'initial\n' > collect_evidence.txt
  git add collect_evidence.txt
  git commit -q -m 'initial collect_evidence baseline'
  printf 'web_distillation deleted commit marker\n' >> collect_evidence.txt
  git add collect_evidence.txt
  git commit -q -m 'deleted commit touching collect_evidence web_distillation'
  git reset --hard HEAD~1 >/dev/null
)

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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-git-evidence-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(16)
port = sock.getsockname()[1]
responses = [
    "selecionar contrato para evidencia git\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>investigar historico git via collect_evidence</parameter></function></tool_call>",
    "coletar reflog sem trocar para busca textual\n</think>\n\n<tool_call><function=collect_evidence><parameter=strategyId>collect_git_reflog</parameter><parameter=intent>recover deleted commit touching collect_evidence</parameter><parameter=terms>collect_evidence web_distillation</parameter><parameter=budget_bytes>12000</parameter></function></tool_call>",
    f"responder com evidencia git\n</think>\n\nE1 contem GIT_REFLOG e mostra o commit removido 'deleted commit touching collect_evidence web_distillation'. {expect}",
]
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(port))

with open(prompts_file, "w", encoding="utf-8") as prompts:
    while True:
        conn, _ = sock.accept()
        with conn:
            request_line, body = recv_request(conn)
            if request_line is None:
                continue
            method, path, *_ = request_line.split()
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":8192}')
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
test -s "$PORT_FILE" || { printf 'git-evidence-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "Use collect_evidence source=git strategy=reflog para recuperar o commit removido que tocou collect_evidence web_distillation e responda contendo $EXPECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'git-evidence-flow: missing final answer marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'git-evidence-flow: protocol error surfaced\n' >&2; exit 1; }
grep -q 'strategyId>collect_git_reflog' "$PROMPTS_FILE" || { printf 'git-evidence-flow: collect_git_reflog strategy id was not requested by model\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%' and body like '%reflog%'")" -ge 1 || { printf 'git-evidence-flow: missing collect_evidence reflog tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like '%strategy_id=collect_git_reflog%'")" -ge 1 || { printf 'git-evidence-flow: missing strategy id audit\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_event' and body like '%source=git%' and body like '%strategy=reflog%'")" -ge 1 || { printf 'git-evidence-flow: missing git reflog tool_event\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%[GIT_REFLOG]%' and body like '%deleted commit touching collect_evidence web_distillation%'")" -ge 1 || { printf 'git-evidence-flow: missing reflog evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body not like '%git reflog --all%'")" -ge 1 || { printf 'git-evidence-flow: raw command leaked into model evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%required follow-up%'")" -eq 0 || { printf 'git-evidence-flow: unexpected required follow-up repair\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%answer deferred available workspace evidence collection%'")" -eq 0 || { printf 'git-evidence-flow: cited git answer was incorrectly deferred\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'git-evidence-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'git-evidence-flow: ok work=%s db=%s\n' "$WORK" "$DB"
