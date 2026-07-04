# phenom-zig spike

MVP baixo nivel do Phenom em Zig + C.

Escopo do spike:

1. CLI `chat` minimo.
2. Renderer append-only.
3. Streaming HTTP local para Ollama e llama.cpp.
4. SQLite audit via `sqlite3` C.
5. Tool gate fake.
6. `read_file_range`.
7. `EvidencePacket`.
8. Snapshot de terminal.
9. Build release.

Dependencias do sistema:

- Zig 0.16.0 ou compatível.
- `sqlite3` e headers de desenvolvimento (`libsqlite3-dev` em Debian/Ubuntu).

Comandos offline esperados:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- chat --offline --session spike --prompt "responda somente: ok"
```

Probe de backend sem inferencia:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- probe --backend llamacpp --host HOST:PORT
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- probe --backend ollama --host HOST:PORT
```

Teste real de backend nao faz parte da suite offline e exige servidor ativo. Exemplos:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- chat --backend ollama --host HOST:PORT --model MODEL --prompt "ola" --max-tokens 64 --thinking auto
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- chat --backend llamacpp --host HOST:PORT --model MODEL --prompt "ola" --max-tokens 64 --thinking auto
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL
```

`real-smoke` usa um token sentinela (`PHENOM_REAL_7319`) por padrao e falha se a resposta visivel nao contiver o texto esperado. Em ambientes com sandbox de rede, o mesmo comando pode falhar antes de chegar ao servidor; nesse caso, valide o transporte com `curl` e rode o smoke com rede liberada.

Regra de validacao:

- Toda task deve declarar se cumpre 100% do objetivo ou se e micro-base/parcial.
- Toda task deve listar complexidade restante quando nao cobrir 100%.
- Features que dependem de servidor/modelo devem ter teste real opt-in separado da suite offline.
- A suite offline nunca deve depender de `127.0.0.1`, Ollama, llama.cpp, rede ou modelo real.
- `real-smoke` usa `--fail-on-model-error` e `--expect-contains`; se o backend nao conectar, falhar ou nao gerar a saida esperada, o comando retorna exit code nao-zero.

Notas de arquitetura:

- O renderer e append-only por padrao; nao usa alternate screen.
- O audit operacional vai para SQLite, nao para MEMORY/SKILLS.
- O HTTP e propositalmente limitado a HTTP local sem TLS para o MVP.
- O HTTP usa sockets C (`socket`, `connect`, `read`, `write`); IPv4 literal conecta direto por `sockaddr_in` e nomes de host usam fallback `getaddrinfo`.
- Ollama usa `/api/chat`.
- llama.cpp usa `/completion`.
- `probe` nao usa endpoint de inferencia: llama.cpp usa `GET /`; Ollama usa `GET /api/tags`.
- O prompt llama.cpp segue o template Qwopus/Qwen informado pelo usuario: `<|im_start|>system`, `<|im_start|>user`, `<|im_start|>assistant`.
- `--thinking off` inicia o assistant com `<think>\n\n</think>\n\n`, igual ao comportamento `enable_thinking=false` do template.
- `--thinking on` inicia o assistant com `<think>\n`, permitindo reasoning do modelo; o renderer mostra esse bloco como `thinking` em baixo destaque e separa a resposta final em `assistant`.
- `--thinking auto` usa `off` para chat simples e `on` para prompts com sinais de codigo, bug, patch, debug, arquivo, tool ou tarefa mais longa.
- Deltas de streaming decodificam escapes JSON como `\n`.
- O renderer classifica blocos `<think>...</think>` mesmo quando as tags chegam quebradas entre chunks.
- Se o stream trouxer apenas `</think>` porque `<think>` veio do prompt/template, o conteudo anterior e tratado como thinking, nao como resposta final.
- `--max-tokens` limita a geracao no MVP; default atual: 512.
- Se o modelo terminar dentro de `<think>` sem resposta final visivel, o CLI mostra um status explicito em vez de finalizar em branco.
- O gate fake existe para provar a fronteira parser/controller/executor antes de tools reais.
- Tool loop offline inicial parseia `<tool_call>`, valida allowlist, executa `read_file_range` e gera `EvidencePacket` + `MicroContext`.
- Nenhum teste offline assume que `127.0.0.1:11434` esta ativo; host real deve ser provado por comando real separado.
