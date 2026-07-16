# A tentativa de criar um agente de AI focado em codiogo de baixo consumo de tokens

Data da auditoria: 2026-07-03

Este documento descreve friamente o que o Phenom CLI implementa hoje como agente de codigo, o que ele faz bem, o que esta parcial, o que esta quebrado em regra de negocio e o que ainda nao esta implementado de forma confiavel. A leitura foi feita a partir da source atual, principalmente:

- `src/agent.ts`
- `src/tools.ts`
- `src/use-cases/run-tool-loop.ts`
- `src/use-cases/build-inference-messages.ts`
- `src/tool-call-parser.ts`
- `src/agent-control/*`
- `src/tools/registrars/*`
- `src/memory/*`
- `src/lsp-diagnostics.ts`
- `src/tests/*`

## 1. Tese real do projeto

O Phenom CLI tenta ser um agente coder para modelos pequenos ou baratos, com baixo consumo de tokens. A ideia central nao e competir por "modelo mais inteligente", mas sim compensar a menor capacidade do modelo com:

- ferramentas compactas;
- evidencia destilada;
- contexto sob demanda;
- micro-contexto editavel;
- validacao operacional;
- memoria progressiva;
- parser tolerante a varios protocolos de tool call;
- controle de loops, duplicatas e respostas finais fracas.

A arquitetura pretendida e parecida com MVC:

- Model: o modelo de AI decide a intencao e chama ferramentas.
- View: CLI/TUI/renderizador mostra progresso, mensagens, raciocinio, tools e resultado.
- Controller: agente executa contratos, ferramentas, validacoes, memoria e politicas operacionais.

O ponto de regra de negocio mais importante: o controller nao deve inferir a direcao operacional por palavras-chave do prompt. Ele deve expor contratos e ferramentas, e o modelo deve escolher usando a descricao desses contratos. O agente pode validar protocolo, seguranca, estado e consistencia, mas nao deve transformar sinonimos ou palavras soltas em decisao de negocio.

## 2. Diagnostico executivo

O projeto tem bastante infraestrutura real de agente coder. Nao e um mock simples. Existem ferramentas de arquivo, git, comandos, browser, validacao, LSP, AST, RAG, memoria, micro-contexto e loop multi-turno com reparos. A base e suficiente para sustentar um agente coder de baixo custo.

Mas o produto ainda nao esta confiavel como produto porque a regra de negocio foi ficando espalhada em muitas camadas. Hoje ha uma mistura de:

- contrato model-driven;
- prompts com instrucoes fortes;
- filtros de tools;
- parser de protocolos;
- reparos automaticos;
- memoria persistente;
- validacao automatica;
- testes reais que historicamente cobravam sucesso funcional do app testado.

Essa mistura cria regressao facil: uma mudanca em contexto/memoria pode fazer o modelo parar de chamar tools, uma mudanca em browser_check pode transformar evidencia em falso erro, uma mudanca em parser pode converter um fragmento de protocolo em uma ferramenta inexistente, e uma mudanca em testes pode avaliar o modelo em vez do agente.

Resumo frio:

- O Phenom tem o esqueleto e muitas pecas de um agente coder.
- A direcao "baixo consumo de tokens" esta presente no design, mas ainda nao esta estabilizada.
- O produto sofre mais por acoplamento de fluxo do que por falta de features.
- O risco atual nao e "nao existe agente"; o risco e "existem varios agentes parciais disputando controle dentro do mesmo loop".

## 3. Funcionalidades implementadas

### 3.1 CLI, view e fluxo de interacao

Implementado:

- Entrada CLI em `src/index.ts`.
- Renderizacao de eventos via `src/cli-renderer.ts`, `src/stream-markdown-renderer.ts` e `src/tui/event-bus.ts`.
- Separacao de chunks de conteudo, reasoning e tool progress.
- Evento especifico de resposta final: `AGENT_FINAL_RESPONSE`.
- Suporte a stream ligado/desligado (`Agent.setStreamEnabled`).
- Modos operacionais: `chat`, `code`, `jarvis`, com normalizacao de aliases antigos.

O que acerta:

- A UI nao precisa conhecer as regras internas das tools.
- O agente emite progresso durante tool loop, validacao, compaction e execucao.
- Ha separacao razoavel entre conteudo final e raciocinio quando o parser consegue distinguir os canais.

O que erra/parcial:

- O fluxo visual ainda depende de muitos eventos laterais do loop. Isso dificulta saber se uma falha e de UI, parser, modelo ou controller.
- Algumas mensagens de reparo/controle entram como mensagens de usuario internas, o que pode poluir a semantica do historico.
- A view nao e o principal problema, mas ela reflete a complexidade do controller.

Nao implementado de forma madura:

- Um painel de auditoria unico por turno que explique: tools anunciadas, tools chamadas, tools executadas, resultados, memoria injetada, validacoes automaticas e motivo de parada.

### 3.2 Backend de modelo e formatos de chat

Implementado:

