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
import re
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
    "horario de brasilia agora fonte oficial",
    "resposta do primeiro turno usando evidencia web destilada\n</think>\n\nE1 confirma a atualizacao ambigua por Web RAG: PHENOM_WEB_AMBIG_BRASILIA_FACT. Vou manter este fio para as proximas perguntas.\nPHENOM_AMBIG_T1",
    "continuidade ambigua sem usuario dizer web; declaro ragweb para cotacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>cotacao dolar real hoje fonte confiavel</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>ambiguous follow-up needs current external evidence</parameter></function></tool_call>",
    "cotacao dolar real hoje fonte confiavel",
    "resposta do segundo turno preservando continuidade\n</think>\n\nE1 confirma a atualizacao da cotacao em continuidade: PHENOM_WEB_AMBIG_DOLAR_FACT. O contexto anterior continua sendo PHENOM_AMBIG_T1.\nPHENOM_AMBIG_T2",
    "usuario declarou ragweb explicitamente; contrato web continua model-driven\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>cotacao euro real hoje fonte confiavel</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>user explicitly requested ragweb</parameter></function></tool_call>",
    "cotacao euro real hoje fonte confiavel",
    "resposta do terceiro turno declarativo\n</think>\n\nE1 confirma a busca declarativa por RAG Web: PHENOM_WEB_DECL_EURO_FACT. Mantive os pontos anteriores PHENOM_AMBIG_T1 e PHENOM_AMBIG_T2.\nPHENOM_DECL_T3",
    "resumo linear sem nova busca\n</think>\n\nResumo da sessao: primeiro o pedido ambiguo virou PHENOM_WEB_AMBIG_BRASILIA_FACT; depois a continuidade ambigua virou PHENOM_WEB_AMBIG_DOLAR_FACT; por fim o pedido declarativo com RAG Web virou PHENOM_WEB_DECL_EURO_FACT. A conversa manteve PHENOM_AMBIG_T1, PHENOM_AMBIG_T2 e PHENOM_DECL_T3.\nPHENOM_CONTINUITY_FINAL",
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
                prompt = payload.get("prompt") or "\n".join(message.get("content", "") for message in payload.get("messages", []))
                prompts.write(f"---REQUEST {completion_count + 1}---\n")
                prompts.write(prompt)
                prompts.write("\n")
                prompts.flush()
                if completion_count < 2:
                    current_date = re.search(r"(?m)^current_date=(\d{4}-\d{2}-\d{2})$", prompt)
                    current_weekday = re.search(r"(?m)^current_weekday=([A-Za-z]+)$", prompt)
                    if not current_date or not current_weekday:
                        text = "contexto temporal ausente\n</think>\n\nTEMPORAL_CONTEXT_MISSING"
                    elif completion_count == 0:
                        text = f"usar data autoritativa do sistema\n</think>\n\nHoje e {current_date.group(1)}.\nPHENOM_TEMPORAL_DATE_OK"
                    else:
                        text = f"usar dia autoritativo do sistema\n</think>\n\nHoje cai em {current_weekday.group(1)}.\nPHENOM_TEMPORAL_WEEKDAY_OK"
                else:
                    response_index = completion_count - 2
                    text = responses[response_index] if response_index < len(responses) else responses[-1]
                completion_count += 1
                send(conn, "200 OK", "text/event-stream", completion_payload(text))
                if completion_count >= len(responses) + 2:
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

run_turn PHENOM_TEMPORAL_DATE_OK "moço, que dia é hoje?" temporal-date
run_turn PHENOM_TEMPORAL_WEEKDAY_OK "e hoje cai em que dia da semana?" temporal-weekday
run_turn PHENOM_AMBIG_T1 "vi falar que o horário mudou, como ficou isso em Brasília?" turn1
run_turn PHENOM_AMBIG_T2 "e aquele valor em real que o pessoal olha, como está agora?" turn2
run_turn PHENOM_DECL_T3 "confere também esse negócio do euro em real pra mim hoje" turn3
run_turn PHENOM_CONTINUITY_FINAL "sem olhar de novo, me explica rapidinho o que você conferiu" turn4

wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT

cat "$WORK"/turn*.out >"$WORK/all.out"
cat "$WORK"/turn*.err >"$WORK/all.err"

grep -q 'PHENOM_CONTINUITY_FINAL' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: missing final continuity marker\n' >&2; exit 1; }
! grep -q '\[MODEL_PROTOCOL_ERROR\]' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: protocol error surfaced\n' >&2; exit 1; }

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'turn_start'")" -eq 6 || { printf 'ambiguous-web-continuity-flow: expected six user turns\n' >&2; exit 1; }
test "$(sql_count "kind = 'turn_done' and body like 'status=ok%quality=confirmed%'")" -eq 6 || { printf 'ambiguous-web-continuity-flow: not all turns confirmed\n' >&2; exit 1; }
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
grep -q '^current_date=' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: current_date missing from model context\n' >&2; exit 1; }
grep -q '^current_weekday=' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: current_weekday missing from model context\n' >&2; exit 1; }
! grep -q 'TEMPORAL_CONTEXT_MISSING' "$WORK/all.out" || { printf 'ambiguous-web-continuity-flow: temporal context was unavailable\n' >&2; exit 1; }
grep -q 'PHENOM_AMBIG_T1' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 1 marker not present in later context\n' >&2; exit 1; }
grep -q 'PHENOM_AMBIG_T2' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 2 marker not present in later context\n' >&2; exit 1; }
grep -q 'PHENOM_DECL_T3' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: turn 3 marker not present in later context\n' >&2; exit 1; }
grep -q 'set_operational_contract(contract=answer_only|' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: operational contract schema missing\n' >&2; exit 1; }
grep -q '|search_web|rag_web|' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: web contracts missing from schema\n' >&2; exit 1; }
! grep -q 'required_tool_calls' "$PROMPTS_FILE" || { printf 'ambiguous-web-continuity-flow: required_tool_calls leaked into model prompt\n' >&2; exit 1; }

printf 'ambiguous-web-continuity-flow: ok work=%s db=%s\n' "$WORK" "$DB"
