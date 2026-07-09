# Alinhamento Phenom Zig vs AUDIT/TASKS/phenom-cli-ts

Status: auditoria fria da etapa atual.

Data: 2026-07-07.

Fontes primarias:

- `doc/AGENTE_AI_BAIXO_CONSUMO_TOKENS_AUDIT.md`
- `TASKS.md`
- `../phenom-cli-ts`
- `phenom-zig/src`

## Veredito executivo

O `phenom-zig` nao esta vazio nem fora de direcao. Ele ja corrigiu parte real dos problemas que o AUDIT apontava no TypeScript: renderer mais previsivel, SQLite auditavel, contrato pequeno, gate de tool, contexto destilado, bloqueio de raw leak, micro-context com hash, ranking por `rg`/FTS/symbol e separacao recente entre dialogo e evidencia de sessao.

Mas o `phenom-zig` ainda nao preserva todos os acertos do `phenom-cli-ts`. Ele esta mais proximo de uma base solida de `collect_evidence` + TUI do que de um agente coder completo. O maior desalinhamento atual e operacional: o TypeScript ja tinha um loop de agente com tool surface ampla, `set_operational_contract`, mutation, validation, browser/runtime, memory orchestrator, phase context, session tools e news. O Zig reduziu essa superficie para `collect_evidence` e `search_session`. Isso evita ruido, mas tambem remove capacidades que eram parte do produto.

Conclusao cetica: o `phenom-zig` resolveu problemas de base, mas ainda nao resolveu "o problema como um todo". Se continuar implementando fluxos sem consultar `phenom-cli-ts`, `AUDIT` e `TASKS.md` antes de cada eixo, vai recriar bugs ja documentados: prompt como contrato, ferramenta sem fase operacional, evidencia insuficiente, memoria concorrente, grounding fragil e regressao de comportamento real.

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
- `phenom-zig/src/main.zig:370` tambem instrui o modelo a inferir intencao e chamar `collect_evidence`/`search_session`.

O que o Zig corrigiu:

- Removeu varias heuristicas hardcoded que tinham sido introduzidas durante o port.
- `phenom-zig/src/contracts.zig:65-66` deixa model-visible apenas `collect_evidence` e `search_session`.
- `phenom-zig/src/main.zig:471` valida allowlist antes de executar tool.

O que o Zig quebrou ou ainda nao preservou:

- `set_operational_contract` existe no manifesto Zig como interno, mas nao e executavel/model-visible. No TS ele e parte da superficie model-visible em `intent-tool-contract.ts`.
- O contrato em Zig ainda e texto em `collectEvidenceToolSchema`, nao uma API operacional de fases com estado tipado.
- O Zig usa uma reparacao especifica `singleStructuredPathFromPrompt` em `main.zig` para path ausente. Isso e pragmatico, mas precisa ser tratado como reparo de protocolo, nao como interpretacao de intencao.

Veredito:

- Parcialmente alinhado.
- Melhor que TS em superficie pequena e gate.
- Pior que TS em contrato operacional completo.

Proxima exigencia:

- Portar `set_operational_contract` como contrato real antes de mutation/validation.
- Auditar cada tool call com: contrato ativo, estrategia, tool visivel, validacao, executor, evidencia liberada ao modelo.

## A1 - Tool surface e ferramentas reais

Evidencia canonica:

- AUDIT lista tools model-visible principais: `collect_evidence`, `read_file`, `path_exists`, `list_dir`, `write_file`, `create_file`, `apply_patch`, `run_validation`, `validate_syntax`, `run_tests`, `run_code`, `browser_check`, git, session e `set_operational_contract`.
- `../phenom-cli-ts/src/agent-control/intent-tool-contract.ts:33-53` implementa essa lista.
- `phenom-zig/src/contracts.zig:65-66` so deixa `collect_evidence` e `search_session` visiveis.
- `phenom-zig/src/contracts.zig:67-122` lista muitas tools como internas, mas elas nao estao integradas ao loop principal.

O que o Zig corrigiu:

- Evitou a montanha de tools expostas ao modelo pequeno.
- Cumpre parcialmente o ponto "tool nao anunciada nunca executa".
- Evita expor primitivas internas como `grep_file`, `parse_ast`, `rag_search`.

O que o Zig perdeu:

- O TS ja tinha fluxo operacional de leitura exata, mutacao, validacao, browser, git, news e memoria.
- O Zig ainda nao e um agente coder completo: ele coleta evidencia e responde, mas nao edita/valida como o produto final exige.
- O usuario nao deve precisar lembrar que `apply_patch`, validation e runtime ainda nao existem no loop Zig.

Veredito:

- Alinhado com "baixo ruido" e "tools internas escondidas".
- Desalinhado com "produto final completo".

Proxima exigencia:

- Reintroduzir tools por contratos, nao por lista solta:
  - `mutation` -> `apply_patch`, `write_file`, `create_file`
  - `validation` -> `run_validation`, `validate_syntax`, `run_tests`, `run_code`
  - `runtime/browser` -> `browser_check` e servidor
  - `session/memory` -> leitura e escrita controlada
  - `news` -> profile proprio, nao micro-contexto

