#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/zig-out/bin/phenom"}
WORK=${PHENOM_THREE_LEVEL_WORK:-/tmp/phenom-three-level-100}
BACKEND=${PHENOM_THREE_LEVEL_BACKEND:-llamacpp}
HOST=${PHENOM_THREE_LEVEL_HOST:-inference.local:11434}
MODEL=${PHENOM_THREE_LEVEL_MODEL:-phenom:latest}
TIMEOUT=${PHENOM_THREE_LEVEL_TIMEOUT:-180}

command -v sqlite3 >/dev/null || { printf 'three-level: sqlite3 required\n' >&2; exit 1; }
command -v timeout >/dev/null || { printf 'three-level: timeout required\n' >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"

failures=0
transient_retries=0

answer_for() {
  level=$1 turn=$2 previous=$3
  slot=$(( (turn - 1) % 10 ))
  if [ "$slot" -eq 9 ]; then printf '%s' "$previous"; return; fi
  case "$level:$slot" in
    standard:0) printf '95' ;; standard:1) printf 'bom dia' ;; standard:2) printf '13:45' ;;
    standard:3) printf 'papéis' ;; standard:4) printf '60' ;; standard:5) printf '1,2,7,9' ;;
    standard:6) printf '0' ;; standard:7) printf '30' ;; standard:8) printf 'entrega intacta' ;;
    intermediate:0) printf '30' ;; intermediate:1) printf 'não' ;; intermediate:2) printf '409' ;;
    intermediate:3) printf 'rebase' ;; intermediate:4) printf '640' ;; intermediate:5) printf 'CNAME' ;;
    intermediate:6) printf '+' ;; intermediate:7) printf 'A' ;; intermediate:8) printf 'atomicidade' ;;
    advanced:0) printf '8' ;; advanced:1) printf '9' ;; advanced:2) printf '30' ;;
    advanced:3) printf '15' ;; advanced:4) printf '0,8' ;; advanced:5) printf 'O(log n)' ;;
    advanced:6) printf 'p verdadeiro e q falso' ;; advanced:7) printf '1' ;; advanced:8) printf '0,01' ;;
  esac
}

prompt_for() {
  level=$1 turn=$2 marker=$3 previous=$4
  slot=$(( (turn - 1) % 10 ))
  if [ "$slot" -eq 9 ]; then
    printf 'Sem inventar: qual foi o identificador exato da sua resposta imediatamente anterior nesta conversa? Responda exatamente: %s|%s' "$marker" "$previous"
    return
  fi
  case "$level:$slot" in
    standard:0) printf 'Quanto é 37 + 58? Responda exatamente: %s|95' "$marker" ;;
    standard:1) printf 'Traduza "good morning" para português. Responda exatamente: %s|bom dia' "$marker" ;;
    standard:2) printf 'Tenho reunião às 14:30 e preciso sair 45 minutos antes. Responda exatamente: %s|13:45' "$marker" ;;
    standard:3) printf 'Qual é o plural de "papel"? Responda exatamente: %s|papéis' "$marker" ;;
    standard:4) printf 'Uma compra custa R$ 80 e tem desconto de 25%%. Responda exatamente: %s|60' "$marker" ;;
    standard:5) printf 'Ordene crescentemente 9, 2, 7, 1. Responda exatamente: %s|1,2,7,9' "$marker" ;;
    standard:6) printf 'Complete sem explicação: água congela a quantos graus Celsius ao nível do mar? Responda exatamente: %s|0' "$marker" ;;
    standard:7) printf 'Se hoje eu li 12 páginas e ontem 18, qual o total? Responda exatamente: %s|30' "$marker" ;;
    standard:8) printf 'Resuma "A entrega chegou cedo e sem danos" em duas palavras. Responda exatamente: %s|entrega intacta' "$marker" ;;

    intermediate:0) printf 'Uma rede IPv4 /27 possui quantos endereços utilizáveis para hosts, desconsiderando rede e broadcast? Responda exatamente: %s|30' "$marker" ;;
    intermediate:1) printf 'Em SQL, COUNT(coluna) conta valores NULL? Responda exatamente: %s|não' "$marker" ;;
    intermediate:2) printf 'Em HTTP, qual status indica conflito de estado do recurso? Responda exatamente: %s|409' "$marker" ;;
    intermediate:3) printf 'No Git, qual comando reaplica commits locais sobre outra base? Responda exatamente: %s|rebase' "$marker" ;;
    intermediate:4) printf 'Um arquivo tem permissões rw-r----- em octal. Responda exatamente: %s|640' "$marker" ;;
    intermediate:5) printf 'Em DNS, qual registro aponta um nome para outro nome canônico? Responda exatamente: %s|CNAME' "$marker" ;;
    intermediate:6) printf 'Em regex, qual quantificador significa uma ou mais ocorrências? Responda exatamente: %s|+' "$marker" ;;
    intermediate:7) printf 'Uma fila FIFO contém A,B,C nessa ordem. Após remover um elemento, qual sai? Responda exatamente: %s|A' "$marker" ;;
    intermediate:8) printf 'Em ACID, qual propriedade garante tudo ou nada numa transação? Responda exatamente: %s|atomicidade' "$marker" ;;

    advanced:0) printf 'Calcule a derivada de x^3 - 4x em x=2. Responda exatamente: %s|8' "$marker" ;;
    advanced:1) printf 'Calcule a integral definida de 2x de 0 a 3. Responda exatamente: %s|9' "$marker" ;;
    advanced:2) printf 'Uma matriz diagonal tem autovalores 2, 3 e 5. Qual é o determinante? Responda exatamente: %s|30' "$marker" ;;
    advanced:3) printf 'Em um grafo completo não direcionado K6, quantas arestas existem? Responda exatamente: %s|15' "$marker" ;;
    advanced:4) printf 'Se P(A)=0,4, P(B|A)=0,5 e P(B)=0,25, calcule P(A|B). Responda exatamente: %s|0,8' "$marker" ;;
    advanced:5) printf 'Qual a complexidade assintótica da busca binária? Responda exatamente: %s|O(log n)' "$marker" ;;
    advanced:6) printf 'Na lógica proposicional, p implica q é falsa somente em qual caso? Responda exatamente: %s|p verdadeiro e q falso' "$marker" ;;
    advanced:7) printf 'Um sistema linear homogêneo com 4 incógnitas e posto 3 tem nulidade igual a quanto? Responda exatamente: %s|1' "$marker" ;;
    advanced:8) printf 'Para f(x)=x², qual é o erro da aproximação linear em torno de x=1 quando x=1,1? Responda exatamente: %s|0,01' "$marker" ;;
  esac
}