- Cliente Ollama/OpenAI compativel em `src/ollama-client.ts` e `src/api-client.ts`.
- Deteccao de backend/modelo em `src/backend-detector.ts` e `src/model-capabilities.ts`.
- Suporte a native tools quando o backend/modelo permite.
- Modo text-protocol quando native tools nao e confiavel.
- Detectores/parsers de formatos em `src/chat/*`, incluindo state machine, stream normalizer, dialect router e strip de artefatos.
- Estimativa e contagem de tokens, incluindo uso de `/tokenize` quando disponivel.

O que acerta:

- O projeto reconhece que modelos pequenos e backends diferentes quebram em formatos diferentes.
- Ha fallback para protocolo textual JSON.
- O sistema tenta manter o prompt prefix-stable para aproveitar KV cache.

O que erra/parcial:

- O parser aceita muitos formatos e isso aumenta superficie de falso positivo.
- Em teste real recente apareceu uma chamada interpretada como tool `content`, fora das tools anunciadas. Isso indica que algum fragmento de protocolo ou parametro pode estar sendo promovido indevidamente a tool.
- A normalizacao entre native tools, text protocol e mensagens persistidas ainda e fragil.

Nao implementado de forma madura:

- Uma camada unica de "ToolCallEnvelope" validada contra tools anunciadas antes de entrar no loop.
- Telemetria obrigatoria do parser: raw strategy, ferramenta extraida, origem da chamada, validacao contra schema, e motivo de rejeicao.

### 3.3 Agent/controller principal

Implementado:

- Classe `Agent` em `src/agent.ts`.
- Gerenciamento de sessao via `SessionManager` e `SessionBrain`.
- Montagem de system prompt dinamico com contexto de projeto.
- Exposicao de tools conforme modo e contrato.
- Loop principal delegado para `runToolLoopUseCase`.
- Injecao de contratos operacionais no prompt.
- Separacao entre ferramentas model-visible e internas.
- Persistencia de mensagens e save de sessao.

O que acerta:

- O agente nao e apenas um wrapper de chat. Ele tem estado, ferramentas, memoria, policy e validacao.
- O modo `chat` evita tools pesadas por padrao.
- O modo `code` expoe a superficie real de coding assistant.
- O prompt tenta orientar o modelo a usar tools em vez de pedir codigo ao usuario.

O que erra/parcial:

- `Agent.buildSystemPrompt` carrega muita regra operacional em texto. Isso e barato comparado a passar arquivos inteiros, mas ainda e fragil porque modelos pequenos podem ignorar ou confundir instrucoes.
- O metodo `getTurnToolDefinitions` hoje deriva um contrato sempre `model_driven`, mas a decisao pratica ainda depende de filtros e instrucoes manuais.
- A fronteira entre "contrato operacional" e "tool avulsa" ainda nao esta cristalina para o modelo.
- O controller ainda contem varias intervencoes automaticas e reparos que podem disputar com a intencao do modelo.

Nao implementado de forma madura:

- Um manifesto curto e versionado de contratos, com exemplos de schema sem exemplos de negocio.
- Um contrato de execucao explicitamente auditavel: "o modelo escolheu contrato X; o controller executou fases A/B/C; retornou evidencias Y/Z".

### 3.4 Contrato de intencao e exposicao de tools

Implementado em `src/agent-control/intent-tool-contract.ts`:

- `IntentKind = 'model_driven'`.
- `EvidencePolicy = 'model_driven'`.
- Lista de tools model-visible.
- Lista de internal context tools.
- Filtro que remove ferramentas internas, salvo `PHENOM_EXPOSE_INTERNAL_CONTEXT_TOOLS=1`.

Tools model-visible principais:

- `collect_evidence`
- `read_file`
- `path_exists`
- `list_dir`
- `write_file`
- `create_file`
- `apply_patch`
- `delete_file`
- `delete_dir`
- `run_validation`
- `validate_syntax`
- `run_tests`
- `run_code`
- `browser_check`
- `git_status`
- `git_diff`
- `git_log`
- `date`
- `get_session_context`
- `list_session_files`
- `set_operational_contract`

Tools internas bloqueadas por padrao:

- `build_task_context`
- `get_context`
- `project_map`
- `parse_ast`
- `grep_file`
- `search_code`
- `find_function`
- `extract_block`
- `who_calls`
- `rag_status`
- `rag_index`
- `rag_search`

O que acerta:

- O codigo removeu a classificacao por palavras-chave e assumiu explicitamente model-driven.
- A lista separa ferramentas de alto nivel de primitivas internas.
- O modelo ve `collect_evidence` como contrato operacional em vez de ser obrigado a conhecer `build_task_context`.

O que erra/parcial:

- `classifyIntent` nao classifica nada; retorna sempre `model_driven`. Isso e correto contra heuristicas, mas tambem significa que o sistema nao tem um contrato declarativo rico de intencao. Ele so tem uma superficie unica.
- A lista model-visible ainda e grande para modelo pequeno. Mesmo compactada, muita escolha pode degradar tool selection.
- O teste real de contratos ainda expôs que o parser pode produzir tool inexistente (`content`). Isso quebra a premissa "modelo so chama tool anunciada".

