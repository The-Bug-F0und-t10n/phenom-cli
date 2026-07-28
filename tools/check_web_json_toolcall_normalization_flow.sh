#!/usr/bin/env sh
set -eu

BIN="${1:-zig-out/bin/phenom}"
case "$BIN" in
  /*) ;;
  *) BIN="$(pwd)/$BIN" ;;
esac
WORK="${PHENOM_WEB_JSON_TOOLCALL_SMOKE_DIR:-/tmp/phenom-web-json-toolcall-flow-smoke}"
PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.txt"
OUT_FILE="$WORK/out.txt"
ERR_FILE="$WORK/err.txt"
SESSION="web-json-toolcall-flow"
EXPECT="PHENOM_WEB_JSON_NORMALIZED"

rm -rf "$WORK"
mkdir -p "$WORK"

python3 - "$PORT_FILE" "$PROMPTS_FILE" "$EXPECT" <<'PY' &
import json
import socket
import sys
from urllib.parse import parse_qs, urlparse

port_file = sys.argv[1]
prompts_file = sys.argv[2]
expect_marker = sys.argv[3]
completion_count = 0

base_query = "irradiacao solar media Londrina PR kWh m2 dia"
refined_query = "irradiacao solar media Londrina PR kWh m2 dia Atlas Solarimetrico INPE"

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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-web-json-toolcall-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(32)
port = sock.getsockname()[1]
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
                if "Atlas" in q:
                    send(conn, "200 OK", "text/html", "<html><head><title>DuckDuckGo</title></head><body></body></html>")
                else:
                    send(conn, "200 OK", "text/html", "<html><head><title>Londrina Solar</title></head><body><p>Irradiacao solar em Londrina : 4.</p><p>Atlas Solarimetrico do INPE.</p></body></html>")
            elif method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4,5,6,7,8]}')
            elif method == "POST" and path == "/completion":
                payload = json.loads(body.decode("utf-8"))
                prompt = payload.get("prompt", "")
                prompts.write(f"---REQUEST {completion_count + 1}---\n")
                prompts.write(prompt)
                prompts.write("\n")
                prompts.flush()
                if "WEB_EVIDENCE_INPUT" in prompt:
                    if "Atlas Solarimetrico INPE" in prompt:
                        text = f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q={refined_query.replace(' ', '%20')}\nstatus=202\nquery={refined_query}\ntitle=DuckDuckGo\nexcerpt="
                    else:
                        text = f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q={base_query.replace(' ', '%20')}\nstatus=200\nquery={base_query}\ntitle=irradiacao solar media Londrina PR kWh m2 dia at DuckDuckGo\nexcerpt=result=1 title=Irradiacao solar em Londrina (PR) -- 4. result=3 snippet=Atlas Solarimetrico do INPE."
                elif "tool call after the tool phase was closed" in prompt:
                    text = f"A evidencia coletada informa irradiacao solar em Londrina com trecho direto: 4.\n{expect_marker}"
                elif "tool phase is closed" in prompt:
                    text = f"""Vou pesquisar de novo.

```json
{{
  "tool_call": {{
    "name": "search_web",
    "arguments": {{
      "query": "{refined_query}"
    }}
  }}
}}
```"""
                elif "EMPTY_WEB_EVIDENCE_ANSWER_REPAIR" in prompt:
                    text = f"Nao encontrei evidencia direta suficiente na segunda busca para confirmar a media de irradiacao solar de Londrina com seguranca. A primeira busca trouxe apenas trecho parcial apontando '4.', sem unidade completa nem fonte final verificavel.\n{expect_marker}"
                elif "MODEL_DECLARED_QUERY" in prompt:
                    text = refined_query if "Atlas Solarimetrico INPE" in prompt else base_query
                else:
                    text = f"preciso pesquisar\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>{base_query}</parameter><parameter=reason>buscar dado externo solicitado</parameter></function></tool_call>"
                completion_count += 1
                send(conn, "200 OK", "text/event-stream", completion_payload(text))
                if completion_count >= 7:
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
test -s "$PORT_FILE" || { printf 'web-json-toolcall-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  printf 'web_search_url = "http://127.0.0.1:%s/search?q={query}"\n' "$PORT" > config.toml
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "como media a irradiacao solar em Londrina - PR, pesquise na internet. Responda contendo $EXPECT." \
    --max-tokens 512 \
    --thinking on \
    --expect-contains "$EXPECT" \
    --fail-on-model-error \
    --no-color
) >"$OUT_FILE" 2>"$ERR_FILE" || {
  cat "$OUT_FILE" >&2
  cat "$ERR_FILE" >&2
  exit 1
}

grep -q "$EXPECT" "$OUT_FILE" || { printf 'web-json-toolcall-flow: missing final marker\n' >&2; exit 1; }
! grep -q '"tool_call"' "$OUT_FILE" || { printf 'web-json-toolcall-flow: JSON tool_call leaked to visible output\n' >&2; exit 1; }
! grep -q '```json' "$OUT_FILE" || { printf 'web-json-toolcall-flow: fenced JSON leaked to visible output\n' >&2; exit 1; }
! grep -q 'PHENOM_WEB_LANG_EN' "$OUT_FILE" || { printf 'web-json-toolcall-flow: English fallback path leaked\n' >&2; exit 1; }

DB="$WORK/.phenom-zig/phenom.db"
sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -eq 1 || { printf 'web-json-toolcall-flow: expected exactly one web_search execution\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=web_search%' and body like '%contract=answer_only%'")" -ge 1 || { printf 'web-json-toolcall-flow: JSON tool_call was not rejected after tool phase closed\n' >&2; exit 1; }
test "$(sql_count "kind = 'answer_repair' and body = 'tool call emitted after tool phase closed'")" -ge 1 || { printf 'web-json-toolcall-flow: missing closed tool phase answer repair\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'web-json-toolcall-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'web-json-toolcall-flow: ok work=%s db=%s\n' "$WORK" "$DB"