run_level() {
  level=$1
  session="three-level-${level}-100"
  dir="$WORK/$level"
  mkdir -p "$dir"
  previous=""
  turn=1
  while [ "$turn" -le 100 ]; do
    marker=$(printf '%s-%03d' "${level^^}" "$turn")
    prompt=$(prompt_for "$level" "$turn" "$marker" "$previous")
    expected="$marker|$(answer_for "$level" "$turn" "$previous")"
    output="$dir/turn-$(printf '%03d' "$turn").out"
    error="$dir/turn-$(printf '%03d' "$turn").err"
    attempt=1
    passed=0
    while [ "$attempt" -le 3 ]; do
      before=$(sqlite3 "$WORK/.phenom-zig/phenom.db" 'select coalesce(max(id),0) from events;' 2>/dev/null || printf 0)
      if (
        cd "$WORK"
        timeout "$TIMEOUT" "$BIN" chat \
          --backend "$BACKEND" \
          --host "$HOST" \
          --model "$MODEL" \
          --session "$session" \
          --prompt "$prompt" \
          --max-tokens 256 \
          --thinking "$( [ "$level" = advanced ] && printf on || printf off )" \
          --expect-contains "$expected" \
          --fail-on-model-error \
          --no-color
      ) >"$output" 2>"$error"; then
        actual=$(sqlite3 "$WORK/.phenom-zig/phenom.db" "select coalesce(group_concat(body,''),'') from events where session='$session' and kind='assistant_delta' and id>$before order by id;")
        if [ "$actual" = "$expected" ]; then passed=1; break; fi
        printf '%s turn %s mismatch expected=[%s] actual=[%s]\n' "$level" "$turn" "$expected" "$actual" >>"$WORK/failures.log"
      else
        printf '%s turn %s attempt %s transport/process failure\n' "$level" "$turn" "$attempt" >>"$WORK/retries.log"
      fi
      transient_retries=$((transient_retries + 1))
      attempt=$((attempt + 1))
      sleep 2
    done
    if [ "$passed" -ne 1 ]; then
      printf '%s turn %s process failure\n' "$level" "$turn" >>"$WORK/failures.log"
      failures=$((failures + 1))
    fi
    previous=$marker
    turn=$((turn + 1))
  done

  db="$WORK/.phenom-zig/phenom.db"
  sql="session = '$session'"
  ok=$(sqlite3 "$db" "select count(*) from events where $sql and kind='turn_done' and body like 'status=ok%';")
  errors=$(sqlite3 "$db" "select count(*) from events where $sql and kind='turn_error';")
  length=$(sqlite3 "$db" "select count(*) from events where $sql and kind='model_stop' and body like '%reason=length%';")
  tools=$(sqlite3 "$db" "select count(*) from events where $sql and kind='tool_start';")
  protocol=$(sqlite3 "$db" "select count(*) from events where $sql and kind='assistant_delta' and (body like '%<tool_call>%' or body like '%[MODEL_PROTOCOL_ERROR]%' or body like '%[WEB_EVIDENCE]%');")
  dialogue=$(sqlite3 "$db" "select count(*) from events where $sql and kind='model_context' and body like '%[RECENT_DIALOGUE]%';")
  printf '%s ok=%s errors=%s length=%s tools=%s protocol=%s dialogue=%s\n' "$level" "$ok" "$errors" "$length" "$tools" "$protocol" "$dialogue" | tee "$dir/summary.txt"
  if [ "$ok" -ne 100 ] || [ "$errors" -ne 0 ] || [ "$length" -ne 0 ] || [ "$tools" -ne 0 ] || [ "$protocol" -ne 0 ] || [ "$dialogue" -lt 90 ]; then
    failures=$((failures + 1))
  fi
}

run_level standard
run_level intermediate
run_level advanced

printf 'three-level failures=%s transient_retries=%s work=%s\n' "$failures" "$transient_retries" "$WORK"
test "$failures" -eq 0