Nao implementado de forma madura:

- Niveis de tool surface escolhidos pelo proprio modelo via um contrato pequeno. Exemplo: o primeiro turno poderia expor apenas `set_operational_contract`, `collect_evidence`, `read_file`, `path_exists`, `list_dir`; depois o controller poderia abrir mutation/validation se o modelo declarar essa necessidade.
- Validacao hard de tool call contra allowlist anunciada antes de executar ou registrar como tool.

### 3.5 Tool system e normalizacao de argumentos

Implementado em `src/tools.ts`:

- Registro modular de tools por registrars.
- Adaptacao generica de aliases de argumentos.
- Normalizacao de wrappers comuns: `{ args: {...} }`, `{ arguments: {...} }`.
- Reparos estruturados para campos obrigatorios ausentes.
- Resultados com `recoverable`, `missingFields`, `normalizedArgs`, `normalizationNotes`.

O que acerta:

- Modelos pequenos frequentemente erram nomes de parametros; a adaptacao reduz falhas bobas.
- O erro de argumentos e retornado ao modelo como reparavel.
- A normalizacao fica no ToolSystem, nao espalhada no Agent.

O que erra/parcial:

- Algumas alias lists sao amplas demais. Exemplo: `content` tambem aparece como alias de `description` e `message`. Isso ajuda em casos reais, mas aumenta risco de interpretar estrutura ambigua.
- Normalizacao generica nao substitui schema validation completo. Ela conserta forma, mas nao garante semantica.
- Pode mascarar erro de prompt/schema: se o modelo chama quase certo, o sistema adapta; mas fica mais dificil saber se o contrato esta claro.

Nao implementado de forma madura:

- Validador JSON schema real por tool, com diferenca clara entre "alias aceito", "campo inferido" e "erro semanticamente impossivel".
- Métrica por tool: taxa de chamadas com normalizacao, taxa de reparo, taxa de repeticao apos reparo.

### 3.6 Ferramentas de filesystem e mutacao

Implementado em `src/tools/registrars/filesystem-tools.ts`:

- `read_file`
- `path_exists`
- `list_dir`
- `write_file`
- `create_file`
- `apply_patch`
- `delete_file`
- `delete_dir`
- backups em `.phenom-trash`
- diffs de escrita e patch
- sugestoes para ENOENT
- micro-contexto para arquivos escritos/lidos
- validacao de micro-context hash/range
- protecoes contra full rewrite indevido
- reparos para patch sem `replace`, range incoerente, contexto stale.

O que acerta:

- Esta e uma das partes mais fortes do projeto.
- `apply_patch` tem varios modos de edicao e boas mensagens de reparo.
- O sistema tenta evitar overwrite cego e document-sized replacement disfarçado.
- `read_file` e outputs de mutacao retornam contexto util ao modelo.

O que erra/parcial:

- A superficie de `apply_patch` ficou grande. Modelos pequenos podem errar entre `operations`, `search/replace`, range, contextId, full rewrite.
- Alguns fallbacks textuais/regex ainda existem dentro da ferramenta para localizar substituicoes. Isso e aceitavel como algoritmo de patch, mas nao deve virar inferencia de intencao.
- O modelo pode aplicar patch parcial, e isso nao e algo que a tool sozinha consegue resolver sem um plano/checklist mais explicito.

Nao implementado de forma madura:

- Um modo "atomic task patch" com checklist de arquivos/alteracoes esperadas declaradas pelo modelo e verificadas pelo controller.
- Uma representacao formal de "mutacao pretendida" separada do payload de patch.

### 3.7 Evidencia, contexto e micro-contexto

Implementado em `src/tools/registrars/context-tools.ts` e `src/tools/micro-context.ts`:

- `collect_evidence`
- `get_minimal_context` como alias de compatibilidade
- `build_task_context` interno
- `get_context` interno
- RAG quando indexado
- fallback lexical via `rg`
- AST summaries
- selecao de candidatos
- micro-contextos com id e sha256
- ranges editaveis
- evidencia de validacao
- integracao com `runLspDiagnostics`
- deteccao generica de mismatch de shape de dados JS
- output com `[EVIDENCE_DISTILLED]`, `[MICRO_CONTEXT]`, `[NEXT_ACTION]` e secoes compactas.

O que acerta:

- Esta e a feature que mais combina com o objetivo de baixo consumo de tokens.
- O modelo nao precisa ler projeto inteiro.
- O contexto pode ser edit-ready, com range, hash e path.
- A integracao LSP no collect_evidence aumenta muito a qualidade da evidencia.

O que erra/parcial:

- A qualidade do output ainda pode ser ruidosa. Se uma ferramenta retorna falso positivo, o modelo pequeno tende a perseguir o ruido.
- Naming historico inconsistente (`EVIDENCE_PACK`, `EVIDENCE_DISTILLED`, `ACTIVE_MICRO_CONTEXT`, `PERSISTENT_MEMORY`) pode confundir testes e prompt.
- `build_task_context` existe como tool real, mas e interna por regra. Isso esta correto para economia, mas exige que `collect_evidence` represente muito bem as estrategias disponiveis.
- O contrato `compact` ainda precisa ser completamente coerente com a memoria dinamica.

