# Alinhamento Phenom Zig vs AUDIT/TASKS/phenom-cli-ts

Status: auditoria fria da etapa atual.

Data: 2026-07-07.

Fontes primarias:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md`
- `TASKS.md`
- `../phenom-cli-ts`
- `phenom-zig/src`

## Veredito executivo

O `phenom-zig` ja saiu da fase "base de collect_evidence". Ele preserva a superficie pequena para modelo local, mas agora tem contrato operacional model-visible, fases auditadas, `apply_patch` com micro-context fresco, `validate_syntax`, promocao controlada de memoria, runtime HTTP limitado, metadata de backend e smokes reais que consultam SQLite.

Ainda nao preserva todos os acertos do `phenom-cli-ts`. A diferenca atual nao e mais "nao edita"; e amplitude: git/tools amplas, browser DOM real, news operacional, matriz multi-backend e suite real completa ainda nao estao no mesmo nivel do TS. O Zig esta mais solido em gate, auditoria e limites; o TS ainda e referencia de comportamento amplo.

Conclusao cetica: as medidas recentes sao inteligentes porque mantem o modelo como decisor de contrato e restringem reparos a protocolo/ferramentas explicitas. O risco a vigiar e reintroduzir heuristica de intencao por linguagem natural. Quando o modelo erra a ferramenta ativa, o controller deve reparar o protocolo; nao deve inventar patch, escolher negocio ou declarar sucesso sem executor real.

## Regra de auditoria daqui para frente

Antes de implementar qualquer fluxo que ja existia no TypeScript, a tarefa deve abrir e citar o trecho equivalente em `../phenom-cli-ts`. Se nao houver trecho equivalente, a tarefa deve declarar isso explicitamente.

Formato minimo por task futura:

- Referencia TS consultada.
- Falha apontada no AUDIT/TASKS.
- O que sera preservado do TS.
- O que sera corrigido no Zig.
- O que nao sera portado agora e por que.
- Teste unitario.
- Smoke real se envolver modelo/servidor/tool loop.
- Revisao baixo nivel Zig antes do commit.

Sem isso, a task fica desalinhada por processo, mesmo que compile.

## A0 - Contrato central model-driven

Evidencia canonica:

- AUDIT diz que o controller nao deve inferir direcao operacional por palavras-chave; deve expor contratos/ferramentas e deixar o modelo escolher.
- `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts:43` retorna sempre `model_driven`.
- `../phenom-cli-ts/src/agent.ts:821` e `../phenom-cli-ts/src/agent.ts:830` instruem o modelo a usar `collect_evidence` preservando paths concretos, sem trocar por resumo generico.
- `phenom-zig/src/main.zig` instrui o modelo a inferir intencao, selecionar contrato via `set_operational_contract` e so entao usar ferramentas do contrato ativo.

O que o Zig corrigiu:

- Removeu varias heuristicas hardcoded que tinham sido introduzidas durante o port.
- `phenom-zig/src/contracts.zig` mantem superficie inicial pequena e abre ferramentas por contrato: workflow, evidencia, mutacao, validacao/runtime e memoria.
- `phenom-zig/src/main.zig:471` valida allowlist antes de executar tool.

O que o Zig ainda precisa preservar melhor:

- `set_operational_contract` ja e model-visible e executa selecao de contrato.
- O contrato em Zig ainda usa schema textual no prompt, mas a decisao e auditada em estado tipado e `contracts.ActiveContract`.
- O Zig usa uma reparacao especifica `singleStructuredPathFromPrompt` em `main.zig` para path ausente. Isso e pragmatico, mas precisa ser tratado como reparo de protocolo, nao como interpretacao de intencao.

Veredito:

- Parcialmente alinhado.
- Melhor que TS em superficie pequena e gate.
- Menos amplo que TS em contrato operacional completo.

Proxima exigencia:

- Preservar o reparo estreito: somente corrigir protocolo/ferramenta explicita; nao inferir intencao por palavras naturais.
- Ampliar contratos sem expor primitivas soltas.

## A1 - Tool surface e ferramentas reais

Evidencia canonica:

- AUDIT lista tools model-visible principais: `collect_evidence`, `read_file`, `path_exists`, `list_dir`, `write_file`, `create_file`, `apply_patch`, `run_validation`, `validate_syntax`, `run_tests`, `run_code`, `browser_check`, git, session e `set_operational_contract`.
- `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts:33-53` implementa essa lista.
- `phenom-zig/src/contracts.zig` agora deixa `set_operational_contract` no contrato inicial e libera `collect_evidence`, `search_session`, `apply_patch`, `validate_syntax`, `inspect_runtime` e `promote_context` apenas nos contratos corretos.

O que o Zig corrigiu:

- Evitou a montanha de tools expostas ao modelo pequeno.
- Cumpre parcialmente o ponto "tool nao anunciada nunca executa".
- Evita expor primitivas internas como `grep_file`, `parse_ast`, `rag_search`.

O que o Zig perdeu:

- O TS ainda tem amplitude maior em git, browser, news, validadores e tools utilitarias.
- O Zig ja edita e valida o caso coder basico, mas ainda nao cobre todas as familias de ferramentas do produto final.
- O usuario nao precisa configurar variavel global para o fluxo normal; smokes reais criam ambiente temporario e limpam sucesso automaticamente.

Veredito:

- Alinhado com "baixo ruido" e "tools internas escondidas".
- Desalinhado com "produto final completo".

Proxima exigencia:

- Reintroduzir tools por contratos, nao por lista solta:
  - `mutation` -> ampliar alem de `apply_patch` para `write_file`, `create_file`, rename/delete seguros
  - `validation` -> ampliar alem de `validate_syntax` para `run_validation`, `run_tests`, `run_code`
  - `runtime/browser` -> manter HTTP runtime auditado e adicionar browser DOM real
  - `session/memory` -> leitura e escrita controlada
  - `news` -> profile proprio, nao micro-contexto

## A2 - Tool loop

Evidencia canonica:

- `../phenom-cli-ts/src/agent.ts:552` marca o "Core tool loop".
- `../phenom-cli-ts/src/agent.ts:594-623` deriva contrato, filtra tools, chama `runToolLoopUseCase`, passa state, brain, stream, parser, executor, memory/context compaction e `OperationalRunStore`.
- `phenom-zig/src/main.zig` implementa loop sobre envelope de tool, contrato ativo e fases auditadas.
- O loop executa `collect_evidence`, `search_session`, `apply_patch`, `validate_syntax`, `inspect_runtime` e `promote_context` conforme contrato.

O que o Zig corrigiu:

- Suprime texto de tool call antes de renderizar.
- Deduplica coletas iguais no turno.
- Tem limite de emergencia e budget.
- Reinjeta evidencia destilada em um novo `ModelTurnContext`.
- Audita tool events no SQLite.

O que o Zig ainda nao preserva do TS:

- Nao ha `OperationalRunStore` identico ao TS; o equivalente pragmatico e SQLite append-only com `turn_phase`, `turn_error`, eventos de tool e replay textual.
- Nao ha browser DOM state.
- Nao ha distill dropped messages/sumarizacao semantica de janela longa.
- Alguns erros de ferramenta ainda caem em reparo/finalizacao controlada; isso e melhor que sucesso falso, mas precisa mais cenarios negativos reais.

Problema criado:

- O loop ficou correto para evidencia + patch simples + validacao Zig, mas ainda estreito para produto completo. Smokes reais provam fatias importantes, nao a matriz inteira.

Veredito:

- Boa base de loop operacional.
- Ainda nao e o loop principal completo do Phenom porque faltam browser DOM, git/tools amplas, validators amplos e matriz real multi-backend.

Proxima exigencia:

- Expandir as fases existentes para ferramentas restantes.
- Manter falhas tipadas como `model_protocol`, `tool_contract`, `tool_runtime`, `infrastructure`, `insufficient_evidence` e `validation_failed`.

## A3 - Contexto, evidencia e micro-contexto

Evidencia canonica:

- AUDIT 3.7 aponta `collect_evidence`, `build_task_context`, RAG, lexical `rg`, AST, micro-context id/sha, ranges editaveis, LSP e `[NEXT_ACTION]`.
- `../phenom-cli-ts/src/tools/registrars/context-tools.ts:368-566` implementa `collect_evidence` com `mode`, `task/query`, `targetFiles`, `scopeRoot`, `symbol`, `stage`, `selectedCandidates`, `need`, `terms`, `budget`, `maxEvidence`, `compact`.
- `../phenom-cli-ts/src/tools/micro-context.ts:52-80` materializa micro-context com id, sha256, path e range.
- `../phenom-cli-ts/src/tools/micro-context.ts:82-170` valida context id/hash/path/range/stale antes de patch.
- `phenom-zig/src/collect_evidence.zig:11-19` tem args menores: `path`, `terms`, `task`, `strategy`, `start_line`, `max_lines`, `budget_bytes`.
- `phenom-zig/src/collect_evidence.zig:143-196` ranqueia ranges e cria evidence + micro-context.
- `phenom-zig/src/micro_context.zig:52-80` cria id/hash/path/range/excerpt.

O que o Zig corrigiu:

- `EvidencePacket` e `MicroContext` sao ownership-safe e testados.
- Hash de range existe.
- `collect_evidence` nao vaza raw output.
- Estrategias reais ativas: `path`, `lexical`, `symbol`, `diagnostic`.
- FTS5/BM25 e `rg` foram incorporados sem embeddings.
- Inventario foi corrigido para nao enviesar por linguagem/ecossistema.

O que o Zig ainda nao preserva:

- `stage=candidates/minimum/expand/overview` e `selectedCandidates` ja existem no parser/loop.
- `need`, `scopeRoot` e `targetFiles` ja entram em `collect_evidence`, ainda com cobertura menor que o contrato TS.
- `EvidencePacket v1` existe como formato textual estavel de entradas E#, mas ainda nao tem todos os campos ricos do TS como findings/obligations/stalePaths.
- `apply_patch` ja valida micro-context fresco antes de escrever.
- `diagnostic` e apenas Zig sintatico, enquanto TS tinha LSP/diagnostics mais amplo.

Problema criado:

- O Zig ainda depende bastante de termos/model-selected retrieval keys. Melhorou com candidates/expand/overview, mas ainda nao tem a riqueza completa do TS para hypotheses e avaliacao de suficiencia.

Veredito:

- Melhor que o TS em limpeza/ownership/bounds.
- Menos completo que o TS em contrato de coleta.

Proxima exigencia:

- Evoluir `collect_evidence` sem heuristica:
  - completar `hypotheses`, suficiencia e stale obligations;
  - manter o modelo como cerebro;
  - agente executa e audita estrategia, nao interpreta negocio.

## A4 - Ranking e busca

Evidencia canonica:

- AUDIT pede RAG/AST escondidos atras de `collect_evidence`, e metricas de custo/beneficio por estrategia.
- `../phenom-cli-ts/src/tools/registrars/context-tools.ts:405-463` combina RAG, lexical, scope, validation, root causes, structural ranges, merge e selection.
- `phenom-zig/src/evidence_ranker.zig` tem fontes `prompt_path`, `symbol_ast`, `rg`, `fts_bm25`, `fallback_scan`, `workspace_overview`, `keyword_discovery`.

O que o Zig corrigiu:

- Removeu stopwords hardcoded e filtros por ecossistema apos revisao.
- Usa `rg`, FTS5/BM25, symbol parser e diagnostic como fontes objetivas.
- Faz merge de ranges.
- Tem audit de ranking.

O que ainda esta fragil:

- Ainda ha ranking por tokens e score deterministico. Isso e aceitavel sem embeddings, mas nao substitui julgamento do modelo.
- `workspace_overview` e fallback generico; precisa continuar livre de vies de stack.
- Nao ha etapa de candidatos/minimum como no TS.
- Nao ha metrica real "evidencia suficiente para responder/editar".

Veredito:

- Alinhado como base deterministica sem embeddings.
- Parcial como substituto do `collect_evidence` TS.

Proxima exigencia:

- Smoke real deve medir: pergunta ambigua -> modelo coleta -> avalia insuficiencia -> refina coleta -> responde com E#.
- Nao aceitar "marcador final passou" como prova de boa evidencia.

## A5 - Historico, sessao, memoria e SKILLS

Evidencia canonica:

- `../phenom-cli-ts/src/agent.ts:746-764` usa `recentMessages` como historico normal e nao injeta session context no system prompt.
- `../phenom-cli-ts/src/use-cases/build-inference-messages.ts:53-95` sanitiza historico, preserva current query e compacta se necessario.
- `../phenom-cli-ts/src/use-cases/build-inference-messages.ts:115-130` remove wrappers/protocolos crus de assistant message.
- AUDIT 3.8 diz que memoria dinamica/persistente existe, mas ha risco de multiplas memorias concorrentes.
- `phenom-zig/src/session_context.zig:68-111` agora renderiza `[RECENT_DIALOGUE]`.
- `phenom-zig/src/session_context.zig:113-155` renderiza `[SESSION_EVIDENCE]` para busca.

O que o Zig corrigiu:

- Separou `RECENT_DIALOGUE` de `SESSION_CONTEXT`.
- Evita MEMORY/SKILLS inventados.
- SQLite armazena audit de turno, tool, evidence, session e tempo.
- Corrigiu o bug real em que o modelo respondia "sem evidencia" apesar de haver conversa recente.

O que o Zig ainda nao preserva:

- Nao ha janela de mensagens com roles reais enviada como mensagens separadas; o dialogo recente vira bloco de texto.
- Nao ha sumarizacao semantica de historico longo.
- `search_session` e busca textual simples com truncamento.
- MEMORY/SKILLS persistentes sao carregados de arquivos, mas nao ha writer/orchestrator maduro.
- Nao ha hierarquia formal completa: evidence do turno > MEMORY > SKILLS > session.

Problema criado:

- `[RECENT_DIALOGUE]` resolve continuidade, mas pode virar mais uma secao de contexto se nao houver politica de budget e sumarizacao. Isso e menor que o bug anterior, mas ainda precisa controle.

Veredito:

- Corrigido para continuidade recente.
- Parcial para memoria de produto final.

Proxima exigencia:

- Portar uma janela de mensagens/sumarizacao ou documentar por que o Zig vai manter bloco de dialogo.
- Implementar busca de sessao com FTS/BM25 e snippets com role/turn, sem misturar com MEMORY/SKILLS.

## A6 - System prompt e output para modelo

Evidencia canonica:

- AUDIT aponta que `Agent.buildSystemPrompt` era grande e fragil.
- `../phenom-cli-ts/src/agent.ts:801-878` mantem system prompt dinamico, mas tenta preservar prefixo estavel e mover contexto volateis para a mensagem atual/tool.
- `phenom-zig/src/model_context.zig:4-6` usa um system prompt muito curto.
- `phenom-zig/src/model_context.zig:35-124` renderiza `TURN_CONTEXT v1`.

O que o Zig corrigiu:

- System prompt ficou compacto.
- MEMORY/SKILLS so aparecem se carregados.
- Tool outputs viram contexto destilado.
- Raw markers sao bloqueados em `assertNoRawContextLeak`.

O que o Zig ainda nao preserva:

- O TS considera limite real de contexto do backend e schemaBaselineTokens; Zig agora audita `backend_metadata` com tokenizer, schema baseline e context window quando o backend fornece, mas ainda nao usa isso para compaction fina por bucket.
- O TS sanitiza mensagens de tool round-trip; Zig ainda depende do proprio `TURN_CONTEXT`.
- O Zig ainda usa muitas instrucoes em `NEXT_ACTION`, que podem virar micro-system-prompt variavel por fase.

Veredito:

- Melhor em simplicidade.
- Parcial em cache/context-window real.

Proxima exigencia:

- Continuar auditando prompt bytes/tokens reais quando disponiveis no SQLite.
- Auditar system/context prefix stability.
- Tipar `NEXT_ACTION` como campo de contrato, nao como texto livre crescente.

## A7 - Renderer/TUI

Evidencia canonica:

- AUDIT cita renderizacao por `cli-renderer.ts`, `stream-markdown-renderer.ts` e `tui/event-bus.ts`.
- `../phenom-cli-ts/src/cli-renderer.ts` tem renderer append-like, prompt proprio, markdown stream, thinking, tools, diffs, restore e visualizer.
- `phenom-zig/src/render.zig`, `tui.zig`, `ui_events.zig` e testes em `main.zig` cobrem prompt, restore, thinking, tools, markdown e diff.

O que o Zig corrigiu:

- Portou boa parte do visual: prompt, thinking, tool blocks, markdown, diff com cores menos agressivas, statusbar/visualizer, restore de SQLite, Worked for.
- Reduziu glitches de TS ao mover para controle baixo nivel.
- Tem testes de snapshot em `render.zig` e `main.zig`.

O que ainda exige prova:

- Resize real em TTY/tmux precisa smoke visual recorrente.
- Markdown/diff foi ajustado varias vezes por feedback manual; precisa suite de regressao com capturas representativas.
- Visual "identico" ao TS ainda e criterio visual, nao apenas unitario.

Veredito:

- Area mais madura do Zig ate agora.
- Ainda precisa prova operacional continua, nao apenas assert de string.

Proxima exigencia:

- Snapshot terminal por largura: 40, 80, 120, 180 cols.
- Fixture de markdown/diff/tool/thinking restaurado do SQLite.

## A8 - HTTP/backend/model protocol

Evidencia canonica:

- `../phenom-cli-ts/src/agent.ts:560-585` resolve formato de chat uma vez por turno e distingue falha de mock vs backend real.
- `../phenom-cli-ts/src/agent.ts:780-798` considera schemaBaselineTokens para native tools.
- `phenom-zig/src/http.zig` suporta Ollama e llama.cpp com template Qwopus/harmony e streaming.

O que o Zig corrigiu:

- Corrigiu porta/host/backend e endpoints `/api/chat` vs `/completion`.
- Suporta `thinking` on/off/auto.
- Evita resposta offline `ok` enganosa.

O que ainda nao preserva:

- Nao ha native tool calling.
- Nao ha detecao robusta de chat format por backend como TS.
- `n_ctx/schema baseline` sao auditados quando backend fornece, mas ainda nao dirigem compaction operacional.
- Falha de modelo vs infra ja tem taxonomia objetiva; ainda faltam `stream_timeout`, DNS/familia de rede e matriz multi-backend real.
- `inspect_runtime` executa HTTP GET limitado e audita status/server/body sanitizado; browser DOM real ainda nao existe.

Veredito:

- Bom cliente local streaming com metadata e falhas tipadas.
- Parcial como camada de agente produtivo multi-backend.

## A9 - News e context profiles

Evidencia canonica:

- O usuario definiu que news nao deve operar com micro-contexto minimo.
- TS tem `news` com providers, preferences, cache, classification e newspaper view.
- `phenom-zig/src/contracts.zig:28-29` declara estrategias `news_table` e `document_summary`, mas nao ha executores equivalentes.

O que o Zig corrigiu:

- Implementou `ContextProfile` para separar code evidence, session, news/doc/log, document summary, runtime diagnostics e memory.
- Impediu que news/document/runtime caiam por acidente no micro-context editavel de codigo.

O que falta:

- News table/profile com fontes em storage, preferencias e briefing.
- Documento/PDF/log profile com budget maior e sumarizacao propria.

Veredito:

- Infra de profile implementada; news/document executores completos ainda pendentes.

Proxima exigencia:

- Implementar news/document tools usando os profiles existentes.
- Manter `code_micro` fora de news/document/runtime.

## A10 - Patch/mutation/validacao

Evidencia canonica:

- AUDIT exige que patch nao aplique sobre contexto stale.
- TS valida micro-context stale em `micro-context.ts:82-170`.
- TS tem `apply_patch`, `write_file`, `create_file`, `run_validation`, `browser_check` e policies.
- Zig tem `micro_context.Registry.validateFresh` integrado a `apply_patch` no loop.

O que o Zig corrigiu:

- Tem primitiva de micro-context com sha.
- Detecta stale antes de patch.
- `apply_patch` registra resultado no SQLite e so escreve com `contextId` fresco.
- `validate_syntax` registra evidencia diagnostica antes do final quando o contrato exige validacao.

O que falta:

- `write_file`, `create_file`, delete/rename e git tools amplas ainda nao estao no loop principal.
- `run_tests`, `run_code` e validadores multi-linguagem ainda nao estao equivalentes ao TS.
- Browser DOM continua fora.

Veredito:

- Patch simples end-to-end esta implementado e comprovado com backend real.
- Requisito central de coder agent esta parcialmente cumprido; amplitude de ferramentas e validacao ainda pendente.

## A11 - Testes reais e criterio de confiabilidade

Evidencia canonica:

- AUDIT pede testes reais separados de infraestrutura e modelo, com relatorios por tool surface, prompt chars, memory blocks, parser strategy, calls e results.
- `TASKS.md` exige provar:
  1. Tool nao anunciada nunca executa.
  2. Contexto bruto nao vaza.
  3. MEMORY/SKILLS nao competem com storage operacional.
  4. News nao depende de prompt improvisado.
  5. Patch nao aplica sobre contexto stale.
  6. Falha de modelo nao parece falha de infraestrutura.
  7. Cada turno pode ser auditado/reproduzido.

Status no Zig:

- 1: Provado offline para gate e real para fluxos de contrato/evidencia/patch; ainda falta matriz de todas as tools TS.
- 2: Bem encaminhado por `assertNoRawContextLeak` e smokes com audit.
- 3: Parcial; MEMORY/SKILLS estao separados de SQLite operacional e promocao e controlada, mas nao ha orchestrator final equivalente ao TS.
- 4: Profile implementado; news executor completo ainda nao implementado.
- 5: Implementado para `apply_patch` com micro-context fresco; faltam cenarios reais negativos de stale e outras mutacoes.
- 6: Melhorado com taxonomia de erro e backend failure classification; faltam timeouts/DNS/multi-backend real.
- 7: SQLite audita eventos, fases e erros; replay textual existe, mas ainda nao substitui um inspector completo.

Veredito:

- Confiavel para os fluxos comprovados: TUI/streaming/evidencia, patch Zig simples, validacao sintatica Zig e runtime HTTP limitado.
- Ainda nao confiavel como agente coder final completo porque faltam git/tools amplas, browser DOM, news e matriz real de regressao.

## Mapa de alinhamento por eixo

| Eixo | TS preservado? | Falha do TS corrigida? | Novo problema no Zig? | Status |
|---|---:|---:|---:|---|
| TUI/render | Sim, em grande parte | Sim | Precisa prova visual ampla | Parcial alto |
| HTTP local | Parcial | Sim | Sem native tools/formato robusto/browser DOM | Parcial alto |
| SQLite audit | Sim | Sim | Inspector completo ainda falta | Parcial alto |
| Contrato model-driven | Sim para contratos atuais | Sim | Reparos devem continuar estreitos | Parcial alto |
| Tool gate | Sim | Sim | Surface ainda menor que TS | Parcial alto |
| collect_evidence | Parcial alto | Sim | Args/estagios ainda menos ricos que TS | Parcial alto |
| Micro-context | Sim para patch | Sim | Falta matriz stale negativa real ampla | Parcial alto |
| Memory/SKILLS | Parcial | Parcial | Sem orchestrator final | Parcial |
| Session continuity | Sim apos T280 | Sim | Sem sumarizacao longa | Parcial |
| Mutation | Parcial | Sim | Sem write/create/git amplos | Parcial |
| Validation/runtime | Parcial | Parcial | Diagnostic Zig-only e HTTP-only runtime | Parcial |
| News/context profiles | Profile sim, news nao | Parcial | Executor news pendente | Parcial |
| Real test suite | Parcial | Parcial | Smokes ainda estreitos | Parcial |

## Problemas novos introduzidos pelo Zig

1. Superficie operacional ainda menor que a do TS.
   - Bom para modelo pequeno, ruim para produto final.
   - Se nao houver contratos progressivos, o agente vira "respondedor com evidencia", nao coder agent.

2. Contrato de contexto ainda textual.
   - `TURN_CONTEXT v1` e legivel, mas nao e schema operacional completo.
   - `NEXT_ACTION` ainda carrega muita politica em frase.

3. Coleta guiada depende demais de `terms`.
   - Melhorou depois da correcao model-driven, mas TS tinha `task`, `need`, `stage`, `targetFiles`, `scopeRoot`, `selectedCandidates`.

4. Historico recente virou bloco, nao mensagem real.
   - Corrigiu bug imediato.
   - Ainda nao e equivalente ao `recentMessages` do TS.

5. Smokes ainda podem dar falso positivo fora dos cenarios auditados.
   - Marcador final prova que o modelo terminou.
   - Nao prova que a evidencia foi ideal, suficiente ou sem extrapolacao.

## Acertos do Zig que devem ser preservados

1. Binario baixo nivel com TUI mais previsivel.
2. Renderer com snapshot e restore via SQLite.
3. `collect_evidence` pequeno e model-visible.
4. Tools internas escondidas.
5. Sem raw context no modelo.
6. Evidence/micro-context com ownership claro.
7. Inventario sem vies por linguagem/ecossistema.
8. Separacao `RECENT_DIALOGUE` vs `SESSION_CONTEXT`.
9. Config merge sem sobrescrever usuario.
10. Testes unitarios em Zig cobrindo ownership e limites.

## Ordem recomendada para realinhar

1. Congelar este documento como check obrigatorio antes de novas features.
2. Preservar `set_operational_contract` model-visible e impedir heuristica ampla de intencao.
3. Completar `collect_evidence` com suficiencia/hypotheses/obligations equivalentes ao TS.
4. Completar `EvidencePacket v1` tipado com anchors, findings, obligations e next actions.
5. Expandir mutation alem de `apply_patch`: write/create/delete/rename/git com as mesmas garantias de micro-context/stale.
6. Expandir validation alem de `validate_syntax`: run_tests/run_code/validadores por linguagem.
7. Ampliar runtime de HTTP GET auditado para browser DOM real quando necessario.
8. Transformar replay de turno em inspector operacional completo.
9. Usar backend metadata real para compaction por contexto quando disponivel.
10. Portar news usando os context profiles existentes.

## Criterio para dizer "alinhado"

O projeto so deve ser considerado alinhado com AUDIT/TASKS/phenom-cli-ts quando:

- Cada fluxo portado cita a referencia TS usada.
- Cada contrato model-visible tem executor real.
- Cada executor retorna evidencia destilada e auditavel.
- Nenhuma tool interna aparece ao modelo por acidente.
- Nenhum raw output aparece no contexto.
- MEMORY/SKILLS nao competem com SQLite operacional.
- Patch exige contexto fresco quando contexto foi usado.
- Validation/runtime tem executor real ou indisponibilidade auditavel, com falha tipada.
- News/documentos usam profiles proprios, nao code micro-context.
- Smokes reais avaliam comportamento, nao apenas marcador final.
- O SQLite permite reconstruir: prompt, modelo, contrato, tools anunciadas, calls, resultados, contexto enviado e resposta final.

## Conclusao

O `phenom-zig` esta na direcao certa como rebase baixo nivel e agora ja cobre fluxos reais de agente, nao apenas resposta com evidencia. A base ficou mais segura e mais limpa que o TS em pontos especificos, mas ainda perdeu amplitude operacional. O caminho correto nao e adicionar atalhos no Zig; e portar os acertos do TS por contrato, corrigindo as falhas do AUDIT uma por uma.

Regra final desta auditoria: quando houver duvida, `phenom-cli-ts` e referencia de comportamento; `AUDIT` define o que nao repetir; `TASKS.md` define a ordem e criterios; `phenom-zig` deve implementar somente depois de cruzar os tres.
