# Architecture

## Runtime atual (fonte de verdade)

### Fluxo principal

1. CLI (`src/index.ts`) recebe input/comandos.
2. `Agent.processInput()` inicia ciclo de execução.
3. `Agent.runToolLoop()` executa iterações de inferência + tools.
4. `OllamaClient` faz streaming/chat e usa `ApiClient` para `/v1/chat/completions` com fallback para `/api/chat`.
5. `ToolSystem` executa ferramentas locais (fs/git/shell/search/web).
6. Estado e memória são persistidos em `SessionState` + `SessionBrain`.
7. Eventos de UI/telemetria fluem via `EventBus` para renderizadores CLI/TUI.

### Tool-calling

1. Caminho primário: tool-calls nativos vindos do stream.
2. Caminho fallback: parsing de resposta textual para protocolo tool/final em `src/tool-call-parser.ts`.
3. Resultado de tool é reinjetado no contexto:
   - `role: tool` no caminho nativo.
   - `role: user` (mensagem estruturada) no fallback JSON.

### Componentes principais

1. `src/agent.ts` — orquestração de ciclo.
2. `src/use-cases/*` — casos de uso extraídos (`run-tool-loop`, `build-inference-messages`, `tool-execution-policy`, `execute-tool-with-events`).
3. `src/ollama-client.ts` — adapter de alto nível para inferência.
4. `src/api-client.ts` — cliente HTTP streaming/non-streaming.
5. `src/tools.ts` — registry/execução de tools.
6. `src/state.ts` — memória operacional curta.
7. `src/session-brain.ts` — memória persistente de sessão/plano.
8. `src/cli-renderer.ts` e `src/tui/*` — interface de saída.

## Estado da refatoração

O roadmap incremental em andamento está documentado em:

- [docs/REFATORACAO_DEVLOG.md](/home/ashirak/Projects/person/ai/cli-ai/phenom-cli-ts/docs/REFATORACAO_DEVLOG.md)
- [docs/CLEAN_ARCH_AUDIT_PLAN.md](/home/ashirak/Projects/person/ai/cli-ai/phenom-cli-ts/docs/CLEAN_ARCH_AUDIT_PLAN.md)
- [docs/TESTING.md](/home/ashirak/Projects/person/ai/cli-ai/phenom-cli-ts/docs/TESTING.md)
