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

Decisao revisada em 2026-07-04: antes de assumir Rust como base final, sera implementado um spike rapido em Zig + C. A motivacao e filosofica e operacional: controle maior do runtime, arquitetura 100% pertencente ao Phenom, menor dependencia de crates/frameworks, terminal previsivel e possibilidade de otimizar as primitivas necessarias. Rust continua como referencia comparativa, mas o alvo preferencial passa a ser Zig + C se o spike provar renderer, HTTP local streaming, SQLite, gate, evidencia, snapshots e build release.

Regra do spike Zig + C:

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

Alvo final: buckets de tokens por turno e economia estimada por estrategia.

Tasks que resolvem: T101, T110, T111, T112.

Teste de prova: audit fake soma tokens por bucket e calcula economia de EvidencePacket contra arquivo completo.

Risco residual: contagem exata depende do backend/tokenizer; estimativa local deve ser marcada como estimativa quando `/tokenize` nao estiver disponivel.

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

1. Criar metricas por estrategia: chars/tokens input, entries, confidence, fallback.
2. Integrar no TurnAudit.
3. Testar collect_evidence lexical vs RAG fallback.
4. Nao usar tokenizer remoto em teste offline.
5. Renderizar resumo pequeno no audit, nao no prompt.

### T110 - Passos especificos

1. Criar buckets: system, contracts, memory, skills, evidence, repairs, toolSchema.
2. Usar contador local estimado e opcional `/tokenize` quando disponivel.
3. Testar soma com contador fake.
4. Registrar por turno no audit.
5. Nao bloquear execucao por medicao ausente.

### T111 - Passos especificos

1. Para EvidenceEntry de file_slice, comparar tamanho do trecho com tamanho total conhecido.
2. Testar economia estimada em arquivo fake 10000 chars.
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
3. Implementar `estimateEvidenceTokens(entry)` com estimativa simples local.
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

Teste primeiro: collect_evidence registra chars/tokens aproximados por estrategia.

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

Status: pending

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

### T111 - Medir economia vs `read_file` completo

Status: pending

Evidencia: objetivo do projeto e evitar ler projeto inteiro usando contexto sob demanda.

Impacto: comprova valor de collect_evidence/micro-contexto.

Teste primeiro: EvidencePacket com snippet de 1000 chars contra arquivo 10000 chars registra economia aproximada.

Implementacao: estimar bytes/tokens poupados por anchor.

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

Implementacao: criar `ContextBudgetPolicy` por perfil com limites de itens, chars aproximados e prioridade de corte.

Passos de implementacao:

1. Criar teste para budget de cada perfil.
2. Definir limites iniciais conservadores por perfil.
3. Implementar truncamento deterministico por prioridade.
4. Medir chars/tokens aproximados por bloco renderizado.
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
6. Registrar `batches`, `groups`, `chunks`, `llm_calls` e `tokens_estimated`.

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
6. Medir chars/tokens estimados por bloco em teste.

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

## Fase 20 - Spike Zig + C do Phenom final

Esta fase registra a mudanca pratica de direcao: em vez de aceitar Rust como decisao final sem prova, criar um MVP em Zig + C para medir se a filosofia de controle total combina melhor com o Phenom.

### T221 - Implementar MVP `phenom-zig` com renderer, HTTP local, SQLite, gate e evidencia

Status: implemented-verified

Evidencia: o usuario definiu explicitamente o spike minimo: CLI chat, renderer append-only, streaming HTTP local para llama.cpp e Ollama, SQLite audit, tool gate fake, `read_file_range`, `EvidencePacket`, snapshot de terminal e build release.

Impacto: transforma a discussao filosofica Zig+C vs Rust em prova tecnica local, pequena e reversivel.

Teste primeiro: o spike inclui testes unitarios/snapshots para CLI args, renderer append-only, tool gate, EvidencePacket e parsing de deltas Ollama/llama.cpp. Verificado com Zig 0.16.0 baixado em `/tmp`, usando `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache`.