Nao implementado de forma madura:

- Um formato unico de evidencia com schema estavel, por exemplo `EvidencePacket v1`.
- Uma garantia formal de que todo achado importante vira anchor/self-contained entry antes de compactar.
- Testes que mecam "evidencia contem informacao suficiente para editar" sem exigir que o modelo edite corretamente.

### 3.8 Memoria dinamica e persistente

Implementado em `src/memory/*`:

- `PersistentEntry`
- `PersistentMemory`
- `MemoryOrchestrator`
- fases `explore`, `decide`, `act`, `verify`
- working memory durante exploracao
- persistent memory compacta
- stale paths apos mutacao
- observacao de tool results
- finalization blockers a partir de obrigacoes abertas
- runtime target memory
- failed attempts memory

Tambem existem memorias de sessao/projeto:

- `SessionBrain`
- `.MEMORY.md`
- `.SKILL.md`
- `MemoryWriter`
- `SkillStore`
- `LearningLoop`

O que acerta:

- O projeto reconhece que historico bruto mata modelos pequenos.
- A memoria por fase e a direcao certa.
- O orchestrator observa tools e tenta transformar resultados em entries compactas.
- Stale path e micro-context stale sao conceitos corretos para edicao segura.

O que erra/parcial:

- Ainda ha mais de uma memoria conceitual: session brain, persistent project memory, memory orchestrator, micro-context registry, operational run store. Isso dificulta entender qual fonte e autoritativa.
- A extracao de entries depende de parsing textual de outputs de tools.
- Se uma tool muda o formato de output, a memoria pode perder evidencia.
- A memoria pode bloquear final answer se interpretar uma obrigacao como aberta, mesmo que o modelo tenha seguido outro caminho valido.

Nao implementado de forma madura:

- Um event log tipado entre tools e memory orchestrator. Hoje muita coisa e texto.
- Uma politica clara de prioridade: tool result tipado > persistent entry > working memory > session brain > `.MEMORY.md`.
- Uma tela/audit obrigatoria da memoria injetada por turno.

### 3.9 Validacao, LSP e runtime

Implementado:

- `validate_syntax`
- `run_validation`
- `run_tests`
- `run_code`
- `browser_check`
- `start_background_command` e status de background em `utility-tools`
- LSP client stdio em `src/lsp-client.ts`
- registry de provedores LSP em `src/lsp-registry.ts`
- instalador LSP em `src/lsp-installer.ts`
- TypeScript/JavaScript via `ts.createLanguageService` em `src/lsp-diagnostics.ts`
- regras para JS puro nao ser typechecked sem `checkJs`
- validacao por escopo/projeto em `workflow-tools`.

O que acerta:

- A infraestrutura de validacao e acima da media para um CLI experimental.
- `run_validation` tenta descobrir o root correto, agrupar arquivos e usar o tipo de validacao certo.
- O browser flow existe e consegue coletar console errors, page errors, failed requests, HTTP errors, DOM snapshot e canvas snapshot como evidencia.
- Background service readiness e um recurso essencial para frontend real.

O que erra/parcial:

- Historicamente `validate_syntax` e `run_validation` geraram falsos positivos que desviaram o modelo.
- Browser/canvas deve ser evidencia, nao criterio de falha especifico de app. Isso foi corrigido parcialmente: canvas blank nao deve virar failure global.
- Runtime validation automatica pode ser correta em controller tests, mas em testes reais nao deve ser exigida como sucesso do modelo.
- LSP auto-install pode ser util, mas tambem cria custo/latencia e dependencia ambiental.

Nao implementado de forma madura:

- Uma politica de validacao por confidence: syntax error hard, type diagnostic scoped, browser error hard, canvas/dom snapshot informational.
- Um modo frontend runtime padrao: subir servidor, detectar porta real, rodar browser_check na URL certa, coletar erros, encerrar processo.
- Um protocolo tipado para tool `start_background_command` -> `runtimeTarget` -> `browser_check`.

### 3.10 Parser de tool calls e reparo de protocolo

Implementado em `src/tool-call-parser.ts` e `src/use-cases/run-tool-loop.ts`:

- JSON primario `{"type":"tool","toolName":"...","args":{...}}`
- JSON final `{"type":"final","content":"..."}`
- OpenAI-like `{ "name": "...", "arguments": ... }`
- nested `function`
- tags `<tool_call>`
- `[TOOL_CALLS]`
- `<function=...><parameter=...>`
- scan de JSON embedded
- limpeza de renderer artifacts
- deteccao de fragmentos quebrados
- prompts de reparo para:
  - tool JSON invalido;
  - reserved final tool;
  - reasoning-only output;
  - final answer generico;
  - duplicate tool calls;
  - missing args;
  - syntax repair;
  - failed edit.

O que acerta:

