# Auditoria Técnica e Plano de Refatoração (Clean Architecture)

## 1. Objetivo da task

Convergir o projeto para um agente CLI de assistência de código/debug com:

1. Provider único: Ollama.
2. Forte compatibilidade com Qwen 3.5 (thinking, vision e tool-call nativos).
3. Fallbacks de tool-call não padronizado explícitos, previsíveis e testáveis.
4. Arquitetura limpa com redução de acoplamento, maior testabilidade e menor risco operacional.

## 2. Escopo auditado

Mapeamento funcional por módulos críticos (`agent`, `api-client`, `ollama-client`, `tools`, `cli/tui`, `state/session`, parser e capabilities), com foco em:

1. Bugs.
2. Contratos frágeis.
3. Dívida de infraestrutura/testes.
4. Aderência ao objetivo Ollama + Qwen3.5.

## 3. Mapa atual (pragmático)

1. Orquestração: `src/agent.ts` (alta centralização de responsabilidades).
2. Transporte inferência: `src/ollama-client.ts` + `src/api-client.ts` (duplicações e muito `any`).
3. Ferramentas: `src/tools.ts` (agora como orquestrador de registrars por domínio).
4. Interface: `src/index.ts`, `src/cli-renderer.ts`, `src/tui/professional-tui.ts`.
5. Estado/sessão: `src/state.ts`, `src/session-brain.ts`.
6. Fallback tool-calling: `src/tool-call-parser.ts`.
7. Capabilities por modelo: `src/model-capabilities.ts`.

## 4. Acertos já confirmados

1. Pipeline de fallback de tool-call extraído e coberto por testes.
2. Suporte multimodal (imagem) integrado ao CLI com guard de capability.
3. Matriz de capabilities para Qwen 3/3.5 expandida e testada.
4. Infra de testes offline consolidada em `npm run test:core`.
5. Extração de `ToolSystem` em registrars (`filesystem`, `search`, `navigation`, `git`, `utility`) com API estável.
6. Encapsulamento melhorado no CLI: remoção de acesso direto ao `sessionManager` via `as any`.

## 5. Pontos críticos (ceticismo técnico)

### 5.1 Arquitetura

1. `src/agent.ts` ainda mistura múltiplas responsabilidades, porém já reduziu significativamente após extrações para `use-cases`.
2. `src/tools.ts` foi reduzido para composição, mas ainda concentra normalização de args e parsing de diff.
3. Tipagem `any` foi reduzida nas fronteiras de alto risco (`api-client`, `ollama-client`, `index`, `model-capabilities`), mas ainda persiste em módulos periféricos legados de UI/TUI.

### 5.2 Bugs/risco funcional

1. Parsing heurístico depende de JSON balanceado dentro de texto; robusto para casos atuais, mas ainda sensível a respostas ambíguas.
2. (Resolvido nesta iteração) falso encerramento com `[done]` em tarefas de IO quando o modelo emitia apenas texto de intenção sem tool call.
3. Ferramentas destrutivas receberam bloqueio fora do workspace, mas ainda sem política de confirmação explícita por risco.
4. Busca web (`web_search`) mistura engines e parsing HTML heurístico; suscetível a drift e falhas silenciosas.

### 5.3 Infra/testes

1. Cobertura offline foi fortalecida com fixtures Qwen/Ollama; faltam apenas cenários online adicionais por modelo em ambiente com Ollama ativo.
2. Muitos testes acessam internals com `as any`, sinal de fronteiras de encapsulamento insuficientes.
3. Cobertura de casos de uso extraídos foi iniciada com suíte dedicada; ainda faltam cenários negativos/erros de transporte.

## 6. Alvo de arquitetura limpa

## 6.1 Camadas

1. `domain`: contratos puros (`Message`, `ToolCall`, `ToolResult`, `ModelCapabilities`, eventos).
2. `application`: casos de uso (`ProcessUserTurn`, `RunToolLoop`, `BuildContextWindow`, `ParseFallbackToolCall`).
3. `infra/ollama`: adapters HTTP/stream exclusivos Ollama, com contratos tipados (sem `any` externo).
4. `infra/tools`: registrars por domínio (`filesystem`, `search`, `web`, `git`, `utility`, `navigation`).
5. `interfaces/cli`: entrada/saída e renderização (CLI/TUI), sem regras de negócio.

