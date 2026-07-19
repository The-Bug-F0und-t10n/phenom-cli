# Phenom Zig

Phenom Zig e o binario Zig/C do projeto Phenom: um agente local de terminal com CLI/TUI, streaming para modelos locais, renderer markdown append-only, auditoria SQLite, memoria operacional de sessao e tool loop controlado por contratos.

O projeto e voltado a uso local-first com backends como Ollama e llama.cpp. A proposta central e executar conversas, recuperacao de contexto e acoes de codigo com evidencia destilada, limites auditaveis e separacao explicita entre dialogo, memoria persistente, micro-contexto e outputs de ferramentas.

## Principais recursos

- CLI com comandos `chat`, `probe`, `snapshot`, `version` e `help`.
- TUI append-only, sem alternate screen, com recuperacao de sessao ao reabrir o binario.
- Renderer markdown com headings, listas, code blocks, diff, tabelas com quebra interna de celulas e output de tools.
- Streaming HTTP local para Ollama (`/api/chat`) e llama.cpp (`/completion`).
- Filtro de reasoning para blocos `<think>...</think>`.
- Auditoria SQLite em `.phenom-zig/phenom.db`.
- Recuperacao de sessao por eventos recentes, `SESSION_FOCUS`, FTS5/BM25 e resumo operacional de sessoes longas.
- Tool loop com allowlist por contrato operacional.
- `collect_evidence`, `search_session`, `apply_patch`, `validate_syntax`, `promote_context` e perfis de contexto.
- Orcamento pre-send de contexto do modelo, com limite atual de 24 KiB e rejeicao de marcadores brutos.

## Requisitos

- Linux ou ambiente POSIX compativel.
- Zig 0.16.0 ou binario Zig equivalente em `bin/zig-x86_64-linux-0.16.0/zig`.
- `sqlite3` e headers de desenvolvimento.
- Opcional: Ollama ou llama.cpp ativo para inferencia real.

Debian/Ubuntu:

```sh
sudo apt-get install sqlite3 libsqlite3-dev
```

## Instalacao rapida

Build e instalacao local:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast
```

O build instala:

- `zig-out/bin/phenom`
- `~/.local/bin/phenom`
- `~/.config/phenom/config.toml` mesclado a partir de `../config.toml`

Verificacao:

```sh
phenom version
phenom chat --offline --session dev --prompt "responda somente: ok"
```

## Uso basico

Chat com backend real:

```sh
phenom chat --backend ollama --host 127.0.0.1:11434 --model llama3.2 --prompt "ola"
phenom chat --backend llamacpp --host 127.0.0.1:8080 --model local --prompt "ola"
```

Modo interativo:

```sh
phenom chat --session trabalho
```

Probe sem inferencia:

```sh
phenom probe --backend ollama --host 127.0.0.1:11434
phenom probe --backend llamacpp --host 127.0.0.1:8080
```

## Documentacao

- [Indice geral](doc/INDEX.md)
- [Instalacao](doc/INSTALL.md)
- [Build e testes](doc/BUILD.md)
- [Flags e configuracao](doc/FLAGS.md)

## Dados locais

O projeto grava estado operacional no diretorio de trabalho:

- `.phenom-zig/phenom.db`: eventos, historico de input, FTS e foco de sessao.
- `MEMORY.md` e `SKILLS.md`: memoria persistente textual, somente quando promovida explicitamente.
- `zig-out/`, `.zig-cache/`, `zig-cache/`: artefatos de build/cache.

O audit SQLite nao deve ser tratado como memoria persistente do modelo. Ele e trilha operacional para restauracao, busca, diagnostico e prova de fluxo.

## Validacao

Suite offline:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build test
```

Smokes reais exigem backend ativo:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL
```

## Estado do projeto

Phenom Zig e produto em desenvolvimento ativo. O nucleo de CLI/TUI, renderizacao, streaming, auditoria, recuperacao de sessao, contexto operacional, contratos e ferramentas principais ja existe. Familias adicionais de tools, integracoes externas e politicas mais amplas devem seguir as tasks e guardrails do repositorio antes de serem consideradas completas.

Ao alterar codigo, use os documentos de `doc/`, `../TASKS.md`, `../alinhamento.md` e os testes como fonte de verdade operacional.