- Modelos pequenos e backends locais quebram muito protocolo; a tolerancia e necessaria.
- O loop nao aceita facilmente `done` apos tool result.
- Ha replay de resultado para duplicatas e reparo quando argumentos incompletos se repetem.

O que erra/parcial:

- Tolerancia demais pode virar falso positivo. A chamada `content` vista em teste real e um exemplo provavel.
- O parser nao parece validar cedo contra "tools anunciadas neste turno" antes de tratar como chamada real.
- Reparos sucessivos adicionam contexto e podem degradar modelos pequenos em loops longos.
- O modelo pode parar de emitir calls validas quando o contexto fica cheio de fragmentos de reparo.

Nao implementado de forma madura:

- Um AST/protocolo intermediario com estados: parsed, schema-valid, advertised, executable, rejected.
- Um limite adaptativo de reparos por classe com resumo compacto, nao prompts repetidos longos.
- Testes reais focados em "parser nao inventa tool" usando saidas reais capturadas.

### 3.11 RAG, AST e busca semantica

Implementado:

- `src/rag/*`
- `src/semantic-search.ts`
- `parse_ast`
- `find_function`
- `extract_block`
- `project_map`
- `who_calls`
- `get_context`
- fallback lexical.

O que acerta:

- Ha uma camada de descoberta de contexto alem de `read_file`.
- O design permite economizar tokens ao recuperar trechos relevantes.
- As ferramentas internas podem ser usadas por contratos maiores sem inflar a tool surface do modelo.

O que erra/parcial:

- RAG e AST estao parcialmente escondidos atras de `collect_evidence`, mas ainda existem como tools diretas em alguns modos/envs.
- Se a indexacao RAG nao existir, o fallback lexical precisa ser muito bom.
- A relacao entre `get_context`, `build_task_context`, `collect_evidence` e `get_minimal_context` ainda carrega historia/compatibilidade demais.

Nao implementado de forma madura:

- Um unico contrato de contexto com estrategias internas selecionaveis por parametro, sem expor nomes legados ao modelo.
- Métrica de custo/beneficio: tokens gastos por estrategia vs precisao da evidencia.

### 3.12 Git e comandos

Implementado:

- `git_status`
- `git_diff`
- `git_log`
- `git_add`
- `git_commit`
- `run_code`
- `start_background_command`
- guards contra comandos destrutivos obvios
- cwd limitado ao project root para utility tools.

O que acerta:

- Git e comando de shell sao essenciais para um coder agent.
- Ha tentativa de limitar dano e truncar outputs grandes.
- Background command com readiness e reuso de servico e uma boa base para frontend.

O que erra/parcial:

- `run_code` continua sendo uma ferramenta de alto risco e alto ruido para modelos pequenos.
- O limite de comandos destrutivos e regex-based. Isso e aceitavel como safety guard, mas nao cobre todos os casos.
- O fluxo de servidor/browser ainda precisa virar contrato operacional claro, nao improviso por prompt.

Nao implementado de forma madura:

- Sandbox operacional por comando com politica explicita.
- Captura padrao de processos iniciados para cleanup no fim do turno/teste.

### 3.13 Memoria de skills e aprendizado

Implementado:

- `.MEMORY.md`
- `.SKILL.md`
- `MemoryWriter`
- `SkillStore`
- `LearningLoop`
- tools `update_memory`, `record_skill`, `record_skills`, `read_memory`, `read_skills`.

O que acerta:

- A intencao de transformar experiencia em memoria reutilizavel e correta.
- O prompt evita injetar `.MEMORY.md` e `.SKILL.md` sempre, preservando cache.

O que erra/parcial:

- Aprendizado automatico pode gravar padroes ruins se o criterio de sucesso nao for confiavel.
- Ainda nao esta claro quando uma skill deve ser considerada validada.
- Mais uma memoria aumenta a chance de contradicao com persistent memory dinamica.

Nao implementado de forma madura:

- Validador de skill baseado em evidencia real: mutacao, validacao, teste ou reproducao.
- Separacao entre memoria de projeto, memoria de sessao e skill reutilizavel.

### 3.14 Testes

Implementado:

- Testes unitarios de parser, tools, LSP, memory, renderer.
- Testes de integracao para tool loop e use cases.
- Testes reais com modelo:
  - `test-real-model-acceptance`
  - `test-real-inference`
  - `test-real-tool-loop-stress`
  - `test-real-tool-loop-medium-complex`
  - `test-real-intent-tool-contracts`
  - `test-real-micro-context-flow`
  - `test-real-micro-context-natural-flow`
  - `test-real-evidence-pack-flow`

Estado observado nesta auditoria:

- `npx tsc --noEmit`: passou.
- `npm run test:use-cases`: 93/93 passou.
- `npm run test:tool-registrars`: 72/72 passou.
- Testes reais foram interrompidos por mudanca de foco; um deles ja mostrou falha util: tool `content` chamada sem estar anunciada.

O que acerta:

- A suite controlada cobre bastante infraestrutura.
- Existem testes reais, o que e essencial para agente com modelo pequeno.
- Ha testes especificos para "nao inferir contrato por texto" e para preservar tool round-trip.

