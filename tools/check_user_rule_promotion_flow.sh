#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
case "$BIN" in
  /*) ;;
  *) BIN="$ROOT/$BIN" ;;
esac
WORK=${PHENOM_RULE_PROMOTION_DIR:-/tmp/phenom-rule-promotion-flow}
DB="$WORK/.phenom-zig/phenom.db"
PORT_FILE="$WORK/port"
PROMPTS_FILE="$WORK/prompts.log"

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'rule-promotion-flow: sqlite3 CLI is required\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'rule-promotion-flow: python3 is required\n' >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

python3 - "$PORT_FILE" "$PROMPTS_FILE" <<'PY' &
import json
import socket
import sys
import urllib.parse

port_file, prompts_file = sys.argv[1:3]
responses = [
    "<think>o usuario definiu uma regra operacional duravel; devo persistir como skill interpretada</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>memory</parameter><parameter=requiresMemoryPromotion>true</parameter><parameter=reason>persistir regra operacional duravel confirmada pelo usuario</parameter></function></tool_call>",
    "<think>contrato memory ativo; promover regra normalizada para skills</think>\n\n<tool_call><function=promote_context><parameter=target>skills</parameter><parameter=text>Nao commitar sem rodar testes</parameter></function></tool_call>",
    "<think>promocao concluida; responder curto</think>\n\nRegistrado em SKILLS.md: nao commitar sem rodar testes.",
    "<think>o usuario pergunta por regra local persistida; preciso consultar MEMORY/SKILLS</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>memory</parameter><parameter=query>regra local antes de commitar testes</parameter><parameter=reason>recuperar regra operacional persistida</parameter></function></tool_call>",
    "<think>buscar regra persistida relevante</think>\n\n<tool_call><function=search_persistent_context><parameter=target>skills</parameter><parameter=terms>commitar testes regra operacional</parameter></function></tool_call>",
    "<think>ignorei a evidencia recuperada por engano</think>\n\nNao tenho nenhuma regra local persistida sobre isso.",
    "<think>SKILLS recuperou a regra; responder aplicando-a</think>\n\nA regra local e: nao commitar sem rodar testes. Antes de commitar, rode os testes relevantes.",
]
completion_count = 0

def send(conn, status, ctype, body):
    if isinstance(body, str):
        raw = body.encode()
    else:
        raw = body
    headers = (
        f"HTTP/1.1 {status}\r\n"
        f"Content-Type: {ctype}\r\n"
        f"Content-Length: {len(raw)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode()
    conn.sendall(headers + raw)

def completion_payload(text):
    return "data: " + json.dumps({"content": text, "stop": True}, ensure_ascii=False) + "\n\n"

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(64)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(sock.getsockname()[1]))

try:
    while True:
        conn, _ = sock.accept()
        with conn:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            if not data:
                continue
            header, _, body = data.partition(b"\r\n\r\n")
            line = header.split(b"\r\n", 1)[0].decode("utf-8", "ignore")
            parts = line.split()
            path = parts[1] if len(parts) > 1 else "/"
            if path.startswith("/tokenize"):
                try:
                    payload = json.loads(body.decode("utf-8", "ignore") or "{}")
                    content = payload.get("content") or payload.get("prompt") or ""
                except Exception:
                    content = ""
                send(conn, "200 OK", "application/json", json.dumps({"tokens": list(range(max(1, len(content) // 4))) }))
                continue
            if path.startswith("/props"):
                send(conn, "200 OK", "application/json", json.dumps({"default_generation_settings": {"n_ctx": 65536}}))
                continue
            if path.startswith("/completion"):
                try:
                    payload = json.loads(body.decode("utf-8", "ignore") or "{}")
                    prompt = payload.get("prompt", "")
                except Exception:
                    prompt = ""
                with open(prompts_file, "a", encoding="utf-8") as f:
                    f.write(f"---REQUEST {completion_count}---\n{prompt}\n")
                text = responses[completion_count] if completion_count < len(responses) else responses[-1]
                completion_count += 1
                send(conn, "200 OK", "text/event-stream", completion_payload(text))
                continue
            send(conn, "404 Not Found", "text/plain", "not found")
except KeyboardInterrupt:
    pass
finally:
    sock.close()
PY
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
test -s "$PORT_FILE" || { printf 'rule-promotion-flow: fake model did not start\n' >&2; exit 1; }
PORT=$(cat "$PORT_FILE")
SESSION=rule-promotion-flow

(
  cd "$WORK"
  "$BIN" chat --backend llamacpp --host "127.0.0.1:$PORT" --model fake --session "$SESSION" --prompt "daqui pra frente, nao faca comite sem rodar testes" --no-color
) >"$WORK/turn1.out" 2>"$WORK/turn1.err"

grep -q 'Nao commitar sem rodar testes' "$WORK/SKILLS.md" || {
  printf 'rule-promotion-flow: SKILLS.md missing promoted interpreted rule\n' >&2
  exit 1
}

(
  cd "$WORK"
  "$BIN" chat --backend llamacpp --host "127.0.0.1:$PORT" --model fake --session "$SESSION" --prompt "qual regra local devo seguir antes de commitar?" --no-color
) >"$WORK/turn2.out" 2>"$WORK/turn2.err"

sql_count() {
  sqlite3 "$DB" "select count(*) from events where session = '$SESSION' and $1;"
}

test "$(sql_count "kind = 'contract_selected' and body like '%contract=memory%'")" -ge 2 || {
  printf 'rule-promotion-flow: memory contract was not selected in both turns\n' >&2
  exit 1
}
test "$(sql_count "kind = 'persistent_promotion' and body like '%target=skills%' and body like '%status=promoted%'")" -ge 1 || {
  printf 'rule-promotion-flow: missing persistent_promotion audit\n' >&2
  exit 1
}
test "$(sql_count "kind = 'persistent_context' and body like '%Nao commitar sem rodar testes%'")" -ge 1 || {
  printf 'rule-promotion-flow: second turn did not retrieve SKILLS.md\n' >&2
  exit 1
}
test "$(sql_count "kind = 'answer_repair' and body = 'retrieved skills contradiction'")" -ge 1 || {
  printf 'rule-promotion-flow: retrieved SKILLS contradiction did not trigger answer repair\n' >&2
  exit 1
}
grep -q 'nao commitar sem rodar testes' "$WORK/turn2.out" || {
  printf 'rule-promotion-flow: final answer did not apply retrieved rule\n' >&2
  exit 1
}
! grep -q 'Nao tenho nenhuma regra local persistida' "$WORK/turn2.out" || {
  printf 'rule-promotion-flow: contradicted SKILLS answer leaked to user\n' >&2
  exit 1
}
grep -q 'requiresMemoryPromotion' "$PROMPTS_FILE" || {
  printf 'rule-promotion-flow: prompt did not expose memory promotion contract\n' >&2
  exit 1
}
grep -q 'generic best practices' "$PROMPTS_FILE" || {
  printf 'rule-promotion-flow: prompt did not constrain retrieved SKILLS answers\n' >&2
  exit 1
}

kill "$SERVER_PID" 2>/dev/null || true
trap - EXIT
printf 'rule-promotion-flow: ok workdir=%s\n' "$WORK"
