# Documentacao geral do Phenom Zig

Este indice e a pagina principal da documentacao tecnica do Phenom Zig.

## Leitura recomendada

1. [Instalacao](INSTALL.md): prepara ambiente, compila, instala e verifica o binario.
2. [Build e testes](BUILD.md): descreve build, testes offline e smokes reais.
3. [Flags e configuracao](FLAGS.md): lista comandos, flags e chaves de `config.toml`.

## Visao geral

Phenom Zig e um agente local de terminal feito em Zig com integracao C para sistema operacional, sockets e SQLite. Ele fornece:

- interface CLI/TUI;
- streaming para modelo local;
- renderer markdown append-only;
- auditoria operacional persistida em SQLite;
- recuperacao de sessao;
- tool loop auditavel;
- contratos de ferramentas;
- contexto model-visible tipado e limitado;
- mecanismos de evidencia e micro-contexto para trabalho com codigo.

O objetivo nao e apenas conversar com um modelo. O objetivo e manter um fluxo operacional confiavel em que cada acao relevante tenha trilha auditavel, contexto controlado e separacao clara entre o que e memoria, evidencia, dialogo e output bruto.

## Componentes principais

### CLI

Entrada principal em `src/main.zig` e parsing em `src/cli.zig`.

Comandos:

- `chat`: conversa interativa ou turno unico.
- `probe`: teste de conectividade com backend.
- `snapshot`: snapshot local.
- `version`: versao.
- `help`: uso resumido.

### TUI e renderer

O renderer fica em `src/render.zig`.

Caracteristicas:

- append-only;
- nao usa alternate screen;
- renderiza usuario, assistant, thinking, tools, diff, status e done line;
- suporta markdown progressivo;
- suporta tabelas markdown com quebra interna de celula;
- renderiza code blocks e diff fences;
- restaura sessao usando os mesmos eventos visuais do fluxo vivo.

O replay de sessao junta deltas de assistant por turno antes de renderizar. Isso evita que markdown salvo em fragments seja reprocessado de forma diferente na restauracao.

### HTTP local

Implementado em `src/http.zig`.

Backends:

- Ollama: `/api/chat`
- llama.cpp: `/completion`

`probe` nao chama inferencia:

- Ollama: `GET /api/tags`
- llama.cpp: `GET /`

O transporte atual e local-first, sem TLS. O codigo usa sockets C para conectar, ler e escrever.

### Reasoning

O filtro de reasoning separa blocos `<think>...</think>` da resposta final.

Regras praticas:

- thinking pode ser mostrado durante o turno vivo;
- thinking antigo nao e replayado no restore da TUI;
- se o modelo termina dentro de `<think>` sem resposta visivel, o CLI mostra status explicito;
- `--thinking auto` escolhe comportamento com base no tipo de prompt.

### SQLite audit

Implementado em `src/audit.zig`.

Banco padrao:

```text
.phenom-zig/phenom.db
```

Eventos comuns:

- `turn_start`
- `assistant_delta`
- `assistant_thinking_delta`
- `turn_done`
- `tool_start`
- `tool_event`
- `evidence`
- `session_context`
- `model_context`
- `model_context_budget`
- `token_usage`
- `persistent_promotion`

O audit e operacional. Ele nao e memoria persistente model-visible por si so.

### Recuperacao de sessao

A recuperacao usa:

- eventos recentes de dialogo;
- `SESSION_FOCUS`;
- FTS5/BM25 para busca explicita via `search_session`;
- resumo operacional de sessao longa;
- restore visual por ultimos turnos.

Pontos importantes:

- o prompt atual nao entra como contexto antigo;
- turnos falhos ou low-confidence sao ignorados em focos relevantes;
- fatos exatos antigos devem ser recuperados com `search_session` quando necessario;
- restore visual nao replaya reasoning antigo;
- markdown restaurado e renderizado como bloco consolidado por resposta.

### Contexto do modelo

O contexto model-visible e montado em blocos:

- system/header;
- contracts/tool schema;
- skills;
- memory;
- candidates;
- evidence;
- focus;
- dialogue;
- session;
- obligations;
- grounding;
- next_action.

Antes de enviar ao backend, o contexto passa por:

- rejeicao de marcadores brutos;
- medicao de bytes por bucket;
- evento `model_context_budget`;
- limite atual de 24 KiB.