O que erra/parcial:

- Muitos testes reais historicamente cobravam que o modelo resolvesse o app seeded. Isso mede capacidade do modelo, nao confiabilidade do agente.
- Teste real deve validar o fluxo: tool advertised, tool called, tool result returned, evidence injected, memory compacted, parser intacto, final answer nao generico.
- Exigir que `radiusPx` seja corrigido, canvas desenhe 3 arcos ou HTML tenha translucidez transforma teste de agente em benchmark de raciocinio do modelo.

Nao implementado de forma madura:

- Suite real de infraestrutura separada da suite de capacidade do modelo.
- Fixtures de saida real do modelo para parser/regressao offline.
- Relatorios padronizados por teste real com tool surface, prompt chars, memory blocks, parser strategy, calls e results.

## 4. O que o Phenom acerta hoje

### 4.1 Ele tem uma superficie real de coding assistant

O projeto implementa o basico que um agente coder precisa:

- ler arquivos;
- listar diretorios;
- checar paths;
- escrever/criar arquivos;
- aplicar patches;
- executar comandos;
- rodar validacao/testes;
- usar git;
- subir e observar processos;
- checar browser;
- manter sessao;
- preservar memoria;
- recuperar contexto.

Isso nao esta faltando.

### 4.2 Ele tenta economizar tokens do jeito certo

As decisoes corretas:

- nao injetar `.MEMORY.md` e `.SKILL.md` sempre;
- manter system prompt mais estavel para KV cache;
- compactar historico;
- usar `collect_evidence` em vez de read full project;
- usar micro-contexto editavel;
- truncar outputs de comandos;
- compactar tool schema;
- separar internal tools de model-visible tools.

### 4.3 Ele reconhece que modelos pequenos precisam de reparo operacional

O loop trata:

- JSON quebrado;
- resposta final generica;
- reasoning-only;
- duplicata de tool;
- argumentos incompletos;
- patch falho;
- validacao falha;
- contexto estourado.

Isso e necessario para modelos pequenos.

### 4.4 Ele ja tem validacao mais forte que muitos prototipos

LSP, TypeScript LanguageService, validao por projeto, syntax validator, browser_check e run_tests formam uma base boa. O problema atual e calibrar ruido e escopo, nao ausencia de validacao.

### 4.5 Ele removeu parte importante das heuristicas de intencao

`intent-tool-contract.ts` hoje declara `model_driven`. Isso respeita a regra de negocio central: o modelo escolhe, o controller executa contratos.

## 5. O que o Phenom erra hoje

### 5.1 Ha excesso de caminhos para a mesma funcao

Contexto pode vir de:

- `collect_evidence`
- `get_minimal_context`
- `build_task_context`
- `get_context`
- `read_file`
- RAG
- AST
- grep/search
- memory orchestrator
- session brain

Isso e poderoso, mas a regra de negocio fica dificil de manter. Para o modelo pequeno, muitas alternativas podem parecer competidoras. Para o controller, muitos formatos de saida precisam ser parseados.

### 5.2 Contrato operacional ainda e mais prompt do que API

`set_operational_contract` existe, mas muito comportamento ainda depende de instrucoes no system prompt:

- quando usar collect_evidence;
- quando declarar mutation;
- quando criar arquivo apos path_exists false;
- quando validar;
- quando perguntar ao usuario.

Isso nao e errado por si so, mas e menos robusto que um contrato de fases com retorno tipado.

### 5.3 Parser tolerante demais pode inventar ferramenta

A falha `content` e grave em regra de negocio. Se uma palavra/parametro vira nome de tool, o agente deixa de ser confiavel. O minimo esperado:

- tool call extraida deve existir na allowlist anunciada;
- se nao existir, deve virar protocol repair, nao tool result normal;
- o audit deve mostrar raw parse strategy e trecho responsavel.

### 5.4 Testes reais confundiram fluxo do agente com competencia do modelo

Esse foi um dos maiores desvios. Um agente coder deve ser testado em duas camadas:

- Infraestrutura: o agente expoe tools certas, executa, retorna evidencia, preserva round-trip, valida protocolo, compacta contexto.
- Capacidade do modelo: o modelo resolve tarefas reais.

Se um teste de infraestrutura falha porque o modelo nao desenhou 3 planetas, o teste esta medindo a coisa errada.

### 5.5 Memoria tem muitas fontes autoritativas

O projeto tem:

- historico da sessao;
- SessionBrain;
- MemoryOrchestrator;
- PersistentMemory;
- `.MEMORY.md`;
- `.SKILL.md`;
- micro-context registry;
- operational run store.

Sem uma hierarquia formal, o sistema pode carregar contexto redundante, stale ou contraditorio.

### 5.6 Validacao automatica pode virar ruido

Validar depois de mutar e correto como controller behavior. Mas:

- nem todo diagnostico deve bloquear finalizacao;
- nem toda evidencia de browser e falha;
- JS browser puro nao deve receber erro TS irrelevante;
- testes reais nao devem exigir que o modelo tenha chamado validacao, se a camada controlada ja testa a regra automatica.