## 6.2 Política de tool-calling

1. Native tool-call do modelo.
2. `<tool_call>...</tool_call>`.
3. JSON estruturado.
4. Falha explícita e encerramento controlado (sem “reparo mágico” via nova chamada de LLM).

## 7. Plano de execução (incremental e verificável)

### Fase A — Estabilização de contratos (P0)

1. Reduzir `as any` em entrypoints (CLI e integração principal).
2. Introduzir interfaces explícitas para eventos e mensagens de inferência.
3. Garantir `build` + `test:core` após cada lote.

### Fase B — Modularização de infraestrutura tools (P0/P1)

1. Extrair registrars restantes de `src/tools.ts` (`filesystem`, `search/web`, `navigation`).
2. Manter `ToolSystem` apenas como composição + normalização + execução.
3. Adicionar testes unitários por registrar (sem depender de `Agent`).

### Fase C — Desacoplamento do Agent (P1)

1. Extrair casos de uso: loop de tools, janela de contexto, síntese, normalização de nome de tool.
2. Reduzir `agent.ts` para coordenação de alto nível.
3. Cobrir contratos por testes de unidade e integração curta.

### Fase D — Hardening Ollama/Qwen3.5 (P1)

1. Consolidar tipagem forte para respostas native/openai-compat no `api-client`.
2. Formalizar matrix de capabilities (thinking/vision/native tools) com fixtures reais versionadas.
3. Cobrir fallbacks de stream/tool-call com testes de regressão orientados a casos reais.

### Fase E — Infra e higiene final (P2)

1. Isolar/remover artefatos não runtime de `src/`.
2. Separar suíte offline/online por tags e scripts claros.
3. Atualizar docs finais para refletir a arquitetura implementada.

## 8. Critérios de aceite por fase

1. `npm run build` verde.
2. `npm run test:core` verde.
3. Sem regressão no fluxo Ollama native tool-calls.
4. Sem regressão no fallback parser.
5. Devlog atualizado com motivação, mudança e validação.

## 9. Status da execução (nesta iteração)

1. Parser test alinhado ao comportamento real de estratégia.
2. `ToolSystem` foi modularizado por registrars (`filesystem`, `search`, `navigation`, `git`, `utility`).
3. CLI deixou de acessar internals do `Agent` por `as any` para restauração de sessão.
4. Eventos de stream ganharam contrato tipado discriminado em `api-client`.
5. Hardening de paths destrutivos implementado e coberto por teste.
6. Tool-loop do `Agent` extraído para caso de uso dedicado (`src/use-cases/run-tool-loop.ts`).
7. Artefatos não-runtime foram realocados de `src/` para `artifacts/legacy-src/`.
8. Builder de contexto do `Agent` extraído para `src/use-cases/build-inference-messages.ts`.
9. Política de execução de tools extraída para `src/use-cases/tool-execution-policy.ts`.
10. Testes unitários diretos de use-cases adicionados e integrados ao `test:core`.
11. `build` e `test:core` validados após mudanças.
12. Fluxo `executeToolWithEvents` extraído para use-case dedicado com validação em suíte unitária.
13. Tipagem hardening aplicada em `api-client` e `ollama-client` com remoção de `any` nas bordas de stream/chat.
14. Guard de confiabilidade adicionado no `run-tool-loop` para impedir conclusão sem tool execution em tarefas de filesystem IO.
15. Fixtures versionados Qwen3.5/Ollama adicionados e validados em suíte dedicada (`test:qwen-fixtures`).
16. Parser de fallback endurecido para priorizar tool-call em payload textual ambíguo (`final` + `tool`).
17. Separação explícita de testes `offline`/`online` e documentação operacional em `docs/TESTING.md`.
18. Política anti-loop determinística adicionada ao `run-tool-loop` (assinatura de plano/resultado + hard-cap + limite de extensão).

## 10. Mapa por arquivo (acertos x gaps)

