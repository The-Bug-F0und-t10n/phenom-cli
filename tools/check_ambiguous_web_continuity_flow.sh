#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_AMBIGUOUS_WEB_CONTINUITY_SMOKE_DIR:-/tmp/phenom-ambiguous-web-continuity-smoke}
DB="$WORK/.phenom-zig/phenom.db"
SESSION=ambiguous-web-continuity-flow

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'ambiguous-web-continuity-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'ambiguous-web-continuity-flow: python3 is required for scripted backend\n' >&2
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
from urllib.parse import parse_qs, urlparse

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
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nServer: phenom-ambiguous-web-smoke\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode("ascii") + raw
    )

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(64)
port = sock.getsockname()[1]

responses = [
    "usuario ambiguo pediu fato externo atual; declaro ragweb com query propria\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>horario de brasilia agora fonte oficial</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>external fact from ambiguous user wording</parameter></function></tool_call>",
    f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q=horario%20de%20brasilia%20agora%20fonte%20oficial\nstatus=200\nquery=horario de brasilia agora fonte oficial\ntitle=Busca horario Brasilia\nexcerpt=Resultado atual sintetizado: PHENOM_WEB_AMBIG_BRASILIA_FACT.",
    "resposta do primeiro turno usando evidencia web destilada\n</think>\n\nE1 confirma a atualizacao ambigua por Web RAG: PHENOM_WEB_AMBIG_BRASILIA_FACT. Vou manter este fio para as proximas perguntas. PHENOM_AMBIG_T1.",
    "continuidade ambigua sem usuario dizer web; declaro ragweb para cotacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>cotacao dolar real hoje fonte confiavel</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>ambiguous follow-up needs current external evidence</parameter></function></tool_call>",
    f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q=cotacao%20dolar%20real%20hoje%20fonte%20confiavel\nstatus=200\nquery=cotacao dolar real hoje fonte confiavel\ntitle=Busca dolar real\nexcerpt=Resultado atual sintetizado: PHENOM_WEB_AMBIG_DOLAR_FACT.",
    "resposta do segundo turno preservando continuidade\n</think>\n\nE1 confirma a atualizacao da cotacao em continuidade: PHENOM_WEB_AMBIG_DOLAR_FACT. O contexto anterior continua sendo PHENOM_AMBIG_T1. PHENOM_AMBIG_T2.",
    "usuario declarou ragweb explicitamente; contrato web continua model-driven\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>cotacao euro real hoje fonte confiavel</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>user explicitly requested ragweb</parameter></function></tool_call>",
    f"[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{port}/search?q=cotacao%20euro%20real%20hoje%20fonte%20confiavel\nstatus=200\nquery=cotacao euro real hoje fonte confiavel\ntitle=Busca euro real\nexcerpt=Resultado atual sintetizado: PHENOM_WEB_DECL_EURO_FACT.",
    "resposta do terceiro turno declarativo\n</think>\n\nE1 confirma a busca declarativa por RAG Web: PHENOM_WEB_DECL_EURO_FACT. Mantive os pontos anteriores PHENOM_AMBIG_T1 e PHENOM_AMBIG_T2. PHENOM_DECL_T3.",
    "resumo linear sem nova busca\n</think>\n\nResumo da sessao: primeiro o pedido ambiguo virou PHENOM_WEB_AMBIG_BRASILIA_FACT; depois a continuidade ambigua virou PHENOM_WEB_AMBIG_DOLAR_FACT; por fim o pedido declarativo com RAG Web virou PHENOM_WEB_DECL_EURO_FACT. A conversa manteve PHENOM_AMBIG_T1, PHENOM_AMBIG_T2 e PHENOM_DECL_T3. PHENOM_CONTINUITY_FINAL.",
]

