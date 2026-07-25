#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_QUERY_WEB_RAG_SMOKE_DIR:-/tmp/phenom-query-web-rag-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=query-web-rag-flow
EXPECT=PHENOM_QUERY_WEB_RAG_OK

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'query-web-rag-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'query-web-rag-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
python3 - "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT" <<'PY' &
import json
import socket
import sys
from urllib.parse import parse_qs, urlparse

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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-query-web-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(32)
port = sock.getsockname()[1]
responses = [
    "pergunta externa sem URL declara contrato rag web\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>horario de brasilia agora fonte confiavel</parameter><parameter=budget_bytes>4096</parameter><parameter=reason>conhecimento externo nao atribuido ao contexto do modelo</parameter></function></tool_call>",
    "horario de brasilia agora fonte confiavel",
    f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q=horario%20de%20brasilia%20agora%20fonte%20confiavel\nstatus=200\nquery=horario de brasilia agora fonte confiavel\ntitle=Busca local Web RAG\nexcerpt=A busca por query retornou PHENOM_QUERY_WEB_FACT para uma pergunta sem URL.",
    f"responder com web rag\n</think>\n\nE1 mostra que a pergunta sem URL foi resolvida via Web RAG por query e retornou PHENOM_QUERY_WEB_FACT. {expect}",
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
            parsed = urlparse(path)
            if method == "GET" and parsed.path == "/search":
                q = parse_qs(parsed.query).get("q", [""])[0]
                if "horario de brasilia" not in q:
                    send(conn, "400 Bad Request", "text/plain", "bad query")
                else:
                    send(conn, "200 OK", "text/html", "<html><head><title>Busca local Web RAG</title></head><body><p>A busca por query retornou PHENOM_QUERY_WEB_FACT para uma pergunta sem URL.</p></body></html>")
            elif method == "GET" and path == "/props":
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
test -s "$PORT_FILE" || { printf 'query-web-rag-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  printf 'web_search_url = "http://127.0.0.1:%s/search?q={query}"\n' "$PORT" > config.toml
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "Qual e o horario de Brasilia agora? Responda contendo $EXPECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$WORK/out.txt" 2>"$WORK/err.txt"

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

grep -q "$EXPECT" "$WORK/out.txt" || { printf 'query-web-rag-flow: missing final answer marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/out.txt" || { printf 'query-web-rag-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_start' and body like 'web_search%' and body like '%/search?q=horario%20de%20brasilia%'")" -ge 1 || { printf 'query-web-rag-flow: missing query-resolved web_search tool_start\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 1 || { printf 'query-web-rag-flow: missing web distillation\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_QUERY_WEB_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'query-web-rag-flow: missing distilled query evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'query-web-rag-flow: turn was not confirmed\n' >&2; exit 1; }

test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=set_operational_contract%' and body like '%state=accepted%'")" -ge 1 || { printf 'query-web-rag-flow: model contract declaration was not accepted\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=search_web%' and body like '%strategyId=search_web_distilled%'")" -ge 1 || { printf 'query-web-rag-flow: rag_web contract was not selected\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_executor' and body like '%executor=web_search%'")" -ge 1 || { printf 'query-web-rag-flow: search_web contract did not execute web_search\n' >&2; exit 1; }
grep -q 'web_search_url/PHENOM_WEB_SEARCH_URL' "$PROMPTS_FILE" || { printf 'query-web-rag-flow: schema did not expose configured query search behavior\n' >&2; exit 1; }

printf 'query-web-rag-flow: ok work=%s db=%s\n' "$WORK" "$DB"