### 5.7 A complexidade atual ameaca o objetivo de baixo custo

O objetivo e baixo consumo de tokens, mas reparos sucessivos, memoria renderizada, instrucoes longas, schemas amplos e outputs de tools podem crescer rapido. A arquitetura quer economizar tokens; a implementacao ainda pode gastar tokens corrigindo seu proprio fluxo.

## 6. O que esta parcialmente implementado

### 6.1 Model-driven MVC

Existe:

- intencao model-driven;
- tools/contratos visiveis;
- controller executando;
- CLI como view.

Falta:

- contrato operacional tipado e auditavel;
- validacao de tool call contra contrato por turno;
- separacao forte entre "decisao do modelo" e "mitigacao do controller".

### 6.2 Contratos como tools

Existe:

- `collect_evidence` como contrato operacional;
- `set_operational_contract` como declaracao de gates;
- `run_validation` como contrato de validacao.

Falta:

- manifesto pequeno de contratos;
- documentacao de fases internas;
- retorno tipado alem de texto;
- capacidade de executar parte do contrato sem obrigar suite inteira.

### 6.3 Memoria dinamica

Existe:

- PersistentMemory;
- MemoryOrchestrator;
- working memory;
- compaction;
- stale paths.

Falta:

- event log tipado;
- sumarizacao provada;
- regra de prioridade entre memorias;
- testes reais orientados a memoria sem exigir sucesso funcional do modelo.

### 6.4 Runtime/browser frontend flow

Existe:

- start background;
- readiness;
- browser_check;
- DOM/canvas snapshot;
- console/page/request/http diagnostics.

Falta:

- fluxo canonico ponta a ponta;
- deteccao de porta real sempre confiavel;
- cleanup padrao;
- separacao estrita entre "evidencia visual" e "erro".

### 6.5 Coleta de evidencia com LSP

Existe:

- `collect_evidence` chama LSP diagnostics;
- TypeScript/JS bem mais calibrado;
- provedores externos.

Falta:

- schema tipado de finding;
- classificacao de severidade/ruido;
- garantias de que falso positivo nao sequestra o loop.

## 7. O que nao esta implementado de forma suficiente

1. Gate universal de tool call anunciada.

   Toda tool call, nativa ou textual, deveria ser validada contra a lista exata de tools anunciadas no turno. Tool inexistente deve ser protocol error reparavel, nunca execucao.

2. Relatorio de auditoria por turno.

   Cada turno deveria registrar:

   - prompt chars/tokens;
   - tools anunciadas;
   - parser strategy;
   - tool calls extraidas;
   - allowlist validation;
   - args normalizados;
   - tool results;
   - memory blocks injetados;
   - finalization blockers;
   - motivo de parada.

3. Contrato tipado de evidencia.

   `EVIDENCE_DISTILLED` deveria ter schema estavel, mesmo que renderizado como texto. Exemplo: findings, anchors, obligations, nextActions, stalePaths, confidence.

4. Separacao formal entre teste de agente e teste de modelo.

   Testes reais de agente devem passar se o fluxo funcionou, mesmo que o modelo nao resolva o bug. Benchmarks de modelo podem existir, mas em outra suite.

5. Politica de ruido de validacao.

   Diagnosticos precisam de categoria:

   - blocking;
   - warning;
   - informational;
   - evidence-only.

6. API de contratos operacionais.

   `collect_evidence` hoje faz muito. Isso pode continuar, mas precisa se declarar melhor:

   - quais estrategias internas existem;
   - quais parametros controlam escopo;
   - que parte do contrato foi executada;
   - qual contexto foi liberado ao modelo.

7. Fonte unica de memoria operacional.

   O projeto precisa decidir qual memoria e autoritativa no turno ativo. As demais devem ser inputs ou outputs, nao concorrentes.

8. Metrica de baixo consumo.

   O projeto ainda nao mede de forma padrao:

   - tokens por turno;
   - tokens de tool schema;
   - tokens de memoria;
   - tokens de evidence;
   - tokens gastos em reparos;
   - economia vs read_file completo.

## 8. Lista minusiosa de features por status

### Implementado e razoavelmente forte

- Registro modular de tools.
- Filesystem tools.
- Atomic patch com diff.
- Backup antes de mutacao destrutiva.
- ENOENT com sugestoes.
- Micro-context id/hash.
- Session persistence.
- Git tools.
- Command execution com truncamento.
- Background process registry.
- Browser diagnostics basico.
- TypeScript/JS diagnostics.
- External LSP registry/installer/client.
- Context compaction.
- Tool round-trip sanitization.
- Parser multi-dialeto.
- Duplicate tool repair/replay.
- Final answer guard apos tools.
- Tests unitarios e integracao.

### Implementado, mas instavel ou incompleto