def search_body(query):
    if "horario de brasilia" in query:
        return "<html><head><title>Busca horario Brasilia</title></head><body><p>Resultado atual sintetizado: PHENOM_WEB_AMBIG_BRASILIA_FACT.</p><p>HTML bruto nao deve entrar no contexto permanente.</p></body></html>"
    if "dolar real" in query:
        return "<html><head><title>Busca dolar real</title></head><body><p>Resultado atual sintetizado: PHENOM_WEB_AMBIG_DOLAR_FACT.</p></body></html>"
    if "euro real" in query:
        return "<html><head><title>Busca euro real</title></head><body><p>Resultado atual sintetizado: PHENOM_WEB_DECL_EURO_FACT.</p></body></html>"
    return ""

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
                query = parse_qs(parsed.query).get("q", [""])[0]
                html = search_body(query)
                if not html:
                    send(conn, "400 Bad Request", "text/plain", "bad query")
                else:
                    send(conn, "200 OK", "text/html", html)
            elif method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4,5,6,7,8,9,10]}')
            elif method == "POST" and path == "/v1/chat/completions":
                payload = json.loads(body.decode("utf-8"))
                prompts.write(f"---REQUEST {completion_count + 1}---\n")
                prompts.write(payload.get("prompt") or "\n".join(message.get("content", "") for message in payload.get("messages", [])))
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
test -s "$PORT_FILE" || { printf 'ambiguous-web-continuity-flow: scripted backend did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

run_turn() {
  marker=$1
  prompt=$2
  out=$3
  (
    cd "$WORK"
    PHENOM_WEB_SEARCH_URL="http://127.0.0.1:$PORT/search?q={query}" "$BIN" chat \
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

run_turn PHENOM_AMBIG_T1 "Atualiza aquele horario de Brasilia para mim, sem enrolar." turn1
run_turn PHENOM_AMBIG_T2 "E aquele valor em real que vou comparar depois, como esta agora?" turn2
run_turn PHENOM_DECL_T3 "Agora declarativamente use ragweb para conferir o euro em real hoje." turn3
run_turn PHENOM_CONTINUITY_FINAL "Sem pesquisar de novo, resume o que voce fez nas buscas e mantenha a ordem da conversa." turn4

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

cat "$WORK"/turn*.out >"$WORK/all.out"
cat "$WORK"/turn*.err >"$WORK/all.err"

grep -q 'PHENOM_CONTINUITY_FINAL' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: missing final continuity marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_start'")" -eq 4 || { printf 'ambiguous-web-continuity-flow: expected four user turns\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -eq 4 || { printf 'ambiguous-web-continuity-flow: not all turns confirmed\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=set_operational_contract%' and body like '%state=accepted%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing accepted model contract declarations\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%contract=search_web%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing search_web contract selections\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%external fact from ambiguous user wording%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing non-declarative ambiguous web contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%ambiguous follow-up needs current external evidence%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing ambiguous follow-up web contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_selected' and body like '%user explicitly requested ragweb%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing declarative ragweb contract\n' >&2; exit 1; }
test "$(sql_count "kind = 'contract_executor' and body like '%executor=web_search%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: search_web contract did not execute web_search repeatedly\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_start' and body like 'web_search%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing web_search executions\n' >&2; exit 1; }
test "$(sql_count "kind = 'web_distillation' and body like '%success=true%'")" -ge 3 || { printf 'ambiguous-web-continuity-flow: missing web distillations\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_AMBIG_BRASILIA_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing distilled Brasilia evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_AMBIG_DOLAR_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing distilled dolar evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'evidence' and body like '%PHENOM_WEB_DECL_EURO_FACT%' and body not like '%<html>%'")" -ge 1 || { printf 'ambiguous-web-continuity-flow: missing distilled euro evidence\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_envelope' and body like '%raw_name=web_search%'")" -eq 0 || { printf 'ambiguous-web-continuity-flow: model bypassed contract with direct web_search\n' >&2; exit 1; }
test "$(sql_count "kind = 'tool_repair' and body like '%synthetic%'")" -eq 0 || { printf 'ambiguous-web-continuity-flow: synthetic repair was used\n' >&2; exit 1; }

grep -q '\[RECENT_DIALOGUE\]' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: recent dialogue was not sent to model\n' >&2; exit 1; }
grep -q 'PHENOM_AMBIG_T1' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 1 marker not present in later context\n' >&2; exit 1; }
grep -q 'PHENOM_AMBIG_T2' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 2 marker not present in later context\n' >&2; exit 1; }
grep -q 'PHENOM_DECL_T3' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 3 marker not present in later context\n' >&2; exit 1; }
grep -q 'contract=rag_web' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: initial schema did not expose rag_web contract declaration\n' >&2; exit 1; }
! grep -q 'required_tool_calls' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: required_tool_calls leaked into model prompt\n' >&2; exit 1; }

printf 'ambiguous-web-continuity-flow: ok work=%s db=%s\n' "$WORK" "$DB"
