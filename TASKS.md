# TASKS.md - Devlog da refatoracao massiva do Phenom CLI

Data de inicio: 2026-07-04

Fonte primaria: `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md`

Fonte operacional: `doc/banchmark/phenom_latest.txt`

Fonte de referencia/rollback reverso: `../phenom-cli-ts`

Decisao arquitetural adicionada em 2026-07-04, agora marcada como referencia comparativa: o projeto final poderia ser reescrito do zero em Rust. A arvore TypeScript atual e `../phenom-cli-ts` passam a ser referencias de comportamento, prova e migracao, nao a base final de implementacao.

Motivacao:

- TS provou a ideia, mas trouxe baixa previsibilidade em producao para este tipo de CLI agente.
- O renderer/TUI em TS apresenta glitches e exige muita logica defensiva.
- O produto final precisa de terminal/TUI robusto, append-only confiavel, subprocess/sandbox previsivel, IO forte, SQLite/control stores e binario distribuivel.
- Rust oferece melhor base para CLI/TUI, async IO, filesystem, subprocess, diff/patch, SQLite, tipagem forte e distribuicao.

Regra preservada: as tasks existentes continuam validas como requisitos de produto e criterios de aceite. Qualquer port do TS deve ser tratado como migracao seletiva de comportamento, nao copia estrutural.

Decisao atual revisada em 2026-07-08: o Phenom em Zig + C e produto final em fase de construcao, nao uma prova rapida, base descartavel ou implementacao relaxada. Esta formulacao e regra operacional porque linguagem de baixa exigencia faz proximas inferencias tratarem o projeto com desleixo, sem validacao suficiente e fora do alinhamento global. A motivacao tecnica e filosofica: controle maior do runtime, arquitetura 100% pertencente ao Phenom, menor dependencia de crates/frameworks, terminal previsivel e possibilidade de otimizar as primitivas necessarias. Rust continua como referencia comparativa, mas o alvo atual de produto e Zig + C.

Regra do produto Zig + C:

- Core em Zig.
- Interop C para primitivas maduras, especialmente SQLite e futuramente TLS/HTTP publico/tree-sitter quando necessario.
- C++ fica fora do core; se inevitavel, deve entrar por adapter C fino.
- HTTP baixo nivel e aceitavel para endpoints locais controlados como Ollama e llama.cpp.
- TLS/crypto nao devem ser reinventados.
- A arquitetura do agente, contratos, contexto, renderer, audit, EvidencePacket e tool gate pertencem ao Phenom.

## Regra de trabalho

Este arquivo e o devlog operacional da refatoracao. Nenhuma feature abaixo deve ser implementada antes de existir teste que descreva o comportamento esperado. Cada task deve ser pequena o suficiente para gerar um patch revisavel, com escopo limitado, evidencia rastreavel e criterio de aceite objetivo.

Principios obrigatorios:

- Teste antes da feature.
- Uma task deve tocar o menor numero possivel de arquivos.
- Toda task deve conter a secao `Passos de implementacao`. Task sem essa secao esta incompleta e nao pode ser executada.
- Os passos devem dizer como a task sera feita no codigo: teste, arquivos, helpers/APIs, integracao, validacao e checagem de impacto no modelo.
- Mudancas de contrato devem ser medidas por testes de infraestrutura, nao por sucesso subjetivo do modelo.
- Testes reais de modelo devem ficar separados dos testes de fluxo do agente.
- O controller nao deve decidir regra de negocio por palavras-chave do prompt.
- O modelo deve escolher usando contratos e ferramentas anunciadas.
- O controller pode validar protocolo, seguranca, estado, consistencia, memoria e parada.
- O projeto deve respeitar limitacoes do modelo pequeno com contexto compacto, evidencia destilada e reparo operacional, sem reduzir desnecessariamente sua autonomia.
- Status de task deve ser honesto: `done` so pode ser usado quando a feature cumprir 100% do objetivo descrito, com testes e smokes pertinentes. Implementacao parcial deve ser marcada como `partial`, `pending-urgent` ou `blocked`, explicando quais partes foram entregues, quantas partes faltam e o que impede considerar a feature plenamente utilizavel.
- Mensagem final de task nao pode dizer "corrigido", "pronto" ou "implementado" sem separar: comportamento provado, comportamento parcial, smoke real executado, smoke real pendente e riscos residuais.

## Invariantes de confiabilidade para uso real

Estas invariantes sao obrigatorias. Uma feature so pode ser considerada pronta se nao quebrar nenhuma delas, e as fases de aceite precisam provar isso por teste ou replay auditavel.

1. Tool nao anunciada nunca executa.
2. Contexto bruto nao vaza para o modelo.
3. MEMORY/SKILLS nao competem com storage operacional.
4. News nao depende de prompt improvisado.
5. Patch em codigo nao aplica sobre contexto stale.
6. Falha de modelo nao parece falha de infraestrutura.
7. Cada turno consegue ser auditado e reproduzido.

Regra de aceite: se uma task toca parser, tools, contexto, memoria, storage, News, patch, validacao, modelo real ou audit, ela deve registrar no devlog quais invariantes afeta e qual teste/replay prova que continuam verdadeiras.

## Arquitetura canonica de contexto

Correcao de direcao: o objetivo nao e criar varias memorias nem varias fontes autoritativas de contexto. O objetivo e exatamente o contrario.

No Phenom CLI, qualquer tool que colete dados deve ser tratada como meio de coleta, nao como fonte alternativa de contexto. O resultado bruto da tool deve ser serializado, filtrado, comprovado e transformado em contexto destilado minimo, com evidencia intrinseca e tangivel para o modelo.

Modelo conceitual correto:

1. Tool coleta dado bruto.
2. Controller normaliza o resultado da tool em evento tipado.
3. Destilador extrai somente evidencia util, verificavel e proporcional a tarefa.
4. Evidencia vira `EvidenceEntry`/`EvidencePacket`, com path, range, comando, status, trecho, erro, hash ou qualquer prova objetiva aplicavel.
5. Modelo recebe apenas o contexto destilado necessario para agir.
6. Audit guarda o bruto/metadata suficiente para depuracao, mas nao injeta isso no prompt por padrao.

Unicas fontes persistentes de contexto fora da evidencia do turno:

- `MEMORY.md` / `.MEMORY.md`: memoria pratica entre sessoes e tasks do projeto/diretorio vigente. Guarda fatos uteis, decisoes, insights, estado de tarefas, arquitetura local e informacoes recorrentes que ja foram verificadas.
- `SKILLS.md` / `.SKILL.md`: regras absolutas, preferencias do usuario e padroes operacionais confirmados pela interacao. Exemplo: se o usuario diz/verifica "nunca use any", isso vira regra persistente em skills.

Regra de ouro: RAG, AST, grep, read_file, browser_check, LSP, run_validation, git, shell, session files e qualquer outra tool nao sao contexto por si. Sao coletores. A unica coisa que o modelo deve receber deles e evidencia destilada, com prova suficiente para confiar e agir.

### Fluxo exato de contexto

Este fluxo e obrigatorio para implementacao:

```text
tool result bruto
  -> ToolEvent interno
  -> EvidenceEntry destilada
  -> EvidencePacket selecionado por budget
  -> ModelTurnContext renderizado
  -> mensagem compacta ao modelo
```

O que fica somente no agente:

- raw tool outputs;
- full file reads;
- `rg --json` bruto;
- parser strategies detalhadas;
- audit trail completo;
- token accounting;
- candidate EvidenceEntries antes de filtro;
- evidencias rejeitadas;
- decisoes de fallback;
- updates candidatos de MEMORY/SKILLS ainda nao persistidos.

O que pode ir ao modelo:

- `[TURN_CONTEXT v1]` com task/mode/budget;
- `[CONTRACTS]` compacto;
- `[SKILLS]` somente se existir em `SKILLS.md`/`.SKILL.md` ou se regra explicita acabou de ser confirmada para aplicacao;
- `[MEMORY]` somente se existir em `MEMORY.md`/`.MEMORY.md` ou entrada ja promovida;
- `[EVIDENCE]` derivado do turno atual;
- `[OBLIGATIONS]` curtas;
- `[NEXT_ACTION]` quando houver uma acao obvia e segura.

Regra anti-erro: se nao existe MEMORY/SKILLS persistido/promovido, o bloco nao deve aparecer. Tool output recem-coletado e evidencia do turno, nao MEMORY.

### Perfis de contexto por dominio

Correcao de direcao adicionada em 2026-07-04: o Phenom CLI nao e "full minimal context" em todos os fluxos. Baixo consumo de tokens e micro-contexto sao estrategias, nao uma regra universal de produto.

O contexto minimo funciona bem para fluxo de codigo e tarefas relacionadas porque o alvo costuma ser localizado: arquivo, simbolo, range, diff, diagnostico, stack trace ou trecho editavel. Nesses casos, micro-contexto com path/range/hash reduz tokens e aumenta seguranca de patch.

Mas existem dominios em que contexto minimo prejudica a qualidade operacional:

- News/noticias: precisa de catalogo persistente de fontes, metadados de localidade, score de confianca, RSS/API/homepage, filtros por autenticacao, cache, deduplicacao, ranking e preferencias. O modelo nao deve receber tudo isso bruto, mas o agente precisa operar sobre esse volume internamente.
- PDFs, logs e leituras em massa: precisam de indexacao, segmentacao, agregacao, estatisticas, busca e resumos hierarquicos. Um micro-trecho isolado pode perder o padrao global.
- Pesquisa web/RAG ampla: precisa de fan-out controlado, cache, ranking, confiabilidade de fonte e citacoes.

Portanto, o plano correto e ter `ContextProfile` por dominio:

- `code_micro`: evidencia compacta, editavel, orientada a path/range/hash.
- `mass_read`: ingestao/indexacao interna, chunks e resumo hierarquico antes de resposta.
- `news_operational`: catalogo persistente de fontes + coleta/ranking/deduplicacao; output ao modelo/formatter e um dossie estruturado, nao micro-contexto.
- `runtime_diagnostics`: sinais de processo/browser/LSP convertidos em evidencias objetivas.

Regra revisada: tools continuam nao sendo fontes autoritativas diretas para o modelo, mas nem toda coleta deve ser reduzida a micro-contexto. O controller escolhe o perfil operacional. O modelo recebe o produto adequado ao dominio: micro-evidencia para codigo, dossie estruturado para news, resumo hierarquico para leitura massiva, diagnostico para runtime.

Impacto sobre MEMORY/SKILLS: `MEMORY.md` e `SKILLS.md` continuam sendo as unicas fontes persistentes textuais visiveis ao modelo. Bancos/cache/catalogos como `trusted_sources` sao infraestrutura operacional do agente, nao memoria conversacional. Eles podem alimentar contratos especificos, mas nao viram bloco `[MEMORY]`.

## Arquitetura canonica de contratos e estrategias

Contratos devem ser tratados como endpoints de API para o modelo. Estrategias devem ser tratadas como funcoes/opcoes internas desse endpoint. Implementacoes sao metodos internos do controller/tool system que podem ser compostos livremente sem virar tool surface permanente.

Modelo conceitual correto:

1. Contrato = endpoint model-visible.
   Exemplo: `collect_evidence`, `mutate_file`, `validate_work`, `inspect_runtime`.
2. Estrategia = opcao declarativa dentro do contrato.
   Exemplo: `collect_evidence({ strategy: "symbol" })`, `collect_evidence({ strategy: "runtime_error" })`, `validate_work({ strategy: "syntax" })`.
3. Implementacao = metodos internos que o controller escolhe e compoe.
   Exemplo: estrategia `symbol` pode chamar `grep`, AST summary, `read_file` rangeado e hash de micro-contexto.
4. Saida = sempre evidencia destilada ou resultado estruturado.
   O modelo nao recebe a arvore de chamadas internas; recebe o resultado minimo comprovavel.

Regra de negocio: o modelo pode exigir um contrato e pode sugerir estrategia, mas nao deve ficar preso a um fluxo rigido. O controller pode:

- aceitar estrategia explicita quando ela for valida;
- trocar para fallback quando a estrategia nao for aplicavel;
- combinar estrategias quando o custo for baixo e a evidencia exigir;
- rejeitar estrategia inexistente com repair curto;
- registrar no audit qual estrategia foi pedida, qual foi executada e por que.

Anti-engessamento:

- Contrato nao deve impor fases longas obrigatorias.
- Estrategia nao deve virar estado persistente permanente.
- Surface nao deve abrir dezenas de tools internas.
- O modelo nao deve precisar conhecer `grep_file`, `rag_search`, `parse_ast`, LSP internals ou browser internals para pedir evidencia.
- O controller nao deve escolher direcao por keyword do prompt; ele apenas executa o contrato chamado e adapta a estrategia com base em disponibilidade, custo e evidencia.

Forma de API desejada para o modelo:

```json
{
  "type": "tool",
  "toolName": "collect_evidence",
  "args": {
    "goal": "find where tool calls are executed",
    "strategy": "symbol",
    "targets": ["runToolLoopUseCase", "executeToolWithEvents"],
    "budget": "small"
  }
}
```

O modelo informa intencao operacional e restricoes. O controller decide se usa grep, AST, read_file rangeado, RAG ou combinacao, e retorna `EvidencePacket`.

Relação com o benchmark: `phenom:latest` tem `tool_calling 90%`, `agentic_tasks 100%` e `logical_reasoning 100%`. Isso sugere que o modelo suporta contratos declarativos e escolha de estrategia simples. O ponto fraco nao e "incapaz de agir"; o risco e sobrecarregar o modelo com ferramentas internas, estados persistentes e escolhas excessivas. Portanto, a API deve ser pequena, estrategias devem ser nomes curtos e opcionais, e o controller deve fazer a composicao dinamica.

## Cobertura real do audit

Resposta franca: a primeira versao deste `TASKS.md` nao podia ser considerada "100% resolvida". Ela listava fases corretas, mas ainda estava generica em pontos importantes: nao explicitava a motivacao de cada problema, nao provava cobertura item a item contra a auditoria e nao separava claramente "alvo final" de "primeiro patch seguro". Esta secao corrige essa falha de planejamento.

Definicao de "100% alinhado com o audit":

- Cada problema-raiz do audit tem uma resolucao planejada.
- Cada resolucao tem alvo final mensuravel.
- Cada alvo final esta quebrado em tasks pequenas.
- Cada task tem teste antes da feature.
- Cada feature que altera comportamento do agente tem criterio de aceite em infraestrutura, nao apenas em modelo real.
- Cada ponto ainda incerto fica marcado como risco residual, nao escondido como se ja estivesse resolvido.

### PR001 - Regra de negocio espalhada em muitas camadas

Problema no audit: o produto mistura contrato model-driven, prompt forte, filtros de tools, parser, reparos, memoria, validacao automatica e testes reais. O resultado e que "varios agentes parciais" disputam controle no mesmo loop.

Motivacao tecnica: enquanto regra operacional estiver espalhada, qualquer alteracao local pode mudar a decisao global. Exemplo: mudar parser pode executar tool inexistente; mudar memoria pode bloquear finalizacao; mudar browser_check pode transformar evidencia visual em erro de negocio.

Alvo final: uma fronteira unica de controller:

- modelo escolhe contrato/tool anunciada;
- parser apenas extrai candidato;
- gate valida se candidato pertence ao contrato do turno;
- executor roda tool;
- audit registra decisao, resultado e motivo de parada;
- memoria/validacao consomem eventos tipados, nao texto solto.

Tasks que resolvem: T010-T014, T020-T024, T030-T034, T070-T077.

Teste de prova: uma chamada emitida pelo modelo so pode chegar ao executor se tiver passado por envelope, allowlist e audit. Um teste fake deve provar que `content` nao executa, que `read_file` anunciado executa e que ambos aparecem no audit com estados distintos.

Risco residual: durante migracao, `set_plan`/SessionBrain e novos contratos podem coexistir. T034 existe para impedir que a transicao vire outro eixo concorrente.

### PR002 - Parser tolerante demais pode inventar ferramenta

Problema no audit: uma saida real virou tool `content`, fora das tools anunciadas.

Motivacao tecnica: modelos pequenos e backends locais quebram protocolo. O parser precisa ser tolerante, mas a execucao precisa ser estrita. Endurecer o parser direto quebraria compatibilidade; deixar executor aceitar tudo quebra seguranca e regra de negocio.

Alvo final: parser tolerante + executor estrito.

- Parser pode extrair candidato desconhecido.
- Envelope marca origem e estrategia.
- Gate valida contra tools anunciadas no turno.
- Tool inexistente vira repair compacto, nunca `executeToolWithEvents`.

Tasks que resolvem: T010, T011, T012, T013, T014, T040.

Teste de prova: fixture offline com tool `content` deve passar pelo parser, ser rejeitada pelo gate e deixar contador de executor em zero.

Risco residual: native tool calls tambem precisam passar pelo mesmo gate, nao so text protocol. T012 deve cobrir os dois caminhos.

### PR003 - Contratos devem ser endpoints, estrategias devem ser funcoes

Problema no audit: muitas regras vivem em `buildSystemPrompt`: quando coletar evidencia, quando mutar, quando validar, quando perguntar ao usuario. O refinamento arquitetural e que contrato nao deve ser workflow engessado; contrato deve ser endpoint de API para o modelo, e estrategia deve ser uma opcao curta dentro desse endpoint.

Motivacao tecnica: prompt longo e instrucional e fragil com modelo pequeno. Ao mesmo tempo, contratos rigidos demais engessam o agente. O meio correto e API pequena, estrategias dinamicas e controller capaz de compor implementacoes internas sem expor overhead ao modelo.

Alvo final: contratos pequenos, versionados e model-driven, com estrategias opcionais e auditaveis.

- Contrato model-visible funciona como endpoint.
- Estrategia funciona como parametro/função dentro do endpoint.
- Implementacoes internas podem chamar varias tools/metodos sem virar surface.
- Mutacao/validacao/runtime podem abrir por contrato, nao por keyword do prompt.
- `set_plan` fica como planejamento de passos, nao como contrato operacional.

Tasks que resolvem: T030-T038, T050-T054, T080-T085.

Teste de prova: prompts com wording diferente nao mudam contrato por heuristica; chamada explicita de `collect_evidence` com `strategy: "symbol"` executa estrategia valida; estrategia inexistente vira repair curto; fallback fica registrado no audit.

Risco residual: muitas estrategias nomeadas recriam overhead de tool surface; poucas estrategias genericas demais viram prompt disfarçado. T035-T038 existem para calibrar esse ponto.

### PR004 - Tool surface grande demais para modelo pequeno

Problema no audit: mesmo com ferramentas boas, muitas choices model-visible degradam selecao.

Motivacao tecnica: o benchmark mostra tool calling forte, mas 90% ainda significa erro real em ambientes longos. Reduzir choices no primeiro turno diminui custo cognitivo e tokens de schema.

Alvo final: surface progressiva.

- Primeiro turno: contratos e leitura segura.
- Depois: mutacao/validacao/runtime conforme contrato.
- Ferramentas internas continuam disponiveis ao controller.

Tasks que resolvem: T031, T032, T033, T100.

Teste de prova: `getExposedToolDefinitions` nao expoe `grep_file`, `rag_search`, `parse_ast` por padrao, mas `collect_evidence` consegue usar estrategias equivalentes internamente.

Risco residual: tarefas triviais de edicao podem exigir uma chamada a mais. O audit de tokens em T110/T111 deve medir se o custo compensa.

### PR005 - Toda coleta deve convergir para contexto destilado unico

Problema no audit: contexto aparece vindo de muitos nomes e fluxos (`collect_evidence`, `get_minimal_context`, `build_task_context`, `get_context`, `read_file`, RAG, AST, grep, memoria e SessionBrain). A formulacao correta nao e aceitar varias fontes: e transformar todas essas ferramentas em coletores que alimentam uma unica saida destilada.

Motivacao tecnica: modelo pequeno nao deve receber bruto de varias ferramentas e tentar decidir o que importa. O controller deve assumir a responsabilidade de transformar tool result em evidencia minima, verificavel e util para a tarefa. Isso reduz tokens, reduz ruido e impede que o modelo persiga falso positivo.

Alvo final: `EvidencePacket v1` como saida unica de contexto do turno. Toda tool de coleta produz eventos tipados que viram `EvidenceEntry`. O modelo ve somente entradas destiladas com prova tangivel: path/range/hash, comando executado, status, trecho exato, erro objetivo, origem e confidence.

Tasks que resolvem: T050-T054, T060-T063, T070-T077, T100-T101.

Teste de prova: `read_file`, `grep_file`, `run_validation` e `browser_check` com mocks diferentes geram o mesmo tipo de `EvidenceEntry`; o prompt final recebe apenas o pacote destilado, nao os outputs brutos.

Risco residual: o audit precisa guardar bruto/metadata suficiente para debug, mas isso nao pode voltar para o prompt como "mais contexto".

### PR006 - Micro-contexto editavel nao pode ser so texto util

Problema no audit: micro-contexto precisa ter id, path, range e hash para edicao segura; sem isso, patch pode mirar trecho stale.

Motivacao tecnica: modelos pequenos se beneficiam de handles compactos, mas o controller precisa provar que o trecho ainda e o mesmo antes de aplicar patch.

Alvo final: registry de micro-contexto com hash/range e validacao em `apply_patch`.

Tasks que resolvem: T060, T061, T062, T063.

Teste de prova: criar contexto, alterar arquivo, tentar patch com contextId antigo; resultado deve ser erro reparavel `stale_context`.

Risco residual: `apply_patch` sem contextId deve continuar funcionando para compatibilidade, mas o audit deve marcar menor confianca.

### PR007 - MEMORY e SKILLS sao as unicas fontes persistentes

Problema no audit: SessionBrain, PersistentMemory, MemoryOrchestrator, `.MEMORY.md`, `.SKILL.md`, micro-context registry e operational run store podem competir. A direcao correta e eliminar essa competicao conceitual: fora da evidencia destilada do turno, so existem memoria pratica e skills/regras.

Motivacao tecnica: memoria contraditoria e pior que falta de memoria para modelo pequeno; aumenta tokens, cria bloqueios falsos e enfraquece a confianca do modelo. O sistema precisa distinguir fato de projeto, preferencia/regra do usuario e evidencia operacional do turno.

Alvo final: duas fontes persistentes e um pipeline de evidencia:

- `MEMORY.md` / `.MEMORY.md`: fatos e insights praticos do projeto/diretorio vigente, persistidos entre sessoes.
- `SKILLS.md` / `.SKILL.md`: regras absolutas e preferencias do usuario verificadas na interacao.
- Evidencia do turno: nao e memoria concorrente; e pacote destilado temporario derivado das tools.

Tasks que resolvem: T070-T077, T120-T121.

Teste de prova: uma regra do usuario como "nunca use any" vai para SKILLS; um insight verificado do projeto vai para MEMORY; um resultado de `read_file`/LSP/browser vira EvidencePacket temporario e nao persiste como memoria permanente sem promocao explicita.

Risco residual: a arvore atual usa `.MEMORY.md` e `.SKILL.md`; se o produto final preferir `MEMORY.md` e `SKILLS.md` sem ponto/plural, a task deve incluir migracao/compatibilidade de nomes.

### PR008 - Validacao automatica pode virar ruido

Problema no audit: diagnosticos historicamente desviaram o modelo; browser/canvas deve ser evidencia, nao falha de negocio; JS puro nao deve sofrer typecheck irrelevante.

Motivacao tecnica: validacao boa aumenta confianca, mas falso positivo consome loops e tokens. O controller precisa classificar severidade antes de bloquear.

Alvo final: politica de validacao por severidade.

- syntax error: blocking;
- erro runtime/browser real: blocking;
- type diagnostic scoped: warning ou blocking conforme confianca;
- DOM/canvas snapshot: evidence-only;
- JS sem `checkJs`: nao typecheck bloqueante.

Tasks que resolvem: T080, T081, T082, T084.

Teste de prova: canvas blank nao falha global; syntax error bloqueia; JS sem checkJs nao produz erro TS hard.

Risco residual: LSP externo introduz ambiente e latencia. Auto-install deve ficar depois do diagnostico local.

### PR009 - Runtime/browser frontend flow nao e canonico

Problema no audit: subir servidor, detectar porta, rodar browser_check, coletar erros e encerrar processo ainda e improvisado.

Motivacao tecnica: sem protocolo tipado, testes reais de frontend viram benchmark de sorte do modelo e do ambiente.

Alvo final: contrato `start_background_command -> runtimeTarget -> browser_check -> cleanup`.

Tasks que resolvem: T083, T084, T085.

Teste de prova: servidor fake gera target, browser_check mock consome URL, cleanup encerra processo.

Risco residual: Playwright/browser pode nao existir no ambiente. Teste unitario deve usar mock; teste real fica separado.

### PR010 - Testes reais confundem agente com capacidade do modelo

Problema no audit: teste que exige HTML especifico, canvas com N arcos ou bug seeded corrigido mede modelo, nao agente.

Motivacao tecnica: se a infra falha, precisamos saber qual contrato quebrou. Se o modelo falha, precisamos saber que a infra ainda entregou ferramentas, evidencia e validação corretamente.

Alvo final: tres camadas:

- `test:agent-infra`: offline, deterministico;
- `test:real:agent-flow`: modelo real, assert de fluxo;
- `test:real:model-capability`: modelo real, assert de tarefa resolvida.

Tasks que resolvem: T001, T002, T140, T141, T142.

Teste de prova: um modelo fake que nao resolve bug ainda passa infra se chamou tool anunciada, recebeu result, manteve round-trip e finalizou com estado auditavel.

Risco residual: alguns testes existentes terao que ser reclassificados, nao apagados.

### PR011 - Reparos automaticos podem consumir o ganho de baixo token

Problema no audit: prompts repetidos de repair enchem contexto e degradam modelos pequenos.

Motivacao tecnica: reparo e necessario, mas deve ser resumido, limitado por classe e medido em tokens.

Alvo final: repair budget por classe e resumo compacto.

Tasks que resolvem: T042, T043, T110, T112.

Teste de prova: tres erros iguais viram um resumo compacto; audit mostra tokens gastos em repairs.

Risco residual: limite agressivo demais pode encerrar antes de uma recuperacao valida. Deve ser adaptativo por classe de erro.

### PR012 - Normalizacao generica mascara schema ruim

Problema no audit: aliases amplos ajudam o modelo, mas escondem quando o contrato nao esta claro.

Motivacao tecnica: aceitar alias pode ser correto; aceitar sem telemetria impede melhorar schema/prompt.

Alvo final: normalizacao com notas e metricas por tool.

Tasks que resolvem: T013, T023, T092.

Teste de prova: `write_file` com `data` normaliza para `content`, mas audit registra `content<-data`; campo semanticamente impossivel continua erro.

Risco residual: reduzir aliases cedo pode quebrar modelo real. Primeiro medir, depois podar.

### PR013 - Mutacao e patch precisam de intencao verificavel

Problema no audit: `apply_patch` e poderoso demais; patch parcial ou full rewrite indevido nao sao resolvidos so pela tool.

Motivacao tecnica: edicao segura exige saber o que o modelo pretendia mudar e comparar com o diff observado.

Alvo final: `MutationIntent` + protecoes de full rewrite + erros reparaveis.

Tasks que resolvem: T060-T063, T090-T092.

Teste de prova: patch pequeno passa; full rewrite sem intencao explicita falha; patch sem `replace` retorna missingFields estruturado.

Risco residual: tarefas legitimas de rewrite precisam caminho explicito para prosseguir.

### PR014 - Audit trail por turno e requisito, nao opcional cosmetico

Problema no audit: sem painel de auditoria unico, falhas de UI/parser/model/controller se misturam.

Motivacao tecnica: refatoracao massiva sem audit vira discussao subjetiva. O produto precisa explicar o que aconteceu em cada turno.

Alvo final: `TurnAudit` persistivel e resumivel:

- prompt chars/tokens;
- tools anunciadas;
- parser strategy;
- calls extraidas;
- allowlist validation;
- args normalizados;
- tool results;
- memory blocks;
- validation blockers;
- motivo de parada.

Tasks que resolvem: T020-T024, T130, T131.

Teste de prova: um turno fake com uma tool valida e uma rejeitada renderiza summary e replay.

Risco residual: audit completo pode gerar arquivo grande; nao deve ser injetado no prompt por padrao.

### PR015 - Metricas de baixo consumo ainda nao provam valor

Problema no audit: o projeto tenta economizar tokens, mas nao mede tokens de schema, memoria, evidencia, repairs e economia vs read_file completo.

Motivacao tecnica: sem metrica, uma feature "compacta" pode custar mais em reparos do que economiza em contexto.

Alvo final: buckets de tokens reais por turno quando o backend/tokenizer fornecer contagem, e economia por bytes/chars quando token real nao estiver disponivel.

Tasks que resolvem: T101, T110, T111, T112.

Teste de prova: audit soma tokens reais por bucket com tokenizer real/fake de teste e calcula economia por bytes/chars de EvidencePacket contra arquivo completo.

Risco residual: contagem de tokens depende do backend/tokenizer; quando `/tokenize` nao estiver disponivel, tokens ficam ausentes em vez de estimados.

### PR016 - Learning loop pode persistir padrao ruim

Problema no audit: aprendizado automatico pode gravar skills sem criterio de sucesso confiavel.

Motivacao tecnica: uma skill ruim vira bug persistente e caro para modelo pequeno.

Alvo final: skill candidate vs validated, com evidencia de sucesso.

Tasks que resolvem: T120, T121.

Teste de prova: skill sem mutacao/validacao/teste fica candidate; so vira validated com evidencia real.

Risco residual: algumas boas praticas sao qualitativas. Elas devem entrar como memoria de projeto, nao skill operacional validada.

## O que ainda nao esta resolvido ate virar codigo

Este documento alinha o plano, mas nao resolve o produto sozinho. A resolucao real so existe quando:

- testes offline provam os contratos;
- patches pequenos implementam cada task;
- testes reais de fluxo confirmam que o modelo pequeno consegue usar os contratos;
- metricas mostram que o custo de tokens caiu ou ficou justificado;
- o audit de turno permite explicar uma falha sem ler logs brutos.

Portanto, a resposta correta para "resolve 100%?" e:

- Como plano revisado: deve cobrir 100% dos problemas descritos no audit.
- Como implementacao atual: ainda nao resolve, porque o codigo nao foi alterado.
- Como garantia de produto: so sera 100% apos executar as tasks, validar os testes e ajustar os riscos residuais encontrados.

## Estado observado nesta arvore

### Benchmark do modelo

`doc/banchmark/phenom_latest.txt` registra `phenom:latest` como `Qwopus3.5-9B-Coder-GGUF`, score geral `93.3/100`, `tool_calling 90.0%`, `agentic_tasks 100.0%`, `logical_reasoning 100.0%`, `multilingual 50.0%`, total de `23661` tokens em `19` testes e media `41.4` tokens/s.

Impacto no plano:

- O modelo tem capacidade real de tool calling, planejamento e raciocinio.
- O ponto fraco nao deve ser tratado como incapacidade geral do modelo.
- O sistema precisa reduzir ruido, contratos ambiguos e reparos longos.
- Como multilingual aparece baixo, prompts e outputs de protocolo devem preferir tags estaveis e ingles tecnico curto, mesmo quando a conversa esta em portugues.

### Evidencia da arvore atual

- `src/tool-call-parser.ts:8-43` retorna `ToolLoopResponse` diretamente, sem envelope intermediario validado.
- `src/tool-call-parser.ts:46-90` aceita tags `<tool_call>`, `[TOOL_CALLS]` e `<|tool_call|>`, extrai `name/toolName/function.name`, mas nao recebe allowlist do turno.
- `src/tool-call-parser.ts:93-119` aceita JSON primario OpenAI-like por `name` e `arguments`, tambem sem validacao contra tools anunciadas.
- `src/tool-call-parser.ts:122-148` escaneia JSON embutido e escolhe a primeira tool encontrada.
- `src/use-cases/run-tool-loop.ts` executa tools via `deps.executeToolWithEvents(toolName, rawArgs)` depois de normalizar nome e argumentos; a auditoria exige gate antes da execucao.
- `src/tools.ts:73-131` registra filesystem, search, navigation, project, git, utility, session, workflow, memory, news, ast e rag, mas nao registra `context-tools`.
- `src/tools.ts:173-256` centraliza normalizacao de argumentos; isso ajuda modelos pequenos, mas precisa ser auditado e medido por tool.
- `src/tools/registrars/filesystem-tools.ts:115-291` implementa `read_file` paginado, ENOENT com sugestoes e output estruturado.
- `src/tools/registrars/filesystem-tools.ts:335-380` documenta `write_file` como full rewrite, com erro estruturado para `path/content`.
- `src/tools/registrars/search-tools.ts:50-215` implementa `grep_file` como ferramenta direta model-visible hoje, enquanto a auditoria quer primitivas internas atras de `collect_evidence`.
- `src/tools/registrars/rag-tools.ts:46-154` expoe `rag_status`, `rag_index`, `rag_search` como ferramentas diretas.
- `src/tools/registrars/workflow-tools.ts:31-202` implementa `set_plan`, `list_pending_tasks`, `complete_step`, mas a auditoria pede `set_operational_contract` e contratos de fases auditaveis.
- `src/tools/registrars/utility-tools.ts:99-271` contem `date` e `run_code`; `rg` confirmou que `start_background_command` e `browser_check` existem na referencia, mas nao nesta arvore.
- `src/session-brain.ts:55-354` e memoria de sessao/planos; a referencia tem tambem `src/memory/*`, que nao existe nesta arvore atual.
- `src/agent-control` nao existe nesta arvore; existe em `../phenom-cli-ts/src/agent-control`.
- `src/memory` nao existe nesta arvore; existe em `../phenom-cli-ts/src/memory`.
- `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts:17-54` define internal tools e model-visible tools, incluindo `collect_evidence` e `set_operational_contract`.
- `../phenom-cli-ts/src/tests/unit/test-intent-tool-contract.ts:22-97` ja prova que wording do prompt nao deve classificar direcao operacional.
- `rg` confirmou na referencia: `collect_evidence` em `context-tools.ts`, `run_validation` em `workflow-tools.ts`, `start_background_command` e `browser_check` em `utility-tools.ts`, `set_operational_contract` em `agent.ts`.

Conclusao de baseline: a auditoria descreve uma versao mais avancada que nao esta integralmente nesta arvore rollback. Portanto, as tasks abaixo distinguem correcao de codigo existente de reintroducao controlada da referencia.

## Ordem macro recomendada

1. Congelar features novas ate estabilizar loop principal.
2. Separar testes de infraestrutura do agente e benchmarks de modelo.
3. Criar gate universal de tool call anunciada.
4. Criar audit por turno.
5. Reintroduzir contrato model-driven e surface de tools controlada.
6. Reintroduzir `collect_evidence` com `EvidencePacket v1`.
7. Reintroduzir micro-contexto editavel.
8. Criar pipeline unico de destilacao de contexto por evidencia.
9. Calibrar validacao e runtime/browser.
10. Medir custo/token por turno e por feature.

## Matriz de passos especificos por task

Esta matriz e obrigatoria. Ela complementa as secoes de cada task e deve guiar a implementacao. Quando uma task for executada, seus passos genericos devem ser substituidos ou refinados por estes passos especificos, preservando a regra de teste primeiro.

### T000 - Passos especificos

1. Rodar `git status --short` antes de qualquer patch e registrar no devlog somente os arquivos tocados pela task.
2. Separar arquivos gerados pelo agente de arquivos pre-existentes do usuario; nunca limpar `.phenom-*` ou sessoes sem pedido explicito.
3. Comparar a task com a referencia `../phenom-cli-ts` apenas para leitura; nao copiar arquivos inteiros sem reduzir escopo.
4. Registrar em cada task: refs consultadas, arquivos alterados, testes executados e risco residual.

### T001 - Passos especificos

1. Criar teste em `src/tests/unit` que leia `package.json` e falhe se `test:agent-infra` nao existir.
2. Montar `test:agent-infra` com suites offline ja existentes: parser, use-cases, tool policy, registrars e renderer minimo.
3. Consultar `../phenom-cli-ts/package.json` para nomes de scripts de referencia, mas nao copiar suites reais/modelo para infra.
4. Garantir que o script nao dependa de Ollama, browser, rede ou modelo real.
5. Rodar o novo teste de package e depois `npm run test:agent-infra`.

### T002 - Passos especificos

1. Criar teste de package que exige scripts `test:real:agent-flow` e `test:real:model-capability`.
2. Mapear testes reais de `../phenom-cli-ts/src/tests/real/*` e classificar: fluxo do agente vs capacidade do modelo.
3. Criar aliases inicialmente conservadores sem mover casos complexos.
4. Documentar que `agent-flow` valida protocolo/audit/tools e `model-capability` valida tarefa resolvida.
5. Nao fazer teste de infraestrutura depender de sucesso visual/canvas/bug seeded.

### T010 - Passos especificos

1. Criar teste unitario para `ToolCallEnvelope` antes do tipo existir.
2. Basear o parser atual em `src/tool-call-parser.ts` e observar `../phenom-cli-ts/src/tool-call-parser.ts`, que tem multi-call, mas ainda nao resolve allowlist por si.
3. Criar tipo em modulo pequeno, preferencialmente `src/tool-call-envelope.ts` ou `src/domain-contracts.ts`.
4. Campos minimos: rawName, canonicalName?, args, parseStrategy, source, state, rejectionReason?.
5. Nao alterar parser nem loop nesta task; apenas modelar envelope e helpers puros.

### T011 - Passos especificos

1. Criar teste com envelope `rawName=content` e allowlist `read_file`; esperar `rejected/tool_not_advertised`.
2. Criar teste com alias `read` e allowlist `read_file`; esperar canonicalizacao permitida somente se canonical esta anunciada.
3. Implementar `validateToolCallEnvelope(envelope, advertisedNames, aliasResolver?)`.
4. Corrigir erro de `../phenom-cli-ts`: parser tolerante nao deve significar executor permissivo.
5. Retornar rejeicao estruturada para repair, nao excecao.

### T012 - Passos especificos

1. Criar teste de `runToolLoopUseCase` com LLM fake emitindo `{"name":"content","arguments":{"text":"x"}}`.
2. O executor fake deve contar chamadas; assert final: zero execucoes.
3. Extrair allowlist de `toolDefs` recebidos pelo use-case, nao do ToolSystem global.
4. Inserir gate antes de `deps.executeToolWithEvents`.
5. Fazer o mesmo caminho cobrir text protocol e native `toolCallsFromStream`.
6. Retornar repair compacto ao modelo e registrar rejeicao no audit.

### T013 - Passos especificos

1. Testar `normalizeToolNameWithAliases` com allowlist do turno, nao lista global.
2. Manter aliases uteis de `src/use-cases/tool-execution-policy.ts`, mas medir quando alias foi usado.
3. Impedir que alias resolva para tool nao anunciada no turno.
4. Registrar nota `alias: read -> read_file` no envelope/audit.
5. Nao adicionar novos aliases amplos inspirados na referencia sem teste real.

### T014 - Passos especificos

1. Criar fixture offline para a falha `content`; usar saida minima baseada no audit, nao depender de modelo real.
2. Cobrir parse primary JSON, tagged tool call e native-like shape.
3. Assert: parser pode extrair candidato, gate rejeita, executor nao roda.
4. Guardar fixture em `src/tests/fixtures/tool-calls/` ou inline se menor.
5. Incluir fixture no script `test:agent-infra`.

### T020 - Passos especificos

1. Estudar `../phenom-cli-ts/src/agent-control/operational-run-store.ts` e `operational-run-inspector.ts`.
2. Criar `TurnAudit` menor que a referencia: eventos do turno, tools anunciadas, calls, rejeicoes, results, contexto enviado.
3. Testar serializacao estavel e sem raw output gigante.
4. Nao criar store persistente nesta task; apenas modelo e builder.
5. Garantir que audit e prompt sao coisas separadas.

### T021 - Passos especificos

1. Criar teste em `runToolLoopUseCase` com dois `toolDefs` fake e audit ativo.
2. Registrar `advertisedTools` no inicio do turno antes da inferencia.
3. Incluir nome, schema hash/size e modo native/text protocol.
4. Nao injetar essa lista completa no prompt alem do manifesto compacto.
5. Usar esse snapshot como fonte da allowlist de T012.

### T022 - Passos especificos

1. Criar teste com parse strategies `primary_json`, `tagged_tool_call`, `embedded_json_scan`.
2. Ligar `parseToolCallOrFinalDetailed` ao envelope/audit.
3. Referenciar `../phenom-cli-ts/src/tool-call-parser.ts` apenas para multi-call e markers adicionais; nao copiar a lista permissiva de nomes como seguranca.
4. Registrar raw excerpt truncado, nunca resposta completa.
5. Usar strategy no repair quando rejeitado.

### T023 - Passos especificos

1. Alterar teste de `ToolSystem` para esperar notas de normalizacao.
2. Refatorar `normalizeToolArgs` para retornar `{ args, notes }` internamente mantendo API externa.
3. Registrar wrappers desembrulhados, aliases de path/content, ops->operations e patch unified diff.
4. Corrigir fragilidade da referencia: normalizacao nao deve mascarar campo semanticamente impossivel.
5. Medir por tool quantas chamadas precisaram normalizacao.

### T024 - Passos especificos

1. Portar o minimo de `OperationalRunStore` da referencia, removendo acoplamentos a task-state/plan se nao forem usados.
2. Criar teste com tmpdir: criar run, adicionar evento, listar, ler replay.
3. Persistir JSON pequeno sob `.phenom-context/runs` ou local configuravel.
4. Nao gravar raw tool output completo por padrao; usar `rawRef`/truncamento.
5. Criar inspector textual depois, em T131.

### T030 - Passos especificos

1. Portar/adaptar `../phenom-cli-ts/src/tests/unit/test-intent-tool-contract.ts`.
2. Criar `src/agent-control/intent-tool-contract.ts` com `model_driven`, sem keyword classification.
3. Reaproveitar lista da referencia como base, mas remover qualquer tool ausente nesta arvore ate ser reintroduzida.
4. Garantir que prompts diferentes retornam contrato identico.
5. Exportar filtro de internal tools para T031.

### T031 - Passos especificos

1. Criar teste que monta defs com `grep_file`, `rag_search`, `parse_ast`, `read_file`, `collect_evidence`.
2. Aplicar filtro no ponto de `Agent.getExposedToolDefinitions`.
3. Usar env `PHENOM_EXPOSE_INTERNAL_CONTEXT_TOOLS=1` apenas para debug/teste.
4. Corrigir erro da referencia: internal tools nao devem reaparecer por outro caminho de schema/text protocol.
5. Verificar que controller ainda pode chamar coletores internamente.

### T032 - Passos especificos

1. Localizar implementacao de referencia em `../phenom-cli-ts/src/agent.ts`.
2. Criar teste de tool registrar/agent que chama `set_operational_contract`.
3. Implementar tool sem side effects: grava contrato ativo no turno/audit.
4. Validar args: goal, phase?, allowedStrategies?, requestedSurface?.
5. Nao abrir mutation automaticamente nesta task; apenas registrar declaracao.

### T033 - Passos especificos

1. Criar teste de surface inicial com poucos contratos/tools.
2. Definir tiers: `observe`, `mutate`, `validate`, `runtime`.
3. Abrir tier por contrato declarado ou modo code explicito, nunca por keyword solta do prompt.
4. Medir tamanho do schema antes/depois.
5. Manter fallback para compatibilidade atras de env se testes existentes quebrarem.

### T034 - Passos especificos

1. Rodar/consultar testes de plan atuais e referencia `test-plan.ts`.
2. Documentar no codigo que `set_plan` planeja passos e `set_operational_contract` declara contrato/surface.
3. Garantir que um nao sobrescreve estado do outro.
4. Se ambos existirem, audit deve registrar ambos separadamente.
5. Evitar portar task-state-machine inteiro da referencia nesta task.

### T035 - Passos especificos

1. Criar teste de manifesto compacto com limite de chars/tokens.
2. Definir `src/contracts/manifest.ts` ou `src/agent-control/contract-manifest.ts`.
3. Incluir endpoints iniciais: collect_evidence, mutate_file, validate_work, inspect_runtime, set_operational_contract.
4. Remover exemplos com paths reais para nao enviesar modelo.
5. Renderizar manifesto para prompt separado do system fixo.

### T036 - Passos especificos

1. Criar teste para registry de estrategias por contrato.
2. Definir estrategias pequenas para `collect_evidence`: auto, symbol, path, diagnostic, runtime, diff.
3. Cada estrategia deve ter custo esperado, precondicoes e fallback.
4. Nao expor metodos internos como tools.
5. Rejeitar estrategia invalida com lista curta de estrategias validas.

### T037 - Passos especificos

1. Criar teste para `strategy=symbol` com AST indisponivel e grep disponivel.
2. Implementar router puro que recebe contrato, estrategia, budget e targets.
3. Retornar plano interno: metodos, fallbackReason, costEstimate.
4. Integrar primeiro em `collect_evidence`, nao em todos contratos.
5. Registrar requested/executed strategies no TurnAudit.

### T038 - Passos especificos

1. Criar teste que calcula tamanho do manifesto renderizado.
2. Definir limite inicial baseado no benchmark: pequeno o suficiente para nao disputar evidence.
3. Registrar no audit chars/tokens de manifesto e estrategias.
4. Falhar teste se nova estrategia aumentar schema sem atualizar limite/justificativa.
5. Comparar antes/depois do filtro de tools de T031.

### T040 - Passos especificos

1. Manter parser tolerante atual e o parser multi-call da referencia como fonte de formatos.
2. Criar teste provando que parser extrai unknown tool, mas executor rejeita via T011/T012.
3. Separar helpers de parser e gate em modulos distintos.
4. Nao inserir allowlist dentro do parser.
5. Documentar fronteira: parser identifica candidato; gate decide executabilidade.

### T041 - Passos especificos

1. Portar a ideia de `parseToolCallsOrFinalDetailed` de `../phenom-cli-ts/src/tool-call-parser.ts`.
2. Criar testes para arrays em `<tool_call>`, `[TOOL_CALLS]` e `<|tool_call|>`.
3. Preservar API antiga `parseToolCallOrFinalDetailed` para compatibilidade.
4. Loop pode processar uma por vez inicialmente, mas audit deve ver todas.
5. Corrigir erro da referencia: multi-call tambem passa por allowlist por chamada.

### T042 - Passos especificos

1. Identificar repairs existentes em `run-tool-loop.ts`.
2. Criar contador por classe: invalid_args, unadvertised_tool, duplicate, generic_final, failed_edit.
3. Testar tres erros iguais gerando resumo compacto.
4. Armazenar resumo no audit e contexto, nao repetir prompt longo.
5. Definir limite adaptativo por budget de T112.

### T043 - Passos especificos

1. Localizar guard de final generico no loop atual e comparar com referencia.
2. Criar teste: apos tool success, final `done` nao encerra se ha obligation aberta.
3. Criar lista curta de finais genericos, sem bloquear respostas validas curtas.
4. Ligar obligations estruturadas de EvidencePacket/contract.
5. Registrar repair no audit com motivo.

### T050 - Passos especificos

1. Criar `src/context/evidence-packet.ts` ou usar tipos de T070.
2. Testar schema minimo: entries, obligations, nextAction, budget.
3. Nao copiar o formato textual `[EVIDENCE_DISTILLED]` da referencia como API interna; transformar em objeto primeiro.
4. Renderer textual fica separado em T075.
5. Garantir que EvidencePacket nao contem raw output.

### T051 - Passos especificos

1. Estudar `../phenom-cli-ts/src/tools/registrars/context-tools.ts`, especialmente `collect_evidence`.
2. Implementar versao minima menor: goal, strategy, targets, budget.
3. Internamente usar coletores existentes: path_exists/list_dir/read_file/grep_file quando necessario.
4. Retornar EvidencePacket, nao output textual gigante.
5. Corrigir erro da referencia: nao misturar nomes historicos `get_minimal_context/build_task_context` na surface.

### T052 - Passos especificos

1. Extrair logica util de `grep_file` atual para helper interno reutilizavel.
2. Criar teste com simbolo e path retornando file/line/snippet.
3. Limitar hits e tamanho por evidencia.
4. Criar absence evidence quando nada encontrado, para impedir loops de busca.
5. Nao expor `grep_file` ao modelo por padrao.

### T053 - Passos especificos

1. Usar `src/rag/*` atual e referencia apenas atras de strategy `semantic`.
2. Criar teste com RAG ausente: collect_evidence cai para lexical e registra fallback.
3. Nunca rodar embeddings em teste offline.
4. Registrar custo estimado de RAG no audit.
5. Nao bloquear evidencia se RAG falhar.

### T054 - Passos especificos

1. Identificar ponto de `compactLoopMessages` no loop.
2. Criar teste com EvidencePacket antes de compactacao e janela pequena.
3. Preservar anchors path/range/proof/use.
4. Dropar detalhes redundantes primeiro.
5. Garantir que user intent atual continua pinado.

### T060 - Passos especificos

1. Portar apenas o nucleo de `../phenom-cli-ts/src/tools/micro-context.ts`.
2. Criar registry com id, path, startLine, endLine, sha256, createdAt.
3. Testar stale quando arquivo muda.
4. Nao integrar em read/apply_patch nesta task.
5. Guardar registry em memoria primeiro; persistencia fica fora.

### T061 - Passos especificos

1. Criar teste de `read_file` rangeado produzindo micro-context metadata.
2. Integrar registry de T060 em filesystem registrar.
3. Renderizar handle curto, nao duplicar conteudo.
4. Manter env/flag para compat se necessario.
5. Garantir que output segue sendo destilavel por T072.

### T062 - Passos especificos

1. Criar teste `apply_patch` com contextId valido e stale.
2. Antes de aplicar patch, validar hash/range no registry.
3. Em stale, retornar erro reparavel com path/range esperado.
4. Sem contextId, manter fluxo atual.
5. Registrar stale evidence/audit para o modelo pedir novo contexto.

### T063 - Passos especificos

1. Criar teste de patch que troca >70% do arquivo sem flag.
2. Medir proporcao alterada por linhas/bytes antes de escrever.
3. Exigir `rewrite_explicit` ou contrato de full rewrite.
4. Permitir arquivos novos e pequenos com regra diferente.
5. Retornar repair compacto com alternativa: usar patch menor ou declarar rewrite.

### T070 - Passos especificos

1. Criar `src/context/types.ts` com ToolEvent, EvidenceEntry, EvidencePacket, ModelTurnContext.
2. Criar teste unitario de construcoes minimas.
3. Usar unions restritas para kind/confidence/severity.
4. Nao integrar no loop ainda.
5. Evitar campos que incentivem raw output no contexto do modelo.

### T071 - Passos especificos

1. Criar `src/context/tool-event.ts` com createToolEvent e store por turno.
2. Integrar em `runToolLoopUseCase` logo apos toolResult.
3. Manter fluxo atual de tool response inalterado.
4. Testar com output bruto contendo marcadores proibidos.
5. Confirmar que esse bruto nao chega ao renderer de modelo.

### T072 - Passos especificos

1. Criar `src/context/evidence-distillers.ts`.
2. Implementar distillers para read_file, grep_file, validation, browser, git e command.
3. Testar cada distiller com evento fake.
4. Criar fallback absence/generic seguro.
5. Rejeitar/truncar proofs que carreguem bruto demais.

### T073 - Passos especificos

1. Criar `src/context/select-evidence.ts`.
2. Implementar budgets tiny/small/focused/large.
3. Ordenar por severidade, alvo, confidence e relevance.
4. Retornar selected/rejected/budgetUsed.
5. Testar dedupe, corte e preservacao de evidence critica.

### T074 - Passos especificos

1. Criar `src/context/persistent-context.ts`.
2. Ler MEMORY.md depois fallback `.MEMORY.md`; SKILLS.md depois `.SKILL.md`.
3. Arquivo ausente retorna arrays vazios.
4. Parser limita entradas e recusa bruto evidente.
5. Testar temp dirs com ausente, presente e prioridade de nomes.

### T075 - Passos especificos

1. Criar `src/context/render-model-context.ts`.
2. Renderizar headings somente quando ha dados.
3. Criar `assertNoRawContextLeak`.
4. Snapshotar formato final.
5. Garantir que MEMORY/SKILLS nao aparecem sem arrays.

### T076 - Passos especificos

1. Adicionar parametro opcional `modelTurnContext` em build-inference-messages.
2. Inserir depois do system fixo e antes do user atual.
3. Proteger com env `PHENOM_MODEL_CONTEXT_V1=1` no primeiro rollout.
4. Medir tamanho no audit.
5. Testar que system prompt nao muda e raw output nao entra.

### T077 - Passos especificos

1. Criar `src/tests/unit/test-model-turn-context.ts`.
2. Criar fixtures de raw read_file, rg JSON e command output gigante.
3. Testar ausencia/presenca de MEMORY/SKILLS.
4. Testar que evidence destilada entra e bruto nao.
5. Incluir suite em `test:agent-infra`.

### T080 - Passos especificos

1. Portar menor parte de `run_validation` de `../phenom-cli-ts/src/tools/registrars/workflow-tools.ts`.
2. Criar teste com SyntaxValidator fake e projeto TS.
3. Retornar ValidationEvidence estruturado com escopo/severidade.
4. Nao ativar browser/runtime nesta task.
5. Garantir que resultado vira EvidenceEntry por T072.

### T081 - Passos especificos

1. Portar/adaptar `../phenom-cli-ts/src/agent-control/validation-policy.ts`.
2. Criar categorias blocking/warning/informational/evidence-only.
3. Testar syntax error blocking, canvas blank evidence-only, JS no-check warning/ignored.
4. Integrar policy em run_validation/browser evidence.
5. Finalizacao so bloqueia por blocking.

### T082 - Passos especificos

1. Portar diagnostico local de `lsp-diagnostics.ts` antes de lsp-client/installer.
2. Criar teste JS sem checkJs nao bloqueante.
3. Criar teste TS com erro real.
4. Auto-install externo fica fora desta task.
5. Destilar diagnosticos em EvidenceEntry.

### T083 - Passos especificos

1. Portar de `../phenom-cli-ts/src/tools/registrars/utility-tools.ts` apenas registry de background command.
2. Criar teste com comando fake e readiness por stdout.
3. Guardar pid, command, cwd, detectedUrl/status.
4. Implementar status/cleanup.
5. Nao abrir browser nesta task.

### T084 - Passos especificos

1. Portar browser_check da referencia com retorno tipado reduzido.
2. Criar interface para browser runner mockavel.
3. Testar console error blocking e canvas blank evidence-only.
4. Nao exigir Playwright real em teste unitario.
5. Destilar resultado em EvidenceEntry runtime/browser.

### T085 - Passos especificos

1. Criar contrato interno RuntimeTarget produzido por T083.
2. Testar fluxo fake: start server -> target URL -> browser_check -> cleanup.
3. Integrar `inspect_runtime`/`validate_work(strategy=browser)`.
4. Registrar todos os passos no TurnAudit.
5. Teste real com browser fica em suite separada.

### T090 - Passos especificos

1. Definir `MutationIntent` com target, operation, evidenceIds, expectedChange.
2. Testar intent contra diff observado.
3. Integrar inicialmente no audit, nao bloquear patch.
4. Usar evidenceIds para provar base da mutacao.
5. Depois ligar a full rewrite guard.

### T091 - Passos especificos

1. Criar teste de write_file em arquivo existente com pequena mudanca e sem full rewrite.
2. Comparar conteudo anterior/novo por linhas.
3. Retornar warning/rejection quando rewrite parece indevido.
4. Permitir create file e rewrite explicito.
5. Registrar backup/snapshot no audit.

### T092 - Passos especificos

1. Criar testes para apply_patch sem replace, range incoerente e context stale.
2. Padronizar erro com recoverable/missingFields/normalizedArgs.
3. Reaproveitar mensagens boas do filesystem-tools atual.
4. Evitar regex ad hoc nova quando schema pode validar.
5. Garantir repair curto para modelo.

### T100 - Passos especificos

1. Testar que RAG/AST/search nao aparecem na surface padrao.
2. Garantir que `collect_evidence` consegue chama-los internamente por estrategia.
3. Usar filtro de T031.
4. Manter env de debug para expor internals.
5. Medir reducao do schema.

### T101 - Passos especificos

1. Criar metricas por estrategia: bytes/chars input, tokens reais quando o backend/tokenizer real fornecer, entries, confidence, fallback.
2. Integrar no TurnAudit.
3. Testar collect_evidence lexical vs RAG fallback.
4. Nao usar tokenizer remoto em teste offline.
5. Renderizar resumo pequeno no audit, nao no prompt.

### T110 - Passos especificos

1. Criar buckets: system, contracts, memory, skills, evidence, repairs, toolSchema.
2. Usar somente contagem real: `/tokenize` real pre-envio ou contadores reais pos-inferencia do backend.
3. Testar soma com tokenizer fake apenas como test double deterministico, nunca como estrategia runtime.
4. Registrar por turno no audit.
5. Nao bloquear execucao por medicao ausente.

### T111 - Passos especificos

1. Para EvidenceEntry de file_slice, comparar tamanho do trecho com tamanho total conhecido.
2. Testar economia por bytes/chars e, quando houver tokenizer real disponivel, por tokens reais.
3. Registrar economia por estrategia.
4. Nao exibir calculo detalhado ao modelo.
5. Usar metrica para calibrar budgets.

### T112 - Passos especificos

1. Ligar repair budget aos buckets de T110.
2. Testar budget baixo reduz verbosity.
3. Criar resumo por classe de repair.
4. Nao suprimir primeiro repair util.
5. Registrar suppressions no audit.

### T120 - Passos especificos

1. Criar helper de promocao para MEMORY separado de evidence.
2. Testar que EvidenceEntry temporaria nao grava arquivo.
3. Promover somente fato verificado, reutilizavel e com origem.
4. Limitar tamanho/duplicatas em MEMORY.
5. Nao gravar regras de usuario em MEMORY.

### T121 - Passos especificos

1. Criar helper de promocao para SKILLS.
2. Testar regra explicita do usuario vira skill candidate/confirmed.
3. Preferencia inferida exige confirmacao.
4. Padrao tecnico exige evidencia de sucesso.
5. Nao gravar fatos de projeto em SKILLS.

### T130 - Passos especificos

1. Criar evento/resumo `TURN_AUDIT_SUMMARY`.
2. Testar renderer com tools announced/called/rejected/context sent.
3. Mostrar resumo curto, nao raw audit.
4. Integrar opcionalmente no CLI renderer.
5. Garantir que TTS/final answer nao repete audit.

### T131 - Passos especificos

1. Portar minimo de `operational-run-inspector.ts`.
2. Criar teste com run fake persistido por T024.
3. Implementar list, summary, replay.
4. Truncar raw output no replay por padrao.
5. Comando CLI pode vir depois, mas renderer deve existir.

### T140 - Passos especificos

1. Criar harness real que valida audit, nao tarefa resolvida.
2. Prompt deve forcar ferramenta simples e verificar round-trip.
3. Assert: tools anunciadas, call valida, result, evidence, final nao generico.
4. Nao assertar UI/canvas/bug especifico.
5. Salvar relatorio por run.

### T141 - Passos especificos

1. Separar benchmark de capacidade do modelo em script proprio.
2. Reaproveitar formato de `doc/banchmark/phenom_latest.txt`.
3. Falha nao quebra `test:agent-infra`.
4. Relatorio deve dizer modelo, host, tokens, dimensoes.
5. Usar para calibrar estrategias, nao para validar core.

### T142 - Passos especificos

1. Criar pasta `src/tests/fixtures/model-outputs/`.
2. Capturar/minimizar saidas reais problematicas: content tool, malformed args, generic final, multi-tool.
3. Testar fixtures offline contra parser/gate.
4. Remover dados irrelevantes e prompts longos.
5. Documentar origem e bug coberto em cada fixture.

## Fase 0 - Baseline e seguranca de refatoracao

### T000 - Registrar baseline da arvore atual

Status: pending

Evidencia: `git status --short` mostrou worktree suja com muitos arquivos modificados e nao rastreados. O projeto tem mudancas pre-existentes que nao devem ser revertidas.

Impacto: evita misturar refatoracao com reversao acidental de trabalho existente.

Teste primeiro: nao se aplica a codigo; criar registro textual no devlog a cada grupo de mudancas.

Implementacao: antes de cada patch, rodar `git status --short` e documentar arquivos tocados pela task.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: cada task futura lista arquivos alterados e testes rodados.

### T001 - Criar script/suite de baseline local

Status: pending

Evidencia: `package.json` tem scripts separados como `test:core`, `test:use-cases`, `test:tool-registrars`, `test:toolcall-parser`, `test:memory-skill-flow`, mas nao ha script dedicado para `agent-infra`.

Impacto: reduz regressao durante refatoracao massiva.

Teste primeiro: criar teste que falha se o script `test:agent-infra` nao existir em `package.json`.

Implementacao: adicionar script que rode parser, use-cases, tool registrars, model capabilities e event bus, sem modelo real.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: `npm run test:agent-infra` passa offline.

### T002 - Separar explicitamente teste real de fluxo e benchmark de modelo

Status: pending

Evidencia: a auditoria diz que testes reais historicos mediam se o modelo corrigiu app seeded, nao se o agente preservou protocolo.

Impacto: falhas passam a apontar para infraestrutura ou capacidade do modelo de forma correta.

Teste primeiro: teste em `package.json` garantindo scripts distintos `test:real:agent-flow` e `test:real:model-capability`.

Implementacao: criar aliases inicialmente apontando para suites existentes ou stubs, depois migrar casos.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: documentacao dos scripts indica que `agent-flow` valida protocolo e `model-capability` valida solucao de tarefa.

## Fase 1 - Gate universal de tool call anunciada

### T010 - Definir tipo `ToolCallEnvelope`

Status: pending

Evidencia: `src/tool-call-parser.ts` retorna `ToolLoopResponse` sem estado `parsed/schema-valid/advertised/executable/rejected`.

Impacto: cria fronteira unica entre parser tolerante e execucao real.

Teste primeiro: adicionar teste unitario que constroi envelope para `read_file` com estado `parsed`, origem `primary_json`, args brutos e nome extraido.

Implementacao: criar tipo pequeno em `src/domain-contracts.ts` ou novo modulo sem alterar execucao ainda.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: parser antigo continua passando; novo helper gera envelope sem executar tool.

### T011 - Validar envelope contra allowlist de tools anunciadas

Status: pending

Evidencia: auditoria relata tool inexistente `content`; parser nao conhece a lista de tools do turno.

Impacto: impede que fragmento de protocolo vire chamada executavel.

Teste primeiro: fixture com `{"name":"content","arguments":{"text":"x"}}` e allowlist `["read_file"]` deve produzir `rejected` com motivo `tool_not_advertised`.

Implementacao: criar funcao pura `validateToolCallEnvelope(envelope, advertisedToolNames)`.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: tool inexistente nunca fica `executable`.

### T012 - Aplicar gate no loop antes de `executeToolWithEvents`

Status: pending

Evidencia: no loop, a execucao acontece depois de `normalizeToolName` e `parseToolCallArgs`; precisa barrar antes da chamada.

Impacto: corrige a falha de regra de negocio mais grave apontada pela auditoria.

Teste primeiro: teste de `runToolLoopUseCase` com modelo fake emitindo tool `content`; deve gerar repair/protocol error e nao chamar executor.

Implementacao: passar `advertisedToolNames` ao loop com base em `toolDefs`, validar cada chamada e transformar rejeicao em mensagem compacta de reparo.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: contador/mock de executor permanece zero para tool nao anunciada.

### T013 - Preservar aliases apenas depois do gate correto

Status: pending

Evidencia: `normalizeToolNameWithAliases` aceita aliases como `read`, `patch`, `run`; isso e util, mas pode ampliar superficie se aplicado antes da allowlist.

Impacto: evita que alias textual contorne contrato anunciado.

Teste primeiro: `read` deve normalizar para `read_file` somente se `read_file` estiver anunciado; `content` nao deve normalizar para nada.

Implementacao: validar alias contra set anunciado e registrar nota de normalizacao.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: aliases validos continuam funcionando; nomes desconhecidos viram rejeicao reparavel.

### T014 - Adicionar fixture offline para falha real `content`

Status: pending

Evidencia: auditoria cita chamada `content` como falha real observada.

Impacto: transforma bug historico em regressao permanente.

Teste primeiro: fixture em `src/tests/fixtures` ou inline em `test-tool-call-parser` com saida real/minimizada.

Implementacao: cobrir parser + gate, nao depender de modelo real.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: fixture passa offline e falha se `content` for executavel.

## Fase 2 - Auditoria por turno

### T020 - Criar modelo de `TurnAudit`

Status: pending

Evidencia: auditoria pede prompt chars/tokens, tools anunciadas, parser strategy, calls, allowlist, args normalizados, results, memoria, blockers e motivo de parada.

Impacto: falhas reais deixam de depender de interpretacao subjetiva de logs.

Teste primeiro: teste unitario cria `TurnAudit` vazio e adiciona evento `tools_advertised`.

Implementacao: tipo puro sem IO persistente inicialmente.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: objeto serializa para JSON estavel.

### T021 - Registrar tools anunciadas por turno

Status: pending

Evidencia: `Agent.runToolLoop` calcula `toolDefs` antes do loop; esse e o ponto correto para snapshot.

Impacto: base para allowlist e debugging de tool surface.

Teste primeiro: fake agent/use-case recebe dois tools e audit contem exatamente esses nomes.

Implementacao: passar nomes para audit no inicio do loop.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: audit mostra tools anunciadas na ordem enviada ao modelo.

### T022 - Registrar parser strategy e trecho responsavel

Status: pending

Evidencia: `parseToolCallOrFinalDetailed` ja retorna `strategy`, mas nao ha telemetria obrigatoria por chamada.

Impacto: permite saber se a chamada veio de JSON primario, tag, scan embutido ou stream nativo.

Teste primeiro: parser de tagged call deve registrar `tagged_tool_call`.

Implementacao: anexar strategy ao envelope/audit.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: cada tool call no audit tem `strategy`.

### T023 - Registrar args normalizados e notas de normalizacao

Status: pending

Evidencia: `src/tools.ts:173-256` normaliza wrappers, path aliases, content aliases e apply_patch.

Impacto: mede se schema esta claro ou se o sistema esta consertando chamadas demais.

Teste primeiro: tool `write_file` com alias `data` deve registrar `content<-data`.

Implementacao: alterar normalizador para retornar `{ args, notes }` mantendo compatibilidade.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: comportamento final igual, audit contem notas.

### T024 - Persistir audit por turno em local controlado

Status: pending

Evidencia: referencia tem `OperationalRunStore`; arvore atual nao tem `src/agent-control`.

Impacto: permite replay e inspecao sem inflar prompt.

Teste primeiro: store grava JSON em diretorio temporario e lista ultimo run.

Implementacao: reintroduzir store minimo inspirado na referencia.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: arquivo de audit e criado somente quando habilitado ou em testes.

## Fase 3 - Contrato model-driven e tool surface

### T030 - Reintroduzir `intent-tool-contract.ts` com teste primeiro

Status: pending

Evidencia: referencia tem contrato em `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts`; arvore atual nao tem `src/agent-control`.

Impacto: remove decisao por keyword e centraliza surface model-visible.

Teste primeiro: portar/adaptar `test-intent-tool-contract.ts` antes do modulo.

Implementacao: criar `src/agent-control/intent-tool-contract.ts` com `IntentKind = "model_driven"`, internal tools e model-visible tools.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: textos diferentes geram contrato identico.

### T031 - Filtrar internal tools da surface model-visible

Status: pending

Evidencia: hoje `grep_file`, `search_code`, `rag_*` existem como tools diretas; auditoria quer primitivas internas atras de contratos.

Impacto: reduz escolhas para modelo pequeno e reforca `collect_evidence`.

Teste primeiro: `grep_file`, `search_code`, `rag_search`, `parse_ast`, `project_map` nao aparecem em `getExposedToolDefinitions` por padrao.

Implementacao: aplicar `filterToolDefinitionsForIntent` no agente.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: env `PHENOM_EXPOSE_INTERNAL_CONTEXT_TOOLS=1` pode expor para debug, padrao esconde.

### T032 - Adicionar `set_operational_contract` minimo

Status: pending

Evidencia: referencia registra `set_operational_contract`; arvore atual usa `set_plan/complete_step`.

Impacto: modelo declara fases e necessidades sem o controller inferir por prompt.

Teste primeiro: chamada com fases `explore/act/verify` retorna contrato aceito e auditavel.

Implementacao: tool inicialmente sem side effects destrutivos; salva contrato no audit/brain.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: contrato aparece no turno e nao executa nenhuma mutacao sozinho.

### T033 - Reduzir surface inicial em camadas

Status: pending

Evidencia: auditoria recomenda primeiro turno com `set_operational_contract`, `collect_evidence`, `read_file`, `path_exists`, `list_dir`, abrindo mutation/validation depois.

Impacto: menos ruido de selecao de tool para modelo pequeno.

Teste primeiro: em modo inicial, `write_file/apply_patch/run_code/browser_check` nao aparecem ate contrato liberar mutacao/validacao.

Implementacao: adicionar modo de surface por fase, default conservador no code assistant.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: tarefas simples ainda conseguem ler/listar; mutacao requer declaracao ou contexto operacional explicito.

### T034 - Compatibilizar `set_plan` com contrato operacional

Status: pending

Evidencia: `workflow-tools.ts` tem `set_plan`, `list_pending_tasks`, `complete_step`; nao deve ser descartado em patch grande.

Impacto: preserva comportamento atual enquanto evolui para contratos.

Teste primeiro: `set_plan` continua funcionando mesmo com `set_operational_contract` presente.

Implementacao: documentar `set_plan` como planejamento de execucao, nao contrato de surface.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: testes existentes de plan continuam passando.

### T035 - Definir manifesto pequeno de contratos como endpoints

Status: pending

Evidencia: contratos precisam ser API model-visible, nao fluxos rigidos nem instrucoes longas no prompt.

Impacto: reduz overhead cognitivo do modelo e preserva autonomia.

Teste primeiro: manifesto serializa contratos com `name`, `description`, `strategies`, `inputSchema`, `outputSchema` e `sideEffects`, sem exemplos de negocio que enviesem paths/tools.

Implementacao: criar manifesto inicial com poucos endpoints:

- `collect_evidence`: coleta e destila evidencias;
- `mutate_file`: aplica mudancas pequenas/seguras;
- `validate_work`: valida sintaxe/testes/runtime conforme escopo;
- `inspect_runtime`: observa processo/browser quando aplicavel;
- `set_operational_contract`: declara necessidade/fase sem executar.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: schema do manifesto cabe em prompt compacto e nao expoe ferramentas internas.

### T036 - Criar registry de estrategias por contrato

Status: pending

Evidencia: estrategia e funcao de um endpoint; nao deve virar tool independente nem estado persistente.

Impacto: permite implementacoes dinamicas sem engessar o modelo em fluxos complexos.

Teste primeiro: `collect_evidence` aceita estrategias `auto`, `symbol`, `path`, `diagnostic`, `runtime`, `diff`; estrategia invalida retorna repair curto com lista compacta.

Implementacao: criar registry puro:

- contrato;
- estrategia;
- custo esperado;
- precondicoes;
- metodos internos possiveis;
- tipo de evidencia produzida;
- fallback recomendado.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: estrategia nao altera surface de tools; altera apenas roteamento interno do contrato.

### T037 - Implementar roteamento dinamico de estrategia com fallback

Status: pending

Evidencia: modelo pode pedir estrategia especifica, mas controller deve adaptar quando ela nao e aplicavel, sem keyword routing de user prompt.

Impacto: evita engessamento e evita falha boba quando RAG/LSP/browser nao esta disponivel.

Teste primeiro: `collect_evidence(strategy="symbol")` usa lexical/AST quando disponivel; se AST indisponivel, cai para lexical e registra `fallbackReason`; se nada encontra, retorna ausencia comprovada.

Implementacao: roteador recebe contrato + estrategia + budget + alvos e decide metodos internos por custo/disponibilidade.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: audit registra `requestedStrategy`, `executedStrategies`, `fallbackReason`, `costEstimate` e `evidenceCount`.

### T038 - Medir overhead do manifesto e das estrategias

Status: pending

Evidencia: benchmark indica modelo capaz, mas tool_calling 90% nao justifica surface grande ou schema longo.

Impacto: garante que contratos/estrategias ajudem o modelo em vez de aumentar tokens e confusao.

Teste primeiro: teste calcula tamanho aproximado do manifesto e falha se ultrapassar limite configurado.

Implementacao: adicionar metricas no audit:

- chars/tokens do manifesto;
- quantidade de contratos anunciados;
- quantidade de estrategias por contrato;
- estrategia pedida vs executada;
- repairs por estrategia invalida.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: manifesto inicial fica pequeno, e aumento de estrategias exige justificativa por metrica.

## Fase 4 - Parser e reparo de protocolo

### T040 - Separar parser tolerante de executor estrito

Status: pending

Evidencia: parser aceita varios protocolos; executor precisa rejeitar o que nao esta anunciado.

Impacto: mantem suporte a modelos pequenos sem abrir execucao indevida.

Teste primeiro: parser pode extrair tool desconhecida, mas validator marca rejeitada.

Implementacao: nao endurecer parser diretamente; endurecer transicao parser->loop.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: parser fixtures antigas passam; gate barra execucao.

### T041 - Suportar multiplas tool calls em parser offline

Status: pending

Evidencia: referencia tem `parseToolCallsOrFinalDetailed`; arvore atual pega primeira tool em array/tag.

Impacto: reduz perda de chamadas em backends que emitem batelada.

Teste primeiro: `[TOOL_CALLS][{"name":"read_file"...},{"name":"git_status"...}]` retorna duas chamadas.

Implementacao: adicionar API nova sem remover `parseToolCallOrFinal`.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: loop pode continuar processando primeira chamada inicialmente; API nova coberta.

### T042 - Limitar reparos repetidos por classe

Status: pending

Evidencia: auditoria alerta que prompts repetidos de reparo degradam modelos pequenos.

Impacto: controla consumo de tokens e evita loops longos.

Teste primeiro: tres erros `invalid_args` geram resumo compacto em vez de tres mensagens longas.

Implementacao: contador por classe de erro no loop.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: audit registra `repair_suppressed_summary`.

### T043 - Proteger final answer generico apos tool

Status: pending

Evidencia: auditoria diz que loop nao deve aceitar facilmente `done` apos tool result.

Impacto: melhora confiabilidade de finalizacao.

Teste primeiro: depois de tool bem sucedida, final `done`/`ok` gera repair.

Implementacao: manter/ajustar guard existente no loop com criterio auditavel.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: final generico nao encerra se havia obrigacoes abertas.

## Fase 5 - EvidencePacket e `collect_evidence`

### T050 - Definir `EvidencePacket v1`

Status: pending

Evidencia: auditoria pede schema estavel: findings, anchors, obligations, nextActions, stalePaths, confidence; a arquitetura definida aqui exige que esse schema seja a saida unica dos coletores para o modelo.

Impacto: testes e controller deixam de parsear texto livre; MEMORY/SKILLS ficam separados como contexto persistente, nao como deposito de tool outputs.

Teste primeiro: validar objeto minimo com `findings[]`, `anchors[]`, `nextActions[]`.

Implementacao: criar tipos e renderer textual separado.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: renderer produz texto compacto para o modelo; objeto estruturado fica disponivel para audit e para eventual promocao explicita a MEMORY/SKILLS.

### T051 - Reintroduzir `collect_evidence` minimo

Status: pending

Evidencia: referencia tem `context-tools.ts` com `collect_evidence`; arvore atual nao registra context tools.

Impacto: cria contrato de contexto de baixo consumo.

Teste primeiro: `collect_evidence` com query e path retorna `[EVIDENCE_PACKET v1]` e pelo menos um anchor.

Implementacao: primeira versao usa `grep_file`, `read_file` e `path_exists` internamente.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: `grep_file` pode ficar interno, mas evidencia chega ao modelo via `collect_evidence`.

### T052 - Adicionar estrategia lexical controlada

Status: pending

Evidencia: atual `grep_file` ja usa `rg --json`; e candidato ideal para backend interno.

Impacto: contexto focado sem expor busca granular ao modelo.

Teste primeiro: query por simbolo retorna path e linha.

Implementacao: mover chamada para helper reutilizavel ou invocar ToolSystem internamente com audit.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: resultado limita quantidade e tamanho de snippets.

### T053 - Adicionar estrategia RAG opcional

Status: pending

Evidencia: `rag_status/index/search` existem; auditoria recomenda esconder atras de contrato unico.

Impacto: mantem capacidade sem inflar surface.

Teste primeiro: quando indice ausente, `collect_evidence` registra fallback lexical sem falhar.

Implementacao: chamar RAG apenas se status indicar indice presente, salvo parametro explicito.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: sem rede/embeddings, teste offline continua passando.

### T054 - Adicionar anchors self-contained antes de compaction

Status: pending

Evidencia: auditoria pede garantia formal de que achado importante vira anchor antes de compactar.

Impacto: preserva informacao suficiente para editar depois.

Teste primeiro: compaction recebe EvidencePacket e preserva anchors com path/range/resumo.

Implementacao: hook no loop antes de `compactLoopMessages`.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: anchor sobrevive a janela reduzida de mensagens.

## Fase 6 - Micro-contexto editavel

### T060 - Reintroduzir registry de micro-contexto

Status: pending

Evidencia: referencia tem `src/tools/micro-context.ts`; arvore atual nao tem esse modulo.

Impacto: permite edicoes pequenas com hash/range, alinhado ao baixo consumo.

Teste primeiro: criar contexto para path/range gera id e sha256.

Implementacao: modulo isolado sem integrar apply_patch inicialmente.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: registry detecta stale quando conteudo do arquivo muda.

### T061 - Renderizar micro-contexto em `read_file`

Status: pending

Evidencia: auditoria diz que read/mutation devem retornar contexto util ao modelo.

Impacto: o modelo ganha handle editavel sem reler arquivo inteiro.

Teste primeiro: `read_file` com range retorna `MICRO_CONTEXT id=...`.

Implementacao: adicionar opcao/env para gerar micro-contexto em reads.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: output continua compacto e compatibilidade mantida.

### T062 - Validar micro-contexto em `apply_patch`

Status: pending

Evidencia: auditoria pede validacao hash/range e reparo para contexto stale.

Impacto: evita patch aplicado em trecho errado.

Teste primeiro: patch com contextId stale deve falhar com erro reparavel.

Implementacao: aceitar `contextId` opcional em `apply_patch`.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: patch sem contextId continua funcionando; com contextId ganha seguranca.

### T063 - Proteger contra full rewrite indevido

Status: pending

Evidencia: auditoria destaca risco de document-sized replacement disfarçado.

Impacto: reduz dano em refatoracoes grandes.

Teste primeiro: `apply_patch` que substitui quase arquivo inteiro sem declaracao de full rewrite deve ser recusado.

Implementacao: medir proporcao alterada e exigir flag/contrato.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: pequenas edicoes passam, full rewrite exige intencao explicita.

## Fase 7 - Destilacao canonica de contexto

Sequencia obrigatoria desta fase:

1. Criar tipos puros e testes sem integrar no loop.
2. Capturar `ToolEvent` em paralelo ao fluxo atual, sem mudar prompt.
3. Destilar eventos fake em `EvidenceEntry` com testes offline.
4. Selecionar evidence por budget.
5. Carregar MEMORY/SKILLS de arquivos persistentes, sem tool output.
6. Renderizar `ModelTurnContext`.
7. Integrar no fluxo de mensagens.
8. Adicionar testes anti-vazamento.

Regra de rollout: ate T075, nenhuma mudanca deve alterar comportamento do modelo em producao; tudo pode existir como camada paralela testada. A primeira mudanca perceptivel no prompt so deve acontecer em T076, quando o renderer ja estiver protegido por testes.

### T070 - Criar tipos `ToolEvent`, `EvidenceEntry` e `ModelTurnContext`

Status: pending

Evidencia: a arquitetura correta exige separar bruto interno, evidencia destilada e contexto renderizado ao modelo. Hoje outputs de tools ainda chegam ao loop como texto formatado e podem ser reinjetados sem fronteira clara.

Impacto: cria o contrato interno que impede misturar raw output, evidence, MEMORY e SKILLS.

Teste primeiro: teste de tipos/helpers cria:

- `ToolEvent` com `turnId`, `toolName`, `args`, `success`, `output`, `error`, `timestamp`;
- `EvidenceEntry` com `id`, `kind`, `confidence`, `sourceTool`, `proof`, `use`, `rawRef`;
- `ModelTurnContext` com `task`, `mode`, `budget`, `contracts`, `evidence`, `obligations`, `nextAction`, `memory?`, `skills?`.

Implementacao: criar modulo sugerido `src/context/types.ts`.

Passos de implementacao:

1. Criar diretorio `src/context/`.
2. Criar `src/context/types.ts`.
3. Definir `ToolEvent`:
   - `turnId: string`;
   - `callId?: string`;
   - `toolName: string`;
   - `args: Record<string, unknown>`;
   - `success: boolean`;
   - `output: string`;
   - `error: string | null`;
   - `timestamp: number`;
   - `rawRef?: string`.
4. Definir `EvidenceKind` como union inicial:
   - `file_slice`;
   - `search_hit`;
   - `validation_error`;
   - `runtime_error`;
   - `browser_observation`;
   - `git_change`;
   - `command_output`;
   - `absence`.
5. Definir `EvidenceEntry`:
   - `id`;
   - `kind`;
   - `confidence`;
   - `sourceTool`;
   - `proof`;
   - `use`;
   - `path?`;
   - `lines?`;
   - `severity?`;
   - `rawRef?`;
   - `metadata?`.
6. Definir `ContractSummary` compacto para `[CONTRACTS]`.
7. Definir `ModelTurnContext` com campos opcionais `memory` e `skills`, mas sem default automatico.
8. Criar helper puro `createEvidenceId(index)` ou aceitar ids externos; evitar dependencia global.
9. Criar teste unitario `src/tests/unit/test-model-context.ts` começando por tipos/helpers.

Criterio de aceite: nenhum prompt muda nesta task; apenas tipos, helpers puros e testes.

### T071 - Capturar tool result como `ToolEvent` interno

Status: pending

Evidencia: toda tool que coleta dados precisa passar por serializacao antes de virar contexto destilado.

Impacto: raw output passa a ficar no agente/audit, nao no prompt.

Teste primeiro: no loop com executor fake, uma chamada `read_file` gera `ToolEvent`; o model context renderizado nao contem o raw output.

Implementacao: criar `src/context/tool-event.ts` e integrar depois de `executeToolWithEvents` no loop. O evento pode apontar para audit/rawRef, mas nao deve ser renderizado diretamente.

Passos de implementacao:

1. Criar `src/context/tool-event.ts`.
2. Implementar `createToolEvent(input)` que recebe `turnId`, `toolName`, `args`, `ToolResultLike`, `callId?`.
3. Implementar `summarizeRawOutputForAudit(output)` somente para metadata interna, nao para modelo.
4. Criar `ToolEventStore` simples em memoria por turno:
   - `add(event)`;
   - `list(turnId)`;
   - `clear(turnId)`.
5. Integrar no `runToolLoopUseCase` logo apos `toolResult` ser produzido e antes de formatar resposta para modelo.
6. Manter o fluxo atual de tool response intacto nesta task; a captura roda em paralelo.
7. Adicionar teste de loop com executor fake:
   - executor retorna output bruto com `---BEGIN CONTENT---`;
   - `ToolEventStore` recebe esse output;
   - nenhuma funcao de render de contexto e chamada ainda.
8. Registrar no audit/event store `rawRef`, mas nao colocar `rawRef` no prompt.

Criterio de aceite: raw output existe no audit/event store; nao entra em `ModelTurnContext`.

### T072 - Criar destiladores de evidencias por familia de tool

Status: pending

Evidencia: read/grep/RAG/AST/LSP/browser/git/shell sao coletores diferentes, mas a saida para o modelo deve ser uma so: evidencia minima e tangivel.

Impacto: transforma dados brutos em contexto perfeito para o modelo, sem exagero e sem perda da prova essencial.

Teste primeiro: eventos fake de `read_file`, `grep_file`, `run_validation`, `browser_check`, `git_diff` e `run_code` produzem `EvidenceEntry[]` com campos comuns e sem output bruto completo.

Implementacao: criar modulo sugerido `src/context/evidence-distillers.ts` com destiladores pequenos por familia de tool:

- filesystem/search: path, range, trecho, hash quando possivel;
- validation/LSP: erro, severidade, path/range, comando/validator;
- browser/runtime: console/page/request errors como blocking, DOM/canvas como evidence-only;
- git: arquivos alterados, diff summary, status;
- command: comando, exit code, linhas relevantes.

Passos de implementacao:

1. Criar `src/context/evidence-distillers.ts`.
2. Exportar `distillToolEvent(event: ToolEvent): EvidenceEntry[]`.
3. Implementar roteamento por `event.toolName`.
4. Implementar `distillReadFile`:
   - reconhecer metadata `[READ_FILE]`;
   - extrair `path`, `range`, `truncated`;
   - selecionar no maximo pequeno trecho relevante;
   - nunca copiar corpo inteiro;
   - preencher `proof` com fato verificavel, nao resumo vago.
5. Implementar `distillGrepFile`:
   - extrair `file:line`;
   - limitar hits;
   - criar uma entry por hit ou grupo pequeno.
6. Implementar `distillValidation`:
   - detectar `[SYNTAX_FAIL]`, `[SYNTAX_OK]`, exit code e severidade;
   - erro de sintaxe vira `validation_error`;
   - sucesso pode virar evidence de validacao quando relevante.
7. Implementar `distillBrowserCheck` preparado para:
   - console/page/request errors como `runtime_error`;
   - DOM/canvas snapshot como `browser_observation` evidence-only.
8. Implementar `distillGit`:
   - status/diff summary;
   - arquivos alterados;
   - nao incluir diff gigante.
9. Implementar fallback `distillGenericCommand`:
   - comando;
   - exit code;
   - 3-8 linhas relevantes;
   - output bruto fica em `rawRef`.
10. Criar testes com eventos fake para cada familia.
11. Criar teste negativo provando que `EvidenceEntry.proof` nao contem output bruto grande.

Criterio de aceite: modelo recebe entradas destiladas; audit guarda referencia ao bruto.

### T073 - Selecionar `EvidencePacket` por budget

Status: pending

Evidencia: o plano correto exige que o modelo receba uma unica composicao de contexto derivada das ferramentas, nao multiplas fontes concorrentes.

Impacto: estabelece o canal oficial de contexto operacional para o modelo.

Teste primeiro: multiplas entradas de evidencia sao ordenadas, deduplicadas, limitadas por budget e renderizadas em uma unica secao `[EVIDENCE]`; entradas rejeitadas ficam internas.

Implementacao: criar `src/context/select-evidence.ts` com budget por entrada, prioridade por relevancia e garantia de preservar provas essenciais.

Passos de implementacao:

1. Criar `src/context/select-evidence.ts`.
2. Definir budgets iniciais:
   - `tiny`: poucas entradas, proof/use curtos;
   - `small`: entradas principais;
   - `focused`: permite mais evidencias, ainda sem bruto;
   - `large`: reservado para debug, nao padrao.
3. Implementar medicao por bytes/chars e tokens somente quando houver tokenizer real disponivel.
4. Implementar ranking:
   - blocking errors primeiro;
   - evidence citada por obligations;
   - paths diretamente alvo;
   - confidence high;
   - duplicatas removidas por `kind/path/lines/proof`.
5. Implementar dedupe de entries equivalentes.
6. Implementar truncamento de `proof` e `use` por limite, preservando path/range.
7. Implementar retorno com:
   - `selected`;
   - `rejected`;
   - `budgetUsed`;
   - `budgetLimit`.
8. Testar que uma entrada critica nao e removida por entries informativas.
9. Testar que output bruto em uma entry malformada e cortado/rejeitado.

Criterio de aceite: prompt nao contem outputs brutos das tools quando pacote destilado esta disponivel; evidencias preservam `proof` e `use`.

### T074 - Carregar MEMORY e SKILLS apenas de fontes persistentes

Status: pending

Evidencia: as unicas fontes persistentes de contexto devem ser memoria pratica do projeto e regras/preferencias do usuario.

Impacto: preserva continuidade entre sessoes sem criar memoria concorrente com evidencia do turno.

Teste primeiro:

- se `MEMORY.md`/`.MEMORY.md` nao existe, `[MEMORY]` nao aparece;
- se `SKILLS.md`/`.SKILL.md` nao existe, `[SKILLS]` nao aparece;
- tool output recem-coletado nunca cria `[MEMORY]`;
- regra explicita confirmada pode aparecer em `[SKILLS]`.

Implementacao: criar `src/context/persistent-context.ts` com leitura compacta de `MEMORY.md`/`.MEMORY.md` e `SKILLS.md`/`.SKILL.md`, compatibilidade de nomes e limite de entradas.

Passos de implementacao:

1. Criar `src/context/persistent-context.ts`.
2. Definir busca de arquivos em ordem:
   - MEMORY: `MEMORY.md`, depois `.MEMORY.md`;
   - SKILLS: `SKILLS.md`, depois `.SKILL.md`.
3. Implementar `loadPersistentContext(cwd, opts)` retornando:
   - `memory: string[]`;
   - `skills: string[]`;
   - `sources: { memoryPath?, skillsPath? }`.
4. Implementar parser simples por linhas/bullets/headings:
   - ignorar linhas vazias;
   - limitar entradas;
   - limitar tamanho por entrada;
   - nao interpretar tool output como memoria.
5. Implementar filtro por relevancia opcional ao task text sem buscar semanticamente nesta task.
6. Implementar regra: arquivo inexistente => array vazio, nao bloco vazio.
7. Implementar regra: candidate updates de runtime nao entram aqui.
8. Criar testes com temp dir:
   - nenhum arquivo => sem memory/skills;
   - apenas `.MEMORY.md` => memory carregada;
   - `MEMORY.md` e `.MEMORY.md` => preferir `MEMORY.md`;
   - skill explicita em `SKILLS.md` => aparece;
   - texto bruto com `---BEGIN CONTENT---` no arquivo deve ser truncado ou rejeitado.

Criterio de aceite: audit mostra exatamente quais trechos persistentes foram injetados e por que.

### T075 - Renderizar `ModelTurnContext` no formato exato enviado ao modelo

Status: pending

Evidencia: a conversa definiu que deve ficar claro o que e enviado ao modelo e o que fica no agente.

Impacto: cria uma unica funcao responsavel pelo prompt variavel, evitando vazamento de bruto e blocos inexistentes.

Teste primeiro: renderizacao sem memory/skills nao contem `[MEMORY]` nem `[SKILLS]`; renderizacao com evidence contem `[EVIDENCE]`; renderizacao nunca contem `---BEGIN CONTENT---`, `[READ_FILE]`, `rawOutput` ou `rg --json`.

Implementacao: criar `src/context/render-model-context.ts` com renderer de:

- `[TURN_CONTEXT v1]`;
- `[CONTRACTS]`;
- `[SKILLS]` somente quando houver;
- `[MEMORY]` somente quando houver;
- `[EVIDENCE]`;
- `[OBLIGATIONS]`;
- `[NEXT_ACTION]`.

Passos de implementacao:

1. Criar `src/context/render-model-context.ts`.
2. Implementar `renderModelTurnContext(ctx: ModelTurnContext): string`.
3. Renderizar sempre:
   - `[TURN_CONTEXT v1]`;
   - `task`;
   - `mode`;
   - `budget`.
4. Renderizar `[CONTRACTS]` somente com manifesto compacto recebido em `ctx.contracts`.
5. Renderizar `[SKILLS]` somente se `ctx.skills.length > 0`.
6. Renderizar `[MEMORY]` somente se `ctx.memory.length > 0`.
7. Renderizar `[EVIDENCE]` somente se houver evidence selecionada.
8. Renderizar evidence em formato fixo:
   - `E1 file_slice confidence=high`;
   - `source: read_file`;
   - `path: ...`;
   - `lines: ...`;
   - `proof: ...`;
   - `use: ...`.
9. Renderizar `[OBLIGATIONS]` com ids `O1`, `O2`.
10. Renderizar `[NEXT_ACTION]` com uma frase curta.
11. Implementar `assertNoRawContextLeak(rendered)` usado em teste e opcionalmente em dev.
12. Criar snapshot tests pequenos.

Criterio de aceite: snapshots pequenos do renderer provam a forma exata enviada ao modelo.

### T076 - Integrar `ModelTurnContext` em `build-inference-messages`

Status: pending

Evidencia: system prompt deve ficar estavel; contexto variavel deve entrar como bloco separado para reduzir quebra de KV cache e evitar prompt inchado.

Impacto: conecta a arquitetura ao fluxo real de inferencia.

Teste primeiro: `buildInferenceMessagesUseCase` ou wrapper equivalente inclui system prompt fixo e uma mensagem de contexto variavel sem raw outputs.

Implementacao: integrar `renderModelTurnContext` na montagem de mensagens, preferencialmente apos system prompt fixo e antes do pedido atual, com budget configuravel.

Passos de implementacao:

1. Localizar ponto de montagem em `src/use-cases/build-inference-messages.ts` e chamada em `src/agent.ts`.
2. Adicionar parametro opcional `modelTurnContext?: string` ao use-case, sem quebrar chamadas existentes.
3. Inserir contexto variavel como mensagem separada apos system prompt fixo.
4. Garantir que a mensagem de contexto nao substitui o user input atual.
5. Garantir que compaction nao remove o user input atual.
6. Integrar inicialmente atras de flag/env, por exemplo `PHENOM_MODEL_CONTEXT_V1=1`, para rollout seguro.
7. Criar builder no agente ou loop:
   - carrega persistent context;
   - seleciona evidence do turno;
   - renderiza model context;
   - passa ao build messages.
8. Medir chars/tokens do context block no audit.
9. Testar com `buildInferenceMessagesUseCase` que:
   - system prompt permanece igual;
   - context block aparece uma vez;
   - raw tool output nao aparece.

Criterio de aceite: system prompt nao cresce com tool outputs; contexto variavel e compacto e rastreavel no audit.

### T077 - Testar regras anti-vazamento de contexto bruto

Status: pending

Evidencia: o maior risco e voltar a mandar "contexto minimo" gigante ou bruto para o modelo.

Impacto: protege o objetivo de baixo consumo de tokens.

Teste primeiro: suite com asserts negativos:

- model context nao contem raw full file;
- model context nao contem `---BEGIN CONTENT---`;
- model context nao contem output JSON bruto de `rg`;
- model context nao contem `[MEMORY]` sem arquivo/promoção;
- model context nao contem `[SKILLS]` sem arquivo/regra confirmada.

Implementacao: criar teste unitario dedicado para `renderModelTurnContext` e `persistent-context`.

Passos de implementacao:

1. Criar suite `src/tests/unit/test-model-turn-context.ts`.
2. Criar fixture de raw read_file com `---BEGIN CONTENT---` e conteudo grande.
3. Criar fixture de raw rg JSON.
4. Criar fixture de MEMORY ausente.
5. Criar fixture de SKILLS ausente.
6. Testar que o renderer rejeita ou nao inclui bruto.
7. Testar que MEMORY/SKILLS ausentes nao geram headings vazios.
8. Testar que MEMORY/SKILLS presentes geram headings.
9. Testar que tool output recem-coletado aparece apenas como `[EVIDENCE]`.
10. Adicionar script ou incluir no `test:agent-infra` quando essa suite existir.

Criterio de aceite: qualquer vazamento bruto falha em teste offline.

## Fase 8 - Validacao, LSP e runtime/browser

### T080 - Reintroduzir `run_validation` canonico

Status: pending

Evidencia: referencia tem `run_validation`; arvore atual tem `validate_syntax` e `run_tests`, mas nao contrato canonico.

Impacto: valida por escopo e tipo de projeto com retorno unificado.

Teste primeiro: `run_validation` em arquivo TS chama syntax/project validation conforme escopo fake.

Implementacao: portar incremental de `workflow-tools.ts` da referencia.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: resultado inclui severidade e escopo.

### T081 - Classificar diagnosticos por severidade

Status: pending

Evidencia: auditoria pede categorias `blocking`, `warning`, `informational`, `evidence-only`.

Impacto: falso positivo nao sequestra loop.

Teste primeiro: canvas snapshot vazio e `evidence-only`; syntax error e `blocking`.

Implementacao: criar `validation-policy.ts` minimo.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: finalizacao so bloqueia por severidade blocking.

### T082 - Reintroduzir LSP TypeScript/JS calibrado

Status: pending

Evidencia: referencia tem `lsp-diagnostics.ts`, `lsp-client.ts`, `lsp-registry.ts`, `lsp-installer.ts`; arvore atual nao lista esses arquivos.

Impacto: melhora evidencia de codigo sem exigir full read.

Teste primeiro: JS sem `checkJs` nao recebe typecheck bloqueante.

Implementacao: portar diagnostico local primeiro; auto-install fica separado.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: diagnosticos entram em EvidencePacket com severidade.

### T083 - Reintroduzir `start_background_command`

Status: pending

Evidencia: referencia tem tool em `utility-tools.ts`; arvore atual nao.

Impacto: viabiliza fluxo frontend real sem improvisar com `run_code`.

Teste primeiro: comando fake que imprime porta gera runtime target com pid/status.

Implementacao: registry de processo em memoria, timeout e readiness.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: processo pode ser consultado e encerrado.

### T084 - Reintroduzir `browser_check` como evidencia, nao criterio de negocio

Status: pending

Evidencia: auditoria diz que canvas blank nao deve virar failure global.

Impacto: frontend diagnostics fica util sem falso erro.

Teste primeiro: browser_check com snapshot canvas blank retorna `evidence-only`, success true se nao ha console/page error hard.

Implementacao: portar tool com retorno tipado de console/page/request/dom/canvas.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: erros de console/page sao blocking; snapshot visual e informativo.

### T085 - Criar fluxo canonico frontend runtime

Status: pending

Evidencia: auditoria pede protocolo `start_background_command -> runtimeTarget -> browser_check`.

Impacto: tarefas frontend ficam testaveis.

Teste primeiro: use-case com server fake passa URL detectada para browser_check mock.

Implementacao: contrato operacional de runtime, sem depender do modelo escolher URL manualmente.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: cleanup do processo ocorre no fim do teste/turno.

## Fase 9 - Filesystem e patch atomico

### T090 - Formalizar `MutationIntent`

Status: pending

Evidencia: auditoria pede representacao formal de mutacao pretendida separada do payload de patch.

Impacto: permite verificar se patch parcial cumpriu plano.

Teste primeiro: intent com file, operation, expectedChange valida contra patch aplicado.

Implementacao: tipo pequeno e audit; sem bloquear execucao inicialmente.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: audit mostra intent e diff observado.

### T091 - Medir risco de full rewrite em `write_file`

Status: pending

Evidencia: `write_file` substitui arquivo inteiro; descricao orienta usar `apply_patch` para edicao parcial.

Impacto: evita perda grande de codigo.

Teste primeiro: write_file em arquivo existente com mudanca pequena sugerida deve retornar aviso ou exigir flag.

Implementacao: comparar conteudo anterior e novo; classificar rewrite.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: create file novo continua simples; overwrite grande fica auditado.

### T092 - Melhorar erros reparaveis de `apply_patch`

Status: pending

Evidencia: auditoria pede reparos para patch sem replace, range incoerente e contexto stale.

Impacto: reduz loops de patch falho.

Teste primeiro: operacao sem `replace` retorna missingFields estruturado.

Implementacao: padronizar erro com `recoverable`, `missingFields`, `normalizedArgs`.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: modelo recebe schema minimo para reenviar chamada correta.

## Fase 10 - RAG, AST e busca

### T100 - Transformar RAG/AST em estrategias internas de contexto

Status: pending

Evidencia: auditoria diz que `get_context`, `build_task_context`, `collect_evidence`, RAG e AST carregam historico demais.

Impacto: reduz tool surface e estabiliza regra de negocio.

Teste primeiro: `getExposedToolDefinitions` nao mostra `rag_search`/`parse_ast` por padrao.

Implementacao: manter registrars, mas filtrar model-visible.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: tools internas podem ser chamadas pelo controller.

### T101 - Criar metrica custo/beneficio por estrategia de contexto

Status: pending

Evidencia: auditoria pede tokens gastos por estrategia vs precisao da evidencia.

Impacto: orienta baixo consumo com dados.

Teste primeiro: collect_evidence registra bytes/chars por estrategia e tokens somente quando houver contador real.

Implementacao: adicionar campos no audit.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: output final de audit mostra custo de lexical/RAG/AST/read_file.

## Fase 11 - Metricas de baixo consumo

### T110 - Medir tokens de prompt/schema/memoria/evidencia/reparos

Status: partial

Evidencia: auditoria lista essa metrica como insuficiente.

Impacto: toda refatoracao pode ser avaliada pelo objetivo central do projeto.

Teste primeiro: contador fake retorna tokens por bloco e audit soma corretamente.

Implementacao: expandir `TurnAudit` com buckets.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: cada turno tem resumo `tokens.system`, `tokens.tools`, `tokens.memory`, `tokens.evidence`, `tokens.repairs`.

Atualizacao parcial em 2026-07-09:

- Entregue no Zig: parser de contadores reais do backend (`prompt_eval_count`/`eval_count`, `tokens_evaluated`/`tokens_predicted`, `usage.prompt_tokens`/`usage.completion_tokens`) sem fallback estimado.
- Entregue no Zig: `token_update` absoluto atualiza a statusbar interativa com `in/out/tok/s`; o SQLite persiste somente o `token_usage` final para evitar spam por token.
- Provado por smoke real `token-accounting-real-20260709b`: `token_usage|input=611 output=35 total=646 tokens_per_second=40.49 exact=true final=true`.
- Nao entregue: buckets por bloco (`system`, `tools`, `memory`, `evidence`, `repairs`) ainda nao existem porque isso exige tokenizer real pre-envio por backend.
- Regra mantida: nao ha estimativa de tokens. Se o backend nao fornecer contador real, nenhum token e registrado.

### T111 - Medir economia vs `read_file` completo

Status: pending

Evidencia: objetivo do projeto e evitar ler projeto inteiro usando contexto sob demanda.

Impacto: comprova valor de collect_evidence/micro-contexto.

Teste primeiro: EvidencePacket com snippet de 1000 chars contra arquivo 10000 chars registra economia por bytes/chars; tokens entram somente com tokenizer real.

Implementacao: medir bytes/chars poupados por anchor e adicionar tokens poupados apenas quando `/tokenize` real estiver integrado.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: audit reporta economia sem afetar prompt.

### T112 - Criar limite adaptativo de reparos por token budget

Status: pending

Evidencia: reparos sucessivos podem consumir mais que a economia de contexto.

Impacto: evita loops caros.

Teste primeiro: com budget baixo, segundo reparo longo vira resumo curto.

Implementacao: usar buckets do audit para decidir repair verbosity.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: comportamento e deterministico em teste offline.

## Fase 12 - Learning loop e skills

### T120 - Definir promocao explicita para MEMORY

Status: pending

Evidencia: MEMORY deve guardar informacoes entre sessoes de tasks, insights do projeto e fatos praticos verificados do diretorio vigente. Tool result bruto nao deve virar memoria automaticamente.

Impacto: evita transformar ruido de tool em contexto permanente e mantem MEMORY como fonte persistente util.

Teste primeiro: EvidenceEntry temporaria nao altera MEMORY; uma promocao explicita com fato verificado grava entrada compacta.

Implementacao: criar regra de promocao: somente fatos verificados, reutilizaveis e relevantes ao projeto podem entrar em MEMORY. Cada entrada deve ter fonte/evidencia resumida.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: MEMORY nao contem output bruto de tool; contem fato pratico, origem e data/escopo.

### T121 - Definir promocao explicita para SKILLS

Status: pending

Evidencia: SKILLS deve guardar regras absolutas e preferencias do usuario verificadas pela query/interacao. Exemplo: "nunca use any" vira regra absoluta.

Impacto: preferencias do usuario deixam de depender de memoria de conversa e passam a orientar tarefas futuras de forma consistente.

Teste primeiro: query do usuario com regra explicita gera candidate skill; regra so e persistida quando confirmada como preferencia operacional, nao inferida de forma fraca.

Implementacao: distinguir:

- regra explicita do usuario: pode ser persistida como absoluta;
- preferencia inferida: fica candidate ate confirmacao;
- padrao tecnico aprendido em tarefa: exige evidencia de sucesso antes de virar skill.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: SKILLS nao recebe fatos de projeto; recebe somente regras/preferencias/padroes operacionais.

## Fase 13 - Relatorios e CLI

### T130 - Expor resumo de audit no CLI

Status: pending

Evidencia: auditoria pede painel unico por turno.

Impacto: usuario consegue entender tools anunciadas, chamadas, resultados, memoria e motivo de parada.

Teste primeiro: renderer recebe `TURN_AUDIT_SUMMARY` e renderiza linhas essenciais.

Implementacao: evento novo ou reuse de progress com payload estruturado.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: CLI mostra resumo curto sem poluir conversa.

### T131 - Adicionar comando para replay de audit

Status: pending

Evidencia: referencia tem `operational-run-inspector`.

Impacto: depuracao de falhas reais fica reprodutivel.

Teste primeiro: store com um run renderiza summary e replay.

Implementacao: portar inspector minimo.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: comando lista runs e mostra detalhes de um id.

## Fase 14 - Suites reais

### T140 - Criar `test-real-agent-flow` com modelo real mas criterio de infraestrutura

Status: pending

Evidencia: auditoria pede validar tool advertised, called, result returned, evidence injected, memory compacted, parser intacto e final nao generico.

Impacto: mede agente sem exigir que modelo resolva bug seeded.

Teste primeiro: definir harness e asserts de fluxo antes de tarefas complexas.

Implementacao: usar prompts pequenos e criterios de eventos/audit.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: falha aponta para componente de infraestrutura.

### T141 - Criar `test-real-model-capability` separado

Status: pending

Evidencia: benchmark atual mostra capacidade real do modelo; essa medicao deve existir, mas fora da suite de infraestrutura.

Impacto: melhora calibracao de prompts sem bloquear core infra.

Teste primeiro: script existe e gera relatorio sem afetar `test:agent-infra`.

Implementacao: mover ou referenciar benchmarks.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: falha classificada como capacidade/estrategia, nao regressao de agente.

### T142 - Capturar fixtures reais de saida do modelo

Status: pending

Evidencia: auditoria pede fixtures de saidas reais problematicas para parser offline.

Impacto: parser evolui sem depender de rodar modelo a cada teste.

Teste primeiro: fixture `content-tool-call` falha antes do gate e passa depois.

Implementacao: salvar saidas minimizadas em `src/tests/fixtures`.

Passos de implementacao:

1. Criar ou ajustar o teste que deve falhar sem esta mudanca.
2. Identificar os arquivos e pontos de integracao antes de editar codigo.
3. Implementar a menor API/helper necessario para satisfazer o teste.
4. Integrar o helper no fluxo existente sem alterar comportamento nao relacionado.
5. Rodar o teste especifico da task e registrar o resultado no devlog.
6. Revisar se a mudanca respeita baixo consumo de tokens, evidencia destilada e ausencia de contexto bruto no prompt.

Criterio de aceite: fixtures rodam em `test:agent-infra`.

## Fase 15 - Context profiles e News operacional

Esta fase existe para corrigir uma interpretacao errada: micro-contexto e adequado para codigo, mas nao para todos os dominios. News deve operar com contexto operacional amplo, persistente e indexado, sem despejar esse volume no prompt do modelo.

Referencia principal: `/home/ashirak/Projects/person/ai/ollama_cli/client_v1/cli-agent-v2`.

### T150 - Definir `ContextProfile` por dominio

Status: pending

Evidencia: o plano anterior tratava "contexto destilado minimo" como regra geral. Isso nao cobre News, PDFs, logs e leitura massiva. O benchmark mostra modelo forte em agentic/logical/tool calling, mas contexto longo e prompt inchado continuam sendo risco; a solucao e escolher o perfil certo por dominio, nao forcar micro-contexto sempre.

Impacto: evita limitar o agente em tarefas que precisam de agregacao ampla, mantendo baixo consumo onde ele realmente ajuda.

Teste primeiro: criar teste que mapeia tarefas para perfis: edicao de codigo -> `code_micro`; noticias -> `news_operational`; leitura de log/PDF grande -> `mass_read`; browser/runtime -> `runtime_diagnostics`.

Implementacao: criar tipo pequeno `ContextProfile` e resolver perfil por contrato operacional, nao por keyword solta do prompt. A selecao deve vir do contrato chamado ou do modo ativo.

Passos de implementacao:

1. Criar teste unitario para resolver perfil a partir de contrato/mode.
2. Criar tipo `ContextProfile` em modulo de contexto/contratos.
3. Integrar no manifesto de contratos sem aumentar a tool surface.
4. Fazer `collect_evidence` usar `code_micro` por padrao.
5. Reservar `news_operational` e `mass_read` para contratos especificos.
6. Registrar perfil escolhido no audit do turno.

Criterio de aceite: micro-contexto nao e aplicado automaticamente a News/log/PDF; o audit mostra o perfil usado.

### T150A - Implementar o tipo `ContextProfile` e sua politica operacional

Status: pending

Evidencia: declarar perfis no documento nao basta. O codigo precisa de uma entidade real que diferencie o que o agente faz internamente, o que persiste, o que pode ir ao modelo e qual formato de output cada dominio usa.

Impacto: impede que `code_micro`, `news_operational`, `mass_read` e `runtime_diagnostics` virem apenas nomes soltos no prompt. O perfil passa a ser contrato do controller.

Teste primeiro: criar teste unitario que valida a matriz de politica:

- `code_micro`: permite micro-contexto, path/range/hash, EvidencePacket curto, mutacao segura.
- `news_operational`: permite catalogo/cache/chunks internos, proibe catalogo bruto no prompt, renderiza `NEWS_DOSSIER`.
- `mass_read`: permite ingestao/chunks/resumo hierarquico, proibe dump bruto.
- `runtime_diagnostics`: permite sinais de processo/browser/LSP, renderiza diagnostico objetivo.

Implementacao: criar modulo de contexto com `ContextProfile`, `ContextProfilePolicy` e helpers de consulta (`allowsMicroContext`, `modelOutputKind`, `storageScope`, `defaultBudget`).

Passos de implementacao:

1. Criar teste `context-profile-policy` com a matriz acima.
2. Criar tipo union/string literal `ContextProfile`.
3. Criar objeto/tabela de politica por perfil.
4. Adicionar helpers puros para consultar politica sem depender do Agent.
5. Garantir que perfil desconhecido falha fechado, nao cai em `code_micro`.
6. Registrar no devlog quais campos da politica entram no audit.

Criterio de aceite: cada perfil tem comportamento formal em codigo e teste, nao apenas documentacao.

### T150B - Resolver `ContextProfile` a partir do contrato operacional

Status: pending

Evidencia: escolher perfil por palavras-chave recriaria o erro criticado no audit. O perfil deve vir do contrato chamado pelo modelo ou do modo operacional ja estabelecido pelo controller.

Impacto: o agente consegue alternar entre codigo, news, leitura massiva e runtime sem heuristica textual fragil.

Teste primeiro: chamadas de contrato resolvem perfil:

- `collect_evidence` -> `code_micro`;
- `mutate_file` -> `code_micro`;
- `research_news` -> `news_operational`;
- `read_large_document` ou `analyze_logs` -> `mass_read`;
- `inspect_runtime`/`browser_check` -> `runtime_diagnostics`.

Implementacao: criar `resolveContextProfileForContract(contractName, mode, explicitProfile?)`. `explicitProfile` so e aceito se for permitido pelo contrato.

Passos de implementacao:

1. Criar teste de resolver por contrato.
2. Criar mapa `contract -> allowedProfiles -> defaultProfile`.
3. Permitir override explicito somente dentro dos perfis permitidos.
4. Rejeitar override invalido com erro reparavel curto.
5. Integrar resolver ao manifesto de contratos.
6. Registrar `requestedProfile`, `resolvedProfile` e `reason` no audit.

Criterio de aceite: nenhuma task muda de perfil por frase do usuario; muda por contrato/override validado.

### T150C - Separar renderizadores por `ContextProfile`

Status: pending

Evidencia: `EvidencePacket` serve bem para codigo, mas News precisa de dossie operacional e leitura massiva precisa de resumo hierarquico. Um renderer unico vai forcar dominios diferentes no mesmo molde.

Impacto: evita que News vire micro-contexto e evita que codigo receba dumps agregados grandes.

Teste primeiro: o mesmo `ModelTurnContext` com perfis diferentes gera blocos diferentes:

- `code_micro` -> `[EVIDENCE]`;
- `news_operational` -> `[NEWS_DOSSIER v1]`;
- `mass_read` -> `[DOCUMENT_SUMMARY v1]` ou `[LOG_ANALYSIS v1]`;
- `runtime_diagnostics` -> `[RUNTIME_DIAGNOSTICS v1]`.

Implementacao: criar dispatch de renderizacao por perfil, mantendo `[MEMORY]` e `[SKILLS]` como blocos opcionais globais.

Passos de implementacao:

1. Criar snapshots de renderizacao por perfil.
2. Extrair renderer atual de Evidence para `renderCodeMicroContext`.
3. Criar stubs testaveis para `renderNewsOperationalContext`, `renderMassReadContext` e `renderRuntimeDiagnosticsContext`.
4. Garantir que cada renderer tem budget proprio.
5. Bloquear catalogo bruto, raw file dump, raw logs e raw tool output no renderer.
6. Integrar o dispatch no `ModelTurnContext`.

Criterio de aceite: cada perfil tem formato de prompt proprio e testado.

### T150D - Adicionar orcamento e limites por `ContextProfile`

Status: pending

Evidencia: "baixo consumo" nao significa sempre minimo; significa gastar tokens onde traz ganho operacional. News pode usar mais contexto que codigo, mas ainda precisa de limite.

Impacto: permite perfis ricos sem explodir prompt ou alucinar o modelo pequeno.

Teste primeiro: budgets default diferem por perfil e truncam no lugar correto:

- `code_micro`: poucos trechos, hashes e ranges.
- `news_operational`: top eventos/fontes, nao catalogo inteiro.
- `mass_read`: resumo hierarquico e top evidencias.
- `runtime_diagnostics`: erros/sinais priorizados por severidade.

Implementacao: criar `ContextBudgetPolicy` por perfil com limites de itens, bytes/chars e, quando disponivel, tokens reais por tokenizer do backend.

Passos de implementacao:

1. Criar teste para budget de cada perfil.
2. Definir limites iniciais conservadores por perfil.
3. Implementar truncamento deterministico por prioridade.
4. Medir bytes/chars por bloco renderizado e tokens somente por tokenizer real.
5. Registrar cortes no audit.
6. Falhar teste se renderer ultrapassar budget sem justificativa.

Criterio de aceite: perfis amplos continuam controlados e auditaveis.

### T150E - Garantir fronteira entre storage operacional e contexto persistente

Status: pending

Evidencia: `trusted_sources`, caches de headlines, chunks de news, indices de PDF/log e audit SQLite sao infraestrutura operacional. Eles nao podem virar `[MEMORY]`, mas tambem nao podem ser descartados como se fossem ruido.

Impacto: resolve a tensao entre "unicas fontes persistentes visiveis" e "dominios que precisam de dados persistentes internos".

Teste primeiro: dados em SQLite operacional alimentam `NEWS_DOSSIER`, mas nao aparecem em `[MEMORY]`; `MEMORY.md` continua sendo carregado apenas dos arquivos/promocoes explicitas.

Implementacao: marcar stores por `storageScope`: `operational`, `audit`, `persistent_context`. Somente `persistent_context` pode renderizar `[MEMORY]`/`[SKILLS]`.

Passos de implementacao:

1. Criar teste com `trusted_sources` populado e `MEMORY.md` ausente.
2. Assertar que `[MEMORY]` nao aparece.
3. Assertar que `NEWS_DOSSIER` usa fontes selecionadas.
4. Criar enum/tipo `StorageScope`.
5. Aplicar scope aos stores planejados.
6. Registrar violacao como erro de teste anti-vazamento.

Criterio de aceite: storage operacional pode ser persistente sem competir com MEMORY/SKILLS.

### T151 - Criar store SQLite unico para catalogos operacionais

Status: pending

Evidencia: `cli-agent-v2/source_indexer.py` define `trusted_sources` com `url`, `domain`, `name`, `topic`, `subtopics`, `region`, `format`, `geo_city`, `geo_state`, `geo_country`, `approval_score`, scores parciais, `is_active`, `http_status`, `response_ms`, `requires_auth`, `has_api`, `has_rss`, `api_endpoint`, `rss_url` e `notes`. A versao atual usa `./memory.db`; no Phenom isso deve ficar em storage controlado do projeto.

Impacto: permite News operar com bastante informacao interna sem criar varios arquivos soltos e sem transformar catalogo em MEMORY.

Teste primeiro: store cria schema `trusted_sources`, insere/upserta fonte por `(url, geo_city, geo_state, geo_country)`, consulta por localidade/topico/score e nao cria arquivos fora de `./.phenom/`.

Implementacao: adaptar o melhor do `SourceDB` de `source_indexer.py`, corrigindo o hardcode `./memory.db` para um `PhenomStore` unico.

Passos de implementacao:

1. Criar teste de schema e upsert em SQLite temporario.
2. Criar `src/storage/phenom-store.ts` ou modulo equivalente ja alinhado ao repo.
3. Criar tabela `trusted_sources` com indices de topic/score/active/country/state.
4. Implementar upsert preservando endpoint API existente quando novo valor for vazio/demo.
5. Implementar query por cidade/UF/topico/minScore.
6. Garantir que o path padrao seja `./.phenom/phenom.sqlite3`.

Criterio de aceite: catalogo operacional persiste em um unico SQLite controlado e nao aparece como `[MEMORY]`.

### T152 - Portar indexacao de fontes como contrato interno de News

Status: pending

Evidencia: `source_indexer.py` monta catalogo por fontes globais, nacionais, estaduais e dinamicas em `build_catalog()`. `build_dynamic_sources()` adiciona energia, agua, meteorologia, TCE, TJ, diario oficial, saude, seguranca, prefeitura, transparencia, licitacoes, diario municipal, InfoDengue, qualidade do ar e portais de noticia por UF. Depois `compute_score()` calcula `approval_score`.

Impacto: News deixa de depender de contexto minimo e passa a operar com uma base de fontes verificavel e reaproveitavel.

Teste primeiro: dado `city/state/country`, o indexador gera fontes com `topic`, `region`, `format`, scores e geografia; fonte 404 pode ser marcada/removida; fonte 401/403 vira `requires_auth`/inativa conforme politica.

Implementacao: portar de forma incremental apenas o nucleo: schema, builder de catalogo e scoring. Descoberta externa/DDG e verificacao HTTP entram atras de flag/contrato posterior.

Passos de implementacao:

1. Criar fixture pequena de localidade BR com UF e cidade.
2. Criar teste para gerar catalogo deterministico sem rede.
3. Implementar builder de fontes estaticas/dinamicas minimo.
4. Implementar `approval_score` a partir dos scores parciais.
5. Persistir fontes via store da T151.
6. Registrar no audit quantas fontes foram criadas/atualizadas, sem enviar catalogo bruto ao modelo.

Criterio de aceite: indexacao popula `trusted_sources` e gera evidencia operacional de contagem/qualidade, nao prompt gigante.

### T153 - Implementar `SourceProvider` de News baseado em `trusted_sources`

Status: pending

Evidencia: `news_use_case.py` usa `SourceProvider._from_db()` para carregar fontes do DB via `_get_trusted_news_sources(min_score=5.0)`, filtra `requires_auth`, deduplica por domain, cruza `geo_city`, `geo_state`, `region`, nome da fonte e prioriza local > estadual > nacional.

Impacto: separa a obtencao real de fontes do modelo. O modelo pede News; o controller consulta catalogo, aplica regra de localidade e retorna um conjunto de fontes confiaveis para coleta.

Teste primeiro: com tabela populada por fontes locais, estaduais, nacionais e uma fonte `requires_auth`, a query retorna locais primeiro, remove autenticadas e deduplica dominio.

Implementacao: criar provider interno do contrato `news_operational` que recebe `location`, `stateUf`, `topic`, `minScore`, `maxSources`.

Passos de implementacao:

1. Criar teste com SQLite temporario e fontes fake.
2. Implementar `NewsSourceProvider` usando store da T151.
3. Normalizar localidade sem depender do LLM.
4. Aplicar ordem local/name/state/national.
5. Aplicar `maxSources` configuravel.
6. Registrar no audit `sources_total`, `sources_selected`, `trusted_count`, `auth_filtered`.

Criterio de aceite: News seleciona fontes por dados estruturados, nao por contexto textual minimo.

### T154 - Implementar coleta de manchetes RSS/homepage com cache

Status: pending

Evidencia: `HeadlineFetcher` em `news_use_case.py` coleta em paralelo com semaforo, tenta RSS primeiro (`has_rss` + `rss_url`) e cai para homepage. `rag_web._fetch_source_headlines()` tambem usa cache por `domain:time_filter:topico` com TTL.

Impacto: reduz latencia e evita gastar chamadas de modelo antes de ter dados concretos.

Teste primeiro: fonte com RSS usa RSS; fonte sem RSS usa homepage; falha em uma fonte nao derruba coleta; headlines duplicadas sao removidas; cache evita segunda coleta dentro do TTL.

Implementacao: criar fetcher desacoplado do modelo, com adaptadores HTTP mockaveis e cache em SQLite ou memoria com TTL.

Passos de implementacao:

1. Criar teste com HTTP adapter fake.
2. Implementar `NewsHeadlineFetcher` com concorrencia limitada.
3. Implementar RSS-first e fallback homepage.
4. Deduplicar headlines por normalizacao.
5. Persistir cache em tabela `news_headline_cache` ou cache interno com TTL auditado.
6. Registrar fontes com headlines e fontes sem retorno no audit.

Criterio de aceite: coleta roda sem LLM e produz lista estruturada de manchetes por fonte.

### T155 - Implementar analise de manchetes em chunks, nao micro-contexto

Status: pending

Evidencia: `HeadlineAnalyzer` processa batches de `CHUNK_SIZE = 40`, agrupa por similaridade textual via `group_similar_headlines`, sintetiza grupos multi-fonte/single, filtra preferencias depois da categorizacao e persiste `AnalysisChunk` no `NewsSessionDB`.

Impacto: News precisa de contexto agregado. O modelo nao deve receber um micro-trecho; deve receber chunks de eventos, fontes e confianca.

Teste primeiro: 80 manchetes viram dois batches; manchetes similares viram um evento; grupos multi-fonte preservam fontes; preferencia do usuario remove categoria suprimida; chunks sao persistidos.

Implementacao: criar `NewsEventAnalyzer` com duas camadas: agrupamento deterministico sem LLM e sintese compacta opcional via modelo apenas sobre grupos ja reduzidos.

Passos de implementacao:

1. Criar fixtures de manchetes com duplicatas e fontes diferentes.
2. Implementar agrupamento por similaridade textual.
3. Implementar estrutura `NewsEventChunk`.
4. Adicionar sintese compacta opcional com prompt pequeno e JSON estrito.
5. Persistir chunks em tabela `news_analysis_chunks`.
6. Registrar `batches`, `groups`, `chunks`, `llm_calls` e tokens reais quando disponiveis.

Criterio de aceite: output de News e um dossie estruturado de eventos, nao micro-contexto.

### T156 - Renderizar contexto de News como dossie operacional compacto

Status: pending

Evidencia: `RawWebDataBuilder` monta paginas virtuais com `title`, `description`, `headlines`, `body`, fontes, categorias, `confidence` e `pipeline_stages`. Isso e diferente de `EvidencePacket` de codigo: e um produto agregado para formatter/resposta.

Impacto: o modelo recebe informacao suficiente para responder News com qualidade, sem receber a tabela inteira de fontes nem logs brutos.

Teste primeiro: chunks analisados + fontes + alertas civicos geram `[NEWS_DOSSIER v1]` com localidade, periodo, topico, eventos, fontes, confianca, falhas e timestamp; nao contem catalogo completo nem prompts internos.

Implementacao: criar renderer especifico para `news_operational`, separado do renderer `code_micro`.

Passos de implementacao:

1. Criar teste de renderizacao do dossie com snapshot compacto.
2. Definir schema textual/JSON pequeno para `[NEWS_DOSSIER v1]`.
3. Incluir top N eventos, fontes por evento e score de confianca.
4. Incluir falhas operacionais resumidas: sem fontes, sem manchetes, fonte timeout.
5. Garantir limite de tamanho por `maxEvents`/`maxSourcesPerEvent`.
6. Integrar ao `ModelTurnContext` por profile, sem usar `[EVIDENCE]` de codigo.

Criterio de aceite: News tem contexto suficiente para boa resposta e nao viola a separacao MEMORY/SKILLS/catalogo operacional.

### T157 - Criar testes de aceitacao operacional para News

Status: pending

Evidencia: o fluxo correto de News e operacional: catalogo -> fontes selecionadas -> coleta -> validacao local -> chunks -> dossie -> resposta. Medir apenas "contexto minimo" nao prova esse fluxo.

Impacto: evita regressao onde News volta a depender de prompt gigante, DDG improvisado ou micro-contexto insuficiente.

Teste primeiro: criar harness offline com store populado, fetcher fake e modelo fake para sintese; assertar cada etapa do pipeline.

Implementacao: suite `test:news-operational` ou equivalente dentro da estrutura do repo.

Passos de implementacao:

1. Criar fixture SQLite com `trusted_sources`.
2. Criar fixture de RSS/homepage fake.
3. Rodar provider, fetcher, analyzer e renderer sem rede real.
4. Assertar contadores de audit por etapa.
5. Assertar que o prompt final contem dossie e nao contem catalogo bruto.
6. Adicionar caso de falha: sem fontes, fonte auth, fonte timeout, sem manchetes.

Criterio de aceite: News e validado como operacao completa, nao como tarefa de micro-contexto.

## Fase 16 - Provas de confiabilidade para uso real

Esta fase existe para transformar confiabilidade em prova operacional, nao em promessa. Cada task abaixo corresponde diretamente a uma invariante obrigatoria.

### T160 - Provar que tool nao anunciada nunca executa

Status: pending

Invariante provada: 1. Tool nao anunciada nunca executa.

Evidencia: o audit relatou caso real de parser promovendo `content` como tool inexistente. O agente precisa aceitar parser tolerante, mas executor estrito.

Impacto: remove uma classe critica de risco operacional e seguranca.

Teste primeiro: fixture com native tool call e text protocol chamando `content`, `delete_file` nao anunciado e uma tool valida anunciada. Somente a valida pode chegar ao executor.

Implementacao: teste de ponta do gate parser -> allowlist -> executor com contador fake de execucoes.

Passos de implementacao:

1. Criar fixture offline com tool inexistente e tool nao anunciada.
2. Criar executor fake que registra chamadas reais.
3. Rodar parser tolerante e gate estrito.
4. Assertar que `content` e tool nao anunciada viram rejeicao reparavel.
5. Assertar que contador de execucao fica zero para rejeitadas.
6. Registrar no audit `rejected_tool_call` com motivo e trecho de origem.

Criterio de aceite: nenhuma tool fora da allowlist anunciada executa em nenhum protocolo suportado.

### T161 - Provar que contexto bruto nao vaza para o modelo

Status: pending

Invariante provada: 2. Contexto bruto nao vaza para o modelo.

Evidencia: o audit aponta risco de outputs brutos, reparos longos, raw tool output e contexto minimo gigante degradarem o modelo.

Impacto: protege baixo consumo de tokens e reduz alucinacao por ruido.

Teste primeiro: tool outputs contendo `rawOutput`, `rg --json`, conteudo completo de arquivo, logs longos e prompt interno passam pelo pipeline; o prompt final nao contem esses marcadores.

Implementacao: teste anti-vazamento no renderer de `ModelTurnContext` e nos renderers por `ContextProfile`.

Passos de implementacao:

1. Criar fixtures de outputs brutos de read/grep/shell/news/log.
2. Transformar fixtures em `ToolEvent`.
3. Rodar destiladores e renderizadores por perfil.
4. Assertar ausencia de marcadores brutos no prompt final.
5. Assertar presenca de evidencias/dossies/summaries derivados.
6. Registrar cortes e hashes no audit para depuracao sem vazar no prompt.

Criterio de aceite: prompt final contem apenas contexto renderizado por perfil, nunca raw tool output.

### T162 - Provar que MEMORY/SKILLS nao competem com storage operacional

Status: pending

Invariante provada: 3. MEMORY/SKILLS nao competem com storage operacional.

Evidencia: o usuario definiu MEMORY/SKILLS como unicas fontes persistentes textuais visiveis. Ao mesmo tempo, News precisa de `trusted_sources` e outros stores operacionais.

Impacto: permite persistencia interna rica sem criar varias memorias concorrentes.

Teste primeiro: SQLite com `trusted_sources`, cache de news e audit populados, mas sem `MEMORY.md`/`SKILLS.md`; renderizacao nao cria blocos `[MEMORY]`/`[SKILLS]`, mas News ainda usa o catalogo operacional.

Implementacao: teste de fronteira `StorageScope` + renderer de contexto persistente.

Passos de implementacao:

1. Criar store operacional fake com fontes e chunks.
2. Garantir ausencia de arquivos MEMORY/SKILLS.
3. Renderizar turno de News.
4. Assertar que `[MEMORY]` e `[SKILLS]` nao aparecem.
5. Assertar que `[NEWS_DOSSIER v1]` usa dados operacionais.
6. Repetir com `MEMORY.md` real e provar que ele aparece separado do storage.

Criterio de aceite: storage operacional alimenta contratos, mas nao vira memoria conversacional.

### T163 - Provar que News nao depende de prompt improvisado

Status: pending

Invariante provada: 4. News nao depende de prompt improvisado.

Evidencia: a operacao correta de News vem de `trusted_sources`, SourceProvider, fetcher, analyzer, chunks e dossie. Prompt grande de localidade ou DDG improvisado nao deve ser o eixo principal.

Impacto: News fica operacional, testavel e previsivel.

Teste primeiro: pipeline offline com `trusted_sources` populado, fetcher fake e modelo fake gera `NEWS_DOSSIER` sem usar web real nem prompt livre de descoberta.

Implementacao: teste de pipeline que falha se o contrato tentar montar fontes por prompt em vez de consultar store/provider.

Passos de implementacao:

1. Criar SQLite fixture com fontes locais/estaduais/nacionais.
2. Criar fetcher fake que retorna manchetes por dominio.
3. Criar analyzer fake ou deterministico para chunks.
4. Executar `research_news`/`news_operational`.
5. Assertar que as fontes vieram do provider/store.
6. Assertar que prompts usados, se existirem, so sintetizam chunks ja reduzidos.

Criterio de aceite: News funciona em teste offline estruturado sem prompt improvisado de descoberta.

### T164 - Provar que patch nao aplica sobre contexto stale

Status: pending

Invariante provada: 5. Patch em codigo nao aplica sobre contexto stale.

Evidencia: micro-contexto precisa de id, path, range e hash. Sem validacao, o modelo pode editar trecho que mudou desde a leitura.

Impacto: reduz risco de corrupcao de codigo.

Teste primeiro: criar micro-contexto de arquivo, alterar arquivo externamente, tentar aplicar patch com `contextId` antigo; deve falhar com `stale_context` e sugestao de recolher contexto.

Implementacao: integrar validacao de hash/range no fluxo de patch atomico.

Passos de implementacao:

1. Criar arquivo fixture e micro-contexto.
2. Alterar o trecho antes do patch.
3. Chamar patch com `contextId` antigo.
4. Assertar erro reparavel `stale_context`.
5. Assertar que arquivo nao mudou.
6. Registrar no audit hash esperado, hash atual e path/range.

Criterio de aceite: patch com contexto stale nunca aplica alteracao parcial.

### T165 - Provar que falha de modelo nao parece falha de infraestrutura

Status: pending

Invariante provada: 6. Falha de modelo nao parece falha de infraestrutura.

Evidencia: o audit exige separar testes de infraestrutura de capacidade do modelo. Falhas de JSON, chamada errada, final generico ou incapacidade linguistica devem ser classificadas corretamente.

Impacto: depuracao fica objetiva; regressao de agente nao e confundida com limite do modelo.

Teste primeiro: simular respostas de modelo invalidas, tool inexistente, JSON quebrado, final generico e timeout de modelo. O audit deve classificar como `model_output_error`/`model_capability`/`model_timeout`, nao como falha de tool infra quando a infra nao executou nada errado.

Implementacao: criar taxonomia de falhas e aplicar no loop/audit.

Passos de implementacao:

1. Criar enum/tipo de `FailureOrigin`.
2. Criar fixtures de falhas de modelo.
3. Rodar loop com tools fake saudaveis.
4. Assertar classificacao da falha.
5. Assertar que testes reais reportam categoria correta.
6. Expor classificacao no audit summary.

Criterio de aceite: toda falha tem origem classificada; erro do modelo nao acusa infra sem evidencia.

### T166 - Provar que cada turno consegue ser auditado e reproduzido

Status: pending

Invariante provada: 7. Cada turno consegue ser auditado e reproduzido.

Evidencia: o audit pede painel unico por turno, replay de audit, parser strategy, tools anunciadas, calls, results, memoria, evidencia e motivo de parada.

Impacto: uso real exige explicar e reproduzir comportamento, principalmente quando o modelo erra.

Teste primeiro: executar turno fake com tool valida, tool rejeitada, evidence renderizado e final answer; salvar audit; rodar replay; comparar resumo reproduzido com snapshot.

Implementacao: persistir `TurnAudit` em store controlado e criar replay deterministico sem chamar modelo real.

Passos de implementacao:

1. Criar scenario fixture de turno completo.
2. Persistir audit com id de turno.
3. Implementar replay que le audit e reconstroi timeline.
4. Assertar tools anunciadas/chamadas/rejeitadas/executadas.
5. Assertar contexto renderizado e motivo de parada.
6. Criar comando ou helper para inspecionar replay.

Criterio de aceite: qualquer turno salvo pode gerar resumo auditavel e replay offline.

### T167 - Criar suite agregada de confiabilidade real

Status: pending

Invariantes provadas: 1, 2, 3, 4, 5, 6 e 7.

Evidencia: as invariantes isoladas precisam rodar juntas para impedir regressao cruzada.

Impacto: define o minimo para chamar o projeto de confiavel para uso real controlado.

Teste primeiro: comando `test:reliability` ou suite equivalente roda T160-T166 com fixtures offline e nao depende de rede/modelo real.

Implementacao: agregar testes existentes sob um suite runner.

Passos de implementacao:

1. Criar script de teste de confiabilidade.
2. Incluir fixtures de parser, contexto, memory/storage, news, patch, failure origin e replay.
3. Garantir que a suite rode offline.
4. Gerar relatorio curto com status de cada invariante.
5. Integrar ao devlog como gate antes de testes reais.
6. Documentar que falha nessa suite bloqueia release/uso real.

Criterio de aceite: uma unica suite prova as sete invariantes sem depender do modelo real.

## Fase 17 - CLI renderer e diff legivel

Esta fase registra o requisito visual: o `phenom-cli-ts` tem um renderer de CLI bom e deve servir como referencia de experiencia. O problema conhecido e o diff: vermelho/verde muito saturado ou com background forte ofusca o conteudo. A cor deve guiar leitura, nao competir com o codigo.

Referencia local:

- `../phenom-cli-ts/src/cli-renderer.ts`
- `../phenom-cli-ts/src/stream-markdown-renderer.ts`
- `src/cli-renderer.ts`
- `src/diff-renderer.ts`

Referencia externa possivel: `https://github.com/openai/codex`. Antes de copiar qualquer implementacao, verificar licenca e preferir extrair principios visuais. O objetivo e inspiracao de UX: gutter limpo, marcadores fortes, corpo do codigo legivel, background suave e fallback sem cor.

### T170 - Auditar renderer atual contra renderer do `phenom-cli-ts`

Status: pending

Evidencia: `phenom-cli-ts/src/cli-renderer.ts` tem melhorias que a arvore atual nao tem, incluindo append mode, preview limit, highlight por linguagem e diff inline mais rico. A arvore atual tem `src/diff-renderer.ts` com `chalk.bgGreen.black`/`chalk.bgRed.black` e `src/cli-renderer.ts` colorindo linhas inteiras com `chalk.green`/`chalk.red`.

Impacto: reaproveita o melhor da referencia sem transportar regressao visual.

Teste primeiro: criar snapshot textual/ANSI de uma mutacao com linhas adicionadas, removidas, modificadas e contexto; o teste deve capturar os estilos atuais para comparar depois.

Implementacao: relatorio curto no devlog + fixtures de render.

Passos de implementacao:

1. Criar fixture de diff com TypeScript realista, linhas longas e tokens pequenos.
2. Capturar output atual de `src/diff-renderer.ts`.
3. Capturar output atual do `renderFileDiff` em `src/cli-renderer.ts`.
4. Comparar com o comportamento de `../phenom-cli-ts/src/cli-renderer.ts`.
5. Registrar quais partes portar: limite de preview, highlight de codigo, paleta suave.
6. Registrar quais partes corrigir: vermelho/verde ofuscante, backgrounds agressivos e baixa legibilidade.

Criterio de aceite: existe baseline visual testavel antes da mudanca.

### T171 - Verificar fonte aberta do Codex e extrair principios de diff

Status: pending

Evidencia: o usuario sugeriu um diff inspirado no Codex se o codigo fonte for aberto. A referencia externa deve ser usada com cuidado de licenca e sem copiar codigo sem necessidade.

Impacto: melhora UX do diff com uma referencia madura, mantendo responsabilidade legal/tecnica.

Teste primeiro: esta task e documental/arquitetural; o teste e um checklist que falha se a implementacao citar Codex sem registrar fonte/licenca/principios extraidos.

Implementacao: verificar o repositorio `openai/codex`, licenca, arquivos relevantes de diff/render e documentar apenas principios aplicaveis.

Passos de implementacao:

1. Confirmar URL publica do repositorio Codex.
2. Confirmar licenca antes de portar qualquer trecho.
3. Identificar como o Codex diferencia gutter, marcadores, headers e corpo do codigo.
4. Extrair principios visuais, nao copiar implementacao por padrao.
5. Registrar no devlog links/arquivos consultados.
6. Se a licenca ou fonte nao permitir, implementar paleta propria inspirada apenas em padroes gerais de diff legivel.

Criterio de aceite: decisao de inspiracao/copia e documentada com fonte e licenca.

### T172 - Implementar paleta de diff legivel inspirada no Codex

Status: pending

Evidencia: `src/diff-renderer.ts` usa `bgGreen.black`/`bgRed.black` em word diff e split diff; isso pode ofuscar o texto. `src/cli-renderer.ts` usa marker colorido e texto inteiro vermelho/verde, ainda agressivo em terminais escuros.

Impacto: diff fica legivel em uso real, especialmente em patches grandes.

Teste primeiro: snapshot ANSI deve provar que:

- marcadores `+`/`-` sao fortes;
- line numbers e gutter sao dim/neutros;
- corpo do codigo nao usa background saturado;
- adicao/remocao usam foreground suave ou background muito leve;
- contexto permanece neutro;
- `NO_COLOR=1` gera output plain legivel.

Implementacao: criar `DiffTheme` com tokens semanticos: `addMarker`, `delMarker`, `modMarker`, `gutter`, `context`, `addText`, `delText`, `header`, `hunk`.

Passos de implementacao:

1. Criar teste de snapshot ANSI para tema default.
2. Criar teste plain com `NO_COLOR`.
3. Substituir `chalk.bgGreen.black`/`bgRed.black` por paleta suave.
4. Separar cor do marker da cor do texto.
5. Evitar colorir linha inteira quando houver highlight de codigo.
6. Expor tema configuravel por env ou opcao interna sem aumentar prompt/model context.

Criterio de aceite: diff comunica adicao/remocao sem prejudicar leitura do codigo.

### T173 - Unificar render de diff entre `diff-renderer.ts` e `cli-renderer.ts`

Status: pending

Evidencia: hoje existem dois caminhos de diff: `src/diff-renderer.ts` e `CliRenderer.renderFileDiff`. Duplicacao aumenta chance de uma paleta ficar corrigida e outra continuar ofuscante.

Impacto: uma mudanca de tema vale para word diff, file diff, split diff e eventos `FILE_DIFF`.

Teste primeiro: a mesma fixture renderizada por API standalone e pelo evento `FILE_DIFF` deve usar a mesma paleta e os mesmos limites.

Implementacao: extrair formatador puro de diff para modulo compartilhado, deixando `CliRenderer` responsavel apenas por escrever blocos.

Passos de implementacao:

1. Criar teste que compara renderer standalone e renderer inline.
2. Extrair `renderInlineFileDiff`/`formatDiffLine` para modulo puro.
3. Fazer `src/diff-renderer.ts` usar o modulo puro.
4. Fazer `CliRenderer.renderFileDiff` usar o modulo puro.
5. Preservar header especifico do CLI.
6. Remover duplicacao de paleta agressiva.

Criterio de aceite: nao existem dois estilos divergentes de diff no CLI.

### T174 - Adicionar limites, truncamento e testes de terminal para diff

Status: pending

Evidencia: `phenom-cli-ts` tem `maxInlineDiffPreviewLines`; patches grandes nao devem inundar o terminal. A legibilidade tambem depende de largura, wrap e fallback sem TTY.

Impacto: diff permanece util em patches grandes e ambientes diferentes.

Teste primeiro: diff com 3000 linhas deve mostrar preview + linha de truncamento; largura estreita nao quebra gutter; pipe mode nao emite controle de cursor.

Implementacao: portar/adaptar limite de preview e testes de renderer.

Passos de implementacao:

1. Criar fixture de diff grande.
2. Criar teste de truncamento por `maxInlineDiffPreviewLines`.
3. Criar teste com largura estreita simulada.
4. Criar teste plain/non-TTY.
5. Garantir que truncamento informa linhas omitidas.
6. Registrar no audit/renderer summary quando diff foi truncado.

Criterio de aceite: diff grande nao trava nem polui o terminal; usuario sabe que houve truncamento.

## Fase 18 - Visual Codex e motor append-only do renderer

Esta fase registra um requisito visual mais amplo que o diff. O objetivo e importar para o Phenom a experiencia visual observada no Codex CLI: bloco de user query limpo, finalizacao de inferencia discreta, amostragem de execucao de tools, separadores consistentes entre outputs e motor principal append-only, adequado para tmux, terminal scrollback e copy direto.

Fonte externa verificada: `https://github.com/openai/codex`, repositorio publico `openai/codex`, licenca Apache-2.0 conforme GitHub API em 2026-07-04. Antes de copiar qualquer trecho, revisar arquivos concretos e registrar atribuicao/licenca se houver port direto. Preferencia: portar comportamento e principios visuais para TypeScript local.

Referencia local:

- `src/cli-renderer.ts`
- `src/tui/event-bus.ts`
- `src/stream-markdown-renderer.ts`
- `../phenom-cli-ts/src/cli-renderer.ts`
- `../phenom-cli-ts/src/stream-markdown-renderer.ts`

### T180 - Auditar visual do Codex para blocos de conversa e eventos

Status: pending

Evidencia: o usuario quer importar o visual do user query, finalizacao de inferencia, amostragem de tools e divisorias. Isso exige mapear comportamento visual antes de implementar.

Impacto: evita portar apenas detalhes esteticos soltos e perder o motor de UX.

Teste primeiro: criar checklist/snapshot esperado com os blocos: user query, assistant stream, finalizacao, tool start, tool result sample, tool error, diff, separador entre turns.

Implementacao: estudar Codex CLI e `phenom-cli-ts`, registrar principios e comparar com renderer atual.

Passos de implementacao:

1. Localizar no repositorio Codex os modulos de TUI/render/eventos.
2. Registrar arquivos consultados e licenca.
3. Capturar exemplos visuais ou snapshots textuais do comportamento esperado.
4. Mapear cada bloco visual para evento do Phenom (`USER_MESSAGE`, `THINK_START`, `TOOL_START`, `TOOL_RESULT`, `FILE_DIFF`, `THINK_END`).
5. Definir quais elementos serao copiados como comportamento, nao codigo.
6. Registrar no devlog gaps entre Phenom atual, `phenom-cli-ts` e Codex.

Criterio de aceite: existe especificacao visual antes de qualquer implementacao.

### T181 - Implementar motor append-only como modo principal do CLI

Status: pending

Evidencia: pela analise visual do usuario, o Codex funciona como append-only. `phenom-cli-ts` tambem introduz `appendMode` para preservar scrollback nativo e copy mode, enquanto a arvore atual ainda carrega muita logica de alt-screen/scroll region.

Impacto: melhora uso real em tmux, SSH, terminal scrollback e copia direta de output.

Teste primeiro: renderer em modo TTY append-only nao deve limpar tela, nao deve entrar em alternate screen por padrao e deve produzir transcript linear copiavel.

Implementacao: tornar append-only o modo principal; alternate screen fica opt-in por env.

Passos de implementacao:

1. Criar teste fake TTY que captura writes do renderer.
2. Assertar ausencia de enter-alt-screen quando env nao pede.
3. Assertar que blocos sao apenas anexados ou atualizados minimamente sem apagar scrollback.
4. Portar/adaptar `appendMode` de `phenom-cli-ts`.
5. Manter fallback plain para pipe/non-TTY.
6. Documentar env de opt-in para alt-screen se ainda existir.

Criterio de aceite: tmux/copy mode funciona com transcript linear por padrao.

### T182 - Renderizar user query no estilo Codex

Status: pending

Evidencia: o bloco de user query deve ser visualmente distinto, compacto e copiavel. O renderer atual tem bubble/history, mas precisa padronizar espaçamento e divisoria sem depender de caixa pesada.

Impacto: melhora leitura de turnos longos e facilita copiar prompt/resposta.

Teste primeiro: snapshot ANSI/plain de user query curta, multiline e paste placeholder.

Implementacao: criar renderer puro `renderUserTurnBlock` com label/gutter/divisor e comportamento plain.

Passos de implementacao:

1. Criar snapshots para query curta e multiline.
2. Garantir que o texto do usuario continua copiavel sem caracteres invasivos no meio da linha.
3. Definir label discreto e separador antes/depois do bloco.
4. Integrar `USER_MESSAGE` ao renderer puro.
5. Garantir reflow por largura sem quebrar palavras de forma ilegivel.
6. Testar plain/non-TTY sem ANSI.

Criterio de aceite: user query fica clara, copiavel e consistente entre turns.

### T183 - Renderizar finalizacao de inferencia no estilo Codex

Status: pending

Evidencia: finalizacao de inferencia deve informar conclusao, tempo/tokens quando disponivel e nao poluir historico com linhas redundantes. O Phenom ja tem `[done]`, mas precisa padronizar com append-only e divisorias.

Impacto: usuario entende quando o turno terminou sem receber ruído no transcript.

Teste primeiro: snapshot de `THINK_END` com e sem stats; `[done]` aparece uma vez, em local previsivel, e nao duplica no historico.

Implementacao: criar `renderInferenceDoneBlock` ou status final append-only.

Passos de implementacao:

1. Criar teste para turno com streaming e `THINK_END`.
2. Criar teste para resposta sem streaming.
3. Garantir que done/status nao duplica em `history` e `layoutHistory`.
4. Incluir tempo, tokens e tps quando disponiveis.
5. Separar visualmente do proximo user turn.
6. Manter plain mode legivel.

Criterio de aceite: finalizacao e discreta, unica e copiavel.

### T184 - Renderizar amostragem de execucao de tools

Status: pending

Evidencia: o usuario quer o visual de amostragem de tools: mostrar o suficiente para acompanhar execucao sem despejar todo output bruto no terminal. Isso tambem conversa com as invariantes de contexto bruto.

Impacto: o usuario acompanha tools reais sem perder legibilidade nem scrollback.

Teste primeiro: tool start/result/error com output curto, output longo, JSON, shell e diff. Output longo deve ser resumido com contagem e amostra.

Implementacao: criar `ToolExecutionSample` com head/tail/omitted bytes/lines e renderer proprio.

Passos de implementacao:

1. Criar fixtures de outputs de tool curtos e longos.
2. Implementar sampler deterministico por linhas/bytes.
3. Renderizar tool start com nome, args resumidos e estado.
4. Renderizar result com status, duracao, linhas omitidas e amostra.
5. Renderizar error com causa e amostra curta.
6. Integrar com audit para preservar metadata sem despejar bruto no terminal.

Criterio de aceite: tool execution fica auditavel visualmente sem inundar CLI.

### T185 - Padronizar espacamentos e divisorias entre outputs

Status: pending

Evidencia: o usuario citou explicitamente espacamentos no output do modelo e divisorias entre outputs. Sem regra central, cada evento adiciona newline/box de forma diferente e o transcript fica irregular.

Impacto: melhora leitura, copia e previsibilidade visual.

Teste primeiro: sequencias user -> assistant -> tool -> diff -> assistant -> done -> next user devem ter exatamente os gaps esperados em snapshot.

Implementacao: criar `SpacingPolicy` baseada em tipo de bloco anterior/proximo.

Passos de implementacao:

1. Definir tipos de bloco: user, assistant, thinking, tool, diff, status, divider.
2. Criar tabela de spacing entre blocos.
3. Remover newlines manuais duplicados nos handlers.
4. Aplicar spacing via unico helper.
5. Criar snapshots de sequencias comuns.
6. Testar plain e ANSI.

Criterio de aceite: outputs nao colam nem abrem buracos inconsistentes.

### T186 - Criar snapshots end-to-end do renderer append-only

Status: pending

Evidencia: mudanca visual sem snapshot regressa facil. O renderer precisa provar user query, tools, diff, assistant output, done e separadores em conjunto.

Impacto: estabiliza UX antes das features maiores.

Teste primeiro: fixture de turno completo gera transcript append-only deterministico.

Implementacao: criar harness de renderer com fake output stream e eventos do `eventBus`.

Passos de implementacao:

1. Criar fake TTY output com largura fixa.
2. Emitir eventos de turno completo.
3. Capturar output ANSI e plain.
4. Normalizar timestamps/duracoes para snapshot.
5. Assertar que nao ha alt-screen por padrao.
6. Assertar que transcript e copiavel em ordem linear.

Criterio de aceite: existe snapshot e2e do visual principal do CLI.

## Fase 19 - Reescrita Rust do zero para o projeto final

Esta fase torna explicito o novo alvo: o Phenom final deve nascer em Rust. A arvore TypeScript atual, `../phenom-cli-ts` e os projetos auxiliares continuam sendo fontes de evidencia, fixtures, comportamento desejado e anti-exemplos. Eles nao devem ditar a estrutura do novo codigo.

Motivacao: a prova de conceito ja validou que o agente precisa de contratos pequenos, contexto destilado, renderer append-only, audit/replay, memoria separada de storage operacional e perfis por dominio. O problema agora e estabilidade de produto: TS trouxe glitches de render, menor previsibilidade em TUI/terminal, dependencia pesada de runtime e mais fragilidade em subprocess/IO. Rust passa a ser a base final para CLI robusto, terminal previsivel, binario distribuivel, SQLite nativo, async IO, subprocess controlado e tipagem forte.

Regra de migracao: nenhuma task desta fase deve portar codigo TS mecanicamente. Cada task deve primeiro criar teste/fixture em Rust que preserve o comportamento desejado; depois implementar a menor parte possivel. O criterio de sucesso e reproduzir as garantias do produto, nao manter nomes ou pastas da versao TS.

### T190 - Criar workspace Rust minimo do Phenom final

Status: pending

Evidencia: o projeto atual ja tem muitas responsabilidades misturadas em TS: CLI, renderer, loop, tools, memoria, audit, contexto e testes reais. Para a versao final, a base precisa nascer com fronteiras de crate/modulo claras.

Impacto: evita recriar a montanha de arquivos e acoplamentos da versao anterior; cria uma base pequena para patches futuros.

Teste primeiro: `cargo test` deve rodar uma suite vazia/minima com um teste de smoke do crate principal e um teste de binario que valida `phenom --version`.

Implementacao: criar workspace Rust com crates/modulos iniciais para CLI, core, renderer, model, tools, storage e tests, sem implementar features completas ainda.

Passos de implementacao:

1. Criar `Cargo.toml` de workspace e crate binario `phenom`.
2. Criar crate/modulo `phenom-core` para tipos centrais.
3. Criar crate/modulo `phenom-cli` para entrada de comandos.
4. Criar crate/modulo `phenom-render` para renderer terminal.
5. Criar crate/modulo `phenom-storage` para SQLite/audit futuro.
6. Adicionar teste de smoke para versao e inicializacao sem modelo.

Criterio de aceite: `cargo test` passa e o binario inicia sem depender de Ollama, SQLite real ou tools externas.

### T191 - Definir CLI e configuracao compativeis com o uso atual

Status: pending

Evidencia: a arvore TS ja expoe fluxo `chat`, sessoes, envs de modelo/cache e testes reais com `npm run dev -- chat --session ... --prompt ...`. O Rust deve manter a ergonomia de uso que ja foi provada.

Impacto: permite migrar testes, scripts e habitos de uso sem obrigar o usuario a reaprender o produto.

Teste primeiro: teste de parsing CLI valida `chat --session X --prompt Y`, `--model`, `--host`, `--cwd`, `--no-color` e modo pipe/non-TTY.

Implementacao: usar parser CLI Rust tipado e uma estrutura `RuntimeConfig` unica.

Passos de implementacao:

1. Levantar flags/envs usados hoje nos testes reais e scripts.
2. Criar `RuntimeConfig` com precedencia: CLI > env > config file > defaults.
3. Criar comandos iniciais `chat`, `replay`, `audit`, `doctor` e `version`.
4. Implementar `--cwd` como raiz operacional validada.
5. Implementar `--no-color` e deteccao non-TTY.
6. Adicionar testes de precedencia e erro de configuracao.

Criterio de aceite: o CLI Rust aceita o fluxo principal atual e falha com erro claro quando configuracao obrigatoria esta ausente.

### T192 - Criar modelo de eventos append-only do terminal

Status: pending

Evidencia: o usuario quer renderer robusto, inspirado em Codex e `phenom-cli-ts`, com transcript copiavel em tmux e sem glitches. Isso exige separar eventos de renderizacao antes da UI.

Impacto: torna o terminal previsivel e impede que cada feature escreva diretamente no stdout.

Teste primeiro: uma sequencia de eventos user -> assistant -> tool -> diff -> done deve gerar transcript linear deterministico em snapshot plain e ANSI.

Implementacao: criar `UiEvent`, `RenderBlock`, `RenderSink` e uma politica append-only sem alternate screen por padrao.

Passos de implementacao:

1. Definir enum `UiEvent` para user message, assistant delta, tool start/result/error, diff, status e done.
2. Definir `RenderSink` abstrato para TTY, non-TTY e teste.
3. Criar `AppendOnlyRenderer` puro, sem dependencia do loop do agente.
4. Implementar snapshots com largura fixa.
5. Garantir ausencia de clear screen/alternate screen no modo default.
6. Registrar plain transcript para replay/copy.

Criterio de aceite: renderer append-only gera output linear e testavel sem executar modelo.

### T193 - Implementar blocos visuais do CLI final em Rust

Status: pending

Evidencia: as tasks T180-T186 descrevem user query, finalizacao de inferencia, amostragem de tools, espacamentos e divisorias. A versao Rust deve implementar esses blocos como primeira experiencia, nao como port posterior.

Impacto: remove o ponto de dor principal do TS: glitches de render e output inconsistente.

Teste primeiro: snapshots de user query multiline, streaming de resposta, tool longa truncada, erro de tool, done e proximo turno.

Implementacao: criar renderizadores puros por bloco e uma `SpacingPolicy` central.

Passos de implementacao:

1. Criar `render_user_block`.
2. Criar `render_assistant_stream_block`.
3. Criar `render_tool_sample_block`.
4. Criar `render_done_block`.
5. Criar `SpacingPolicy` por transicao de bloco.
6. Cobrir ANSI, `NO_COLOR` e non-TTY.

Criterio de aceite: o output final tem espacamento previsivel, copia limpa e nenhum controle de tela invasivo por padrao.

### T194 - Criar renderer de diff legivel em Rust

Status: pending

Evidencia: o TS usa vermelho/verde que pode ofuscar conteudo. A referencia visual deve ser Codex/`phenom-cli-ts`, mas com paleta propria e legivel.

Impacto: patches ficam revisaveis no terminal, reduzindo risco de aplicar mudanca errada.

Teste primeiro: snapshot de diff pequeno, diff grande truncado, largura estreita, `NO_COLOR` e linhas com tokens curtos.

Implementacao: criar `DiffTheme`, `DiffRenderer` e truncamento configuravel.

Passos de implementacao:

1. Criar fixture de diff com add/remove/context/hunk.
2. Implementar gutter neutro e markers fortes.
3. Evitar background saturado no corpo do codigo.
4. Implementar truncamento com contagem de linhas omitidas.
5. Integrar ao `AppendOnlyRenderer`.
6. Validar fallback plain sem ANSI.

Criterio de aceite: diff comunica alteracoes sem esconder codigo e sem inundar o terminal.

### T195 - Criar cliente de modelo com streaming e erro tipado

Status: pending

Evidencia: o projeto atual usa modelo local/Ollama e testes reais. A versao final precisa separar falha de modelo de falha de infraestrutura, uma das invariantes de confiabilidade.

Impacto: melhora diagnostico em producao e impede que timeout, resposta invalida e indisponibilidade virem "erro generico do agente".

Teste primeiro: cliente fake cobre streaming normal, timeout, conexao recusada, JSON invalido, resposta vazia e cancelamento.

Implementacao: definir trait `ModelClient` com eventos de streaming e `ModelErrorKind`.

Passos de implementacao:

1. Criar trait `ModelClient`.
2. Criar tipos `ModelRequest`, `ModelChunk`, `ModelResponse` e `ModelErrorKind`.
3. Implementar cliente fake para testes do loop.
4. Implementar adaptador Ollama/OpenAI-compatible atras da trait.
5. Separar erros de transporte, protocolo, modelo e cancelamento.
6. Expor stats de duracao/tokens quando disponiveis.

Criterio de aceite: o loop consegue testar comportamento sem modelo real e classifica falhas de forma auditavel.

### T196 - Definir protocolo de mensagens e tool calls do modelo

Status: pending

Evidencia: o audit apontou parser tolerante demais e risco de executar tool inventada. No Rust, o protocolo deve nascer com envelope estrito e parser separado do executor.

Impacto: protege a invariante "tool nao anunciada nunca executa".

Teste primeiro: fixtures de saida do modelo provam: JSON valido vira candidato, texto solto nao executa, tool nao anunciada e rejeitada, multiplas chamadas sao parseadas sem executar.

Implementacao: criar `ToolCallCandidate`, `ToolCallEnvelope`, parser e validador separados.

Passos de implementacao:

1. Definir formato model-visible de chamada de tool.
2. Criar parser tolerante que retorna candidatos e diagnosticos.
3. Criar envelope normalizado com id, nome, args, origem e trecho.
4. Criar validador que exige allowlist do turno.
5. Garantir que parser nao chama executor.
6. Registrar rejeicoes como eventos de audit.

Criterio de aceite: nenhuma chamada chega ao executor sem envelope validado contra tools anunciadas.

### T197 - Criar controller de turno orientado a contratos

Status: pending

Evidencia: contratos sao endpoints de API para o modelo; estrategias sao opcoes internas. O TS misturou regra de negocio em muitas camadas. O Rust deve centralizar o fluxo no controller.

Impacto: reduz comportamento engessado e evita que parser, memoria, prompt ou renderer controlem a regra de negocio.

Teste primeiro: loop fake cobre pergunta simples, chamada de contrato, resultado de tool, reparo curto, finalizacao e limite de iteracoes.

Implementacao: criar `TurnController` com estados explicitos e dependencias injetadas.

Passos de implementacao:

1. Definir estados `Preparing`, `CallingModel`, `Parsing`, `ExecutingTool`, `RenderingContext`, `Final`.
2. Injetar `ModelClient`, `ContractRegistry`, `ToolExecutor`, `ContextBuilder`, `AuditLog` e `Renderer`.
3. Implementar limite de iteracoes e cancelamento.
4. Garantir que renderer recebe eventos, nao decide regra.
5. Garantir que memoria/storage recebem eventos, nao texto bruto solto.
6. Cobrir transicoes com testes unitarios.

Criterio de aceite: um turno completo roda com modelo fake e deixa trilha auditavel.

### T198 - Criar manifesto pequeno de contratos model-visible

Status: pending

Evidencia: o benchmark mostra que o modelo suporta tool calling e tarefas agenticas, mas pode alucinar se receber schema enorme. O manifesto deve ser pequeno e estavel.

Impacto: da autonomia ao modelo sem inchar system prompt ou expor ferramentas internas.

Teste primeiro: snapshot do manifesto valida tamanho, nomes, descricoes curtas e ausencia de tools internas.

Implementacao: criar `ContractManifest` com endpoints iniciais: `collect_evidence`, `mutate_file`, `validate_work`, `inspect_runtime`, `manage_memory`, `news_query`.

Passos de implementacao:

1. Definir tipo `ContractSpec`.
2. Criar descricoes curtas e args essenciais.
3. Separar contratos model-visible de implementacoes internas.
4. Criar snapshot de token/char budget.
5. Adicionar filtro por `ContextProfile`/modo.
6. Bloquear exposicao acidental de tools internas.

Criterio de aceite: o modelo ve uma API pequena e consistente, nao a lista de metodos internos.

### T199 - Criar registry de estrategias dinamicas por contrato

Status: pending

Evidencia: estrategias sao funcoes/opcoes internas do endpoint. Se virarem fluxo persistente rigido, o agente fica engessado.

Impacto: permite compor grep, AST, leitura rangeada, RAG, runtime ou news sem expor tudo ao modelo.

Teste primeiro: `collect_evidence(strategy="symbol")` usa estrategia symbol quando disponivel; estrategia invalida gera fallback/reparo auditado; estrategia omitida escolhe default por perfil.

Implementacao: criar `StrategyRegistry` interno com selecao, fallback e custo.

Passos de implementacao:

1. Definir trait `Strategy`.
2. Definir `StrategyRequest` com contrato, goal, targets, budget e perfil.
3. Registrar estrategias por contrato.
4. Implementar fallback com motivo auditado.
5. Medir custo estimado antes de executar estrategia cara.
6. Garantir que estrategias nao entram no prompt como ferramentas separadas.

Criterio de aceite: contratos ficam pequenos e estrategias permanecem dinamicas, internas e auditaveis.

### T200 - Implementar gate estrito de tools e contratos

Status: pending

Evidencia: uma das provas obrigatorias e que tool nao anunciada nunca executa. Isso precisa existir antes de qualquer tool real.

Impacto: cria a barreira de seguranca principal entre texto do modelo e efeitos no sistema.

Teste primeiro: executor fake prova que chamadas fora da allowlist, alias nao permitido, contrato fora do perfil e args invalidos nao executam.

Implementacao: criar `ExecutionGate` que valida contrato, tool, schema, perfil, permissao e estado do turno.

Passos de implementacao:

1. Definir `AllowedSurface` por turno.
2. Validar nome canonico e aliases permitidos.
3. Validar schema dos args antes do executor.
4. Validar contrato/perfil ativo.
5. Retornar erro reparavel para o modelo quando seguro.
6. Registrar aceites/rejeicoes no audit.

Criterio de aceite: executor so recebe chamadas aprovadas pelo gate.

### T201 - Criar executor de tools com sandbox operacional

Status: pending

Evidencia: o produto precisa ler arquivos, buscar, rodar validacoes, talvez shell/browser, mas sem vazar bruto ao modelo e sem permitir efeitos inesperados.

Impacto: torna ferramentas previsiveis e observaveis.

Teste primeiro: executor fake e tools de filesystem provam cwd preso, path traversal bloqueado, timeout aplicado e output bruto guardado somente no audit/storage.

Implementacao: criar `ToolExecutor`, `ToolResultRaw`, `ToolEvent` e politica de timeout/permissao.

Passos de implementacao:

1. Definir trait `Tool`.
2. Definir `ToolResultRaw` interno.
3. Aplicar raiz operacional/cwd em paths.
4. Aplicar timeout e limite de bytes por tool.
5. Emitir `ToolEvent` tipado.
6. Encaminhar bruto para audit, nao para prompt.

Criterio de aceite: tools reais executam sob controle e produzem evento tipado para destilacao.

### T202 - Implementar tools basicas de codigo em Rust

Status: pending

Evidencia: o fluxo de codigo depende de listar, buscar, ler range, coletar evidencia e aplicar patch. Essas sao as primeiras capacidades reais do agente.

Impacto: permite resolver bugs de codigo com micro-contexto em vez de leitura bruta massiva.

Teste primeiro: fixtures de projeto pequeno cobrem `list_dir`, `search_text`, `read_file_range`, `stat_file` e erros de path.

Implementacao: criar tools internas de filesystem com saida estruturada.

Passos de implementacao:

1. Implementar `list_dir` com limite e ordenacao deterministica.
2. Implementar `search_text` usando estrategia eficiente disponivel.
3. Implementar `read_file_range` com linhas, hash e limite de bytes.
4. Implementar `stat_file` com mtime, tamanho e hash parcial/total.
5. Converter resultados para `ToolEvent`.
6. Criar destiladores iniciais para evidencia de codigo.

Criterio de aceite: o agente consegue coletar evidencia de codigo sem enviar arquivo inteiro por padrao.

### T203 - Implementar patch engine com protecao contra contexto stale

Status: pending

Evidencia: uma invariante obrigatoria e que patch em codigo nao aplica sobre contexto stale. O TS ja tinha preocupacao com micro-contexto e anchors.

Impacto: reduz risco de corromper arquivo quando o conteudo mudou entre leitura e patch.

Teste primeiro: patch aplica quando hash/range batem, rejeita quando arquivo mudou, rejeita full rewrite suspeito e mostra diff antes/depois.

Implementacao: criar `PatchIntent`, `PatchPlan`, `PatchApplyResult` e validacao por hash/range/anchor.

Passos de implementacao:

1. Definir formato de patch aceito pelo agente.
2. Guardar hash/range da evidencia usada.
3. Validar arquivo atual antes de aplicar.
4. Rejeitar contexto stale com erro reparavel.
5. Gerar diff renderizavel apos patch.
6. Registrar patch plan e resultado no audit.

Criterio de aceite: patch nunca aplica quando a evidencia usada esta desatualizada.

### T204 - Criar pipeline Rust de evidencia destilada

Status: pending

Evidencia: tools sao coletores; o modelo deve receber EvidencePacket, nao bruto. Esta e a arquitetura central do audit.

Impacto: protege token budget, reduz alucinacao e torna cada acao comprovavel.

Teste primeiro: resultados brutos grandes viram `EvidencePacket` compacto com path/range/status/hash/trecho; bruto nao aparece no prompt renderizado.

Implementacao: criar `ToolEvent -> EvidenceEntry -> EvidencePacket`.

Passos de implementacao:

1. Definir `EvidenceEntry`.
2. Definir `EvidencePacket` com budget e perfil.
3. Criar destiladores por familia: filesystem, search, patch, validation, news, runtime.
4. Implementar selecao por relevancia/custo.
5. Criar teste anti-vazamento de bruto.
6. Integrar ao audit para rastrear entrada bruta e evidencia final.

Criterio de aceite: o modelo recebe apenas evidencia destilada, proporcional e rastreavel.

### T205 - Implementar `ModelTurnContext` e system prompt compacto

Status: pending

Evidencia: o benchmark mostra modelo pequeno porem capaz; system prompt inchado e contexto minimo gigante prejudicam performance.

Impacto: melhora estabilidade de inferencia e reduz consumo de tokens.

Teste primeiro: snapshot do prompt final valida blocos `[TURN_CONTEXT]`, `[CONTRACTS]`, `[SKILLS]`, `[MEMORY]`, `[EVIDENCE]`, `[OBLIGATIONS]` e ausencia de blocos inexistentes.

Implementacao: criar builder de prompt por `ContextProfile` com budget explicito.

Passos de implementacao:

1. Definir `ModelTurnContext`.
2. Criar system prompt base curto e imutavel.
3. Renderizar contratos ativos compactos.
4. Inserir MEMORY/SKILLS somente se persistidos/promovidos.
5. Inserir EvidencePacket conforme perfil.
6. Medir bytes/chars por bloco em teste; tokens somente via tokenizer real/fake de teste.

Criterio de aceite: o prompt enviado ao modelo e pequeno, auditavel e nao inventa memoria inexistente.

### T206 - Implementar MEMORY/SKILLS como fontes textuais persistentes

Status: pending

Evidencia: MEMORY guarda fatos entre sessoes; SKILLS guarda regras/preferencias confirmadas. Nenhum storage operacional deve competir com esses blocos.

Impacto: corrige a confusao entre memoria conversacional e banco/cache interno.

Teste primeiro: sem arquivos persistidos, blocos nao aparecem; com arquivos validos, aparecem compactos; sugestoes novas ficam pendentes ate promocao explicita.

Implementacao: criar `MemoryStore` textual e `SkillStore` textual com promocao controlada.

Passos de implementacao:

1. Detectar `MEMORY.md`/`.MEMORY.md` no cwd.
2. Detectar `SKILLS.md`/`.SKILL.md` no cwd.
3. Implementar leitura compacta e limite de budget.
4. Criar candidatos de update sem persistir automaticamente.
5. Criar comando/contrato de promocao explicita.
6. Testar que SQLite/cache nunca vira bloco `[MEMORY]`.

Criterio de aceite: MEMORY/SKILLS sao as unicas fontes persistentes textuais visiveis ao modelo.

### T207 - Criar SQLite operacional unico

Status: pending

Evidencia: o projeto `cli-agent-v2` usa SQLite para memory logger/news/session. Para o Phenom, SQLite deve guardar audit, news sources, cache e metadata operacional, mas nao substituir MEMORY/SKILLS.

Impacto: reduz montanha de arquivos soltos e melhora reproducibilidade.

Teste primeiro: banco temporario cria schema, registra turno, source de news, cache de fetch e evento de audit sem criar arquivos extras fora do esperado.

Implementacao: criar `OperationalStore` SQLite com migrations versionadas.

Passos de implementacao:

1. Definir path controlado do banco por workspace/sessao.
2. Criar migrations para `turns`, `events`, `tool_raw`, `trusted_sources`, `fetch_cache`.
3. Implementar adapter com transacoes.
4. Garantir cleanup em testes temporarios.
5. Separar storage operacional de prompt rendering.
6. Adicionar teste que conta arquivos criados pelo fluxo basico.

Criterio de aceite: operacao do agente nao cria montanha de arquivos e nao injeta storage no modelo.

### T208 - Implementar audit e replay reproduzivel

Status: pending

Evidencia: cada turno precisa ser auditado e reproduzido. Isso tambem prova as sete invariantes de confiabilidade.

Impacto: transforma bugs de modelo/agente em casos reproduziveis, nao em relatos subjetivos.

Teste primeiro: turno com modelo fake e tool fake grava audit; replay reconstrui prompt, tools anunciadas, tool calls, eventos e resposta final.

Implementacao: criar `AuditRecorder`, `AuditReader` e comando `replay`.

Passos de implementacao:

1. Registrar request do modelo sem segredos.
2. Registrar prompt renderizado ou hash + blocos auditaveis.
3. Registrar tools anunciadas e chamadas rejeitadas/aceitas.
4. Registrar ToolEvent, EvidencePacket e resposta final.
5. Implementar replay deterministico com modelo fake gravado.
6. Criar resumo CLI de audit.

Criterio de aceite: um turno pode ser explicado e reproduzido sem depender de memoria humana.

### T209 - Implementar validacao e diagnosticos como evidencia

Status: pending

Evidencia: validacao nao deve virar regra de negocio solta; deve produzir evidencia objetiva. O TS tinha `run_validation`, LSP/browser e testes reais separados.

Impacto: o agente entende falhas de build/test/runtime sem confundir com falha de modelo.

Teste primeiro: comando fake de validacao produz success, failure, timeout e stderr longo; todos viram EvidenceEntry compacta.

Implementacao: criar contrato interno `validate_work` com estrategias `command`, `syntax`, `test`, `diagnostic`.

Passos de implementacao:

1. Implementar executor de comando controlado por timeout.
2. Capturar exit code, stdout/stderr amostrados e duracao.
3. Classificar severidade de diagnostico.
4. Destilar output em EvidenceEntry.
5. Renderizar resultado no CLI sem vazar bruto enorme.
6. Registrar comando e ambiente no audit.

Criterio de aceite: validacao guia o agente com evidencia compacta e erro tipado.

### T210 - Implementar perfis de contexto em Rust

Status: pending

Evidencia: o usuario corrigiu que micro-contexto nao serve para tudo. O Rust precisa nascer com `code_micro`, `news_operational`, `mass_read` e `runtime_diagnostics`.

Impacto: evita transformar baixo consumo de tokens em limitacao burra do produto.

Teste primeiro: cada contrato resolve perfil correto e renderiza contexto diferente para codigo, news, leitura massiva e diagnostico.

Implementacao: criar enum `ContextProfile` e politicas por perfil.

Passos de implementacao:

1. Definir `ContextProfile`.
2. Mapear contratos para perfil default.
3. Permitir override controlado pelo controller.
4. Criar budgets por perfil.
5. Criar renderizadores de contexto por perfil.
6. Testar que news nao usa micro-contexto de codigo.

Criterio de aceite: o agente escolhe formato de contexto pelo dominio, nao por uma regra global minimalista.

### T211 - Implementar News com catalogo operacional de fontes

Status: pending

Evidencia: o fluxo de noticias deve descobrir fontes dentro de tabela de dados, como no `cli-agent-v2`, nao depender de prompt improvisado nem de contexto minimo.

Impacto: torna News confiavel e independente de alucinacao de fontes pelo modelo.

Teste primeiro: banco com `trusted_sources` retorna fontes por topico/localidade/confianca; sem fontes suficientes, o contrato falha com erro operacional claro.

Implementacao: criar tabelas e provider `NewsSourceProvider`.

Passos de implementacao:

1. Definir schema `trusted_sources`.
2. Implementar seed/import controlado de fontes.
3. Implementar selecao por topico, localidade, idioma e score.
4. Registrar fonte escolhida no audit.
5. Bloquear uso de fonte nao cadastrada sem permissao explicita.
6. Testar separacao entre trusted sources e MEMORY.

Criterio de aceite: News parte de catalogo operacional, nao de improviso no prompt.

### T212 - Implementar pipeline News de coleta, ranking e dossie

Status: pending

Evidencia: News precisa operar com RSS/homepage/cache/deduplicacao/chunks e entregar dossie estruturado ao modelo/formatter.

Impacto: suporta tarefas em que contexto minimo seria insuficiente.

Teste primeiro: fixtures RSS/HTML locais geram noticias deduplicadas, ranqueadas e renderizadas como `NEWS_DOSSIER` compacto.

Implementacao: criar `NewsFetcher`, `NewsRanker`, `NewsDossier`.

Passos de implementacao:

1. Buscar fontes selecionadas com cache operacional.
2. Parsear RSS/HTML em itens normalizados.
3. Deduplicar por URL/titulo/hash.
4. Rankear por recencia, confianca da fonte e relevancia.
5. Criar chunks/resumo operacional.
6. Renderizar `NEWS_DOSSIER` sem despejar HTML bruto.

Criterio de aceite: News produz contexto rico, estruturado e auditavel sem depender de prompt improvisado.

### T213 - Implementar leitura massiva para PDFs/logs como perfil separado

Status: pending

Evidencia: PDFs, logs e leitura em massa nao funcionam bem com micro-contexto isolado. Precisam de indexacao, chunks e resumo hierarquico.

Impacto: expande o Phenom alem de codigo sem quebrar a arquitetura de contexto.

Teste primeiro: fixtures de log grande e texto longo geram indice, chunks, resumo por secao e EvidencePacket agregado.

Implementacao: criar pipeline `mass_read` inicial para texto/logs; PDF pode entrar depois por adapter.

Passos de implementacao:

1. Criar `DocumentChunk` e `DocumentIndex`.
2. Implementar ingestao de texto/log com limites.
3. Implementar busca e resumo hierarquico deterministico/fake para testes.
4. Criar EvidencePacket agregado por topico.
5. Separar bruto no storage operacional.
6. Planejar adapter PDF sem bloquear a base inicial.

Criterio de aceite: leitura massiva nao usa o mesmo micro-contexto de patch de codigo.

### T214 - Criar harness de testes reais com modelo separado dos testes de infraestrutura

Status: pending

Evidencia: o audit exige separar capacidade real do modelo de garantia do agente. O benchmark `phenom_latest.txt` mede capacidade, mas nao deve ser confundido com teste unitario.

Impacto: evita regressao silenciosa e permite rodar CI sem modelo real.

Teste primeiro: suite offline com modelo fake passa sem Ollama; suite real fica opt-in por env e registra modelo/host/data.

Implementacao: criar `tests/offline`, `tests/real_model` e comandos cargo separados.

Passos de implementacao:

1. Criar modelo fake deterministico para loop.
2. Criar fixtures reais de saida do modelo.
3. Criar testes opt-in para Ollama/OpenAI-compatible.
4. Registrar benchmark usado e capacidades esperadas.
5. Garantir que falha real do modelo nao falha suite offline.
6. Criar relatorio curto por run real.

Criterio de aceite: infraestrutura e modelo real sao medidos separadamente.

### T215 - Migrar fixtures e comportamentos provados do TS para Rust

Status: pending

Evidencia: o TS provou fluxos de tool loop, micro-contexto, contratos, renderer e testes reais. A migracao deve preservar comportamento, nao codigo.

Impacto: reduz risco de perder aprendizados da prova de conceito.

Teste primeiro: cada fixture migrada deve falhar no Rust antes da feature correspondente e passar apos implementacao.

Implementacao: criar pasta de fixtures de compatibilidade com casos extraidos de `src/tests`, `../phenom-cli-ts/src/tests` e benchmark.

Passos de implementacao:

1. Catalogar fixtures TS relevantes por area.
2. Converter fixtures para JSON/texto neutro.
3. Criar testes Rust que consomem fixtures sem depender de TS.
4. Marcar fixtures que representam anti-exemplos/regressoes.
5. Remover dependencia de runtime Node nos testes Rust.
6. Registrar cobertura no devlog por invariante.

Criterio de aceite: aprendizados do TS entram como provas executaveis no Rust.

### T216 - Criar pacote distribuivel e wrapper npm opcional

Status: pending

Evidencia: Codex usa Rust como implementacao real e npm como canal de distribuicao/launcher. O usuario perguntou sobre essa arquitetura e ela pode ser util para distribuicao sem manter TS como core.

Impacto: entrega binario robusto sem abandonar ergonomia de instalacao via npm quando conveniente.

Teste primeiro: pacote local chama binario Rust e `phenom --version` funciona sem compilar em runtime.

Implementacao: criar build release e wrapper npm fino apenas para localizar/executar binario.

Passos de implementacao:

1. Definir targets suportados inicialmente.
2. Criar processo de build release.
3. Criar wrapper npm minimo sem regra de negocio.
4. Testar execucao do binario pelo wrapper.
5. Garantir que logs/config continuam no mesmo layout.
6. Documentar que Node nao e runtime do agente final.

Criterio de aceite: distribuicao pode usar npm sem trazer de volta a fragilidade TS no core.

### T217 - Criar taxonomia de erros e saidas de diagnostico

Status: pending

Evidencia: falha de modelo nao pode parecer falha de infraestrutura. O mesmo vale para tool, contrato, validacao, storage e renderer.

Impacto: melhora confiabilidade percebida e depuracao em producao.

Teste primeiro: cada categoria de erro gera mensagem curta ao usuario, evento de audit e codigo interno distinto.

Implementacao: criar `PhenomError` com `ErrorKind` e conversoes controladas.

Passos de implementacao:

1. Definir categorias: config, model, protocol, contract, tool, storage, validation, render, user_cancelled.
2. Criar formato de erro para CLI.
3. Criar formato detalhado para audit.
4. Evitar `anyhow` opaco nas fronteiras principais.
5. Mapear erros de crates externas para categorias.
6. Testar mensagens e codigos.

Criterio de aceite: diagnosticos sao especificos, acionaveis e reproduziveis.

### T218 - Implementar cancelamento, timeout e controle de concorrencia

Status: pending

Evidencia: agente real precisa lidar com streaming, tools longas, subprocessos e fetch de news sem travar terminal.

Impacto: melhora previsibilidade em producao e evita processos perdidos.

Teste primeiro: modelo lento, tool lenta, fetch lento e Ctrl-C simulado encerram com estado auditado e sem deixar task pendente.

Implementacao: usar runtime async com cancel tokens e limites por operacao.

Passos de implementacao:

1. Definir timeout default por modelo, tool, validation e news fetch.
2. Criar cancel token por turno.
3. Propagar cancelamento para subprocess/fetch/model stream.
4. Emitir evento de UI de cancelamento.
5. Registrar cancelamento no audit.
6. Testar que recursos sao liberados.

Criterio de aceite: operacoes longas nao deixam o CLI preso ou inconsistente.

### T219 - Criar suite agregada das sete invariantes no Rust

Status: pending

Evidencia: o usuario exigiu provas explicitas: tool nao anunciada, bruto nao vaza, MEMORY/SKILLS separados, News sem prompt improvisado, patch sem stale, erro tipado e replay.

Impacto: define o nivel minimo de confiabilidade para uso real.

Teste primeiro: suite `reliability_invariants` falha enquanto qualquer garantia nao estiver implementada.

Implementacao: agregar testes offline que exercitam controller, gate, contexto, storage, news, patch, erro e audit.

Passos de implementacao:

1. Criar teste para tool nao anunciada.
2. Criar teste para anti-vazamento de bruto.
3. Criar teste para MEMORY/SKILLS vs SQLite.
4. Criar teste para News via trusted sources.
5. Criar teste para patch stale.
6. Criar teste para erro tipado e replay.

Criterio de aceite: a suite das invariantes passa sem modelo real.

### T220 - Criar gate de pronto para migracao final

Status: pending

Evidencia: reescrever do zero so vale se a base Rust provar que cobre o que o projeto atual faz e corrige o que deu errado anteriormente.

Impacto: impede declarar a migracao concluida por entusiasmo ou por existencia de binario parcial.

Teste primeiro: comando `phenom doctor --release-gate` ou teste equivalente lista capacidades implementadas, pendentes e bloqueantes.

Implementacao: criar checklist executavel de release/migracao.

Passos de implementacao:

1. Listar capacidades essenciais do TS atual.
2. Mapear cada capacidade para task Rust.
3. Mapear cada problema do audit para teste Rust.
4. Criar comando/relatorio de gate.
5. Bloquear release se invariantes falharem.
6. Registrar no devlog o primeiro ponto em que Rust pode substituir TS.

Criterio de aceite: existe uma definicao objetiva de quando o Phenom Rust e confiavel para uso real.

## Fase 20 - Produto Zig + C do Phenom final

Esta fase registra a mudanca pratica de direcao: em vez de aceitar Rust como decisao final sem prova, criar a base inicial do produto em Zig + C para medir e consolidar se a filosofia de controle total combina melhor com o Phenom.

### T221 - Implementar base inicial `phenom-zig` com renderer, HTTP local, SQLite, gate e evidencia

Status: implemented-verified

Evidencia: o usuario definiu explicitamente a base inicial necessaria: CLI chat, renderer append-only, streaming HTTP local para llama.cpp e Ollama, SQLite audit, tool gate fake, `read_file_range`, `EvidencePacket`, snapshot de terminal e build release.

Impacto: transforma a discussao filosofica Zig+C vs Rust em prova tecnica local, pequena e reversivel.

Teste primeiro: a base inicial inclui testes unitarios/snapshots para CLI args, renderer append-only, tool gate, EvidencePacket e parsing de deltas Ollama/llama.cpp. Verificado com Zig 0.16.0 baixado em `/tmp`, usando `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache`.

Implementacao: criar `phenom-zig/` isolado, sem tocar no core TS, usando Zig como core e `sqlite3` via C.

Passos de implementacao:

1. Criar `phenom-zig/build.zig` com binario `phenom`, teste e link C/SQLite.
2. Criar CLI minimo `chat`, `snapshot`, `version` com flags de host, backend, model, session, prompt, offline e no-color.
3. Criar renderer append-only deterministico com snapshot plain.
4. Criar cliente HTTP local baixo nivel para Ollama `/api/chat` e llama.cpp `/completion`, com chunked transfer e linhas SSE/NDJSON.
5. Criar audit SQLite via `sqlite3` C em `.phenom-zig/phenom.db`.
6. Criar gate fake e tool `read_file_range` com protecao contra path traversal.
7. Criar `EvidencePacket` compacto para evidencia de arquivo.
8. Adicionar `.gitignore` para build/runtime do produto.
9. Documentar comandos esperados de teste, build release e chat no README do produto.

Criterio de aceite: `zig build test`, `zig build -Doptimize=ReleaseFast`, `zig build run -- snapshot` e `chat --offline` passam. Chat real contra Ollama/llama.cpp ainda deve ser executado quando houver servidor local ativo.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build run -- snapshot`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build run -- chat --offline --session dev --prompt "responda somente: ok"`

Resultado observado:

- Snapshot append-only gerou `> user`, `assistant`, `done` em ordem linear.
- SQLite `.phenom-zig/phenom.db` registrou `turn_start`, `assistant` e `turn_done`.
- Binario release gerado em `phenom-zig/zig-out/bin/phenom` com tamanho observado de 12 MB.
- Ajuste posterior no streaming: deltas de llama.cpp/Ollama decodificam escapes JSON como `\n` e o renderer filtra `<think>...</think>` para nao vazar reasoning no transcript.
- Ajuste posterior de regressao: filtro de reasoning agora e stateful e cobre tags `<think>`/`</think>` quebradas entre chunks; `--max-tokens` foi adicionado para limitar geracao.
- Ajuste posterior de protocolo: payload llama.cpp passou a seguir o `chat_template.jinja` Qwopus/Qwen fornecido pelo usuario, com `<|im_start|>system/user/assistant`, `<think>\n\n</think>\n\n` para `enable_thinking=false` e stop em `<|im_end|>`.
- Ajuste posterior de thinking dinamico: CLI ganhou `--thinking auto|on|off`; `off` usa bloco de thinking vazio/fechado do template, `on` abre `<think>\n`, e `auto` liga thinking para prompts com sinais de codigo/debug/patch/tool/arquivo/tarefa longa.
- Ajuste posterior de render: thinking deixou de ser apagado; agora e classificado e exibido em baixo destaque com bloco `thinking`, separado do output `assistant`. O filtro cobre tags quebradas entre chunks e tambem o caso em que apenas `</think>` aparece no stream porque `<think>` ja veio do prompt/template.

### T222 - Criar base agente offline no produto Zig com tool call, tool loop e micro-contexto

Status: implemented-verified-micro-base

Evidencia: as tasks primarias T196, T197, T200, T202, T204 e T214 exigem parser de tool call separado do executor, gate estrito, loop fake/offline, tools basicas de codigo, EvidencePacket/micro-contexto e separacao entre teste offline e teste real. A base T221 tinha renderer, HTTP, SQLite, gate fake, `read_file_range` e EvidencePacket, mas ainda nao tinha tool call model-visible, tool loop nem micro-contexto testado.

Impacto: transforma a base de CLI streaming em uma micro-base inicial de agente, nao em agente completo. O que existe agora: um output fake/offline pode conter uma tool call no formato do template Qwopus; o controller offline parseia uma chamada, valida allowlist, executa uma unica tool permitida, gera evidencia e micro-contexto sem depender de modelo real ou host local.

Escopo real implementado:

- Parser simples de uma unica chamada `<tool_call>`.
- Gate simples por allowlist de nomes.
- Execucao somente de `read_file_range`.
- Uma iteracao offline, sem chamada real de modelo no meio do loop.
- EvidencePacket textual simples.
- MicroContext simples com path/range/hash.
- Testes unitarios/offline sem rede.

O que isto nao implementa:

- Nao implementa tool loop real modelo -> tool -> modelo.
- Nao implementa multiplas tool calls no mesmo turno.
- Nao implementa contratos model-visible completos.
- Nao implementa manifest de tools/contratos no prompt.
- Nao implementa retorno `<tool_response>` no formato do template.
- Nao implementa audit completo de tool calls aceitas/rejeitadas.
- Nao implementa replay.
- Nao implementa patch seguro/stale check.
- Nao implementa estrategia dinamica de contexto.
- Nao implementa budget de contexto.
- Nao implementa separacao completa de raw tool output vs contexto enviado ao modelo.
- Nao implementa teste real contra llama.cpp/Ollama.
- Nao implementa renderer visual completo estilo Codex/phenom-cli-ts; o renderer atual ainda e minimo.
- Nao implementa CLI final identico ao `phenom-cli-ts`; apenas uma base operacional pequena.

Teste primeiro: foram adicionados testes offline para parser XML de `<tool_call>`, rejeicao de texto sem tool, execucao de `read_file_range` anunciada, rejeicao de tool nao anunciada antes da execucao e renderizacao de `MicroContext` com path/range/hash.

Implementacao: criar modulos pequenos em `phenom-zig/src`:

- `tool_call.zig`: parser XML do formato `<tool_call><function=...><parameter=...>`.
- `tool_loop.zig`: loop offline de uma iteracao, com parse -> gate -> executor -> EvidencePacket -> MicroContext.
- `micro_context.zig`: contexto pequeno com path, range e hash derivado de `read_file_range`.

Passos de implementacao:

1. Criar parser de tool call compatível com o formato XML do `chat_template.jinja`.
2. Garantir que texto normal nao vira tool call.
3. Reusar `gate.isAllowed` antes de executar qualquer tool.
4. Executar somente `read_file_range` no loop inicial.
5. Converter resultado em `EvidencePacket`.
6. Converter o mesmo resultado em `MicroContext` com path/range/hash.
7. Adicionar testes offline que nao usam rede, Ollama, llama.cpp nem `127.0.0.1`.
8. Atualizar README para separar comandos offline de exemplos reais de backend.

Criterio de aceite: `zig build test` e `zig build -Doptimize=ReleaseFast` passam; nenhum teste offline assume host real ativo; tool nao anunciada nao executa; tool anunciada gera evidencia e micro-contexto.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest`

Resultado observado:

- Suite offline passou sem servidor local.
- Release build passou.
- `real-smoke` contra `192.168.1.122:11434` falhou deste ambiente com `ConnectFailed` e exit code nao-zero, que e o comportamento esperado para teste real quando o servidor nao esta acessivel.
- A qualidade da resposta do modelo na nova infraestrutura nao foi validada deste ambiente porque o backend real nao conectou; deve ser reexecutada no host/rede onde `curl http://HOST:PORT/completion` conecta.
- `tool_loop` executa `read_file_range` apenas quando `read_file_range` esta na allowlist.
- `tool_loop` rejeita `shell` quando apenas `read_file_range` esta anunciado.
- `MicroContext` renderiza `path`, `lines` e `hash`.
- README nao apresenta `127.0.0.1:11434` como validacao real; backend real exige `HOST:PORT` ativo e comando separado.

Pendencias mapeadas para tasks existentes:

- T196: ainda falta protocolo completo de tool calls, envelope tipado, diagnosticos de parser, multiplas chamadas e separacao formal parser/executor.
- T197: ainda falta controller de turno real com estados, modelo fake injetavel, limite de iteracoes, repair e finalizacao.
- T198: ainda falta manifesto pequeno de contratos model-visible e snapshot de tamanho/schema.
- T199: ainda falta registry de estrategias dinamicas por contrato.
- T200: o gate atual e so allowlist por nome; falta validar schema, contrato ativo, perfil, permissao e estado do turno.
- T201: ainda falta executor generico de tools com sandbox, timeout, limite de bytes e ToolEvent tipado.
- T202: so existe `read_file_range`; faltam `list_dir`, `search_text`, `stat_file` e saidas estruturadas completas.
- T203: patch engine/stale check ainda nao existe.
- T204: EvidencePacket existe em forma simples; falta pipeline real ToolEvent -> EvidenceEntry -> EvidencePacket por familia de tool e anti-vazamento de bruto.
- T205: ainda falta ModelTurnContext e system prompt compacto renderizado por perfil.
- T208: audit SQLite existe de forma simples; falta audit/replay reproduzivel de turno, prompt, tools anunciadas, chamadas rejeitadas/aceitas e evidencia final.
- T214: falta harness real separado para modelo; hoje ha somente testes offline.
- T219: falta suite agregada das sete invariantes no Zig.
- T180-T186: renderer ainda nao atingiu o visual Codex/phenom-cli-ts; faltam snapshots e2e de user query, tool sample, diff, done, spacing e transcript completo.

Complexidade restante:

- Alta: tool loop real com modelo em streaming, porque precisa pausar/interpretar resposta parcial, executar tool, montar `<tool_response>` e chamar o modelo novamente sem duplicar contexto.
- Alta: contrato/strategy system, porque precisa manter surface pequena para o modelo sem engessar fluxo interno.
- Alta: patch seguro, porque depende de micro-contexto com hash/range/anchor e rejeicao de contexto stale.
- Alta: audit/replay, porque precisa gravar prompt, tools anunciadas, chamadas, rejeicoes, outputs brutos internos, evidencia destilada e resposta final sem vazar segredos.
- Media/alta: renderer final, porque precisa ser append-only, copiavel, legivel em tmux, com thinking/tool/diff/status separados e snapshots ANSI/plain.
- Media: tools basicas de codigo, porque `read_file_range` ja provou filesystem minimo, mas faltam busca, listagem, stat/hash e limites robustos.
- Media: testes reais, porque dependem de ambiente externo e devem ficar opt-in, sem contaminar suite offline.

## Riscos conhecidos

- Reintroduzir muitos modulos da referencia de uma vez recriaria o problema original de patches confusos.
- Endurecer parser diretamente pode quebrar backends locais; o endurecimento deve ficar no gate parser->executor.
- Reduzir tool surface demais pode limitar o modelo apesar do benchmark forte; por isso a reducao deve ser faseada e auditavel.
- Qualquer memoria operacional nova que vire fonte de contexto concorrente viola a arquitetura; tool results devem virar EvidencePacket temporario, e persistencia so ocorre via promocao explicita para MEMORY ou SKILLS.
- Browser/LSP podem introduzir dependencia ambiental; primeiro devem ter testes offline/mocks.
- Aplicar micro-contexto a todos os dominios e uma regressao arquitetural. News, PDFs, logs e leitura massiva exigem perfis de contexto agregados e stores operacionais internos.
- Catalogos operacionais como `trusted_sources` nao podem virar `[MEMORY]`, mas tambem nao devem ser descartados como "contexto demais"; eles sao infraestrutura de dominio.
- Portar o renderer do `phenom-cli-ts` sem corrigir a paleta de diff manteria um problema de UX real: cores red/green podem ofuscar o conteudo. Diff deve ter teste visual antes de mudanca.
- Inspiracao no Codex deve respeitar fonte/licenca; por padrao extrair principios de UX e implementar localmente.
- Copiar visual do Codex sem preservar append-only/tmux/copy seria uma implementacao superficial. O comportamento de transcript linear e parte do requisito.
- Renderer sem snapshots e fragil: pequenas mudancas em newline/status/tool output podem quebrar a experiencia de uso real.
- A reescrita Rust nao pode virar port mecanico do TS. TS e referencia de comportamento, fixtures e anti-regressoes; a arquitetura final deve nascer com fronteiras menores e testes primeiro.
- Usar npm como distribuicao opcional nao pode recolocar Node/TS no core do agente. O wrapper deve apenas localizar e executar o binario Rust.
- Rust nao elimina bugs de produto por si so. As sete invariantes e o replay continuam sendo o criterio real de confiabilidade.

## Definicao de pronto para cada task

- Teste criado antes ou no mesmo patch, falhando sem a feature quando aplicavel.
- Secao `Passos de implementacao` presente e especifica o suficiente para guiar o patch.
- Secao `Alinhamento AUDIT/TASKS/phenom-cli-ts` presente. Sem essa secao, a task fica bloqueada, mesmo que tenha teste e codigo.
- Implementacao pequena e localizada.
- `TASKS.md` atualizado com status e notas.
- Testes relevantes executados e registrados.
- Nenhuma mudanca nao relacionada revertida.
- Evidencia de impacto no agente ou no consumo de tokens registrada quando a task tocar prompt, tools, memoria ou evidencia.
- Sempre registrar se a task cumpriu 100% do objetivo ou se e micro-base/parcial.
- Se a task nao cumprir 100%, registrar explicitamente a complexidade restante e quais tasks futuras cobrem essa lacuna.
- Sempre que a feature depender de servidor/modelo real, criar ou registrar teste real opt-in separado da suite offline.
- Nunca considerar `127.0.0.1:11434` como prova offline; host real ativo precisa ser passado por parametro e validado em comando real separado.
- Teste real de servidor/modelo deve falhar com exit code nao-zero quando houver erro de conexao/protocolo/modelo; erro real nao pode parecer sucesso de infraestrutura.

### Secao obrigatoria de alinhamento por task

Motivacao: `alinhamento.md` mostrou que a maior fonte atual de regressao nao e sintaxe Zig, e sim quebra de contrato com `AUDIT`, `TASKS.md` e `../phenom-cli-ts`. Portanto, toda task nova ou pendente que for executada precisa conter exatamente este bloco antes da implementacao:

```md
Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada:
- Falha apontada no AUDIT/TASKS:
- O que sera preservado do TS:
- O que sera corrigido no Zig:
- O que nao sera portado agora e por que:
- Invariantes afetadas:
- Teste unitario obrigatorio:
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop:
- Revisao baixo nivel Zig antes do commit:
```

Regra operacional:

- Tasks historicas ja implementadas continuam como devlog.
- Tasks pendentes antigas sem esse bloco nao podem ser executadas ate receberem esse complemento.
- Tasks urgentes T281-T290 abaixo sobem acima das demais tasks pendentes porque corrigem desalinhamentos estruturais entre `phenom-zig`, `AUDIT` e `phenom-cli-ts`.
- Se a task portar comportamento ja existente no TS, a referencia TS precisa ser arquivo/linha ou funcao concreta, nao memoria do agente.
- Se nao houver equivalente TS, a task deve declarar explicitamente: `Nao existe referencia TS direta`.

## T223 - Corrigir smoke real do `phenom-zig` para provar inferencia visivel

Status: implemented-verified-partial-real-backend.

Cumprimento: parcial controlado. A task cumpre 100% do objetivo pequeno de impedir falso positivo do `real-smoke`: agora o comando so passa quando ha resposta visivel esperada. Ela nao cumpre 100% de "provar conexao" em todos os ambientes, porque a execucao normal do sandbox bloqueou socket do binario Zig. Esta task nao implementa tool loop real nem agente completo.

Evidencia:

- O usuario reportou que o teste "nao esta chegando ao servidor" e depois que "o retorno e ok, mas o modelo em si nao processou nada".
- `curl -v http://192.168.1.122:11434/` conectou e recebeu `HTTP/1.1 200 OK` com `Server: llama.cpp`, provando que o servidor estava acessivel pelo transporte HTTP quando a ferramenta de rede estava liberada.
- `curl -v http://192.168.1.122:11434/completion` com `n_predict=32` recebeu `200 OK`, mas o conteudo parou dentro de `<think>`, provando que token baixo pode parecer "sem resposta" mesmo com inferencia iniciada.
- `curl` com prompt Qwopus thinking-off, `n_predict=96` e token sentinela retornou `content:"PHENOM_REAL_7319"`, provando que o backend/modelo processa quando o prompt e o budget permitem resposta final.
- O binario Zig dentro do sandbox falhou com `SocketCreateFailed`; o mesmo `real-smoke` com permissao de rede liberada passou e imprimiu `PHENOM_REAL_7319`. Isto prova que o smoke real precisa rodar em ambiente com socket liberado. Nao se deve comparar diretamente `curl` aprovado/rede liberada com o binario Zig sandboxado como se fossem o mesmo perfil de permissao.

Impacto:

- O teste real deixa de aceitar sucesso fraco como `ok`.
- Falha de transporte, falha HTTP, resposta vazia e falha de inferencia visivel passam a ser separadas.
- A validacao real com permissao de rede liberada prova que o request saiu do binario Zig, chegou no llama.cpp e gerou texto visivel esperado.
- A validacao normal em sandbox prova somente que o erro e classificado como transporte e nao vira falso sucesso.

Teste primeiro:

- Adicionar teste offline de parse de `--expect-contains`.
- Adicionar teste offline de parser de status HTTP 2xx vs nao-2xx.
- Reexecutar smoke real com token sentinela contra servidor ativo.

Implementacao:

- `phenom-zig/src/cli.zig`: adicionar `--expect-contains TEXT`.
- `phenom-zig/src/main.zig`: acumular resposta visivel do streaming e falhar com `ExpectedVisibleOutputMissing` se a expectativa nao aparecer.
- `phenom-zig/src/http.zig`: validar status HTTP antes de processar corpo; adicionar caminho direto para IPv4 literal por `sockaddr_in` e manter fallback `getaddrinfo` para nomes de host.
- `phenom-zig/build.zig`: mudar `real-smoke` default para prompt `Complete: PHENOM_REAL_7319`, `--max-tokens 96`, `--thinking off` e `--expect-contains PHENOM_REAL_7319`.
- `phenom-zig/README.md`: documentar que `real-smoke` exige rede liberada e valida conteudo gerado.

Passos de implementacao:

1. Provar servidor com `curl` antes de alterar o binario.
2. Provar que token baixo pode terminar dentro do reasoning.
3. Criar uma expectativa objetiva de saida visivel.
4. Fazer o CLI acumular apenas saida visivel, nao thinking.
5. Falhar o comando real quando a expectativa nao aparece.
6. Endurecer transporte IPv4 literal do cliente Zig sem declarar que isso resolve todos os perfis de rede.
7. Reexecutar suite offline, build release e smoke real.

Criterio de aceite:

- `zig build test` passa sem rede/modelo.
- `zig build -Doptimize=ReleaseFast` passa.
- `zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` retorna exit code 0 somente quando a saida visivel contem `PHENOM_REAL_7319`.
- Se o ambiente bloquear sockets para o binario Zig, a falha deve aparecer como erro de transporte e nao como sucesso de modelo.
- A task nao esta completa para diagnostico de rede ate existir erro tipado com errno/address/status no audit.

Validacao executada:

- `curl -sS -v --connect-timeout 3 http://192.168.1.122:11434/` -> conectou, `HTTP/1.1 200 OK`, `Server: llama.cpp`.
- `curl -sS -v --connect-timeout 3 http://192.168.1.122:11434/completion ... n_predict=32 ...` -> conectou e inferiu, mas parou dentro de `<think>`.
- `curl -sS http://192.168.1.122:11434/completion ... thinking-off ... n_predict=96 ...` -> retornou `PHENOM_REAL_7319`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

## T258 - Criar `ToolEvent` tipado e audit summary sem vazamento de raw

Status: implemented-verified.

Motivacao: T257 criou o executor `collect_evidence`, mas ainda faltava a fronteira formal entre raw interno e evidencia destilada. As tasks T070, T071, T072, T161, T201, T204 e T208 apontam o mesmo risco: se outputs de tools continuarem como texto solto, o loop real pode reinjetar bruto no modelo, perder replay e confundir falha de tool com falha de modelo.

Evidencia:

- `TASKS.md` T070 pede `ToolEvent`, `EvidenceEntry` e `ModelTurnContext`.
- `TASKS.md` T071 pede raw output no event store, nao no prompt.
- `TASKS.md` T204 pede pipeline `ToolEvent -> EvidenceEntry -> EvidencePacket`.
- `TASKS.md` T257 deixou pendente `ToolEvent` tipado com raw interno persistido no audit.
- `phenom-zig/src/collect_evidence.zig` ainda criava EvidenceEntry diretamente do range, sem evento intermediario.

Impacto esperado:

- `ToolEvent` passa a ser a fronteira owned de resultado bruto de tool.
- Raw output existe no event store em memoria para audit/replay operacional.
- EvidenceEntry passa a ser derivada de ToolEvent com budget.
- Audit SQLite recebe resumo com tool, args, path, range, raw_bytes e raw_hash, sem conteudo bruto.
- O proximo `ModelTurnContext` pode consumir EvidencePacket sabendo que raw nao entra no prompt.

Teste primeiro:

- `tool_event` prova que raw existe no evento, mas nao aparece no audit summary.
- `tool_event` prova destilacao budgetada para EvidenceEntry sem tail bruto.
- `tool_event` prova Store owns dos eventos appendados.
- `collect_evidence` prova que `tool_event_audit_text` contem metadata e nao contem tail bruto.
- `audit` prova que `recordToolEventSummary` grava metadata e nao grava raw output.

Implementacao:

- `phenom-zig/src/tool_event.zig`: criar `ToolEvent`, `Store`, `fromFileRange`, `toEvidenceEntryBudgeted` e `renderAuditSummary`.
- `phenom-zig/src/collect_evidence.zig`: trocar fluxo para `ToolEvent -> EvidenceEntry`.
- `phenom-zig/src/audit.zig`: adicionar `recordToolEventSummary`.
- `phenom-zig/src/main.zig`: incluir `tool_event.zig` na suite principal.

Passos de implementacao:

1. Criar ToolEvent owned com raw output e metadata.
2. Criar Store simples em memoria.
3. Criar conversao ToolEvent -> EvidenceEntry budgetada.
4. Criar audit summary sem raw.
5. Integrar collect_evidence ao evento.
6. Criar metodo de audit SQLite para summary.
7. Rodar testes focados e build completo.
8. Revisar ownership, leak, truncamento e anti-vazamento antes do commit.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `ToolEvent.deinit` libera tool, args, path, raw e erro opcional.
- Store: `Store.append` assume ownership e usa `errdefer` em falha de append.
- Distilacao: `toEvidenceEntryBudgeted` cria `FileRange` temporario owned e libera no defer.
- Audit: summary usa `allocPrint` e `recordEvent`; nao inclui `raw_output`.
- Anti-vazamento: testes usam `SECRET_RAW_TAIL` e falham se aparecer em evidence/model/audit summary.
- Limite: esta task nao cria persistencia de blob raw em SQLite; raw fica no event store em memoria. Persistencia raw dedicada so deve entrar se replay byte-a-byte exigir, com tabela propria e politica de retencao.

Criterio de aceite:

- `zig test src/tool_event.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/tool_loop.zig -lc` passa.
- `zig test src/audit.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.

Pendencias deliberadas:

- `ModelTurnContext` ainda nao existe.
- Loop real streaming ainda nao consome ToolEvent.
- Audit ainda nao grava tools anunciadas/rejeitadas/aceitas por turno em um envelope unico.
- Persistencia raw byte-a-byte em SQLite ainda nao existe; por ora ha raw no event store em memoria e resumo auditavel no SQLite.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_event.zig -lc` -> passou; 12 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 23 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_loop.zig -lc` -> passou; 31 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/audit.zig -lc -lsqlite3` -> passou; 16 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

## T259 - Criar `ModelTurnContext` minimo e renderer anti-raw

Status: implemented-verified.

Motivacao: T258 separou raw interno de evidencia destilada, mas ainda faltava a funcao que define exatamente o que sera enviado ao modelo. As tasks T075, T077 e T205 indicam que o system prompt deve ficar compacto e o contexto variavel deve ser um bloco unico, sem MEMORY/SKILLS falsos, sem blocos vazios e sem raw output.

Evidencia:

- `TASKS.md` T075 pede renderer de `[TURN_CONTEXT v1]`, `[CONTRACTS]`, `[SKILLS]`, `[MEMORY]`, `[EVIDENCE]`, `[OBLIGATIONS]` e `[NEXT_ACTION]`.
- `TASKS.md` T077 pede testes anti-vazamento para `---BEGIN CONTENT---`, `[READ_FILE]`, `rawOutput` e `rg --json`.
- `TASKS.md` T205 pede system prompt compacto e `ModelTurnContext` por perfil.
- `phenom-zig/src/collect_evidence.zig` ja produz EvidencePacket/MicroContext budgetados, mas ainda nao havia renderer oficial do contexto variavel.

Impacto esperado:

- Existe um renderer unico para o contexto variavel do modelo.
- `[MEMORY]` e `[SKILLS]` so aparecem quando explicitamente fornecidos.
- `[EVIDENCE]` so aparece quando ha evidencias.
- Raw markers falham como `RawContextLeak`.
- System prompt inicial fica curto e estavel, separado do contexto variavel.
- A proxima integracao de inferencia pode usar esse renderer sem inventar formato novo.

Teste primeiro:

- System prompt fica menor que 240 chars e contem regra contra MEMORY/SKILLS inventados.
- Contexto sem memory/skills/evidence nao renderiza blocos vazios.
- Contexto com evidence/obligations/next action renderiza formato fixo.
- Contexto com memory/skills so renderiza quando os arrays sao fornecidos.
- Renderer rejeita raw markers.
- Saida real de `collect_evidence` entra no `ModelTurnContext` sem vazar `SECRET_RAW_TAIL`.

Implementacao:

- `phenom-zig/src/model_context.zig`: criar `system_prompt_v1`, `EvidenceBlock`, `ModelTurnContext`, `renderSystemPrompt`, `renderModelTurnContext` e `assertNoRawContextLeak`.
- `phenom-zig/src/main.zig`: incluir `model_context.zig` na suite principal.

Passos de implementacao:

1. Definir struct borrowed de `ModelTurnContext` sem ownership complexo.
2. Criar renderer append-only em `ArrayList`.
3. Renderizar blocos somente quando presentes.
4. Normalizar evidence removendo cabecalho `[EVIDENCE]` interno duplicado.
5. Implementar `assertNoRawContextLeak`.
6. Criar testes isolados e teste com `collect_evidence`.
7. Rodar testes focados, build completo e release.
8. Revisar bounds/alloc/raw leak antes do commit.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: renderer retorna slice owned; caller libera; structs usam slices borrowed e nao precisam `deinit`.
- Allocations temporarias de labels `E{}`/`O{}` usam `defer`.
- Bounds: render usa `appendSlice`/`allocPrint`; sem escrita em buffer fixo.
- Anti-vazamento: `assertNoRawContextLeak` roda sobre o output final antes de retornar.
- Escopo: ainda nao integra no HTTP/model call; evita alterar comportamento real antes de T076 equivalente no Zig.
- Server/modelo: nao ha chamada ao backend nesta task; smoke real nao e pertinente.

Criterio de aceite:

- `zig test src/model_context.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.

Pendencias deliberadas:

- Carregamento real de MEMORY/SKILLS de arquivos persistentes ainda nao existe.
- Integracao do `ModelTurnContext` na chamada HTTP/modelo ainda nao existe.
- Selecao/ranking de multiplas evidencias por budget ainda nao existe.
- Perfis `news_operational` e `mass_read` ainda nao renderizam formatos proprios.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/model_context.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 23 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

## T260 - Carregar MEMORY/SKILLS somente de fontes persistentes

Status: implemented-verified.

Motivacao: depois do `ModelTurnContext`, faltava provar a regra de que MEMORY/SKILLS nao sao storage operacional nem tool output. As tasks T074, T162 e T206 exigem carregar somente arquivos persistentes textuais visiveis, sem inventar blocos e sem transformar audit/sqlite/cache em memoria conversacional.

Evidencia:

- `TASKS.md` define MEMORY/SKILLS como unicas fontes persistentes textuais visiveis ao modelo.
- `TASKS.md` T074 pede fallback `MEMORY.md -> .MEMORY.md` e `SKILLS.md -> .SKILL.md`.
- `TASKS.md` T162 pede prova de que storage operacional nao compete com MEMORY/SKILLS.
- `phenom-zig/src/model_context.zig` ja renderizava memory/skills quando arrays eram fornecidos, mas nao havia loader real.

Impacto esperado:

- `MEMORY.md` e `.MEMORY.md` viram as unicas fontes de `[MEMORY]`.
- `SKILLS.md` e `.SKILL.md` viram as unicas fontes de `[SKILLS]`.
- Nomes sem ponto têm prioridade sobre fallback com ponto.
- Arquivo ausente gera array vazio e nao cria heading vazio.
- Arquivo com marcador de raw/tool output e rejeitado para evitar contaminacao persistente.
- Loader recebe `std.Io`, entao nao depende de test IO em release.

Teste primeiro:

- Sem arquivos: memory e skills vazios, sem paths.
- `MEMORY.md` e `.MEMORY.md`: prefere `MEMORY.md`.
- Apenas `.MEMORY.md`/`.SKILL.md`: fallback carrega.
- Arquivo com `---BEGIN CONTENT---` nao produz entradas.
- Saida carregada passa pelo `ModelTurnContext`; `[MEMORY]` ausente nao aparece e `[SKILLS]` presente aparece.

Implementacao:

- `phenom-zig/src/persistent_context.zig`: criar `Loaded`, `loadFromCwd`, `loadFromDir`, parser de entradas e filtro anti-raw.
- `phenom-zig/src/main.zig`: incluir `persistent_context.zig` na suite principal.

Passos de implementacao:

1. Definir `Loaded` owned com listas de memory/skills e paths opcionais.
2. Implementar leitura por prioridade de nomes.
3. Limitar arquivo a 32 KiB.
4. Parsear linhas/headings/bullets compactos.
5. Limitar entradas e tamanho por entrada.
6. Rejeitar arquivos com marcadores raw/tool output.
7. Testar integracao com `ModelTurnContext`.
8. Rodar testes focados, build completo e release.
9. Revisar ownership, release build e anti-vazamento antes do commit.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `Loaded.deinit` libera cada entrada e path opcional.
- Ownership: `loadFirst` retorna content/path owned; `Loaded` duplica path antes de liberar arquivo temporario.
- Bounds: `readFileAlloc` usa `.limited(32 * 1024)`; entradas usam `max_entries=24` e `max_entry_bytes=240`.
- Anti-vazamento: se o arquivo contem `---BEGIN CONTENT---`, `[READ_FILE]`, `[TOOL_EVENT]`, `rawOutput`, `raw_output` ou `rg --json`, o arquivo e rejeitado.
- Release: loader recebe `std.Io`; nao usa `std.testing.io` fora dos testes.
- Escopo: loader nao promove nada automaticamente para MEMORY/SKILLS.

Criterio de aceite:

- `zig test src/persistent_context.zig -lc` passa.
- `zig test src/model_context.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.

Pendencias deliberadas:

- Integrar loader ao fluxo real de inferencia ainda nao foi feito.
- Promocao explicita para MEMORY/SKILLS ainda nao existe.
- Audit ainda nao registra quais entradas persistentes foram usadas no turno.
- Storage operacional SQLite/news/cache continua separado e ainda nao tem teste dedicado de nao competicao.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/persistent_context.zig -lc` -> passou; 34 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/model_context.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

## T261 - Integrar `ModelTurnContext` no HTTP com rollout controlado

Status: implemented-verified.

Motivacao: T259 e T260 criaram renderer e loader persistente, mas nada ainda chegava ao backend. A task T076 pede integrar contexto variavel apos system prompt, com system prompt estavel e rollout por flag. O cuidado principal: nao anunciar contratos/tools antes do tool loop real estar pronto, porque isso induz o modelo a emitir tools que o runtime ainda nao executa em streaming.

Evidencia:

- `phenom-zig/src/http.zig` so aceitava `prompt` simples em `streamChat`.
- `phenom-zig/src/main.zig` chamava `client.streamChat(prompt, &sink)`, sem caminho para contexto variavel.
- `TASKS.md` T076 pede `PHENOM_MODEL_CONTEXT_V1=1` no primeiro rollout.
- Smoke real inicial com contexto contendo `model_visible_tools` fez o modelo tentar `collect_evidence` antes do loop real, provando que contratos nao podem entrar agora.

Impacto esperado:

- Sem `PHENOM_MODEL_CONTEXT_V1=1`, payload e comportamento continuam no caminho antigo.
- Com `PHENOM_MODEL_CONTEXT_V1=1`, contexto so e injetado quando ha MEMORY/SKILLS persistentes carregados.
- Contratos/tools nao sao anunciados no contexto real ate o tool loop streaming existir.
- Ollama recebe contexto como mensagem `user` separada antes do pedido atual.
- llama.cpp recebe contexto como bloco `<|im_start|>user` separado antes do pedido atual.
- Audit registra `model_context` somente quando contexto realmente foi injetado.

Teste primeiro:

- `http` prova payload llama.cpp antigo sem contexto.
- `http` prova payload Ollama com contexto como mensagem separada.
- `http` prova payload llama.cpp com contexto antes do user request.
- `main` prova parser da env opt-in.
- Smoke real sem flag passa.
- Smoke real com flag e sem MEMORY/SKILLS passa e nao grava novo `model_context`.

Implementacao:

- `phenom-zig/src/http.zig`: adicionar `InferenceInput`, `streamInference` e `buildBodyForInput`.
- `phenom-zig/src/main.zig`: passar `std.Io` ate o turno, criar `buildOptionalModelContext`, checar `PHENOM_MODEL_CONTEXT_V1`.
- `main.zig`: trocar chamada para `streamInference`.
- `main.zig`: carregar MEMORY/SKILLS persistentes apenas quando flag estiver ativa e so renderizar contexto se houver entradas persistentes.

Passos de implementacao:

1. Manter `streamChat(prompt)` como wrapper compatível.
2. Criar payload HTTP com contexto opcional.
3. Inserir contexto separado antes do user request.
4. Criar helper opt-in por env.
5. Carregar persistent context no turno.
6. Evitar tool/contracts surface antes do loop real.
7. Registrar `model_context` no audit somente quando usado.
8. Rodar testes unitarios, build, release e smoke real.
9. Revisar regressao real quando o modelo tentou tool antes do loop.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `model_context_text` e owned e liberado com `defer`; `persistent.deinit` libera entradas apos render copiar o texto.
- Payload: `jsonEscape` roda em prompt e contexto; strings escapadas sao liberadas.
- Compatibilidade: `streamChat` continua existindo e chama `streamInference` sem contexto.
- Rollout: env aceita somente `1`, `true` ou `on`; default e off.
- Regra de negocio: contratos/tools nao entram no contexto real ainda, porque o loop real nao esta pronto.
- Audit: nao grava contexto quando nao ha MEMORY/SKILLS; evita ruido e prova que storage operacional nao virou memoria.

Criterio de aceite:

- `zig test src/http.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` passa.
- `PHENOM_MODEL_CONTEXT_V1=1 ./zig-out/bin/phenom chat ... PHENOM_CTX_261 ...` passa.

Pendencias deliberadas:

- Contexto de contratos/tools so deve voltar quando o tool loop real streaming estiver implementado.
- Ainda falta integrar evidence de tool call real ao segundo turno do modelo.
- Ainda falta registrar no audit quais MEMORY/SKILLS foram usados quando existirem.
- Ainda falta teste real com MEMORY/SKILLS presentes e prompt de codigo, depois do comportamento de tool loop estar seguro.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/http.zig -lc` -> passou; 19 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou; resposta visivel continha `PHENOM_REAL_7319`.
- `PHENOM_MODEL_CONTEXT_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 96 --prompt 'Complete: PHENOM_CTX_261' --expect-contains PHENOM_CTX_261 --show-expect-status --fail-on-model-error` -> passou com permissao escalada; resposta visivel continha `PHENOM_CTX_261`.
- `sqlite3 .phenom-zig/phenom.db "select kind ..."` -> confirmou que o ultimo smoke com flag nao gravou `model_context` quando nao havia MEMORY/SKILLS no cwd.

## T262 - Integrar primeiro tool loop real de uma iteracao

Status: implemented-verified-partial.

Motivacao: depois de MicroContext, `collect_evidence`, `ToolEvent`, `ModelTurnContext` e persistent context, o proximo risco real era ligar modelo -> tool -> evidence -> modelo. A task T222 ja marcava esse ponto como alta complexidade porque o agente precisa interpretar output do modelo, executar tool, montar contexto destilado e chamar o modelo novamente sem duplicar contexto.

Evidencia:

- `phenom-zig/src/main.zig` fazia apenas uma chamada `client.streamInference`.
- `phenom-zig/src/tool_loop.zig` executava `collect_evidence` apenas offline.
- `TASKS.md` T222: "tool loop real com modelo em streaming" ainda faltava.
- `TASKS.md` T261 mostrou que anunciar tools cedo faz o modelo tentar ferramenta antes do runtime estar pronto.

Impacto esperado:

- `PHENOM_TOOL_LOOP_V1=1` ativa o primeiro loop real.
- O runtime analisa a resposta visivel do primeiro turno.
- Se houver tool call valida `collect_evidence`, valida gate, executa tool, audita `tool_event`, emite evidence e chama o modelo uma segunda vez com `ModelTurnContext` contendo EvidencePacket.
- Se a tool nao foi anunciada, e rejeitada sem execucao.
- Se nao houver tool call, comportamento permanece igual.
- Limite inicial: uma tool call e uma segunda inferencia.

Teste primeiro:

- Parser/gate/tool loop offline ja provam `collect_evidence` anunciado.
- `main` prova flag opt-in `PHENOM_TOOL_LOOP_V1`.
- Build completo prova integracao.
- Smoke real com flag ativa e sem tool call prova nao regressao e ausencia de execucao indevida.

Implementacao:

- `phenom-zig/src/main.zig`: adicionar `runToolLoopFollowup`.
- `main.zig`: adicionar `toolLoopEnabled`/`toolLoopValueEnabled`.
- `main.zig`: apos primeira inferencia e `sink.flush`, tentar parsear `tool_call.parseFirst`.
- `main.zig`: permitir apenas `collect_evidence`.
- `main.zig`: executar `collect_evidence`, registrar `tool_start`, `tool_event`, `evidence`, emitir eventos visuais e fazer segunda chamada `streamInference`.

Passos de implementacao:

1. Criar flag opt-in.
2. Detectar tool call apos primeira resposta.
3. Diferenciar parse error/rejected/missing path de falha de infraestrutura.
4. Executar `collect_evidence`.
5. Montar follow-up `ModelTurnContext` com evidence.
6. Fazer segunda inferencia com o prompt original e contexto destilado.
7. Agregar visivel do follow-up para expectativas/testes.
8. Rodar build, release e smoke real idle.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `call.deinit`, `result.deinit`, `follow_context` e `follow_sink.deinit` liberam ownership.
- Bounds: `collect_evidence` usa budget fixo inicial de 3800 bytes.
- Gate: somente `collect_evidence` passa; qualquer outra tool e auditada como rejeitada.
- Erros: parse/model tool error viram audit/progress; HTTP follow-up respeita `--fail-on-model-error`.
- Anti-vazamento: segunda inferencia recebe `ModelTurnContext` com EvidencePacket, nao raw tool output.
- Rollout: comportamento so ativa com `PHENOM_TOOL_LOOP_V1=1`.

Criterio de aceite:

- `zig build test` passa.
- `zig test src/tool_loop.zig -lc` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real com `PHENOM_TOOL_LOOP_V1=1` e prompt simples passa sem executar tool indevida.
- Audit do smoke idle nao contem `tool_start`/`tool_event`.

Pendencias deliberadas:

- Ainda nao ha captura streaming que suprime o texto da tool call antes de renderizar no transcript; primeira versao detecta apos a resposta visivel.
- Ainda falta smoke deterministico em que o modelo emite tool call valida no formato suportado.
- Ainda falta repair prompt quando o modelo pede `collect_evidence` sem path.
- Ainda falta mais de uma iteracao de tool loop.
- Ainda falta schema model-visible claro para forcar formato de tool call sem inchar prompt.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_loop.zig -lc` -> passou; 31 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 96 --prompt 'Complete: PHENOM_LOOP_IDLE_262' --expect-contains PHENOM_LOOP_IDLE_262 --show-expect-status --fail-on-model-error` -> passou com permissao escalada; resposta visivel continha `PHENOM_LOOP_IDLE_262`.
- `sqlite3 .phenom-zig/phenom.db "select kind ..."` -> confirmou que o ultimo smoke idle nao registrou `tool_start` nem `tool_event`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` dentro do sandbox -> falhou com `SocketCreateFailed`, mostrando que o teste nao chegou ao servidor nesse perfil de permissao.
- O mesmo `real-smoke` com permissao de rede liberada -> passou e imprimiu:

```text
> user
Complete: PHENOM_REAL_7319

assistant
PHENOM_REAL_7319

done
```

O que ainda falta fora desta task:

- Harness real com relatorio estruturado de host/model/backend/tokens/latencia.
- Erros tipados mais ricos no cliente HTTP, incluindo errno/status code no audit.
- Comando `probe` separado para diagnosticar DNS/socket/connect/HTTP sem chamar modelo.
- Teste real para Ollama `/api/chat`.
- Tool loop real modelo -> tool -> modelo.
- Replay completo do turno real.

## T224 - Encerrar streaming real ao receber fim logico do backend

Status: implemented-verified-real-backend.

Cumprimento: 100% para o objetivo pequeno desta task. Ela corrige o caso em que o modelo ja gerou resposta visivel, mas o CLI nao chega a imprimir `done` porque o client HTTP espera o fechamento fisico do socket. Esta task nao implementa timeouts, retry, probe nem diagnostico completo de rede.

Evidencia:

- O usuario executou `zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest`.
- A GPU reagiu e o terminal mostrou:

```text
> user
Complete: PHENOM_REAL_7319

assistant
PHENOM_REAL_7319
```

- A ausencia de `done` indica que a resposta visivel chegou, mas o loop de leitura nao finalizou o turno.
- Em streaming local, llama.cpp pode sinalizar fim por JSON com `"stop":true`; Ollama sinaliza por `"done":true`; SSE tambem pode enviar `data: [DONE]`. O client anterior processava `content`/`response`, mas nao encerrava o loop nesses marcadores.

Impacto:

- O renderer append-only volta a ter fechamento previsivel do turno.
- `real-smoke` deixa de depender do fechamento do socket para finalizar.
- A falha observada passa a ser coberta por teste offline e por smoke real.

Teste primeiro:

- Adicionar teste offline em `http.zig` onde uma linha llama.cpp `data: {"content":"PHENOM_REAL_7319","stop":true}` deve entregar o delta e retornar fim de stream.
- Adicionar teste offline em `http.zig` onde uma linha Ollama `{"done":true}` deve finalizar sem delta visivel.
- Manter teste existente de delta normal sem fim de stream.

Implementacao:

- `phenom-zig/src/http.zig`: fazer `processModelLine`, `feedLines`, `feedChunked` e `flushLine` retornarem `bool` indicando fim logico do stream.
- Tratar `data: [DONE]`, `"stop":true`, `"done":true` e chunk HTTP tamanho zero como fim.
- Em `streamChat`, quebrar o loop de leitura quando `feedLines`/`feedChunked` retorna fim.

Passos de implementacao:

1. Confirmar que o renderer `done()` ja imprime `done` quando `streamChat` retorna.
2. Corrigir o parser para propagar fim logico do stream.
3. Garantir que o delta de conteudo da mesma linha ainda seja entregue antes de finalizar.
4. Rodar suite offline.
5. Rodar build release.
6. Rodar `real-smoke` contra llama.cpp ativo.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `real-smoke` contra llama.cpp imprime token esperado e `done`.
- A task nao reivindica diagnostico completo de rede nem timeout; isso continua pendente.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` com rede liberada -> passou e imprimiu:

```text
> user
Complete: PHENOM_REAL_7319

assistant
PHENOM_REAL_7319

done
```

O que ainda falta fora desta task:

- Timeout de leitura para stream que nunca envia marcador de fim.
- Erro tipado diferenciando socket aberto sem fim, backend lento e stream malformado.
- Teste real para Ollama `/api/chat`.
- Comando `probe` separado para diagnostico de transporte sem inferencia.

## T225 - Mostrar success/fail explicito no `real-smoke`

Status: implemented-verified-real-backend.

Cumprimento: 100% para o objetivo pequeno desta task. O `real-smoke` agora mostra status humano explicito quando a expectativa visivel passa ou falha. Esta task nao muda chat normal, protocolo de modelo nem criterio de inferencia; apenas torna o resultado do smoke legivel no terminal.

Evidencia:

- O usuario perguntou por que o teste mostrava `PHENOM_REAL_7319` mas nao mostrava `success` ou `fail`.
- Antes, `--expect-contains` registrava sucesso no audit, mas nao imprimia status no terminal.
- Depois da primeira alteracao, o status apareceu colado ao token (`PHENOM_REAL_7319status...`), provando que o renderer precisava separar `status` do bloco `assistant`.

Impacto:

- O operador ve resultado do smoke sem depender apenas do exit code.
- Chat normal nao recebe status de teste porque a impressao explicita depende de `--show-expect-status`.
- O renderer passa a separar `assistant`, `status` e `done` em blocos copiaveis.

Teste primeiro:

- Adicionar teste offline de parse para `--show-expect-status`.
- Adicionar snapshot offline do renderer onde `status` apos delta do assistant inicia em bloco separado.

Implementacao:

- `phenom-zig/src/cli.zig`: adicionar flag `--show-expect-status`.
- `phenom-zig/src/main.zig`: quando `--expect-contains` passa e `--show-expect-status` esta ativo, imprimir `status success expected visible text found: ...`; quando falha, imprimir `status fail expected visible text missing: ...`.
- `phenom-zig/build.zig`: fazer `real-smoke` passar `--show-expect-status` por padrao.
- `phenom-zig/src/render.zig`: separar `status` de `assistant` com newline/bloco proprio e evitar linha em branco extra antes de `done`.

Passos de implementacao:

1. Adicionar flag sem alterar chat normal.
2. Mostrar status somente quando a flag estiver ativa.
3. Corrigir renderer para nao colar status ao ultimo delta.
4. Cobrir com teste offline.
5. Reexecutar suite offline, build release e smoke real.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `real-smoke` imprime token esperado, status `success` e `done`.
- Se a expectativa falhar, o terminal deve mostrar `status fail ...` antes do erro/exit code.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou e imprimiu:

```text
> user
Complete: PHENOM_REAL_7319

assistant
PHENOM_REAL_7319

status success expected visible text found: PHENOM_REAL_7319

done
```

O que ainda falta fora desta task:

- Status visual final mais sofisticado estilo Codex/phenom-cli-ts.
- Separar claramente smoke test de chat comum na UX.
- Harness real estruturado com resumo de backend/model/latencia/tokens.

## T226 - Criar comando `probe` para diagnosticar backend sem inferencia

Status: implemented-verified-real-backend.

Cumprimento: 100% para o objetivo pequeno desta task. O comando `probe` separa transporte/HTTP de inferencia do modelo. Esta task nao implementa timeout, retry, DNS detalhado por endereco, nem relatorio completo de latencia/tokens.

Evidencia:

- T223, T224 e T225 mostraram que `real-smoke` agora prova inferencia visivel, mas ainda era usado para descobrir problemas de socket/rede.
- O mesmo ambiente podia mostrar `SocketCreateFailed` no binario Zig e sucesso quando a rede era liberada. Sem probe, essa diferenca ficava misturada com teste de modelo.
- A proxima etapa de tool loop real precisa de uma fronteira clara entre falha de infraestrutura e falha/capacidade do modelo.

Impacto:

- `real-smoke` fica reservado para provar inferencia.
- `probe` prova parse de host, tentativa TCP e status HTTP sem gerar texto.
- Falhas de socket/HTTP podem ser reproduzidas sem gastar GPU nem contexto do modelo.

Teste primeiro:

- Adicionar teste offline de parse para `phenom probe --backend llamacpp --host HOST:PORT`.
- Adicionar teste offline de path de probe por backend: llama.cpp usa `/`, Ollama usa `/api/tags`.
- Adicionar teste offline de parse de status HTTP e header `Server`.

Implementacao:

- `phenom-zig/src/cli.zig`: adicionar comando `probe`.
- `phenom-zig/src/http.zig`: adicionar `probeBackend`, `ProbeResult`, path sem inferencia por backend, parser de status e parser de header.
- `phenom-zig/src/main.zig`: adicionar `runProbe` com output append-only simples.
- `phenom-zig/README.md`: documentar comandos de probe e deixar claro que probe nao usa endpoint de inferencia.

Passos de implementacao:

1. Reusar o parser de `--backend` e `--host` existente.
2. Criar path de probe que nao gera texto.
3. Abrir socket usando o mesmo transporte do chat.
4. Enviar request HTTP leve.
5. Ler somente headers suficientes para status/server.
6. Imprimir resultado em blocos lineares: `probe`, `backend`, `endpoint`, `tcp`, `http`, `server`, `result`.
7. Sair com exit code 1 em falha, sem stack/error prefix no terminal.
8. Validar falha em sandbox e sucesso com rede liberada.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Probe em ambiente sem socket liberado imprime `tcp fail ... result fail` e exit code 1.
- Probe com rede liberada contra llama.cpp imprime `tcp success`, `http success status=200`, `server llama.cpp`, `result success`.
- O comando nao chama `/completion` nem `/api/chat`, portanto nao mede inferencia.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom probe --backend llamacpp --host 192.168.1.122:11434` no sandbox -> exit code 1:

```text
probe
backend llamacpp
endpoint http://192.168.1.122:11434/
tcp fail error=SocketCreateFailed
result fail
```

- `./zig-out/bin/phenom probe --backend llamacpp --host 192.168.1.122:11434` com rede liberada -> exit code 0:

```text
probe
backend llamacpp
endpoint http://192.168.1.122:11434/
tcp success
http success status=200
server llama.cpp
result success
```

O que ainda falta fora desta task:

- Timeout de socket/leitura.
- Erro tipado com errno/address tentado.
- Probe para varios enderecos retornados por DNS.
- Probe real para Ollama `/api/tags`.
- Harness real estruturado com latencia, modelo, tokens e backend.

## T227 - Corrigir hardening de `read_file_range`, ownership de tool call e allocators

Status: implemented-verified-offline.

Cumprimento: 100% para o objetivo pequeno desta task. Corrige os bugs reportados em `tools.zig`, `tool_call.zig` e o uso de allocator no flush HTTP. Nao corrige `parseHost` com validacao forte nem restricao de familia DNS, por decisao explicita do usuario (#8 e #9 ficam fora desta etapa).

Evidencia:

- `tools.zig` rejeitava qualquer path contendo `..`, bloqueando falsos positivos como `foo..txt`.
- `tools.zig` usava `mode.ptr` de slice para `fopen`; isso dependia de detalhe da string literal.
- `tools.zig` devolvia `FileRange.path` emprestado e liberava apenas `text`.
- O hash era calculado sobre o buffer limitado por `max_bytes`, entao o mesmo arquivo podia gerar hashes diferentes conforme a janela visivel.
- `tool_call.zig` devolvia `ToolCall.name` e `ToolCall.path` como slices do output original.
- `http.zig` usava `std.heap.page_allocator` no flush final de linha.
- `start_line=0` era aceito por acidente embora a API seja 1-based.

Impacto:

- Paths com `..` dentro de nome de arquivo deixam de ser falsamente classificados como traversal.
- Traversal por componente (`../x`, `foo/../../bar`) continua bloqueado.
- Leitura de arquivos sensiveis/ocultos do cwd fica bloqueada para o modelo (`.env`, `.git/*`, `credentials.json`, `secret`, `token`, chaves privadas comuns).
- Symlinks que escapam do cwd sao bloqueados por `realpath`.
- `FileRange` e `ToolCall` passam a ter ownership explicito.
- Hash de stale context fica estavel entre janelas visiveis diferentes, usando uma janela fixa inicial de 64 KiB.

Teste primeiro:

- Teste de traversal por componente.
- Teste de falso positivo `foo..txt` e `valid..path`.
- Teste de paths ocultos/sensiveis.
- Teste de `start_line=0`.
- Teste de ownership de `FileRange.path`.
- Teste de hash estavel com `max_bytes` diferente.
- Teste de ownership de `ToolCall.name` e `ToolCall.path`.

Implementacao:

- `phenom-zig/src/tools.zig`: adicionar `validateModelPath`, `realPathInsideCwd`, denylist simples de paths sensiveis, `start_line` 1-based, `FileRange.path` owned, hash fixo de 64 KiB e `fopen` com `[*:0]const u8`.
- `phenom-zig/src/tool_call.zig`: trocar parser para `parseFirst(allocator, output) !?ToolCall` e adicionar `ToolCall.deinit`.
- `phenom-zig/src/tool_loop.zig`: adaptar para parser owned e `defer call.deinit`.
- `phenom-zig/src/http.zig`: passar allocator para `flushLine` e tornar `ParsedHost.host` owned com `deinit`, sem alterar politica de validacao de host.

Passos de implementacao:

1. Corrigir validação lexical de path por componente, nao por substring.
2. Adicionar denylist pragmatica para arquivos ocultos e nomes sensiveis.
3. Resolver realpath e garantir que o alvo fica dentro do cwd.
4. Estabilizar hash em janela fixa independente do `max_bytes` visivel.
5. Tornar ownership de retornos explicito.
6. Atualizar callers.
7. Rodar testes offline e release build.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Testes provam que `foo..txt` nao vira traversal, mas `foo/../../bar` vira.
- Testes provam que `.env` e `config/credentials.json` sao bloqueados.
- Testes provam que `FileRange.path` e `ToolCall` nao dependem do buffer original.
- Testes provam hash estavel entre janelas de leitura.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lsqlite3 -lc` -> 36/36 testes passaram.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

O que ainda falta fora desta task:

- Validacao forte de `parseHost` (#8) quando a politica de rede do produto for definida.
- Restricao de familia/endereco em `getaddrinfo` (#9) quando a politica de rede do produto for definida.
- Sandbox configuravel por diretorio raiz em vez de cwd fixo.
- Hash full-file streaming quando stale check exigir garantia alem dos primeiros 64 KiB.
- Audit/replay registrando rejeicoes de path sensivel com erro tipado.

## T228 - Concluir ownership de `EvidenceEntry`

Status: implemented-verified-offline.

Cumprimento: 100% para o objetivo pequeno desta task. A mudanca pendente em `evidence.zig` corrigia a direcao principal, mas faltava fechar cleanup em falha parcial de alocacao e provar ownership por teste.

Evidencia:

- `EvidenceEntry.deinit` original liberava apenas `range` e `excerpt`, mas `source` e `kind` podiam ser owned.
- `fromFileRange` original devolvia `source = range.path` e `kind = "file_range"` emprestados.
- A mudanca pendente ja duplicava `source`, `kind` e `excerpt`, mas fazia alocacoes diretamente no return literal. Se uma alocacao posterior falhasse, alocacoes anteriores poderiam vazar.
- `EvidencePacket.add` assumia ownership na pratica, mas se `append` falhasse o entry passado nao era limpo.

Impacto:

- `EvidenceEntry` agora tem ownership uniforme de `source`, `kind`, `range` e `excerpt`.
- `fromFileRange` limpa alocacoes parciais com `errdefer`.
- `EvidencePacket.add` limpa o entry se a transferencia de ownership falhar no append.
- Evidence gerada a partir de `FileRange` continua valida mesmo se o range original for mutado/liberado depois.

Teste primeiro:

- Adicionar teste que cria `FileRange` com buffers mutaveis, chama `fromFileRange`, muta os buffers originais e verifica que `EvidenceEntry` preserva `source`, `kind`, `range` e `excerpt`.

Implementacao:

- `phenom-zig/src/evidence.zig`: completar `fromFileRange` com variaveis locais owned e `errdefer`.
- `phenom-zig/src/evidence.zig`: adicionar `errdefer entry.deinit` em `EvidencePacket.add`.
- `phenom-zig/src/evidence.zig`: manter teste existente ajustado para campos owned e adicionar teste de ownership.

Passos de implementacao:

1. Confirmar se a mudanca pendente resolvia ownership funcional.
2. Identificar vazamento em alocacao parcial.
3. Adicionar cleanup com `errdefer`.
4. Cobrir ownership com teste offline.
5. Rodar suite offline e release build.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Teste prova que `EvidenceEntry` nao depende do buffer original de `FileRange`.
- `fromFileRange` nao deixa alocacoes anteriores sem cleanup quando uma etapa posterior falha.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

O que ainda falta fora desta task:

- Teste com allocator falhante para provar cleanup em cada ponto de falha de forma granular.
- Audit/replay completo para ownership de evidence persistida em SQLite.

## T229 - Portar superficie visual do CLI `phenom-cli-ts` para o renderer Zig

Status: implemented-verified-offline.

Cumprimento: parcial deliberado para o pedido amplo de CLI final. Esta task porta a superficie visivel append-only ja suportada pela base Zig: user query, assistant stream, thinking em baixo destaque, sample de tool, diff preview, status textual, `[done]`, prompt row e status row. Nao implementa ainda o event loop interativo raw-mode completo do `phenom-cli-ts`, nem visualizer animado, resize/reflow, scroll region DECSTBM, historico de input, bracketed paste ou markdown renderer completo.

Evidencia:

- `../phenom-cli-ts/src/cli-renderer.ts:753-768` define `formatUserMessageBubble`/`formatUserMessageBlock` com `USER_BG = \x1b[48;5;236m`, `USER_FG = \x1b[38;5;252m`, gutter de conteudo e bloco com separadores.
- `../phenom-cli-ts/src/cli-renderer.ts:1038-1041` define thinking como `│ thinking` e linhas com `│ ` em tom baixo.
- `../phenom-cli-ts/src/cli-renderer.ts:1320-1392` mostra tool start/result como anuncio numerado e amostra de output com gutter `    │`.
- `../phenom-cli-ts/src/cli-renderer.ts:1588-1652` finaliza inferencia com `[done]` discreto.
- `../phenom-cli-ts/src/cli-renderer.ts:2488-2575` define status row ativa como `Thinking (elapsed · esc to interrupt)` com visualizer opcional.
- `../phenom-cli-ts/src/cli-renderer.ts:2880-3310` define prompt/statusbar com prefixo `> `, background `USER_BG/USER_FG`, largura `cols - 1` e sem pintar a ultima coluna.
- `phenom-zig/src/render.zig` anterior ainda tinha labels antigos (`> user`, `assistant`, `done`) no baseline commit e depois snapshots pendentes que nao passavam.

Impacto:

- O transcript do produto deixa de parecer debug output e passa a seguir a linguagem visual do `phenom-cli-ts`.
- O user prompt e o prompt row usam a mesma paleta ANSI fixa do TS.
- Assistant/status/done/tool/diff recebem gutter de conteudo de uma coluna, preservando copia em terminal/tmux.
- Thinking fica separado e de baixo destaque, sem vazar colado ao output final.
- A implementacao continua append-only e testavel por snapshots; nao introduz alternate screen nem cursor control nesta etapa.

Teste primeiro:

- Snapshot de thinking com gutter `│ thinking`, conteudo em baixo destaque e separacao do output final.
- Snapshot end-to-end append-only: user bubble, assistant delta e `[done]`.
- Snapshot de status apos assistant delta para provar que status nao cola no texto do modelo.
- Snapshot de tool sample com anuncio numerado e output truncado.
- Snapshot de diff preview com markers suaves e truncamento.
- Snapshot ANSI da paleta do user bubble igual ao `phenom-cli-ts`.
- Snapshot ANSI do prompt row com `> ` e mesma paleta.
- Snapshot plain do status row com shape ativo do `phenom-cli-ts`.

Implementacao:

- `phenom-zig/src/render.zig`: substituir labels antigos por blocos append-only com gutter e separadores.
- `phenom-zig/src/render.zig`: implementar wrap hard do user bubble por largura, preservando quebras de linha.
- `phenom-zig/src/render.zig`: adicionar `promptRow` e `statusRow` puros para contrato visual da statusbar/prompt.
- `phenom-zig/src/render.zig`: manter color=false removendo ANSI, para snapshots deterministas.
- `phenom-zig/src/render.zig`: manter ANSI color=true com as constantes exatas do TS para user/prompt.

Passos de implementacao:

1. Comparar `phenom-zig/src/render.zig` com `../phenom-cli-ts/src/cli-renderer.ts`.
2. Identificar elementos visuais ja suportados pela base Zig e os que exigem engine interativa.
3. Corrigir user bubble para usar gutter, palette e wrap do TS.
4. Corrigir assistant stream para prefixar gutter por linha.
5. Corrigir thinking/tool/status/done/diff para blocos separados e copiaveis.
6. Adicionar contrato puro de prompt row/status row.
7. Adicionar snapshots pequenos cobrindo cada elemento.
8. Rodar teste offline, release build e chat offline real do binario.

Revisao baixo nivel antes do commit:

- Ownership/lifetime: renderer nao armazena slices recebidos; escreve tudo sincronicamente no writer.
- `deinit`/allocacao: nao ha novas alocacoes dinamicas no renderer; wrap do user bubble opera por slices e buffers fixos.
- C interop: nenhuma nova chamada C nesta task.
- Bounds/overflow: largura usa saturating subtraction (`-|`) e floors (`@max`) para evitar underflow em terminais estreitos; wrap do user bubble avanca por posicao virtual e evita loop infinito quando label excede largura.
- Escrita parcial: continua usando `writer.writeAll`, herdando retry/append do writer existente.
- ANSI: `color=false` nao escreve escapes; `color=true` usa constantes fixas testadas.
- Erro/comportamento: renderer propaga erro de writer; nao engole falhas de IO.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Chat offline real mostra user bubble, assistant output e `[done]` no formato novo.
- TASKS deixa claro que esta task nao e a CLI/TUI final completa; e a base visual append-only + contratos puros de prompt/status.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou; o modelo respondeu `PHENOM_REAL_7319` e o renderer mostrou status de sucesso + `[done]`.
- `./zig-out/bin/phenom chat --offline --no-color --session renderer-check --prompt "ola"` -> passou e exibiu:

```text

 > [user] ola

 ok

 [done]
```

O que ainda falta fora desta task:

- Engine interativa raw-mode equivalente ao `phenom-cli-ts`: leitura de teclas, cursor, historico, multiline, paste, interrupt e renderizacao incremental do prompt.
- Statusbar animada com `MiniVisualizer`, resize/reflow e isolamento de cursor.
- Scroll region DECSTBM/append-mode completo para impedir overlap entre stream, status e prompt em TTY real.
- Markdown renderer incremental com tabelas/code blocks/highlight equivalente ao TS.
- Diff renderer com line numbers reais, header info (`lines/bytes/op`) e paleta final anti-ofuscamento.
- Eventos de renderer completos (`USER_MESSAGE`, `THINK_START`, `TOOL_START`, `TOOL_RESULT`, `FILE_DIFF`, `THINK_END`) em vez de chamadas diretas parciais.

## T230 - Completar TUI interativa Zig com prompt fixo, statusbar, visualizer e prova real

Status: implemented-verified-real.

Cumprimento: 100% para os elementos de CLI exigidos nesta etapa: `chat` sem `--prompt` agora abre TUI raw-mode, pinta prompt fixo com a mesma paleta do `phenom-cli-ts`, reserva scroll region para output append-only, mostra statusbar com visualizer, preserva cursor, aceita historico, setas, backspace UTF-8, bracketed paste basico, Ctrl-D para sair e Ctrl-C para cancelar. Tambem corrige a validacao anterior: `chat --prompt --offline` nao e mais usado como prova de backend; backend real e provado por `real-smoke` e por teste PTY com permissao de rede.

Evidencia:

- `../phenom-cli-ts/src/cli-renderer.ts:333-760` implementa raw stdin, bracketed paste, historico, setas, Ctrl-C/Ctrl-D e prompt ownership.
- `../phenom-cli-ts/src/cli-renderer.ts:2860-3310` implementa bottom bar com prompt fixo, `USER_BG/USER_FG`, scroll region e cursor parking.
- `../phenom-cli-ts/src/cli-renderer.ts:2488-2575` implementa statusbar com prose de inferencia e visualizer a direita.
- `../phenom-cli-ts/src/visualizer-mini.ts` define modos `idle/listening/thinking/working/responding`.
- `phenom-zig/src/main.zig` antes so executava `chat` com `--prompt`; sem prompt nao havia TUI real equivalente ao fluxo `npm run dev -- chat`.
- A validacao anterior com `--offline` imprimia `ok`, mas isso era resposta fake local, nao inferencia do modelo.

Impacto:

- `./phenom chat` passa a ser usavel como CLI interativa, nao apenas comando one-shot.
- Output do modelo continua append-only e copiavel, enquanto prompt/statusbar ficam reservados no rodape.
- Statusbar sinaliza inferencia com `Thinking (0s · esc to interrupt)` e visualizer em glyphs de bloco.
- Tool output ganhou glyph `▸` no anuncio, alinhando o sample de tools ao visual Codex-like/TS.
- `--prompt` continua sendo caminho deterministico para automacao e testes reais.
- A diferenca entre falha de modelo e falha de infraestrutura fica visivel: teste sem permissao de rede em TTY retornou `SocketCreateFailed`; teste com permissao de rede provou backend.

Teste primeiro:

- Parser: `chat --offline` sem `--prompt` ativa modo interativo.
- Editor: submit preserva UTF-8 em backspace.
- Editor: historico com setas sobe/desce.
- Editor: bytes depois de Enter sao preservados para a proxima leitura (`ola\r\x04`).
- Prompt view: wrap respeita largura e mantem cursor em janela visivel.
- Bottom bar: snapshot com status, prompt e visualizer.
- Visualizer: frames e mapping por label deterministicos.
- Renderer: tool sample mostra glyph `▸`.

Implementacao:

- `phenom-zig/src/tui.zig`: criar `InputEditor`, `TerminalUi`, `renderBottomBar`, `computePromptView`, `visualizerFrame` e helpers de largura UTF-8.
- `phenom-zig/src/cli.zig`: adicionar `prompt_provided` para separar one-shot de interativo.
- `phenom-zig/src/main.zig`: rotear `chat` sem `--prompt` para TUI interativa; extrair `runChatTurnWithUi`; pulsar visualizer durante deltas visiveis/thinking.
- `phenom-zig/src/render.zig`: adicionar glyph `▸` no sample de tools.

Passos de implementacao:

1. Criar editor puro testavel antes de mexer no terminal.
2. Adicionar raw mode com `termios`, bracketed paste e restore garantido em `deinit`.
3. Pintar bottom bar em scroll region DECSTBM sem alternate screen.
4. Reservar linhas de prompt/status para output append-only nao colidir.
5. Integrar TUI somente quando `chat` nao recebe `--prompt`.
6. Manter caminho `--prompt` estavel para automacao.
7. Pulsar visualizer em eventos de streaming sem thread concorrente.
8. Validar offline, release, real-smoke e PTY real.

Revisao baixo nivel antes do commit:

- Ownership/lifetime: `InputEditor.submit` devolve linha owned; callers liberam com `allocator.free`. Historico duplica entradas e libera em `deinit`.
- `deinit`: `TerminalUi.deinit` sempre chama `detach`; `InputEditor.deinit` libera buffer, pending, draft e entradas de historico.
- C interop: `termios` e `tcsetattr` restauram raw mode; `read` trata `0` como EOF e `<0` como erro; `ioctl(TIOCGWINSZ)` tem fallback 80x24.
- Bounds/overflow: prompt wrapping usa floors, saturating subtraction e max rows; pending preserva bytes apos submit sem ler fora do slice.
- UTF-8: backspace/delete andam por boundary de codepoint; statusbar nao corta UTF-8 no meio.
- Terminal: DECSTBM e bracketed paste sao desativados em detach; teste PTY confirmou cleanup.
- Concorrencia: visualizer nao usa timer/thread; avanca apenas em chamadas do loop, evitando interleaving com output do modelo.
- Erro/comportamento: `chat` sem prompt em non-TTY imprime usage e falha como `MissingPrompt`; `--prompt` nao entra na TUI.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `real-smoke` com `--prompt` prova backend real e nao usa `ok` offline.
- PTY offline com `ola\r\x04` executa turno, mostra statusbar/visualizer, imprime output e restaura terminal.
- PTY real com permissao de rede executa turno, backend responde `PHENOM_REAL_7319`, statusbar pulsa e terminal restaura.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou; backend retornou `PHENOM_REAL_7319`.
- PTY offline `./zig-out/bin/phenom chat --offline --no-color`, input `ola\r\x04` -> passou; exibiu statusbar, visualizer, user bubble, `ok`, `[done]` e restaurou terminal.
- PTY real com rede liberada `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 96 --thinking off --expect-contains PHENOM_REAL_7319 --show-expect-status`, input `Complete: PHENOM_REAL_7319\r\x04` -> passou; backend retornou `PHENOM_REAL_7319`, status de sucesso e `[done]`.

Observacao operacional:

- O teste PTY real sem permissao de rede falhou com `SocketCreateFailed`; isso foi classificado como infraestrutura/sandbox e repetido com permissao elevada. O teste elevado passou.

## T231 - Corrigir paridade do fluxo `phenom chat` com `phenom-cli-ts`

Status: implemented-verified-real.

Motivacao: a implementacao T230 criou uma TUI funcional, mas ainda nao copiava a ordem operacional real do `phenom-cli-ts`. O fluxo correto observado em `../phenom-cli-ts/src/index.ts` e: criar `Agent`, criar `CliRenderer`, `renderer.attach()`, inicializar sessao, entrar em pipe mode quando `--prompt`/stdin pipe, chamar `renderer.bindInput`, em `onLine` emitir `USER_MESSAGE`, executar comando slash ou `agent.processInput`, chamar `renderer.renderPrompt`, salvar transcript/historico em `onClose`. A referencia TS usa `.phenom-history`, mas no Zig final isso e uma evidencia de comportamento visual/operacional, nao uma decisao de storage.

Evidencia:

- `../phenom-cli-ts/src/index.ts:50-52`: cria `Agent`, `CliRenderer` e chama `renderer.attach()`.
- `../phenom-cli-ts/src/index.ts:128-161`: pipe mode em `!stdin.isTTY || options.prompt`; emite `USER_MESSAGE`, chama `agent.processInput`, faz cleanup e sai.
- `../phenom-cli-ts/src/index.ts:179-263`: interactive mode carrega `.phenom-history`, define `onLine`, `onClose`, `onFatalError`, chama `renderer.bindInput` e `renderer.renderPrompt`.
- `../phenom-cli-ts/src/cli-renderer.ts:753-768`: user bubble usa `> [${userLabel}]`.
- `../phenom-cli-ts/src/cli-renderer.ts:1320-1355`: tool start renderiza label + detail via `nextToolAnnouncement`, sem numeracao visivel no print real.
- Print real do usuario mostra `[ashirak]`, `│ thinking`, `▸ Running: ...`, output sample com gutter, statusbar com visualizer largo e prompt permanente.

Impacto esperado:

- `phenom-zig chat` deve preservar historico entre execucoes via SQLite operacional, nao `.phenom-history`.
- Ctrl-D e `/exit` devem salvar historico, restaurar terminal e imprimir `Session saved. Use phenom chat to continue.`.
- User bubble deve usar `$USER` como label (`[ashirak]`) em vez de `[user]`.
- Tool announcements devem seguir `▸ Running: comando`, nao `▸ 1. Running`.
- Statusbar deve usar visualizer dinamico no espaco disponivel, nao um frame fixo pequeno.

Implementacao em andamento:

- `phenom-zig/src/main.zig`: adicionar carga/persistencia de historico, `userLabel`, `/exit`, `/reset` e label real no renderer.
- `phenom-zig/src/tui.zig`: adicionar carga de historico no editor e visualizer largo.
- `phenom-zig/src/render.zig`: adicionar `toolSampleWithDetail` e remover numeracao visivel do tool announcement.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Snapshot de tool announcement prova `▸ Running: ls -la ~/.config/nvim`.
- PTY com `/exit` salva/restaura e imprime mensagem de sessao.
- PTY com prompt real mostra label de usuario vindo de `$USER`.
- `real-smoke` continua provando backend real.

Revisao baixo nivel obrigatoria antes do commit:

- Verificar ownership de linhas carregadas/salvas no historico.
- Verificar cleanup de raw mode/DECSTBM em Ctrl-D, `/exit` e erro.
- Verificar que label de usuario e slice de env usado somente durante render sincrono.
- Verificar que visualizer largo nao corta UTF-8 no meio.
- Verificar que `--prompt` nao entra em TUI interativa e nao usa output fake offline como prova de backend.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY `/exit` em `./zig-out/bin/phenom chat --offline --no-color` -> restaurou DECSTBM/bracketed paste e imprimiu `Session saved. Use phenom chat to continue.`
- `./zig-out/bin/phenom chat --offline --no-color --prompt "ola"` -> exibiu `> [ashirak] ola`, provando label por `$USER`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou; backend retornou `PHENOM_REAL_7319`, nao `ok` offline.

## T232 - Migrar historico interativo do arquivo para SQLite

Status: implemented-verified-real.

Motivacao: a T231 portou o comportamento visual do `phenom-cli-ts`, mas tambem trouxe o detalhe errado de storage `.phenom-history`. Para o Phenom Zig, o historico deve usar o SQLite operacional em `.phenom-zig/phenom.db`, porque o projeto ja decidiu reduzir arquivos soltos e separar storage operacional de contexto do modelo. O editor pode manter um cache em memoria para navegacao com setas, mas a fonte persistente nao pode ser arquivo texto paralelo.

Evidencia:

- `phenom-zig/src/audit.zig`: antes desta task so criava tabela `events`; nao havia tabela de historico de input.
- `phenom-zig/src/main.zig:111`: `runInteractiveChat` chamava `loadHistory` antes do loop.
- `phenom-zig/src/main.zig:264-301`: `loadHistory`/`saveHistory` liam e gravavam `.phenom-history` via C stdio.
- `phenom-zig/src/tui.zig:227-426`: `InputEditor.history` e apenas estrutura de navegacao em memoria; ele nao precisa saber qual storage persistente alimenta suas entradas.
- Regra operacional do projeto: `MEMORY.md`/`SKILLS.md` sao contexto persistente do projeto; historico de CLI e audit sao storage operacional e devem ficar fora do prompt do modelo.

Impacto esperado:

- `phenom-zig chat` carrega historico interativo de `.phenom-zig/phenom.db`.
- Cada input nao vazio submetido no modo interativo e persistido em `input_history`.
- Navegacao com seta continua usando `InputEditor.history`, alimentado por linhas newest-first vindas do SQLite.
- `.phenom-history` deixa de ser criado ou atualizado pelo binario Zig.
- Historico e deduplicado na leitura: repetir uma linha move essa linha para o topo.
- Banco limita o historico operacional aos 200 inputs distintos mais recentes para evitar crescimento sem controle.

Teste primeiro:

- `audit.zig`: inserir `primeiro`, `segundo`, `primeiro`; leitura deve retornar `primeiro`, `segundo`.
- `audit.zig`: inserir 205 linhas distintas; leitura deve retornar 200, de `line-204` ate `line-5`.
- Validacao PTY em diretorio temporario: sair com `/exit` nao deve criar `.phenom-history`.

Implementacao:

- `phenom-zig/src/audit.zig`: adicionar tabela `input_history`, indice `(line, id)`, `recordInputHistory`, `loadInputHistoryNewestFirst` e `freeHistoryLines`.
- `phenom-zig/src/main.zig`: abrir `.phenom-zig/phenom.db` no modo interativo, carregar history do banco e gravar cada input nao vazio com `recordInputHistory`.
- `phenom-zig/src/main.zig`: remover `loadHistory`/`saveHistory` baseados em `.phenom-history`.

Passos de implementacao:

1. Criar schema SQLite antes de alterar o loop interativo.
2. Escrever testes unitarios do banco provando ordem, dedupe e limite.
3. Substituir chamadas de arquivo em `runInteractiveChat` por chamadas de `AuditDb`.
4. Remover dependencia de C stdio do `main.zig`.
5. Rodar testes unitarios e release.
6. Rodar PTY em diretorio temporario para provar que `.phenom-history` nao nasce.
7. Comitar somente `phenom-zig/src/audit.zig`, `phenom-zig/src/main.zig` e `TASKS.md`.

Revisao baixo nivel obrigatoria antes do commit:

- Ownership/lifetime: linhas retornadas de SQLite sao duplicadas para o allocator chamador e liberadas por `freeHistoryLines`; o editor duplica novamente para seu proprio cache.
- `deinit`: `sqlite3_stmt` sempre finaliza; linhas alocadas em falha sao limpas por `errdefer`.
- C interop: SQL e input sao `dupeZ`; `sqlite3_column_text` e copiado antes de `sqlite3_step` avancar/finalizar.
- Bounds/overflow: `limit` valida `c_int`; trimming ignora input vazio; trim de storage fica limitado a 200 linhas distintas.
- Erro/comportamento: falha de SQLite deve abortar o fluxo interativo porque historico/audit operacional e parte da confiabilidade do CLI.
- Escopo: nao resolver validacao de host/DNS nesta task; isso pertence ao modulo HTTP.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- PTY `/exit` em diretorio temporario nao cria `.phenom-history`.
- `real-smoke` continua provando backend real.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY em `/tmp` com `/home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/zig-out/bin/phenom chat --offline --no-color`, input `/exit\r` -> restaurou terminal e imprimiu `Session saved. Use phenom chat to continue.`
- Verificacao de arquivos apos PTY: `/tmp/.phenom-zig/phenom.db` existe; `/tmp/.phenom-history` nao existe.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou; backend retornou `PHENOM_REAL_7319`.

Revisao baixo nivel executada:

- Corrigido possivel leak em `loadInputHistoryNewestFirst`: `dupe` da linha agora e separado do `append`, com `errdefer` para liberar se o append falhar.
- `recordInputHistory` valida tamanho antes de passar length para `sqlite3_bind_text` como `c_int`.
- `main.zig` nao importa mais `stdio.h`; persistencia por arquivo foi removida do caminho interativo.

## T233 - Iniciar port do chat TS com contrato de eventos no Zig

Status: implemented-verified-real.

Motivacao: a analise do `phenom-cli-ts` mostrou que o chat real nao e apenas um renderer bonito. O fluxo e `index.ts` criando `Agent` + `CliRenderer`, emitindo eventos (`USER_MESSAGE`, `THINK_START`, `MESSAGE_CHUNK`, `REASONING_CHUNK`, `TOOL_START`, `TOOL_RESULT`, `FILE_DIFF`, `THINK_END`) e deixando o renderer decidir layout/status/stream. O Zig ainda chamava `renderer.user`, `renderer.assistantDelta`, `renderer.done` diretamente, o que impediria portar fielmente o motor do TS sem reescrever o controller de novo.

Evidencia:

- `../phenom-cli-ts/src/index.ts:49-52`: `Agent`, `CliRenderer` e `renderer.attach()` sao criados antes do chat.
- `../phenom-cli-ts/src/index.ts:198-218`: `onLine` emite `USER_MESSAGE`, executa comando slash ou `agent.processInput`, depois renderiza prompt.
- `../phenom-cli-ts/src/tui/event-bus.ts:5-56`: lista de eventos que define o contrato visual/operacional do chat.
- `../phenom-cli-ts/src/cli-renderer.ts:1089-1845`: `CliRenderer` escuta eventos e decide user bubble, chunks, thinking, tools, diff, status, cancelamento e done.
- `phenom-zig/src/main.zig` antes desta task chamava renderer diretamente e, em `--offline`, emitia `ok`, confundindo stub local com output de modelo.

Impacto esperado:

- `phenom-zig chat` passa a ter um contrato interno de eventos equivalente ao caminho TS.
- O renderer atual vira apenas um subscriber/adaptador; futuras tasks podem trocar o motor visual sem mudar o controller.
- `--offline` nao parece mais resposta real do modelo: output vira `[offline stub] model not called`.
- Tool demo passa por `tool_start`/`tool_result`, preparando a paridade de tool UI do TS.
- Streaming real passa por `message_chunk` e `reasoning_chunk`, preparando a supressao de envelopes/tool JSON no renderer.

Teste primeiro:

- `ui_events.zig`: EventBus entrega eventos em ordem de registro.
- `ui_events.zig`: RendererEventSink transforma `user_message`, `think_start`, `message_chunk`, `think_end` em transcript com user bubble, resposta e `[done]`.
- `main.zig`: offline stub deve conter `offline` e `model not called`, e nunca ser `ok`.

Implementacao:

- `phenom-zig/src/ui_events.zig`: adicionar `EventType`, `Event`, payloads pequenos, `EventBus` sincrono e `RendererEventSink`.
- `phenom-zig/src/main.zig`: criar EventBus por turno, registrar renderer sink e trocar chamadas diretas por eventos.
- `phenom-zig/src/main.zig`: trocar branch `--offline` de `ok` para `[offline stub] model not called`.
- `phenom-zig/src/main.zig`: `StreamSink` passa a emitir `message_chunk` e `reasoning_chunk`.

Passos de implementacao:

1. Criar contrato de eventos independente do renderer.
2. Cobrir ordem de dispatch com teste unitario.
3. Cobrir adapter renderer com snapshot simples.
4. Inserir bus no `runChatTurnWithUi`.
5. Emitir eventos para user, think start, tool demo, chunks, errors, status e think end.
6. Remover `ok` ambiguo do modo offline.
7. Rodar teste, release, offline prompt e smoke real.

Revisao baixo nivel obrigatoria antes do commit:

- Ownership/lifetime: payloads sao slices validos durante `emit` sincrono; o bus nao armazena payload apos retorno.
- Alocacao: `EventBus` so aloca lista de handlers; `deinit` libera a lista.
- Erro/comportamento: erro em handler aborta o turno; isso e correto porque renderer/audit precisam falhar visivelmente, nao mascarar output quebrado.
- Bounds/overflow: nenhuma aritmetica nova em terminal; esta task nao altera wrapping/statusbar.
- Escopo: ainda nao porta o visualizer com noise/cascade, markdown streaming, mouse wheel, transcript restore completo ou suppressao de tool envelopes do TS.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `./zig-out/bin/phenom chat --offline --no-color --prompt oi` mostra `[offline stub] model not called`, nao `ok`.
- `real-smoke` continua provando que o caminho sem `--offline` chama backend real.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --offline --no-color --prompt oi` -> exibiu `[offline stub] model not called` e `[done]`, sem `ok`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest` -> passou; backend retornou `PHENOM_REAL_7319`.

Revisao baixo nivel executada:

- `EventBus.emit` e sincrono; nenhum payload fica armazenado depois do handler.
- `RendererEventSink` nao possui buffers owned; so guarda ponteiro do renderer valido durante o turno.
- `StreamSink.visible` continua owned e liberado em `deinit`.
- `offlineStubResponse` retorna string literal estatica; nao exige free.
- `real-smoke` provou que `--offline` nao interfere no caminho real.

## T234 - Corrigir prompt digitado e statusbar assincrona no chat Zig

Status: implemented-verified-real.

Motivacao: antes de continuar o port do chat TS, dois bugs bloqueavam uso real da TUI: o texto digitado no prompt nao aparecia de forma confiavel em raw mode, e a statusbar/visualizer so mudava quando o loop principal chamava `pulseStatus`, sem ticker proprio durante prefill/inferencia. No TS, `CliRenderer` usa footer fixo com repaint ativo durante inferencia e save/restore cursor; o Zig precisava do mesmo principio operacional.

Evidencia:

- `phenom-zig/src/tui.zig`: `cfmakeraw` desativa processamento de output do terminal; `renderBottomBar` usava `\n` puro entre linhas. Em raw mode, `\n` nao garante retorno para coluna 1, causando prompt pintado fora da posicao esperada.
- `phenom-zig/src/tui.zig`: `pulseStatus` so rodava quando chamado pelo stream; durante prefill/model wait nao havia atualizacao assincrona.
- `../phenom-cli-ts/src/cli-renderer.ts:2447-2455`: TS inicia timer de repaint durante inferencia.
- `../phenom-cli-ts/src/cli-renderer.ts:2463-2484`: TS redesenha footer com save/restore cursor para nao misturar status com output do modelo.
- `../phenom-cli-ts/src/cli-renderer.ts:2499-2556`: TS monta status com label, elapsed/tokens e visualizer dinamico.

Impacto esperado:

- Texto digitado aparece no prompt antes do Enter.
- Statusbar atualiza de forma assincrona durante espera do modelo, nao apenas quando chega token.
- Status muda de `Thinking` para `Responding` quando chegam chunks visiveis.
- Renderer e footer compartilham lock simples para reduzir risco de escape sequences intercaladas.
- `showDone`, `showPrompt` e `detach` param a thread e fazem join antes de limpar/restaurar terminal.

Teste primeiro:

- Snapshot do bottom bar passa a esperar CRLF (`\r\n`) entre linhas, cobrindo raw mode.
- PTY offline: digitar `abc` sem Enter deve mostrar `> abc`.
- PTY real: durante inferencia, statusbar deve repintar wave e mudar `Thinking` -> `Responding`.

Implementacao:

- `phenom-zig/src/tui.zig`: trocar separadores do bottom bar para `\r\n`.
- `phenom-zig/src/tui.zig`: adicionar `status_running`, `status_thread`, `status_started_ms`, `write_mutex`, `startStatusTicker`, `stopStatusTicker` e ticker com `usleep(80ms)`.
- `phenom-zig/src/tui.zig`: formatar status dinamico como `{label} ({elapsed}s · esc to interrupt)` usando `clock_gettime(CLOCK_MONOTONIC)`.
- `phenom-zig/src/ui_events.zig`: adicionar lock opcional no `RendererEventSink`.
- `phenom-zig/src/main.zig`: passar mutex da TUI para renderer sink e atualizar status para `Thinking`/`Responding` nos chunks.

Passos de implementacao:

1. Corrigir CRLF do footer para raw mode.
2. Adicionar lock terminal compartilhado.
3. Criar ticker assincrono de status durante inferencia.
4. Garantir stop/join em done/prompt/detach.
5. Atualizar labels do main para `Thinking`/`Responding`.
6. Rodar unitarios e release.
7. Validar PTY offline e PTY real.

Revisao baixo nivel obrigatoria antes do commit:

- Lifetime: thread recebe ponteiro para `TerminalUi`; `stopStatusTicker` faz join antes de `deinit` liberar editor/restaurar terminal.
- Concorrencia: `RendererEventSink` e `TerminalUi.draw` usam o mesmo `std.atomic.Mutex`; writes do renderer e do footer nao rodam simultaneamente.
- C interop: `usleep` e `clock_gettime(CLOCK_MONOTONIC)` usam headers libc ja declarados; falha de `clock_gettime` retorna elapsed 0.
- Raw mode: CRLF evita depender de `OPOST/ONLCR`, que `cfmakeraw` desativa.
- Escopo: ainda nao porta o visualizer noise/cascade completo do TS; esta task corrige funcionamento assincrono e visibilidade.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- PTY offline mostra texto digitado antes do Enter.
- PTY real mostra statusbar atualizando durante inferencia e backend retorna token esperado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY offline `./zig-out/bin/phenom chat --offline --no-color`, input parcial `abc` -> output mostrou `> abc` antes do Enter.
- PTY offline `abc\r/exit\r` -> mostrou statusbar, resposta offline explicita, `[done]`, restaurou terminal.
- PTY real `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 96 --thinking off --expect-contains PHENOM_REAL_7319 --show-expect-status`, input `Complete: PHENOM_REAL_7319\r` -> statusbar repintou wave, mudou `Thinking` para `Responding`, backend retornou `PHENOM_REAL_7319`, terminal restaurou em `/exit`.

## T235 - Corrigir streaming do bloco thinking e finalizacao duplicada no chat Zig

Status: implemented-verified-real.

Motivacao: o log real mostrou o bloco `thinking` ilegivel, com gutter `│` inserido entre tokens (`O │ usuario │ esta...`), e o fim do turno apareceu com `[done]` duplicado/prompt corrompido. Isso quebra a paridade visual com o `phenom-cli-ts`, atrapalha copia do terminal e mascara a separacao entre raciocinio de baixo destaque e resposta final.

Evidencia:

- Log reportado pelo usuario: `│ thinking` seguido de `│ O │ usuário │ está...`, resposta final desalinhada, dois `[done]` e prompt final `n>`.
- `phenom-zig/src/render.zig`: `thinkingDelta` escrevia `│ ` para cada chunk recebido. Como o backend streama tokens, cada token virava uma falsa linha visual.
- `phenom-zig/src/main.zig`: `runChatTurnWithUi` ja finalizava o transcript via evento `think_end`/`renderer.done()`, e `runInteractiveChat` chamava `ui.showDone()` logo depois, criando segunda finalizacao no footer.
- `../phenom-cli-ts/src/cli-renderer.ts`: o thinking e renderizado como bloco append-only com gutter por linha, nao por token.

Impacto esperado:

- `thinking` streamado por token fica legivel, com um unico `│` no inicio de cada linha logica.
- Texto UTF-8 em portugues permanece contiguo dentro de chunks coloridos.
- `[done]` aparece uma vez no transcript do turno.
- Apos o turno interativo, o footer volta para prompt limpo em vez de imprimir outro estado final.

Teste primeiro:

- Unitario do renderer com chunks `"O"`, `" usuario"`, `" esta\nok"` deve produzir `│ O usuario esta` e `│ ok`, sem gutter entre tokens.
- Unitario com ANSI ligado deve preservar substring UTF-8 `usuario em portugues` com acentos.
- PTY offline deve mostrar um unico `[done]` e prompt limpo depois do turno.
- Smoke real com `--thinking on` deve mostrar bloco thinking sem `│` entre tokens.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar `thinking_needs_gutter` ao `AppendOnlyRenderer`.
- `phenom-zig/src/render.zig`: mudar `thinkingDelta` para escrever gutter apenas no inicio de linha logica e preservar fatias UTF-8 entre `\n`.
- `phenom-zig/src/render.zig`: ajustar `thinkingEnd` para nao forcar linha extra quando o bloco ja terminou em newline.
- `phenom-zig/src/main.zig`: trocar `ui.showDone()` por `ui.showPrompt()` no loop interativo; o `[done]` do transcript continua sendo responsabilidade do evento `think_end`.

Passos de implementacao:

1. Reproduzir causa no renderer por leitura do codigo e teste de chunks.
2. Adicionar estado minimo para gutter do thinking.
3. Preservar escrita por slice para nao quebrar UTF-8.
4. Remover duplicacao visual de done no loop interativo.
5. Rodar unitarios, build release, PTY offline e smoke real com backend.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: nenhum buffer owned novo; `thinking_needs_gutter` e estado escalar dentro do renderer.
- UTF-8: escrita do thinking usa fatias entre newlines, nao byte a byte, evitando ANSI no meio de codepoint.
- Concorrencia: mantido o lock existente do `RendererEventSink` quando ha TUI; a mudanca nao adiciona thread nem ponteiro novo.
- Terminal cleanup: `ui.showPrompt()` para ticker via `stopStatusTicker` e redesenha footer; `renderer.done()` permanece append-only no transcript.
- Escopo: nao altera parsing de reasoning nem protocolo HTTP; corrige apenas render/finalizacao.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- PTY offline `ola\r/exit\r` mostra um unico `[done]` e restaura terminal.
- Smoke real `--thinking on --prompt ola` mostra `│ thinking` com texto continuo e resposta final separada.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY offline `./zig-out/bin/phenom chat --offline --no-color`, input `ola\r/exit\r` -> mostrou `[offline stub] model not called`, um unico `[done]`, prompt limpo e mensagem de sessao salva.
- Smoke real sem permissao de rede no sandbox -> falhou antes de conectar com `SocketCreateFailed`, validando que nao era falha do renderer.
- Smoke real com permissao de rede `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 80 --prompt ola --no-color` -> passou; backend respondeu `Ola! Como posso ajudar?` e `[done]` apareceu uma vez.
- Smoke real com thinking `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 140 --thinking on --prompt ola --no-color` -> passou; bloco `thinking` saiu com texto continuo em portugues, sem gutter entre tokens.

## T236 - Corrigir alinhamento do transcript append-only em terminal raw

Status: implemented-verified-real.

Motivacao: apos T235, o gutter do `thinking` parou de repetir por token, mas o log interativo ainda mostrou os blocos deslocados para a direita. A causa nao era o renderer de thinking: em raw mode, `cfmakeraw` desativa a traducao de output do terminal, entao `\n` desce linha sem retornar para coluna 1. O footer ja usava CRLF; faltava normalizar o transcript append-only quando a TUI esta ativa.

Evidencia:

- Log reportado pelo usuario: user bubble inicia correto, mas `│ thinking`, resposta final e `[done]` aparecem com grandes espacos antes do conteudo.
- `phenom-zig/src/tui.zig`: `attach` usa `cfmakeraw`, que remove processamento de output.
- `phenom-zig/src/render.zig`: o transcript append-only emite `\n` em varios pontos por design, correto para stdout normal, mas insuficiente quando stdout esta sob TUI raw.
- PTY offline antes da correcao: depois de uma linha preenchida ate o fim, linhas seguintes podiam herdar coluna errada.

Impacto esperado:

- Transcript interativo volta para coluna 1 em cada newline.
- Modo `--prompt` nao interativo preserva LF normal.
- Nao e necessario alterar todos os blocos do renderer nem ligar `OPOST` globalmente no terminal.
- Footer/statusbar continua usando sua propria renderizacao CRLF.

Teste primeiro:

- Unitario do writer: `a\nb`, `\r\n`, `c\n` devem virar `a\r\nb\r\nc\r\n` sem duplicar CR.
- PTY offline interativo deve mostrar user bubble, resposta e `[done]` alinhados na margem.
- PTY real com `--thinking on` deve mostrar `│ thinking`, resposta e `[done]` alinhados na margem.

Implementacao:

- `phenom-zig/src/fd_writer.zig`: adicionar `NewlineWriter(Inner)` com modo `crlf`.
- `phenom-zig/src/fd_writer.zig`: preservar estado `prev_cr` para nao transformar `\r\n` em `\r\r\n`.
- `phenom-zig/src/main.zig`: usar `NewlineWriter(fd_writer.FdWriter)` no renderer do turno; `crlf = true` somente quando ha `TerminalUi` ativa.

Passos de implementacao:

1. Identificar que o deslocamento vem de LF em raw mode, nao de padding do renderer.
2. Criar writer pequeno com traducao LF -> CRLF.
3. Ativar o writer apenas no transcript do chat interativo.
4. Rodar unitarios, release, PTY offline e PTY real com thinking.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: `NewlineWriter` nao aloca; guarda apenas `inner`, `crlf` e `prev_cr` no stack do turno.
- C interop: nenhuma mudanca em `termios`; evita efeitos colaterais de reativar `OPOST/ONLCR` globalmente.
- UTF-8: writer so inspeciona bytes `\r` e `\n`; nao reescreve bytes multibyte.
- Concorrencia: renderer continua protegido pelo mutex da TUI via `RendererEventSink`; writer vive ate o fim de `runChatTurnWithUi`.
- Escopo: nao altera visualizer/statusbar; corrige apenas newline do transcript append-only em raw mode.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- PTY offline `ola\r/exit\r` mostra blocos alinhados na margem.
- PTY real `--thinking on`, input `ola`, mostra `│ thinking`, resposta e `[done]` alinhados na margem.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY offline `./zig-out/bin/phenom chat --offline --no-color`, input `ola\r/exit\r` -> passou; user bubble, resposta offline e `[done]` iniciaram alinhados na margem.
- PTY real `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 140 --thinking on --no-color`, input `ola\r/exit\r` -> passou; `│ thinking`, resposta final e `[done]` iniciaram alinhados na margem.

## T237 - Ajustar wrapping do thinking e resiliencia do TUI a resize

Status: implemented-verified-real.

Motivacao: o layout estava quase correto, mas ainda faltava enquadrar o texto longo do `thinking` dentro do componente e reduzir o espaco variavel entre fim do thinking e output. Tambem havia risco em resize: o footer recalculava largura em cada draw, mas a scroll region so era ressincronizada quando a quantidade de linhas do prompt mudava, nao quando o terminal mudava `rows/cols`.

Evidencia:

- Log reportado: `thinking` com linha longa sem enquadramento visual no componente.
- `phenom-zig/src/render.zig`: `thinkingDelta` preservava gutter por linha, mas nao tinha largura interna para quebrar linhas longas.
- `phenom-zig/src/main.zig`: depois de `</think>`, o output visivel podia chegar com `\n\n` ou espaco inicial do template/modelo, inflando o gap antes da resposta.
- `phenom-zig/src/tui.zig`: `drawUnlocked` chamava `terminalSize()`, mas `resyncScrollRegion()` so era acionado por mudanca de `bottom_rows`.

Impacto esperado:

- `thinking` passa a quebrar dentro da largura disponivel e cada continuacao recebe gutter `│`.
- A resposta final apos thinking remove whitespace inicial vindo da transicao `</think>`, deixando o gap visual controlado pelo renderer.
- Renderer interativo atualiza `terminal_columns` antes de cada evento, entao novos chunks respeitam a largura atual depois de resize.
- TUI ressincroniza scroll region quando `rows` ou `cols` mudam.
- Footer limita linhas de prompt conforme altura disponivel para reduzir quebra em terminais pequenos.

Teste primeiro:

- Unitario do renderer: terminal estreito deve quebrar `abcdefghi` em `│ abcdefgh` + `│ i`.
- Unitario do stream: transicao pos-thinking deve aparar `\r\n\t ` antes da resposta final.
- Unitario do prompt view: limite de linhas pequeno deve mostrar somente as ultimas linhas visiveis.
- PTY pequeno deve manter footer dentro da area reservada.
- PTY grande deve manter statusbar/prompt alinhados.
- Smoke real com `--thinking on` deve mostrar thinking enquadrado e gap controlado antes da resposta.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar `thinking_col`, `setTerminalColumns` e `writeWrappedThinkingText`.
- `phenom-zig/src/render.zig`: contar codepoints UTF-8 como uma coluna pratica e escrever fatias, nao byte a byte, preservando ANSI e texto UTF-8.
- `phenom-zig/src/ui_events.zig`: adicionar callback opcional `terminal_columns` no `RendererEventSink`.
- `phenom-zig/src/main.zig`: ligar `currentTerminalColumns` quando ha TUI ativa.
- `phenom-zig/src/main.zig`: aparar whitespace inicial apenas na primeira resposta visivel apos `endThinking`.
- `phenom-zig/src/tui.zig`: guardar ultimo `terminal_rows/terminal_cols`, ressincronizar scroll region em resize e limitar linhas do prompt no footer.

Passos de implementacao:

1. Adicionar wrapping interno do thinking sem quebrar UTF-8.
2. Atualizar largura dinamica antes de cada evento renderizado.
3. Normalizar whitespace inicial depois de `</think>`.
4. Ressincronizar scroll region em mudanca de tamanho.
5. Limitar prompt footer pela altura disponivel.
6. Rodar unitarios, release e smokes PTY pequeno/grande/real.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: nenhum buffer owned novo no renderer/event sink; novos campos sao escalares e callback de funcao estatica.
- UTF-8: wrapping usa fatias por codepoint; nao injeta ANSI dentro de codepoint e nao corta bytes deliberadamente.
- Concorrencia: callback de coluna roda dentro do mesmo lock do renderer quando ha TUI; nao cria thread nova.
- Terminal: resize chama `resyncScrollRegionFor(size)` com tamanho capturado no draw atual; footer limita linhas para nao desenhar area maior que o terminal.
- Limite deliberado: transcript append-only nao reflowa texto antigo depois de resize; apenas novos chunks e footer passam a usar a largura atual.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- PTY estreito nao quebra footer nem deixa thinking sair do componente.
- PTY grande mantem statusbar/prompt alinhados.
- Smoke real `--thinking on` mostra thinking wrapped e resposta separada por gap controlado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY pequeno `stty cols 32 rows 10; ./zig-out/bin/phenom chat --offline --no-color`, input longo + `/exit` -> passou; footer ficou na area reservada e transcript alinhou.
- PTY real pequeno `stty cols 36 rows 12; ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 120 --thinking on --no-color`, input `ola` + `/exit` -> passou; thinking quebrou com gutter nas continuacoes e resposta ficou separada por gap controlado.
- PTY grande `stty cols 140 rows 40; ./zig-out/bin/phenom chat --offline --no-color`, input `ola em terminal grande` + `/exit` -> passou; statusbar, prompt e transcript ficaram alinhados.
- Smoke real limpo `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 120 --thinking on --prompt ola --no-color` -> passou; thinking enquadrado e resposta final sem whitespace inicial.

## T238 - Restaurar sessao SQLite com estilos e portar visualizer.py para Zig

Status: implemented-verified.

Motivacao: o chat Zig ja persistia eventos operacionais em SQLite, mas ao abrir uma sessao nao reconstruia o transcript visivel. Isso deixava o SQLite como audit passivo, nao como fonte de recuperacao da sessao. Alem disso, a statusbar usava uma onda estatica simples, enquanto o `phenom-cli-ts` executa um visualizer baseado no `visualizer.py` com estados, noise e transicao em cascata.

Evidencia:

- `phenom-zig/src/audit.zig`: havia `events(session, kind, body)`, mas so existia leitura para `input_history`.
- `phenom-zig/src/main.zig`: `runInteractiveChat` carregava historico de input, mas nao reemitia eventos da sessao para o renderer.
- `phenom-zig/src/main.zig`: `tool_start` era exibido ao vivo mas nao era persistido, entao uma recuperacao futura perderia o anuncio da tool.
- `../phenom-cli-ts/src/cli-renderer.ts:951-1030`: `restoreConversation` reconstrui user, thinking, tools e assistant a partir de dados logicos, nao de texto bruto stale.
- `../phenom-cli-ts/src/visualizer-mini.ts`: porta do `visualizer.py` com estados `idle/listening/thinking/working/responding`, noise deterministico e cascade left-to-right.
- `../phenom-cli-ts/visualizer.py`: referencia original de blocos, estados e cascata visual.

Impacto esperado:

- Ao abrir `phenom chat --session ID`, eventos existentes no SQLite sao reemitidos como transcript estilizado.
- User messages, thinking, tool start, evidence/tool result, assistant output, status/error e done usam o renderer atual.
- O replay nao usa texto renderizado antigo; largura, cores e wrapping sao recalculados no momento da restauracao.
- `tool_start` passa a ser persistido para novas sessoes.
- Statusbar passa a usar visualizer stateful com energia/densidade/caos e transicao em cascata, alinhado ao `phenom-cli-ts`.

Teste primeiro:

- SQLite in-memory com eventos `turn_start`, `assistant_thinking_delta`, `tool_start`, `evidence`, `assistant_delta`, `turn_done` deve renderizar transcript contendo user bubble, `thinking`, `Reading`, evidence, assistant e `[done]`.
- Audit store deve carregar eventos por sessao em ordem de insercao.
- Visualizer deve renderizar largura correta em idle/active e sobreviver a resize.
- PTY deve restaurar uma sessao real offline a partir de `.phenom-zig/phenom.db`.

Implementacao:

- `phenom-zig/src/audit.zig`: adicionar `AuditEvent`, `loadSessionEvents` e `freeAuditEvents`.
- `phenom-zig/src/main.zig`: adicionar `renderRestoredSession`, chamado no boot interativo apos abrir SQLite e antes do prompt.
- `phenom-zig/src/main.zig`: mapear eventos SQLite para `EventBus`: `turn_start`, `assistant_thinking_delta`, `tool_start`, `evidence`, `assistant_delta`, `assistant_offline_stub`, erros/status e `turn_done`.
- `phenom-zig/src/main.zig`: persistir `tool_start` como `name\tdetail`.
- `phenom-zig/src/render.zig`: `tool_start` com sample vazio nao imprime mais falso `no output`.
- `phenom-zig/src/tui.zig`: adicionar `MiniVisualizer` stateful com formulas do `visualizer-mini.ts`/`visualizer.py`, resize de largura e tick de 33ms.
- `phenom-zig/src/tui.zig`: statusbar usa frame renderizado pelo `MiniVisualizer` em vez de frame estatico.

Passos de implementacao:

1. Criar leitura tipada dos eventos SQLite.
2. Criar replay de sessao usando renderer/event bus existente.
3. Persistir `tool_start` para novas sessoes.
4. Corrigir anuncio de tool sem resultado falso.
5. Portar mini visualizer para Zig sem alocacao.
6. Conectar visualizer ao ticker/statusbar.
7. Rodar unitarios, release e PTY de restauracao.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: `loadSessionEvents` duplica `kind/body` e `freeAuditEvents` libera todos; `renderRestoredSession` usa `defer`.
- SQLite: statements sao finalizados; bind usa tamanhos explicitos; limite de eventos evita replay sem teto.
- Terminal: replay escreve via `NewlineWriter` com CRLF quando esta em TUI raw.
- Concorrencia: replay usa o mesmo mutex da TUI no `RendererEventSink`.
- Visualizer: sem heap; buffer maximo fixo `max_visualizer_cols * 4`; `setWidth` clampa largura.
- Limite deliberado: replay usa eventos disponiveis no SQLite atual; sessoes antigas sem `tool_start` ainda restauram evidence/assistant/done, mas nao podem inventar detalhe de tool que nao foi salvo.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Sessao offline criada com `--session restore-smoke --demo-read-file src/main.zig` restaura transcript estilizado ao abrir a mesma sessao.
- Visualizer aparece na statusbar com frame gerado pelo port stateful, nao por tabela estatica.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- PTY `./zig-out/bin/phenom chat --session restore-smoke --offline --no-color --demo-read-file src/main.zig`, input `analise com ferramenta` + `/exit` -> gravou user/tool/evidence/assistant/done no SQLite.
- PTY abrindo a mesma sessao -> restaurou user bubble, `▸ Reading: src/main.zig`, bloco evidence com gutter, assistant offline e `[done]` antes do prompt.
- Visualizer no smoke PTY exibiu onda gerada durante `Thinking`, com ticker de 33ms.

## T239 - Manter linhas vazias internas dentro do componente thinking

Status: implemented-verified-real.

Motivacao: o modelo pode emitir raciocinio em paragrafos separados por linhas vazias. O renderer preservava essas quebras como linhas totalmente vazias, sem gutter, fazendo o bloco `thinking` parecer varios componentes soltos. O visual esperado e um unico componente vertical: todas as linhas internas, inclusive separadores de paragrafo, precisam continuar marcadas pelo gutter `│`.

Evidencia:

- Log reportado: `thinking` aparece com uma linha vazia crua entre `Preciso responder...`, `Da Vinci se refere...` e `Vou fornecer...`.
- `phenom-zig/src/render.zig`: em `thinkingDelta`, quando o byte atual era `\n`, o renderer escrevia apenas newline e marcava `thinking_needs_gutter = true`; em `\n\n`, a segunda quebra virava linha vazia sem `│`.
- `../phenom-cli-ts/src/cli-renderer.ts`: `formatThinkingBlock` renderiza linha vazia interna como marker do thinking, mantendo o bloco unido.

Impacto esperado:

- Paragrafos dentro de `thinking` ficam em um unico bloco visual.
- Linhas vazias internas aparecem como `│`, nao como buracos no transcript.
- Wrapping, UTF-8 e gap entre `thinking` e resposta final permanecem inalterados.

Teste primeiro:

- Renderer com `primeiro\n\nsegundo\n\nterceiro` deve produzir `│ primeiro`, `│`, `│ segundo`, `│`, `│ terceiro`.
- Smoke real com `--thinking on` deve mostrar parágrafos internos do thinking com gutter continuo.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar `writeThinkingBlankLine`.
- `phenom-zig/src/render.zig`: quando `thinkingDelta` recebe newline enquanto `thinking_needs_gutter` ja esta ativo, escrever uma linha vazia com gutter antes do newline.

Passos de implementacao:

1. Reproduzir causa pela leitura do estado `thinking_needs_gutter`.
2. Adicionar helper minimo para blank line guttered.
3. Cobrir com teste de snapshot do renderer.
4. Rodar unitarios, release e smoke real.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: nenhum estado ou buffer novo owned; helper escreve direto no writer.
- UTF-8: mudanca so intercepta byte newline; texto multibyte continua pelo caminho existente.
- Terminal: em TUI raw, newline continua passando pelo `NewlineWriter`; gutter blank line recebe CRLF como o resto do transcript.
- Escopo: nao altera parser de thinking, protocolo HTTP, replay SQLite ou statusbar.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real `--thinking on --prompt "quem foi davinci"` mostra blank lines internas como `│`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 180 --thinking on --prompt "quem foi davinci" --no-color` -> passou; paragrafos internos do thinking apareceram com linhas `│`.

## T240 - Concluir fase visual Codex/TUI com snapshots append-only

Status: implemented-verified-real.

Motivacao: depois das correcoes de TUI, restore SQLite, visualizer, resize e thinking, faltava fechar a conclusao operacional sobre Codex: o Phenom Zig deve seguir os principios de UX, nao copiar implementacao. A base agora precisa provar em snapshot que o turno append-only tem user query, thinking, tool sample, diff, resposta e `[done]` em sequencia copiavel, com espacamentos previsiveis e diff sem paleta ofuscante.

Evidencia:

- Fase 18 do devlog define Codex como referencia de comportamento: transcript append-only, blocos limpos, tool samples, finalizacao discreta e divisorias consistentes.
- T229-T239 implementaram partes reais no Zig: user bubble, thinking, TUI raw, statusbar, resize, restore SQLite, visualizer e blank lines internas.
- `phenom-zig/src/render.zig`: ainda nao havia snapshot unico cobrindo uma sequencia completa user -> thinking -> tool -> diff -> assistant -> done.
- `phenom-zig/src/render.zig`: diff ja usava marker colorido e corpo neutro, mas nao havia teste provando ausencia de background saturado vermelho/verde.

Impacto esperado:

- A conclusao Codex fica codificada como contrato de renderer, nao apenas texto em task.
- Regressao de espacamento entre user, thinking, tool, diff, resposta e done passa a falhar em teste.
- Diff continua legivel: marker forte, corpo do codigo sem background saturado.
- O motor permanece append-only, compatível com tmux/scrollback/copy.

Teste primeiro:

- Snapshot end-to-end de turno append-only com user query, thinking com blank line interna, tool sample, diff truncado, assistant e `[done]`.
- Snapshot ANSI de diff garantindo que nao ha `\x1b[41`/`\x1b[42` e que apenas os markers `- │`/`+ │` recebem foreground red/green.
- Smoke real `--thinking on` para verificar spacing user -> thinking -> resposta com backend.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar snapshot `codex style append only turn snapshot covers core blocks`.
- `phenom-zig/src/render.zig`: adicionar teste `ansi diff colors markers without saturated backgrounds`.
- `phenom-zig/src/render.zig`: adicionar `assistant_wrote_content` para nao fechar assistant vazio como linha extra.
- `phenom-zig/src/render.zig`: adicionar `suppress_next_block_gap` para evitar gap duplicado quando `thinkingEnd` ja emitiu separador.
- `phenom-zig/src/render.zig`: evitar newline extra na abertura de thinking logo apos user block.

Passos de implementacao:

1. Criar snapshot completo da sequencia visual Codex-like.
2. Rodar teste e identificar gaps extras.
3. Remover newline extra user -> thinking.
4. Impedir que assistant vazio entre thinking/tool gere linha fantasma.
5. Impedir que `blockGap` duplique separador pos-thinking.
6. Criar teste ANSI de diff sem background saturado.
7. Rodar unitarios, release e smoke real.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: novos campos sao booleanos escalares no renderer; sem alocacao.
- Terminal: mudanca atua no transcript append-only; TUI raw continua usando `NewlineWriter`.
- Concorrencia: renderer continua sincrono e protegido pelo mutex quando chamado via TUI.
- ANSI: teste garante que diff nao usa background red/green saturado.
- Escopo: nao implementa markdown renderer completo nem copia codigo do Codex; fecha principios visuais centrais ja suportados no Zig.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Snapshot completo do turno append-only passa.
- Smoke real com `--thinking on --prompt ola` mostra spacing user -> thinking -> resposta sem gaps duplicados.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 120 --thinking on --prompt ola --no-color` -> passou; user, thinking, resposta e `[done]` apareceram em sequencia linear sem gaps duplicados.

## T241 - Trocar marcador final por footer Codex-like com duracao real

Status: implemented-verified-real.

Motivacao: o usuario pediu para substituir o marcador final `[done]` por uma divisoria no estilo Codex: `─ Worked for 7m 17s ─...`. O objetivo e manter o transcript append-only copiavel, mas tornar a finalizacao mais informativa e visualmente alinhada com a referencia do Codex, sem poluir o output do modelo nem depender de texto bruto salvo no historico.

Evidencia:

- `phenom-zig/src/render.zig`: `done()` escrevia finalizacao curta e os snapshots ainda validavam o marcador antigo.
- `phenom-zig/src/ui_events.zig`: o event sink ja recebe `user_message`, `think_start` e `think_end`, portanto consegue medir a duracao real do turno sem criar estado global.
- `phenom-zig/src/main.zig`: replay SQLite e turno real passam pelo mesmo `RendererEventSink`, entao a mudanca precisa ser feita no renderer/event sink, nao em cada fluxo de chat.
- Smoke real anterior mostrava o fim do turno como marcador literal, sem duracao.

Impacto esperado:

- Todo turno renderizado por `RendererEventSink` termina com `Worked for Ns` ou `Worked for Mm Ss`.
- `renderer.done()` continua disponivel para snapshots/caminhos sem temporizador e usa `0s`.
- A divisoria respeita largura do terminal e nao corta caractere UTF-8.
- O historico SQLite continua armazenando eventos logicos; a estetica do footer e recalculada no replay.

Teste primeiro:

- Snapshot append-only simples deve trocar o marcador final pela linha `Worked for`.
- Snapshot de status + finalizacao deve provar que o footer entra em bloco separado.
- Snapshot completo Codex-like deve terminar com a divisoria nova.
- Teste do `RendererEventSink` e do restore SQLite devem procurar `Worked for`, nao `[done]`.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar `doneWithElapsed(elapsed)` e manter `done()` como wrapper para `0s`.
- `phenom-zig/src/render.zig`: adicionar writer de divisoria que preenche ate `paintCols()`.
- `phenom-zig/src/render.zig`: escrever prefixo UTF-8 por colunas, nao por bytes, para evitar corte invalido do caractere `─`.
- `phenom-zig/src/ui_events.zig`: iniciar cronometro em `user_message` quando necessario e em `think_start` no fluxo normal.
- `phenom-zig/src/ui_events.zig`: formatar duracao no `think_end`, chamar `doneWithElapsed` e zerar estado do turno.
- `phenom-zig/src/tui.zig`: trocar status residual `showDone()` para `Worked for 0s` e manter colorizacao discreta.
- `phenom-zig/src/main.zig`: atualizar teste de restore SQLite para o footer novo.

Passos de implementacao:

1. Trocar snapshots para expressar o footer esperado.
2. Implementar API minima `doneWithElapsed`.
3. Medir duracao no event sink com `clock_gettime(CLOCK_MONOTONIC)`.
4. Corrigir corte UTF-8 da divisoria por largura de coluna.
5. Atualizar TUI/status residual.
6. Rodar unitarios, release e smoke real.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: nenhum heap novo; buffers de formatacao ficam na stack e sao escritos antes de sair do escopo.
- UTF-8: `writeDimColumns` percorre codepoints pelo tamanho UTF-8 e nunca fatia o caractere `─` no meio.
- Tempo: `CLOCK_MONOTONIC` evita regressao por ajuste de relogio do sistema; fallback retorna `0s`.
- Concorrencia: cronometro e renderer continuam dentro do mesmo `RendererEventSink`; quando ha TUI, o mutex existente protege a escrita.
- Terminal: footer usa `paintCols()` e respeita resize para novos blocos; nao tenta reflowar transcript antigo.
- Atualizacao 2026-07-09: tokens/throughput reais foram conectados depois via backend metrics; esta etapa visual continua sobre footer/elapsed.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real com backend local mostra resposta do modelo e footer `Worked for`.
- Nenhum caminho visual novo em `phenom-zig/src` deve depender do literal `[done]`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --max-tokens 80 --thinking on --prompt ola --no-color` -> passou; backend respondeu, thinking/output ficaram alinhados e o footer mostrou `Worked for 2s`.

## T242 - Adicionar config.toml para defaults do Phenom Zig

Status: implemented-verified.

Motivacao: o CLI Zig estava exigindo flags repetidas para `backend`, `host`, `port`, `model`, `thinking` e demais opcoes operacionais. Para uso real instalado em `~/.local/bin`, isso precisa virar configuracao persistente em `~/.config/phenom/config.toml`, mantendo flags como override explicito por turno.

Evidencia:

- `phenom-zig/src/cli.zig`: `parseArgs` partia sempre de defaults internos (`127.0.0.1:11434`, `llama3.2`, `ollama`, `thinking=auto`).
- `phenom-zig/src/main.zig`: `main` chamava `cli.parseArgs` direto; nao havia camada de config antes das flags.
- `phenom-zig/build.zig`: havia build/install padrao, mas nenhum step para publicar binario em `~/.local/bin` e config em `~/.config/phenom`.
- Uso real reportado pelo usuario alterna backend/host/model/thinking com frequencia; repetir isso em flags aumenta erro operacional.

Impacto esperado:

- `config.toml` na raiz do repo serve como default de desenvolvimento.
- Runtime instalado le `~/.config/phenom/config.toml` quando nao existe `./config.toml` no diretorio atual.
- Ordem de precedencia fica clara: defaults internos < config file < flags.
- `host` e `port` podem ser separados; `server` continua existindo como alias completo para `HOST:PORT` ou URL com `http://`.
- O prompt nao entra no config para nao transformar `phenom chat` interativo em prompt fixo acidental.
- `zig build install-local` copia `zig-out/bin/phenom` para `~/.local/bin/phenom` e `../config.toml` para `~/.config/phenom/config.toml`.

Teste primeiro:

- Parser deve aplicar `backend`, `host`, `port`, `model`, `thinking`, `max_tokens` e `no_color`.
- Flags devem sobrescrever valores vindos do config.
- `server` deve funcionar como alias de endpoint completo.
- Smoke runtime com config temporario `offline = true` deve executar sem tentar rede, mesmo sem flag `--offline`.

Implementacao:

- `phenom-zig/src/cli.zig`: adicionar `parseArgsWithBase(base, args)` e manter `parseArgs` como wrapper.
- `phenom-zig/src/config_file.zig`: criar loader de `./config.toml` com fallback para `~/.config/phenom/config.toml`.
- `phenom-zig/src/config_file.zig`: implementar parser TOML subset para `key = value`, strings, bools, ints, comentarios e secoes ignoradas.
- `phenom-zig/src/config_file.zig`: manter buffer do arquivo vivo enquanto `cli.Config` usa slices dele.
- `phenom-zig/src/main.zig`: trocar `cli.parseArgs` por `config_file.load`.
- `config.toml`: adicionar template operacional na raiz do repo.
- `phenom-zig/build.zig`: adicionar step `install-local`.
- `phenom-zig/src/cli.zig`: documentar lookup e chaves aceitas no help.

Passos de implementacao:

1. Separar parsing CLI puro de parsing com defaults.
2. Criar loader owned para o arquivo de config.
3. Parsear chaves simples e validar enum/bool/int.
4. Compor `host:port` quando `port` for informado.
5. Conectar loader no `main`.
6. Adicionar template `config.toml`.
7. Adicionar step de instalacao local.
8. Rodar unitarios, release e smoke offline por config.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: `LoadedConfig` libera `text` e `owned_host`; `cli.Config` nao sobrevive ao `deinit`.
- Heap: apenas o texto do config e o `host:port` composto sao alocados; sem storage global.
- I/O: leitura usa libc sincrona, limite de 64 KiB, falha em arquivo grande e nao ignora arquivo existente que nao pode ser aberto.
- Erros: OOM ao montar caminho de `HOME` nao e mascarado; `HOME` ausente apenas desativa fallback de usuario.
- Install: `install-local` valida `HOME` antes de copiar e falha antes de tocar paths fora do usuario se `HOME` estiver ausente.
- Compatibilidade: flags continuam tendo precedencia e `parseArgs` antigo permanece para testes/caminhos existentes.
- Limite deliberado: parser nao implementa TOML completo; aceita somente o subset operacional do config atual. Expandir quando surgir necessidade real de tabelas/listas.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `phenom chat --prompt oi` com config temporario `offline = true` deve retornar stub offline sem tocar rede.
- Help lista origem do config e chaves aceitas.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/config_file.zig -lc` -> passou; 8 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- Smoke runtime em `/tmp/phenom-config-smoke/config.toml` com `offline = true`, sem flag `--offline`: `/home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/zig-out/bin/phenom chat --prompt oi` -> passou; exibiu `[offline stub] model not called`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou `/home/ashirak/.local/bin/phenom` e `/home/ashirak/.config/phenom/config.toml`.
- `/home/ashirak/.local/bin/phenom version` -> passou; exibiu `phenom-zig 0.2.0-dev`.

## T243 - Persistir estatisticas de inferencia no replay SQLite

Status: implemented-verified.

Motivacao: depois da troca para footer `Worked for {time}`, o turno ao vivo mostrava a duracao correta, mas a recuperacao da sessao reconstruia o fim do turno sem o tempo original. Isso fazia o replay perder um dado operacional pertinente ao uso do agente e degradava a confiabilidade auditavel da sessao.

Evidencia:

- `phenom-zig/src/main.zig`: `runChatTurnWithUi` gravava `turn_done` com corpo fixo `ok`, sem `elapsed_ms`.
- `phenom-zig/src/main.zig`: `renderRestoredSession` recebia `turn_done` e emitia `think_end`, forçando o `RendererEventSink` a calcular tempo novo durante replay.
- `phenom-zig/src/ui_events.zig`: `RendererEventSink` ja sabia formatar `Worked for`, mas nao aceitava metadado persistido.
- Smoke SQLite antes da mudanca teria apenas `turn_done|ok`, insuficiente para reproduzir duracao do turno.

Impacto esperado:

- Cada turno novo grava `turn_done` como `status=<status> elapsed_ms=<N>`.
- Replay usa `elapsed_ms` persistido para renderizar `Worked for` com o mesmo tempo logico do turno original.
- Sessoes antigas com `turn_done = ok` continuam restaurando; nesse caso o footer cai no comportamento legado sem metadado.
- Erros de modelo e falhas de expectativa tambem fecham o turno com `turn_done` e duracao, em vez de depender de fechamento visual sem stats.

Teste primeiro:

- Teste de restore SQLite deve gravar `turn_done` com `elapsed_ms=1234` e exigir `Worked for 1s` no transcript.
- Parser de `elapsed_ms` deve aceitar corpo novo e retornar `null` para corpo legado `ok`.
- Smoke runtime deve mostrar `turn_done|status=ok elapsed_ms=N` no SQLite.
- Replay TTY com `elapsed_ms=1234` deve renderizar `Worked for 1s`.

Implementacao:

- `phenom-zig/src/ui_events.zig`: adicionar evento de dominio `turn_done` com `elapsed_ms` opcional.
- `phenom-zig/src/ui_events.zig`: manter `think_end` para compatibilidade, mas concentrar o fechamento em `finish`.
- `phenom-zig/src/ui_events.zig`: expor `monotonicMillis`, `elapsedMillisSince` e `formatElapsedMillis`.
- `phenom-zig/src/main.zig`: medir inicio do turno em `runChatTurnWithUi`.
- `phenom-zig/src/main.zig`: adicionar `recordAndEmitTurnDone`, gravando `status` e `elapsed_ms` antes de emitir o fechamento.
- `phenom-zig/src/main.zig`: trocar sucesso, erro de modelo e falha de expectativa para `recordAndEmitTurnDone`.
- `phenom-zig/src/main.zig`: parsear `elapsed_ms` no replay e emitir `turn_done` com o valor persistido.

Passos de implementacao:

1. Adicionar evento `turn_done` no event bus.
2. Fazer renderer sink aceitar elapsed persistido.
3. Gravar `elapsed_ms` no SQLite no fim do turno.
4. Atualizar replay para consumir `elapsed_ms`.
5. Preservar compatibilidade com sessoes antigas.
6. Rodar unitarios, release e smoke SQLite/replay.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: `recordAndEmitTurnDone` aloca apenas o corpo do evento na stack do turno via allocator e libera com `defer`.
- SQLite: schema nao muda; `turn_done` continua evento logico, agora com corpo chave-valor.
- Compatibilidade: `parseElapsedMs("ok")` retorna `null`; sessoes antigas nao quebram.
- Tempo: usa `CLOCK_MONOTONIC` via helper existente; `elapsed_ms` e gravado como inteiro decimal.
- Replay: `model_error` e `expectation_failed` deixam o turno aberto ate `turn_done`; sessoes antigas sem `turn_done` fecham no fallback de fim do replay.
- Atualizacao 2026-07-09: tokens/throughput reais agora sao persistidos como `token_usage` final quando o backend fornece contadores reais; sem estimativa.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- SQLite de uma sessao nova contem `turn_done|status=ok elapsed_ms=N`.
- Replay de sessao com `elapsed_ms=1234` mostra `Worked for 1s`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `/home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/zig-out/bin/phenom chat --session elapsed-smoke --offline --no-color --prompt oi` em `/tmp/phenom-elapsed-smoke` -> passou; gravou sessao offline.
- `sqlite3 .phenom-zig/phenom.db "select kind, body from events where session='elapsed-smoke' order by id;"` -> mostrou `turn_done|status=ok elapsed_ms=1`.
- Replay TTY da sessao com `turn_done` alterado para `status=ok elapsed_ms=1234` -> passou; transcript restaurado mostrou `Worked for 1s`.

## T244 - Recuperar Worked for em sessao alvo legada

Status: implemented-verified.

Motivacao: a persistencia de `elapsed_ms` resolvia sessoes novas, mas uma sessao alvo criada antes da T243 ainda tinha `turn_done=ok`. Ao recuperar esse historico, o replay nao tinha o metadado novo e renderizava `Worked for 0s`, mesmo havendo `created_at` suficiente no SQLite para derivar a duracao aproximada do turno.

Evidencia:

- `phenom-zig/src/audit.zig`: `loadSessionEvents` carregava apenas `kind` e `body`; descartava `created_at`.
- `phenom-zig/src/main.zig`: `parseElapsedMs("ok")` retorna `null`; sem fallback, o `RendererEventSink` calcula duracao no momento do replay.
- Smoke de sessao alvo legada com `turn_start` em `14:00:00` e `turn_done=ok` em `14:00:02` inicialmente restaurou `Worked for 0s` com binario anterior ao fallback.

Impacto esperado:

- Sessoes novas continuam usando `elapsed_ms` persistido em `turn_done`.
- Sessoes legadas sem `elapsed_ms` passam a derivar duracao por `created_at` de `turn_start` e `turn_done`.
- Se timestamps estiverem ausentes ou inconsistentes, o replay cai para comportamento anterior sem quebrar a sessao.
- O replay continua renderizando texto atual, nao salva footer bruto.

Teste primeiro:

- Helper `restoredElapsedMs("ok", 100, 102)` deve retornar `2000`.
- Helper deve retornar `null` se `turn_done` vier antes de `turn_start`.
- Smoke TTY com SQLite legado controlado deve restaurar `Worked for 2s`.

Implementacao:

- `phenom-zig/src/audit.zig`: adicionar `created_at_unix_s` em `AuditEvent`.
- `phenom-zig/src/audit.zig`: `loadSessionEvents` passa a selecionar `cast(strftime('%s', created_at) as integer)`.
- `phenom-zig/src/main.zig`: guardar timestamp do `turn_start` durante replay.
- `phenom-zig/src/main.zig`: adicionar `restoredElapsedMs`, com precedencia para `elapsed_ms` real e fallback para diferenca de timestamps.
- `phenom-zig/src/main.zig`: usar `restoredElapsedMs` ao emitir `turn_done` restaurado.

Passos de implementacao:

1. Carregar timestamp junto dos eventos SQLite.
2. Propagar timestamp sem alterar schema.
3. Criar fallback por diferenca `turn_done.created_at - turn_start.created_at`.
4. Cobrir helper com teste.
5. Validar sessao legada real em TTY.
6. Reinstalar binario em `~/.local/bin`.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: `created_at_unix_s` e escalar; nao adiciona alocacao nem libera extra.
- SQLite: schema permanece intacto; query usa `strftime` sobre coluna existente.
- Compatibilidade: `elapsed_ms` no corpo do `turn_done` tem precedencia sobre timestamp derivado.
- Precisao: fallback legado tem precisao de segundos porque `created_at` antigo usa `current_timestamp`; aceitavel para recuperar sessoes alvo antigas.
- Erros: timestamp ausente, nulo ou invertido retorna `null`, sem crash e sem duracao falsa negativa.
- Escopo: nao tenta reescrever eventos antigos no banco; apenas melhora o replay.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Sessao legada com `turn_done=ok` e timestamps diferentes restaura `Worked for Ns`.
- Binario instalado em `~/.local/bin/phenom` recebe a correcao.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- SQLite legado em `/tmp/phenom-legacy-elapsed/.phenom-zig/phenom.db` com `turn_start` `2026-07-05 14:00:00`, `turn_done=ok` `2026-07-05 14:00:02` -> replay TTY mostrou `Worked for 2s`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; reinstalou `/home/ashirak/.local/bin/phenom`.

## T245 - Instalar config.toml sem sobrescrever valores do usuario

Status: implemented-verified.

Motivacao: `zig build install-local` copiava `../config.toml` diretamente para `~/.config/phenom/config.toml`. A cada atualizacao do binario, qualquer configuracao real do usuario era perdida. O fluxo correto e criar o config quando ele nao existe; quando existe, aplicar atualizacoes da base do template, como novos parametros e comentarios, preservando os valores ativos do usuario.

Evidencia:

- `phenom-zig/build.zig`: `install-local` executava `install -Dm644 ../config.toml "$HOME/.config/phenom/config.toml"`, sobrescrevendo o arquivo de destino.
- Config instalado real continha customizacao (`host = "inference.local"`, `thinking = "on"`), que seria perdida em qualquer update simples por copia direta.
- `config.toml`: template precisa continuar podendo evoluir com comentarios e chaves novas.

Impacto esperado:

- Primeira instalacao cria `~/.config/phenom/config.toml` a partir do template.
- Instalacoes futuras usam o template atual como base estrutural e preservam valores ativos do usuario para chaves existentes.
- Chaves novas do template entram no arquivo instalado.
- Chaves customizadas do usuario que nao existem no template sao preservadas no fim do arquivo.
- Se o merge gerar conteudo identico, o arquivo nao e regravado.

Teste primeiro:

- Merge em destino inexistente deve criar config igual ao template.
- Merge em destino com `backend`, `host`, `port`, `model` customizados deve preservar esses valores.
- Template novo com chave adicional deve inserir a chave adicional.
- Chave customizada do usuario deve ser mantida em bloco final.
- `install-local` real deve preservar `host = "inference.local"` e `thinking = "on"` no config instalado.

Implementacao:

- `phenom-zig/tools/merge_config.sh`: criar script POSIX shell/awk sem dependencia de gawk.
- `merge_config.sh`: detectar linhas ativas `key = value`, ignorando comentarios e linhas vazias.
- `merge_config.sh`: imprimir o template novo, substituindo valores das chaves que ja existem no arquivo do usuario.
- `merge_config.sh`: anexar chaves ativas do usuario que nao existem no template sob um bloco de preservacao.
- `merge_config.sh`: comparar temp e destino com `cmp -s` antes de mover, evitando rewrite desnecessario.
- `phenom-zig/build.zig`: trocar copia direta de config por `sh tools/merge_config.sh ../config.toml "$HOME/.config/phenom/config.toml"`.

Passos de implementacao:

1. Criar script de merge pequeno e auditavel.
2. Remover dependencia de `ARGIND` para compatibilidade com awk comum.
3. Ligar script ao `install-local`.
4. Testar criacao inicial em `/tmp`.
5. Testar preservacao de valores e chave customizada em `/tmp`.
6. Rodar build/test/release.
7. Rodar `install-local` real e inspecionar config instalado.

Revisao baixo nivel obrigatoria antes do commit:

- I/O: script escreve em arquivo temporario no mesmo diretorio e usa `mv` atomico dentro do filesystem.
- Falhas: `set -eu` e `trap` removem temp em erro.
- Compatibilidade: usa POSIX shell e awk basico; nao depende de gawk.
- Preservacao: valores ativos do usuario vencem valores do template; comentarios/base do template vencem comentarios antigos.
- Limite deliberado: comentarios customizados soltos do usuario nao sao preservados, porque nao ha marcador confiavel para diferenciar comentario antigo da base de comentario escrito pelo usuario.

Criterio de aceite:

- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Merge em `/tmp` preserva valores do usuario e adiciona chave nova do template.
- `install-local` nao sobrescreve valores existentes no config real.

Validacao executada:

- `sh phenom-zig/tools/merge_config.sh /tmp/phenom-config-merge-test/template.toml /tmp/phenom-config-merge-test/config.toml` em destino inexistente -> criou config igual ao template.
- Merge com destino contendo `backend = "ollama"`, `host = "192.168.1.122"`, `port = 11435`, `model = "custom:model"` e `custom_knob = "keep-me"` + template com `new_param = true` -> preservou valores do usuario, adicionou `new_param = true` e anexou `custom_knob`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- `/home/ashirak/.config/phenom/config.toml` apos install manteve `host = "inference.local"` e `thinking = "on"`.

## T246 - Fechar contrato Codex-like do terminal Zig

Status: implemented-verified.

Motivacao: as tasks Codex-like anteriores tinham implementado blocos essenciais, mas ainda nao estavam 100% como contrato operacional. O desvio mais visivel era o ciclo de tools: `TOOL_START` anunciava a tool e `TOOL_RESULT` reimprimia outro anuncio antes do resultado. Isso deixava o transcript menos parecido com Codex/phenom-cli-ts, poluia replay SQLite e quebrava a leitura append-only.

Evidencia:

- `phenom-zig/src/ui_events.zig`: `tool_result` chamava `toolSampleWithDetail(result.name, "", result.output)`, duplicando `▸ Reading`/`▸ Running`.
- `phenom-zig/src/render.zig`: so havia API publica combinada `toolSampleWithDetail`; nao existia contrato separado para start, output e failure.
- `phenom-zig/src/main.zig`: demo tool nao mudava a statusbar para `Reading`, apesar do TS mudar o op label conforme tool ativa.
- T240 ja tinha snapshot amplo, mas nao provava lifecycle start/result sem duplicacao.

Impacto esperado:

- Tool lifecycle fica Codex-like: um anuncio `▸ Running/Reading/Patching`, depois stdout/evidence/erro no mesmo bloco.
- `TOOL_RESULT` nao duplica o anuncio.
- Erro de tool aparece como `✗ resumo`, com primeira linha truncada para evitar despejo bruto.
- Statusbar TUI passa por `Thinking -> Reading -> Thinking/Responding` no fluxo de tool atual.
- Replay SQLite herda o mesmo contrato porque reemite `tool_start` e `tool_result`.

Teste primeiro:

- Snapshot de `toolStart + toolOutput` deve conter um unico `▸ Running`.
- Snapshot de `toolFailure` deve renderizar `✗ compile failed`.
- Snapshot completo Codex-like deve usar start/result separados.
- Teste de restore SQLite deve garantir `▸ Reading` uma vez.
- PTY com `--demo-read-file` deve mostrar statusbar `Reading` e transcript sem duplicar tool.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar `toolStart`, `toolOutput` e `toolFailure`.
- `phenom-zig/src/render.zig`: manter `toolSampleWithDetail` como wrapper de compatibilidade.
- `phenom-zig/src/render.zig`: adicionar helper `firstLine` para erro curto e `countNeedle` para teste.
- `phenom-zig/src/ui_events.zig`: mapear `tool_start` para `toolStart`.
- `phenom-zig/src/ui_events.zig`: mapear `tool_result` para `toolOutput` ou `toolFailure`.
- `phenom-zig/src/ui_events.zig`: mapear `tool_error` para start opcional + failure.
- `phenom-zig/src/main.zig`: durante `demo_read_file`, statusbar muda para `Reading` enquanto a tool executa e volta para `Thinking`.
- `phenom-zig/src/main.zig`: restore test passa a validar que `▸ Reading` aparece uma vez.

Passos de implementacao:

1. Separar API de tool start/result/failure no renderer.
2. Atualizar event sink para usar lifecycle separado.
3. Atualizar snapshot Codex-like completo.
4. Adicionar snapshots de lifecycle e erro.
5. Conectar statusbar `Reading` no fluxo de tool atual.
6. Validar replay SQLite sem tool duplicada.
7. Rodar unitarios, release e smoke PTY.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria/lifetime: nenhuma alocacao nova no renderer/event sink; helpers operam sobre slices existentes.
- Bounds: `firstLine` limita erro a 200 bytes e corta somente por indice de linha; erro UTF-8 muito longo pode truncar por byte no limite, aceitavel para resumo de falha atual.
- Terminal: tool output continua usando gutter append-only e `NewlineWriter` no TUI raw.
- Concorrencia: statusbar usa os metodos TUI existentes e mutex interno; renderer segue protegido pelo `RendererEventSink`.
- Compatibilidade: `toolSampleWithDetail` permanece para testes/callers antigos.
- Limite deliberado: markdown renderer rico ainda nao entra; o contrato fechado aqui e o Codex-like operacional de transcript, tools, diff, prompt, statusbar e replay.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke `--demo-read-file` mostra um unico `▸ Reading`.
- PTY interativo mostra statusbar `Thinking -> Reading -> Thinking` e prompt permanente.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 19 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --offline --no-color --prompt 'analise' --demo-read-file src/main.zig --session codex-like-smoke` -> passou; transcript exibiu um unico `▸ Reading: src/main.zig` e evidence no mesmo bloco.
- PTY `./zig-out/bin/phenom chat --offline --no-color --demo-read-file src/main.zig --session codex-like-pty`, input `analise` + `/exit` -> passou; statusbar mostrou `Thinking`, depois `Reading`, depois `Thinking`, transcript permaneceu alinhado e prompt foi restaurado.

## T247 - Renderizar Markdown completo para output de agente de codigo no Zig

Status: implemented-verified.

Motivacao: o contrato Codex-like ainda estava incompleto porque `assistantDelta` escrevia texto bruto. Isso deixava respostas reais com Markdown visivelmente inferiores ao `phenom-cli-ts`: headings, listas, links, tabelas, fences de codigo e diffs apareciam como texto cru ou sem enquadramento. Para um agente focado em codigo, o renderer precisa transformar Markdown em transcript terminal legivel, copiavel e append-only.

Evidencia:

- `../phenom-cli-ts/src/stream-markdown-renderer.ts` implementa renderer incremental com linhas pendentes, fences, diff, tabelas, heading/lista/blockquote/hr, inline markdown e highlight por linguagem.
- `../phenom-cli-ts/src/cli-renderer.ts:800-804` renderiza conteudo restaurado pelo `StreamMarkdownRenderer`, entao historico tambem recebe o mesmo visual.
- `phenom-zig/src/render.zig` antes desta task chamava `writeContentStream` em `assistantDelta`, portanto nao havia parse Markdown no caminho principal do chat nem no replay que reemite `message_chunk`.
- Smoke real com prompt pedindo Markdown exigia que o caminho HTTP -> `assistantDelta` renderizasse `#`, bullets e fence `zig`, nao que o modelo entregasse texto ja estilizado.

Impacto esperado:

- Output do assistant passa a renderizar Markdown operacional completo para codigo: headings, bullets, listas numeradas, blockquotes, horizontal rules, links, inline code, bold, fenced code, fenced diff/patch, tabelas e highlight lexical basico.
- Fences de codigo usam gutter `│`, preservando blocos copiaveis e alinhados.
- Diffs dentro de Markdown usam cor/marker suave e nao usam background red/green saturado.
- Tabelas Markdown sao bufferizadas e emitidas como caixas terminal compactas.
- Streaming simples continua aparecendo imediatamente; chunks plain text nao ficam presos ate `[done]`.
- Chunks Markdown incompletos ficam pendentes ate newline ou fechamento do bloco, evitando vazar `**`, crases e tabelas quebradas.
- Replay SQLite que reemite `message_chunk` recebe o mesmo renderer, sem precisar salvar output ja formatado.

Teste primeiro:

- Snapshot de heading/lista/link/fence `zig` prova que marcadores Markdown nao vazam como texto cru.
- Snapshot de fence `diff` prova `@@`, `-old`, `+new` e ausencia de backgrounds saturados.
- Snapshot de tabela prova bordas `┌`, `├`, `└` e celulas alinhadas.
- Snapshot de streaming split prova que texto plain aparece imediatamente e Markdown incompleto so aparece formatado no flush.
- Snapshot de newline plain prova que streaming imediato nao adiciona gutter fantasma no fim da linha.
- Suite antiga de thinking/tool/diff/statusbar continua passando, provando que a mudanca nao quebrou o contrato Codex-like anterior.
- Smoke real com llama.cpp/Ollama compativel prova o caminho modelo -> renderer.

Implementacao:

- `phenom-zig/src/render.zig`: `assistantDelta` passa a chamar `writeMarkdownStream`.
- `render.zig`: adicionar buffer fixo de linha Markdown (`8192` bytes), estado de fence, linguagem do fence e buffer fixo de tabela (`8192` bytes).
- `render.zig`: implementar parser incremental por linhas completas, com flush em `closeOpenBlocks`.
- `render.zig`: streaming plain text sem marcadores Markdown continua usando `writeContentStream` para nao congelar respostas simples.
- `render.zig`: implementar heading/lista/blockquote/hr/diff solto/prosa inline.
- `render.zig`: implementar inline `**bold**`, `` `code` `` e `[label](url)` sem deixar marcadores no transcript.
- `render.zig`: implementar fences genericos com gutter `│` e highlight lexical simples para keywords, strings, numeros, comentarios e chamadas de funcao.
- `render.zig`: implementar fence `diff`/`patch` com cores por linha `+`, `-`, `@@` e sem background saturado.
- `render.zig`: implementar tabela Markdown com deteccao de linhas `|`, separador `---`, calculo de largura visivel e bordas terminal.
- `render.zig`: corrigir ciclo de inferencia Zig entre `writeInlineMarkdown` e `writeBoldInlineMarkdown` usando error set explicito.
- `render.zig`: adicionar helper `trimLeft` porque Zig 0.16 nao expoe `std.mem.trimLeft`.

Passos de implementacao:

1. Comparar o comportamento esperado com `StreamMarkdownRenderer` do TS.
2. Trocar somente a entrada de assistant output para Markdown stream.
3. Adicionar buffers fixos e estados de Markdown no renderer append-only.
4. Implementar renderizacao estrutural antes de inline.
5. Implementar fences de codigo e diff.
6. Implementar tabelas bufferizadas.
7. Restaurar streaming imediato para plain text.
8. Adicionar snapshots de Markdown de codigo.
9. Rodar render isolado, build completo e smoke real.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: buffers sao arrays fixos dentro do renderer; nao ha alocacao dinamica no caminho Markdown.
- Bounds: todo append verifica capacidade antes de copiar; linhas maiores que o buffer caem para render bruto/gutter em vez de overflow.
- Lifetime: slices de tabela/linha sao usados antes de limpar buffers; nada e armazenado fora do renderer.
- UTF-8: avanco visual usa `utf8ByteLen`; nao tenta validar Unicode completo, mas evita quebrar bytes ASCII por indice em loops principais.
- Error set: recursao inline/bold usa `anyerror!void` para impedir `dependency loop` no Zig.
- Terminal: renderer segue append-only; nao entra em alternate screen e nao faz repaint.
- Compatibilidade: APIs publicas anteriores (`assistantDelta`, `done`, `tool*`) nao mudaram.
- Limite deliberado: nao e um parser CommonMark academico; cobre o Markdown necessario para output real de agente de codigo. Extensoes futuras devem entrar com snapshot antes de feature.

Criterio de aceite:

- `zig test src/render.zig -lc` passa com snapshots Markdown.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real renderiza titulo, lista e bloco `zig` sem deixar `#`, `-` e fence como ruido bruto.
- Nenhum background ANSI red/green saturado aparece em diff Markdown.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 24 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --no-color --max-tokens 160 --prompt 'responda em markdown curto com: um titulo, uma lista e um bloco de codigo zig com const ok = true'` -> passou; transcript renderizou heading, bullets `•` e fence `zig` com gutter `│`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o renderer atualizado em `~/.local/bin/phenom`.

## T248 - Portar paleta de codigo e diff do `phenom-cli-ts` para Markdown Zig

Status: implemented-verified.

Motivacao: a T247 renderizava a estrutura Markdown, mas o codigo e o diff ainda nao tinham a mesma coloracao do `phenom-cli-ts`. O Zig usava ANSI basico (`31/32/33/36`) e diff sem background pastel. Visualmente isso nao batia com o renderer TS, que usa paleta hex 24-bit derivada do tema do usuario e backgrounds suaves em diff fenced.

Evidencia:

- `../phenom-cli-ts/src/stream-markdown-renderer.ts`: define `C.keyword = #a48ec7`, `C.string = #7fa98f`, `C.number = #cfa06e`, `C.fn = #7a9cc6`, `C.type = #7fb2c9`, `C.comment = #5f6a72`, `C.text = #9aa6b2`, `C.preproc = #d4b97a`.
- `../phenom-cli-ts/src/stream-markdown-renderer.ts`: diff fenced usa `#edf8f0` para adicoes e `#fff0f0` para remocoes, sem `bgGreen`/`bgRed` saturado.
- `phenom-zig/src/render.zig`: antes desta task, fences e highlighter usavam `writeYellowBold`, `writeGreen`, `writeCyan` e `writeRed`, sem ANSI 24-bit.
- Smoke real colorido mostrou que o caminho precisava emitir `38;2`/`48;2`, nao apenas render estrutural.

Impacto esperado:

- Fences de codigo passam a usar gutter cyan dim, backticks em `#d4b97a` e linguagem em `#7a9cc6`.
- Keywords, strings, numeros, funcoes, tipos, comentarios e texto base usam a mesma familia visual do TS.
- Diff fenced passa a usar background pastel em adicoes/remocoes e foreground especifico no gutter.
- Continua proibido background saturado ANSI `41/42`.
- Modo `--no-color` continua imprimindo texto limpo, porque os helpers 24-bit respeitam `options.color`.

Teste primeiro:

- Teste ANSI de code fence exige sequencias `38;2;212;185;122`, `38;2;122;156;198`, `38;2;164;142;199` e `38;2;127;169;143`.
- Teste ANSI de diff fenced exige `48;2;237;248;240` para `+new` e `48;2;255;240;240` para `-old`.
- Teste diff confirma ausencia de `\x1b[41` e `\x1b[42`.
- Teste de fence com linguagem separada por espaco prova que ` ``` ts` renderiza `ts` uma vez.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar struct `Rgb` e constantes da paleta TS.
- `render.zig`: adicionar `writeRgb`, `writeRgbBg`, `writeRgbFgBg` e `writeCyanDim`.
- `render.zig`: renderizar fence com partes separadas: gutter, backticks, lang e resto.
- `render.zig`: trocar highlight generico para tons TS por categoria.
- `render.zig`: trocar diff fenced para background pastel e gutter com fg/bg.

Passos de implementacao:

1. Ler a paleta e regras de diff em `stream-markdown-renderer.ts`.
2. Portar apenas os tons necessarios para o renderer Zig atual.
3. Adicionar testes ANSI exatos para code e diff.
4. Rodar renderer isolado.
5. Rodar build completo e release.
6. Rodar smoke real colorido com Markdown contendo code e diff.
7. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem alocacao nova; helpers escrevem direto no writer.
- Bounds: `writeFenceLine` usa slices calculadas sobre a linha atual; fence sem lang cai para texto restante; fence com espaco antes da linguagem usa `fenceLangStart` para nao duplicar bytes.
- ANSI: helpers respeitam `options.color`; modo plain nao recebe escape.
- Terminal: ANSI 24-bit e background pastel sao append-only; nao usam cursor movement.
- Compatibilidade: highlighter continua lexical simples; nao tenta portar todo regex engine do TS nesta task.
- Limite deliberado: a cobertura e por categoria visual principal, nao por todos os dialetos (`html/css/json/yaml/sql`) do TS; esses devem entrar com fixtures dedicadas quando forem exigidos.

Criterio de aceite:

- `zig test src/render.zig -lc` passa com testes de paleta 24-bit.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real colorido mostra sequencias ANSI `38;2` em codigo e `48;2` em diff.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 27 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 180 --prompt 'responda somente este markdown: ```ts\nconst value = "ok";\nrun(value);\n```\n```diff\n-old\n+new\n```'` -> passou; transcript emitiu `38;2` para code e `48;2` para diff pastel.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T249 - Tornar diff Markdown legivel com foreground explicito estilo Codex

Status: implemented-verified.

Motivacao: a T248 corrigiu a paleta, mas manteve um erro de legibilidade: o conteudo das linhas `+` e `-` recebia apenas background pastel. A cor do texto ficava dependente do tema do terminal. Em alguns temas, o diff ficava fraco ou invisivel para humanos. O comportamento desejado e codex-like: fundo de destaque e texto com foreground explicito escuro/legivel.

Evidencia:

- `phenom-zig/src/render.zig`: em `writeCodeLine`, o gutter usava `writeRgbFgBg`, mas a linha usava `writeRgbBg(diff_add_bg, line)` e `writeRgbBg(diff_del_bg, line)`.
- Smoke real mostrava `\x1b[48;2;237;248;240m+new` e `\x1b[48;2;255;240;240m-old`, sem `38;2` no conteudo.
- O usuario reportou que a coloracao do diff nao era visivel ao humano e pediu coloracao como Codex, com background e texto visivel.

Impacto esperado:

- Linhas adicionadas usam foreground verde escuro `#2f6f45` sobre background `#edf8f0`.
- Linhas removidas usam foreground vermelho escuro `#8a3030` sobre background `#fff0f0`.
- Gutter e conteudo da linha usam o mesmo par foreground/background.
- Background ANSI saturado `41/42` continua proibido.
- Modo `--no-color` continua sem ANSI.

Teste primeiro:

- Teste ANSI de diff fenced exige `38;2;47;111;69;48;2;237;248;240m+new`.
- Teste ANSI de diff fenced exige `38;2;138;48;48;48;2;255;240;240m-old`.
- Teste continua exigindo ausencia de `\x1b[41` e `\x1b[42`.

Implementacao:

- `phenom-zig/src/render.zig`: trocar `writeRgbBg(diff_add_bg, line)` por `writeRgbFgBg(diff_add_fg, diff_add_bg, line)`.
- `phenom-zig/src/render.zig`: trocar `writeRgbBg(diff_del_bg, line)` por `writeRgbFgBg(diff_del_fg, diff_del_bg, line)`.
- `phenom-zig/src/render.zig`: renomear o teste de diff para explicitar foreground/background legivel.

Passos de implementacao:

1. Localizar o ponto exato onde o conteudo `+/-` recebia apenas background.
2. Aplicar foreground/background no conteudo inteiro.
3. Endurecer asserts ANSI.
4. Rodar renderer isolado.
5. Rodar build completo e release.
6. Rodar smoke real colorido com diff fenced.
7. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem alocacao nova.
- ANSI: foreground/background sao emitidos em uma unica sequencia por trecho, reduzindo estado parcial do terminal.
- Terminal: reset continua apos cada trecho, evitando vazamento de background para linhas seguintes.
- Compatibilidade: modo sem cor preserva texto puro.
- Escopo: altera apenas diff fenced em Markdown; diff preview standalone continua com sua paleta propria.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real mostra `38;2;...;48;2` tanto no gutter quanto no conteudo `+/-`.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 27 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 120 --prompt 'responda somente este markdown: ```diff\n-old\n+new\n```'` -> passou; transcript mostrou `38;2;138;48;48;48;2;255;240;240m-old` e `38;2;47;111;69;48;2;237;248;240m+new`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T250 - Adicionar padding vertical pequeno no bloco de user query

Status: implemented-verified.

Motivacao: o bloco de user query no output estava compacto demais: a linha `> [user] ...` ficava colada nas bordas verticais da bubble. O usuario pediu um espacamento vertical pequeno no output. A cor e largura do bloco devem permanecer iguais ao visual do `phenom-cli-ts`; a mudanca e apenas padding interno.

Evidencia:

- `phenom-zig/src/render.zig`: `user()` escrevia `\n`, a linha de query e depois `\n\n`, sem linha pintada vazia antes/depois da query.
- Snapshots `append only snapshot`, `codex style append only turn snapshot` e `ansi user bubble` provavam a bubble de uma unica linha.
- Smoke offline mostrava que o texto do usuario ficava visualmente apertado quando comparado ao restante do transcript.

Impacto esperado:

- User query passa a ter uma linha vazia pintada acima e uma abaixo do texto.
- A bubble continua append-only, copiavel e sem cursor movement.
- Em `--no-color`, o padding vira linhas de espaco; em TTY colorido, vira area pintada com `USER_BG/USER_FG`.
- Prompt fixo/statusbar nao muda; so o transcript de user message muda.

Teste primeiro:

- Snapshot plain do turno passa a exigir linha vazia antes/depois de `> [user]`.
- Snapshot amplo Codex-like passa a exigir o padding no primeiro bloco.
- Snapshot ANSI exige `USER_BG/USER_FG` nas linhas vazias.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar `writeUserBlankLine`.
- `render.zig`: `user()` chama `writeUserBlankLine()` antes e depois de `writeWrappedUserLine`.
- `render.zig`: atualizar snapshots afetados.

Passos de implementacao:

1. Localizar o render do user block.
2. Adicionar helper pequeno reaproveitando `userInnerWidth`.
3. Inserir padding vertical interno.
4. Atualizar snapshots.
5. Rodar renderer isolado, build completo, release e smoke offline.
6. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem alocacao nova.
- Bounds: usa `userInnerWidth() + 1`, mesmo tamanho visual da linha pintada atual.
- Terminal: nao usa cursor movement, alternate screen ou repaint.
- Compatibilidade: multiline/wrap continua passando pelo mesmo `writeWrappedUserLine`.
- Escopo: nao altera prompt row fixo nem statusbar.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke offline mostra user block com respiro vertical.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 27 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --offline --no-color --prompt 'oi'` -> passou; transcript renderizou user block com linha vazia acima e abaixo da query.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T251 - Renderizar diff Markdown com numero de linha, marcador e pipe estrutural

Status: implemented-verified.

Motivacao: mesmo depois da cor legivel, o diff Markdown ainda nao parecia um diff operacional. A coloracao ficava aplicada sobre o `│`, que deveria ser estrutura, e o conteudo aparecia como `+new`/`-old` cru, sem coluna de numero de linha nem marcador de edicao separado. O comportamento correto e codex-like: `lineNo marker │ text`, onde numero/marcador/texto recebem cor e o pipe fica como separador estrutural.

Evidencia:

- `phenom-zig/src/render.zig`: `writeCodeLine` em diff fenced escrevia `│ ` com foreground/background e depois a linha inteira `+new`/`-old` tambem com foreground/background.
- `../phenom-cli-ts/src/cli-renderer.ts:2774-2829`: render de file diff usa formato `N marker │ text`, com line number, marcador e pipe separados.
- Smoke real anterior mostrava `│ ` colorido com background e sem numeros/sinais em colunas separadas.

Impacto esperado:

- Diff fenced em Markdown passa a renderizar linhas editadas como `   7 - │ old` e `   9 + │ new`.
- O hunk `@@ -7,2 +9,2 @@` define os numeros iniciais.
- Context lines incrementam old/new e aparecem como `  10   │ same`.
- O `│` nao recebe background de add/remove; fica dim/estrutural.
- Sinal `+`/`-` fica em coluna propria e colorida.
- Conteudo nao inclui mais o sinal cru; `+new` vira `+ │ new`.

Teste primeiro:

- Teste plain exige `   7 - │ old`, `   9 + │ new`, `  10   │ same`.
- Teste plain garante ausencia de `-old` e `+new`.
- Teste ANSI garante que `│ ` nao recebe `fg+bg` de add/remove.
- Suite antiga de Markdown/diff continua passando.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar estado `markdown_diff_old_line` e `markdown_diff_new_line`.
- `render.zig`: resetar estado ao abrir/fechar fence `diff`/`patch`.
- `render.zig`: adicionar `parseUnifiedHunk` para extrair old/new start de `@@ -a,b +c,d @@`.
- `render.zig`: substituir render bruto de `+/-` por `writeMarkdownDiffEditLine`.
- `render.zig`: adicionar `writeDiffLineNumber` e `writeDimLineNumber`.
- `render.zig`: manter file headers e hunk headers como linhas estruturais sem coluna falsa de edicao.

Passos de implementacao:

1. Comparar comportamento atual com `renderFileDiff` do TS.
2. Adicionar estado numerico do diff fenced.
3. Parsear hunk headers.
4. Renderizar add/remove/context com colunas separadas.
5. Atualizar testes ANSI e plain.
6. Rodar renderer isolado, build completo, release e smoke real.
7. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem alocacao; numeros sao escalares no renderer.
- Bounds: parser de hunk anda por indices checados e retorna `null` para formato invalido.
- ANSI: background fica em numero/marcador/texto; pipe usa `writeDim`, sem background.
- Estado: abertura de fence diff inicia old/new em 1; hunk sobrescreve; fechamento limpa estado.
- Compatibilidade: diffs sem hunk ainda recebem numeros a partir de 1.
- Escopo: altera apenas diff fenced Markdown; diff preview standalone permanece como estava.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real sem cor mostra `line marker │ text`.
- Smoke real com cor mostra `│` sem background add/remove.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 28 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --no-color --max-tokens 120 --prompt 'responda somente este markdown: ```diff\n@@ -7,2 +9,2 @@\n-old\n+new\n same\n```'` -> passou; transcript mostrou `7 - │ old`, `9 + │ new`, `10   │ same`.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 120 --prompt 'responda somente este markdown: ```diff\n@@ -7,2 +9,2 @@\n-old\n+new\n```'` -> passou; transcript mostrou ANSI de add/remove no numero, marcador e texto, mas `│` em dim sem background.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T252 - Aplicar syntax highlight do `phenom-cli-ts` no texto do diff Markdown

Status: implemented-verified.

Motivacao: o diff Markdown ja tinha numeros, marcadores e pipe estrutural, mas o texto da linha ainda nao seguia o `phenom-cli-ts`. O conteudo de linhas `+/-` ficava chapado com a cor de add/remove. No TS, o meta do diff usa cor de edicao, mas o texto do codigo preserva syntax highlight por linguagem sobre o background de add/remove.

Evidencia:

- `../phenom-cli-ts/src/cli-renderer.ts:2797-2819`: calcula `codeLang = codeLangFromPath(diff.path)`, aplica `highlightCode(text, codeLang)` e depois envolve o texto com `addBg`/`delBg`.
- `phenom-zig/src/render.zig`: `writeMarkdownDiffEditLine` chamava `writeRgbFgBg(fg, bg, text)`, entao `const`, strings, numeros e funcoes nao recebiam a paleta de codigo.
- Smoke real anterior mostrava o conteudo inteiro em verde/vermelho escuro, nao keywords/strings como no renderer TS.

Impacto esperado:

- File headers `--- a/app.ts`/`+++ b/app.ts` definem a linguagem do diff Markdown.
- Texto de linhas editadas usa syntax highlight por categoria sobre o background de add/remove.
- Numeros e marcadores continuam usando cor de edicao.
- Pipe continua dim/estrutural.
- Sem path conhecido, texto cai para `tone_text` sobre o background, equivalente ao fallback TS.

Teste primeiro:

- Teste ANSI com `app.ts` exige `const` em `#a48ec7` sobre background add/del.
- Teste ANSI exige strings em `#7fa98f` sobre background add/del.
- Teste garante que `const` nao usa a cor verde/vermelha do marcador.
- Testes anteriores de numeros, marker e pipe continuam passando.

Implementacao:

- `phenom-zig/src/render.zig`: adicionar estado `markdown_diff_code_lang`.
- `render.zig`: inferir linguagem a partir de `+++ b/path.ext`/`--- a/path.ext`.
- `render.zig`: adicionar helpers `firstToken`, `stripDiffPathPrefix` e `codeLangFromPath`.
- `render.zig`: extrair `writeHighlightedCodeBg` para reutilizar highlighter com background opcional.
- `render.zig`: `writeMarkdownDiffEditLine` passa a chamar `writeHighlightedDiffText`.
- `render.zig`: context lines tambem usam highlighter quando linguagem e conhecida, mas sem background.

Passos de implementacao:

1. Confirmar comportamento do TS em `renderFileDiff`.
2. Adicionar estado de linguagem no diff Markdown.
3. Inferir linguagem pelos file headers.
4. Reusar highlighter existente com background opcional.
5. Atualizar testes ANSI.
6. Rodar renderer isolado, build completo, release e smoke real.
7. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: estado de linguagem usa array fixo `[24]u8`; sem alocacao.
- Bounds: `codeLangFromPath` e parser de header operam com slices checadas.
- ANSI: cada token recebe foreground e background; reset apos token evita vazamento.
- Fallback: path ausente ou extensao desconhecida nao quebra render, usa `tone_text`.
- Escopo: nao porta todos os regex sofisticados do TS; aplica a paleta/categorias ja existentes no highlighter Zig.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real com `app.ts` mostra `const` e strings com syntax highlight sobre background de diff.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 180 --prompt 'responda somente este markdown: ```diff\n--- a/app.ts\n+++ b/app.ts\n@@ -1 +1 @@\n-const value = "old";\n+const value = "new";\n```'` -> passou; transcript mostrou `const` em `38;2;164;142;199` e strings em `38;2;127;169;143` com background add/del.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T253 - Suavizar background do diff Markdown para o texto continuar sendo o foco

Status: implemented-verified.

Motivacao: depois da T252, o texto do diff preservava syntax highlight, mas o background ainda era forte demais (`#edf8f0` e `#fff0f0`). Isso competia com o proprio codigo. O comportamento desejado e igual ao file diff do `phenom-cli-ts`: background quase branco, meta do diff discreta e syntax highlight como foco principal.

Evidencia:

- `phenom-zig/src/render.zig`: usava `diff_add_bg = #edf8f0`, `diff_del_bg = #fff0f0`, `diff_add_fg = #2f6f45`, `diff_del_fg = #8a3030`.
- `../phenom-cli-ts/src/cli-renderer.ts`: file diff usa `addBg = #f7fbf8`, `delBg = #fff8f8`, `addMeta = #1f7a46`, `delMeta = #a33a3a`.
- Smoke real mostrava background perceptivel demais no conteudo inteiro da linha.

Impacto esperado:

- Background de adicao fica `#f7fbf8`, mais sutil.
- Background de remocao fica `#fff8f8`, mais sutil.
- Numeros e marcadores usam meta `#1f7a46`/`#a33a3a`, seguindo o TS.
- Texto do codigo continua com syntax highlight por linguagem sobre fundo sutil.
- Background antigo forte fica bloqueado por teste.

Teste primeiro:

- Testes ANSI passam a exigir `48;2;247;251;248` e `48;2;255;248;248`.
- Teste garante ausencia de `48;2;237;248;240` e `48;2;255;240;240`.
- Teste de syntax highlight no diff continua exigindo keyword/string com background de diff.

Implementacao:

- `phenom-zig/src/render.zig`: trocar constantes de background e meta do diff para os valores usados no `phenom-cli-ts`.
- `render.zig`: atualizar snapshots ANSI.
- `render.zig`: adicionar asserts anti-regressao contra os backgrounds antigos.

Passos de implementacao:

1. Comparar valores com `phenom-cli-ts/src/cli-renderer.ts`.
2. Trocar constantes Zig.
3. Atualizar asserts ANSI.
4. Rodar renderer isolado, build completo, release e smoke real.
5. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: somente constantes RGB; sem alocacao.
- ANSI: continua usando foreground/background explicitos com reset por token.
- Terminal: pipe segue dim e sem background.
- Compatibilidade: `--no-color` nao muda.
- Escopo: altera apenas diff Markdown, sem tocar no renderer de diff standalone.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real mostra `48;2;247;251;248` e `48;2;255;248;248`, sem os fundos antigos.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 180 --prompt 'responda somente este markdown: ```diff\n--- a/app.ts\n+++ b/app.ts\n@@ -1 +1 @@\n-const value = "old";\n+const value = "new";\n```'` -> passou; transcript mostrou `48;2;247;251;248` e `48;2;255;248;248`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T254 - Simular transparencia no diff Markdown removendo background do texto

Status: implemented-verified.

Motivacao: terminal ANSI nao suporta transparencia real. Mesmo com background mais suave, pintar todo o texto do codigo criava uma faixa visual que ainda competia com a leitura. A simulacao mais pragmatica de transparencia e limitar o background aos metadados do diff (numero e marcador), deixando o texto do codigo com syntax highlight normal.

Evidencia:

- `phenom-zig/src/render.zig`: `writeMarkdownDiffEditLine` passava `bg` para `writeHighlightedDiffText(text, bg)`, aplicando background em cada token do codigo.
- Smoke real mostrava `const`, strings e pontuacao com `48;2` no conteudo inteiro da linha.
- O usuario pediu coloracao "mais transparente", ou seja, menor peso visual no diff.

Impacto esperado:

- Numero de linha e marcador `+/-` continuam com background sutil de diff.
- Pipe continua dim e estrutural.
- Texto do codigo nao recebe background; fica apenas com syntax highlight.
- O diff ainda e identificavel, mas o foco volta para o codigo.

Teste primeiro:

- Testes ANSI garantem que `new`, `old`, `const` e strings nao carregam `48;2`.
- Testes continuam exigindo background nos numeros e marcadores.
- Testes continuam impedindo backgrounds antigos e saturados.

Implementacao:

- `phenom-zig/src/render.zig`: trocar `writeHighlightedDiffText(text, bg)` por `writeHighlightedDiffText(text, null)`.
- `render.zig`: atualizar asserts para syntax highlight sem background no conteudo.
- `render.zig`: renomear teste para `without edit background`.

Passos de implementacao:

1. Confirmar que ANSI nao oferece alpha real.
2. Remover background apenas do conteudo editado.
3. Manter background no meta do diff.
4. Atualizar snapshots ANSI.
5. Rodar renderer isolado, build completo, release e smoke real.
6. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem alocacao nova.
- ANSI: menos sequencias de background no conteudo, menor risco de vazamento visual.
- Acessibilidade: codigo fica mais legivel por preservar contraste do tema.
- Compatibilidade: modo sem cor nao muda.
- Escopo: altera apenas diff Markdown; diff standalone nao muda.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real mostra `48;2` em numeros/marcadores e ausencia de background no texto do codigo.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 180 --prompt 'responda somente este markdown: ```diff\n--- a/app.ts\n+++ b/app.ts\n@@ -1 +1 @@\n-const value = "old";\n+const value = "new";\n```'` -> passou; transcript mostrou background so em numero/marcador e texto do codigo sem `48;2`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T255 - Fazer tint do diff Markdown percorrer a linha inteira com baixo contraste

Status: implemented-verified.

Motivacao: remover o background do texto reduziu o peso visual, mas criou outro problema: a coloracao nao percorria a linha inteira. Terminal ANSI nao tem alpha real, entao a solucao pragmaticamente correta e usar um tint escuro de baixo contraste em toda a linha editada, mantendo o syntax highlight por cima.

Evidencia:

- `phenom-zig/src/render.zig`: T254 chamava `writeHighlightedDiffText(text, null)`, entao o texto e o restante da linha nao tinham background.
- Smoke real mostrava background apenas no numero/marcador.
- O usuario pediu a coloracao menos solida e tambem percorrendo toda a linha.

Impacto esperado:

- Linhas adicionadas usam tint escuro `#0f1d16` em texto e preenchimento ate o fim da largura.
- Linhas removidas usam tint escuro `#231414` em texto e preenchimento ate o fim da largura.
- Syntax highlight continua visivel por cima do tint.
- Numero e marcador continuam com foreground de diff.
- O tint e discreto, nao branco/pastel solido.

Teste primeiro:

- Testes ANSI exigem background `48;2;15;29;22` e `48;2;35;20;20`.
- Testes garantem que o preenchimento final da linha tambem recebe background.
- Testes garantem que o pipe nao recebe background de diff.
- Testes impedem retorno aos fundos claros `#f7fbf8/#fff8f8` e fortes `#edf8f0/#fff0f0`.

Implementacao:

- `phenom-zig/src/render.zig`: trocar constantes do background do diff para tint escuro.
- `render.zig`: `writeMarkdownDiffEditLine` volta a passar `bg` para `writeHighlightedDiffText`.
- `render.zig`: adicionar `writeDiffLineFill` para preencher ate `contentWrapWidth`.
- `render.zig`: adicionar `writeRgbBgSpaces` sem alocacao.
- `render.zig`: adicionar `visibleTextWidth` para calcular preenchimento simples.

Passos de implementacao:

1. Definir tint escuro baixo contraste para add/del.
2. Aplicar tint no texto editado.
3. Preencher restante da linha com o mesmo tint.
4. Atualizar asserts ANSI.
5. Rodar renderer isolado, build completo, release e smoke real.
6. Instalar binario atualizado.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem alocacao; preenchimento usa fatias de string estatica.
- Bounds: `writeDiffLineFill` so escreve se largura usada for menor que `contentWrapWidth`.
- UTF-8: largura visual usa contagem por codepoint simples, suficiente para codigo ASCII/UTF-8 comum.
- ANSI: cada trecho reseta; fill final tambem reseta, evitando vazamento para proxima linha.
- Terminal: background percorre ate a largura de conteudo, nao a ultima coluna do terminal.

Criterio de aceite:

- `zig test src/render.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real mostra tint escuro em texto e preenchimento ate o fim da linha.
- `install-local` passa.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/render.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 180 --prompt 'responda somente este markdown: ```diff\n--- a/app.ts\n+++ b/app.ts\n@@ -1 +1 @@\n-const value = "old";\n+const value = "new";\n```'` -> passou; transcript mostrou `48;2;15;29;22`/`48;2;35;20;20` no texto e no preenchimento final.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou; instalou o binario atualizado em `~/.local/bin/phenom`.

## T256 - Maturar MicroContext e manifesto de contratos/tools antes do tool loop real

Status: implemented-verified.

Motivacao: antes do modelo executar tool call em loop real, o agente precisa de micro-contexto maduro. `collect_evidence` depende de tools internas e estrategias; se o loop vier antes, ele so executa texto bruto e nao cria base segura para patch, replay e anti-vazamento.

Evidencia:

- `phenom-zig/src/micro_context.zig` tinha apenas `path`, `start_line`, `end_line` e `hash`, sem `context_id`, sha do range, registry, budget ou stale check.
- `phenom-zig/src/tool_loop.zig` ja executava `read_file_range`, mas retornava micro-contexto textual simples.
- `../phenom-cli-ts/src/tools/micro-context.ts` prova o desenho necessario: `ctx_*`, sha256 do range, registry limitado, validacao stale e erro reparavel.
- `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts` separa tools model-visible de internal context tools.
- `../phenom-cli-ts/src/tools/registrars/*` lista a superficie real: filesystem, search, context, workflow, git, utility, news, rag, session, project, memory e document.

Impacto esperado:

- Micro-contexto passa a ter `id`, `path`, `range`, `sha256`, `source_tool`, `budget_bytes` e `excerpt` limitado.
- Registry em memoria controla contexts por turno e evita crescimento sem limite.
- Stale context passa a ser detectavel antes de patch ou mutacao.
- Manifesto Zig declara todas as tools relevantes do TS, separando model-visible de internal context.
- Contratos/estrategias iniciais ficam pequenos: `collect_evidence` aceita `auto`, `path`, `lexical`, `symbol`, `diagnostic`, `runtime`, `diff` e `semantic`; news/documentos ficam em perfis proprios, nao em micro-contexto de codigo.

Teste primeiro:

- Teste de render do micro-contexto exige `ctx_`, sha256 de 64 chars, source tool e excerpt limitado por budget.
- Teste de registry exige eviction do registro mais antigo.
- Teste de stale altera arquivo apos criar contexto e exige `StaleMicroContext`.
- Teste de manifesto prova que `collect_evidence` e `apply_patch` sao model-visible.
- Teste de manifesto prova que `grep_file`, `rag_search` e `build_task_context` ficam internal context.
- Teste de estrategia prova que `news_table` nao e estrategia valida de `collect_evidence`.

Implementacao:

- `phenom-zig/src/micro_context.zig`: substituir struct simples por `MicroContext` owned, `Registry`, `fromFileRange`, id sha256 e validacao stale.
- `phenom-zig/src/tools.zig`: adicionar `total_lines` em `FileRange`, contando linhas durante streaming sem manter o arquivo inteiro em memoria.
- `phenom-zig/src/evidence.zig`: ajustar fixture manual de `FileRange` para o novo contrato.
- `phenom-zig/src/contracts.zig`: criar manifesto canonico de tools importado da referencia TS e registry de estrategias por contrato.
- `phenom-zig/src/tool_loop.zig`: gerar `MicroContext` maduro no fluxo offline atual.
- `phenom-zig/src/main.zig`: incluir `contracts.zig` na suite de testes Zig.

Passos de implementacao:

1. Portar semantica de id `ctx_*` e sha256 do range.
2. Garantir ownership completo de strings retornadas.
3. Limitar excerpt por `budget_bytes`.
4. Criar registry com limite e eviction.
5. Validar stale relendo o range atual.
6. Criar manifesto com model-visible/internal-context.
7. Criar estrategias permitidas por contrato.
8. Atualizar tool loop offline para usar o micro-contexto novo.
9. Rodar testes unitarios, build completo e release.
10. Commitar somente arquivos desta task.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `MicroContext` owns `id`, `path`, `sha256`, `source_tool` e `excerpt`; `Registry.deinit` libera todos os registros.
- Ownership: `Registry.remember` assume ownership e usa `errdefer` para limpar em falha.
- Bounds: budget usa `min(text.len, budget_bytes)`; eviction so ocorre quando `len >= max_records`; `max_records=0` falha como `InvalidRegistryLimit`.
- Hash: sha256 e calculado sobre texto normalizado CRLF -> LF, alinhado com a referencia TS.
- Stale: validacao relê exatamente `start_line..end_line` e compara sha256, sem depender do hash Wyhash do arquivo.
- Streaming: `read_file_range` conta `total_lines` lendo chunks e guarda em memoria apenas ate `max(max_bytes, 64 KiB)`.
- Escopo: manifestar todas as tools nao significa implementar todas agora; implementacao real vem na task seguinte de executor/collect_evidence.

Criterio de aceite:

- `zig test src/micro_context.zig -lc` passa.
- `zig test src/contracts.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- `TASKS.md` explicita que a task pavimenta o tool loop, mas nao implementa o loop real ainda.

Pendencias deliberadas:

- Integracao do `collect_evidence` executor ainda nao esta feita.
- Tool loop real modelo -> tool -> evidencia -> modelo ainda nao esta feito.
- Patch engine usando `context_id` ainda nao esta feito.
- Audit detalhado de ToolEvent ainda nao esta feito.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/micro_context.zig -lc` -> passou; 9 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/contracts.zig -lc` -> passou; 4 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- Teste com servidor/modelo: nao emitido nesta task porque nao ha chamada ao backend; a proxima task de `collect_evidence`/tool loop real deve ter smoke com servidor.

## T257 - Implementar executor inicial de `collect_evidence` sobre MicroContext

Status: implemented-verified.

Motivacao: T256 criou micro-contexto e manifesto, mas `collect_evidence` ainda era apenas contrato declarado. A regra de negocio exige que tools coletem dados, destilem para EvidencePacket/MicroContext e nao vazem bruto ao modelo. Antes do loop real modelo -> tool -> modelo, o executor precisa existir e ser testado offline.

Evidencia:

- `phenom-zig/src/evidence.zig` copiava `range.text` inteiro em `EvidenceEntry`, sem budget.
- `phenom-zig/src/tool_loop.zig` so executava `read_file_range`; `collect_evidence` anunciado no manifesto nao tinha executor.
- `phenom-zig/src/tool_call.zig` nao parseava `strategy`, entao o contrato nao conseguia direcionar estrategia.
- `TASKS.md` T204 exige `ToolEvent -> EvidenceEntry -> EvidencePacket` e teste anti-vazamento de bruto.
- `TASKS.md` T256 deixou explicitamente pendente a integracao do executor `collect_evidence`.

Impacto esperado:

- `collect_evidence(strategy=path|auto)` executa `read_file_range` internamente e retorna EvidencePacket + MicroContext budgetados.
- Tail bruto fora do budget nao aparece no output destinado ao modelo.
- Estrategias ainda nao implementadas falham como `StrategyNotImplemented`, sem comportamento silencioso ou falso positivo.
- Tool loop offline passa a aceitar `collect_evidence` quando anunciado no gate.
- Parser de tool call passa a reconhecer `strategy`.

Teste primeiro:

- `evidence` prova que `fromFileRangeBudgeted` corta tail bruto e adiciona `[TRUNCATED]`.
- `collect_evidence` prova retorno de EvidencePacket, MicroContext, `ctx_*` e metricas simples.
- `collect_evidence` prova que `symbol` ainda nao implementado retorna erro explicito.
- `collect_evidence` prova que budget zero falha.
- `tool_call` prova parse de `strategy=path`.
- `tool_call` prova que strategy desconhecida nao vira `path` silenciosamente.
- `tool_loop` prova que `collect_evidence` anunciado executa e gera evidencia/micro-contexto.

Implementacao:

- `phenom-zig/src/evidence.zig`: adicionar `fromFileRangeBudgeted` e `budgetedExcerpt`.
- `phenom-zig/src/collect_evidence.zig`: criar executor `execute(args)` para estrategia `path|auto`.
- `phenom-zig/src/micro_context.zig`: preservar flag `truncated` para renderizar `[TRUNCATED]` depois do corte.
- `phenom-zig/src/tool_call.zig`: parsear parametro `strategy`.
- `phenom-zig/src/tool_loop.zig`: executar `collect_evidence` quando permitido pelo gate.
- `phenom-zig/src/main.zig`: incluir modulo novo na suite principal.

Passos de implementacao:

1. Criar teste anti-vazamento em `evidence`.
2. Criar executor path de `collect_evidence`.
3. Criar testes de budget, estrategia nao implementada e budget invalido.
4. Estender parser para `strategy`.
5. Integrar `collect_evidence` ao loop offline existente.
6. Rodar testes focados e build completo.
7. Revisar ownership/bounds antes do commit.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `Result.deinit` libera `context_id`, `evidence_text` e `micro_context_text`; `packet.deinit` libera entries mesmo em erro.
- Ownership: `tool_loop` duplica textos do resultado antes de devolver, evitando dangling apos `result.deinit`.
- Parser: strategy e validada antes de alocar `name/path`, evitando leak quando strategy e invalida.
- Bounds: budget usa `min`; budget zero falha antes de ler arquivo.
- Anti-vazamento: tail alem do budget nao entra em EvidencePacket nem MicroContext; marcador `[TRUNCATED]` e preservado.
- Estrategia: `symbol/lexical/semantic` nao fingem execucao; retornam erro ate existir implementacao real.
- Servidor/modelo: nao ha chamada HTTP nesta task, entao smoke real com backend nao e pertinente.

Criterio de aceite:

- `zig test src/evidence.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/tool_call.zig -lc` passa.
- `zig test src/tool_loop.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.

Pendencias deliberadas:

- Ainda nao existe `ToolEvent` tipado com raw interno persistido no audit.
- Ainda nao existe `ModelTurnContext` renderizado.
- Ainda nao existe loop real streaming que chama o modelo de novo com evidence.
- Estrategias `lexical`, `symbol`, `semantic`, `diagnostic`, `runtime` e `diff` ainda precisam de implementacao propria ou fallback auditado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence.zig -lc` -> passou; 9 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 20 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc` -> passou; 8 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_loop.zig -lc` -> passou; 28 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

## T263 - Fechar limitacoes do tool loop real controlado

Status: implemented-verified.

Motivacao: T262/T257 deixaram o loop real funcional, mas ainda inseguro para uso continuo: o texto bruto da tool call era renderizado antes da execucao, o modelo nao recebia schema compacto suficiente, `collect_evidence` sem `path` virava rejeicao seca, e o loop fazia apenas uma volta. Isso quebrava a regra central do agente: tool call e protocolo interno, evidencia destilada e o unico contexto que deve voltar ao modelo.

Evidencia:

- `phenom-zig/src/main.zig` renderizava `StreamSink.writeVisible` imediatamente e so chamava `tool_call.parseFirst` depois de `sink.flush()`.
- `runToolLoopFollowup` aceitava apenas uma tool call e sempre enviava o follow-up com `Do not call tools again`.
- `runToolLoopFollowup` rejeitava `collect_evidence` sem path com `tool_rejected`, sem reparo model-visible.
- `buildOptionalModelContext` so injetava MEMORY/SKILLS quando `PHENOM_MODEL_CONTEXT_V1=1`; o modelo nao recebia formato compacto de tool call quando `PHENOM_TOOL_LOOP_V1=1`.
- Smoke real anterior provou que anunciar tools demais induz tool call indevida em prompt simples; portanto o schema precisava ser minimo e condicionado ao prompt.

Impacto esperado:

- Texto `<tool_call>...</tool_call>` fica buffered e nao aparece na UI nem no audit como `assistant_delta`.
- Prompt simples com `PHENOM_TOOL_LOOP_V1=1` continua respondendo direto sem schema de tools.
- Prompt de codigo/arquivo recebe apenas schema compacto de `collect_evidence`.
- `collect_evidence` sem `path` gera reparo compacto e uma nova chance de inferencia.
- Loop suporta ate 2 execucoes de tool por turno, sem risco de loop infinito.
- Expectation/assert de output usa apenas resposta visivel final, nao protocolo interno.

Teste primeiro:

- Teste de `StreamSink` deferred prova que XML de tool call fica em `raw_visible`, mas nao em `message_chunk` nem em `visible_bytes`.
- Teste de `StreamSink` deferred prova que resposta normal e liberada exatamente uma vez.
- Teste de schema prova que o contrato compacto contem `collect_evidence`, mas nao `apply_patch`/`grep_file`.
- Teste de heuristica prova que prompt de arquivo/codigo recebe schema e saudacao simples nao recebe.
- Smoke real idle prova que prompt simples nao dispara tool.
- Smoke real de tool prova que o modelo emite tool call valida, a tool executa, o XML e suprimido e a resposta final aparece.

Implementacao:

- `phenom-zig/src/main.zig`: adicionar `raw_visible` e `defer_visible` ao `StreamSink`.
- `phenom-zig/src/main.zig`: `flushDeferredVisible` libera resposta normal depois da decisao do loop.
- `phenom-zig/src/main.zig`: substituir `runToolLoopFollowup` por `runToolLoopIterations`.
- `phenom-zig/src/main.zig`: limitar `max_tool_iterations=2` e `max_tool_repairs=1`.
- `phenom-zig/src/main.zig`: criar `collectEvidenceToolSchema` com somente `collect_evidence`.
- `phenom-zig/src/main.zig`: criar `shouldOfferCollectEvidence` para nao anunciar tool em prompt simples.
- `phenom-zig/src/main.zig`: reparar `collect_evidence` sem path com contexto compacto e audit `tool_repair`.

Passos de implementacao:

1. Bufferizar visible output quando `PHENOM_TOOL_LOOP_V1=1`.
2. Parsear tool call sobre `raw_visible`.
3. Se nao houver tool call, liberar o buffer exatamente uma vez.
4. Se houver tool call valida, suprimir o protocolo e executar `collect_evidence`.
5. Enviar EvidencePacket em ModelTurnContext destilado.
6. Permitir segunda tool call se a resposta seguinte ainda solicitar evidencia.
7. Parar no limite fixo de 2 tools.
8. Reparar uma chamada sem `path`.
9. Rodar testes unitarios, build completo e smoke real.
10. Confirmar no SQLite que `assistant_delta` nao contem `<tool_call>`.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `StreamSink.deinit` libera `visible`, `raw_visible` e `ReasoningFilter`.
- Ownership: `tool_call.parseFirst` retorna `ToolCall` owned; cada iteracao chama `deinit` antes de seguir.
- Bounds: loop tem teto fixo `max_tool_iterations=2`; repair tem teto `max_tool_repairs=1`.
- Raw leak: tool call fica em `raw_visible` transitorio e nao e persistida como `assistant_delta`.
- Audit: `tool_start`, `tool_event`, `evidence`, `model_context`, `tool_repair` e `turn_done` continuam auditaveis.
- Modelo: schema de tool nao e global; so entra quando `PHENOM_TOOL_LOOP_V1=1` e o prompt parece exigir evidencia de arquivo/codigo.
- Infra: falha de socket continua `model_error`; falha de tool loop vira `tool_loop_error`, sem parecer erro de infraestrutura.
- Terminal: o render recebe apenas eventos finais/tool/evidence; nao recebe protocolo XML interno.

Criterio de aceite:

- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig test src/tool_call.zig -lc` passa.
- `zig test src/tool_loop.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real idle com `PHENOM_TOOL_LOOP_V1=1` passa sem tool call.
- Smoke real de `collect_evidence README.md` passa com tool renderizada, resposta final e sem XML visivel.
- Query SQLite retorna `0` para `assistant_delta like '%<tool_call>%'`.

Pendencias deliberadas:

- Ainda nao existe executor real para todas as tools do manifesto; esta task fecha apenas `collect_evidence`.
- Ainda nao existe patch engine com `context_id`/stale check no fluxo de mutacao.
- Ainda nao existe reparo semantico para estrategia invalida alem de audit `tool_parse_error`.
- Ainda nao existe selecao inteligente de multiplos arquivos; o modelo ainda precisa pedir cada path.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 118 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc` -> passou; 9 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_loop.zig -lc` -> passou; 31 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 96 --prompt 'Complete: PHENOM_LOOP_IDLE_263' --expect-contains PHENOM_LOOP_IDLE_263 --show-expect-status --fail-on-model-error` -> passou; resposta visivel `PHENOM_LOOP_IDLE_263`.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 220 --prompt 'Use collect_evidence no arquivo README.md e depois responda exatamente: PHENOM_TOOL_DONE_263' --expect-contains PHENOM_TOOL_DONE_263 --show-expect-status --fail-on-model-error` -> passou; renderizou `collect_evidence README.md` duas vezes pelo limite controlado e resposta final `PHENOM_TOOL_DONE_263`.
- `sqlite3 .phenom-zig/phenom.db "select count(*) from events where session='default' and kind='assistant_delta' and body like '%<tool_call>%';"` -> retornou `0`.

## T264 - Impedir `collect_evidence` duplicado no mesmo turno

Status: implemented-verified.

Motivacao: o smoke real da T263 passou tecnicamente, mas revelou comportamento ruim para UX e custo: o modelo pediu `collect_evidence README.md` duas vezes e o agente executou duas vezes porque `max_tool_iterations=2` permitia a segunda chamada. Isso nao deve ser tratado como normal; multiplas iteracoes existem para evidencias diferentes, nao para repetir o mesmo path/range/strategy.

Evidencia:

- Transcript real mostrou dois blocos identicos `▸ collect_evidence: README.md`.
- `runToolLoopIterations` tinha contador de maximo, mas nao guardava chamadas ja executadas.
- O follow-up apos a primeira evidencia ainda permitia uma segunda tool call e apenas instruia "one more file", sem enforcement no agente.
- A regra de negocio exige que tool output seja evidencia destilada e auditavel; executar evidencia identica duplica render, audit e tokens sem novo valor.

Impacto esperado:

- Mesmo `collect_evidence(path,strategy,start_line,max_lines)` so executa uma vez por turno.
- Se o modelo repetir a mesma tool call, o agente registra `tool_duplicate`, nao renderiza nova tool, e chama o modelo com a evidencia ja coletada.
- O contexto de duplicata nao inclui `[TOOLS v1]`, entao a proxima inferencia fica direcionada a resposta final.
- Iteracao dupla continua disponivel para arquivo/range diferente.

Teste primeiro:

- Teste de `ToolLoopState` prova que a mesma chamada passa a ser reconhecida como duplicada apos `rememberExecuted`.
- Teste de contexto de duplicata prova que evidencia coletada continua presente e schema de tool nao aparece.
- Smoke real repete o prompt que duplicava `README.md` e exige apenas uma execucao no audit.

Implementacao:

- `phenom-zig/src/main.zig`: adicionar `ToolCallKey` owned com `path`, `strategy`, `start_line` e `max_lines`.
- `phenom-zig/src/main.zig`: adicionar `ToolLoopState` com chamadas executadas, evidencias owned e contador de reparo de duplicata.
- `phenom-zig/src/main.zig`: antes de executar `collect_evidence`, verificar `state.hasExecuted`.
- `phenom-zig/src/main.zig`: em duplicata, registrar `tool_duplicate`, emitir status discreto e renderizar ModelTurnContext com evidencias ja coletadas sem schema de tools.
- `phenom-zig/src/main.zig`: extrair `renderCollectedEvidenceContext` para montar EvidenceBlocks a partir do estado owned.

Passos de implementacao:

1. Criar chave de dedupe por path/strategy/range.
2. Guardar evidencia owned apos execucao bem-sucedida.
3. Bloquear execucao repetida antes de `tool_start`.
4. Forcar resposta final com evidencia ja coletada.
5. Limitar reparo de duplicata a uma tentativa.
6. Rodar testes focados, build completo e smoke real.
7. Confirmar no SQLite que o ultimo turno tem `tool_start=1` e `evidence=1`.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `ToolLoopState.deinit` libera todas as keys e evidencias duplicadas.
- Ownership: `rememberExecuted` duplica `path` e `evidence_text`; nao guarda ponteiro para `collect_evidence.Result`.
- Bounds: duplicata tem teto `max_duplicate_tool_repairs=1`, evitando loop infinito se o modelo insistir.
- Audit: duplicata nao cria `tool_start` nem `evidence`; apenas `tool_duplicate` e novo `model_context`.
- Modelo: contexto de duplicata omite `[TOOLS v1]`, preserva evidencia e instrui resposta final.
- Terminal: render nao recebe segundo `tool_start`, entao nao duplica bloco visual.

Criterio de aceite:

- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig test src/tool_call.zig -lc` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real que antes duplicava `collect_evidence README.md` mostra apenas um bloco de tool.
- Query SQLite do ultimo turno mostra `tool_start=1` e `evidence=1`.

Pendencias deliberadas:

- Dedupe ainda e por chamada exata; ranges sobrepostos em mesmo arquivo ainda podem executar como chamadas diferentes.
- Nao ha ranking de evidencias nem merge de ranges adjacentes.
- Ainda falta aplicar a mesma politica quando outras tools forem implementadas.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 120 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc` -> passou; 9 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 220 --prompt 'Use collect_evidence no arquivo README.md e depois responda exatamente: PHENOM_TOOL_DONE_263' --expect-contains PHENOM_TOOL_DONE_263 --show-expect-status --fail-on-model-error` -> passou; renderizou um unico `collect_evidence README.md` e resposta final `PHENOM_TOOL_DONE_263`.
- `sqlite3 .phenom-zig/phenom.db "with last_turn as (select max(id) as start_id from events where session='default' and kind='turn_start' and body='Use collect_evidence no arquivo README.md e depois responda exatamente: PHENOM_TOOL_DONE_263') select kind, count(*) from events, last_turn where id >= start_id group by kind order by kind;"` -> retornou `tool_start|1`, `evidence|1`, `assistant_delta|1`, `turn_done|1`.

## T265 - Maturar `collect_evidence` com ranking rg, merge, estrategias e budget por qualidade

Status: implemented-verified.

Motivacao: `collect_evidence` nao pode depender do modelo pequeno para escolher ranges perfeitos. O agente precisa fazer recuperacao deterministica, auditavel e barata: buscar candidatos com `rg`, pontuar por sinais objetivos, fundir ranges sobrepostos/adjacentes, aplicar budget adaptativo e decidir novas coletas por budget/qualidade, nao por numero fixo de chamadas.

Evidencia:

- `collect_evidence.zig` so executava `path|auto` como leitura direta de arquivo/range.
- `symbol`, `lexical`, `semantic`, `diagnostic`, `runtime` e `diff` retornavam `StrategyNotImplemented`.
- `main.zig` ainda tinha limite operacional de 2 coletas por turno.
- Smoke real com `strategy=auto` revelou dois bugs de alinhamento: o modelo emitiu `path=None`, e o ranking inicial escolheu evidencia ruim por termos genericos.
- Smoke real seguinte revelou risco de `RawContextLeak` quando ranking pegava range de teste contendo marcador bruto proibido.

Impacto esperado:

- `collect_evidence(strategy=auto|lexical|symbol|semantic|diagnostic|runtime|diff)` funciona sem path fixo.
- Ranking usa `rg` como tool interna auditada, sem shell/interpolacao e com stdout limitado.
- Audit registra `[CANDIDATE_RANKING]`, `rg_invocations`, `rg_available`, candidatos, scores e reasons, sem raw rg output.
- Ranges sobrepostos/adjacentes sao fundidos antes da leitura.
- Orçamento por range e quantidade de ranges variam conforme budget e score.
- Tool loop permite nova coleta por budget/qualidade (`remainingBudget`, `best_quality`), com hard cap apenas como fusivel.
- `path=None|null|undefined` vindo do modelo vira path ausente.
- Ranges contendo marcadores brutos proibidos sao descartados antes de entrar em EvidencePacket/MicroContext.

Teste primeiro:

- Teste de merge combina ranges adjacentes/sobrepostos.
- Teste de ranker prova uso auditado de `rg` e ausencia de marcador bruto no audit.
- Teste de budget adaptativo prova diferenca por qualidade.
- Teste de `collect_evidence` lexical prova ranking rg -> evidence/micro-context.
- Teste de estrategias `symbol`, `semantic`, `diagnostic`, `runtime` e `diff` prova que todas executam.
- Teste de raw marker prova que ranking descarta ranges proibidos.
- Teste de parser prova que `path=None` e tratado como ausente.
- Smoke real prova `strategy=auto` sem path no modelo, evidencia correta e resposta final.

Implementacao:

- `phenom-zig/src/evidence_ranker.zig`: novo modulo com extracao de termos estruturais, ordenacao por especificidade, chamada `std.process.run` para `rg`, fallback scan, score, reasons, merge e audit.
- `phenom-zig/src/collect_evidence.zig`: `Args.path` virou opcional, `Args.task` foi adicionado, `execute` recebe `std.Io`, e estrategias ranqueadas geram EvidencePacket multi-range.
- `phenom-zig/src/main.zig`: tool loop passa `io`, schema compacto anuncia `auto|path|lexical|symbol|semantic|diagnostic|runtime|diff`, e limite principal passa a ser budget/qualidade.
- `phenom-zig/src/tool_call.zig`: normaliza `path=None|null|undefined` para path ausente.
- `phenom-zig/src/tool_loop.zig` e `model_context.zig`: atualizados para nova assinatura de `collect_evidence.execute`.

Passos de implementacao:

1. Criar ranker deterministico baseado em `rg`.
2. Extrair apenas termos estruturais do prompt, sem stopwords linguisticas.
3. Priorizar termos especificos como `collect_evidence`, paths, extensoes, simbolos e diagnosticos.
4. Pontuar candidatos por match, path, definicao, estrategia e penalidade de teste/cache.
5. Fundir ranges sobrepostos/adjacentes.
6. Gerar audit compacto de ranking.
7. Executar estrategias reais sobre ranking.
8. Aplicar budget adaptativo por qualidade/range count.
9. Trocar loop para budget/qualidade com hard cap de emergencia.
10. Validar com testes e smoke real.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `RankingResult.deinit` libera candidatos e audit; `EvidenceCandidate.deinit` libera path/reasons; `ToolLoopState.deinit` libera keys/evidencias.
- Ownership: `collect_evidence` duplica evidence/context/audit antes de retornar; micro-contexts temporarios sao liberados.
- Subprocesso: `rg` e chamado via argv separado, sem shell, stdout/stderr limitados.
- Bounds: `max_candidates`, `max_ranges`, `max_lines_per_range`, `max_rg_bytes` e `model_budget_limit` limitam crescimento.
- Raw leak: ranges com `---BEGIN CONTENT---`, `[READ_FILE]`, `rawOutput`, `raw_output` e `SECRET_RAW_TAIL` sao descartados.
- Dedupe: chamadas iguais ainda sao reutilizadas; chamadas diferentes podem executar se budget/qualidade permitirem.
- Qualidade: `best_quality >= 82` encerra novas coletas; budget restante abaixo de 2200 tambem encerra.
- Fusivel: `max_tool_emergency_iterations=8` existe apenas contra loop infinito, nao como criterio normal.

Criterio de aceite:

- `zig test src/evidence_ranker.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/tool_call.zig -lc` passa.
- `zig test src/tool_loop.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real `strategy=auto` sem path passa e coleta arquivo relacionado a `collect_evidence`.
- Audit do ultimo turno tem `[CANDIDATE_RANKING]`, `rg_invocations`, `tool_start collect_evidence auto` e zero marcador bruto.

Pendencias deliberadas:

- Ranking ainda e heuristico; nao usa AST real nem LSP.
- `semantic` ainda e semantica heuristica por termos e paths, nao embedding/RAG.
- `diagnostic`, `runtime` e `diff` executam como estrategias reais de recuperacao textual/rankeada, mas ainda nao integram fontes estruturadas de build logs, sqlite audit ou git diff parser.
- Merge nao faz uniao inteligente de ranges distantes no mesmo simbolo; apenas sobrepostos/adjacentes.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc` -> passou; 7 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 28 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc` -> passou; 10 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_loop.zig -lc` -> passou; 36 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 126 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- Smoke real inicial de `strategy=auto` falhou com `path=None` tratado como arquivo; corrigido no parser.
- Smoke real seguinte falhou com `RawContextLeak`; corrigido descartando ranges com marcadores proibidos e penalizando testes.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --prompt 'Use collect_evidence com strategy auto sem path para achar evidencia sobre collect_evidence e depois responda exatamente: PHENOM_AUTO_EVIDENCE_265' --expect-contains PHENOM_AUTO_EVIDENCE_265 --show-expect-status --fail-on-model-error` -> passou; coletou `src/collect_evidence.zig` e resposta final `PHENOM_AUTO_EVIDENCE_265`.
- `sqlite3 .phenom-zig/phenom.db "with last_turn as (select max(id) as start_id from events where session='default' and kind='turn_start' and body like 'Use collect_evidence com strategy auto%') select kind, substr(body,1,160) from events,last_turn where id >= start_id and kind in ('tool_event','tool_start','evidence','assistant_delta') order by id;"` -> mostrou `tool_start collect_evidence auto`, `[CANDIDATE_RANKING]`, `rg_invocations`, evidencia em `src/collect_evidence.zig` e resposta final.
- `sqlite3 .phenom-zig/phenom.db "with last_turn as (select max(id) as start_id from events where session='default' and kind='turn_start' and body like 'Use collect_evidence com strategy auto%') select count(*) from events,last_turn where id >= start_id and body like '%---BEGIN CONTENT---%';"` -> retornou `0`.

## T266 - Remover stopwords linguisticas do ranking de evidencia

Status: implemented-verified.

Motivacao: a implementacao inicial da T265 adicionou uma tabela hardcoded de stopwords (`use`, `com`, `sem`, `para`, `strategy`, `path`, `auto` etc.) para impedir que o ranking por `rg` usasse termos fracos do prompt. Isso contradiz a regra de negocio descrita no audit: o controller nao deve inferir direcao operacional por palavras soltas do prompt. Mesmo sendo usado dentro de `collect_evidence`, esse filtro linguistico cria comportamento opaco, dependente de idioma e perigoso para modelos pequenos.

Evidencia:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` afirma que o controller nao deve inferir direcao operacional por palavras-chave do prompt; ele deve executar contratos e estrategias.
- `TASKS.md` arquitetura canonica diz que tools coletam bruto e o controller destila evidencia, mas nao promove varias fontes/contextos por heuristica escondida.
- A T265 registrava "filtrar stopwords" como passo, o que estava desalinhado com o proprio objetivo de ranking deterministico auditavel.
- O codigo em `evidence_ranker.zig` tinha `isStopWord`, uma lista linguistica fixa e dependente de portugues/ingles.

Impacto esperado:

- O ranker nao usa mais tabela de palavras comuns.
- A extracao de termos passa a aceitar apenas sinais estruturais: path, extensao, snake_case, camelCase, tokens com `.`/`-`, nomes canonicos de contratos/tools e tokens de diagnostico.
- Prosa comum do prompt nao entra como termo de busca.
- O audit continua mostrando termos/ranking, mas agora os termos sao tecnicamente justificaveis.
- A decisao operacional continua vindo do contrato `collect_evidence` chamado pelo modelo; o ranker so recupera evidencia objetiva.

Teste primeiro:

- Teste de extracao prova que `collect_evidence` e `RawContextLeak` entram.
- Teste de extracao prova que `Use`, `strategy` e `path` nao entram por prosa.
- Testes existentes de ranking, collect_evidence e main continuam passando.

Implementacao:

- `phenom-zig/src/evidence_ranker.zig`: remover `isStopWord`.
- `phenom-zig/src/evidence_ranker.zig`: remover conversao generica de qualquer palavra para snake_case.
- `phenom-zig/src/evidence_ranker.zig`: adicionar `isStructuredSearchTerm`, `hasUpperAfterLower`, `isKnownContractTerm` e `looksLikeDiagnosticToken`.
- `phenom-zig/src/evidence_ranker.zig`: naquele momento ainda manteve expansoes canonicas de frases de contrato como `tool loop`, `tool call` e `collect evidence`; a T270 removeu isso por ainda ser interpretacao textual escondida.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: nenhuma nova alocacao persistente; `TermList.deinit` continua liberando termos aceitos.
- Bounds: menos termos reduzem invocacoes de `rg` e custo de audit.
- Regra de negocio: controller nao classifica intencao por idioma; ele apenas usa tokens estruturais apos o modelo chamar `collect_evidence`.
- Compatibilidade: `collect_evidence` por path nao muda; estrategias ranqueadas continuam usando `rg`.
- Risco residual: se o modelo nao fornecer nenhum token estruturado nem path, `collect_evidence(auto)` pode retornar poucos candidatos. Isso e preferivel a inferir por prosa solta; a solucao futura e schema com `target/symbol/query` tipado, nao stopwords.

Criterio de aceite:

- `zig test src/evidence_ranker.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `TASKS.md` registra que stopwords linguisticas foram removidas por violarem o eixo do audit.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc` -> passou; 8 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 29 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 127 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.

## T267 - Criar `ToolCallEnvelope` antes do executor real

Status: implemented-verified.

Motivacao: o audit aponta que uma saida real ja foi interpretada como tool `content`, fora das tools anunciadas. T263/T264/T265 fecharam o loop controlado de `collect_evidence`, mas o parser ainda retornava `ToolCall` direto para o loop real. Isso era suficiente para uma tool unica, mas nao e robusto para a proxima etapa de contratos: toda chamada precisa passar por um envelope tipado, validado contra o contrato ativo e auditado antes de qualquer executor.

Evidencia:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` exige que tool call extraida exista na allowlist anunciada e que tool inexistente vire protocol repair/rejection, nunca execucao.
- `TASKS.md` PR002/T010-T014 pedem `ToolCallEnvelope` com origem, estrategia de parser, nome bruto, estado e motivo de rejeicao.
- `phenom-zig/src/main.zig` chamava `tool_call.parseFirst` diretamente em `runToolLoopIterations` e `streamDeferredToolLoopTurn`.
- O gate existia, mas estava dentro de `runOneToolLoopStep`; isso ainda deixava parser, gate e audit sem uma fronteira unica.

Impacto esperado:

- Toda tool textual passa por `ToolCallEnvelope` antes do executor.
- Tool fora do contrato ativo vira `tool_rejected` com `rejected/tool_not_advertised`.
- Estrategia invalida vira envelope rejeitado com `rejected/invalid_strategy`.
- O SQLite registra `tool_envelope` com contrato, source, parser, raw name e estado.
- `collect_evidence` continua sendo a unica tool executavel do contrato ativo atual.
- O fluxo real continua funcionando com modelo e backend, sem vazar XML de tool call no output.

Teste primeiro:

- Teste de envelope aceita `collect_evidence` anunciado.
- Teste de envelope rejeita `content` antes de executor.
- Teste de envelope transforma estrategia invalida em rejeicao auditavel.
- Teste de audit do envelope registra contrato, source, parser, raw name e state.
- Teste principal garante que o loop existente continua passando.
- Smoke real garante que o modelo ainda chama `collect_evidence`, recebe evidencia e finaliza.

Implementacao:

- `phenom-zig/src/tool_envelope.zig`: criar `ToolCallEnvelope`, `ActiveContract`, `Source`, `ParseStrategy`, `State` e `RejectionReason`.
- `phenom-zig/src/tool_envelope.zig`: validar chamada extraida contra `ActiveContract.collectEvidence()`.
- `phenom-zig/src/tool_envelope.zig`: adicionar `renderAudit` e `takeCall` para ownership explicito.
- `phenom-zig/src/main.zig`: substituir parse direto por envelope em `runToolLoopIterations`.
- `phenom-zig/src/main.zig`: substituir parse direto por envelope em `streamDeferredToolLoopTurn`.
- `phenom-zig/src/main.zig`: registrar `tool_envelope` antes de executar ou rejeitar.

Passos de implementacao:

1. Criar modulo isolado de envelope.
2. Mover allowlist do primeiro contrato para `ActiveContract.collectEvidence`.
3. Converter erros de parse/strategy em estado rejeitado.
4. Auditar todo envelope aceito ou rejeitado.
5. Integrar envelope no primeiro output do modelo.
6. Integrar envelope nos follow-ups apos evidencia.
7. Rodar testes focados, suite principal, build release e smoke real.
8. Consultar SQLite para provar `tool_envelope -> tool_start -> evidence -> assistant_delta`.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `ToolCallEnvelope.deinit` libera `raw_name` e libera `ToolCall` se ainda nao foi consumido.
- Ownership: `takeCall` zera `self.call`, evitando double free quando o loop assume ownership.
- Erro de alocacao: `fromAcceptedCall` usa `errdefer call.deinit`, evitando leak se `raw_name` falhar.
- Rejeicao: `rejectedCall` duplica `raw_name` e libera a `ToolCall` rejeitada antes de retornar.
- Bounds: nenhuma nova estrutura cresce por turno; envelope e liberado a cada iteracao.
- Regra de negocio: controller nao infere direcao por prompt; apenas valida se a tool chamada pertence ao contrato ativo.
- Audit: rejeicao nao cria `tool_start`, `tool_event` nem `evidence`.

Criterio de aceite:

- `zig test src/tool_envelope.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real com `collect_evidence README.md` passa e registra `tool_envelope state=accepted`.
- Query SQLite do smoke mostra `tool_envelope`, `tool_start`, `tool_event`, `evidence`, `assistant_delta` e `turn_done`.

Pendencias deliberadas:

- Ainda nao existe `set_operational_contract` real com mudanca dinamica de surface por turno.
- `ActiveContract.collectEvidence()` ainda e fixo; a proxima task deve mover isso para manifesto/versionamento de contratos.
- Ainda nao ha repair model-visible para tool nao anunciada; por enquanto rejeita e audita.
- Native tool calls ainda precisam passar pelo mesmo envelope quando forem reintroduzidas.
- Mutacao/validacao/runtime continuam fora do contrato executavel ate o micro-contexto e stale patch estarem completos.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_envelope.zig -lc` -> passou; 15 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 127 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --prompt 'Use collect_evidence no arquivo README.md e depois responda exatamente: PHENOM_ENVELOPE_267' --expect-contains PHENOM_ENVELOPE_267 --show-expect-status --fail-on-model-error --session envelope-267` -> passou; renderizou um unico `collect_evidence README.md` e resposta final `PHENOM_ENVELOPE_267`.
- `sqlite3 .phenom-zig/phenom.db "select kind, substr(body,1,180) from events where session='envelope-267' and kind in ('tool_envelope','tool_rejected','tool_start','tool_event','evidence','assistant_delta','turn_done') order by id;"` -> mostrou `tool_envelope state=accepted`, `tool_start collect_evidence README.md`, `tool_event`, `evidence`, `assistant_delta PHENOM_ENVELOPE_267` e `turn_done status=ok`.

## T268 - Mover contrato ativo para manifesto versionado

Status: implemented-verified.

Motivacao: T267 criou o envelope, mas deixou `ActiveContract.collectEvidence()` dentro de `tool_envelope.zig`. Isso ainda misturava parser/gate com definicao de contrato. A regra de negocio pede contratos como endpoints versionados e auditaveis; o envelope deve validar contra um contrato recebido, nao possuir a surface por conta propria.

Evidencia:

- `TASKS.md` T035 pede manifesto pequeno de contratos como endpoints.
- `TASKS.md` T036 pede registry separado para estrategias por contrato.
- `TASKS.md` T267 registrou como pendencia que `ActiveContract.collectEvidence()` ainda era fixo e deveria ir para manifesto/versionamento.
- `phenom-zig/src/tool_envelope.zig` importava `gate.zig` e possuia a allowlist `&.{"collect_evidence"}` localmente.
- `phenom-zig/src/main.zig` chamava diretamente `tool_envelope.ActiveContract.collectEvidence()`.

Impacto esperado:

- `contracts.zig` passa a ser dono de `manifest_version`, `ContractSpec` e `ActiveContract`.
- `tool_envelope.zig` deixa de conhecer a allowlist e apenas valida `active_contract.allows(call.name)`.
- Audit de envelope inclui `version=contracts.v1`.
- Comportamento externo permanece igual: apenas `collect_evidence` executa no contrato ativo atual.
- A proxima task pode trocar `currentActiveContract()` por estado real de `set_operational_contract` sem mexer no parser.

Teste primeiro:

- Teste em `contracts.zig` prova que o contrato ativo vem do manifesto, aceita `collect_evidence` e rejeita `content`/`grep_file`.
- Teste de envelope continua provando rejeicao de tool nao anunciada.
- Teste de envelope prova que audit registra `version=contracts.v1`.
- Teste principal garante que o loop real continua funcionando.

Implementacao:

- `phenom-zig/src/contracts.zig`: adicionar `manifest_version = "contracts.v1"`.
- `phenom-zig/src/contracts.zig`: criar `ContractSpec`, `ActiveContract`, `contract_specs` e `activeContract`.
- `phenom-zig/src/contracts.zig`: adicionar `ActiveContract.allows`.
- `phenom-zig/src/tool_envelope.zig`: remover `ActiveContract` local e import direto de `gate.zig`.
- `phenom-zig/src/tool_envelope.zig`: aceitar `contracts.ActiveContract` e renderizar version no audit.
- `phenom-zig/src/main.zig`: adicionar `currentActiveContract()` como ponto unico temporario.

Passos de implementacao:

1. Criar contrato ativo no manifesto.
2. Migrar allowlist local do envelope para `contracts.zig`.
3. Atualizar envelope para depender de `contracts.ActiveContract`.
4. Registrar versao no audit de envelope.
5. Atualizar `main.zig` para obter o contrato ativo por helper unico.
6. Rodar testes focados, suite principal, build release e smoke real.
7. Consultar SQLite para provar `tool_envelope version=contracts.v1`.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `ActiveContract` usa slices estaticos do manifesto; nao introduz alocacao nem ownership novo.
- Ownership: `ToolCallEnvelope` continua owning apenas `raw_name` e `ToolCall`.
- Bounds: `contract_specs` e allowlists sao arrays estaticos pequenos.
- Regra de negocio: contrato ativo agora e dado operacional, nao detalhe do parser.
- Audit: replay passa a saber qual versao de contrato validou a chamada.
- Compatibilidade: `collect_evidence` continua sendo a unica tool permitida no loop real.

Criterio de aceite:

- `zig test src/contracts.zig -lc` passa.
- `zig test src/tool_envelope.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real passa e audit contem `tool_envelope contract=collect_evidence version=contracts.v1`.

Pendencias deliberadas:

- `currentActiveContract()` ainda retorna sempre `collect_evidence`; falta estado real por turno.
- `set_operational_contract` ainda nao executa nem altera surface.
- O manifesto ainda nao serializa descricoes/inputSchema/outputSchema; isso fica para T035 completo.
- Smoke real mostrou que, mesmo pedindo `README.md`, o modelo escolheu `strategy=auto`; isso nao quebra T268, mas indica que o schema/contrato ainda precisa de parametros tipados como `target/path` e reparo quando o pedido do usuario inclui arquivo explicito.
- Native tools ainda nao passam pelo envelope.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/contracts.zig -lc` -> passou; 5 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_envelope.zig -lc` -> passou; 15 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 128 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --prompt 'Use collect_evidence no arquivo README.md e depois responda exatamente: PHENOM_CONTRACT_268' --expect-contains PHENOM_CONTRACT_268 --show-expect-status --fail-on-model-error --session contract-268` -> passou; resposta final `PHENOM_CONTRACT_268`.
- `sqlite3 .phenom-zig/phenom.db "select kind, substr(body,1,220) from events where session='contract-268' and kind in ('tool_envelope','tool_rejected','tool_start','tool_event','evidence','assistant_delta','turn_done') order by id;"` -> mostrou `tool_envelope contract=collect_evidence version=contracts.v1`, `tool_start collect_evidence auto`, `tool_event`, `evidence`, `assistant_delta PHENOM_CONTRACT_268` e `turn_done status=ok`.

## T269 - Reparar `collect_evidence(auto)` quando existe um unico path estruturado explicito

Status: implemented-verified.

Motivacao: o smoke da T268 mostrou um desalinhamento operacional: o usuario pediu evidencia alvo em `README.md`, mas o modelo chamou `collect_evidence` com `strategy=auto` sem path e o ranker coletou `src/collect_evidence.zig`. Isso nao e falha de infraestrutura, mas prejudica confiabilidade do micro-contexto. A correcao nao pode virar inferencia por palavras-chave; deve usar apenas argumento estruturado comprovavel.

Evidencia:

- `TASKS.md` arquitetura canonica diz que micro-contexto de codigo e orientado a path/range/hash.
- `TASKS.md` PR003 permite o controller adaptar estrategia com base em disponibilidade, custo e evidencia, sem inferir direcao por keyword do prompt.
- T268 registrou explicitamente que o schema/contrato precisava melhorar quando o pedido do usuario inclui arquivo explicito.
- Smoke real `contract-268` mostrou `tool_start collect_evidence auto` e evidencia em `src/collect_evidence.zig`, apesar de `README.md` estar no prompt.

Impacto esperado:

- Se o modelo chama `collect_evidence` sem path e o prompt contem exatamente um token que parece path seguro, o controller usa esse path como argumento efetivo.
- Se ha zero ou mais de um path estruturado, nao ha reparo automatico.
- O reparo muda `strategy=auto` para `strategy=path` somente quando o path foi recuperado de forma estruturada.
- O audit registra `tool_arg_repair` quando o reparo acontece.
- Dedupe passa a usar os argumentos efetivos, nao a chamada bruta `<auto>`.

Teste primeiro:

- Teste extrai `README.md` de prompt com um unico path.
- Teste extrai `README.md` mesmo com pontuacao final `README.md.`.
- Teste nao repara quando existem dois paths (`README.md` e `TASKS.md`).
- Teste nao repara texto sem path.
- Teste nao aceita traversal como `../README.md`.
- Teste de dedupe usa path efetivo reparado.

Implementacao:

- `phenom-zig/src/main.zig`: adicionar `singleStructuredPathFromPrompt`.
- `phenom-zig/src/main.zig`: aceitar apenas tokens com extensoes textuais conhecidas e sem absoluto/traversal/hidden-prefix.
- `phenom-zig/src/main.zig`: em `runOneToolLoopStep`, calcular `repaired_path` antes de decidir estrategia.
- `phenom-zig/src/main.zig`: registrar `tool_arg_repair` quando o path foi recuperado.
- `phenom-zig/src/main.zig`: trocar `ToolLoopState.hasExecuted/rememberExecuted` para variantes por args efetivos.

Passos de implementacao:

1. Criar helper de extracao estruturada de path.
2. Garantir que mais de um path nao gera reparo.
3. Corrigir pontuacao final de path (`README.md.`).
4. Aplicar path reparado antes de missing-path repair.
5. Ajustar dedupe para usar path/strategy/start/max efetivos.
6. Rodar teste principal, build release e smoke real.
7. Consultar SQLite para verificar path efetivo no tool event.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `singleStructuredPathFromPrompt` retorna path owned; caminho de multiplos paths libera o primeiro candidato antes de retornar `null`.
- Ownership: `repaired_path` e liberado no fim de `runOneToolLoopStep`; o executor duplica path internamente quando precisa persistir.
- Bounds: extracao itera tokens do prompt uma vez, sem buffers grandes.
- Seguranca: path absoluto, traversal e token iniciado com `.` sao rejeitados antes de virar argumento.
- Regra de negocio: nao ha classificacao por palavras comuns; apenas token estruturado de path apos o modelo ja ter chamado `collect_evidence`.
- Audit: quando o reparo acontece, `tool_arg_repair` registra `path<-prompt_structured_path`.

Criterio de aceite:

- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real com `README.md` continua coletando `README.md`.
- Smoke real forcado com `strategy auto sem path` nao pode voltar a coletar arquivo aleatorio quando `README.md` e o unico path estruturado.

Pendencias deliberadas:

- Smoke real nao acionou `tool_arg_repair` porque o modelo emitiu path corretamente mesmo quando o prompt pediu `sem path`; o reparo fica provado offline por teste unitario.
- O schema ainda deveria ter campo `target/path` mais claro dentro do manifesto completo.
- A extracao cobre extensoes textuais conhecidas; novos dominios devem declarar extensoes no contrato/perfil, nao ampliar por heuristica solta.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 130 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- Primeiro smoke forçado mostrou bug de pontuacao: `README.md.` nao era aceito como path estruturado; corrigido no trim e coberto por teste.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --prompt 'Use collect_evidence no arquivo README.md e depois responda exatamente: PHENOM_PATH_REPAIR_269' --expect-contains PHENOM_PATH_REPAIR_269 --show-expect-status --fail-on-model-error --session path-repair-269` -> passou; coletou `README.md`.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --prompt 'Use collect_evidence com strategy auto sem path, mas a evidencia alvo e README.md. Depois responda exatamente: PHENOM_PATH_REPAIR_FORCED_269B' --expect-contains PHENOM_PATH_REPAIR_FORCED_269B --show-expect-status --fail-on-model-error --session path-repair-forced-269b` -> passou; coletou `README.md`.
- `sqlite3 .phenom-zig/phenom.db "select kind, substr(body,1,220) from events where session='path-repair-forced-269b' and kind in ('tool_envelope','tool_arg_repair','tool_start','tool_event','evidence','assistant_delta','turn_done') order by id;"` -> mostrou `tool_start collect_evidence README.md`, `tool_event args=strategy=path path=README.md`, evidencia de `README.md` e resposta final.

## T270 - Remover vies de inventario no `collect_evidence(auto)`

Status: implemented-verified.

Motivacao: o teste real com uma pergunta ambigua de usuario comum mostrou que o schema sem gate linguistico induziu o modelo a chamar `collect_evidence(auto)`, mas o ranker retornou `NoEvidenceCandidates` quando nao havia path nem termo estruturado util. A primeira tentativa de corrigir isso usou uma lista fixa de arquivos conhecidos (`README.md`, `package.json`, `build.zig`, `Cargo.toml`, `src/main.zig` etc.). Isso foi rejeitado porque introduz vies operacional: o controller passaria a decidir quais arquivos "devem" explicar o projeto por preferencia hardcoded, violando a regra de negocio do audit e da T266.

Evidencia:

- `TASKS.md` T266 estabelece que o controller nao deve inferir direcao operacional por stopwords, palavras do prompt ou tabela linguistica.
- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` exige contratos e estrategias auditaveis, nao contexto montado por inferencia escondida.
- Smoke real `ambiguous-tool-270e` mostrou `collect_evidence(auto)` seguido de `NoEvidenceCandidates` para uma pergunta natural sobre o projeto.
- Diff local continha `addWorkspaceOverviewCandidates` com lista fixa de caminhos e `overviewScore` favorecendo nomes como `readme`, `package`, `build`, `cargo`, `pyproject`, `main` e `index`.
- O mesmo arquivo ainda mapeava frases livres como `tool loop`, `tool call` e `collect evidence` para termos internos, o que era outro caminho de interpretacao textual escondida.

Impacto esperado:

- `collect_evidence(auto)` sem path/termo estruturado passa a ter fallback de inventario estrutural do workspace.
- O inventario usa `rg --files` como coletor auditavel, com argv separado e limite de stdout/stderr.
- Nenhum nome de arquivo e privilegiado por lista fixa.
- Nenhuma frase livre do prompt vira termo interno no ranker.
- A ordenacao do inventario usa somente propriedades neutras: profundidade menor, path menor e ordem lexicografica.
- O modelo recebe evidencia destilada; raw output do coletor nao entra no contexto.
- O contrato continua sendo escolhido pelo modelo; o controller apenas executa `collect_evidence(auto)` dentro do budget.

Teste primeiro:

- Teste `auto ranking without structured terms falls back to workspace overview` prova que prompt sem termo estruturado retorna candidatos `workspace_overview`.
- Teste `term extraction keeps structured symbols and ignores prose without stopword table` continua provando que prosa comum nao entra como termo.
- Teste real ambigue de usuario valida que o modelo chama a tool, recebe evidencia e responde sem `NoEvidenceCandidates`.

Implementacao:

- `phenom-zig/src/evidence_ranker.zig`: remover expansoes por frase livre (`tool loop`, `tool call`, `collect evidence`).
- `phenom-zig/src/evidence_ranker.zig`: implementar `addWorkspaceOverviewCandidates` com `rg --files --hidden` e globs de exclusao para cache/vendor.
- `phenom-zig/src/evidence_ranker.zig`: filtrar apenas arquivos texto/codigo ja aceitos por `looksLikeTextCode`.
- `phenom-zig/src/evidence_ranker.zig`: substituir score por nome por `overviewScore` baseado em profundidade e tamanho de path.
- `phenom-zig/src/evidence_ranker.zig`: adicionar `sortOverviewPaths` e `pathDepth`.
- `phenom-zig/src/main.zig`: manter schema de `collect_evidence` sempre disponivel quando `PHENOM_TOOL_LOOP_V1=1`, sem gate linguistico por prompt.

Passos de implementacao:

1. Identificar e remover a lista fixa de paths.
2. Remover scoring por basename.
3. Remover conversao de frases livres em termos internos.
4. Criar inventario estrutural via `rg --files`.
5. Ordenar candidatos por propriedades neutras.
6. Manter limites de stdout, stderr, quantidade de paths e quantidade de ranges.
7. Validar testes focados, suite principal e build release.
8. Rodar smoke real ambigue com servidor.
9. Consultar SQLite para provar envelope, ranking, evidencia e ausencia de raw marker.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `result.stdout` e `result.stderr` sao liberados; cada path temporario em `paths` e liberado no `defer`; candidatos finais duplicam `path` e `reasons` e seguem ownership de `RankingResult`.
- Ownership: `paths.items` so guarda buffers owned temporarios; `out.append` duplica antes do `defer` liberar temporarios.
- Bounds: `stdout_limit` usa `budget.max_rg_bytes`; `stderr_limit` e 8 KiB; `paths` para em `budget.max_candidates * 8`; saida final para em `budget.max_candidates`.
- Subprocesso: `rg` e chamado sem shell, com argv separado.
- Raw leak: audit registra candidatos e reasons, nao stdout bruto; query SQLite confirmou zero `---BEGIN CONTENT---`.
- Regra de negocio: nao ha stopword, lista de arquivos preferidos, phrase mapping ou classificacao por idioma.
- Risco operacional: se `rg` nao existir, o fallback estrutural retorna sem candidatos; isso e melhor que inventar evidencia por vies. Uma etapa futura pode adicionar coletor nativo sem mudar regra de ranking.

Criterio de aceite:

- `zig test src/evidence_ranker.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real ambigue passa com `collect_evidence(auto)` e resposta final.
- SQLite mostra `tool_envelope state=accepted`, `tool_start collect_evidence auto`, `[CANDIDATE_RANKING]`, `source=workspace_overview`, `evidence`, `assistant_delta` e `turn_done status=ok`.
- SQLite mostra `0` ocorrencias de marcador bruto `---BEGIN CONTENT---`.

Pendencias deliberadas:

- O fallback estrutural ainda depende de `rg --files`; coletor nativo de inventario pode ser implementado depois para ambientes sem rg.
- A estrategia `auto` ainda nao faz leitura semantica do workspace; ela fornece uma visao estrutural neutra quando nao ha alvo tipado.
- Ordenar por profundidade/path nao garante a melhor evidencia conceitual em todos os projetos; a melhora correta deve vir de contrato/modelo pedindo `path`, `symbol`, `query` ou estrategia especifica, nao de lista hardcoded.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc` -> passou; 10 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 31 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 131 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt 'Analise esse projeto e me diga, em termos simples, o que ele faz. Termine exatamente com: PHENOM_AMBIG_TOOL_270F' --expect-contains PHENOM_AMBIG_TOOL_270F --show-expect-status --fail-on-model-error --session ambiguous-tool-270f` -> passou; modelo chamou `collect_evidence(auto)`, recebeu evidencia e respondeu com `PHENOM_AMBIG_TOOL_270F`.
- `sqlite3 .phenom-zig/phenom.db "select kind, substr(body,1,900) from events where session='ambiguous-tool-270f' and kind in ('model_context','tool_envelope','tool_start','tool_event','evidence','assistant_delta','turn_done') order by id;"` -> mostrou `tool_envelope state=accepted`, `tool_start collect_evidence auto`, `[CANDIDATE_RANKING]`, `source=workspace_overview`, evidencia, resposta e `turn_done status=ok`.
- `sqlite3 .phenom-zig/phenom.db "select count(*) from events where session='ambiguous-tool-270f' and body like '%---BEGIN CONTENT---%';"` -> retornou `0`.

## T271 - Alinhar superficie ativa e ranking ao produto final

Status: implemented-verified.

Motivacao: revisao de alinhamento apontou cinco riscos de regressao para os mesmos problemas do `phenom-cli-ts`: ranking com vies por linguagem/teste, estrategias anunciadas sem executor maduro, manifesto model-visible maior que o runtime real, contrato ativo fixo sem honestidade de superficie, e reparo de path com falso positivo para `..` textual. Como o projeto e produto final em construcao, a correcao deve estabilizar a regra de negocio: o modelo so ve e so consegue usar contratos que o controller executa de forma auditavel; qualquer estrategia futura fica fora da superficie ativa ate existir executor real.

Evidencia:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` define que o controller nao deve inferir direcao operacional por palavras-chave do prompt.
- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` aponta a falha real de tool `content` fora da allowlist e exige envelope validado contra tools anunciadas.
- `phenom-zig/src/evidence_ranker.zig` ainda dava bonus para `.zig`, penalizava `test` e injetava termos como `pub`, `fn`, `error`, `patch`, `audit` por estrategia.
- `phenom-zig/src/contracts.zig` marcava muitas tools como `model_visible`, mas o contrato ativo real so executava `collect_evidence`.
- Smoke real `align-271` passou no marcador, mas respondeu sem ferramenta e alucinou um projeto To-Do List. Isso mostrou que o marcador sozinho nao prova o fluxo de negocio.
- Smoke real `align-271b` chamou `collect_evidence`, mas ainda extrapolou capacidades nao evidenciadas. Isso mostrou que evidencia coletada precisa virar restricao de groundedness, nao sugestao.

Impacto esperado:

- Ranking nao privilegia extensao `.zig` nem penaliza arquivos de teste.
- Estrategias inativas (`symbol`, `semantic`, `diagnostic`, `runtime`, `diff`) nao sao anunciadas ao modelo, nao sao aceitas pelo envelope e nao fazem fallback silencioso para `auto`.
- `compactModelVisibleTools` passa a refletir a superficie executavel atual: apenas `collect_evidence` e model-visible.
- `collect_evidence` ativo fica limitado a `auto`, `path` e `lexical`.
- Path repair aceita nomes legitimos como `foo..txt` e continua rejeitando traversal por componente `..`.
- O contrato inicial obriga evidencia antes de qualquer claim sobre projeto/repo/codigo/arquivos/implementacao.
- O contexto apos tool obriga resposta final a usar apenas evidencia coletada e nao adicionar capacidades ausentes.

Teste primeiro:

- Teste de ranker prova que score de arquivo `.zig` e arquivo de teste equivalente e igual.
- Teste de ranker prova que estrategia inativa nao injeta termos sinteticos (`pub`, `fn`).
- Teste de contracts prova que `apply_patch`, `run_tests` e `set_operational_contract` nao aparecem em `compactModelVisibleTools`.
- Teste de envelope prova que estrategia `semantic` e rejeitada pelo contrato ativo.
- Teste de collect_evidence prova que estrategias inativas retornam `InvalidStrategy`, sem fallback para `auto`.
- Teste de main prova schema sem `symbol|semantic|diagnostic|runtime|diff`.
- Teste de path repair prova que `foo..txt` e aceito e `../README.md` continua rejeitado.

Implementacao:

- `phenom-zig/src/evidence_ranker.zig`: remover seed de termos por estrategia.
- `phenom-zig/src/evidence_ranker.zig`: remover lista hardcoded de termos conhecidos de contrato; aceitar somente sinais estruturais (`_`, `.`, `-`, CamelCase, token diagnostico).
- `phenom-zig/src/evidence_ranker.zig`: remover bonus por `.zig`, penalidade por `test` e boost de definicao baseado em `fn/const/pub`.
- `phenom-zig/src/contracts.zig`: mover todas as tools nao executaveis agora para `internal_context`.
- `phenom-zig/src/contracts.zig`: manter apenas `auto`, `path` e `lexical` como estrategias ativas de `collect_evidence`.
- `phenom-zig/src/contracts.zig`: mudar `resolveCollectEvidenceStrategy` para retornar `null` em estrategia inativa.
- `phenom-zig/src/collect_evidence.zig`: retornar `InvalidStrategy` quando a estrategia nao esta ativa.
- `phenom-zig/src/tool_envelope.zig`: rejeitar estrategia parseada que nao pertence ao contrato ativo.
- `phenom-zig/src/main.zig`: reduzir schema model-visible para `auto|path|lexical`.
- `phenom-zig/src/main.zig`: trocar rejeicao de qualquer substring `..` por validacao de componente traversal.
- `phenom-zig/src/main.zig`: fortalecer contrato inicial e contexto pos-tool contra claims sem evidencia.

Passos de implementacao:

1. Remover pesos enviesados do ranker.
2. Reduzir estrategias ativas ao que existe de fato.
3. Fazer envelope validar estrategia contra contrato ativo.
4. Fazer executor rejeitar estrategia inativa sem fallback silencioso.
5. Reduzir manifesto model-visible ao runtime executavel atual.
6. Corrigir reparo de path para distinguir traversal real de nome legitimo.
7. Fortalecer contrato textual para exigir evidencia em claims sobre workspace.
8. Fortalecer contexto pos-tool para limitar resposta a evidencia coletada.
9. Validar offline, build release, smoke real e SQLite.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: sem novos buffers persistentes alem das strings ja owned por context/render; alteracoes de contrato usam arrays estaticos.
- Ownership: envelope rejeitado continua liberando `ToolCall`; executor rejeita antes de alocar `Result`.
- Bounds: nenhuma nova coleta amplia `max_candidates`, `max_ranges`, `model_budget_limit` ou `max_rg_bytes`.
- Subprocesso: `rg` permanece via argv separado, sem shell.
- Raw leak: query SQLite do smoke final retornou `0` para marcador `---BEGIN CONTENT---`.
- Regra de negocio: controller nao classifica intencao por keyword; ele reduz a superficie e valida protocolo/contrato.
- Ranker: sem stopwords, sem lista fixa de arquivos e sem lista semantica de nomes de contratos; candidatos usam `rg`, paths explicitos ou inventario estrutural auditado.
- Produto: features futuras nao sao removidas do roadmap; ficam internal/inativas ate terem executor real e testes reais.

Criterio de aceite:

- `zig test src/contracts.zig -lc` passa.
- `zig test src/evidence_ranker.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/tool_envelope.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real de pergunta ambigua sobre projeto chama `collect_evidence(auto)` antes da resposta.
- SQLite do smoke real mostra `tool_start=1`, `evidence=1` e zero raw marker.

Pendencias deliberadas:

- `set_operational_contract` ainda nao e model-visible porque nao existe executor/estado real para trocar contratos em runtime.
- `symbol`, `semantic`, `diagnostic`, `runtime` e `diff` continuam no enum/roadmap, mas nao sao estrategias ativas ate terem implementacao propria.
- O smoke `align-271c` ainda mostrou que o modelo pode extrapolar detalhes em linguagem natural mesmo apos evidencia. Nao foi adicionado filtro por blacklist porque isso seria nova heuristica fragil. A solucao correta e uma proxima task de groundedness por claims/citacoes: claims sobre workspace devem apontar para evidence ids/ranges ou serem marcadas como nao evidenciadas.
- README descrevia `phenom-zig` com linguagem de base descartavel; isso afetava a resposta real porque a evidencia vem do arquivo. Deve permanecer tratado em task de documentacao/produto, nao no controller.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/contracts.zig -lc` -> passou; 5 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc` -> passou; 12 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 33 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_envelope.zig -lc` -> passou; 16 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 133 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt 'Analise esse projeto e me diga, em termos simples, o que ele faz. Termine exatamente com: PHENOM_ALIGN_271' --expect-contains PHENOM_ALIGN_271 --show-expect-status --fail-on-model-error --session align-271` -> passou no marcador, mas falhou semanticamente: sem tool/evidence e resposta To-Do List. Usado como evidencia para fortalecer contrato.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt 'Analise esse projeto e me diga, em termos simples, o que ele faz. Termine exatamente com: PHENOM_ALIGN_271B' --expect-contains PHENOM_ALIGN_271B --show-expect-status --fail-on-model-error --session align-271b` -> chamou `collect_evidence(auto)`, mas ainda extrapolou capacidades. Usado como evidencia para fortalecer contexto pos-tool.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt 'Analise esse projeto e me diga, em termos simples, o que ele faz. Termine exatamente com: PHENOM_ALIGN_271C' --expect-contains PHENOM_ALIGN_271C --show-expect-status --fail-on-model-error --session align-271c` -> chamou `collect_evidence(auto)`, recebeu evidencia e respondeu com marcador.
- `sqlite3 .phenom-zig/phenom.db "select count(*) from events where session='align-271c' and kind='tool_start'; select count(*) from events where session='align-271c' and kind='evidence'; select count(*) from events where session='align-271c' and body like '%---BEGIN CONTENT---%';"` -> retornou `1`, `1`, `0`.

## T272 - Tornar evidencia inicial propriedade do controller

Status: implemented-verified.

Motivacao: revisao da regra de negocio apos a T271 apontou um erro conceitual: para perguntas sobre workspace/codigo/projeto, `collect_evidence` nao deve depender de uma decisao opcional do modelo. A evidencia e o contexto minimo que o modelo usa para responder e para decidir se precisa de outra tool. Logo, a primeira coleta deve ser preflight do controller quando o tool loop esta ativo; o modelo so deve pedir novas coletas quando a evidencia inicial for insuficiente ou quando precisar de outro range/path/estrategia.

Evidencia:

- O audit exige que tools de coleta serializem dados em contexto destilado minimo com evidencia tangivel, sem vazar raw context.
- A T271 reduziu superficie e estrategias, mas ainda deixava a primeira evidencia depender do comportamento do modelo.
- Smoke real `align-271` mostrou que o modelo pode responder sem ferramenta e ainda passar no marcador, criando falsa confiabilidade.
- Smoke real `align-271b` e `align-271c` mostraram que, quando a evidencia entra no contexto, o fluxo melhora, mas a decisao inicial ainda estava no lugar errado.

Impacto esperado:

- Todo turno com `PHENOM_TOOL_LOOP_V1=1` executa `collect_evidence(auto)` antes da primeira inferencia.
- O primeiro `model_context` ja contem `[EVIDENCE]`, sem exigir que o modelo descubra sozinho que precisa de contexto do workspace.
- O modelo continua autorizado a chamar `collect_evidence` de novo, mas somente para evidencia adicional diferente e dentro de budget/qualidade.
- Falha no preflight vira `tool_error` auditado e status visual, nao falha falsa de infraestrutura.
- O fluxo fica alinhado com a visao do projeto: controller cuida de protocolo, evidencia, budget e auditoria; modelo raciocina sobre contexto destilado.

Teste primeiro:

- Teste de `buildInitialModelContext` prova que evidencia inicial entra no contexto com schema compacto.
- Teste de schema prova que apenas `auto|path|lexical` continuam visiveis.
- Smoke real de pergunta ambigua sobre projeto deve renderizar `collect_evidence: preflight:auto` antes da resposta.
- SQLite do smoke real deve mostrar `tool_start=1`, `evidence=1`, `model_context` contendo `[EVIDENCE]` e zero raw marker.

Implementacao:

- `phenom-zig/src/main.zig`: criar `collectInitialEvidence` para executar `collect_evidence(auto)` antes da primeira chamada ao backend quando `PHENOM_TOOL_LOOP_V1=1`.
- `phenom-zig/src/main.zig`: auditar preflight com `tool_start`, `tool_event`, `evidence` e renderizar evento visual de tool.
- `phenom-zig/src/main.zig`: passar `initial_evidence` para `buildInitialModelContext`.
- `phenom-zig/src/main.zig`: atualizar `next_action` inicial para tratar `[EVIDENCE]` como contexto minimo do workspace, nao como sugestao opcional.
- `phenom-zig/src/main.zig`: manter schema `collect_evidence` disponivel para coletas adicionais diferentes.

Passos de implementacao:

1. Inserir preflight antes de `buildInitialModelContext`.
2. Auditar e renderizar a coleta inicial como tool normal.
3. Injetar EvidencePacket no primeiro `model_context`.
4. Ajustar instrucao inicial para groundedness sobre evidencia ja coletada.
5. Validar teste unitario, build, smoke real e SQLite.

Revisao baixo nivel obrigatoria antes do commit:

- Memoria: `preflight_evidence` fica owned pelo turno e e liberado com `defer result.deinit(allocator)`.
- Ownership: `buildInitialModelContext` recebe slice emprestado de `preflight_evidence` apenas durante renderizacao, antes do `defer`.
- Bounds: preflight usa budget fixo de 6000 bytes e o executor continua aplicando limites internos de candidatos/ranges.
- Erro: falha de preflight e registrada como `tool_error` e o turno pode seguir sem mascarar como `ConnectFailed`.
- Raw leak: SQLite do smoke final retornou zero ocorrencias de `---BEGIN CONTENT---`.
- Regra de negocio: nao ha heuristica linguistica nem inferencia por prompt; o preflight e uma etapa do perfil `code_micro` quando o tool loop esta ativo.

Criterio de aceite:

- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real com pergunta natural sobre o projeto passa e mostra preflight.
- SQLite confirma que a evidencia entrou no primeiro contexto enviado ao modelo.

Pendencias deliberadas:

- O preflight ainda usa `auto`; selecao de contrato/perfil alem de `code_micro` deve vir de `context profiles`, nao de keywords do prompt.
- `README.md` foi corrigido para enquadrar o produto como desenvolvimento final em Zig + C; se a resposta real herdar linguagem de base descartavel, a causa deve ser outra evidencia antiga ou cache de contexto.
- Ainda falta groundedness formal por claims/citacoes para impedir que o modelo acrescente detalhes nao evidenciados em linguagem natural.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/contracts.zig -lc` -> passou; 5 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc` -> passou; 12 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 33 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_envelope.zig -lc` -> passou; 16 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 133 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `PHENOM_TOOL_LOOP_V1=1 ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt 'Analise esse projeto e me diga, em termos simples, o que ele faz. Termine exatamente com: PHENOM_PREFLIGHT_272' --expect-contains PHENOM_PREFLIGHT_272 --show-expect-status --fail-on-model-error --session preflight-272` -> passou; renderizou `collect_evidence: preflight:auto` e respondeu com marcador.
- `sqlite3 phenom-zig/.phenom-zig/phenom.db "select 'tool_start', count(*) from events where session='preflight-272' and kind='tool_start'; select 'evidence', count(*) from events where session='preflight-272' and kind='evidence'; select 'raw_marker', count(*) from events where session='preflight-272' and body like '%---BEGIN CONTENT---%'; select 'model_context_evidence', count(*) from events where session='preflight-272' and kind='model_context' and body like '%[EVIDENCE]%';"` -> retornou `1`, `1`, `0`, `1`.

## T273 - Corrigir fluxo de intent do modelo antes da coleta de evidencia

Status: implemented-verified.

Motivacao: teste de producao mostrou que a T272 corrigiu uma falha operacional, mas pelo caminho errado. O log real:

```text
> [ashirak] o que este projeto implementa em cwd ?

│ thinking
│ ... não há contexto fornecido ...

Não tenho contexto sobre qual projeto você está se referindo.
```

provou que o tool loop ainda dependia de `PHENOM_TOOL_LOOP_V1` em producao. A primeira reacao de transformar isso em config/flag tambem estava errada: tool loop nao e opcao, e regra de negocio intrinseca do Phenom. A correcao final precisa respeitar o fluxo definido pelo projeto:

1. `prompt -> model intent of user query`;
2. `model intent -> agent process contract/strategies`;
3. `contract/strategies -> micro-context/evidence`;
4. `model process evidence/context`;
5. `loop inference`.

Evidencia:

- O audit e as tasks descrevem contratos como endpoints model-visible e estrategias como funcoes do contrato.
- O modelo deve expressar a intencao de busca no proprio tool call; o agente nao deve adivinhar termos pelo prompt original.
- O log de producao sem env nao executou `collect_evidence`, portanto o contrato nao era intrinseco.
- O erro posterior `collect_evidence preflight:auto StreamTooLong` mostrou que preflight amplo do controller tambem era errado: alem de pular a intencao do modelo, podia varrer workspace demais.
- `std.Io.Dir.cwd().walk(std.testing.io)` gerou `BADF`, mostrando outro bug baixo nivel no inventario estrutural.

Impacto esperado:

- Chat real sempre carrega schema de `collect_evidence` e bufferiza possivel tool call; nao ha `PHENOM_TOOL_LOOP_V1`, config `tool_loop` ou flag `--no-tool-loop`.
- O primeiro passo de contexto e model-visible: o modelo infere a intencao e chama `collect_evidence`.
- `collect_evidence` aceita `terms` opcional, owned, vindo do modelo.
- O ranker usa `terms` como consulta; se `terms` nao vier, `auto` cai para inventario estrutural neutro, nao para keywords do prompt do usuario.
- Inventario estrutural nao usa stdout gigante (`rg --files`/preflight amplo); usa `opendir/readdir` com budget de paths e ignora storage operacional.
- `StreamTooLong` em keyword discovery deixa de derrubar o turno; vira ausencia de candidatos naquela fase.

Teste primeiro:

- `tool_call` prova parse e ownership de `<parameter=terms>...</parameter>`.
- `collect_evidence` prova que `terms` guia ranking lexical/auto.
- `collect_evidence(auto)` sem `terms` prova fallback para `workspace_overview`, com `terms=0` auditado.
- `evidence_ranker` prova que inventario estrutural nao depende de `std.Io.Dir.walk`.
- `main` prova que schema contem `terms` e que tool loop nao depende de env.
- Smoke real sem `PHENOM_TOOL_LOOP_V1` deve executar `collect_evidence`, responder e auditar `tool_error=0`.

Implementacao:

- `phenom-zig/src/main.zig`: remover dependencia de `toolLoopEnabled`/`PHENOM_TOOL_LOOP_V1`; chat real sempre usa tool loop.
- `phenom-zig/src/main.zig`: remover preflight do controller criado na T272; contexto inicial volta a conter contrato, nao evidencia pre-coletada.
- `phenom-zig/src/main.zig`: atualizar schema para `collect_evidence(path?, terms?, strategy=auto|path|lexical, ...)`.
- `phenom-zig/src/tool_call.zig`: adicionar `terms` owned em `ToolCall`, parser XML e `deinit`.
- `phenom-zig/src/collect_evidence.zig`: adicionar `Args.terms`; ranking usa `terms`, nao `task`.
- `phenom-zig/src/evidence_ranker.zig`: limitar stdout de `rg -c`; `StreamTooLong` nao vira erro fatal.
- `phenom-zig/src/evidence_ranker.zig`: trocar `std.Io.Dir.walk` por inventario C `opendir/readdir`, limitado por budget.
- `phenom-zig/src/evidence_ranker.zig`: ignorar `.git`, caches, build output e storages operacionais `.phenom-*`.

Passos de implementacao:

1. Remover opcionalidade de tool loop.
2. Remover preflight automatico do controller.
3. Adicionar `terms` ao contrato e ao parser.
4. Propagar `terms` para executor e ranker.
5. Corrigir inventario estrutural para nao gerar `StreamTooLong` nem `BADF`.
6. Validar offline, build release e smoke real sem env.

Revisao baixo nivel obrigatoria antes do commit:

- Ownership: `ToolCall.terms` e duplicado no parser e liberado em `deinit`.
- Ownership: dedupe de tool call duplica `terms` e libera em `ToolCallKey.deinit`.
- C interop: cada `opendir` bem-sucedido tem `closedir`; strings `dupeZ` sao liberadas.
- Bounds: inventario estrutural para em `max_candidates * 8`; keyword discovery tem `stdout_limit`.
- Segurança/contexto: `.git`, `zig-cache`, `zig-out`, `node_modules`, `bin`, `.phenom-zig`, `.phenom-context` e `.phenom-sessions` sao ignorados no inventario.
- Regra de negocio: agente nao interpreta prompt original como query; `terms` vem do modelo. Sem `terms`, `auto` usa overview estrutural auditado.

Criterio de aceite:

- `zig test src/tool_call.zig -lc` passa.
- `zig test src/evidence_ranker.zig -lc` passa.
- `zig test src/collect_evidence.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real sem env executa `collect_evidence` e nao mostra `StreamTooLong`.
- SQLite do smoke real mostra `tool_start=1`, `tool_error=0`, `raw_marker=0`, `terms_marker=1`.

Pendencias deliberadas:

- A resposta real ainda depende da qualidade dos `terms` que o modelo escolhe; isso e desejado pelo fluxo, mas a proxima evolucao deve melhorar o schema compacto e exemplos para induzir termos mais especificos.
- Contratos dinamicos alem de `collect_evidence` continuam pendentes; nao foram falsamente anunciados.
- Groundedness por claims/citacoes ainda falta para impedir extrapolacao fina em texto final.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc` -> passou; 12 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc` -> passou; 12 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc` -> passou; 34 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 134 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt 'o que este projeto implementa em cwd ?' --session flow-terms-273 --fail-on-model-error` -> passou sem env; renderizou `collect_evidence: auto`, respondeu e nao mostrou `StreamTooLong`.
- `sqlite3 .phenom-zig/phenom.db "select 'tool_start', count(*) from events where session='flow-terms-273' and kind='tool_start'; select 'tool_error', count(*) from events where session='flow-terms-273' and kind='tool_error'; select 'raw_marker', count(*) from events where session='flow-terms-273' and body like '%---BEGIN CONTENT---%'; select 'terms_marker', count(*) from events where session='flow-terms-273' and body like '%terms=%';"` -> retornou `1`, `0`, `0`, `1`.

## T274 - Implementar contexto descartavel para exploracao guiada por modelo

Status: implemented-verified.

Motivacao: a T273 corrigiu a causa principal do fluxo errado: o agente nao deve adivinhar o que buscar a partir do prompt original; o modelo deve inferir a intencao e chamar `collect_evidence` com `terms`, `path`, `strategy` e demais parametros. Falta agora impedir que varias exploracoes corretas inflem o contexto do modelo. O fluxo desejado e exploratorio: o modelo pode analisar uma evidencia, concluir que ela e insuficiente e emitir outra coleta mais especifica. Isso exige um working set descartavel/compactavel, como a referencia TS ja fazia com working memory, active micro-context e `compact=true`, mas sem reintroduzir `build_task_context`, preflight do controller ou heuristicas semanticas.

Evidencia:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` pede `collect_evidence` como contrato operacional unico, micro-contexto com id/hash/range e raw context descartado.
- `TASKS.md` ja define que tools sao coletores e que o modelo recebe apenas evidencia destilada em `EvidencePacket`/`ModelTurnContext`.
- `../phenom-cli-ts/src/tools/registrars/context-tools.ts` retorna `raw_context_persisted: false`, `[MICRO_CONTEXT]`, `[NEXT_ACTION]` e orienta nova chamada quando a evidencia esta incompleta.
- `../phenom-cli-ts/src/memory/memory-orchestrator.ts` separa `[WORKING_MEMORY]` de `[PERSISTENT_MEMORY]` e limpa working memory com `collect_evidence(compact=true)`.
- `../phenom-cli-ts/src/tests/integration/test-use-cases.ts` prova active micro-context apos compactacao, rehidratacao em follow-up e supressao de snippets ativos quando ficam stale.
- `phenom-zig/src/main.zig` hoje acumula `state.evidence_texts` completos e renderiza todos no proximo `ModelTurnContext`; isso funciona para uma ou duas coletas, mas nao escala para exploracao guiada longa.

Regra de negocio:

- O modelo e o cerebro da busca: ele define `terms`, `path`, `strategy`, `selected`, `need` ou `compact`.
- O agente nao cria termos, nao escolhe foco por palavras do prompt, nao prefere source/docs/test por semantica hardcoded e nao executa preflight de evidencia antes da intencao do modelo.
- O agente executa contrato, valida allowlist/schema/budget/duplicidade/stale/raw leak, audita e compacta contexto operacional.
- Contexto descartavel nao e `MEMORY.md` nem `SKILLS.md`. MEMORY/SKILLS continuam sendo contexto persistente de projeto/usuario. Working evidence e storage operacional do turno/sessao.

Ajuste firmado apos revisao:

- `WorkingContext` e nome de estado interno do agente, nao memoria do modelo.
- O contexto temporario sai da "memoria" do modelo quando o agente deixa de reenviar esse texto no proximo request.
- O produto model-visible deve ser chamado e tratado como `OperationalEvidenceContext`: evidencia operacional minima, intrinseca, tangivel e proporcional ao pedido atual.
- O contexto operacional pode existir no SQLite/audit para replay, mas nao vira contexto permanente do modelo e nao aparece em `[MEMORY]`/`[SKILLS]`.
- O backend local deve ser tratado como stateless do ponto de vista semantico. KV cache, prompt cache ou session cache do servidor sao otimizacoes, nao fonte autoritativa de contexto.
- Se um backend mantiver conversa invisivel fora do prompt enviado pelo agente, esse modo deve ser considerado incompatível com replay/audit ou deve ser desabilitado.
- A fonte de verdade de cada turno e: prompt renderizado pelo agente + eventos auditados no SQLite.
- A memoria persistente textual segue exclusiva: `MEMORY.md`/`.MEMORY.md` e `SKILLS.md`/`.SKILL.md`, somente quando existem ou quando ha promocao explicita futura.

Modelo de requests:

```text
request 1:
  [TURN_CONTEXT v1]
  [CONTRACTS]
  user prompt

modelo:
  collect_evidence(terms/path/strategy definidos pelo modelo)

agente:
  raw tool output -> ToolEvent -> EvidenceEntry -> EvidencePacket -> WorkingContext interno

request 2:
  [TURN_CONTEXT v1]
  [CONTRACTS]
  [EVIDENCE] OperationalEvidenceContext minimo
  [NEXT_ACTION] responder ou refinar

request 3 opcional:
  [EVIDENCE] evidencia ativa mais recente
  [ANCHORS] evidencias antigas compactas
```

Regra de descarte:

- Texto completo de evidencia so fica model-visible enquanto for ativo e couber no budget.
- Quando compactado, o texto completo deixa de ser reenviado; ficam apenas anchors como `E1 path/range/hash/contextId/resumo`.
- Quando nao for mais util, ate o anchor sai do prompt.
- Nada e apagado da auditoria; apenas deixa de ser renderizado para o modelo.
- Nao existe tentativa de apagar KV cache interno do servidor; o controle correto e nao reenviar o conteudo e usar modo stateless/reprodutivel.

Compatibilidade com tasks correlatas:

- T050/T204: esta task nao substitui `EvidencePacket`; ela define como o packet entra e sai do contexto model-visible.
- T060/T061/T062: micro-contexto continua sendo path/range/hash para edicao segura; compactacao nao remove a obrigacao de validar stale antes de patch.
- T070-T077/T205: `ModelTurnContext` continua sendo o unico renderer oficial do que vai ao modelo.
- T074/T120/T121/T162/T206: contexto operacional nao compete com MEMORY/SKILLS e nao promove nada automaticamente.
- T150-T150D/T208-T210: esta task e para `code_micro`; News, PDF/log e runtime continuam dependendo de `ContextProfile` proprio, nao de micro-contexto de codigo.
- T271/T273: nao reintroduz heuristica, preflight automatico nem gate por keywords; a intencao continua vindo do modelo via contrato.

Alvo final:

1. O modelo recebe schema compacto de `collect_evidence` com parametros model-driven:
   - `terms`: consulta criada pelo modelo;
   - `path`: path relativo quando conhecido;
   - `strategy`: somente estrategias ativas e executaveis;
   - `start_line`/`max_lines`: range quando conhecido;
   - `compact`: sinal explicito de que a exploracao atual pode virar resumo/anchors;
   - futuro `selected`: ids de evidencias/candidatos retornados por chamada anterior.
2. Cada chamada de `collect_evidence` gera uma entrada de working evidence com:
   - id estavel (`E1`, `E2` ou `ev_*`);
   - args normalizados;
   - path/range/hash/contextId quando houver;
   - qualidade/custo;
   - texto destilado model-visible;
   - raw output somente no SQLite/audit, nunca no prompt.
3. O `ModelTurnContext` renderiza somente:
   - `OperationalEvidenceContext` com evidencias ativas recentes ou selecionadas;
   - anchors compactos das evidencias antigas, sem snippets completos antigos;
   - `[NEXT_ACTION]` curto dizendo que o modelo pode refinar se a evidencia nao bastar.
4. O loop para por budget/duplicidade/ausencia de progresso/erro recuperavel, nao por numero fixo de chamadas.
5. A cada patch/mutacao futura, micro-context stale remove snippets ativos e preserva apenas anchors/obrigacoes.

Teste primeiro:

- `working_context` guarda duas coletas diferentes com `terms` diferentes e renderiza ambas enquanto cabem no budget.
- `working_context` bloqueia coleta duplicada com mesmos `path/terms/strategy/range`, mas permite coleta diferente no mesmo turno.
- `working_context` compacta evidencia antiga para anchors quando o budget model-visible e excedido.
- `working_context compact=true` limpa snippets ativos e preserva somente anchors/next action.
- `working_context` prova que contexto completo antigo nao e reenviado apos compactacao.
- `model_context` nunca renderiza `---BEGIN CONTENT---`, raw `rg`, stdout bruto ou markers internos.
- `model_context` prova que `[MEMORY]`/`[SKILLS]` nao aparecem por causa de working evidence ou SQLite operacional.
- `http`/`main` deve auditar o prompt/contexto enviado para replay e nao depender de memoria invisivel do backend.
- `runOneToolLoopStep` usa working context para renderizar follow-up, nao `state.evidence_texts` bruto.
- Smoke real ambigue deve permitir: primeira coleta ampla -> modelo emite segunda coleta refinada -> resposta final grounded, sem repetir evidencia identica.

Implementacao:

- Criar `phenom-zig/src/working_context.zig`.
- Definir `WorkingEvidence` owned:
  - `id`;
  - `path`;
  - `terms`;
  - `strategy`;
  - `start_line`;
  - `max_lines`;
  - `context_id`;
  - `evidence_text`;
  - `anchor_text`;
  - `model_bytes`;
  - `quality_score`;
  - `stale`.
- Definir `WorkingContext` owned:
  - lista de evidencias;
  - `model_budget_limit`;
  - `model_budget_used`;
  - `best_quality`;
  - contador de duplicidade;
  - metodos `remember`, `hasDuplicate`, `remainingBudget`, `shouldAllowMoreEvidence`, `compact`, `renderEvidenceBlocks`.
- Definir `OperationalEvidenceContext` como saida renderizavel derivada do `WorkingContext`, sem ownership de raw output.
- Migrar `ToolLoopState` em `phenom-zig/src/main.zig` para usar `WorkingContext`.
- Manter `ToolCallKey` somente se ainda for o menor caminho; se `WorkingEvidence` ja cobre duplicidade, remover duplicacao.
- Atualizar `renderCollectedEvidenceContext` para receber working context e renderizar active evidence + compact anchors.
- Adicionar `compact` ao parser de tool call somente depois do teste falhar.
- Atualizar schema de `collectEvidenceToolSchema` com `compact=true`, deixando claro que o modelo decide quando compactar apos explorar.
- Auditar eventos novos no SQLite:
  - `working_context_add`;
  - `working_context_compact`;
  - `working_context_duplicate`;
  - `working_context_budget`.

Passos de implementacao:

1. Criar testes de `working_context.zig` para ownership, dedupe, budget, compactacao e render sem raw leak.
2. Implementar `working_context.zig` minimo ate os testes passarem.
3. Criar teste em `tool_call.zig` para `<parameter=compact>true</parameter>` owned/boolean.
4. Implementar parse de `compact`.
5. Criar teste em `main.zig` provando que duas coletas diferentes entram no working context e duplicata nao reexecuta.
6. Criar teste em `model_context.zig` provando que working evidence nao cria MEMORY/SKILLS nem reenvia evidencia compactada completa.
7. Trocar `ToolLoopState.evidence_texts` por `WorkingContext`.
8. Atualizar schema e `NEXT_ACTION` para refinamento model-driven sem exemplos enviesados de dominio.
9. Registrar eventos SQLite de add/compact/duplicate/budget e prompt/contexto renderizado para replay.
10. Rodar unit tests, build release e smoke real com query ambigua.
11. Revisar memoria/ownership/bounds/raw leak antes do commit.

Revisao baixo nivel obrigatoria antes do commit:

- Ownership: toda string em `WorkingEvidence` deve ser duplicated/owned e liberada em `deinit`.
- Stale pointer: nenhum `EvidenceBlock` pode apontar para stack temporaria apos render.
- Bounds: compactacao deve acontecer antes de ultrapassar `model_budget_limit`; nenhum append pode depender de `ArrayList.items` apos possivel realloc sem reobter slice.
- Raw leak: `working_context.render*` deve chamar ou espelhar `model_context.assertNoRawContextLeak`.
- Duplicidade: chave deve incluir `path`, `terms`, `strategy`, `start_line`, `max_lines`; chamada diferente nao pode ser bloqueada.
- SQLite: audit pode guardar resumo bruto suficiente, mas prompt so recebe destilado/anchors.
- Backend: nenhum codigo deve depender de session state invisivel do servidor; prompt renderizado precisa ser suficiente para replay.
- Prompt cache: se existir, deve ser tratado como performance; teste de replay deve passar sem assumir cache.
- Regra de negocio: nenhuma lista de stopwords, lista fixa de arquivos, preferencia por linguagem, preferencia source/docs/test ou extracao de termos do prompt original.

Criterio de aceite:

- `zig test src/working_context.zig -lc` passa.
- `zig test src/tool_call.zig -lc` passa.
- `zig test src/model_context.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real sem env mostra pelo menos uma chamada model-driven de `collect_evidence`.
- Smoke real de refinamento nao repete evidencia identica; se o modelo pedir outra coleta com termos/path diferentes, o agente executa.
- SQLite mostra `working_context_add`, zero raw marker em `model_context`, e motivo de parada por budget/qualidade/duplicidade quando aplicavel.
- SQLite mostra o `model_context` exato usado no follow-up e permite demonstrar que evidencia compactada completa nao foi reenviada.
- Nenhum teste cria `[MEMORY]`/`[SKILLS]` a partir de working evidence, SQLite ou audit.

Pendencias deliberadas:

- `selectedCandidates`/`selected` deve ficar para a proxima task se exigir mudar o ranker para emitir ids candidatos antes de materializar snippets.
- Estrategias `symbol`, `semantic`, `diagnostic`, `runtime` e `diff` continuam inativas ate terem executor real.
- Groundedness por claim/citacao ainda e task separada: esta task limita crescimento de contexto e preserva evidencia, mas nao valida cada frase final do modelo.
- Persistencia cross-session do working context deve usar SQLite/audit e rehidratacao controlada como contexto operacional minimo, quando explicitamente retomado; nao deve ser promovida para MEMORY automaticamente.
- Politica fina para backends stateful fica pendente: por enquanto, o contrato de produto assume requests semanticamente stateless e replayavel.
- Smoke real `working-context-274b` ainda mostrou extrapolacao fina do modelo sobre capacidades model-visible. Isso nao foi corrigido por heuristica nesta task; deve ser tratado por groundedness/citacoes em task propria.

Implementado:

- `phenom-zig/src/working_context.zig`: novo estado operacional interno com `WorkingEvidence`, `WorkingContext`, dedupe por `path/terms/strategy/range`, budget cumulativo de tool, budget de render, anchors compactos, `compactAll`, render de `EvidenceBlock` e anti-raw via `model_context.assertNoRawContextLeak`.
- `phenom-zig/src/working_context.zig`: evidencias ativas maiores que 12 KiB sao truncadas antes de entrar no prompt com `[EVIDENCE_TRUNCATED]`; bruto permanece auditavel fora do prompt.
- `phenom-zig/src/tool_call.zig`: parse de `<parameter=compact>true</parameter>` para permitir compactacao model-driven.
- `phenom-zig/src/main.zig`: `ToolLoopState` passou a delegar armazenamento real para `WorkingContext`.
- `phenom-zig/src/main.zig`: duplicatas usam `WorkingContext.hasDuplicate`, chamadas diferentes continuam permitidas.
- `phenom-zig/src/main.zig`: follow-up `ModelTurnContext` agora renderiza blocos derivados do working context, nao array bruto de evidencias.
- `phenom-zig/src/main.zig`: schema model-visible anuncia `compact=false` de forma compacta e sem exemplos enviesados de dominio.
- `phenom-zig/src/main.zig`: SQLite registra `working_context_add`, `working_context_compact`, `working_context_duplicate` e `working_context_budget` quando aplicavel.

Revisao baixo nivel realizada:

- Ownership: `WorkingEvidence` duplica `id`, `path`, `terms`, `context_id`, `evidence_text` e `anchor_text`; `deinit` libera todos.
- Failure path: `WorkingContext.remember` usa `errdefer` para liberar cada alocacao antes de transferir ownership para `ArrayList`.
- Stale pointer: `renderEvidenceBlocks` retorna apenas array temporario de `EvidenceBlock`; os textos apontam para memoria owned pelo `WorkingContext`, vivo durante `renderModelTurnContext`.
- Bounds: `tool_budget_spent` e cumulativo e nao diminui com compactacao; compactar contexto nao permite exploracao infinita.
- Bounds: `max_active_evidence_bytes` limita evidencia ativa model-visible antes de renderizar prompt.
- Raw leak: `remember` valida evidencia ativa e anchor contra marcadores proibidos.
- Duplicidade: chave inclui `path`, `terms`, `strategy`, `start_line`, `max_lines`; smoke real e testes provam que `terms` diferentes nao compartilham chave.
- Backend: nenhuma dependencia nova de session state invisivel; `model_context` continua auditado no SQLite.
- Regra de negocio: nao foi adicionada lista de stopwords, lista fixa de arquivos, preferencia por linguagem/source/docs/test nem extracao de termos do prompt original.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/working_context.zig -lc` -> passou; 45 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc` -> passou; 13 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 141 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 620 --prompt "o que este projeto implementa em cwd ?" --session working-context-274b --fail-on-model-error` -> passou; modelo chamou `collect_evidence`.
- `sqlite3 .phenom-zig/phenom.db "select kind, count(*) from events where session='working-context-274b' and kind in ('tool_start','tool_error','working_context_add','working_context_compact','working_context_duplicate','model_context','evidence') group by kind order by kind;"` -> retornou `evidence=1`, `model_context=2`, `tool_start=1`, `working_context_add=1`, nenhum `tool_error`.
- `sqlite3 .phenom-zig/phenom.db "select length(body) from events where session='working-context-274b' and kind='model_context' order by id;"` -> retornou `1390` e `14183`, provando follow-up limitado apos teto de evidencia ativa.
- `sqlite3 .phenom-zig/phenom.db "select 'raw_marker', count(*) ...; select 'memory_block', count(*) ...; select 'skills_block', count(*) ...; select 'truncated', count(*) ...;"` -> retornou `raw_marker=0`, `memory_block=0`, `skills_block=0`, `truncated=1`.

## T275 - Adicionar contexto operacional de sessao e busca guiada pelo modelo

Status: implementado nesta etapa.

Motivacao: apos T274, o agente tinha contexto de evidencias do turno, mas o modelo ainda nao tinha acesso confiavel a conversas anteriores da mesma sessao. Isso degradava fidelidade em perguntas como "o que combinamos antes?", porque dependeria de memoria invisivel do backend ou de reenviar historico bruto. A regra de negocio exige replay auditavel: SQLite e storage operacional, MEMORY/SKILLS sao contexto persistente textual separado, e o modelo deve escolher a intencao de busca.

Evidencias analisadas:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` aponta conflitos de fontes de memoria, session brain e contexto operacional competindo com `.MEMORY.md`.
- T274 define que working evidence pode existir no SQLite/audit para replay, mas nao vira MEMORY/SKILLS.
- `phenom-zig/src/audit.zig` ja armazenava eventos de sessao no SQLite, mas `loadSessionEvents(... limit ...)` lia os eventos mais antigos quando a sessao crescia.
- `phenom-zig/src/main.zig` auditava `model_context`, `turn_start`, `assistant_delta`, `tool_start`, `working_context_add` e `turn_done`, que sao suficientes para contexto operacional destilado.

Alvo final:

1. Conversa anterior deve entrar no modelo como `[SESSION_CONTEXT]`, temporaria e auditavel.
2. O modelo pode chamar `search_session(terms)` quando precisar procurar fato anterior em uma sessao grande.
3. `terms` vem do modelo; o agente nao extrai intencao do prompt do usuario e nao usa heuristica linguistica hardcoded.
4. SQLite continua sendo storage operacional/replay, nao MEMORY/SKILLS.
5. Contexto bruto e markers internos nunca vazam para o modelo.
6. Backend local continua semanticamente stateless; a fonte de verdade e prompt renderizado + SQLite audit.

Teste primeiro:

- `session_context` renderiza contexto recente sem incluir o prompt atual.
- `session_context.search` usa somente termos fornecidos pelo modelo.
- `session_context.search` ignora eventos raw-heavy como `model_context`.
- `session_context` redige markers proibidos em eventos uteis antigos antes de renderizar.
- `model_context` renderiza `[SESSION_CONTEXT]` separado de `[MEMORY]` e `[SKILLS]`.
- `tool_envelope` aceita `search_session` somente porque o contrato ativo anunciou a tool.
- `main` prova que contexto coletado pode conter evidencia de sessao temporaria sem promover memoria persistente.
- `audit` prova que leitura recente de sessao pega os eventos mais novos e preserva ordem cronologica.

Implementacao:

- Criar `phenom-zig/src/session_context.zig`.
- Definir `SearchResult` owned com `text` e `matches`.
- Implementar `renderRecent`:
  - carrega eventos uteis recentes;
  - exclui `turn_start` igual ao prompt atual;
  - compacta cada evento para uma linha curta;
  - valida anti-raw antes de retornar.
- Implementar `search`:
  - percorre eventos auditados;
  - pontua apenas por termos fornecidos pelo modelo;
  - ordena por score e recencia;
  - retorna `[SESSION_EVIDENCE]` com ids `S#`;
  - nao usa stopwords, preferencias de arquivo, source/docs/test ou inferencia do prompt original.
- Adicionar `SessionBlock` em `model_context.zig`.
- Adicionar `[GROUNDING]` com regras compactas:
  - claims de workspace citam `E#`;
  - claims de sessao citam `S#`;
  - sem evidencia, declarar que nao esta evidenciado.
- Adicionar `search_session` ao contrato ativo executavel.
- Roteamento em `main.zig`:
  - `buildInitialModelContext` injeta sessao recente quando houver;
  - `runOneToolLoopStep` executa `search_session`;
  - busca repetida com os mesmos termos e deduplicada no turno;
  - resultado de busca entra em follow-up como contexto temporario.
- Adicionar `loadRecentSessionEvents` em `audit.zig` para sessoes longas.

Passos de implementacao:

1. Criar testes unitarios de `session_context.zig`.
2. Adicionar `SessionBlock` e teste de separacao MEMORY/SKILLS em `model_context.zig`.
3. Expor `search_session` no contrato ativo e teste de allowlist.
4. Aceitar `search_session` no envelope model-visible.
5. Integrar `buildInitialModelContext` com SQLite audit recente.
6. Integrar `runSearchSessionStep` ao tool loop.
7. Corrigir leitura recente de SQLite para nao usar eventos antigos em sessoes longas.
8. Redigir markers brutos em contexto de sessao antes do prompt.
9. Rodar unitarios, build release e smoke real de recuperacao de sessao.
10. Consultar SQLite para provar `[SESSION_CONTEXT]`, zero raw leak e zero promocao para MEMORY/SKILLS.

Revisao baixo nivel realizada:

- Ownership: `SearchResult.text` e owned e liberado por `deinit`.
- Ownership: `ToolLoopState.session_searches` duplica `terms`; `rememberSessionSearch` usa `errdefer` para nao vazar se `append` falhar.
- Stale pointer: `SessionBlock` aponta para texto vivo durante `renderModelTurnContext`; o texto so e liberado apos render.
- Bounds: cada item de sessao e limitado por `max_entry_bytes`; resultado retorna no maximo `max_search_entries`.
- Raw leak: `model_context.assertNoRawContextLeak` roda no render recente e na busca.
- Raw leak: eventos `model_context` nao entram em busca; markers proibidos em eventos uteis sao redigidos.
- Long session: `loadRecentSessionEvents` busca os ultimos N eventos e reordena cronologicamente.
- Regra de negocio: nenhuma memoria operacional e promovida para `[MEMORY]`/`[SKILLS]`.
- Regra de negocio: a busca de sessao nao usa heuristica linguistica hardcoded; o modelo fornece `terms`.

Criterio de aceite:

- `zig test src/session_context.zig -lc -lsqlite3` passa.
- `zig test src/audit.zig -lc -lsqlite3` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real em dois turnos recupera acordo anterior da sessao sem reenviar historico bruto.
- SQLite mostra `[SESSION_CONTEXT]` em `model_context`.
- SQLite mostra `raw_marker=0` em `model_context`.
- SQLite mostra que o fato de sessao nao virou `[MEMORY]` nem `[SKILLS]`.

Pendencias deliberadas:

- Busca "semantica" aqui significa busca operacional guiada pela intencao semantica emitida pelo modelo em `terms`. Nao foi adicionado embedding local, LSH ou vetor no SQLite nesta task, porque isso exigiria nova dependencia/infra e ainda precisaria de uma politica de budget propria.
- Validador semantico de todas as claims finais ainda nao existe. A task adiciona regras de groundedness e evidencia `S#`/`E#`, mas nao bloqueia automaticamente uma frase final sem citacao.
- Cross-session global search fica pendente; esta etapa limita recuperacao ao `session` atual para manter replay e isolamento.

Implementado:

- `phenom-zig/src/session_context.zig`: novo modulo para contexto operacional temporario de sessao.
- `phenom-zig/src/model_context.zig`: `[SESSION_CONTEXT]` e `[GROUNDING]`.
- `phenom-zig/src/contracts.zig`: `search_session` model-visible e permitido no contrato ativo.
- `phenom-zig/src/tool_envelope.zig`: teste de envelope aceito para `search_session`.
- `phenom-zig/src/main.zig`: injecao de contexto recente, schema, roteamento, dedupe e follow-up de `search_session`.
- `phenom-zig/src/audit.zig`: `loadRecentSessionEvents`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` -> passou; 49 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/audit.zig -lc -lsqlite3` -> passou; 17 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 147 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --session session-context-275 --prompt 'Nesta sessão, registre o seguinte acordo operacional: o renderer do Phenom deve ser append-only e preservar copia direta do terminal. Responda exatamente: PHENOM_SESSION_SEED_275' --expect-contains PHENOM_SESSION_SEED_275 --show-expect-status --fail-on-model-error` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 520 --session session-context-275 --prompt 'Qual foi o acordo operacional que combinamos sobre o renderer do Phenom nesta sessão? Responda com uma frase e termine exatamente com: PHENOM_SESSION_RECALL_275' --expect-contains PHENOM_SESSION_RECALL_275 --show-expect-status --fail-on-model-error` -> passou; modelo recuperou o acordo.
- `sqlite3 .phenom-zig/phenom.db "select 'raw_marker', count(*) ...; select 'session_context', count(*) ...; select 'memory_from_session', count(*) ...; select 'skills_from_session', count(*) ...;"` -> retornou `raw_marker=0`, `session_context=2`, `memory_from_session=0`, `skills_from_session=0`.

## T276 - Adicionar FTS5/BM25 interno ao ranking de evidencia

Status: implementado nesta etapa.

Motivacao: a discussao sobre embeddings concluiu que o produto nao deve exigir dois modelos ativos. O caminho correto para o core e manter um unico modelo de chat e fortalecer recuperacao com ferramentas deterministicas: `rg`, SQLite FTS5/BM25, AST/LSP e contratos. Esta task implementa a primeira parte dessa frente: FTS5/BM25 interno como fonte de candidatos para `collect_evidence`, sem ativar embeddings e sem anunciar estrategia nova ao modelo.

Evidencias analisadas:

- `phenom-zig/src/evidence_ranker.zig` ja usava `rg` para termos estruturados e `keyword_discovery` para termos naturais, mas perguntas ambiguas podiam cair em arquivos genericamente populares.
- Smoke real `fts-bm25-276` mostrou que `keyword_discovery` encheu o budget antes de FTS, retornando `contracts.zig`, `evidence.zig`, `micro_context.zig` e `model_context.zig`, sem `render.zig` util.
- Smoke real `fts-bm25-276b` mostrou FTS ativo, mas com query `OR` ampla e score BM25 isolado; arquivos com termos comuns ainda venciam.
- Smoke real `fts-bm25-276c` apos scoring por cobertura trouxe `src/render.zig` para a evidencia e o modelo respondeu corretamente sobre markdown/diff.

Alvo final:

1. `collect_evidence(auto|lexical)` usa FTS5/BM25 como fonte interna, guiada por `terms` definidos pelo modelo.
2. FTS nao vira prova final; os candidatos sao materializados em arquivo/range/hash via fluxo existente.
3. Nenhum embedding/modelo secundario e necessario.
4. Nenhuma heuristica linguistica hardcoded: sem stopwords, sem preferencia por source/docs/test, sem lista fixa de arquivos.
5. Audit mostra `fts_available`, `fts_indexed_files` e `source=fts_bm25`.
6. `rg` continua sendo a primeira fase para termos estruturados; FTS melhora recall de termos naturais/ambiguos.

Teste primeiro:

- `fts_ranker` indexa workspace em SQLite FTS5 e retorna candidatos sem raw output.
- Query builder preserva termos do modelo sem stopwords.
- Parser de linha do melhor match nao quebra termos por causa de letras `O`/`R`.
- Score de candidato prefere cobertura de mais termos do modelo.
- `evidence_ranker` audita `fts_available` e `fts_indexed_files`.
- `collect_evidence` continua renderizando somente `[EVIDENCE]` destilada.
- `main` segue com tool loop, contratos e zero raw leak.

Implementacao:

- Criar `phenom-zig/src/fts_ranker.zig`.
- Usar SQLite in-memory com FTS5:
  - `create virtual table chunks using fts5(path unindexed, body, tokenize='unicode61')`.
  - Indexar arquivos text/code permitidos ate limites conservadores.
  - Ignorar `.git`, `zig-cache`, `zig-out`, `node_modules`, `.phenom-*` e `bin`.
- Criar query FTS com termos model-provided.
- Pontuar candidatos por:
  - cobertura de termos encontrados no corpo;
  - BM25 como reforco/desempate;
  - sem stopword/lista linguistica.
- Integrar FTS em `evidence_ranker.zig`:
  - fase 1: `rg` para termos estruturados;
  - fase 2: FTS5/BM25;
  - fase 3: keyword discovery por `rg -c`;
  - fase 4: path;
  - fase 5: overview estrutural.
- Manter `semantic`, `symbol`, `diagnostic`, `runtime` e `diff` inativos ate executor real.

Revisao baixo nivel realizada:

- C string: `sqlite3_exec` usa `dupeZ`, nao slice cru.
- Ownership: `fts_ranker.Result` owns candidates e libera paths em `deinit`.
- Failure path: `rank` usa `errdefer` para limpar candidatos se query/index falhar.
- Bounds: indexacao limita `max_indexed_files` e `max_file_bytes`.
- Raw leak: FTS retorna apenas path/line/score; evidência final continua sendo lida por `tools.readFileRange` e passa pelo pipeline de budget/hash.
- Regra de negocio: FTS nao escolhe resposta, so candidatos; modelo continua sendo o analista.
- Regra de negocio: nenhum novo contrato model-visible foi adicionado.

Criterio de aceite:

- `zig test src/fts_ranker.zig -lc -lsqlite3` passa.
- `zig test src/evidence_ranker.zig -lc -lsqlite3` passa.
- `zig test src/collect_evidence.zig -lc -lsqlite3` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real ambigue de markdown/diff encontra `src/render.zig`.
- SQLite mostra `raw_marker=0`, `fts_marker>0`, `render_evidence>0`, `tool_error=0`.

Pendencias deliberadas:

- AST/symbol real ainda nao foi implementado nesta task. Proxima frente deve criar executor `symbol` interno com parsing leve/ctags-like ou Tree-sitter/LSP conforme viabilidade.
- LSP/diagnostic real ainda nao foi implementado nesta task. Deve entrar como estrategia `diagnostic` com severidade e evidencia objetiva.
- FTS e in-memory por chamada nesta etapa; persistir indice no SQLite operacional fica para quando houver invalidacao por hash/mtime bem definida.
- `semantic` continua inativo porque sem embedding nao deve fingir busca semantica neural.

Implementado:

- `phenom-zig/src/fts_ranker.zig`: ranking FTS5/BM25 in-memory com query model-driven, score por cobertura e BM25, bounds e testes.
- `phenom-zig/src/evidence_ranker.zig`: nova fonte `fts_bm25`, auditoria FTS e ordem de fases ajustada.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/fts_ranker.zig -lc -lsqlite3` -> passou; 4 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc -lsqlite3` -> passou; 17 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc -lsqlite3` -> passou; 38 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 152 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 760 --session fts-bm25-276c --prompt 'No código deste projeto, onde fica a parte que renderiza markdown e diff no output? Responda com evidências e termine exatamente com: PHENOM_FTS_276C' --expect-contains PHENOM_FTS_276C --show-expect-status --fail-on-model-error` -> passou; evidencia incluiu `src/render.zig` e resposta final correta.
- `sqlite3 .phenom-zig/phenom.db "select 'raw_marker', count(*) ...; select 'fts_marker', count(*) ...; select 'render_evidence', count(*) ...; select 'tool_error', count(*) ...;"` -> retornou `raw_marker=0`, `fts_marker=1`, `render_evidence=1`, `tool_error=0`.

## T277 - Ativar estrategia `symbol` com coleta estrutural interna

Status: implementado nesta etapa.

Motivacao: T276 melhorou recall para consultas ambiguas com FTS5/BM25, mas ainda faltava uma estrategia de contrato para buscas por simbolo nomeado. O audit e as tasks antigas pedem que `collect_evidence(strategy="symbol")` esconda AST/grep/read_file atras de um contrato unico, sem expor `parse_ast`, `grep_file` ou detalhes de LSP ao modelo. Esta task ativa `symbol` somente agora que existe executor real.

Evidencias analisadas:

- `TASKS.md` T100/T1522/T1553 pediam `collect_evidence(strategy="symbol")` como estrategia interna, com AST/grep e fallback auditado.
- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` aponta que RAG/AST devem ficar atras de `collect_evidence`, nao como tools diretas.
- `phenom-zig/src/contracts.zig` ja tinha enum `.symbol`, mas estrategia estava inativa.
- `phenom-zig/src/tool_call.zig` ja parseava `symbol`, mas `collect_evidence` rejeitava por contrato.

Alvo final:

1. `symbol` passa a ser estrategia real de `collect_evidence`.
2. O modelo continua vendo apenas `collect_evidence`, nao `parse_ast`, `grep_file` ou `symbol_ranker`.
3. O executor estrutural encontra funcoes/tipos/constantes por sintaxe de linguagem.
4. Se a coleta estrutural nao bastar, o fluxo existente ainda pode somar `rg` para termos estruturados.
5. Evidencia final continua sendo path/range/hash.
6. Nenhuma heuristica linguistica hardcoded e adicionada.

Teste primeiro:

- `symbol_ranker` encontra `AppendOnlyRenderer` em `src/render.zig`.
- Parser estrutural extrai declaracao TS/JS simples.
- `collect_evidence(strategy=symbol, terms=AppendOnlyRenderer)` retorna evidencia de `src/render.zig`.
- `contracts` passa a aceitar `.symbol`, mas continua rejeitando `semantic`, `diagnostic`, `runtime` e `diff`.
- `main` anuncia `symbol` no schema compacto.
- Smoke real com modelo chama `collect_evidence: symbol`.

Implementacao:

- Criar `phenom-zig/src/symbol_ranker.zig`.
- Extrair simbolos de arquivos `.zig`, `.ts` e `.js` com regras sintaticas conservadoras:
  - Zig: `pub fn`, `fn`, `pub const`, `const`;
  - TS/JS: `function`, `async function`, `class`, `const`, `let`, `var`, com `export/default`.
- Pontuar por termos fornecidos pelo modelo contra:
  - nome do simbolo;
  - assinatura;
  - path.
- Estimar range por braces com teto de linhas.
- Integrar como `CandidateSource.symbol_ast` em `evidence_ranker`.
- Ativar `.symbol` em `contracts.strategy_specs`.
- Atualizar schema model-visible de `collect_evidence` para `auto|path|lexical|symbol`.
- Manter `semantic`, `diagnostic`, `runtime` e `diff` inativos.

Revisao baixo nivel realizada:

- Ownership: `symbol_ranker.Candidate` owns `path` e `symbol`; `Result.deinit` libera todos.
- Failure path: duplicacao de path/symbol usa `errdefer` antes de append.
- Failure path: adaptador `collectSymbolCandidates` duplica path e reasons com `errdefer`.
- Bounds: indexacao limita `max_indexed_files`, `max_file_bytes`, `max_symbol_lines` e `max_candidates`.
- Stale: resultado de `symbol_ranker` nao e enviado ao modelo diretamente; vira candidato e depois `tools.readFileRange` materializa hash/range atual.
- Raw leak: executor estrutural nao guarda corpo bruto em audit; evidencia final passa pelo pipeline existente.
- Regra de negocio: nao foi adicionada lista de stopwords, preferencia de extensao source/test/docs, ou roteamento por prompt do usuario.
- Contrato: nenhuma nova tool model-visible foi criada.

Criterio de aceite:

- `zig test src/symbol_ranker.zig -lc -lsqlite3` passa.
- `zig test src/contracts.zig -lc` passa.
- `zig test src/evidence_ranker.zig -lc -lsqlite3` passa.
- `zig test src/collect_evidence.zig -lc -lsqlite3` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real chama `collect_evidence: symbol` e responde com `src/render.zig`.
- SQLite mostra `source=symbol_ast`, `raw_marker=0`, `tool_error=0`.

Pendencias deliberadas:

- Isso e parser estrutural/ctags-like, nao AST completa com type resolution. AST completa deve ser avaliada depois com parser real ou LSP, sem quebrar o contrato.
- LSP/diagnostic real continua pendente para estrategia `diagnostic`.
- Ranges por braces sao aproximados e limitados; edicao/mutacao futura ainda deve validar stale/range antes de patch.

Implementado:

- `phenom-zig/src/symbol_ranker.zig`: coletor estrutural de simbolos com bounds, scoring por termos do modelo e testes.
- `phenom-zig/src/evidence_ranker.zig`: fonte `symbol_ast`, audit `symbol_available/symbol_indexed_files/symbols_seen` e fallback para `rg`.
- `phenom-zig/src/contracts.zig`: estrategia `.symbol` ativa em `collect_evidence`.
- `phenom-zig/src/main.zig`: schema compacto anuncia `symbol`.
- `phenom-zig/src/collect_evidence.zig`: teste de estrategia `symbol` real.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/symbol_ranker.zig -lc -lsqlite3` -> passou; 2 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/contracts.zig -lc` -> passou; 5 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc -lsqlite3` -> passou; 19 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc -lsqlite3` -> passou; 42 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 155 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 720 --session symbol-277 --prompt 'Use collect_evidence com strategy symbol para encontrar AppendOnlyRenderer. Depois responda onde esse símbolo está definido e termine exatamente com: PHENOM_SYMBOL_277' --expect-contains PHENOM_SYMBOL_277 --show-expect-status --fail-on-model-error` -> passou; modelo chamou `collect_evidence: symbol`, evidencia apontou `src/render.zig`, resposta correta.
- `sqlite3 .phenom-zig/phenom.db "select 'raw_marker', count(*) ...; select 'symbol_source', count(*) ...; select 'render_evidence', count(*) ...; select 'duplicate', count(*) ...; select 'tool_error', count(*) ...;"` -> retornou `raw_marker=0`, `symbol_source=4`, `render_evidence=1`, `duplicate=1`, `tool_error=0`.

## T278 - Ativar estrategia `diagnostic` com parse Zig local

Status: implementado nesta etapa.

Motivacao: T276 e T277 fecharam duas bases deterministicas do micro-contexto (`fts_bm25` e `symbol`). A proxima dor real do audit e das tasks antigas e diagnostico objetivo como evidencia, sem transformar validacao em erro generico de infraestrutura e sem reintroduzir LSP/auto-install antes de haver fronteira madura. Esta task ativa `collect_evidence(strategy="diagnostic")` de forma deliberadamente pequena: parse sintatico Zig local, com severidade e EvidencePacket.

Evidencias analisadas:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md` 3.9 e 6.5 pedem validacao/LSP como evidencia, com severidade e efeito claro.
- `TASKS.md` T081, T082, T209 e T217 pedem diagnosticos classificados, acionaveis e reproduziveis.
- `TASKS.md` T277 deixou `diagnostic` pendente ate existir executor real.
- `phenom-zig/src/contracts.zig` ja tinha enum/roadmap para `.diagnostic`, mas a estrategia estava inativa.
- `phenom-zig/src/tools.zig` ja materializa arquivo com sandbox, hash e path/range owns; isso evita diagnostico sobre contexto stale.

Alvo final:

1. `diagnostic` passa a ser estrategia real de `collect_evidence`.
2. O modelo continua vendo apenas o contrato `collect_evidence`, nao `zig.Ast`, LSP ou comandos internos.
3. Diagnostico retorna evidencia objetiva com severidade.
4. Parse limpo tambem vira evidencia positiva (`status=ok parser=zig errors=0`).
5. Falha da tool continua separada de falha de modelo/infraestrutura.
6. Nenhum raw context vaza para o modelo.
7. Nenhuma heuristica linguistica hardcoded e adicionada.

Teste primeiro:

- `diagnostic_runner` retorna `severity=blocking` para Zig com erro de parse.
- `diagnostic_runner` retorna `severity=info status=ok` para Zig valido.
- `collect_evidence(strategy=diagnostic, path=...)` renderiza `[DIAGNOSTIC]` dentro de `[EVIDENCE]`.
- `contracts` aceita `.diagnostic` somente agora que existe executor real.
- `main` anuncia `diagnostic` no schema compacto.
- Smoke real com modelo usa `collect_evidence: diagnostic`, cita E1 e finaliza.

Implementacao:

- Criar `phenom-zig/src/diagnostic_runner.zig`.
- Usar `tools.readFileRange` para ler arquivo com sandbox/hash/budget antes do parse.
- Aceitar apenas `.zig` nesta etapa.
- Parsear com `std.zig.Ast.parse`.
- Renderizar:
  - `[DIAGNOSTIC]`;
  - `severity=blocking path=... line=... column=... parser=zig message=...` para erros;
  - `severity=info status=ok parser=zig errors=0` para parse limpo.
- Criar `EvidenceEntry(kind="diagnostic", range="L1-*")`.
- Auditar tool event com `strategy=diagnostic`, `parser=zig`, `raw_bytes` e `blocking`.
- Integrar `executeDiagnostic` em `collect_evidence`.
- Ativar `.diagnostic` em `contracts.strategy_specs`.
- Atualizar schema model-visible para `auto|path|lexical|symbol|diagnostic`.
- Atribuir qualidade alta para diagnostico sintatico limpo ou bloqueante, porque ambos respondem diretamente a perguntas de sintaxe e devem encerrar a coleta quando suficiente.

Revisao baixo nivel realizada:

- Ownership: `diagnostic_runner.Result` owns `EvidenceEntry` e `audit_text`; `deinit` libera ambos.
- Ownership: `EvidenceEntry` e construido com alocacoes nomeadas e `errdefer` por campo, evitando vazamento se uma alocacao intermediaria falhar.
- Ownership: `collect_evidence.executeDiagnostic` clona a entry antes de inserir no `EvidencePacket`, evitando double-free quando `diagnostic.deinit` roda.
- Failure path: `evidence_text`, `micro_context_text`, `tool_event_audit_text` e `context_id` usam `errdefer`.
- Bounds: leitura de diagnostico limita arquivo a 256 KiB e o renderer respeita `budget_bytes`.
- Stale/hash: o hash vem de `tools.readFileRange`, nao do parser nem de contexto antigo.
- Segurança: path passa pelas regras existentes de `tools.readFileRange`; sem leitura absoluta, traversal, hidden path ou sensitive path.
- Regra de negocio: nao houve stopwords, preferencia por source/docs/test, nem inferencia de intencao no agente.
- Contrato: nenhuma nova tool model-visible foi criada.

Criterio de aceite:

- `zig test src/diagnostic_runner.zig -lc -lsqlite3` passa.
- `zig test src/collect_evidence.zig -lc -lsqlite3` passa.
- `zig test src/contracts.zig -lc` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real natural de sintaxe Zig passa com marcador final.
- SQLite mostra `strategy=diagnostic`, `[DIAGNOSTIC]`, `raw_marker=0`, `tool_error=0`, `expectation_passed=1`.

Pendencias deliberadas:

- Isso nao e LSP completo.
- Isso nao typechecka Zig.
- Isso nao valida TypeScript/JavaScript.
- Isso nao executa `zig build` nem testes.
- Proxima frente de diagnostico deve portar validacao TS/JS calibrada e/ou LSP externo somente quando houver politica clara de severidade, ruido, latencia e ambiente.

Implementado:

- `phenom-zig/src/diagnostic_runner.zig`: runner sintatico Zig com EvidenceEntry, audit e testes.
- `phenom-zig/src/collect_evidence.zig`: rota `strategy=diagnostic`, clone seguro de evidence entry e qualidade alta para resultado sintatico objetivo.
- `phenom-zig/src/contracts.zig`: `.diagnostic` ativo em `collect_evidence`.
- `phenom-zig/src/main.zig`: schema compacto anuncia `diagnostic`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/diagnostic_runner.zig -lc -lsqlite3` -> passou; 12 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc -lsqlite3` -> passou; 46 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/contracts.zig -lc` -> passou; 5 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 159 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 1200 --session diagnostic-278e --prompt 'Verifique a sintaxe Zig do arquivo src/main.zig usando evidencia do projeto. Depois responda se ha erro de sintaxe evidenciado e termine exatamente com: PHENOM_DIAGNOSTIC_278E' --expect-contains PHENOM_DIAGNOSTIC_278E --show-expect-status --fail-on-model-error --no-color` -> passou; modelo chamou `collect_evidence: diagnostic`, evidencia mostrou `status=ok parser=zig errors=0`, resposta citou E1 e finalizou.
- `sqlite3 .phenom-zig/phenom.db "select 'diagnostic_tool', count(*) ...; select 'diagnostic_evidence', count(*) ...; select 'raw_marker', count(*) ...; select 'tool_error', count(*) ...; select 'expectation_passed', count(*) ...;"` -> retornou `diagnostic_tool=1`, `diagnostic_evidence=1`, `raw_marker=0`, `tool_error=0`, `expectation_passed=1`.

Observacao de teste real:

- Prompts artificiais que mandam literalmente "emita exatamente esta tool call" dentro do `user_prompt` induzem repeticao da mesma chamada em inferencias seguintes, porque o agente reenvia o pedido original junto do contexto operacional. O smoke aceito usa uma query natural de usuario e prova o fluxo real: modelo escolhe o contrato, agente executa, modelo responde com evidencia.

## T279 - Remover vies de ecossistema no inventario de evidencia

Status: implementado nesta etapa.

Motivacao: revisao do usuario apontou regressao real de regra de negocio: `skipPath` e `looksLikeSource` estavam codificando nomes de ecossistema (`node_modules`, `zig-cache`, `zig-out`, `bin`) e whitelist de linguagem (`.zig`, `.ts`, `.js`). Isso viola a visao do projeto: o agente deve operar em qualquer workspace e qualquer linguagem; quem define intencao e o modelo, e o agente deve executar coleta objetiva sem enviesar o universo de arquivos por stack.

Evidencias analisadas:

- `phenom-zig/src/symbol_ranker.zig` filtrava inventario com `looksLikeSource(path)` limitado a Zig/TS/JS.
- `phenom-zig/src/fts_ranker.zig` indexava apenas `.zig`, `.ts`, `.js`, `.md`, `.json`, `.toml`.
- `phenom-zig/src/evidence_ranker.zig` usava globs/exclusoes com nomes fixos de ecossistema e repetia `looksLikeTextCode`.
- `TASKS.md` ja registrava a regra de negocio: sem stopwords, sem preferencia source/docs/test e sem heuristica linguistica hardcoded.
- T276/T277 melhoraram FTS/symbol, mas ainda carregavam filtro de inventario enviesado. Esta task substitui essa parte.

Alvo final:

1. Inventario de workspace fica centralizado e generico.
2. Nenhum coletor decide que uma linguagem especifica e "source" por extensao.
3. Nenhum coletor exclui diretórios de ecossistema por nome.
4. Arquivo entra por fonte de verdade do projeto (`git ls-files`) ou por prova de conteudo textual UTF-8.
5. Storage operacional do Phenom continua fora do contexto operacional.
6. FTS/BM25 e overview usam o mesmo inventario.
7. `symbol` nao filtra inventario por linguagem; apenas os parsers disponiveis extraem simbolos quando reconhecem sintaxe.

Teste primeiro:

- `workspace_inventory` aceita paths de qualquer extensao/language-like path.
- `workspace_inventory` nao rejeita `node_modules/...` nem `zig-cache/...` por nome.
- `workspace_inventory` rejeita traversal e storage operacional Phenom.
- Classificacao texto/binario e por bytes UTF-8, nao por extensao.
- `fts_ranker`, `symbol_ranker`, `evidence_ranker`, `collect_evidence` e `main` continuam passando.

Implementacao:

- Criar `phenom-zig/src/workspace_inventory.zig`.
- Inventario:
  - primeiro `git ls-files -z` para arquivos tracked;
  - depois `git ls-files -o --exclude-standard -z` somente se houver capacidade;
  - fallback por walk quando git nao esta disponivel.
- Ordenar paths por profundidade, tamanho e ordem lexicografica antes de aplicar limite.
- Validar path com regra estrutural:
  - nao absoluto;
  - sem NUL;
  - sem `.`/`..`;
  - sem storage operacional Phenom.
- Validar conteudo textual por bytes:
  - rejeita NUL;
  - exige UTF-8 valido.
- Trocar `fts_ranker` para indexar inventario comum e validar conteudo, sem lista de extensoes.
- Trocar `symbol_ranker` para usar inventario comum e remover `looksLikeSource`.
- Trocar fallback/overview de `evidence_ranker` para inventario comum.
- Remover globs hardcoded de `rg`; `rg` fica responsavel por respeitar regras naturais do projeto e o inventario valida paths retornados.
- Trocar `looksLikePath` para criterio generico: slash ou ponto interno, sem extensoes fixas.

Revisao baixo nivel realizada:

- Ownership: `workspace_inventory.Result` owns todos os paths e libera em `deinit`.
- Ownership: falhas em `collectGit`/`collectWalk` usam `errdefer` para liberar paths ja coletados.
- Bounds: stdout de git limitado, probe de arquivo limitado e coleta fallback limitada por multiplicador.
- Failure path: se `git ls-files -o` estourar limite por muitos untracked, tracked files permanecem utilizaveis.
- Conteudo: FTS e fallback leem arquivo com limite e descartam bytes nao UTF-8 antes de indexar.
- Regra de negocio: nao ha whitelist de linguagens no inventario.
- Regra de negocio: nao ha blacklist de diretorios de ecossistema no inventario.
- Regra de negocio: storage operacional Phenom nao compete com evidencia do workspace.

Criterio de aceite:

- `rg` em `phenom-zig/src` nao encontra mais `skipPath`, `looksLikeSource`, `looksLikeTextCode` nem glob `!{.git,...}`.
- Ocorrencias de `node_modules`/`zig-cache` em `phenom-zig/src` existem apenas em testes que provam que esses nomes nao sao bloqueados.
- `zig test src/workspace_inventory.zig -lc -lsqlite3` passa.
- `zig test src/fts_ranker.zig -lc -lsqlite3` passa.
- `zig test src/symbol_ranker.zig -lc -lsqlite3` passa.
- `zig test src/evidence_ranker.zig -lc -lsqlite3` passa.
- `zig test src/collect_evidence.zig -lc -lsqlite3` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.

Pendencias deliberadas:

- `symbol` ainda so extrai simbolos para sintaxes com parser implementado hoje. Isso nao e mais filtro de inventario; e limite real de executor. Proximas linguagens devem entrar adicionando parser real ou LSP/AST, nao whitelist de extensao.
- `diagnostic` continua Zig-only pela T278, explicitamente como estrategia limitada de parse Zig local.
- Smoke real `inventory-279` provou tool loop/audit, mas a evidencia para pergunta de markdown ainda nao foi ideal. Isso fica como frente separada de groundedness/ranking, nao deve ser corrigido com blacklist/whitelist.

Implementado:

- `phenom-zig/src/workspace_inventory.zig`: inventario generico tracked-first, fallback textual por conteudo, path policy e testes.
- `phenom-zig/src/fts_ranker.zig`: FTS passa a usar inventario comum e conteudo UTF-8.
- `phenom-zig/src/symbol_ranker.zig`: remove gate `looksLikeSource`; inventario nao escolhe linguagem.
- `phenom-zig/src/evidence_ranker.zig`: remove `skipPath`, remove globs hardcoded, remove `looksLikeTextCode`, overview/fallback usam inventario comum.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/workspace_inventory.zig -lc -lsqlite3` -> passou; 2 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/fts_ranker.zig -lc -lsqlite3` -> passou; 6 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/symbol_ranker.zig -lc -lsqlite3` -> passou; 4 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc -lsqlite3` -> passou; 21 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc -lsqlite3` -> passou; 48 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 161 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 900 --session inventory-279 --prompt 'No codigo deste projeto, onde fica a parte que renderiza markdown no output? Use evidencia e termine exatamente com: PHENOM_INVENTORY_279' --expect-contains PHENOM_INVENTORY_279 --show-expect-status --fail-on-model-error --no-color` -> passou; tool loop executou e finalizou.
- `sqlite3 .phenom-zig/phenom.db "select 'tool_event', count(*) ...; select 'raw_marker', count(*) ...; select 'tool_error', count(*) ...; select 'expectation_passed', count(*) ...;"` -> retornou `tool_event=1`, `raw_marker=0`, `tool_error=0`, `expectation_passed=1`.

## T280 - Separar continuidade conversacional de evidencia pesquisavel da sessao

Status: implementado nesta etapa.

Motivacao: teste real de uso mostrou regressao de regra de negocio no fluxo de sessao. O usuario perguntou se uma solucao tecnica (`w-90`) fazia sentido dentro de um contexto ja conversado. O modelo chamou `search_session`, recebeu trechos relevantes do SQLite, mas respondeu que nao havia evidencia suficiente. A causa raiz nao era Bootstrap nem ranking; era contrato de contexto errado. O agente tratava conversa anterior como evidencia estrita S#, truncava eventos em linhas de audit e instruia o modelo a dizer "nao evidenciado" quando a busca de sessao nao provasse literalmente a resposta. Isso conflita com o fluxo esperado: o historico recente serve para continuidade conversacional; `search_session` serve para recuperar fatos exatos/auditaveis de sessoes longas.

Evidencias analisadas:

- `phenom-zig/src/session_context.zig` tinha apenas `renderRecent`, que renderizava eventos como `kind: body`, sem papeis `user`/`assistant`.
- `phenom-zig/src/main.zig` injetava esse conteudo em `[SESSION_CONTEXT]`, competindo com evidencia S# retornada por `search_session`.
- `runSearchSessionStep` dizia ao modelo: se a busca de sessao nao provar o fato, diga que nao esta evidenciado. Isso bloqueava julgamento tecnico baseado no contexto da conversa.
- `groundingRules` exigia S# para qualquer claim de conversa/sessao, sem separar continuidade recente de fato exato pesquisado.
- `phenom-cli-ts` usa mensagens recentes como chat history normal (`recentMessages`) e reserva ferramenta de sessao para recuperacao operacional opcional, nao para substituir continuidade conversacional.

Alvo final:

1. Historico recente entra como dialogo temporario, com papeis claros, sem virar MEMORY/SKILLS.
2. `search_session` continua sendo ferramenta auditavel para fatos exatos de sessao e retorna S#.
3. O modelo pode usar dialogo recente para entender a pergunta atual sem precisar provar cada inferencia tecnica com S#.
4. Claims sobre workspace/source continuam exigindo E#.
5. Claims exatas sobre o que foi dito/feito em sessao continuam exigindo S#.
6. Raw context, tool events e evidencia bruta nao vazam para o modelo como conversa.
7. O ajuste nao adiciona heuristica linguistica, regra por linguagem, regra por framework nem caso especial para `w-90`.

Teste primeiro:

- `renderRecentDialogue` preserva `user:` e `assistant:`.
- `renderRecentDialogue` agrupa deltas consecutivos de assistente.
- `renderRecentDialogue` remove o prompt atual.
- `renderRecentDialogue` ignora eventos operacionais como `tool_start`.
- `renderRecentDialogue` redige marcadores de raw context.
- `renderModelTurnContext` renderiza `[RECENT_DIALOGUE]` separado de `[SESSION_CONTEXT]`.
- `buildInitialModelContext` injeta `[RECENT_DIALOGUE]`, mas nao cria `[SESSION_CONTEXT]` sem chamada explicita de `search_session`.
- `renderCollectedEvidenceContext` continua aceitando `[SESSION_CONTEXT]` de `search_session`.

Implementacao:

- Adicionar `DialogueBlock` em `model_context.zig`.
- Renderizar `[RECENT_DIALOGUE]` antes de `[SESSION_CONTEXT]`.
- Adicionar `session_context.renderRecentDialogue`.
- Adicionar `session_context.toDialogueBlocks`.
- Alterar `buildInitialModelContext` para usar dialogo recente em vez de contexto S# inicial.
- Ajustar `collectEvidenceToolSchema` para deixar claro que dialogo recente e continuidade, e fatos exatos de sessao vêm de `search_session`.
- Ajustar `runSearchSessionStep` para permitir julgamento tecnico usando o contexto recuperado, sem transformar resultado insuficiente em negativa automatica.
- Ajustar `groundingRules` para separar:
  - E# para workspace/source;
  - S# para fatos exatos de sessao;
  - `[RECENT_DIALOGUE]` somente para continuidade.

Revisao baixo nivel realizada:

- Ownership: `DialogueEntry.text` e owned e liberado por `freeDialogueEntries`.
- Failure path: `renderRecentDialogue` usa `errdefer` para liberar entries e output parcial; revisao encontrou e removeu risco de double-free entre `errdefer` e `defer`.
- Bounds: acumulacao por mensagem limitada por `max_dialogue_accum_bytes`; renderizacao final limitada por `max_dialogue_entry_bytes`.
- Raw leak: dialogo passa por `redactRawMarkers` e `assertNoRawContextLeak`.
- Stale context: dialogo recente nao vira evidencia E#/S# e nao autoriza claims de workspace.
- Regra de negocio: sem stopwords, sem keywords hardcoded, sem preferencia source/docs/test, sem caso especial de framework.

Criterio de aceite:

- `zig test src/session_context.zig -lc -lsqlite3` passa.
- `zig test src/model_context.zig -lc -lsqlite3` passa.
- `zig test src/main.zig -lc -lsqlite3` passa.
- `zig build test` passa.
- `zig build -Doptimize=ReleaseFast` passa.
- Smoke real de continuidade de sessao deve mostrar que o modelo consegue usar conversa recente como contexto e, quando precisar de fato exato de sessao, chamar `search_session`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` -> passou; 66 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/model_context.zig -lc -lsqlite3` -> passou; 56 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 165 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- Smoke real `dialogue-280` chamada 1 registrou contexto conversacional e passou com `CONTEXTO_REGISTRADO_280`.
- Smoke real `dialogue-280` chamada 2 respondeu pergunta dependente do historico e passou com `PHENOM_DIALOGUE_280`.
- Audit SQLite `dialogue-280` retornou `recent_dialogue_context=1`, `session_context_block=0`, `raw_marker=0`, `expectation_passed=2`.

Observacao de smoke:

- O modelo deixou de responder "sem evidencia" e usou continuidade da conversa. Ainda houve extrapolacao tecnica sobre `w-90` como se fosse utility padrao ampla. Isso confirma que T280 corrige o contrato de historico, mas nao encerra a frente de groundedness tecnica. A correcao dessa extrapolacao deve vir por citações/contratos de conhecimento ou evidencia quando o usuario pedir fato de framework, nao por heuristica hardcoded no agente.

Pendencias deliberadas:

- Ainda nao ha resumo semantico longo de sessao; esta task corrige a separacao contratual do historico recente.
- `search_session` ainda usa busca textual simples sobre audit events; FTS/BM25 de sessao pode entrar depois sem mudar o contrato.
- A resposta tecnica final ainda depende do modelo interpretar o dialogo corretamente; o agente nao adiciona vies/heuristicas para substituir essa interpretacao.

## Fase 21 - Realinhamento urgente com AUDIT e phenom-cli-ts

Prioridade: urgente/bloqueante.

Motivacao: `alinhamento.md` concluiu que o `phenom-zig` corrigiu base tecnica importante, mas ficou estreito demais em comparacao ao produto provado no `phenom-cli-ts`. Estas tasks sobem acima das demais pendencias porque evitam nova quebra contratual da regra de negocio: o Zig deve portar acertos do TS por contrato, corrigindo as falhas do AUDIT, e nao recriar fluxos por memoria do agente.

## T281 - Tornar `alinhamento.md` gate obrigatorio de task executavel

Status: implemented-verified.

Prioridade: urgente.

Motivacao: sem um gate documentado, novas inferencias podem voltar a implementar por aproximacao, sem consultar `AUDIT` e `../phenom-cli-ts`.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: nao existe referencia TS direta; esta e uma regra de processo derivada de `alinhamento.md`.
- Falha apontada no AUDIT/TASKS: controller e prompts cresceram por camadas sem contrato tipado e auditavel; tasks antigas podem ser executadas sem checar a referencia correta.
- O que sera preservado do TS: comportamento provado deve ser tratado como marco de referencia.
- O que sera corrigido no Zig: toda task executavel precisa citar o equivalente TS ou declarar ausencia dele.
- O que nao sera portado agora e por que: nenhuma feature runtime; task documental/processual.
- Invariantes afetadas: todas as sete invariantes, por prevenir regressao de processo.
- Teste unitario obrigatorio: check textual simples que falhe se task nova urgente nao tiver bloco `Alinhamento AUDIT/TASKS/phenom-cli-ts`.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: nao aplicavel.
- Revisao baixo nivel Zig antes do commit: nao aplicavel; docs/processo.

Passos de implementacao:

1. Criar script/check leve para validar secoes obrigatorias em tasks `pending-urgent`.
2. Fazer o check procurar os nove campos obrigatorios do bloco de alinhamento.
3. Adicionar comando de validacao documental ou registrar como criterio manual se ainda nao houver runner de docs.
4. Rodar o check em T281-T290.

Criterio de aceite:

- Tasks urgentes sem bloco de alinhamento falham no check.
- Tasks historicas implementadas nao sao reescritas retroativamente.

Implementacao concluida:

- Criado `../tools/check_alignment_tasks.sh`.
- O check valida `T281`-`T301`, prioridade urgente, bloco `Alinhamento AUDIT/TASKS/phenom-cli-ts` e os campos obrigatorios.
- O check tambem valida a matriz de cobertura do `alinhamento.md`.
- O check aceita apenas status urgentes honestos, incluindo `implemented-verified...`, para impedir voltar a `done` sem prova.
- O check foi corrigido para nao emitir `Broken pipe` por `grep -q` em pipelines.

Validacao executada:

- `sh ../tools/check_alignment_tasks.sh` -> passou.

## T282 - Portar `set_operational_contract` como contrato model-visible pequeno

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o Zig tem gate pequeno, mas perdeu o acerto do TS em que o modelo pode declarar contrato operacional antes de abrir mutation/validation/runtime. Sem isso, a proxima expansao de tool surface vira lista solta ou prompt improvisado.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts`; `../phenom-cli-ts/src/agent.ts` em `operationalContractToolDefinition`, `getTurnToolDefinitions` e instrucoes de `set_operational_contract`.
- Falha apontada no AUDIT/TASKS: fronteira entre contrato operacional e tool avulsa ainda nao cristalina; falta contrato de execucao auditavel.
- O que sera preservado do TS: `set_operational_contract` como declaracao model-visible de intencao operacional.
- O que sera corrigido no Zig: contrato deve ser pequeno, tipado e auditado; nao deve abrir tools internas por prompt livre.
- O que nao sera portado agora e por que: mutation/validation completas ficam para T285/T286; esta task so declara e registra contrato ativo.
- Invariantes afetadas: 1, 6, 7.
- Teste unitario obrigatorio: parser aceita `set_operational_contract`; contrato ativo muda tool surface permitida; tool fora do contrato e rejeitada.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, modelo declara contrato e depois chama apenas tool permitida.
- Revisao baixo nivel Zig antes do commit: ownership de strings de contrato, enum bounds, estado por turno sem ponteiro pendurado.

Passos de implementacao:

1. Ler o contrato TS e registrar campos minimos aceitos no Zig.
2. Adicionar contrato model-visible em `contracts.zig` sem expor mutation ainda.
3. Estender `tool_call.zig` para parsear `set_operational_contract`.
4. Guardar contrato ativo no estado do tool loop por turno.
5. Auditar `contract_selected`, `allowed_tools` e motivo de rejeicao.
6. Testar que contrato nao persiste indevidamente entre turnos.

Criterio de aceite:

- Modelo consegue declarar contrato.
- Executor nao roda tool fora do contrato ativo.
- SQLite mostra contrato selecionado e allowlist efetiva.

Implementacao concluida:

- `set_operational_contract` passou a ser model-visible no manifesto Zig.
- Parser XML aceita `requiresInspection`, `requiresMutation`, `requiresRuntimeValidation`, `requiresBrowserDiagnostics` e `reason`, com ownership proprio.
- O tool envelope aceita `set_operational_contract` e rejeita executores futuros ainda nao anunciados, como `apply_patch`.
- O tool loop registra `contract_selected`, altera o contrato ativo do turno e audita `allowed_tools`.
- Apos selecionar contrato, o schema enviado ao modelo deixa de anunciar `set_operational_contract`, evitando repeticao/loop.
- Mutation/validation continuam bloqueados ate T285/T286.

Revisao baixo nivel Zig:

- Campos textuais novos sao duplicados no parser e liberados em `ToolCall.deinit`.
- `ToolLoopState` guarda somente slices estaticos de `contracts.ActiveContract`, sem ownership pendurado.
- `set_operational_contract` consome budget de iteracao e tem dedupe para repeticao no mesmo turno.
- `renderAllowedTools` usa `ArrayList` com `errdefer`.
- Nenhum raw tool output e enviado ao modelo; somente audit/body destilado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/contracts.zig` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/tool_envelope.zig` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 169 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` -> passou.
- `sh tools/check_alignment_tasks.sh` -> passou.

Smoke real executado:

- `timeout 45s ./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 500 --session contract-282d --prompt 'Declare set_operational_contract com requiresInspection=true, requiresMutation=false, requiresRuntimeValidation=false, requiresBrowserDiagnostics=false e reason="teste de contrato". Depois responda exatamente: PHENOM_CONTRACT_282D' --expect-contains PHENOM_CONTRACT_282D --show-expect-status --fail-on-model-error --no-color` -> passou.
- SQLite `contract-282d`: `contract_selected=1`, `contract_duplicate=0`, `tool_rejected=0`, `model_error=0`, `expectation_passed=1`.

Observacao de smoke:

- Uma tentativa anterior expôs loop por repeticao de `set_operational_contract`; a causa raiz foi corrigida removendo `set_operational_contract` do schema apos selecao do contrato ativo.

## T283 - Evoluir `collect_evidence` para contrato rico sem heuristica

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: `alinhamento.md` mostrou que o Zig depende demais de `terms`, enquanto o TS aceitava `task`, `need`, `targetFiles`, `scopeRoot`, `stage` e `selectedCandidates`. Isso limita a exploracao guiada pelo modelo e aumenta falso positivo.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/tools/registrars/context-tools.ts`, funcao `executeCollectEvidence`.
- Falha apontada no AUDIT/TASKS: `collect_evidence` deve representar bem estrategias internas e esconder `build_task_context`; naming/contrato ainda ruidoso.
- O que sera preservado do TS: parametros ricos de intencao model-driven e refinamento por candidatos.
- O que sera corrigido no Zig: manter executor baixo nivel, sem stopwords, sem preferencias source/docs/test, sem path hardcoded.
- O que nao sera portado agora e por que: RAG semantic embeddings nao entram; decisao atual e usar `rg`, FTS5/BM25, AST/LSP/contratos.
- Invariantes afetadas: 1, 2, 5, 7.
- Teste unitario obrigatorio: `collect_evidence` com `targetFiles`, `scopeRoot`, `need`, `stage=candidates`, `selectedCandidates` gera evidencia sem raw leak.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, pergunta ambigua deve coletar candidatos, refinar e responder com E#.
- Revisao baixo nivel Zig antes do commit: ownership dos novos campos, limites de arrays/strings, budget, sem double-free nos candidates.

Passos de implementacao:

1. Mapear parametros TS para struct Zig minima.
2. Estender parser XML para parametros repetidos/listas de forma controlada.
3. Implementar `stage=candidates` retornando candidatos destilados, nao full snippets.
4. Implementar `stage=minimum`/`selectedCandidates` materializando ranges escolhidos.
5. Integrar `need` como texto model-provided auditado, nao heuristica do agente.
6. Preservar path/scopeRoot concreto quando fornecido pelo modelo.

Criterio de aceite:

- O modelo pode explorar em duas etapas sem contexto bruto.
- O agente nao inventa termos nem troca intencao.
- Audit registra parametros pedidos e estrategia executada.

Implementacao concluida:

- `collect_evidence` aceita `intent`, `need`, `targetFiles`, `scopeRoot`, `stage`, `selectedCandidate`/`selectedCandidates`, `path`, `terms` e `strategy`.
- `stage=candidates` devolve `[CANDIDATES]` temporario separado de `[EVIDENCE]`.
- `stage=expand`/`stage=minimum` materializam candidatos escolhidos em evidencia real e micro-contexto.
- Chamadas pathless sem `intent` e sem sinal pesquisavel sao reparadas antes de cair em overview generico.
- Campos de direcao entram no ranking como entrada declarada pelo modelo; o controller nao deriva termos por prompt do usuario.
- Tool events auditam bytes de `intent`, termos/campos e estrategia executada.

Validacao executada:

- `zig test src/collect_evidence.zig -lc -lsqlite3` -> passou.
- `zig test src/tool_call.zig` -> passou.
- `zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-main-memory-quality-test` -> passou; 242 testes.
- `sh tools/check_product_guardrails.sh` -> passou.
- Smoke ambiguo real/fake: `phenom chat --backend llamacpp --host 127.0.0.1:18081 --model fake --thinking off --max-tokens 1600 --session guardrail-flow-final --prompt 'tem uma conta pequena quebrada nesse projeto; arruma do jeito certo, valida e no final escreve PHENOM_GUARDRAIL_FLOW' ...` -> passou; audit registrou `collect_evidence`, `apply_patch`, `validate_syntax`, `expectation_passed` e `turn_done quality=confirmed`.

## T284 - Criar `EvidencePacket v1` tipado e estavel

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: o Zig tem EvidencePacket funcional, mas o contrato model-visible ainda e texto simples. AUDIT pede schema estavel com anchors, findings, obligations, nextActions, stalePaths e confidence.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/tools/registrars/context-tools.ts` renderizadores `renderDistilledEvidence`, `renderMinimumEvidence`, `renderEvidencePack`.
- Falha apontada no AUDIT/TASKS: `EVIDENCE_DISTILLED` deveria ter schema estavel.
- O que sera preservado do TS: saida destilada com escopo, achados, snippets, candidatos e next action.
- O que sera corrigido no Zig: tipo interno forte antes do renderer textual.
- O que nao sera portado agora e por que: formato textual exato do TS nao sera copiado; Zig deve ter schema Phenom v1.
- Invariantes afetadas: 2, 5, 6, 7.
- Teste unitario obrigatorio: packet serializa/renderiza sem raw markers e com campos estaveis.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, modelo cita E# e nao extrapola campo ausente.
- Revisao baixo nivel Zig antes do commit: ownership de listas internas, `errdefer` por campo, limites de excerpt.

Passos de implementacao:

1. Definir structs `Finding`, `Anchor`, `Obligation`, `NextAction`, `EvidencePacketV1`.
2. Adaptar `collect_evidence` para preencher v1.
3. Renderizar texto compacto mantendo compatibilidade com `[EVIDENCE]`.
4. Auditar `packet_version=v1`.
5. Testar anti-raw e budget por campo.

Criterio de aceite:

- Toda evidencia enviada ao modelo vem de packet v1.
- Packet permite replay/auditoria sem depender de parsing fragil de texto livre.

Implementacao em 2026-07-16:

- `phenom-zig/src/evidence.zig`: `EvidencePacket.render` mantem `[EVIDENCE]`, adiciona `packet_version=v1`, schema estavel e entradas `E# kind source range status confidence hash`.
- `EvidencePacket` rejeita marcadores crus (`---BEGIN CONTENT---`, `[READ_FILE]`, `rawOutput`, `raw_output`, `rg --json`, `SECRET_RAW_TAIL`) antes de renderizar ao modelo.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/evidence.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-t284-evidence` -> passou; 9 testes.
- Smoke end-to-end real/fake em `/tmp/phenom-context-task-smoke`: prompt ambiguo corrigiu `src/math.zig`, exibiu `packet_version=v1` em `collect_evidence` e `validate_syntax`, aplicou `apply_patch stale_checked=true`, validou syntax e finalizou com `PHENOM_CONTEXT_TASK_SMOKE`.

Risco residual:

- Anchors/obligations/nextActions ainda vivem no `ModelTurnContext`; o packet v1 Zig ficou deliberadamente compacto para nao duplicar o contrato de contexto.

## T285 - Implementar contrato de mutacao com `apply_patch` e micro-context stale validation

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: sem mutation, `phenom-zig` nao e agente coder final. Sem stale validation, mutation violaria uma das invariantes centrais.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/tools/micro-context.ts`; tools de mutation em `../phenom-cli-ts/src/tools.ts`; instrucoes de `apply_patch` em `../phenom-cli-ts/src/agent.ts`.
- Falha apontada no AUDIT/TASKS: patch em codigo nao pode aplicar sobre contexto stale.
- O que sera preservado do TS: `contextId/contextSha256`, path/range validation e repair claro.
- O que sera corrigido no Zig: patch engine pequeno, com validação de micro-contexto antes de alterar arquivo.
- O que nao sera portado agora e por que: delete/write/create full suite pode vir depois; prioridade e patch seguro.
- Invariantes afetadas: 1, 2, 5, 6, 7.
- Teste unitario obrigatorio: patch com contexto fresco aplica; contexto stale rejeita; path mismatch rejeita; range mismatch rejeita.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, modelo coleta evidencia, aplica patch pequeno e validation/audit mostram sucesso.
- Revisao baixo nivel Zig antes do commit: atomicidade de escrita, backup/rollback, bounds de replace, fsync quando aplicavel, sem path traversal.

Passos de implementacao:

1. Portar somente `apply_patch` minimo como contrato `mutate_file`.
2. Exigir contexto fresco quando chamada trouxer `context_id`/`sha`.
3. Rejeitar contexto stale com erro tipado e repair.
4. Registrar raw diff internamente e evidencia destilada ao modelo.
5. Integrar gate via `set_operational_contract`.

Criterio de aceite:

- Nenhum patch com contexto stale aplica.
- Falha de patch nao parece falha do modelo.

Reconciliacao em 2026-07-16:

- Esta task foi absorvida por `T306` e esta implementada no fluxo real do agente.
- Evidencia ja registrada em `T306`: `phenom-zig/src/apply_patch_tool.zig` valida `contextId` fresco antes de escrever; `phenom-zig/src/main.zig` so executa `apply_patch` sob contrato `mutate_file`; o contexto model-visible inclui `[MICRO_CONTEXT]` para o modelo usar `contextId`.
- Validacao ja registrada em `T306`: `zig test src/apply_patch_tool.zig -lc -lsqlite3` passou com stale context, atomicidade e hunks; smoke end-to-end `PHENOM_EXPANDED_PATCH` executou `collect_evidence`, `apply_patch operation=edit stale_checked=true`, `validate_syntax` e confirmou arquivo corrigido.

## T286 - Implementar contrato de validacao e diagnostico operacional

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: T278 adicionou diagnostico Zig local, mas o produto precisa separar validacao real, diagnostico, runtime e falha de infraestrutura.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent-control/validation-policy.ts`, `validation-evidence.ts`, `lsp-diagnostics.ts`, `run_validation`.
- Falha apontada no AUDIT/TASKS: falha de modelo nao pode parecer falha de infraestrutura; validation deve virar evidencia.
- O que sera preservado do TS: policy de validacao e evidencia de erro acionavel.
- O que sera corrigido no Zig: contrato menor e tipado, sem instalar ferramentas automaticamente.
- O que nao sera portado agora e por que: LSP multi-linguagem completo fica posterior; primeiro validation contract e taxonomia.
- Invariantes afetadas: 2, 5, 6, 7.
- Teste unitario obrigatorio: validation ok/fail/infra_error geram classes distintas.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, mutation deve pedir ou receber validation antes de final quando contrato exigir.
- Revisao baixo nivel Zig antes do commit: subprocess timeout, stdout/stderr limits, exit code, ownership de buffers.

Passos de implementacao:

1. Criar `validate_work` no manifesto.
2. Implementar executor com comando configurado ou diagnostico local inicial.
3. Converter resultado em EvidencePacket v1.
4. Adicionar erro tipado `validation_failed` vs `validation_infra_error`.
5. Auditar comando, exit code, bytes, duracao.

Criterio de aceite:

- Validacao falha nao e apresentada como erro de modelo.
- Resultado de validacao pode ser citado como evidencia.

Reconciliacao em 2026-07-16:

- Esta task foi absorvida por `T306` para o escopo atual de validacao operacional.
- Evidencia ja registrada em `T306`: contrato `validate_work` libera `validate_syntax`; `mutate_file` nao libera validacao por acidente; apos patch o loop muda para validacao quando aplicavel.
- `validate_syntax` usa o diagnostic runner Zig existente e retorna evidencia destilada com `status=ok`/diagnostico, sem raw output no prompt.
- Validacao ja registrada em `T306`: `zig test src/main.zig -lc -lsqlite3`, `zig test src/apply_patch_tool.zig -lc -lsqlite3`, `sh tools/check_product_guardrails.sh` e smoke end-to-end `PHENOM_EXPANDED_PATCH` passaram com `validate_syntax status=ok`.

Risco residual:

- Taxonomia multi-linguagem/LSP/runtime completa ainda nao foi portada; o contrato atual e propositalmente estreito para Zig/local syntax e indisponibilidade operacional explicita.

## T287 - Implementar taxonomia de erros e replay SQLite de turno

Status: pending-urgent.

Prioridade: urgente.

Motivacao: SQLite existe, mas `alinhamento.md` apontou que replay deterministico e classificacao de erro ainda sao parciais.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent-control/operational-run-store.ts`, `error-parser.ts`, `run-tool-loop.ts`.
- Falha apontada no AUDIT/TASKS: cada turno deve ser auditado/reproduzido; falha de modelo nao pode parecer infra.
- O que sera preservado do TS: operational run store, fases e eventos de tool.
- O que sera corrigido no Zig: SQLite como fonte unica operacional, com evento tipado e replay textual.
- O que nao sera portado agora e por que: UI completa de inspector pode vir depois; primeiro schema/eventos.
- Invariantes afetadas: 1, 2, 3, 6, 7.
- Teste unitario obrigatorio: turno com tool aceita/rejeitada/erro/final replaya mesmos eventos.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, smoke deve consultar SQLite e verificar taxonomia.
- Revisao baixo nivel Zig antes do commit: schema migration idempotente, bind sqlite correto, lifetime de strings, sem SQL string ad hoc para dados.

Passos de implementacao:

1. Definir enum de erro: `model_protocol`, `tool_contract`, `tool_runtime`, `infrastructure`, `insufficient_evidence`, `validation_failed`.
2. Registrar modelo/backend/host/config relevantes por turno.
3. Registrar tools anunciadas, contrato ativo, tool calls, outputs internos e contexto enviado.
4. Criar comando/função de replay deterministico.
5. Testar migration em banco existente.

Criterio de aceite:

- Um turno pode ser reconstruido sem depender do terminal.
- Erros aparecem com classe objetiva.

## T288 - Implementar ContextProfile antes de news/document/runtime

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o usuario definiu que micro-contexto minimo nao serve para news, PDFs, logs e leituras massivas. Sem `ContextProfile`, o agente aplicara `code_micro` a tudo e violara regra de negocio.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: news em `../phenom-cli-ts/src/news/*`; contexto em `context-tools.ts`; decisao documentada em `TASKS.md` sobre perfis.
- Falha apontada no AUDIT/TASKS: contexto minimo nao e regra universal; news precisa catalogo e dossie.
- O que sera preservado do TS: news/document/runtime operam com stores e renderers proprios.
- O que sera corrigido no Zig: profile explicito antes de executor.
- O que nao sera portado agora e por que: news completa fica T289; esta task cria infraestrutura de perfil.
- Invariantes afetadas: 2, 3, 4, 7.
- Teste unitario obrigatorio: `code_micro`, `news_table`, `document_summary`, `runtime` geram budgets e blocos distintos.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: nao obrigatorio se for infra offline.
- Revisao baixo nivel Zig antes do commit: enums fechados, budget bounds, sem default silencioso perigoso.

Passos de implementacao:

1. Criar enum `ContextProfile`.
2. Ligar profile ao `ModelTurnContext`.
3. Impedir que `news_table` use `collect_evidence` de codigo.
4. Definir budgets por profile.
5. Auditar profile por turno.

Criterio de aceite:

- Profile errado falha explicitamente.
- News/document/runtime nao usam micro-contexto de codigo por acidente.

Implementacao concluida:

- `ContextProfile` separa `code_evidence`, `session`, `news_doc_log`, `document_summary`, `runtime_diagnostics` e `memory`.
- Schemas por profile/contrato impedem que news/document/runtime recebam `apply_patch` ou micro-contexto editavel de codigo.
- `news_doc_log` declara dossie estruturado, nao `[MICRO_CONTEXT]` de codigo.
- `document_summary` declara resumo hierarquico e bloqueia mutation.
- `memory` declara apenas promocao persistente controlada.

Limite residual:

- News/document executores completos continuam em `T289`; aqui ficou pronto o profile/contrato que impede uso acidental de `code_micro`.

Validacao executada:

- `zig test src/context_profile.zig` -> passou.
- `zig test src/product_guardrails.zig -lc -lsqlite3` -> passou.
- `sh tools/check_product_guardrails.sh` -> passou.

## T289 - Portar News com catalogo operacional de fontes e sem prompt improvisado

Status: pending-urgent.

Prioridade: urgente.

Motivacao: `alinhamento.md` marca news como declarado sem executor. A invariante 4 exige que News nao dependa de prompt improvisado.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/news/*`, `../phenom-cli-ts/src/tools/registrars/news-tools.ts`.
- Falha apontada no AUDIT/TASKS: News precisa catalogo persistente, preferencias, cache, deduplicacao e ranking.
- O que sera preservado do TS: fluxo operacional de fontes, preferencias e newspaper/dossie.
- O que sera corrigido no Zig: SQLite/catalogo operacional em vez de muitos arquivos soltos.
- O que nao sera portado agora e por que: fetch publico/TLS pode exigir adapter C/lib externa; primeiro schema/cache e fontes locais.
- Invariantes afetadas: 2, 3, 4, 6, 7.
- Teste unitario obrigatorio: fontes cadastradas alimentam briefing; fonte inexistente nao e inventada; output e dossie.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim quando houver chamada ao modelo; antes disso, smoke offline de briefing.
- Revisao baixo nivel Zig antes do commit: SQLite schema, URL bounds, cache expiry, sem rede sem timeout.

Passos de implementacao:

1. Criar tabelas de fontes/preferencias/cache.
2. Implementar contrato `news` com strategy `news_table`.
3. Gerar dossie estruturado para o modelo/renderer.
4. Bloquear fontes nao cadastradas.
5. Auditar fontes usadas e timestamps.

Criterio de aceite:

- News responde apenas a partir de fontes operacionais cadastradas.
- MEMORY/SKILLS nao recebem catalogo de news.

## T290 - Criar suite real de alinhamento e confiabilidade

Status: pending-urgent.

Prioridade: urgente.

Motivacao: smokes com marcador final podem dar falso positivo. A suite precisa provar comportamento de agente, nao so conclusao textual.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/tests/real/*`, `../phenom-cli-ts/src/tests/integration/*`.
- Falha apontada no AUDIT/TASKS: testes reais devem separar capacidade do modelo, infraestrutura do agente e comportamento esperado.
- O que sera preservado do TS: testes reais opt-in por fluxo.
- O que sera corrigido no Zig: cada smoke consulta SQLite e valida tool surface/context/evidence, nao apenas marcador.
- O que nao sera portado agora e por que: suite inteira TS nao sera copiada; serao criados cenarios equivalentes em Zig.
- Invariantes afetadas: todas.
- Teste unitario obrigatorio: runner falha quando audit esperado nao aparece.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, esta task e a suite real.
- Revisao baixo nivel Zig antes do commit: comandos nao destrutivos, paths temporarios isolados, cleanup, exit code correto.

Passos de implementacao:

1. Criar harness real opt-in para `phenom-zig`.
2. Cada cenario deve validar SQLite: tools anunciadas, calls, evidencia, raw_marker, erro tipado, resposta.
3. Criar cenarios: tool gate, raw leak, MEMORY/SKILLS, session continuity, collect_evidence refinement, patch stale, validation failure, news profile.
4. Separar falha de modelo de falha de infraestrutura no relatorio.
5. Registrar comandos em TASKS ao implementar cada cenario.

Criterio de aceite:

- Suite falha se marcador final passar mas evidencia estiver errada.
- Suite produz relatorio auditavel por turno.

## Fase 22 - Cobertura integral obrigatoria do `alinhamento.md`

Prioridade: urgente/bloqueante.

Motivacao: `T281`-`T290` cobrem a ordem recomendada do `alinhamento.md`, mas o documento tambem contem eixos, problemas novos, acertos a preservar e criterios finais que precisam existir como tarefas explicitas. Esta fase fecha essa lacuna: nenhum ponto do `alinhamento.md` deve ficar dependente de memoria do agente ou de lembranca do usuario.

Regra operacional desta fase:

- Toda task abaixo e urgente.
- Toda implementacao deve consultar `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md`, `TASKS.md`, `alinhamento.md` e a referencia equivalente em `../phenom-cli-ts` antes de codar.
- Nenhuma task pode adicionar heuristica linguistica hardcoded, stopwords, preferencia por stack, preferencia por paths de projeto ou adivinhacao de intencao pelo agente.
- O modelo decide intencao e contrato; o agente executa contrato/estrategia, audita, destila evidencia e protege invariantes.
- Toda task que alterar Zig exige revisao baixo nivel antes do commit: ownership, lifetimes, bounds, errdefer/defer, SQLite bind, fs safety, subprocess limits, streaming/protocol e raw leak.

Cobertura `alinhamento.md` -> `TASKS.md`:

- Veredito executivo: coberto por `T291` e por esta fase.
- Regra de auditoria daqui para frente: `T281`, reforcado por `T291`.
- A0 Contrato central model-driven: `T282`, `T291`.
- A1 Tool surface e ferramentas reais: `T297`.
- A2 Tool loop: `T293`.
- A3 Contexto, evidencia e micro-contexto: `T283`, `T284`, `T285`.
- A4 Ranking e busca: `T298`.
- A5 Historico, sessao, memoria e SKILLS: `T294`, `T295`.
- A6 System prompt e output para modelo: `T296`.
- A7 Renderer/TUI: `T292`.
- A8 HTTP/backend/model protocol: `T299`.
- A9 News e context profiles: `T288`, `T289`.
- A10 Patch/mutation/validacao: `T285`, `T286`.
- A11 Testes reais e criterio de confiabilidade: `T290`, `T300`.
- Mapa de alinhamento por eixo: `T291`-`T300`.
- Problemas novos introduzidos pelo Zig: `T291`, `T293`, `T296`, `T298`, `T300`.
- Acertos do Zig que devem ser preservados: `T301`.
- Criterio para dizer "alinhado": `T300`.
- Conclusao do `alinhamento.md`: `T291` e gate permanente de `T281`.

## T291 - Criar gate executavel de cobertura total do `alinhamento.md`

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o `alinhamento.md` virou contrato de auditoria. Se uma task futura puder ignorar uma secao `A0`-`A11`, o Zig volta a implementar por aproximacao e recria os erros do TS.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: todas as referencias citadas no `alinhamento.md`; a task e documental/processual.
- Falha apontada no AUDIT/TASKS: tarefas anteriores foram executadas sem sempre consultar `phenom-cli-ts`, gerando regressao de contrato.
- O que sera preservado do TS: comportamento provado passa a ser referencia obrigatoria por eixo.
- O que sera corrigido no Zig: nenhuma task nova executavel entra sem declarar quais eixos do `alinhamento.md` toca e quais nao toca.
- O que nao sera portado agora e por que: nenhuma feature runtime; primeiro o gate.
- Invariantes afetadas: todas.
- Teste unitario obrigatorio: check documental que valida cobertura `A0`-`A11`, mapa por eixo, problemas novos, acertos preservados e criterio final.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: nao aplicavel.
- Revisao baixo nivel Zig antes do commit: nao aplicavel; docs/processo.

Passos de implementacao:

1. Criar script/check que leia `alinhamento.md` e valide se cada heading `A0`-`A11` aparece em uma task urgente ou em matriz de cobertura.
2. Validar que cada task urgente nova tem bloco `Alinhamento AUDIT/TASKS/phenom-cli-ts`.
3. Validar que cada task urgente nova declara referencia TS consultada ou ausencia de equivalente.
4. Rodar check antes de implementar qualquer task de `Fase 21` ou `Fase 22`.

Criterio de aceite:

- O check falha se um eixo do `alinhamento.md` nao estiver mapeado.
- O check falha se uma task urgente nova nao declarar impacto nos criterios finais de alinhamento.

Implementacao concluida:

- Criado gate executavel para cobertura total do `alinhamento.md`.
- O check exige presenca de `A0`-`A11`, mapa por eixo, problemas novos, acertos preservados e criterio final de alinhamento.
- O check exige que todas as tasks urgentes `T281`-`T301` tenham status urgente valido e campos obrigatorios.

Validacao executada:

- `sh ../tools/check_alignment_tasks.sh` -> passou.

## T292 - Provar TUI/render com regressao visual ampla e restore completo

Status: pending-urgent.

Prioridade: urgente.

Motivacao: `A7` marcou TUI/render como area madura, mas ainda sem prova visual ampla. O usuario exigiu visual equivalente ao `phenom-cli-ts`, com prompt, thinking, tools, markdown, diff, statusbar/visualizer, spacing, resize, restore e `Worked for`.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/cli-renderer.ts`, `../phenom-cli-ts/src/stream-markdown-renderer.ts`, `../phenom-cli-ts/src/visualizer-mini.ts`, fluxo `npm run dev chat`.
- Falha apontada no AUDIT/TASKS: renderer TS tinha glitches; diff ofuscava texto; Zig precisa preservar acertos visuais sem regressao.
- O que sera preservado do TS: prompt permanente, output append-only, thinking em bloco, tools, markdown, diff, divisorias, visualizer/statusbar e restore de sessao.
- O que sera corrigido no Zig: suite de snapshots por largura e restore a partir do SQLite, nao validacao manual ad hoc.
- O que nao sera portado agora e por que: TUI fullscreen/alternate screen nao entra; requisito atual e transcript append-only copiavel.
- Invariantes afetadas: 2, 6, 7.
- Teste unitario obrigatorio: snapshots 40/80/120/180 cols com user query, thinking, tool output, markdown, code block, diff, done/worked e restore.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, um smoke real deve registrar eventos no SQLite e restaurar o transcript estilizado sem raw leak.
- Revisao baixo nivel Zig antes do commit: terminal width bounds, ANSI reset, line wrapping, no stale slices, no write parcial sem reset.

Passos de implementacao:

1. Criar fixtures completas de render equivalentes ao chat TS.
2. Criar snapshots por largura fixa.
3. Testar restore de SQLite com os mesmos componentes estilizados.
4. Validar diff com fundo discreto, sinais `+/-`, line numbers e texto legivel.
5. Validar que statusbar/visualizer nao quebra resize.

Criterio de aceite:

- O render nao quebra em terminal pequeno/grande.
- O transcript restaurado contem os mesmos componentes visuais do turno original.

## T293 - Portar loop operacional por fases sem estreitar o agente a respondedor com evidencia

Status: pending-urgent.

Prioridade: urgente.

Motivacao: `A2` diz que o loop Zig esta correto para `collect_evidence`, mas estreito demais para o produto. O TS tinha state, phase context, operational run store, memory/context compaction e executor por fase.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent.ts` em "Core tool loop"; `../phenom-cli-ts/src/agent-control/run-tool-loop.ts`; `../phenom-cli-ts/src/agent-control/operational-run-store.ts`.
- Falha apontada no AUDIT/TASKS: prompt/loop nao podem virar contrato improvisado; cada fase precisa ser auditavel.
- O que sera preservado do TS: fases operacionais, state por turno, run store, compaction de contexto e separacao de tool/model/infra.
- O que sera corrigido no Zig: loop tipado menor, sem camadas soltas, com contratos progressivos e erro classificado.
- O que nao sera portado agora e por que: browser/runtime completos dependem de T297/T299; aqui entra o esqueleto de fases.
- Invariantes afetadas: 1, 2, 5, 6, 7.
- Teste unitario obrigatorio: fase `intent -> contract -> evidence -> mutation -> validation -> final` progride com executor fake e rejeita transicao invalida.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, modelo deve declarar contrato, coletar evidencia, refinar e finalizar sem tool nao anunciada.
- Revisao baixo nivel Zig antes do commit: enum exaustivo, estado por turno sem ponteiro pendurado, limites de iteracao por budget/qualidade, cleanup de buffers.

Passos de implementacao:

1. Definir `OperationalPhase` e `TurnRunState`.
2. Integrar `set_operational_contract` como entrada de fase.
3. Auditar transicoes no SQLite.
4. Impedir que falha de tool caia em resposta direta sem erro tipado.
5. Permitir multiplas iteracoes por budget/qualidade, nao por numero fixo arbitrario.

Criterio de aceite:

- O agente nao finaliza como "respondedor com evidencia" quando o contrato exige acao.
- O replay mostra fase, contrato, tools anunciadas, calls, resultado e final.

## T294 - Corrigir continuidade de sessao para equivalencia com `recentMessages` e sumarizacao longa

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: `A5` mostra que `RECENT_DIALOGUE` corrigiu o bug imediato, mas ainda nao e equivalente ao historico por roles do TS nem resolve sessoes longas.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent.ts` em `recentMessages`; `../phenom-cli-ts/src/use-cases/build-inference-messages.ts`.
- Falha apontada no AUDIT/TASKS: multiplas fontes de memoria/contexto competiam; historico bruto e wrappers podiam vazar.
- O que sera preservado do TS: janela recente como mensagens por role, sanitizacao de wrappers/protocolos crus e current query preservada.
- O que sera corrigido no Zig: manter continuidade sem promover para MEMORY/SKILLS e sem transformar sessao em evidencia estrita por engano.
- O que nao sera portado agora e por que: embedding semantic search nao entra; decisao atual e FTS5/BM25 + contratos.
- Invariantes afetadas: 2, 3, 6, 7.
- Teste unitario obrigatorio: historico recente vira mensagens/estrutura com roles; wrappers crus sao removidos; prompt atual nao duplica.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, pergunta dependente de conversa anterior deve responder sem `search_session`; fato exato antigo deve usar `search_session`.
- Revisao baixo nivel Zig antes do commit: bounds de historico, truncamento por mensagem, ownership de blocos, zero raw markers.

Passos de implementacao:

1. Decidir e documentar se Zig vai enviar historico como mensagens reais ou bloco estruturado equivalente.
2. Implementar sumarizacao longa com FTS5/BM25 de sessao e snippets por role/turn.
3. Separar `RECENT_DIALOGUE` de `SESSION_EVIDENCE` no renderer e no audit.
4. Garantir que MEMORY/SKILLS nao recebem eventos de sessao automaticamente.
5. Auditar bytes/tokens de historico por turno.

Criterio de aceite:

- Conversa recente funciona como continuidade, nao como evidencia litigiosa.
- Sessao longa e recuperavel sem mandar historico bruto inteiro.

Status de completude em 2026-07-08:

- Entregue: historico recente por roles reais, `SESSION_FOCUS` operacional em SQLite, `turn_quality` auditavel, FTS5/BM25 em SQLite, `search_session(scope=current|all, session?)`, S# com `session=`, contexto de turno nos hits de sessao, dedupe preservando ultimo `[SESSION_EVIDENCE]`, separacao de MEMORY/SKILLS e contexto operacional.
- Nao entregue integralmente: sumarizacao longa de sessao e suite opt-in ampla para conversas longas/multissessao.
- Provado nesta etapa: smoke real reproduzivel com servidor ativo para o caso "eu estava falando sobre o que com voce?" na sessao `default`; o modelo recuperou `Matheus` e nao caiu em "nao tenho acesso ao historico". Smoke real posterior com "entao por que voce nao pontuou isso nos assuntos..." acionou `search_session`, recebeu contexto de turno e respondeu usando o assunto de Mateus/Matheus.
- Falta para 100%: completar sumarizacao longa de sessao, consolidar smokes de conversas longas/multissessao como suite opt-in e executar smoke real da arquitetura por perfil provando que `session_recall` chama `search_session` no primeiro fluxo, sem repair textual, antes de marcar a feature inteira como `done`.
- Risco residual: a garantia ampla de continuidade operacional ainda depende da cobertura dos smokes restantes.

Atualizacao em 2026-07-16:

- `phenom-zig/src/session_context.zig`: adiciona `renderLongSessionSummary` para sessoes longas, com linhas compactas por turno confirmado, `operational_summary=true`, `not_evidence=true` e `long_session=true`.
- O resumo longo ignora o prompt atual e turnos falhos/low-confidence para nao contaminar continuidade, MEMORY/SKILLS ou `SESSION_CONTEXT`.
- `phenom-zig/src/main.zig`: mescla o resumo longo em `SESSION_FOCUS`, preservando a regra de que fatos exatos antigos continuam exigindo `search_session` e citacao `S#`.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-t294-session-context` -> passou; 95 testes.

Fechamento em 2026-07-16:

- `phenom-zig/src/session_context.zig`: fallback legado de `SESSION_FOCUS` agora ignora turnos completados com `low_confidence=true`/falha, evitando contaminar contexto longo com tentativas ruins.
- `phenom-zig/src/main.zig`: teste de integracao prova que o contexto inicial inclui `long_session=true`, omite turnos falhos/current prompt do foco e nao promove nada para MEMORY/SKILLS.
- `phenom-zig/build.zig`: adiciona `real-long-session-smoke`, suite opt-in de sessao longa com seis turnos seed e recall final.
- `phenom-zig/README.md`: documenta `real-long-session-smoke`.
- Smoke real/fake em `long-session-fake-294`: seis turnos seed + recall final passaram; SQLite confirmou `long_session_contexts=2`, `model_context_budget=18`, `search_session_calls=2`, `raw_markers=0`, `turn_done_ok=9`.
- Validacao final: `zig test src/session_context.zig -lc -lsqlite3` -> passou; 96 testes. `zig test src/main.zig -lc -lsqlite3` -> passou; 254 testes.

Risco residual:

- Sem embeddings; a decisao do produto permanece FTS5/BM25 + contratos model-driven.

Atualizacao de arquitetura de contexto por perfil em 2026-07-08:

- `phenom-zig/src/context_profile.zig` cria perfis `code_micro`, `session_recall`, `code_evidence` e `news_doc_log`, com schema model-visible por estado (`initial`, `active_contract`, `after_search_session`, `after_collect_evidence`).
- A selecao de perfil usa estado operacional leve, nao heuristica de assunto: sem tool loop vira `code_micro`; com tool loop vira `code_evidence`. `SESSION_FOCUS` nao forca `session_recall`, porque isso prendeu perguntas de workspace em busca de sessao.
- `session_recall` inicial anuncia somente `search_session`; `code_evidence` inicial anuncia `set_operational_contract`, `collect_evidence` e `search_session`; contextos pos-tool nao reenviam schema completo.
- `phenom-zig/src/audit.zig` cria tabela `session_focus` com `topic`, `user_intent`, `useful_facts`, `quality` e `flags`, mantendo SQLite como storage operacional e nao como MEMORY/SKILLS.
- `phenom-zig/src/main.zig` destila cada turno apos `turn_done` com flags objetivas: `answered`, `used_session_context`, `used_evidence`, `refusal`, `contradicted_context=false`, `low_confidence`.
- `phenom-zig/src/session_context.zig` limita `RECENT_DIALOGUE` a continuidade curta e remove `recent_user_topics` desse bloco; topicos longos passam por `SESSION_FOCUS`.
- Em `session_recall`, resposta sem `search_session`/`SESSION_CONTEXT` vira `quality=uncertain`, `contract_missing_context=true` e `low_confidence=true`; o repair textual `session recall denial without search_session` foi removido do fluxo.
- Fallback para sessoes antigas usa apenas `turn_start` compacto como `SESSION_FOCUS legacy_fallback`, sem `assistant_delta` bruto como fonte confiavel.
- Nao foram adicionadas stopwords, listas de linguagem, vies por path/ecossistema nem ranking semantico hardcoded.

Revisao baixo nivel Zig desta atualizacao:

- Ownership: `SessionFocus` duplica colunas SQLite e libera via `freeSessionFocus`; `TurnQuality` duplica `quality/flags` e libera no fechamento do turno.
- SQLite: `session_focus` e `loadLatestTurnEvents` usam SQL parametrizado; statements finalizam com `defer`; limites validam `c_int`.
- Bounds: `RECENT_DIALOGUE` foi reduzido para 4 mensagens e entradas de 600 bytes; `SESSION_FOCUS` compacta linhas e filtra `low_confidence=true`.
- Raw leak: renderers novos passam por redacao/assert de raw markers; MEMORY/SKILLS continuam opt-in por arquivos persistentes.
- Reparos: o repair textual de negativa foi removido; falhas viram qualidade auditavel por contrato operacional e nao segunda inferencia escondida.

Validacao desta atualizacao:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/audit.zig -lc -lsqlite3` -> passou; 23 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` -> passou; 80 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 194 testes.
- Smoke real desta atualizacao: sessao `context-profile-smoke-297`; seed `PHENOM_PROFILE_SEED_297` passou; pergunta ambigua `eu estava falando sobre o que com voce?` acionou `search_session` no primeiro fluxo, retornou S# com `Mateus 1` e respondeu usando a evidencia.
- Audit SQLite do smoke `context-profile-smoke-297`: `tool_repair=0`, `search_session=1`, `memory_block=0`, `skills_block=0`, `raw_marker=0`, `max_context_bytes=2478`.
- Correcao de alinhamento apos revisao: removida a heuristica textual de negativa (`containsSessionDenial` e marcadores de frase); baixa confianca agora deriva de quebra objetiva do contrato `session_recall` quando falta `search_session`/`SESSION_CONTEXT`.

Atualizacao de correcao em 2026-07-09:

- `phenom-zig/src/context_profile.zig`: perfil inicial com tool loop permanece `code_evidence`, expondo `collect_evidence` e `search_session`; `SESSION_FOCUS` vira mapa operacional para o modelo escolher a ferramenta, nao gatilho rigido de perfil.
- `phenom-zig/src/main.zig`: `NEXT_ACTION` quando ha `SESSION_FOCUS` exige exatamente uma tool de contexto antes da prosa, escolhida pelo modelo: `search_session` para fatos de sessao ou `collect_evidence` para workspace/source-code.
- `phenom-zig/src/collect_evidence.zig`: `path="."` e `path="./"` agora significam raiz do workspace e usam ranking/overview, evitando evidencia falsa `- . L1-L1`.
- `phenom-zig/src/working_context.zig`: evidencia ativa model-visible foi limitada a 4 KiB por entrada; se o modelo precisar de mais, deve refinar via nova tool call, mantendo o micro-contexto pequeno.
- Nao foram adicionadas heuristicas linguisticas, stopwords, listas de paths preferidos ou reparo textual oculto.

Validacao da correcao em 2026-07-09:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 195 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc -lsqlite3` -> passou; 50 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/context_profile.zig` -> passou; 2 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-release-cache-flow-final-2 -Doptimize=ReleaseFast` -> passou.
- Smoke real `agent-flow-audit-20260709f`: 4 turnos como usuario comum; pergunta de memoria chamou `search_session` e citou contexto S#; pergunta sobre cwd chamou `collect_evidence: .` e retornou README real.
- Audit SQLite do smoke `agent-flow-audit-20260709f`: `turns=4`, `model_context_count=6`, `avg_context_bytes=3871`, `max_context_bytes=5278`, `search_session_calls=1`, `collect_evidence_calls=1`, `tool_repairs=0`, `low_confidence_turns=0`, `memory_block=0`, `skills_block=0`, `raw_marker=0`.
- Risco residual honesto: o modelo ainda pode responder diretamente em pedidos genericos de ajuda sem tool, o que e aceitavel quando nao faz afirmacao de workspace ou sessao; a suite final de conversas longas/multissessao continua pendente para T294 ficar 100%.

Implementacao desta etapa:

- `phenom-zig/src/audit.zig` adiciona `events_fts` com FTS5/BM25 sobre SQLite operacional da sessao.
- A busca de sessao e restrita por `session`, exclui o prompt atual e pesquisa somente `body`, nao metadados como `kind`, evitando falso positivo operacional.
- `phenom-zig/src/session_context.zig` adiciona renderer de hits FTS como `[SESSION_EVIDENCE]` temporario, com `source=sqlite_audit_fts`, `semantic_search=fts5_bm25` e `raw_context_persisted=false`.
- `phenom-zig/src/main.zig` nao executa mais FTS inicial baseada no prompt do usuario; `[SESSION_CONTEXT]` pesquisavel entra por `search_session` guiado pelo modelo, enquanto `[RECENT_DIALOGUE]` carrega apenas continuidade e trilha compacta de topicos.
- `search_session` deixa de carregar 2000 eventos em memoria e passa a usar SQLite FTS5/BM25 com termos definidos pelo modelo.
- Correcao posterior: `search_session` agora aceita `scope=current|all` e `session?`, permitindo recuperacao operacional de qualquer sessao ativa/inativa gravada no SQLite quando o modelo pedir explicitamente.
- Hits de sessao agora carregam `session=` no S#, para o modelo diferenciar evidencia da sessao atual, outra sessao especifica ou busca global.
- `search_session scope=all` filtra `tool_start` do proprio `search_session` para evitar evidencia recursiva da consulta anterior; outros eventos operacionais continuam auditados no SQLite.
- Nao foram adicionadas stopwords, listas de linguagem, priorizacao de path, ranking por ecossistema ou heuristica linguistica hardcoded.

Revisao baixo nivel Zig:

- Ownership: `SessionSearchHit.session/kind/body` sao duplicados por coluna e liberados por `freeSessionSearchHits`.
- Bounds: `limit` valida `c_int`; renderer limita saida a `max_search_entries`; cada linha passa por `compactOneLine`.
- SQLite: binds usam slices null-terminated temporarias liberadas apos `sqlite3_step`; `scope=all` usa bind null para remover filtro de sessao sem string SQL dinamica; statements sao finalizados com `defer`.
- Contaminacao recursiva: `tool_start` de `search_session` e gravado depois da consulta e o FTS exclui `tool_start` cujo body comeca com `search_session`, evitando que a ferramenta encontre a propria chamada.
- Raw leak: `renderSearchHits` redige markers e chama `assertNoRawContextLeak`; `model_context` continua barrando raw markers.
- Storage: SQLite operacional nao promove eventos para `MEMORY.md`/`SKILLS.md`.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test phenom-zig/src/audit.zig -lc -lsqlite3` -> passou; 20 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` em `phenom-zig/` -> passou; 72 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig -lc -lsqlite3` em `phenom-zig/` -> passou; 16 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` em `phenom-zig/` -> passou; 181 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` em `phenom-zig/` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` em `phenom-zig/` -> passou.
- Smoke real cross-session seed: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --session cross-source-306 --prompt 'Nesta sessao, registre este fato operacional para busca global: a palavra-codigo cross-session e CROSS-SESSION-306. Responda exatamente: PHENOM_CROSS_SEED_306' --expect-contains PHENOM_CROSS_SEED_306 --show-expect-status --fail-on-model-error --no-color` -> passou.
- Smoke real cross-session recall: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 900 --session cross-target-306 --prompt 'Use search_session com terms "cross-session CROSS-SESSION-306 palavra-codigo" e scope all para buscar em qualquer sessao ativa ou inativa. Depois responda exatamente no formato: CODIGO=<valor> PHENOM_CROSS_RECALL_306' --expect-contains CROSS-SESSION-306 --show-expect-status --fail-on-model-error --no-color` -> passou; S1 veio de `session=cross-source-306`, sem `tool_start search_session` como evidencia principal.
- `sh tools/check_alignment_tasks.sh` -> passou.
- Smoke real seed: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 260 --session session-fts-294 --prompt 'Nesta sessao, registre este acordo operacional: a palavra-codigo de validacao do contexto de sessao e AZUL-FTS-294. Responda exatamente: PHENOM_SEED_294' --expect-contains PHENOM_SEED_294 --show-expect-status --fail-on-model-error --no-color` -> passou.
- Smoke real recall: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 420 --session session-fts-294 --prompt 'Qual foi a palavra-codigo de validacao do contexto de sessao que combinamos? Responda exatamente no formato: CODIGO=<valor> PHENOM_RECALL_294' --expect-contains PHENOM_RECALL_294 --show-expect-status --fail-on-model-error --no-color` -> passou; resposta `CODIGO=AZUL-FTS-294 PHENOM_RECALL_294`.
- `phenom-zig/build.zig` adiciona `real-session-smoke`, um smoke opt-in reproduzivel de dois turnos que grava a palavra-codigo na sessao e valida recuperacao no segundo turno com `--expect-contains`.
- `phenom-zig/README.md` documenta `real-session-smoke` como validacao real de contexto de sessao.
- Smoke real reproduzivel: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-session-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest -Dreal-session=real-session-smoke-294b` -> passou; segundo turno respondeu `CODIGO=AZUL-FTS-294 PHENOM_SESSION_RECALL_294`.
- Audit SQLite do target `real-session-smoke-294b`: `fts_context=1`, `raw_marker=0`, `memory_block=0`, `skills_block=0`.
- Audit SQLite: `fts_context=1`, `raw_marker=0`, `memory_block=0`, `skills_block=0`.

Risco residual:

- A busca e "semantica" no sentido operacional acordado para esta etapa: FTS5/BM25 lexical ranqueado, sem embeddings e sem segundo modelo ativo.
- Busca cross-session/global agora existe por contrato, mas so executa quando o modelo pede `scope=all` ou passa `session`. O contexto inicial continua restrito a sessao atual para nao poluir micro contexto nem quebrar replay.

Correcao posterior de continuidade curta:

- Log real mostrou regressao: apos o agente responder "Sou um modelo da Google", o usuario perguntou apenas "da google?" e o modelo tratou como pergunta isolada.
- Causa raiz: `[RECENT_DIALOGUE]` existia como bloco textual auditavel, mas o HTTP enviava esse bloco como uma mensagem `user` de contexto, nao como chat history real com roles `user`/`assistant`.
- `phenom-zig/src/http.zig` agora aceita `dialogue` em `InferenceInput` e serializa mensagens recentes como roles reais para Ollama e llama.cpp.
- `phenom-zig/src/main.zig` monta `dialogue` a partir do SQLite operacional e passa para o backend no turno real.
- `phenom-zig/src/session_context.zig` corrige a exclusao do prompt atual: agora remove somente o `turn_start` atual mais recente, sem apagar turnos antigos com o mesmo texto.
- `phenom-zig/build.zig` adiciona `real-dialogue-smoke`, smoke opt-in de dois turnos para follow-up ambiguo curto.
- `phenom-zig/README.md` documenta `real-dialogue-smoke`.
- Unitarios: `session_context` prova prompt repetido antigo preservado; `main` prova roles recentes; `http` prova serializacao de roles antes do prompt atual.
- Smoke real manual: sessao `continuity-google-301`; turno 1 respondeu `Sou um modelo da Google.`; turno 2 `da google? ...` respondeu `Sim, PHENOM_CONTINUIDADE_301`.
- Audit SQLite da sessao `continuity-google-301`: `recent_dialogue=2`, `raw_marker=0`, `memory_block=0`, `skills_block=0`.
- Smoke real reproduzivel: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-dialogue-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest -Dreal-dialogue-session=real-dialogue-smoke-301c` -> passou; segundo turno `da google?` respondeu `Sim`.
- Audit SQLite da sessao `real-dialogue-smoke-301c`: `recent_dialogue=2`, `raw_marker=0`, `memory_block=0`, `skills_block=0`.

Correcao posterior de linearidade do chat:

- Log real mostrou outro sintoma da mesma familia: apos um exemplo simples de `media(notas)`, o usuario pediu "me de um exemplo mais robusto" e o modelo disse que nao tinha contexto anterior, mudando para Flask/autenticacao.
- Causa raiz refinada: o contexto operacional ainda era serializado como uma mensagem `user` antes do historico real. Isso inseria uma fala artificial no meio da conversa e reduzia a saliencia linear do historico para modelo pequeno.
- `phenom-zig/src/http.zig` agora coloca `ModelTurnContext` dentro da mensagem `system`; o fluxo enviado ao backend fica `system(contexto operacional) -> user/assistant recentes -> user atual`.
- Unitarios HTTP travam que o contexto nao vira `user` artificial e que roles reais precedem o prompt atual.
- Smoke real manual: sessao `continuity-example-302`; turno 1 pediu exemplo simples de `calcular_media`; turno 2 pediu apenas "me de um exemplo mais robusto"; resposta preservou `calcular_media`.
- Audit SQLite da sessao `continuity-example-302`: `recent_dialogue=1`, `raw_marker=0`, `memory_block=0`, `skills_block=0`.
- `real-dialogue-smoke` foi ajustado para esse caso: seed com `calcular_media` e follow-up "me de um exemplo mais robusto"; falha se a resposta nao contiver `calcular_media`.
- Smoke real reproduzivel: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build real-dialogue-smoke -Dreal-backend=llamacpp -Dreal-host=192.168.1.122:11434 -Dreal-model=phenom:latest -Dreal-dialogue-session=real-dialogue-smoke-302` -> passou; segundo turno manteve `calcular_media`.
- Audit SQLite da sessao `real-dialogue-smoke-302`: `recent_dialogue=2`, `raw_marker=0`, `memory_block=0`, `skills_block=0`.

Correcao posterior de duplicata em `search_session`:

- Log real mostrou regressao: o modelo chamou `search_session` duas vezes com os mesmos termos, recebeu evidencia correta na primeira chamada, mas no ramo de duplicata o agente renderizou `SESSION_CONTEXT` vazio e instruiu "Answer using existing E#/S# evidence".
- Causa raiz: `ToolLoopState` guardava apenas as chaves de busca em `session_searches`, nao o ultimo texto `[SESSION_EVIDENCE]`. A segunda inferencia via duplicata nao recebia S# nenhum e o modelo concluiu que nao tinha historico.
- `phenom-zig/src/main.zig` agora guarda `last_session_context` owned no estado do turno e reenvia esse texto em `session_context_duplicate`.
- A memoria e liberada em `ToolLoopState.deinit`; nova evidencia de sessao substitui a anterior com ownership claro.
- Teste unitario novo: `tool loop state keeps session evidence for duplicate search repair` prova que duplicata preserva `[SESSION_CONTEXT]`, S# e conteudo recuperado.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` em `phenom-zig/` -> passou; 182 testes.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test` em `phenom-zig/` -> passou.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast` em `phenom-zig/` -> passou.
- Validacao: `sh tools/check_alignment_tasks.sh` -> passou.
- Smoke real tentado com a pergunta do log (`eu estava falando sobre o que com voce?`) na sessao `default`, mas o servidor `192.168.1.122:11434` falhou com `ConnectFailed` depois de `2m16s`; `curl --max-time 5 http://192.168.1.122:11434/` retornou timeout. Resultado real fica pendente por infraestrutura, nao por falha de teste/unit/build.

Correcao posterior de contaminacao por turno falho:

- Log real mostrou que o modelo continuava respondendo "Nao tenho acesso ao historico" mesmo quando `[SESSION_CONTEXT]` ja continha evidencia correta de `Matheus 1`.
- Causa raiz: respostas de turnos encerrados com `turn_done status=expectation_failed` ainda entravam em `[RECENT_DIALOGUE]` e no chat history real como mensagens `assistant`, contaminando a proxima inferencia.
- `phenom-zig/src/session_context.zig` agora remove do dialogo recente o turno inteiro quando `turn_done` tem `status=expectation_failed` ou `status=model_error`.
- `phenom-zig/src/main.zig` aplica o mesmo criterio ao chat history real enviado ao backend e tambem ignora deltas pertencentes ao `turn_start` atual.
- Revisao baixo nivel: truncamento libera slices owned antes de reduzir `ArrayList`; nao ha ponteiro emprestado novo; criterio usa status auditavel, nao heuristica linguistica.
- Unitarios: `recent dialogue excludes failed turn assistant output by audit status` e `recent chat messages exclude failed assistant turns by audit status`.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` -> passou; 74 testes.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 185 testes.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-local-cache test` -> passou.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-release-cache -Doptimize=ReleaseFast` -> passou.
- Validacao: `sh ../tools/check_alignment_tasks.sh` -> passou.
- Smoke real manual: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 900 --session default --prompt 'eu estava falando sobre o que com voce?' --expect-contains Matheus --show-expect-status --fail-on-model-error --no-color` -> passou; resposta recuperou `Matheus` e tambem citou outro assunto recente da sessao.
- Instalacao local: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-release-cache install-local -Doptimize=ReleaseFast` -> passou.
- Smoke real pelo binario instalado: `phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 900 --session default --prompt 'eu estava falando sobre o que com voce?' --expect-contains Matheus --show-expect-status --fail-on-model-error --no-color` -> passou.

Correcao posterior de uso pratico dos assuntos da sessao:

- Log real mostrou que o modelo conseguia "lembrar" palavras como Matheus, mas nao usava a sessao de forma util: respondia que nao havia evidencia/contexto mesmo com `recent_user_topics` e conversa anterior disponiveis.
- Causa raiz 1: `loadRecentSessionEvents(..., 240)` carregava eventos brutos, entao centenas de `assistant_thinking_delta` expulsavam `turn_start` antigos e a lista de assuntos sumia.
- Causa raiz 2: `buildInitialModelContext` ainda fazia FTS/BM25 inicial com o prompt bruto do usuario. Em prompt ambiguo, isso virava `prompt -> agente adivinha -> contexto ruim`, contrariando o fluxo definido: `prompt -> modelo define intencao -> agente executa contrato`.
- Causa raiz 3: hits de `search_session` eram eventos soltos; o modelo recebia palavra encontrada, mas nao a unidade de conversa/assunto.
- `phenom-zig/src/audit.zig`: `loadRecentSessionEvents` agora filtra apenas eventos uteis para contexto conversacional (`turn_start`, `assistant_delta`, tools/evidencias compactas e `turn_done`), ignorando thinking/model_context.
- `phenom-zig/src/audit.zig`: cada `SessionSearchHit` agora carrega `event_id` e `turn_events`, do `turn_start` anterior ate antes do proximo `turn_start`, limitado e sem prompt atual.
- `phenom-zig/src/session_context.zig`: `renderSearchHits` renderiza `unit=turn_context`, agrupa deltas tokenizados de `assistant_delta`, deduplica turns repetidos e mostra user/assistant/turn_done como unidade S#.
- `phenom-zig/src/session_context.zig`: `recent_user_topics` aparece antes dos ultimos turnos no `[RECENT_DIALOGUE]`, para preservar mapa de assuntos sem promover para MEMORY/SKILLS.
- `phenom-zig/src/main.zig`: remove FTS inicial baseada no prompt; `[SESSION_CONTEXT]` pesquisavel entra somente quando o modelo chama `search_session`.
- `phenom-zig/src/main.zig`: adiciona guard de contrato para negativa explicita de historico/evidencia quando ha `recent_user_topics` e nenhuma `search_session` foi executada; nesse caso, o controlador faz uma segunda inferencia pedindo uma tool call `search_session` com termos escolhidos pelo modelo. Comentario `ponytail` marca o limite: substituir por canal tipado quando o protocolo do modelo suportar.
- Revisao baixo nivel: `SessionSearchHit` agora possui `turn_events` owned e libera com `freeAuditEvents`; render de thread usa buffers owned e libera via `freeThreadEntries`; SQL usa binds parametrizados e statements finalizados com `defer`.
- Unitarios: `recent session events ignore thinking noise for dialogue context`, `session fts hit carries whole turn context`, `session fts renderer merges tokenized assistant deltas inside turn context`, `initial model context does not run prompt based session fts`, `session recall denial repair requires topics and denial`.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/audit.zig -lc -lsqlite3` -> passou; 22 testes.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` -> passou; 78 testes.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 190 testes.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-local-cache-6 test` -> passou.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-release-cache-6 -Doptimize=ReleaseFast` -> passou.
- Smoke real manual: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 1600 --session default --prompt 'entao por que voce nao pontuou isso nos assuntos que voce lembra anteriormente?' --fail-on-model-error --no-color` -> passou no comportamento: controlador acionou `search_session`, evidencia veio como `unit=turn_context`, deltas antigos foram agrupados e a resposta usou o assunto de Mateus/Matheus.
- Instalacao local: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-release-cache-6 install-local -Doptimize=ReleaseFast` -> passou.
- Smoke real pelo binario instalado: `phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 1600 --session default --prompt 'entao por que voce nao pontuou isso nos assuntos que voce lembra anteriormente?' --fail-on-model-error --no-color` -> passou; acionou `search_session` e respondeu usando o assunto Mateus/Matheus.

## T295 - Implementar orchestrator final de MEMORY/SKILLS separado do SQLite operacional

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: `A5` e o mapa de alinhamento marcam MEMORY/SKILLS como parcial. A regra do usuario e absoluta: MEMORY/SKILLS sao as unicas fontes persistentes textuais visiveis ao modelo; SQLite operacional nao compete com elas.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/memory/*`, `../phenom-cli-ts/src/session-brain.ts`, usos de memoria em `../phenom-cli-ts/src/agent.ts`.
- Falha apontada no AUDIT/TASKS: SessionBrain, PersistentMemory, operational stores e arquivos de contexto podiam competir conceitualmente.
- O que sera preservado do TS: capacidade de lembrar preferencias, regras e fatos praticos quando promovidos.
- O que sera corrigido no Zig: writer/orchestrator explicito com promocao controlada, sem memoria concorrente e sem tool output automatico.
- O que nao sera portado agora e por que: UI completa de gerenciamento de memoria pode vir depois; primeiro contrato e store.
- Invariantes afetadas: 2, 3, 6, 7.
- Teste unitario obrigatorio: regra do usuario vai para SKILLS; insight verificado vai para MEMORY; tool output bruto nunca vira memoria sem promocao.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, uma regra confirmada deve aparecer em SKILLS em turno posterior; evidence temporaria nao deve aparecer.
- Revisao baixo nivel Zig antes do commit: escrita atomica de arquivos, merge sem sobrescrever usuario, bounds, locks simples ou estrategia anti-corrupcao.

Passos de implementacao:

1. Definir contrato de promocao para MEMORY e SKILLS.
2. Implementar leitura/escrita atomica com preservacao de edicoes do usuario.
3. Auditar promocao no SQLite como evento operacional, nao como contexto bruto.
4. Renderizar MEMORY/SKILLS somente quando existem e somente como blocos persistentes textuais.
5. Testar que SQLite/news/session/cache nao geram MEMORY/SKILLS.

Criterio de aceite:

- MEMORY/SKILLS nao competem com storage operacional.
- O modelo recebe apenas regras/fatos promovidos, nunca logs ou tool output bruto.

Implementacao concluida:

- Contrato `memory` adicionado como surface model-visible separada.
- Tool `promote_context(target=memory|skills,text)` exposta somente sob contrato `memory`.
- `promote_context` grava via `persistent_context.promoteFromCwd`, com escrita atomica, dedupe, limite de bytes e rejeicao de raw markers.
- Eventos `persistent_promotion` entram no SQLite como audit operacional, nao como contexto bruto.
- `MEMORY.md`/`SKILLS.md` continuam sendo os unicos blocos persistentes textuais renderizados ao modelo.
- Classificacao de qualidade considera `promote_context`/`persistent_promotion` como satisfazendo a obrigacao inicial de contexto quando o contrato exige promocao.

Validacao executada:

- `zig test src/persistent_context.zig -lc -lsqlite3` -> passou.
- `zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-main-memory-quality-test` -> passou; 242 testes.
- Smoke ambiguo real/fake em fixture temporario: modelo selecionou contrato `memory`, chamou `promote_context(target=skills, ...)`, criou/atualizou `SKILLS.md` e encerrou com `turn_done quality=confirmed used_persistent_context=true context_tool_missing=false`.
- `sh tools/check_product_guardrails.sh` -> passou.

## T296 - Tipar output para modelo, token accounting e `NEXT_ACTION`

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: `A6` mostra que o system prompt Zig ficou curto, mas o contexto ainda depende de texto `TURN_CONTEXT v1` e `NEXT_ACTION` pode crescer como micro-system-prompt variavel.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent.ts` em `buildSystemPrompt`; `../phenom-cli-ts/src/use-cases/build-inference-messages.ts`.
- Falha apontada no AUDIT/TASKS: system prompt inchado alucina modelo pequeno; contexto bruto ou estruturacao ruim consome janela rapidamente.
- O que sera preservado do TS: prefixo estavel, contexto volatil fora do system prompt, sanitizacao de mensagens.
- O que sera corrigido no Zig: `NEXT_ACTION` vira campo tipado de contrato; prompt/context bytes sao auditados; raw leak, budget e token usage real viram falha objetiva.
- O que nao sera portado agora e por que: compactacao pre-envio por tokenizer real do backend ainda depende de integrar `/tokenize`; estimativa char/token nao sera usada.
- Invariantes afetadas: 2, 3, 6, 7.
- Teste unitario obrigatorio: renderer rejeita raw markers, mede bytes, falha em budget e renderiza `next_action` tipado.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, SQLite deve registrar system/context bytes e prefix stability.
- Revisao baixo nivel Zig antes do commit: buffer writer bounds, truncamento seguro, sem alloc nao liberado, assert anti-raw antes de envio.

Passos de implementacao:

1. Criar struct tipada para `ModelTurnContextV1`.
2. Separar `next_action` como enum/struct, nao texto livre acumulativo.
3. Auditar bytes por bloco: system, memory, skills, recent dialogue, evidence, session, tools.
4. Registrar estabilidade de prefixo por hash.
5. Falhar envio se raw marker entrar no contexto renderizado.

Criterio de aceite:

- O modelo recebe contexto pequeno, tipado e auditavel.
- O system prompt nao vira deposito de regras variaveis por fase.

Atualizacao parcial em 2026-07-09:

- Entregue: token accounting real pos-inferencia em `phenom-zig/src/http.zig`, `phenom-zig/src/main.zig` e `phenom-zig/src/tui.zig`.
- Entregue: OpenAI-compatible/Ollama/llama.cpp counters reais sao parseados; updates streaming atualizam statusbar; somente evento final `token_usage` e persistido no SQLite.
- Validacao: `zig test src/http.zig -lc`, `zig test src/tui.zig -lc`, `zig test src/main.zig -lc -lsqlite3`, build release e smoke real `token-accounting-real-20260709b`.
- Ainda falta para 100%: tokenizer real pre-envio para compactacao no ponto exato e buckets por bloco do prompt/contexto.

Atualizacao parcial em 2026-07-16:

- `phenom-zig/src/model_context.zig`: adiciona `NextActionKind`, `NextAction` e `next_action_v1`, mantendo o campo legado `next_action` para migracao gradual dos call sites.
- `NEXT_ACTION` tipado renderiza `kind`, `required_tool_calls` e `action`, evitando crescimento silencioso como micro-system-prompt sem metadado.
- `measureRenderedContextBytes` mede buckets por bloco renderizado: system, header, contracts, skills, memory, candidates, evidence, focus, dialogue, session, obligations, grounding e next_action.
- Validacao: `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/model_context.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-t296-model-context` -> passou; 69 testes.

Fechamento em 2026-07-16:

- `phenom-zig/src/main.zig`: todo `ModelTurnContext` enviado ao backend passa por `recordModelContextBudget` imediatamente antes de `streamInference`.
- O audit SQLite grava `model_context_budget` com buckets pre-send: system, header, contracts, skills, memory, candidates, evidence, focus, dialogue, session, obligations, grounding, next_action, total e limite.
- O envio falha antes do backend com `ModelContextBudgetExceeded` se o contexto passar de `24 KiB`, e continua chamando `assertNoRawContextLeak` antes de enviar.
- A politica de tokens ficou explicita e sem estimativa falsa: `model_context_budget` registra `tokenizer=unavailable token_estimate=false`; tokens reais continuam entrando por `token_usage` quando Ollama/OpenAI-compatible/llama.cpp retornam contadores reais.
- Smoke real/fake em `long-session-fake-294`: SQLite confirmou `model_context_budget=18`, `raw_markers=0` e turnos confirmados; os eventos incluem `focus_bytes`, `dialogue_bytes`, `session_bytes` e `total_context_bytes`.
- Validacao final: `zig test src/main.zig -lc -lsqlite3` -> passou; 254 testes. `zig build --cache-dir /tmp/phenom-zig-t296-t294-build` -> passou com permissao elevada por sync em `~/.local/bin`/`~/.config/phenom`.

Risco residual:

- Sem estimativa por tokenizer local; se um endpoint real de `/tokenize` for adotado depois, ele deve preencher tokens por bucket sem substituir os bytes auditados.

## T297 - Expandir tool surface por contratos, nao por lista solta

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: `A1` marcou que o Zig preservou baixo ruido, mas perdeu amplitude operacional. O produto final precisa ferramentas reais sem despejar uma montanha de tools no modelo.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts`; `../phenom-cli-ts/src/tools.ts`; registrars em `../phenom-cli-ts/src/tools/registrars/*`.
- Falha apontada no AUDIT/TASKS: ferramentas existiam, mas exposicao e naming podiam ser ruidosos; ferramenta nao anunciada nunca pode executar.
- O que sera preservado do TS: leitura, filesystem, mutation, validation, runtime/browser, git, session, memory e news como capacidades reais.
- O que sera corrigido no Zig: capacidades entram por contrato model-visible pequeno e executor interno fechado.
- O que nao sera portado agora e por que: cada familia entra por task propria; esta task define matriz e allowlist dinamica.
- Invariantes afetadas: 1, 2, 3, 4, 5, 6, 7.
- Teste unitario obrigatorio: para cada contrato, tools permitidas executam e tools fora do contrato sao rejeitadas antes do executor.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, modelo deve escolher contrato e nao conseguir chamar tool nao anunciada.
- Revisao baixo nivel Zig antes do commit: enum/allowlist exaustivos, parser bounds, audit de rejeicao, sem string compare solto espalhado.

Passos de implementacao:

1. Definir familias: `code_read`, `code_mutation`, `validation`, `runtime_browser`, `git`, `session_memory`, `news`.
2. Mapear cada familia para tools internas e model-visible.
3. Expor apenas contrato atual por turno.
4. Auditar manifest anunciado e chamadas rejeitadas.
5. Criar testes de nao execucao para toda tool nao anunciada.

Criterio de aceite:

- O agente recupera amplitude do TS sem voltar a prompt/tool surface gigante.
- Tool interna nunca executa por acidente.

Implementacao concluida:

- Contratos ativos controlam allowlist dinamica: inicial/coleta, `mutate_file`, `validate_work`, `inspect_runtime`, `memory` e perfis nao-code.
- `apply_patch` continua oculto ate `mutate_file`; `validate_syntax` continua oculto ate `validate_work`; `promote_context` continua oculto ate `memory`.
- Tools internas sao verificadas por `contracts.activeContract(...).allows(...)` antes do executor.
- Rejeicoes, selecao de contrato e tools anunciadas ficam auditaveis.

Limite residual:

- Familias news/browser/runtime/git completas continuam em tasks proprias; `inspect_runtime` hoje retorna indisponibilidade operacional auditavel quando nao ha executor real.

Validacao executada:

- `zig test src/contracts.zig` -> passou.
- `zig test src/tool_envelope.zig` -> passou.
- `zig test src/product_guardrails.zig -lc -lsqlite3` -> passou.
- Smoke ambiguo real/fake `guardrail-flow-final` provou que `apply_patch` so executou apos contrato `mutate_file` e `validate_syntax` so executou na fase de validacao.

## T298 - Medir qualidade de ranking/refinamento sem heuristica de dominio

Status: implemented-verified-real.

Prioridade: urgente.

Motivacao: `A4` mostra que o ranking Zig usa fontes objetivas, mas ainda nao prova qualidade suficiente. A regra de negocio proibe vies hardcoded; portanto qualidade deve vir de candidatos, refinamento model-driven e audit.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/tools/registrars/context-tools.ts` em combinacao de RAG/lexical/scope/validation/merge/selection.
- Falha apontada no AUDIT/TASKS: evidencia insuficiente e falso positivo quebram groundedness; o agente nao deve adivinhar pelo prompt.
- O que sera preservado do TS: coleta multi-fonte atras de `collect_evidence`, candidatos e selecao/refinamento.
- O que sera corrigido no Zig: sem stopwords, sem lista de paths preferidos, sem source>docs hardcoded; modelo escolhe refinamento.
- O que nao sera portado agora e por que: embeddings nao entram; decisao atual e `rg`, FTS5/BM25, AST/LSP e contratos.
- Invariantes afetadas: 2, 5, 6, 7.
- Teste unitario obrigatorio: ranking usa somente sinais estruturais/lexicais fornecidos por tool/model; nenhum filtro de linguagem/ecossistema aparece.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, pergunta ambigua deve retornar candidatos, modelo refinar com `selectedCandidates` e resposta citar E#.
- Revisao baixo nivel Zig antes do commit: limites de candidatos, merge de ranges, dedupe, ownership de excerpts, audit de score sem raw.

Passos de implementacao:

1. Criar metricas auditadas: candidate_count, selected_count, coverage, strategy_mix, dropped_by_budget.
2. Implementar `stage=candidates` sem snippets grandes.
3. Implementar `stage=minimum` com `selectedCandidates`.
4. Permitir refinamento ate budget/qualidade, nao numero fixo arbitrario.
5. Validar ausencia de heuristica hardcoded via grep/check.

Criterio de aceite:

- Pergunta ambigua melhora por iteracao do modelo, nao por adivinhacao do agente.
- O audit explica por que uma evidencia foi escolhida ou descartada.

Implementacao em 2026-07-10:

- `phenom-zig/src/tool_call.zig`: `collect_evidence` parseia `stage` e `selectedCandidate`/`selected_candidate`.
- `phenom-zig/src/collect_evidence.zig`: `stage=candidates` retorna `[CANDIDATES]` temporario, sem `[EVIDENCE]`/`[MICRO_CONTEXT]`; `stage=expand` expande um C# para E# real.
- `phenom-zig/src/model_context.zig`: C# entra em `[CANDIDATES_CONTEXT]`, separado de E#, impedindo candidato temporario virar evidencia final.
- `phenom-zig/src/main.zig`: tool loop suporta candidates -> expand, reparo quando falta `selectedCandidate`, dedupe por budget e parsing de tool call escondido em `<think>`.
- `phenom-zig/src/context_profile.zig`: schema por estado agora anuncia candidates/expand e remove placeholder perigoso que o modelo copiava como termo.
- `phenom-zig/src/main.zig`: valida placeholders de schema (`specific retrieval keys`, `SymbolName FileName ErrorCode`, etc.) como erro de contrato antes de executar busca.
- `phenom-zig/src/evidence_ranker.zig`: merge nao funde `symbol_ast` com path/FTS quando isso desloca a linha real da definicao.
- `phenom-zig/src/symbol_ranker.zig`: ranking definitions-first usa sinais estruturais, sem lista de paths/linguagens/stacks: aliases de import nao viram candidatos, matching aproximado e por especificidade, top-level ganha peso sobre metodos internos.
- `phenom-zig/src/collect_evidence.zig`: C# de simbolo le a assinatura no range real do simbolo, inclusive apos L512, sem fallback para cabecalho do arquivo.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/symbol_ranker.zig` -> passou; 5 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc -lsqlite3` -> passou; 25 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/collect_evidence.zig -lc -lsqlite3` -> passou; 56 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 221 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-definition-candidates-test test` -> passou.
- Smoke real final: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 4200 --session definition-first-render-20260710p --prompt 'qual e a funcao que e responsavel por renderizacao do cli no projeto ?' --fail-on-model-error --no-color` -> passou; `stage=candidates` retornou C1 `src/render.zig L18-L65 pub fn AppendOnlyRenderer`, `stage=expand selectedCandidate=C1` gerou E1 e a resposta final citou `AppendOnlyRenderer`.

## T299 - Robustecer HTTP/backend/model protocol com classificacao de falhas

Status: pending-urgent.

Prioridade: urgente.

Motivacao: `A8` marcou HTTP local como bom cliente streaming, mas parcial para agente produtivo multi-backend. Falha de backend, formato, thinking e native tools nao pode parecer erro do modelo.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: `../phenom-cli-ts/src/agent.ts` em resolucao de formato de chat, mock/backend real e schemaBaselineTokens.
- Falha apontada no AUDIT/TASKS: falha de modelo nao pode parecer infraestrutura; prompt/context deve respeitar backend real.
- O que sera preservado do TS: resolucao por turno de backend/formato e separacao mock/real.
- O que sera corrigido no Zig: probe robusto, erro tipado, contexto/n_ctx auditado quando disponivel e streaming tolerante a formatos suportados.
- O que nao sera portado agora e por que: DNS/restricao de familia de rede nao e prioridade atual; ja foi explicitamente deixado fora.
- Invariantes afetadas: 2, 6, 7.
- Teste unitario obrigatorio: parser separa erro HTTP, erro JSON/protocolo, erro de modelo, EOF dentro de think e resposta vazia.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, Ollama e llama.cpp locais devem registrar endpoint, formato, thinking mode e erro classificado.
- Revisao baixo nivel Zig antes do commit: socket close, partial read, buffer bounds, JSON streaming, sem ponteiro para host temporario.

Passos de implementacao:

1. Auditar backend, endpoint, formato, thinking mode e max tokens por turno.
2. Tipar falhas `connect`, `http_status`, `protocol_parse`, `model_empty`, `model_think_only`, `stream_timeout`.
3. Provar que `--prompt` nunca cai em resposta offline enganosa.
4. Preparar campo para native tool capability sem expor antes de executor real.
5. Registrar n_ctx/schema baseline quando backend fornecer.

Criterio de aceite:

- O usuario sabe se a falha foi modelo, protocolo, ferramenta ou infraestrutura.
- O agente nao responde `ok` sem processamento real quando backend deveria ser usado.

## T300 - Definir checklist final de alinhamento e confiabilidade do produto

Status: implemented-verified.

Prioridade: urgente.

Motivacao: `alinhamento.md` define criterios objetivos para dizer "alinhado". Eles precisam existir como checklist executavel, nao conclusao solta.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: todos os fluxos TS citados em `alinhamento.md`; suites reais em `../phenom-cli-ts/src/tests/*`.
- Falha apontada no AUDIT/TASKS: smokes podem passar por marcador final sem provar comportamento do agente.
- O que sera preservado do TS: testes reais opt-in e comportamento operacional completo.
- O que sera corrigido no Zig: relatorio final cruza criterio, SQLite e transcript.
- O que nao sera portado agora e por que: nenhum criterio sera removido; implementacao pode ser incremental, mas checklist deve existir completo.
- Invariantes afetadas: todas.
- Teste unitario obrigatorio: checklist falha quando qualquer criterio obrigatório nao tem evidencia registrada.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, suite real deve validar cada criterio com SQLite.
- Revisao baixo nivel Zig antes do commit: runner sem destrutividade, paths temporarios, cleanup, exit codes confiaveis.

Passos de implementacao:

1. Criar checklist dos criterios finais do `alinhamento.md`.
2. Ligar cada criterio a query SQLite/teste/snapshot.
3. Produzir relatorio por turno: prompt, modelo, contrato, tools anunciadas, calls, resultados, contexto enviado e resposta final.
4. Falhar se qualquer criterio estiver sem prova.
5. Registrar no `TASKS.md` os comandos reais usados.

Criterio de aceite:

- O projeto so pode ser chamado alinhado quando todos os criterios tiverem prova.
- O relatorio diferencia "nao implementado", "implementado sem prova" e "provado".

Implementacao concluida:

- `src/product_guardrails.zig` define checklist executavel `[PRODUCT_GUARDRAILS v1]`.
- Cada criterio final coberto aponta evidencia concreta: contrato model-driven, tool surface por contrato, raw leak, MEMORY/SKILLS separados, profiles de contexto e patch/validation.
- `tools/check_product_guardrails.sh` roda o gate documental, testes de contratos, perfis, contexto, memoria persistente, patch, evidencia e guardrails.
- O checklist falha se aparecer marker bruto no contexto renderizado.

Limite residual:

- O relatorio ainda e checklist/test suite local, nao um renderer completo de transcript por turno. A prova SQLite de fluxo real foi executada manualmente no smoke `guardrail-flow-final`.

Validacao executada:

- `sh ../tools/check_alignment_tasks.sh` -> passou.
- `sh tools/check_product_guardrails.sh` -> passou.
- `zig build --cache-dir /tmp/phenom-zig-final-guardrails-build-test test` -> passou com permissao elevada por sync em `~/.local/bin`/`~/.config/phenom`.
- SQLite do smoke `guardrail-flow-final` confirmou `contract_selected`, `tool_start`, `tool_event`, `evidence`, `patch_result`, `validation`, `expectation_passed` e `turn_done status=ok quality=confirmed`.

## T301 - Preservar explicitamente os acertos do Zig durante o realinhamento

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o `alinhamento.md` lista acertos do Zig que nao podem ser perdidos ao portar amplitude do TS. Reintroduzir features do TS sem preservar esses acertos recria a regressao original.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Referencia TS consultada: comparativo geral do `alinhamento.md`; o objetivo e preservar melhorias Zig enquanto porta acertos TS.
- Falha apontada no AUDIT/TASKS: refatoracao anterior inchou prompt/contexto e misturou storage/memoria/tools.
- O que sera preservado do TS: amplitude operacional e comportamento provado.
- O que sera corrigido no Zig: manter binario baixo nivel, TUI previsivel, SQLite auditavel, contexto destilado e ownership seguro.
- O que nao sera portado agora e por que: nenhum acerto sera removido; esta task cria guardrails.
- Invariantes afetadas: todas.
- Teste unitario obrigatorio: regressao que prova sem raw context, tools internas escondidas, config merge preservado, inventory sem vies e ownership/bounds.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: sim, suite real deve continuar provando tool gate, raw leak zero e audit/replay.
- Revisao baixo nivel Zig antes do commit: toda feature nova precisa passar por checklist de ownership/bounds/raw leak/tool gate.

Passos de implementacao:

1. Criar lista de acertos preservados como assertions de produto.
2. Ligar cada assertion a teste/unit/smoke existente ou novo.
3. Bloquear regressao de config merge, TUI append-only, raw leak, tool gate e inventario sem vies.
4. Exigir review baixo nivel documentada em TASKS para cada task implementada.

Criterio de aceite:

- Portar acerto do TS nao pode remover acerto do Zig.
- Regressao de qualquer acerto listado no `alinhamento.md` falha teste ou checklist.

Implementacao concluida:

- `src/product_guardrails.zig` registra assertions preservadas: terminal append-only, SQLite auditavel, raw context nao model-visible, tool gate antes do executor, config merge preservador e ranking sem vies de dominio.
- Guardrails unitarios provam que tools internas seguem ocultas, profiles nao-code nao usam schema de codigo e MEMORY/SKILLS so entram como blocos persistentes explicitos.
- `tools/check_product_guardrails.sh` centraliza a regressao minima desses acertos.

Validacao executada:

- `zig test src/product_guardrails.zig -lc -lsqlite3` -> passou.
- `sh tools/check_product_guardrails.sh` -> passou.
- `zig build --cache-dir /tmp/phenom-zig-final-guardrails-build-test test` -> passou.

## T302 - Sincronizar build padrao com binario global

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o usuario reportou regressao operacional real: ao iniciar build do projeto, `zig-out/bin/phenom` recebia as features novas, mas o executavel global em `~/.local/bin/phenom` permanecia antigo. Isso fazia `phenom chat` global executar codigo obsoleto e mascarar validacoes.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Falha apontada: build local e binario operacional divergentes.
- O que sera preservado: `install-local` continua existindo e tambem faz merge preservador de `config.toml`.
- O que foi corrigido no Zig: o step padrao de install agora depende da copia para `~/.local/bin/phenom`; `run`, smokes reais e `test` tambem passam pelo mesmo binario atualizado.
- Invariantes afetadas: validacao real deve executar o binario recem-buildado; config do usuario nao pode ser sobrescrito.
- Smoke real obrigatorio, se envolver modelo/servidor/tool loop: nao; mudanca e de grafo de build/instalacao.
- Revisao baixo nivel Zig antes do commit: sem ponteiros/slices novos; risco principal era ciclo no grafo de build. Evitado fazendo o comando global depender do `addInstallArtifact`, nao do install step completo.

Implementacao:

- `phenom-zig/build.zig`: troca `b.installArtifact(exe)` por `addInstallArtifact` explicito.
- `phenom-zig/build.zig`: copia global usa `exe.getEmittedBin()` como fonte, nao string fixa `zig-out/bin/phenom`.
- `phenom-zig/build.zig`: `b.getInstallStep()` depende da copia global.
- `phenom-zig/build.zig`: `zig build test` tambem depende da copia global, para impedir teste contra fonte nova e CLI global antiga.

Criterio de aceite:

- `zig build test` passa e atualiza `~/.local/bin/phenom`.
- `zig build -Doptimize=ReleaseFast` passa e deixa `zig-out/bin/phenom` e `~/.local/bin/phenom` com mesmo checksum.
- `zig build install-local -Doptimize=ReleaseFast` continua passando.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-build-local-sync-test test` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-build-local-sync-release -Doptimize=ReleaseFast` -> passou.
- `sha256sum zig-out/bin/phenom "$HOME/.local/bin/phenom"` -> ambos retornaram `3b54ba443a3adba0f60d09f41d816f42699bdb6f961cc931fd02fd6efc5b1ced`.
- `./zig-out/bin/phenom version` e `"$HOME/.local/bin/phenom" version` -> ambos retornaram `phenom-zig 0.2.0-dev`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-build-local-sync-install install-local -Doptimize=ReleaseFast` -> passou.

## T303 - Corrigir recuperacao util de memoria de sessao no micro-contexto

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o usuario mostrou log onde a pergunta ambigua `voce lembra do estavamos conversando ?` acionava `search_session`, mas o modelo recebia S# de tentativas antigas ruins e respondia que nao tinha contexto suficiente. A falha nao era simplesmente do modelo: o agente entregava um contexto operacional fraco.

Causa raiz:

- `SESSION_FOCUS` novo substituia o fallback de topicos legados quando existia qualquer linha em `session_focus`.
- Como `session_focus` ainda era recente e raso, ele continha so prompts como `ola`, `ika`, `o que este projeto implementa?` e a propria pergunta de memoria, escondendo topicos antigos relevantes.
- Apos `search_session`, o segundo passe do modelo recebia `SESSION_CONTEXT`, mas perdia `SESSION_FOCUS`; se a busca generica retornasse S# ruim, o modelo nao tinha mapa operacional para emitir uma busca mais especifica.
- `search_session` renderizava turnos marcados por metadado como `low_confidence=true`/`refusal=true` quando eles apareciam em hits FTS. Isso deixava respostas ruins entrarem como evidencia de sessao.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Nao foi adicionada heuristica linguistica hardcoded.
- O modelo continua escolhendo termos de busca; o controller so executa contratos e filtra por metadado operacional.
- `SESSION_FOCUS` permanece `not_evidence=true`; claims exatos ainda precisam citar S#.
- O micro-contexto continua temporario e nao vira memoria permanente do modelo.

Implementacao:

- `phenom-zig/src/session_context.zig`: adiciona merge entre foco armazenado e fallback compacto de turnos.
- `phenom-zig/src/session_context.zig`: `renderSearchHits` descarta hits cujo turno tem `turn_done` com metadado de falha/baixa confianca/refusal.
- `phenom-zig/src/main.zig`: `buildInitialModelContext` sempre combina `session_focus` com fallback de topicos legados.
- `phenom-zig/src/main.zig`: contexto pos-`search_session` conserva `SESSION_FOCUS`, permitindo busca corretiva model-directed quando S# inicial e fraco.
- `phenom-zig/src/context_profile.zig` e `phenom-zig/src/main.zig`: contrato model-visible de `search_session` agora explica que `terms` sao chaves de recuperacao especificas escolhidas pelo modelo: nomes, entidades, simbolos, paths, erros, decisoes ou topicos exatos do `SESSION_FOCUS`/raciocinio atual, nao a frase vaga do usuario.

Limite residual:

- Eventos muito antigos gravados antes de `turn_quality` podem nao ter metadado suficiente para classificacao automatica sem ler semantica do texto. A correcao evita novas contaminacoes por metadado e da ao modelo foco suficiente para busca corretiva.

Criterio de aceite:

- Pergunta ambigua de memoria recebe `SESSION_FOCUS` completo o bastante para o modelo escolher termos melhores.
- `search_session` nao renderiza turnos marcados como baixa confianca/refusal.
- O pos-busca preserva `SESSION_FOCUS` sem promover foco a evidencia.
- Smoke real com a pergunta do log recupera assunto real da sessao.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/session_context.zig -lc -lsqlite3` -> passou; 83 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/context_profile.zig` -> passou; 2 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 204 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-session-memory-fix-3 test` -> passou.
- Smoke real antes do ajuste pos-busca ainda falhou no comportamento: buscou `terms=estavamos conversando` e recuperou tentativas antigas ruins.
- Smoke real final: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 1200 --session default --prompt 'voce lembra do estavamos conversando ?' --fail-on-model-error --no-color` -> passou no comportamento; modelo chamou `search_session` com `terms=matheus bíblia`, recuperou S# sobre `qual a matematica perfeita de Matheus 1 na biblia` e respondeu lembrando o assunto.
- Smoke real posterior ao reforco de prompt respondeu corretamente por continuidade recente, sem nova tool call; portanto nao foi usado como prova de busca, apenas confirmou que o contexto registrado contem a nova instrucao de termos especificos.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-session-memory-release -Doptimize=ReleaseFast` -> passou.

## T304 - Separar intencao de busca e termos em `search_session`

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o usuario apontou falha real no log: `search_session` estava usando `terms=assuntos topicos subtopicos conversand`, que e so a query do usuario reembalada. Isso nao representa intencao de pesquisa. Para o agente funcionar bem, o modelo precisa formular o que quer recuperar e so entao escolher chaves pesquisaveis, como uma lupa de navegador com plano operacional.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Nao foi adicionada heuristica hardcoded por assunto, linguagem, stack ou dominio.
- O modelo continua sendo o cerebro da busca: ele define `intent` e `terms`.
- O controller nao adivinha termos; ele executa o contrato, audita `intent` e usa apenas `terms` no FTS.
- `SESSION_FOCUS` continua sendo mapa operacional `not_evidence=true`, nao fonte de claims finais.

Implementacao:

- `phenom-zig/src/tool_call.zig`: `ToolCall` ganhou `intent`, owned/deinit e parser XML.
- `phenom-zig/src/context_profile.zig`: schema de `search_session` virou `search_session(intent?, terms, scope=current|all, session?)`.
- `phenom-zig/src/context_profile.zig`: o contrato explica que `intent` e a evidencia que o modelo quer recuperar; `terms` sao apenas chaves especificas para esse intent.
- `phenom-zig/src/main.zig`: `NEXT_ACTION` e grounding reforcam a separacao `intent -> retrieval keys`.
- `phenom-zig/src/main.zig`: audit de `tool_start search_session` registra `intent=... terms=...`, mas dedupe e FTS continuam baseados em `terms`.
- `phenom-zig/src/main.zig`: se o contexto inicial exige tool de contexto e o modelo responde prosa, o buffer e descartado e o agente emite um reparo de protocolo antes de mostrar a resposta ao usuario.
- `phenom-zig/src/main.zig`: turnos futuros que ignorarem uma tool obrigatoria passam a ser `quality=uncertain` com `context_tool_missing=true low_confidence=true`, evitando contaminar `SESSION_FOCUS` confirmado.

Limite residual:

- Eventos antigos ja persistidos com respostas contaminadas podem continuar aparecendo ate serem superados por novos turnos com metadado correto. Nao foi feita migracao manual do banco local para evitar mutacao destrutiva de historico do usuario.

Criterio de aceite:

- `search_session` aceita e audita `intent`.
- O prompt nao instrui o modelo a copiar a query do usuario como termos.
- Se o modelo ignorar a obrigacao de tool, a prosa inicial nao e renderizada como resposta final.
- Novas respostas sem tool obrigatoria nao entram como foco confirmado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig` -> passou; 16 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/context_profile.zig` -> passou; 2 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 207 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-session-intent-search-3 test` -> passou.
- Smoke real: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 1600 --session default --prompt 'quais sao os assuntos por topicos e subtopicos que estavamos conversando' --fail-on-model-error --no-color` -> passou no fluxo: a prosa inicial foi reparada, `search_session` executou e os termos passaram a ser chaves de conteudo (`phenom`, `zig`, `c`, `llama`, `ollama`, `Mateus`/genealogia etc.), nao a query literal `assuntos topicos subtopicos`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-release ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-session-intent-release -Doptimize=ReleaseFast` -> passou.

## T305 - Separar intencao de busca e termos em `collect_evidence`

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o usuario mostrou log onde a pergunta `qual e a funcao que e responsavel por renderizacao do cli no projeto ?` fazia o modelo chamar `collect_evidence(strategy=auto)` sem `intent`, sem `terms` e sem `path`. O controller aceitava isso e o executor caia no overview generico do workspace, geralmente README. Para um agente coder isso viola a regra de negocio: evidencia de codigo precisa ser dirigida pela intencao do modelo, nao por fallback generico nem por inferencia do controller.

Alinhamento AUDIT/TASKS/phenom-cli-ts:

- Nao foi adicionada heuristica linguistica hardcoded, lista de arquivos preferidos, stack preferida ou bias por linguagem.
- O modelo continua sendo o cerebro da coleta: ele define `intent`, `terms`, `path` e `strategy`.
- O controller nao gera termos a partir do prompt do usuario; ele apenas valida protocolo, executa contrato, audita e devolve evidencia destilada.
- O overview do workspace continua existindo no executor para chamadas explicitamente direcionadas a overview, mas o tool loop nao aceita `collect_evidence` pathless sem `intent+terms` como busca de codigo precisa.

Implementacao:

- `phenom-zig/src/context_profile.zig`: contrato de `collect_evidence` virou `collect_evidence(intent?, path?, terms?, strategy=...)`.
- `phenom-zig/src/context_profile.zig`: schema instrui o modelo a separar `intent` de `terms` e a usar `symbol`/`lexical` para perguntas de funcao/tipo/simbolo quando adequado.
- `phenom-zig/src/tool_call.zig`: teste de parser cobre `intent` em `collect_evidence`.
- `phenom-zig/src/main.zig`: `collect_evidence` sem `path` agora exige `intent+terms`; se vier fraco, o loop emite repair de protocolo antes de executar overview implicito.
- `phenom-zig/src/main.zig`: audit de `tool_start collect_evidence` registra `intent_bytes` e `terms_bytes`.
- `phenom-zig/src/collect_evidence.zig`: `Args` ganhou `intent` e o audit do tool event registra `intent_bytes`; ranking continua usando apenas `terms` escolhidos pelo modelo.
- `phenom-zig/src/working_context.zig`: refinamento pos-evidencia agora e limitado por budget, nao por score de ranking. Score alto de match textual nao encerra o loop se o modelo julgar que precisa de outra coleta.
- `phenom-zig/src/main.zig`: contexto pos-`collect_evidence` mantem o contrato ativo enquanto ainda ha budget, permitindo coleta guiada adicional. Sem budget, o schema sai do contexto e o modelo deve responder ou declarar insuficiencia.
- `phenom-zig/src/main.zig`: regras de groundedness exigem que perguntas de identidade de codigo so nomeiem funcao/tipo/arquivo quando o identificador/declaracao/callsite aparecer em E#.

Limite residual:

- `need`, `targetFiles` e `scopeRoot` ainda nao foram portados para o contrato Zig. `stage=candidates` e `stage=expand selectedCandidate=C#` foram implementados na T298.
- O ranking ainda depende de termos do modelo; a correcao nao adiciona heuristica semantica hardcoded no controller. A mitigacao atual e contrato mais estrito, reparo de placeholders, candidates temporarios e expansao obrigatoria para E#.

Criterio de aceite:

- `collect_evidence(auto|symbol|lexical)` sem path precisa trazer `intent+terms` antes de executar.
- `collect_evidence(auto)` vazio nao vira README/overview silencioso em pergunta de codigo.
- Apos evidencia insuficiente, o modelo ainda recebe contrato ativo se houver budget para refinamento.
- Resposta final de pergunta de funcao cita E# contendo o identificador nomeado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/tool_call.zig` -> passou; 16 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/context_profile.zig` -> passou; 2 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 210 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-collect-intent-test test` -> passou com sync global.
- Smoke real: `./zig-out/bin/phenom chat --backend llamacpp --host 192.168.1.122:11434 --model phenom:latest --thinking off --max-tokens 2600 --session collect-render-intent-20260710b --prompt 'qual e a funcao que e responsavel por renderizacao do cli no projeto ?' --fail-on-model-error --no-color` -> passou no comportamento. O primeiro passe usou `intent+terms`; uma coleta ruim retornou `build.zig`, o contexto pos-evidencia manteve contrato ativo, a coleta seguinte retornou `src/render.zig` com `pub fn AppendOnlyRenderer`, e a resposta final citou `AppendOnlyRenderer` em E1.

Atualizacao de economia de contexto em 2026-07-10:

- Causa do custo alto: coleta pathless recebia todo o budget restante do turno; `adaptiveBudget` era aplicado por range e podia gastar quase o budget inteiro no primeiro candidato, multiplicando evidencia model-visible.
- Correcao: coleta pathless passou a usar budget exploratorio curto; `collect_evidence` distribui o budget entre candidatos em vez de consumir tudo no primeiro range.
- Correcao: `strategy=symbol` agora usa FTS/BM25 como corroboracao interna antes do sort/trim final, evitando ficar preso ao primeiro simbolo generico chamado `render`.
- Correcao: contexto inicial com tool loop volta a exigir uma tool de contexto antes da prosa; respostas "nao tenho acesso ao repositorio" sem tool viram repair em vez de resposta final.
- Smoke real comparativo:
  - Antes da otimizacao: `collect-render-intent-20260710b` -> `total_tokens=4177`, `max_context_bytes=7260`, `evidence_bytes=12312`, `tool_calls=2`.
  - Depois da otimizacao: `collect-render-budget-20260710c` -> `total_tokens=2141`, `max_context_bytes=4305`, `evidence_bytes=995`, `tool_calls=1`.
  - Resultado final continuou correto: `AppendOnlyRenderer` em `src/render.zig` citado por E1.

## T306 - Fechar fluxo de contexto por contratos, evidencia v2, memoria e patch seguro

Status: implemented-verified.

Prioridade: urgente.

Motivacao: a revisao cetica apontou que o Zig ja estava bom em `collect_evidence`/`search_session`, mas ainda nao fechava o fluxo de contexto como agente coder: contratos selecionados nao liberavam executores reais, `collect_evidence` ainda nao aceitava todos os campos de direcao do TS, MEMORY/SKILLS so eram lidos, patch nao validava stale context no loop e perfis fora de codigo eram declarados mas nao selecionaveis.

Regra de negocio preservada:

- O modelo escolhe intencao, necessidade, termos, contrato e tool call.
- O controller valida contrato, estado, path, stale context, unicidade do patch e executa.
- O controller nao infere direcao por palavras do prompt do usuario.
- Tool output continua evidencia temporaria; MEMORY/SKILLS so recebem promocao explicita e sanitizada.

Implementacao:

- `phenom-zig/src/contracts.zig`: `mutate_file` libera `apply_patch`; `validate_work` libera `validate_syntax`; `inspect_runtime` libera `inspect_runtime` sem abrir mutation. Testes garantem que contratos nao selecionados nao desbloqueiam outros executores.
- `phenom-zig/src/context_profile.zig`: schemas ativos agora sao por contrato selecionado; `mutate_file` mostra `apply_patch(path, search, replace, contextId?)`; perfis `session`, `news`, `document` e `runtime` sao selecionaveis por estado operacional explicito, nao por prompt.
- `phenom-zig/src/tool_call.zig`: parser aceita `need`, `targetFiles`, `scopeRoot`, `selectedCandidates`, `contextId`, `search` e `replace`.
- `phenom-zig/src/collect_evidence.zig`: `Args` aceita `need`, `target_files` e `scope_root`; esses campos entram nos termos de ranking declarados pelo modelo. `intent` continua fora do ranking, servindo para audit/contrato.
- `phenom-zig/src/main.zig`: `collect_evidence stage=minimum` limita linhas; `stage=expand` aceita `selectedCandidates` plural usando o primeiro C#; pathless collect agora exige `intent` e pelo menos um sinal pesquisavel (`terms`, `need`, `targetFiles` ou `scopeRoot`).
- `phenom-zig/src/apply_patch_tool.zig`: novo executor de patch com `search/replace` exato e unico; se `contextId` existir, recalcula micro-contexto do range coletado e falha com `StaleMicroContext` antes de escrever.
- `phenom-zig/src/main.zig`: loop executa `apply_patch` somente sob contrato `mutate_file`; apos patch troca para contrato de validacao e pede `validate_syntax` quando aplicavel.
- `phenom-zig/src/main.zig`: `validate_syntax` usa parser Zig existente (`diagnostic_runner`) e devolve evidencia destilada; `inspect_runtime` retorna indisponibilidade operacional explicita, sem fingir browser/runtime.
- `phenom-zig/src/persistent_context.zig`: promocao explicita para `MEMORY.md`/`SKILLS.md`, com escrita temporaria+rename, dedupe, limite de bytes e rejeicao de raw markers.
- `phenom-zig/src/working_context.zig`: evidencia ativa pode localizar entrada por `context_id`, permitindo validacao stale antes do patch.

Limite residual:

- `inspect_runtime` ainda nao executa browser/runtime real; ele e um contrato auditavel de indisponibilidade, nao uma implementacao de runtime.
- `apply_patch` deixou de ser o executor minimo de um unico `search/replace`: agora suporta `operation=edit|create|delete|rename`; edit aceita multiplos hunks `search/replace`, create recusa overwrite, delete/rename exigem `contextId` fresco.
- Promocao MEMORY/SKILLS agora tambem esta exposta por contrato `memory` via `promote_context(target=memory|skills,text)`, com audit `persistent_promotion`.
- Perfis `news_doc_log`/`document_summary` existem como selecao e schema operacional, mas news/document executores continuam pendentes. News nao foi portado nesta task.

Criterio de aceite:

- Contrato inicial nao permite `apply_patch`.
- `mutate_file` permite `apply_patch`, mas nao `validate_syntax` nem runtime.
- `validate_work` permite `validate_syntax`, mas nao `apply_patch`.
- `collect_evidence` aceita campos v2 sem usar prompt do usuario como fallback semantico.
- Patch com `contextId` stale falha antes de escrever.
- MEMORY/SKILLS recusam raw tool output e deduplicam entradas.
- Perfis nao-code sao selecionados por input operacional explicito.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-context-flow-test-main` -> passou; 233 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-context-flow-test test` -> passou com permissao elevada porque o target depende de `install-local` e escreve em `~/.local/bin`/`~/.config/phenom`.

Validacao adicional do fluxo real do agente em 2026-07-12:

- Correcao pos-teste: `collect_evidence` gerava `micro_context_text`, mas o loop entregava ao modelo apenas `[EVIDENCE]`. Isso impedia o modelo de usar `contextId` em `apply_patch`. `phenom-zig/src/main.zig` agora junta `[EVIDENCE]` e `[MICRO_CONTEXT]` no contexto/tool result model-visible.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-real-flow-contextid-test` -> passou; 234 testes.
- Backend real LAN indisponivel neste momento: `curl --max-time 5 -v http://192.168.1.122:11434/` -> timeout; `phenom probe --backend llamacpp --host 127.0.0.1:11434` com rede liberada -> `ConnectFailed`.
- Smoke end-to-end com binario real e backend HTTP fake deterministico em `/tmp/phenom-real-flow-agent`: `phenom chat --backend llamacpp --host 127.0.0.1:18080 --model fake --thinking off --max-tokens 1600 --session real-flow-fake-306c --prompt 'Corrija src/math.zig ... PHENOM_REAL_FLOW_306' --expect-contains PHENOM_REAL_FLOW_306 --show-expect-status --fail-on-model-error --no-color` -> passou.
- O transcript do smoke mostrou `set_operational_contract: mutate_file`, `collect_evidence: src/math.zig` com `[MICRO_CONTEXT id=ctx_075f6626282308d7 ...]`, `apply_patch` com `status=applied stale_checked=true`, `validate_syntax` com `status=ok parser=zig errors=0` e resposta final `PHENOM_REAL_FLOW_306`.
- Arquivo corrigido pelo agente no fixture: `/tmp/phenom-real-flow-agent/src/math.zig` passou de `return a - b;` para `return a + b;`.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/phenom-zig-real-flow-build-test test` -> passou com permissao elevada.

Validacao adicional em 2026-07-15:

- `zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-main-memory-quality-test` -> passou; 242 testes.
- `sh tools/check_product_guardrails.sh` -> passou.
- Smoke MEMORY/SKILLS com backend HTTP fake deterministico em fixture temporario -> passou; `SKILLS.md` foi criado/atualizado, `persistent_promotion` foi auditado e `turn_done` registrou `quality=confirmed used_persistent_context=true context_tool_missing=false`.
- Smoke ambiguo de patch/validacao com backend HTTP fake deterministico em `/tmp/phenom-guardrail-flow-YwSzPH`: `phenom chat --backend llamacpp --host 127.0.0.1:18081 --model fake --thinking off --max-tokens 1600 --session guardrail-flow-final --prompt 'tem uma conta pequena quebrada nesse projeto; arruma do jeito certo, valida e no final escreve PHENOM_GUARDRAIL_FLOW' --expect-contains PHENOM_GUARDRAIL_FLOW --show-expect-status --fail-on-model-error --no-color` -> passou.
- Arquivo do fixture terminou com `return a + b;`.
- SQLite do smoke `guardrail-flow-final` registrou `contract_selected`, `collect_evidence`, `apply_patch`, `validate_syntax`, `expectation_passed` e `turn_done status=ok quality=confirmed`.

Validacao adicional em 2026-07-15 para patch expandido:

- `zig test src/tool_call.zig` -> passou; parser cobre `operation`, `destinationPath`, `content`, `contextId` repetido e hunks repetidos.
- `zig test src/apply_patch_tool.zig -lc -lsqlite3` -> passou; 83 testes, incluindo multi-hunk atomico por posicoes originais, falha sem escrita quando um hunk invalida, create sem overwrite, delete com contexto fresco e rename com destino inexistente.
- `zig test src/context_profile.zig` -> passou; schema de mutation anuncia operacoes sem abrir nova tool surface.
- `zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-zig-main-expanded-patch-test` -> passou; 248 testes.
- `sh tools/check_product_guardrails.sh` -> passou.
- `zig build --cache-dir /tmp/phenom-zig-expanded-patch-build` -> passou com permissao elevada para sync em `~/.local/bin`/`~/.config/phenom`.
- Smoke CLI end-to-end com backend HTTP fake local corrigido para JSON compacto (`"content":"..."`, sem espaco que o parser atual nao aceita): `phenom chat --backend llamacpp --host 127.0.0.1:18082 --model fake --thinking off --max-tokens 2000 --session expanded-patch-flow --prompt 'tem umas contas pequenas invertidas nesse projeto; arruma com cuidado, valida e no final escreve PHENOM_EXPANDED_PATCH' --expect-contains PHENOM_EXPANDED_PATCH --show-expect-status --fail-on-model-error --no-color` -> passou.
- O fluxo real executou `set_operational_contract`, `collect_evidence`, `apply_patch operation=edit hunks=2 stale_checked=true`, `validate_syntax status=ok` e resposta final com `PHENOM_EXPANDED_PATCH`.
- Arquivo do fixture terminou com `add -> return a + b;` e `sub -> return a - b;`.
- SQLite do smoke registrou `contract_selected`, `tool_start apply_patch operation=edit`, `patch_result hunks=2`, `validation`, `expectation_passed` e `turn_done status=ok quality=confirmed context_tool_missing=false`.

## T307 - Diagnosticar `HttpStatusNotOk` com status e corpo do backend

Status: implemented-verified.

Prioridade: urgente.

Motivacao: em uso real com `inference.local:11434`, a falha `model connection failed: HttpStatusNotOk endpoint=...` escondia o motivo retornado pelo servidor. Isso violava a invariante 6: falha de modelo nao pode parecer falha generica de infraestrutura. O usuario precisava saber se era backend errado, endpoint errado, payload rejeitado ou servidor indisponivel.

Regra de negocio preservada:

- Nao foi adicionada heuristica por prompt.
- O backend continua definido por contrato/config: `ollama` usa `/api/chat`; `llamacpp` usa `/completion`.
- O controller apenas captura diagnostico de protocolo HTTP: status e corpo curto da resposta nao-2xx.

Implementacao:

- `phenom-zig/src/http.zig`: `LocalModelClient` guarda `last_http_status` e `last_http_body_snippet` quando a resposta HTTP nao e 2xx.
- `phenom-zig/src/http.zig`: corpo de erro e limitado a 512 bytes e sanitizado para uma linha segura.
- `phenom-zig/src/main.zig`: mensagem `model connection failed` inclui `status=N body="..."` quando o backend retornou resposta HTTP valida de erro.
- `phenom-zig/src/main.zig`: `LocalModelClient.deinit()` libera o snippet guardado.

Limite residual:

- `--fail-on-model-error` ainda retorna o erro Zig cru para automacao/CI; a mensagem detalhada e emitida no fluxo normal.
- `thinking=on` com `phenom:latest` ainda pode causar erro de protocolo de tool loop em prompts simples; isso e falha separada de comportamento do modelo/tool loop, nao `HttpStatusNotOk`.

Criterio de aceite:

- Backend errado contra llama.cpp mostra `status=404` e corpo `File Not Found`.
- Backend correto `llamacpp` conversa com `inference.local:11434`.
- `probe` confirma `server llama.cpp` sem chamar inferencia.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/http.zig` -> passou; 30 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 283 testes.
- `bash tools/check_product_guardrails.sh` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- `./zig-out/bin/phenom probe --backend llamacpp --host inference.local:11434` com rede liberada -> `tcp success`, `http success status=200`, `server llama.cpp`.
- `./zig-out/bin/phenom chat --backend llamacpp --host inference.local:11434 --model phenom:latest --thinking off --max-tokens 32 --prompt 'responda somente: ok' --fail-on-model-error --no-color` -> passou; resposta `ok`.
- Smoke de diagnostico forçado: `./zig-out/bin/phenom chat --backend ollama --host inference.local:11434 --model phenom:latest --thinking off --max-tokens 32 --prompt 'responda somente: ok' --no-color` -> mostrou `model connection failed: HttpStatusNotOk endpoint=http://inference.local:11434/api/chat status=404 body="...File Not Found..."`.

## T308 - Garantir UTF-8 valido no JSON enviado ao backend

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o servidor llama.cpp retornou `status=500` com `[json.exception.parse_error.101] ... invalid string: ill-formed UTF-8 byte` ao receber `/completion`. A causa estava na fronteira HTTP: `jsonEscape` escapava aspas/controles, mas preservava bytes malformados vindos de prompt, contexto de turno ou historico de sessao. JSON enviado ao backend precisa ser UTF-8 valido sempre.

Regra de negocio preservada:

- Nao foi adicionada heuristica por prompt.
- A correcao fica na camada de transporte/serializacao JSON.
- O conteudo malformado nao quebra a chamada; bytes invalidos viram `\uFFFD`.

Implementacao:

- `phenom-zig/src/http.zig`: `jsonEscape` agora valida sequencias UTF-8 multibyte antes de copiar para o JSON.
- `phenom-zig/src/http.zig`: bytes UTF-8 invalidos, truncados ou com continuação invalida viram `\uFFFD`.
- `phenom-zig/src/http.zig`: controles abaixo de `0x20` que nao sejam `\n`, `\r` ou `\t` viram escape JSON `\u00XX`.

Criterio de aceite:

- `jsonEscape("ok\xfffim")` retorna `ok\uFFFDfim`.
- Body llama.cpp com contexto contendo byte invalido continua sendo UTF-8 valido.
- Smoke real com `/completion` nao retorna mais parse error UTF-8 para o prompt observado.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/http.zig` -> passou; 32 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 285 testes.
- `bash tools/check_product_guardrails.sh` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- `~/.local/bin/phenom chat --backend llamacpp --host inference.local:11434 --model phenom:latest --thinking off --max-tokens 64 --prompt 'olola' --fail-on-model-error --no-color` -> passou; resposta visivel sem `HttpStatusNotOk`.

## T309 - Separar overview estrutural de selecao C# no reparo de evidencia

Status: implemented-verified.

Prioridade: urgente.

Motivacao: o fluxo real ainda podia responder perguntas amplas de workspace com evidencia local ruim. O log observado mostrava `collect_evidence stage=candidates`, o modelo falhava em emitir `stage=expand` visivel depois do repair, e o controller terminava com `[MODEL_PROTOCOL_ERROR] required follow-up tool_call missing after repair; no final evidence was selected`. Apos a primeira correcao, o erro de protocolo sumiu, mas o smoke real ainda mostrou resposta mediocre: o fallback expandia C# local de `evidence_ranker`, `workspace_inventory` ou `model_context` e o modelo tratava esse fragmento como se representasse o projeto inteiro.

Regra de negocio preservada:

- Nao foi adicionada classificacao por palavras do prompt do usuario.
- `stage=overview` e uma opcao model-visible do contrato `collect_evidence`, nao uma tool nova.
- `stage=candidates -> stage=expand` continua sendo o fluxo correto para identidade de funcao, tipo, simbolo ou arquivo.
- O controller valida protocolo e qualidade estrutural dos candidatos: se C# pathless vem espalhado por varios arquivos sem alvo dominante, ele nao e tratado como evidencia de identidade.
- Raw tool output continua fora do contexto model-visible; o modelo recebe apenas `[EVIDENCE]`/`[MICRO_CONTEXT]` destilado.

Implementacao:

- `phenom-zig/src/context_profile.zig`: schema de `collect_evidence` agora anuncia `stage=overview`; instrucoes separam mapa amplo de workspace/projeto de lookup focado e identidade C#.
- `phenom-zig/src/main.zig`: `runCollectEvidenceOverviewStep` executa overview estrutural diretamente via `collect_evidence.execute(strategy=auto)` e devolve E# ao modelo.
- `phenom-zig/src/main.zig`: se uma resposta inicial faz claim de workspace sem evidencia, o repair nao pede outro plano ao modelo; ele coleta overview estrutural minimo primeiro.
- `phenom-zig/src/main.zig`: candidatos pathless difusos sao detectados por distribuicao estrutural de paths. Se nao ha arquivo dominante, o loop converte para overview antes de expor C# como escolha de identidade.
- `phenom-zig/src/main.zig`: falha de selecao C# depois de E# existente nao vira erro de protocolo; o loop pede resposta final com a evidencia existente ou coleta range/overview quando ainda ha rota segura.

Criterio de aceite:

- Pergunta ampla sobre o projeto coleta `stage=overview` e responde com README/E# em vez de C# local.
- `thinking=on` pode gerar tool intent dentro de `<think>` ou tentar `candidates`; o controller ainda entrega evidencia final visivel.
- Candidatos concentrados no mesmo arquivo continuam elegiveis para selecao C#.
- Candidatos espalhados por varios arquivos nao sao usados como prova de identidade.
- O erro `[MODEL_PROTOCOL_ERROR] required follow-up tool_call missing after repair; no final evidence was selected` nao aparece nos smokes reais cobertos.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/context_profile.zig` -> passou; 11 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3` -> passou; 286 testes.
- `bash tools/check_product_guardrails.sh` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- Smoke real `thinking off`: `./zig-out/bin/phenom chat --backend llamacpp --host inference.local:11434 --model phenom:latest --thinking off --max-tokens 900 --session overview-real-off-20260718f --prompt 'o que este projeto implementa?' --fail-on-model-error --no-color` -> passou; audit registrou `tool_repair unsupported workspace claim without evidence`, `tool_start collect_evidence stage=overview`, evidencia `README.md L1-L49` e resposta final correta.
- Smoke real `thinking on`: `./zig-out/bin/phenom chat --backend llamacpp --host inference.local:11434 --model phenom:latest --thinking on --max-tokens 900 --session overview-real-on-20260718f --prompt 'o que este projeto implementa?' --fail-on-model-error --no-color` -> passou; audit registrou `collect_evidence empty search -> candidates_from_task`, `diffuse candidates -> overview`, evidencia `README.md L1-L49` e resposta final correta.

Risco residual:

- Perguntas focadas ainda dependem do modelo fornecer termos uteis ou de candidatos concentrados; esta task evita conclusao ampla baseada em C# difuso, mas nao substitui ranking semantico neural.
- O criterio de dispersao e estrutural e conservador: candidatos concentrados em um arquivo errado ainda podem exigir refinamento posterior do modelo.

## T310 - Implementar caveman code graph estrutural para ranking de evidencia

Status: implemented-verified.

Prioridade: alta.

Motivacao: a coleta de evidencia focada ainda dependia demais de termos lexicais e FTS/BM25. Em perguntas com intencao de fluxo ou funcao, o agente podia devolver trechos concretos mas semanticamente fracos, especialmente quando um simbolo generico ou range adjacente pontuava por path/relacao. A solucao inicial precisa melhorar a estrutura interna sem adicionar dependencia externa, sem hardcode de prompt e sem transformar grafo em contexto bruto model-visible.

Regra de negocio preservada:

- Nao foi adicionada heuristica por pergunta do usuario.
- Nao foi adicionada dependencia Graphify nesta etapa.
- O grafo e implementacao interna do `collect_evidence`; a surface model-visible continua sendo o contrato existente.
- Raw graph/SQLite nao vaza para o prompt; o modelo recebe apenas candidatos/evidencias destiladas.
- `strategy=symbol` continua priorizando identidade simbolica precisa e nao usa caveman graph como atalho.

Passos de implementacao:

1. Criar teste de grafo nativo que indexa workspace, salva nodes/edges em SQLite `:memory:` e ranqueia `executeCandidates`.
2. Criar teste de import Zig local para `@import("audit.zig")`, `@import("./http.zig")` e `@import("../config.zig")`.
3. Implementar `phenom-zig/src/code_graph.zig` com inventario de workspace, extracao simples de simbolos Zig/JS/TS, relacoes diretas de chamada intra-file e imports locais Zig.
4. Integrar `code_graph.rank` em `phenom-zig/src/evidence_ranker.zig` para `strategy=auto|lexical`, depois de `rg` e antes de FTS/BM25.
5. Registrar audit de disponibilidade e tamanho do grafo: `graph_available`, `graph_indexed_files`, `graph_nodes`, `graph_edges`.
6. Marcar candidatos com `source=code_graph` e preview contendo `symbol`, `match=direct|structural`, `indexed_files`, `nodes`, `edges` e `relations`.
7. Corrigir a normalizacao de score para preservar match direto de simbolo acima de vizinho estrutural/import ruidoso.
8. Corrigir o loop de expansao duplicada para responder com E# existente em vez de gerar erro de protocolo quando ja ha evidencia selecionada.
9. Rodar testes unitarios, guardrails, build release e smoke CLI com backend deterministico.

Implementacao:

- `phenom-zig/src/code_graph.zig`: novo grafo caveman em Zig, sem dependencia externa. Usa SQLite em memoria para materializar `nodes` e `edges`, indexa ate 512 arquivos de texto do workspace, extrai simbolos por linhas declarativas e calcula relacoes simples.
- `phenom-zig/src/code_graph.zig`: imports locais Zig sao normalizados sem permitir path absoluto/traversal no output aceito por `workspace_inventory`.
- `phenom-zig/src/code_graph.zig`: candidatos carregam `direct_symbol_match`; vizinhos estruturais entram como suporte, nao como prova primaria.
- `phenom-zig/src/evidence_ranker.zig`: `CandidateSource.code_graph` integrado ao ranking e audit. Score direto pode disputar topo; score estrutural e rebaixado.
- `phenom-zig/src/main.zig`: fallback de expand duplicado usa evidencia existente para resposta final, evitando `[MODEL_PROTOCOL_ERROR]` quando a expansao ja tinha acontecido.

Criterio de aceite:

- `executeCandidates` aparece como candidato do grafo para termos focados.
- Match direto de simbolo fica acima de `deinit`/vizinhos estruturais.
- O grafo aparece no audit como fonte interna, sem expor raw graph ou SQL.
- `collect_evidence` pathless continua respeitando termos/intencao dados pelo modelo e nao inventa estrategia por keyword do prompt.
- Perguntas amplas continuam podendo usar `overview`; caveman graph e suporte para busca focada, nao substituto de overview estrutural.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/code_graph.zig -lc -lsqlite3 --cache-dir /tmp/phenom-caveman-code-graph-test3` -> passou; 10 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/evidence_ranker.zig -lc -lsqlite3 --cache-dir /tmp/phenom-caveman-evidence-ranker-test3` -> passou; 39 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-caveman-main-test3` -> passou; 291 testes.
- `bash tools/check_product_guardrails.sh` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- Smoke CLI com backend llama.cpp fake deterministico em `127.0.0.1:18086`: `./zig-out/bin/phenom chat --backend llamacpp --host 127.0.0.1:18086 --model fake --thinking off --max-tokens 1200 --session caveman-fake-flow-20260718d --prompt 'qual funcao executa os candidatos da coleta de evidencia no projeto?' --expect-contains PHENOM_CAVEMAN_GRAPH --show-expect-status --fail-on-model-error --no-color` -> passou. O transcript mostrou `C1 score=1200 source=code_graph path=src/collect_evidence.zig range=93-140 def: pub fn executeCandidates... preview: code_graph,symbol=executeCandidates,match=direct...` e E1 expandido no range correto.
- Smoke com backend real `inference.local:11434` antes da correcao final de score: o CLI conectou e respondeu sem erro de infraestrutura, mas o modelo escolheu `overview` para uma pergunta focada. Esse resultado fica registrado como limite do comportamento do modelo real, nao como prova do caminho caveman.

Invariantes afetadas:

- 1. Tool nao anunciada nunca executa: preservada; nenhuma tool nova foi adicionada.
- 2. Contexto bruto nao vaza para o modelo: preservada; grafo bruto/SQL ficam internos, somente candidatos/evidencias entram no prompt.
- 6. Falha de modelo nao parece falha de infraestrutura: preservada; o reparo de expand duplicado evita falso erro de protocolo quando ha E#.
- 7. Cada turno consegue ser auditado e reproduzido: ampliada; audit agora registra disponibilidade e tamanho do grafo.

Risco residual:

- O caveman graph nao e tree-sitter, LSP nem embedding neural. Ele cobre simbolos simples, chamadas diretas intra-file e imports Zig locais.
- Nao ha cache persistente do grafo; ele e reconstruido por ranking.
- O modelo real ainda pode escolher `stage=overview` em pergunta focada. Esta task melhora a qualidade quando o contrato pathless/focado chega ao ranker, mas nao muda a decisao autonoma do modelo sobre qual stage chamar.

## T311 - Tornar evidencia duplicada idempotente no estado do tool loop

Status: implemented-verified.

Prioridade: urgente.

Motivacao: em fluxo real o loop podia falhar com `tool loop failed: DuplicateWorkingEvidence` seguido de `[MODEL_PROTOCOL_ERROR] required follow-up tool_call missing after repair; no final evidence was selected`. A causa raiz era uma fronteira errada entre `WorkingContext` e `ToolLoopState`: `WorkingContext.remember` corretamente rejeita duplicata para proteger o store, mas `ToolLoopState.rememberExecutedArgs` propagava essa rejeicao como erro fatal de turno. Para o loop, repetir a mesma evidencia no mesmo turno deve ser idempotente: manter a primeira evidencia, nao duplicar entrada e continuar para resposta/reparo.

Regra de negocio preservada:

- `WorkingContext` continua rejeitando duplicata em sua API baixa.
- O loop nao executa tool nao anunciada e nao adiciona nova surface.
- Nenhuma heuristica por prompt foi adicionada.
- A primeira evidencia coletada continua sendo a fonte preservada; repeticoes nao sobrescrevem texto, `context_id` nem qualidade.

Passos de implementacao:

1. Criar teste em `ToolLoopState` que grava a mesma evidencia duas vezes.
2. Garantir que a segunda chamada nao aumenta `entries.len`.
3. Garantir que a segunda chamada nao sobrescreve `context_id` nem evidencia original.
4. Tratar `error.DuplicateWorkingEvidence` em `ToolLoopState.rememberExecutedArgs` como retorno idempotente.
5. Rodar `main`, guardrails, build release e smoke CLI com coleta duplicada real no loop.

Implementacao:

- `phenom-zig/src/main.zig`: `rememberExecutedArgs` captura `error.DuplicateWorkingEvidence` e retorna sucesso sem mutar o estado.
- `phenom-zig/src/main.zig`: teste `tool loop state treats duplicate working evidence as idempotent`.

Criterio de aceite:

- Duplicata no mesmo turno nao derruba o loop.
- Entrada original continua unica e preservada.
- O erro `DuplicateWorkingEvidence` nao vaza como `tool loop failed`.
- O fluxo ainda consegue emitir resposta final visivel apos repeticao.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-duplicate-working-evidence-main` -> passou; 292 testes.
- `bash tools/check_product_guardrails.sh` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- Smoke CLI com backend llama.cpp fake deterministico em `127.0.0.1:18087`: o backend emitiu `collect_evidence stage=overview` duas vezes no mesmo turno e depois resposta final `PHENOM_DUPLICATE_EVIDENCE_OK`; o comando `./zig-out/bin/phenom chat --backend llamacpp --host 127.0.0.1:18087 --model fake --thinking off --max-tokens 1200 --session duplicate-working-evidence-20260718a --prompt 'force duplicate evidence smoke' --expect-contains PHENOM_DUPLICATE_EVIDENCE_OK --show-expect-status --fail-on-model-error --no-color` -> passou.

Invariantes afetadas:

- 2. Contexto bruto nao vaza para o modelo: preservada; duplicata nao injeta novo bloco bruto.
- 6. Falha de modelo nao parece falha de infraestrutura: corrigida; repeticao de tool/evidencia nao vira erro fatal.
- 7. Cada turno consegue ser auditado e reproduzido: preservada; o smoke registra duas coletas e resposta final.

Risco residual:

- A tool ainda pode executar novamente antes de ser reconhecida como duplicata em rotas que nao fazem precheck. Esta task impede falha fatal e duplicacao de contexto; dedupe antes da execucao dessas rotas pode ser otimizado depois se o custo virar problema.

## T312 - Expor uso de contexto e motivo de corte da geracao no transcript

Status: implemented-verified.

Prioridade: alta.

Motivacao: o CLI nao mostrava no canto direito da statusbar quanto do contexto pre-send estava ocupado e respostas podiam terminar no meio sem explicacao visivel. A causa raiz do corte aparente era que o cliente HTTP reduzia `finish_reason`, `done`, `stop`, `stopped_limit`, `truncated` e limite de tokens a um unico booleano de fim. O renderer entao imprimia `Worked for...` como se fosse parada normal.

Regra de negocio preservada:

- Nao foi adicionada heuristica por prompt.
- O contador de contexto usa bytes reais do `ModelTurnContext` renderizado antes do envio, nao estimativa falsa de tokens.
- O motivo de parada vem de metadados do backend ou do contador final real de output quando disponivel.
- Tool output continua sendo evidencia destilada; somente a renderizacao visual ganhou quebra com gutter.

Passos de implementacao:

1. Criar testes de statusbar para `ctx used/limit` alinhado a direita.
2. Criar teste de renderer para linha longa de tool com gutter em todas as continuacoes.
3. Criar teste HTTP para propagar parada por limite (`stopped_limit`).
4. Integrar `showContextUsage` apos `recordModelContextBudget` nos pontos de inferencia inicial, plano e follow-up.
5. Propagar `CompletionStop` pelo `StreamSink` e pelo sink agregado do tool loop.
6. Emitir `model_stop` e `progress_update` quando a resposta final parar por limite de output.
7. Rodar testes focados, guardrails e build release.

Implementacao:

- `phenom-zig/src/tui.zig`: statusbar aceita `status_right` e mostra `ctx {used}/{limit}` no canto direito; quando o contador existe, ele tem prioridade sobre o visualizer.
- `phenom-zig/src/main.zig`: contexto enviado ao modelo atualiza a UI com `model_context.measureRenderedContextBytes(...).total_context` contra `max_model_context_send_bytes`.
- `phenom-zig/src/http.zig`: parser de streaming emite `CompletionStop` com motivo `length` para `finish_reason=length`, `done_reason=length`, `stop_type=limit`, `stopped_limit=true` ou `truncated=true`.
- `phenom-zig/src/main.zig`: `StreamSink` marca `output_limit_hit` tambem quando o uso final real de output alcanca `--max-tokens`.
- `phenom-zig/src/render.zig`: output de tool quebra linhas longas antes do terminal quebrar, mantendo `    │ ` em cada linha visual.

Criterio de aceite:

- O usuario consegue ver `ctx used/limit` na statusbar sem depender de tokens fabricados.
- Resposta cortada por limite nao parece sucesso silencioso; o transcript recebe `generation stopped at output limit (--max-tokens N)` e o audit usa `status=output_limit`.
- Linhas longas de evidence/tool nao invadem a margem esquerda no wrap visual.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/http.zig --cache-dir /tmp/phenom-stop-reason-http` -> passou; 33 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/render.zig --cache-dir /tmp/phenom-tool-wrap-render4` -> passou; 31 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/tui.zig -lc --cache-dir /tmp/phenom-status-context-tui6` -> passou; 14 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-stop-status-main2` -> passou; 296 testes.
- `bash tools/check_product_guardrails.sh` -> passou.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- Smoke CLI com backend llama.cpp fake deterministico em `127.0.0.1:18088`: `./zig-out/bin/phenom chat --backend llamacpp --host 127.0.0.1:18088 --model fake --thinking off --max-tokens 8 --session output-limit-smoke-20260718b --prompt 'responda com texto longo' --expect-contains 'resposta parcial' --show-expect-status --fail-on-model-error --no-color` -> passou; transcript mostrou `generation stopped at output limit (--max-tokens 8)`.
- Audit do smoke: `model_stop|generation stopped at output limit (--max-tokens 8)` e `turn_done|status=output_limit ... low_confidence=true`.

Invariantes afetadas:

- 2. Contexto bruto nao vaza para o modelo: preservada; contador mede o contexto renderizado, nao injeta bruto.
- 6. Falha de modelo nao parece falha de infraestrutura: ampliada; corte por limite agora aparece como parada de geracao, nao sucesso normal.
- 7. Cada turno consegue ser auditado e reproduzido: ampliada; `model_stop` registra o motivo visivel.

Risco residual:

- O contador da statusbar e em bytes do prompt renderizado, nao janela neural/tokenizada, porque o projeto nao tem tokenizer do modelo local.
- Backends que nao enviam metadados de parada nem token usage final ainda podem encerrar com motivo desconhecido.

## T313 - Corrigir regressao de overview generico e wrap de tool output

Status: implemented-verified.

Prioridade: urgente.

Motivacao: apos T312, o output de tool ganhou gutter nas continuacoes, mas passou a cortar palavras no meio quando o terminal era estreito. Alem disso, o fluxo `collect_evidence stage=overview` ainda podia deixar o modelo responder com "nao ha evidencia, esclareca" depois de uma evidencia generica de README, mesmo havendo orcamento para uma coleta focada. Isso fazia a coleta parecer quebrada para perguntas ambiguas como "caveman e graph".

Regra de negocio preservada:

- Nao foi adicionada heuristica hardcoded por termo do prompt.
- `overview` continua sendo mapa estrutural, nao resposta final obrigatoria.
- O controller apenas valida protocolo, qualidade/estado da evidencia e necessidade de refinamento.
- A coleta focada continua sendo escolhida pelo modelo via contrato `collect_evidence`.

Passos de implementacao:

1. Criar teste de renderer para prose longa de tool quebrar em fronteira de palavra.
2. Manter fallback de quebra dura quando uma palavra e maior que a largura disponivel.
3. Preservar `intent`, `need`, `terms`, `target_files` e `scope_root` quando o modelo chama `stage=overview` com texto de busca.
4. Fazer `overview` exigir uma coleta focada quando ainda ha orcamento e a evidencia e generica/fraca ou e a primeira exploracao.
5. Criar teste unitario para a regra de refinamento apos overview.
6. Rodar teste focado, main, build release e smoke com backend fake que tenta responder com pedido de esclarecimento apos overview.

Implementacao:

- `phenom-zig/src/render.zig`: `writeWrappedToolLine` agora guarda a ultima fronteira de espaco dentro da largura e quebra ali; se nao houver espaco, quebra pelo limite visual como fallback.
- `phenom-zig/src/main.zig`: `runCollectEvidenceOverviewStep` passa os campos de busca do tool call para `collect_evidence.execute`.
- `phenom-zig/src/main.zig`: `shouldRequireOverviewRefinement` alinha `overview` ao comportamento das coletas pathless fracas, usando `renderCollectedEvidenceContextRequiringCollection`.

Criterio de aceite:

- Tool output longo nao quebra palavras normais no meio.
- Depois de overview generico, uma resposta sem nova tool vira repair, nao resposta final.
- O modelo recebe obrigacao explicita para emitir uma coleta focada antes de responder.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/render.zig --cache-dir /tmp/phenom-tool-word-wrap-render2` -> passou; 32 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-overview-refine-main` -> passou; 298 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- Smoke CLI com backend llama.cpp fake em `127.0.0.1:18089`: primeira resposta do modelo chamou `collect_evidence stage=overview`; segunda tentou responder `Nao ha evidencia clara... esclareca`; o controller descartou a prosa, registrou `tool_repair|required follow-up tool call missing`, executou `collect_evidence stage=candidates terms_bytes=24` e chegou ao marcador final `PHENOM_OVERVIEW_REPAIR_OK`.

Invariantes afetadas:

- 1. Tool nao anunciada nunca executa: preservada; nenhuma tool nova foi adicionada.
- 2. Contexto bruto nao vaza para o modelo: preservada; apenas evidencia destilada segue no contexto.
- 6. Falha de modelo nao parece falha de infraestrutura: ampliada; resposta sem coleta obrigatoria vira repair protocolar.
- 7. Cada turno consegue ser auditado e reproduzido: ampliada; smoke registra `tool_repair`, `tool_start` e `turn_done`.

Risco residual:

- Se o modelo insistir em repetir overview/candidatos sem expandir, o loop ainda depende dos limites de iteracao/reparo existentes.

## T314 - Separar raw reasoning de reparos de prosa no tool loop

Status: implemented-verified.

Prioridade: urgente.

Motivacao: pergunta conversacional simples como `quem e voce?` podia acionar `collect_evidence: overview` mesmo quando o proprio modelo raciocinava que nao precisava de tool. A causa raiz era que `runToolLoopIterations` avaliava reparos de "claim sem evidencia" usando `raw_model`, que inclui `<think>`. Quando o reasoning continha palavras como `code evidence` ou `collect_evidence`, o controller interpretava isso como prosa visivel e criava fallback para `collect_evidence`.

Regra de negocio preservada:

- Parser de tool continua lendo `raw_model` para manter suporte a tool calls ocultas/reparaveis ja existentes.
- Reparos de prosa agora olham apenas `raw_visible`, porque somente texto visivel e resposta ao usuario.
- Nenhuma heuristica por prompt foi adicionada.
- Perguntas de codigo continuam podendo acionar `collect_evidence`.

Passos de implementacao:

1. Criar teste de regressao com raw reasoning contendo `code evidence` e resposta visivel direta.
2. Passar `sink.raw_visible.items` para `runToolLoopIterations`.
3. Manter `tool_envelope.parseFirst` sobre `raw_model`.
4. Usar `visible_output` nos reparos `outputNeedsWorkspaceEvidenceRepair` e `outputCitesMissingSessionEvidence`.
5. Rodar unitario, build release, smokes diretos e smoke de codigo.

Implementacao:

- `phenom-zig/src/main.zig`: `runToolLoopIterations` agora recebe `model_output` e `visible_output`.
- `phenom-zig/src/main.zig`: reparos de prosa usam `visible_output`; parser de envelope continua em `model_output`.
- `phenom-zig/src/main.zig`: teste `tool loop prose repairs ignore hidden reasoning text`.

Criterio de aceite:

- Reasoning oculto que menciona evidencia/tool nao dispara `collect_evidence`.
- Resposta direta visivel passa sem o tool loop tomar posse do turno.
- Tool call real em pergunta de codigo continua executando.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-test ./bin/zig-x86_64-linux-0.16.0/zig test src/main.zig -lc -lsqlite3 --cache-dir /tmp/phenom-visible-repair-main` -> passou; 308 testes.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache ./bin/zig-x86_64-linux-0.16.0/zig build install-local -Doptimize=ReleaseFast` -> passou.
- Smoke CLI direto com hidden reasoning em `127.0.0.1:18090`: `quem e voce hidden` -> `PHENOM_DIRECT_HIDDEN_OK`; audit `tool_start` = 0.
- Smoke CLI direto simples em `127.0.0.1:18090`: `quem e voce simples` -> `PHENOM_DIRECT_SIMPLE_OK`; audit `tool_start` = 0.
- Smoke CLI de codigo em `127.0.0.1:18090`: `qual funcao executa candidatos` -> `PHENOM_CODE_TOOL_OK`; audit `tool_start` = 3.

Invariantes afetadas:

- 1. Tool nao anunciada nunca executa: preservada.
- 6. Falha de modelo nao parece falha de infraestrutura: corrigida; reasoning oculto nao cria falso reparo.
- 7. Cada turno consegue ser auditado e reproduzido: preservada; smokes registram contagem de `tool_start`.

Risco residual:

- Se o modelo emitir um tool_call real dentro de `<think>`, o parser ainda pode executar porque isso e comportamento preservado por testes existentes.