Implementacao: criar `phenom-zig/` isolado, sem tocar no core TS, usando Zig como core e `sqlite3` via C.

Passos de implementacao:

1. Criar `phenom-zig/build.zig` com binario `phenom`, teste e link C/SQLite.
2. Criar CLI minimo `chat`, `snapshot`, `version` com flags de host, backend, model, session, prompt, offline e no-color.
3. Criar renderer append-only deterministico com snapshot plain.
4. Criar cliente HTTP local baixo nivel para Ollama `/api/chat` e llama.cpp `/completion`, com chunked transfer e linhas SSE/NDJSON.
5. Criar audit SQLite via `sqlite3` C em `.phenom-zig/phenom.db`.
6. Criar gate fake e tool `read_file_range` com protecao contra path traversal.
7. Criar `EvidencePacket` compacto para evidencia de arquivo.
8. Adicionar `.gitignore` para build/runtime do spike.
9. Documentar comandos esperados de teste, build release e chat no README do spike.

Criterio de aceite: `zig build test`, `zig build -Doptimize=ReleaseFast`, `zig build run -- snapshot` e `chat --offline` passam. Chat real contra Ollama/llama.cpp ainda deve ser executado quando houver servidor local ativo.

Validacao executada:

- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build test`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build run -- snapshot`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache /tmp/zig-x86_64-linux-0.16.0/zig build run -- chat --offline --session spike --prompt "responda somente: ok"`

Resultado observado:

- Snapshot append-only gerou `> user`, `assistant`, `done` em ordem linear.
- SQLite `.phenom-zig/phenom.db` registrou `turn_start`, `assistant` e `turn_done`.
- Binario release gerado em `phenom-zig/zig-out/bin/phenom` com tamanho observado de 12 MB.
- Ajuste posterior no streaming: deltas de llama.cpp/Ollama decodificam escapes JSON como `\n` e o renderer filtra `<think>...</think>` para nao vazar reasoning no transcript.
- Ajuste posterior de regressao: filtro de reasoning agora e stateful e cobre tags `<think>`/`</think>` quebradas entre chunks; `--max-tokens` foi adicionado para limitar geracao no MVP.
- Ajuste posterior de protocolo: payload llama.cpp passou a seguir o `chat_template.jinja` Qwopus/Qwen fornecido pelo usuario, com `<|im_start|>system/user/assistant`, `<think>\n\n</think>\n\n` para `enable_thinking=false` e stop em `<|im_end|>`.
- Ajuste posterior de thinking dinamico: CLI ganhou `--thinking auto|on|off`; `off` usa bloco de thinking vazio/fechado do template, `on` abre `<think>\n`, e `auto` liga thinking para prompts com sinais de codigo/debug/patch/tool/arquivo/tarefa longa.
- Ajuste posterior de render: thinking deixou de ser apagado; agora e classificado e exibido em baixo destaque com bloco `thinking`, separado do output `assistant`. O filtro cobre tags quebradas entre chunks e tambem o caso em que apenas `</think>` aparece no stream porque `<think>` ja veio do prompt/template.

### T222 - Criar base agente offline no spike Zig com tool call, tool loop e micro-contexto

Status: implemented-verified-micro-base

Evidencia: as tasks primarias T196, T197, T200, T202, T204 e T214 exigem parser de tool call separado do executor, gate estrito, loop fake/offline, tools basicas de codigo, EvidencePacket/micro-contexto e separacao entre teste offline e teste real. O spike T221 tinha renderer, HTTP, SQLite, gate fake, `read_file_range` e EvidencePacket, mas ainda nao tinha tool call model-visible, tool loop nem micro-contexto testado.

Impacto: transforma o spike de CLI streaming em uma micro-base minima de agente, nao em agente completo. O que existe agora: um output fake/offline pode conter uma tool call no formato do template Qwopus; o controller offline parseia uma chamada, valida allowlist, executa uma unica tool permitida, gera evidencia e micro-contexto sem depender de modelo real ou host local.

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
