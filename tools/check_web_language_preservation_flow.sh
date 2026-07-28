#!/usr/bin/env sh
set -eu

BIN="${1:-zig-out/bin/phenom}"
case "$BIN" in
  /*) ;;
  *) BIN="$(pwd)/$BIN" ;;
esac
WORK="${PHENOM_WEB_LANGUAGE_SMOKE_DIR:-/tmp/phenom-web-language-flow-smoke}"
PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.txt"
OUT_FILE="$WORK/out.txt"
ERR_FILE="$WORK/err.txt"
SESSION="web-language-flow"
LANG_LABEL="${PHENOM_WEB_LANGUAGE_LABEL:-user-lang-a}"
EXPECT="${PHENOM_WEB_LANGUAGE_EXPECT:-PHENOM_WEB_LANG_USER}"
EMPTY_EVIDENCE="${PHENOM_WEB_LANGUAGE_EMPTY_EVIDENCE:-0}"

rm -rf "$WORK"
mkdir -p "$WORK"

python3 - "$PORT_FILE" "$PROMPTS_FILE" "$LANG_LABEL" "$EXPECT" "$EMPTY_EVIDENCE" <<'PY' &
import json
import socket
import sys
from urllib.parse import parse_qs, urlparse

port_file = sys.argv[1]
prompts_file = sys.argv[2]
lang_label = sys.argv[3]
expect_marker = sys.argv[4]
empty_evidence = sys.argv[5] == "1"
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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-web-language-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
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
                if "solar" not in q:
                    send(conn, "400 Bad Request", "text/plain", "bad query")
                else:
                    send(conn, "200 OK", "text/html", "<html><head><title>Solar Cost</title></head><body><p>Solar off-grid systems require batteries, inverter, panels, and charge controllers.</p></body></html>")
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
                if completion_count == 0:
                    text = "precisa de evidencia externa\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>solar off-grid house cost batteries inverter panels</parameter><parameter=reason>estimar custo externo com evidencia</parameter></function></tool_call>"
                elif completion_count == 1:
                    text = "solar off-grid house cost batteries inverter panels"
                elif "WEB_EVIDENCE_INPUT" in prompt:
                    excerpt = "" if empty_evidence else "Solar off-grid systems require batteries, inverter, panels, and charge controllers."
                    text = f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q=solar%20off-grid%20house%20cost%20batteries%20inverter%20panels\nstatus=200\nquery=solar off-grid house cost batteries inverter panels\ntitle=Solar Cost\nexcerpt={excerpt}"
                elif "EMPTY_WEB_EVIDENCE_ANSWER_REPAIR" in prompt and lang_label in prompt:
                    text = f"{lang_label}: busca-sem-evidencia-direta.\n{expect_marker}"
                elif "Answer in the user's language" in prompt and "source/WEB_EVIDENCE language" in prompt and lang_label in prompt:
                    text = f"preserve user task language\n</think>\n\n{lang_label}: soma-bateria soma-inversor soma-painel soma-controlador.\n{expect_marker}"
                else:
                    text = "answer in english\n</think>\n\nE1 says solar off-grid systems require batteries and inverter. PHENOM_WEB_LANG_EN"
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
test -s "$PORT_FILE" || { printf 'web-language-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

(
  cd "$WORK"
  printf 'web_search_url = "http://127.0.0.1:%s/search?q={query}"\n' "$PORT" > config.toml
  "$BIN" chat \
    --backend llamacpp \
    --host "127.0.0.1:$PORT" \
    --model scripted \
    --session "$SESSION" \
    --prompt "Usuario esta usando o idioma operacional '$LANG_LABEL'. Pesquise e explique nesse idioma operacional o que entra no custo de uma casa off-grid solar. Responda contendo $EXPECT." \
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

grep -q "$EXPECT" "$OUT_FILE" || { printf 'web-language-flow: missing user-language marker\n' >&2; exit 1; }
grep -q "$LANG_LABEL:" "$OUT_FILE" || { printf 'web-language-flow: missing user-language prefix\n' >&2; exit 1; }
! grep -q "PHENOM_WEB_LANG_EN" "$OUT_FILE" || { printf 'web-language-flow: model answered in English path\n' >&2; exit 1; }
! grep -q "web_search returned no direct supporting excerpt" "$OUT_FILE" || { printf 'web-language-flow: English empty-evidence fallback leaked\n' >&2; exit 1; }
if [ "$EMPTY_EVIDENCE" = "1" ]; then
  ! grep -q "EMPTY_WEB_EVIDENCE_ANSWER_REPAIR" "$PROMPTS_FILE" || { printf 'web-language-flow: empty evidence should finalize without model repair\n' >&2; exit 1; }
else
  grep -q "user's language from USER_TASK" "$PROMPTS_FILE" || { printf 'web-language-flow: missing web language obligation in prompt\n' >&2; exit 1; }
  grep -q "source/WEB_EVIDENCE language" "$PROMPTS_FILE" || { printf 'web-language-flow: missing WEB_EVIDENCE language guard\n' >&2; exit 1; }
fi

DB="$WORK/.phenom-zig/phenom.db"
sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 1 || { printf 'web-language-flow: missing web_search execution\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%[WEB_EVIDENCE]%'")" -ge 1 || { printf 'web-language-flow: missing WEB_EVIDENCE\n' >&2; exit 1; }
if [ "$EMPTY_EVIDENCE" = "1" ]; then
  test "$(sql_count "kind = 'answer_repair' and body = 'empty web evidence direct deterministic answer'")" -ge 1 || { printf 'web-language-flow: missing deterministic empty-evidence answer audit\n' >&2; exit 1; }
fi
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -ge 1 || { printf 'web-language-flow: turn was not confirmed\n' >&2; exit 1; }

printf 'web-language-flow: ok work=%s db=%s\n' "$WORK" "$DB"