Tokens reais sao registrados somente quando o backend fornece contadores reais. O projeto nao fabrica estimativa falsa de tokens.

### Contratos e tools

Contratos vivem em `src/contracts.zig` e perfis em `src/context_profile.zig`.

Principio:

```text
modelo escolhe contrato/tool; controller valida; executor so roda se permitido.
```

Ferramentas relevantes:

- `collect_evidence`: coleta evidencia destilada do workspace.
- `search_session`: busca eventos de sessao por termos escolhidos pelo modelo.
- `apply_patch`: aplica mutacao com micro-contexto fresco.
- `validate_syntax`: valida sintaxe operacional.
- `promote_context`: promove texto confirmado para `MEMORY.md` ou `SKILLS.md`.

Outputs brutos de ferramentas nao devem entrar diretamente no prompt. Eles devem ser destilados em evidencia, candidatos, micro-contexto ou audit metadata.

### Evidence e micro-contexto

`EvidencePacket v1` representa evidencia compacta e citavel.

Micro-contexto carrega:

- id;
- path;
- range;
- hash;
- budget;
- trecho editavel controlado.

Mutacoes seguras exigem micro-contexto fresco para reduzir risco de patch stale.

### Memoria persistente

Arquivos:

- `MEMORY.md`
- `SKILLS.md`

Esses arquivos so devem receber conteudo por promocao explicita. Eventos SQLite, tool outputs e dialogos comuns nao viram memoria automaticamente.

### Build system

`build.zig` define:

- executable `phenom`;
- install em `zig-out/bin/phenom`;
- install local em `~/.local/bin/phenom`;
- merge de config para `~/.config/phenom/config.toml`;
- `run`;
- `test`;
- smokes reais opt-in.

Veja [BUILD.md](BUILD.md).

## Fluxo de um turno

1. CLI carrega config.
2. Abre/cria `.phenom-zig/phenom.db`.
3. Registra `turn_start`.
4. Monta contexto inicial.
5. Audita budget do contexto.
6. Chama backend ou offline stub.
7. Filtra thinking e resposta visivel.
8. Se houver tool call, valida contrato e allowlist.
9. Executa tool permitida.
10. Destila resultado para evidencia/contexto.
11. Faz follow-up de modelo quando necessario.
12. Registra `turn_done` com qualidade operacional.
13. Atualiza `SESSION_FOCUS` quando aplicavel.

## Fluxo de restore

Ao abrir `phenom chat --session ID` sem `--prompt`:

1. Carrega historico de input.
2. Carrega ultimos turnos da sessao, nao apenas uma contagem bruta de eventos.
3. Ignora `assistant_thinking_delta`.
4. Junta deltas visiveis do assistant por turno.
5. Reenvia eventos ao renderer.
6. Mostra prompt interativo.

Isso preserva markdown e evita que thinking antigo esconda mensagens novas.

## Garantias importantes

- Suite offline nao depende de rede/modelo.
- Smokes reais sao opt-in.
- Raw output nao deve vazar para model-visible context.
- MEMORY/SKILLS sao separados do audit SQLite.
- Tool execution depende de contrato/allowlist.
- Sessoes usam SQLite local e podem ser buscadas por FTS.
- Renderer deve manter saida copiavel e append-only.

## Limitacoes atuais

- Backends suportados diretamente: Ollama e llama.cpp.
- Transporte HTTP local sem TLS.
- Nem toda familia de tools externa esta portada.
- Qualquer nova integracao deve respeitar contratos, contexto destilado e auditabilidade.
- Embeddings locais nao sao requisito atual; recuperacao usa SQLite/FTS/BM25 e contratos.

## Operacao diaria

Instalar:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast
```

Rodar:

```sh
phenom chat --session default
```

Turno unico:

```sh
phenom chat --session default --prompt "o que este projeto implementa?"
```

Testar:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build test
```

Probe:

```sh
phenom probe --backend ollama --host 127.0.0.1:11434
```

## Politica de contribuicao tecnica

Antes de alterar comportamento:

- leia o codigo local;
- preserve padroes existentes;
- adicione teste proporcional ao risco;
- rode teste focado e suite relevante;
- nao use backend real em teste offline;
- nao promova output bruto para contexto model-visible;
- documente mudancas operacionais quando alterarem uso, build ou flags.