## A2 - Tool loop

Evidencia canonica:

- `../phenom-cli-ts/src/agent.ts:552` marca o "Core tool loop".
- `../phenom-cli-ts/src/agent.ts:594-623` deriva contrato, filtra tools, chama `runToolLoopUseCase`, passa state, brain, stream, parser, executor, memory/context compaction e `OperationalRunStore`.
- `phenom-zig/src/main.zig:386-461` implementa loop sobre envelope de tool.
- `phenom-zig/src/main.zig:467-610` executa `collect_evidence`.
- `phenom-zig/src/main.zig:615-681` executa `search_session`.

O que o Zig corrigiu:

- Suprime texto de tool call antes de renderizar.
- Deduplica coletas iguais no turno.
- Tem limite de emergencia e budget.
- Reinjeta evidencia destilada em um novo `ModelTurnContext`.
- Audita tool events no SQLite.

O que o Zig ainda nao preserva do TS:

- Nao ha `OperationalRunStore` equivalente.
- Nao ha task-state-machine.
- Nao ha phase context.
- Nao ha mutation/validation/browser state.
- Nao ha distill dropped messages/sumarizacao de janela.
- Falha de tool ainda pode virar "responda diretamente" em `main.zig:575`, o que pode parecer falha de modelo em vez de falha operacional claramente classificada.

Problema criado:

- O loop ficou correto para `collect_evidence`, mas estreito demais para o produto. Isso pode dar falsa sensacao de alinhamento porque os smokes passam, mas eles provam uma fatia pequena.

Veredito:

- Boa base inicial de loop de evidencia, ainda insuficiente para declarar o fluxo principal do produto completo.
- Ainda nao e o loop principal completo do Phenom.

Proxima exigencia:

- Portar o conceito de fases do TS antes de liberar mutation.
- Falhas devem ser tipadas como `model_protocol`, `tool_contract`, `tool_runtime`, `infrastructure`, `insufficient_evidence`.

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

- Nao existe `stage=candidates/minimum`.
- Nao existe `selectedCandidates`.
- Nao existe `need`, `hypotheses`, `scopeRoot`, `targetFiles` como contrato de primeira classe.
- Nao existe `EvidencePacket v1` com campos estaveis tipo `findings`, `anchors`, `obligations`, `nextActions`, `stalePaths`, `confidence`.
- Nao existe validacao de micro-context acoplada a `apply_patch`, porque `apply_patch` ainda nao esta no loop.
- `diagnostic` e apenas Zig sintatico, enquanto TS tinha LSP/diagnostics mais amplo.

Problema criado:

- O Zig tem `task` em `collect_evidence.Args`, mas `executeRanked` usa principalmente `terms`; isso reforca a dependencia do modelo emitir bons termos. O TS aceitava uma intencao mais rica (`task`, `need`, `targetFiles`, `stage`) e deixava o agente executar varias fontes.

Veredito:

- Melhor que o TS em limpeza/ownership/bounds.
- Menos completo que o TS em contrato de coleta.

Proxima exigencia:

- Evoluir `collect_evidence` sem heuristica:
  - adicionar `task`, `need`, `targetFiles`, `scopeRoot`, `stage`, `selectedCandidates`;
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

- O TS considera limite real de contexto do backend e schemaBaselineTokens; Zig ainda nao tem equivalente robusto.
- O TS sanitiza mensagens de tool round-trip; Zig ainda depende do proprio `TURN_CONTEXT`.
- O Zig ainda usa muitas instrucoes em `NEXT_ACTION`, que podem virar micro-system-prompt variavel por fase.

Veredito:

- Melhor em simplicidade.
- Parcial em cache/context-window real.

Proxima exigencia:

- Medir prompt bytes/tokens por turno no SQLite.
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
- Nao ha contexto efetivo do servidor/n_ctx usado para compaction.
- Falha de modelo vs infra ainda precisa classificacao mais forte no audit.

Veredito:

- Bom cliente local streaming.
- Parcial como camada de agente produtivo multi-backend.

## A9 - News e context profiles

Evidencia canonica:

- O usuario definiu que news nao deve operar com micro-contexto minimo.
- TS tem `news` com providers, preferences, cache, classification e newspaper view.
- `phenom-zig/src/contracts.zig:28-29` declara estrategias `news_table` e `document_summary`, mas nao ha executores equivalentes.

O que o Zig corrigiu:

- Reconheceu no manifesto que existem perfis fora de code micro-context.

O que falta:

- `context profiles` reais.
- News table/profile com fontes em storage, preferencias e briefing.
- Documento/PDF/log profile com budget maior e sumarizacao propria.

Veredito:

- Registrado, nao implementado.

Proxima exigencia:

- Implementar `ContextProfile` antes de news/document tools.
- `code_micro` nao pode ser default universal.

## A10 - Patch/mutation/validacao

Evidencia canonica:

- AUDIT exige que patch nao aplique sobre contexto stale.
- TS valida micro-context stale em `micro-context.ts:82-170`.
- TS tem `apply_patch`, `write_file`, `create_file`, `run_validation`, `browser_check` e policies.
- Zig tem `micro_context.Registry.validateFresh`, mas mutation nao esta integrada ao loop.

O que o Zig corrigiu:

- Tem primitiva de micro-context com sha.
- Tem base para detectar stale.

O que falta:

- `apply_patch` real no agente.
- Validacao de context id/hash antes de patch.
- Registro de mutacao no SQLite.
- Validation obrigatoria conforme contrato.
- Separar falha de patch, falha de modelo e falha de infra.

Veredito:

- Base existe.
- Requisito central ainda pendente.

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

- 1: Parcialmente provado para `collect_evidence`/`search_session`.
- 2: Bem encaminhado por `assertNoRawContextLeak` e smokes com `raw_marker=0`.
- 3: Parcial; MEMORY/SKILLS estao separados de SQLite operacional, mas nao ha orchestrator final.
- 4: Nao implementado.
- 5: Nao implementado no loop porque mutation ainda falta.
- 6: Parcial; houve melhorias, mas taxonomia de erro ainda nao esta completa.
- 7: Parcial; SQLite audita eventos, mas replay deterministico de turno ainda nao esta completo.

Veredito:

- Ainda nao confiavel como agente coder final.
- Confiavel como base de TUI + streaming + collect_evidence auditavel em desenvolvimento.

## Mapa de alinhamento por eixo

| Eixo | TS preservado? | Falha do TS corrigida? | Novo problema no Zig? | Status |
|---|---:|---:|---:|---|
| TUI/render | Sim, em grande parte | Sim | Precisa prova visual ampla | Parcial alto |
| HTTP local | Parcial | Sim | Sem native tools/formato robusto | Parcial |
| SQLite audit | Sim | Sim | Replay ainda incompleto | Parcial alto |
| Contrato model-driven | Parcial | Sim | Sem `set_operational_contract` real | Parcial |
| Tool gate | Sim | Sim | Surface estreita demais | Parcial alto |
| collect_evidence | Parcial | Sim | Args/estagios menos ricos que TS | Parcial |
| Micro-context | Parcial | Sim | Sem patch integration | Parcial |
| Memory/SKILLS | Parcial | Parcial | Sem orchestrator final | Parcial |
| Session continuity | Sim apos T280 | Sim | Sem sumarizacao longa | Parcial |
| Mutation | Nao | Nao | Produto sem editar | Pendente |
| Validation/runtime | Parcial minimo | Parcial | Diagnostic Zig-only | Pendente |
| News/context profiles | Nao | Nao | Declarado sem executor | Pendente |
| Real test suite | Parcial | Parcial | Smokes ainda estreitos | Parcial |

## Problemas novos introduzidos pelo Zig

1. Superficie operacional estreita demais.
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

5. Smokes podem dar falso positivo.
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
2. Portar `set_operational_contract` como contrato model-visible pequeno.
3. Evoluir `collect_evidence` para aceitar `task`, `need`, `targetFiles`, `scopeRoot`, `stage`, `selectedCandidates`.
4. Criar `EvidencePacket v1` tipado com anchors, findings, obligations e next actions.
5. Implementar mutation contract com `apply_patch` + micro-context stale validation.
6. Implementar validation contract.
7. Implementar error taxonomy no SQLite.
8. Implementar replay de turno.
9. Implementar context profiles: `code_micro`, `news_table`, `document_summary`, `runtime`.
10. Portar news somente depois de context profiles.

## Criterio para dizer "alinhado"

O projeto so deve ser considerado alinhado com AUDIT/TASKS/phenom-cli-ts quando:

- Cada fluxo portado cita a referencia TS usada.
- Cada contrato model-visible tem executor real.
- Cada executor retorna evidencia destilada e auditavel.
- Nenhuma tool interna aparece ao modelo por acidente.
- Nenhum raw output aparece no contexto.
- MEMORY/SKILLS nao competem com SQLite operacional.
- Patch exige contexto fresco quando contexto foi usado.
- Validation/runtime tem falha tipada.
- News/documentos usam profiles proprios, nao code micro-context.
- Smokes reais avaliam comportamento, nao apenas marcador final.
- O SQLite permite reconstruir: prompt, modelo, contrato, tools anunciadas, calls, resultados, contexto enviado e resposta final.

## Conclusao

O `phenom-zig` esta na direcao certa como rebase baixo nivel, mas ainda nao e a versao final do Phenom. A base ficou mais segura e mais limpa que o TS em pontos especificos, mas perdeu amplitude operacional. O caminho correto nao e continuar adicionando atalhos no Zig; e portar os acertos do TS por contrato, corrigindo as falhas do AUDIT uma por uma.

Regra final desta auditoria: quando houver duvida, `phenom-cli-ts` e referencia de comportamento; `AUDIT` define o que nao repetir; `TASKS.md` define a ordem e criterios; `phenom-zig` deve implementar somente depois de cruzar os tres.