- Model-driven operational contract.
- collect_evidence como contrato unico.
- MemoryOrchestrator.
- PersistentMemory summarization/compaction.
- Runtime/browser frontend flow.
- Tool-call parser em casos reais de modelo pequeno.
- Native tools vs text protocol parity.
- Validacao automatica apos mutacao.
- Learning loop/skills.
- RAG como fallback de contexto.
- Testes reais.

### Implementado, mas com risco de regra de negocio

- Normalizacao generica ampla de argumentos.
- Prompts longos com instrucoes operacionais.
- Reparos automaticos repetidos.
- Validacao bloqueante por diagnostico textual.
- Interpretacao de tool result textual pela memoria.
- Exposicao simultanea de muitas tools model-visible.

### Nao implementado ou insuficiente

- Allowlist hard por turno para tool call extraida.
- Schema tipado de EvidencePacket.
- Audit trail obrigatorio por turno.
- Separacao definitiva entre testes de fluxo e benchmarks de modelo.
- Contrato formal de fases para collect_evidence.
- Hierarquia autoritativa de memorias.
- Metricas de custo/token por feature.
- Runtime frontend flow canonico e deterministicamente testavel.
- Parser quarantine para tool inexistente.
- Testes offline com fixtures de saidas reais problemáticas.

## 9. Como os testes deveriam caminhar daqui pra frente

### 9.1 Testes de infraestrutura do agente

Devem validar:

- tools anunciadas correspondem ao contrato;
- modelo nao recebe internal tools quando nao deve;
- tool call extraida existe na allowlist;
- chamada invalida vira reparo, nao execucao;
- tool result sempre segue assistant tool_call;
- nao ha orphan tool message;
- argumentos ausentes geram repair estruturado;
- collect_evidence retorna evidence compacta;
- micro-contexto e visivel ao modelo;
- memoria nao duplica indefinidamente;
- compaction preserva anchors;
- validacao automatica e registrada quando controller a executa;
- browser_check retorna evidencia sem transformar snapshot em erro de negocio;
- final answer apos tool nao pode ser generico.

Nao devem validar:

- se o modelo corrigiu exatamente um bug seeded;
- se o HTML tem exatamente um estilo esperado;
- se canvas desenhou N arcos;
- se o modelo escolheu uma unica ferramenta especifica quando havia ferramentas validas alternativas;
- se a resposta final contem todos os tokens quando a evidencia ja apareceu corretamente em tool result.

### 9.2 Benchmarks de capacidade do modelo

Podem validar:

- aplicou patch completo;
- resolveu bug frontend;
- interpretou evidencia;
- rodou validacao certa;
- sintetizou resposta final perfeita.

Mas devem ficar separados da suite de infraestrutura. Se falharem, o resultado e "modelo/estrategia insuficiente", nao "agente quebrado".

## 10. Recomposicao recomendada do produto

Ordem pragmatica:

1. Congelar features novas.

   Nao adicionar novo contrato, nova memoria ou nova heuristica ate estabilizar o loop principal.

2. Criar gate de tool call anunciada.

   Antes de executar qualquer tool, validar nome contra tools do turno. Isso atacaria diretamente a falha `content`.

3. Criar audit por turno.

   Sem audit, cada falha real vira discussao subjetiva.

4. Tipar EvidencePacket internamente.

   Renderizar texto para o modelo, mas preservar objeto estruturado para memoria/testes.

5. Reduzir tool surface inicial.

   Expor poucos contratos primeiro. Abrir mutation/validation/browser quando o modelo declara via `set_operational_contract` ou quando a tarefa ja esta claramente em modo code com pedido operacional explicito no historico.

6. Separar tests:

   - `test:agent-infra`
   - `test:real:agent-flow`
   - `test:real:model-capability`

7. Consolidar memoria.

   MemoryOrchestrator deve ser a memoria operacional do turno. `.MEMORY.md` e skills entram sob demanda, nao como concorrentes.

8. Definir politica de validacao.

   Cada diagnostico precisa de severidade e efeito: bloquear, orientar, informar.

9. Medir tokens.

   Toda mudanca deve mostrar impacto em tokens do prompt, schema, memoria, evidencia e reparos.

## 11. Conclusao fria

O Phenom CLI nao esta vazio nem irrelevante. Ele tem implementacoes reais de agente coder que muitos prototipos nao tem: patch atomico, evidencia compacta, micro-contexto, LSP, browser diagnostics, memoria, parser multi-protocolo e reparos de loop.

Mas ele tambem nao esta pronto como produto confiavel. A principal quebra nao e falta de feature; e falta de eixo unico de regra de negocio. O projeto precisa parar de medir sucesso pelo app de teste resolvido e voltar a medir o que importa para um agente: ferramenta anunciada, chamada valida, execucao correta, evidencia util, memoria compacta, validacao calibrada e finalizacao coerente.

Se a arquitetura for estabilizada nesse eixo, o projeto ainda faz sentido: um agente coder de baixo consumo para modelos pequenos, onde o controller compensa a fraqueza do modelo com ferramentas e contexto bem desenhados. Se continuar adicionando camadas sem contrato tipado e auditavel, o custo de reparo e ruido vai superar a economia de tokens que o projeto tenta obter.
