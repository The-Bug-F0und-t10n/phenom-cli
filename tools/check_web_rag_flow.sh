#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_WEB_RAG_SMOKE_DIR:-/tmp/phenom-web-rag-flow-smoke}
DB="$WORK/.phenom-zig/phenom.db"
WEB_SESSION=web-rag-tool-flow
COLLECT_SESSION=web-rag-collect-flow
EXPECT_WEB=PHENOM_WEB_RAG_OK
EXPECT_COLLECT=PHENOM_COLLECT_WEB_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'web-rag-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'web-rag-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
python3 - "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT_WEB" "$EXPECT_COLLECT" <<'PY' &
import json
import socket
import sys

port_file, prompts_file, expect_web, expect_collect = sys.argv[1:5]
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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-web-rag-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(16)
port = sock.getsockname()[1]
target = f"http://127.0.0.1:{port}/doc.html"
responses = [
    "selecionar contrato de evidencia externa\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>coletar evidencia web explicita</parameter></function></tool_call>",
    f"buscar pagina indicada\n</think>\n\n<tool_call><function=web_search><parameter=target>{target}</parameter><parameter=query>Phenom Web RAG contrato</parameter><parameter=budget_bytes>4096</parameter></function></tool_call>",
    f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target={target}\nstatus=200\nquery=Phenom Web RAG contrato\ntitle=Phenom Web RAG\nexcerpt=Phenom Web RAG fornece evidencia contratual externa destilada para respostas.",
    f"responder usando WEB_EVIDENCE\n</think>\n\nE1 contem WEB_EVIDENCE da pagina explicitamente buscada e informa que Phenom Web RAG fornece evidencia contratual externa. {expect_web}",
    "selecionar contrato de evidencia por collect_evidence\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>coletar URL pelo collect_evidence</parameter></function></tool_call>",
    f"coletar URL via collect_evidence\n</think>\n\n<tool_call><function=collect_evidence><parameter=httpSearch>true</parameter><parameter=target>{target}</parameter><parameter=query>Phenom Web RAG contrato</parameter><parameter=budget_bytes>4096</parameter></function></tool_call>",
    f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target={target}\nstatus=200\nquery=Phenom Web RAG contrato\ntitle=Phenom Web RAG\nexcerpt=collect_evidence recebeu WEB_EVIDENCE destilada pelo modelo para economizar contexto.",
    f"responder usando evidencia coletada\n</think>\n\nE1 informa que Phenom Web RAG fornece evidencia externa destilada para respostas. {expect_collect}",
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
            if method == "GET" and path == "/doc.html":
                send(conn, "200 OK", "text/html", "<html><head><title>Phenom Web RAG</title></head><body><h1>Phenom Web RAG</h1><p>Contrato web_search fornece evidencia externa destilada para respostas e collect_evidence.</p></body></html>")
            elif method == "GET" and path == "/props":
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
test -s "$PORT_FILE" || { printf 'web-rag-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")
TARGET="http://127.0.0.1:$PORT/doc.html"

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$WEB_SESSION" \
    --prompt "Use evidencia web contratual para resumir $TARGET e responda contendo $EXPECT_WEB." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT_WEB" \
    --fail-on-model-error \
    --no-color
) >"$WORK/web.out" 2>"$WORK/web.err"

(
  cd "$WORK"
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$COLLECT_SESSION" \
    --prompt "Use collect_evidence com target URL para coletar $TARGET e responda contendo $EXPECT_COLLECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT_COLLECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/collect.out" 2>"$WORK/collect.err"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT_WEB" "$WORK/web.out" || { printf 'web-rag-flow: missing web_search final answer\n' >&2; exit 1; }
grep -q "$EXPECT_COLLECT" "$WORK/collect.out" || { printf 'web-rag-flow: missing collect_evidence final answer\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/web.out" || { printf 'web-rag-flow: protocol error surfaced in web_search flow\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/collect.out" || { printf 'web-rag-flow: protocol error surfaced in collect_evidence flow\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$1' and $2;"
}

test "$(sql_count "$WEB_SESSION" "kind = 'contract_selected' and body like '%contract=collect_evidence%' and body like '%web_search%'")" -ge 1 || { printf 'web-rag-flow: web_search contract not selected\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'tool_start' and body like 'web_search%' and body like '%$TARGET%'")" -ge 1 || { printf 'web-rag-flow: missing web_search tool_start\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'tool_event' and body like '%tool=web_search%' and body like '%status=200%'")" -ge 1 || { printf 'web-rag-flow: missing web_search successful tool_event\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'web_distillation' and body like '%success=true%' and body like '%output_bytes=%'")" -ge 1 || { printf 'web-rag-flow: missing web_search model distillation audit\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'evidence' and body like '%[WEB_EVIDENCE]%' and body like '%Phenom Web RAG%' and body not like '%<html>%'")" -ge 1 || { printf 'web-rag-flow: missing distilled WEB_EVIDENCE\n' >&2; exit 1; }
test "$(sql_count "$WEB_SESSION" "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'web-rag-flow: web_search turn was not confirmed\n' >&2; exit 1; }

test "$(sql_count "$COLLECT_SESSION" "kind = 'tool_start' and body like 'collect_evidence%' and body like '%$TARGET%'")" -ge 1 || { printf 'web-rag-flow: missing collect_evidence URL tool_start\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'tool_event' and body like '%tool=web_search%' and body like '%status=200%'")" -ge 1 || { printf 'web-rag-flow: collect_evidence did not reuse web executor\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'web_distillation' and body like '%success=true%' and body like '%output_bytes=%'")" -ge 1 || { printf 'web-rag-flow: missing collect_evidence model distillation audit\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'evidence' and body like '%[WEB_EVIDENCE]%' and body like '%collect_evidence%' and body not like '%<html>%'")" -ge 1 || { printf 'web-rag-flow: collect_evidence URL evidence missing or raw\n' >&2; exit 1; }
test "$(sql_count "$COLLECT_SESSION" "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'web-rag-flow: collect_evidence turn was not confirmed\n' >&2; exit 1; }

grep -q '\[WEB_DISTILLATION_TASK\]' "$PROMPTS_FILE" || { printf 'web-rag-flow: model distillation prompt was not sent\n' >&2; exit 1; }

printf 'web-rag-flow: ok work=%s db=%s\n' "$WORK" "$DB"