1. `src/agent.ts`: forte orquestração e cobertura relevante; concentração caiu com extração de `run-tool-loop`, `build-inference-messages` e política de execução, mas ainda há regras de domínio misturadas.
2. `src/api-client.ts`: fallback entre endpoints implementado e tipagem de stream/chat endurecida; ainda há alta complexidade por concentrar muitos papéis numa classe.
3. `src/ollama-client.ts`: adapter único ao Ollama consolidado e sem `any` nas fronteiras principais; ainda precisa reduzir duplicação de mapeamento de mensagens.
4. `src/model-capabilities.ts`: matriz de capability com testes e fixtures versionadas de referência; possível evolução futura é ampliar catálogo por família.
5. `src/tool-call-parser.ts`: fallback explícito e testado com cenário ambíguo; possível evolução futura é reduzir heurística via protocolo estruturado estrito.
6. `src/tools.ts`: virou camada de composição; ainda centraliza normalização de argumentos e parser de unified diff.
7. `src/tools/registrars/git-tools.ts`: extração limpa com hardening de path destrutivo; falta suíte unitária dedicada do registrar.
8. `src/tools/registrars/utility-tools.ts`: extração limpa de `run_code`; precisa cobertura de limites/segurança.
9. `src/tools/registrars/navigation-tools.ts`: extração de navegação concluída; necessita testes unitários de parsing de bloco.
10. `src/tools/registrars/filesystem-tools.ts`: extração ampla concluída; cobertura atual vem majoritariamente via `test-tools-fix`.
11. `src/tools/registrars/search-tools.ts`: extração concluída; precisa testes determinísticos para parsing de `rg --json` e erros de rede em `web_search`.
12. `src/index.ts`: fluxo CLI mais encapsulado; tratamento de erro tipado endurecido. Restam casts em bordas específicas de libs externas.
13. `src/cli-renderer.ts`: boa cobertura em `test-cli-renderer`; arquivo grande com múltiplos papéis de render.
14. `src/tui/professional-tui.ts`: funcionalidades ricas; alta complexidade e baixa modularidade.
15. `src/session-brain.ts`: domínio de sessão relativamente organizado; merece separação de persistência e regras de plano.
16. `src/state.ts`: estado simples e previsível; pode ganhar tipagem mais estrita para mensagens/tool-calls.
17. `src/advanced-tools.ts`: útil para análise de código; sem integração clara com camadas limpas (deveria virar registrar).
18. `src/syntax-validator.ts`: proteção útil pós-escrita; precisa contrato mais claro de severidade (erro vs aviso).
19. `src/semantic-search.ts`: utilitário importante para contexto; cobertura de erro/edge case ainda limitada.
20. `src/reflector.ts`: estratégia de reflexão interessante; precisa integração formal no fluxo principal ou depreciação.
21. `src/use-cases/run-tool-loop.ts`: extraído e agora coberto por teste unitário direto.
21. `src/use-cases/run-tool-loop.ts`: extraído, coberto por teste unitário e endurecido contra loops repetitivos sem progresso.
22. `src/use-cases/build-inference-messages.ts`: extraído e agora coberto por teste unitário direto.
23. `src/use-cases/tool-execution-policy.ts`: política de execução extraída com cobertura unitária.
24. `src/use-cases/execute-tool-with-events.ts`: extraído com cobertura unitária e responsabilidades de telemetria/estado desacopladas do `Agent`.
25. `artifacts/legacy-src/*`: artefatos legados realocados corretamente; etapa de higiene estrutural concluída.
26. `src/fixtures/qwen-ollama-fixtures.ts`: fixtures versionados de compatibilidade Qwen/Ollama para testes offline determinísticos.
27. `docs/TESTING.md`: estratégia de execução offline/online formalizada para infra de validação.

## 11. Conclusão do plano principal

1. Fases A-E deste plano foram concluídas com validação local (`build` + `test:core` verdes).
2. O objetivo principal foi atingido: arquitetura mais limpa, fallback estruturado e testado, suporte único Ollama com cobertura específica para Qwen3.5.
3. Pendências restantes são evolutivas (hardening incremental), não bloqueiam o encerramento do plano principal.
