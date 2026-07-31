#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_LINEAR_WEB_WORKSPACE_SMOKE_DIR:-/tmp/phenom-linear-web-workspace-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=linear-web-workspace-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'linear-web-workspace-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'linear-web-workspace-flow: python3 is required for scripted backend\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/docs"
cat >"$WORK/README.md" <<'EOF'
# Linear Workspace Fixture

The local project implements a terminal agent with persistent dialogue, Web RAG, and workspace evidence.
Local marker: PHENOM_LOCAL_README_FACT.
EOF
cat >"$WORK/src/config.zig" <<'EOF'
pub const conversation_mode = "linear";
pub const workspace_marker = "PHENOM_LOCAL_CONFIG_FACT";
EOF
cat >"$WORK/docs/notes.md" <<'EOF'
The user wants active conversation continuity while the model switches between web evidence and local evidence.
EOF

PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"
python3 - "$PORT_FILE" "$PROMPTS_FILE" <<'PY' &
import json
import socket
import sys

port_file, prompts_file = sys.argv[1:3]
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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-linear-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(32)
port = sock.getsockname()[1]
doc1 = f"http://127.0.0.1:{port}/doc-alpha.html"
doc2 = f"http://127.0.0.1:{port}/doc-beta.html"

responses = [
    "saudacao e combinado de assunto\n</think>\n\nVamos manter uma conversa linear sobre RAG Web e evidencia local. Marcador inicial PHENOM_LINEAR_T1.",
    f"turno 2 precisa de web\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=target>{doc1}</parameter><parameter=query>Alpha Web RAG PHENOM_WEB_ALPHA_FACT</parameter><parameter=budget_bytes>4096</parameter><parameter=reason>buscar evidencia web alpha escolhida pelo modelo</parameter></function></tool_call>",
    "responder alpha e manter continuidade\n</think>\n\nE1 registra PHENOM_WEB_ALPHA_FACT como evidencia web destilada. Continuo a partir de PHENOM_LINEAR_T1. PHENOM_LINEAR_T2.",
    "turno 3 precisa de workspace\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>collect_evidence</parameter><parameter=reason>ler README local escolhido pelo modelo</parameter></function></tool_call>",
    "coletar README\n</think>\n\n<tool_call><function=collect_evidence><parameter=path>README.md</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>8</parameter></function></tool_call>",
    "responder workspace e lembrar web\n</think>\n\nE1 contem PHENOM_LOCAL_README_FACT no README local. O fio continua com PHENOM_WEB_ALPHA_FACT e PHENOM_LINEAR_T2. PHENOM_LINEAR_T3.",
    f"turno 4 mistura web beta e arquivo config\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=target>{doc2}</parameter><parameter=query>Beta Web RAG PHENOM_WEB_BETA_FACT</parameter><parameter=budget_bytes>4096</parameter><parameter=reason>comparar evidencia web beta com config local</parameter></function></tool_call>",
    "trocar para workspace config\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>collect_evidence</parameter><parameter=reason>agora ler config local apos evidencia web beta</parameter></function></tool_call>",
    "coletar config local\n</think>\n\n<tool_call><function=collect_evidence><parameter=path>src/config.zig</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>8</parameter></function></tool_call>",
    "final linear combinado\n</think>\n\nE1 registra PHENOM_LOCAL_CONFIG_FACT e a evidencia web anterior registra PHENOM_WEB_BETA_FACT. A conversa manteve PHENOM_LINEAR_T1, PHENOM_LINEAR_T2 e PHENOM_LINEAR_T3. PHENOM_LINEAR_FINAL.",
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
            if method == "GET" and path == "/doc-alpha.html":
                send(conn, "200 OK", "text/html", "<html><head><title>Alpha RAG Doc</title></head><body><p>Alpha Web RAG evidence says PHENOM_WEB_ALPHA_FACT and explains distilled external retrieval.</p><p>Raw filler should not be persisted as HTML.</p></body></html>")
            elif method == "GET" and path == "/doc-beta.html":
                send(conn, "200 OK", "text/html", "<html><head><title>Beta RAG Doc</title></head><body><p>Beta Web RAG evidence says PHENOM_WEB_BETA_FACT and complements local config comparison.</p></body></html>")
            elif method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4,5,6,7,8,9,10,11,12]}')
            elif method == "POST" and path == "/v1/chat/completions":
                payload = json.loads(body.decode("utf-8"))
                prompt = payload.get("prompt") or "\n".join(message.get("content", "") for message in payload.get("messages", []))
                prompts.write(f"---REQUEST {completion_count + 1}---\n")
                prompts.write(prompt)
                prompts.write("\n")
                prompts.flush()
                if "[WEB_QUERY_OPTIMIZATION]" in prompt:
                    text = "Alpha Web RAG PHENOM_WEB_ALPHA_FACT" if "alpha" in prompt.lower() else "Beta Web RAG PHENOM_WEB_BETA_FACT"
                elif "[WEB_DISTILLATION_TASK]" in prompt:
                    if "PHENOM_WEB_ALPHA_FACT" in prompt:
                        text = f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target={doc1}\nstatus=200\nquery=Alpha Web RAG PHENOM_WEB_ALPHA_FACT\ntitle=Alpha RAG Doc\nexcerpt=Alpha Web RAG evidence says PHENOM_WEB_ALPHA_FACT and explains distilled external retrieval."
                    else:
                        text = f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target={doc2}\nstatus=200\nquery=Beta Web RAG PHENOM_WEB_BETA_FACT\ntitle=Beta RAG Doc\nexcerpt=Beta Web RAG evidence says PHENOM_WEB_BETA_FACT and complements local config comparison."
                else:
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
test -s "$PORT_FILE" || { printf 'linear-web-workspace-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")
DOC1="http://127.0.0.1:$PORT/doc-alpha.html"
DOC2="http://127.0.0.1:$PORT/doc-beta.html"

run_turn() {
  marker=$1
  prompt=$2
  out=$3
  (
    cd "$WORK"
    "$BIN" chat \
      --backend llamacpp \
      --host "127.0.0.1:$PORT" \
      --model scripted \
      --session "$SESSION" \
      --prompt "$prompt" \
      --max-tokens 512 \
      --thinking on \
      --expect-contains "$marker" \
      --fail-on-model-error \
      --no-color
  ) >"$WORK/$out.out" 2>"$WORK/$out.err"
}

run_turn PHENOM_LINEAR_T1 "Ola. Vamos manter conversa linear sobre RAG Web e evidencia local." turn1
run_turn PHENOM_LINEAR_T2 "Agora use Web RAG para consultar $DOC1 e mantenha o assunto anterior." turn2
run_turn PHENOM_LINEAR_T3 "Agora leia o README local e conecte com a evidencia web anterior." turn3
run_turn PHENOM_LINEAR_FINAL "Agora consulte $DOC2, leia src/config.zig e compare tudo com o que ja conversamos." turn4

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

cat "$WORK"/turn*.out >"$WORK/all.out"
cat "$WORK"/turn*.err >"$WORK/all.err"

grep -q 'PHENOM_LINEAR_FINAL' "$WORK/all.out" || { printf 'linear-web-workspace-flow: missing final marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/all.out" || { printf 'linear-web-workspace-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_start'")" -eq 4 || { printf 'linear-web-workspace-flow: expected four user turns\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -eq 4 || { printf 'linear-web-workspace-flow: not all turns confirmed\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 2 || { printf 'linear-web-workspace-flow: missing repeated web_search calls\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 2 || { printf 'linear-web-workspace-flow: missing repeated web distillation\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'collect_evidence%'")" -ge 2 || { printf 'linear-web-workspace-flow: missing repeated workspace collection\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_ALPHA_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing distilled alpha web evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_BETA_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing distilled beta web evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_LOCAL_README_FACT%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing README evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_LOCAL_CONFIG_FACT%'")" -ge 1 || { printf 'linear-web-workspace-flow: missing config evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic collect_evidence%'")" -eq 0 || { printf 'linear-web-workspace-flow: synthetic collect_evidence was used\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic search_session%'")" -eq 0 || { printf 'linear-web-workspace-flow: synthetic search_session was used\n' >&2; exit 1; }

grep -q '\[RECENT_DIALOGUE\]' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: recent dialogue was not sent to model\n' >&2; exit 1; }
grep -q 'PHENOM_LINEAR_T1' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: turn 1 marker not present in later model context\n' >&2; exit 1; }
grep -q 'PHENOM_LINEAR_T2' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: turn 2 marker not present in later model context\n' >&2; exit 1; }
grep -q 'PHENOM_LINEAR_T3' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: turn 3 marker not present in later model context\n' >&2; exit 1; }
! grep -q 'required_tool_calls' "$PROMPTS_FILE" || { printf 'linear-web-workspace-flow: required_tool_calls leaked into model prompt\n' >&2; exit 1; }

printf 'linear-web-workspace-flow: ok work=%s db=%s\n' "$WORK" "$DB"
