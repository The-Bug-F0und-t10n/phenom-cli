# phenom-zig

Produto Phenom em Zig + C: agente de CLI/TUI para codigo, sessao operacional, tool loop auditavel e contexto destilado.

Estado atual:

1. CLI `chat`, `probe`, `snapshot`, `version` e `help`.
2. Renderer append-only com thinking, markdown, code blocks, diff e eventos de tools.
3. Streaming HTTP local para Ollama e llama.cpp.
4. SQLite audit operacional via `sqlite3` C.
5. Tool gate com allowlist por contrato.
6. `collect_evidence`, `search_session`, micro-contexto e EvidencePacket.
7. Recuperacao de sessao por SQLite FTS5/BM25 com `scope=current|all` e `session?`.
8. Snapshot de terminal e build release.

Estado que ainda nao deve ser tratado como completo:

- Nem todas as ferramentas do `phenom-cli-ts` foram portadas.
- Mutation, validation, runtime/browser, memory writer final e news ainda dependem de tasks proprias.
- Smokes reais dependem de servidor Ollama/llama.cpp ativo e nao fazem parte da suite offline.

Dependencias do sistema:

- Zig 0.16.0 ou compativel.
- `sqlite3` e headers de desenvolvimento (`libsqlite3-dev` em Debian/Ubuntu).

Comandos offline esperados:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- chat --offline --session dev --prompt "responda somente: ok"
```

Probe de backend sem inferencia:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- probe --backend llamacpp --host HOST:PORT
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- probe --backend ollama --host HOST:PORT
```

Testes reais de backend exigem servidor ativo:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- chat --backend ollama --host HOST:PORT --model MODEL --prompt "ola" --max-tokens 64 --thinking auto
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build run -- chat --backend llamacpp --host HOST:PORT --model MODEL --prompt "ola" --max-tokens 64 --thinking auto
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build real-session-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build real-dialogue-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL
```

Regra de validacao:

- Toda task deve declarar se cumpre 100% do objetivo ou se e parcial.
- Toda task parcial deve listar partes entregues, partes faltantes e risco residual.
- Features que dependem de servidor/modelo devem ter teste real opt-in separado da suite offline.
- A suite offline nunca deve depender de `127.0.0.1`, Ollama, llama.cpp, rede ou modelo real.
- Smokes reais usam `--fail-on-model-error` e `--expect-contains`; se o backend nao conectar, falhar ou nao gerar a saida esperada, o comando retorna exit code nao-zero.

Notas de arquitetura:

- O renderer e append-only por padrao; nao usa alternate screen.
- O audit operacional vai para SQLite, nao para MEMORY/SKILLS.
- HTTP atual e local-first, sem TLS, voltado a Ollama e llama.cpp.
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
- `--max-tokens` limita a geracao; default atual: 512.
- Se o modelo terminar dentro de `<think>` sem resposta final visivel, o CLI mostra um status explicito em vez de finalizar em branco.
- Tool loop parseia `<tool_call>`, valida allowlist, executa contrato permitido e gera evidencia/micro-contexto auditavel.
- Nenhum teste offline assume que `127.0.0.1:11434` esta ativo; host real deve ser provado por comando real separado.
