# Instalacao

Este documento descreve como preparar o ambiente, compilar e instalar o Phenom Zig localmente.

## Requisitos de sistema

Obrigatorios:

- Linux ou ambiente POSIX compativel.
- Zig 0.16.0.
- SQLite 3.
- Headers de desenvolvimento do SQLite.
- Shell POSIX com `sh`.

O repositorio ja inclui um binario Zig esperado em:

```sh
./bin/zig-x86_64-linux-0.16.0/zig
```

Se preferir usar `zig` global, garanta que a versao seja compativel com 0.16.0.

## Dependencias no Debian/Ubuntu

```sh
sudo apt-get update
sudo apt-get install sqlite3 libsqlite3-dev
```

## Build e instalacao local

Na raiz `phenom-zig`:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast
```

Esse comando compila e instala:

- `zig-out/bin/phenom`
- `~/.local/bin/phenom`
- `~/.config/phenom/config.toml`

O arquivo de configuracao e mesclado por `tools/merge_config.sh`, preservando valores locais sempre que aplicavel.

## Verificacao da instalacao

```sh
which phenom
phenom version
phenom chat --offline --session install-check --prompt "responda somente: ok"
```

O modo `--offline` nao chama modelo. Ele serve para validar CLI, renderer, SQLite e gravacao de turno.

## Backend Ollama

Exemplo com Ollama local:

```sh
ollama serve
phenom probe --backend ollama --host 127.0.0.1:11434
phenom chat --backend ollama --host 127.0.0.1:11434 --model llama3.2 --prompt "ola"
```

`probe` nao executa inferencia. Ele testa conectividade e endpoint de saude/listagem.

## Backend llama.cpp

Exemplo:

```sh
phenom probe --backend llamacpp --host 127.0.0.1:8080
phenom chat --backend llamacpp --host 127.0.0.1:8080 --model local --prompt "ola"
```

O backend llama.cpp usa `/completion` e template Qwopus/Qwen no corpo do prompt.

## Configuracao local

Ordem de leitura:

1. `./config.toml`, se existir no diretorio atual.
2. `~/.config/phenom/config.toml`, se nao houver config local.
3. Flags de CLI sobrescrevem valores carregados do arquivo.

Exemplo:

```toml
backend = "llamacpp"
host = "127.0.0.1"
port = 8080
model = "local"
thinking = "auto"
max_tokens = 512
session = "default"
```

Tambem e aceito:

```toml
server = "http://127.0.0.1:8080"
```

## Onde os dados ficam

No diretorio em que o comando roda:

- `.phenom-zig/phenom.db`: audit SQLite, eventos, historico e FTS.
- `MEMORY.md`: memoria persistente promovida explicitamente.
- `SKILLS.md`: habilidades persistentes promovidas explicitamente.

Em cache/build:

- `zig-out/bin/phenom`
- `.zig-cache/`
- `zig-cache/`
- valor de `ZIG_GLOBAL_CACHE_DIR`, quando definido.

## Problemas comuns

`sqlite3.h` nao encontrado:

```sh
sudo apt-get install libsqlite3-dev
```

`phenom` ainda executa binario antigo:

```sh
which phenom
ls -l "$(which phenom)" zig-out/bin/phenom
```

Reinstale com:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast
```

Backend nao conecta:

```sh
phenom probe --backend ollama --host 127.0.0.1:11434
phenom probe --backend llamacpp --host 127.0.0.1:8080
```

Use `--fail-on-model-error` em smokes para transformar falha de backend em exit code nao-zero.
