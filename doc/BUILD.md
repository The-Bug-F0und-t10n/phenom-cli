# Build e testes

Este documento descreve os comandos de compilacao, teste e smoke do Phenom Zig.

## Build padrao

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build
```

O build padrao:

- compila `src/main.zig`;
- linka libc;
- linka `sqlite3`;
- gera `zig-out/bin/phenom`;
- instala `~/.local/bin/phenom`;
- mescla `~/.config/phenom/config.toml`.

## Build release

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast
```

Use para o binario que sera chamado por `phenom` no terminal.

## Rodar sem instalar manualmente

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build run -- chat --offline --session dev --prompt "ola"
```

O step `run` depende do install step. Portanto ele tambem sincroniza o binario local.

## Testes offline

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build test
```

A suite offline nao deve depender de:

- rede;
- Ollama;
- llama.cpp;
- `127.0.0.1` ativo;
- modelo real.

Ela cobre CLI, renderer, parser, HTTP body/parsing, auditoria SQLite, session context, contratos, evidence, micro-contexto, patch, validacao e guardrails locais.

## Testes unitarios por arquivo

Exemplos:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/render.zig --cache-dir /tmp/phenom-render-test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/audit.zig -lc -lsqlite3 --cache-dir /tmp/phenom-audit-test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-main-test
```

Use testes por arquivo quando estiver isolando regressao de renderer, SQLite ou fluxo principal.

## Probe de backend

O probe testa conectividade sem inferencia:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build run -- probe --backend ollama --host HOST:PORT
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build run -- probe --backend llamacpp --host HOST:PORT
```

Endpoints usados:

- Ollama: `GET /api/tags`
- llama.cpp: `GET /`

## Smokes reais

Smokes reais sao opt-in e exigem backend ativo.

Smoke simples:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build real-smoke \
  -Dreal-backend=llamacpp \
  -Dreal-host=HOST:PORT \
  -Dreal-model=MODEL
```

Smoke de recuperacao de sessao:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build real-session-smoke \
  -Dreal-backend=llamacpp \
  -Dreal-host=HOST:PORT \
  -Dreal-model=MODEL
```

Smoke de continuidade de dialogo recente:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build real-dialogue-smoke \
  -Dreal-backend=llamacpp \
  -Dreal-host=HOST:PORT \
  -Dreal-model=MODEL
```

Smoke de sessao longa:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build real-long-session-smoke \
  -Dreal-backend=llamacpp \
  -Dreal-host=HOST:PORT \
  -Dreal-model=MODEL
```

Opcoes de build para smokes:

- `-Dreal-backend=ollama|llamacpp`
- `-Dreal-host=HOST:PORT`
- `-Dreal-model=MODEL`
- `-Dreal-prompt=TEXT`
- `-Dreal-expect=TEXT`
- `-Dreal-session=ID`
- `-Dreal-dialogue-session=ID`
- `-Dreal-long-session=ID`

## Caches recomendados

Use cache global fora do repositorio para reduzir ruido:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
```

Use `--cache-dir /tmp/...` em testes pontuais quando quiser separar artefatos:

```sh
./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-main-test
```

## Validacao antes de fechar alteracao

Para alteracoes de renderer:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/render.zig --cache-dir /tmp/phenom-render-test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-main-test
```

Para alteracoes de contexto/sessao:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3 --cache-dir /tmp/phenom-session-test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-main-test
```

Para alteracoes em tool loop/contratos:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/contracts.zig --cache-dir /tmp/phenom-contracts-test
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-main-test
```
