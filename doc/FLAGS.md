# Flags, comandos e configuracao

Este documento lista os comandos, flags e chaves de configuracao suportadas pelo CLI.

## Comandos

```sh
phenom chat [options]
phenom probe [options]
phenom snapshot
phenom version
phenom help
```

## `chat`

Executa um turno de conversa ou abre a TUI interativa quando `--prompt` nao e informado.

Exemplos:

```sh
phenom chat --prompt "ola"
phenom chat --session trabalho
phenom chat --offline --prompt "teste"
phenom chat --backend ollama --host 127.0.0.1:11434 --model llama3.2 --prompt "ola"
phenom chat --backend llamacpp --host 127.0.0.1:8080 --model local --prompt "ola"
```

Flags:

- `--prompt TEXT`: executa um turno nao-interativo com o texto informado.
- `--session ID`: seleciona a sessao SQLite. Default: `default`.
- `--offline`: nao chama modelo; emite stub local. Util para validar CLI e audit.
- `--backend ollama|llamacpp`: seleciona backend HTTP.
- `--host HOST:PORT`: host do backend.
- `--model MODEL`: nome do modelo enviado ao backend.
- `--max-tokens N`: limite de geracao visivel. Default: `4096`.
- `--thinking auto|on|off`: controla template/filtro de reasoning.
- `--no-color`: desativa ANSI colorido.
- `--fail-on-model-error`: retorna erro se o modelo/backend falhar.
- `--expect-contains TEXT`: exige que a resposta visivel contenha o texto.
- `--show-expect-status`: mostra status de expectativa.
- `--demo-read-file PATH`: executa leitura demonstrativa de arquivo via tool controlada.

## `probe`

Testa conectividade com backend sem executar inferencia.

```sh
phenom probe --backend ollama --host 127.0.0.1:11434
phenom probe --backend llamacpp --host 127.0.0.1:8080
```

Flags:

- `--backend ollama|llamacpp`
- `--host HOST:PORT`

Endpoints:

- Ollama: `GET /api/tags`
- llama.cpp: `GET /`

## `snapshot`

Executa snapshot local do terminal/render quando implementado pelo binario.

```sh
phenom snapshot
```

## `version`

Mostra versao do binario:

```sh
phenom version
```

## `help`

Mostra uso resumido:

```sh
phenom help
```

## Thinking

`--thinking off`:

- usa template que fecha `<think>` no inicio;
- reduz chance de reasoning visivel;
- bom para smokes e respostas diretas.

`--thinking on`:

- permite bloco `<think>`;
- renderer mostra reasoning como bloco `thinking`;
- resposta final fica separada.

`--thinking auto`:

- usa `off` para prompts simples;
- usa `on` quando detecta sinais de codigo, bug, patch, debug, arquivo, tool ou tarefa longa.

## Expectativas em smoke

`--expect-contains TEXT` valida a resposta visivel.

Exemplo:

```sh
phenom chat \
  --backend llamacpp \
  --host 127.0.0.1:8080 \
  --model local \
  --prompt "responda exatamente PHENOM_OK" \
  --expect-contains "PHENOM_OK" \
  --show-expect-status \
  --fail-on-model-error
```

Se o texto esperado nao aparecer, o turno registra `expectation_failed` e retorna erro.

## Arquivos de configuracao

Ordem:

1. `./config.toml`
2. `~/.config/phenom/config.toml`
3. flags de CLI

Chaves aceitas:

- `backend = "ollama"` ou `"llamacpp"`
- `host = "127.0.0.1"`
- `port = 11434`
- `server = "http://127.0.0.1:8080"`
- `model = "llama3.2"`
- `thinking = "auto"` ou `"on"` ou `"off"`
- `max_tokens = 4096`
- `no_color = true|false`
- `offline = true|false`
- `fail_on_model_error = true|false`
- `expect_contains = "TEXT"`
- `show_expect_status = true|false`
- `demo_read_file = "PATH"`
- `session = "default"`

Exemplo:

```toml
backend = "llamacpp"
host = "127.0.0.1"
port = 8080
model = "local"
thinking = "auto"
max_tokens = 4096
session = "dev"
no_color = false
```

## Sessoes

A sessao define o namespace de eventos no SQLite.

```sh
phenom chat --session trabalho
phenom chat --session trabalho --prompt "continue"
```

Ao reabrir a TUI, o CLI recupera os ultimos turnos da sessao e renderiza novamente o transcript util. Reasoning antigo (`assistant_thinking_delta`) nao e replayado para evitar poluicao visual.

## Saidas e exit code

Sem `--fail-on-model-error`, falhas de backend podem ser registradas como evento operacional sem quebrar todos os fluxos.

Com `--fail-on-model-error`, falha de conexao/modelo retorna exit code nao-zero.

Com `--expect-contains`, ausencia do texto esperado retorna falha de expectativa.

## Flags de build para smokes

Usadas com `zig build`:

- `-Dreal-backend=ollama|llamacpp`
- `-Dreal-host=HOST:PORT`
- `-Dreal-model=MODEL`
- `-Dreal-prompt=TEXT`
- `-Dreal-expect=TEXT`
- `-Dreal-session=ID`
- `-Dreal-dialogue-session=ID`
- `-Dreal-long-session=ID`
