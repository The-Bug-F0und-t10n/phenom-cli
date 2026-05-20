# FAQ

## Qual modo devo usar?

- `fast` para perguntas curtas
- `reasoning` para implementação/debug/refatoração
- `assistant` para respostas com assistência geral
- `plan` para planejar antes de executar
- `code_assistant` para tarefas de código (modo padrão)
- `jarvis` para operação com mais autonomia

## Como alternar modo no chat?

Use:

```text
/mode reasoning
```

## Como resetar estado da sessão?

```text
/reset
```

## Timeout no agente: o que fazer?

1. Rode `npm run test:core`
2. Use `MODE=fast` para diagnósticos iniciais
3. Verifique conectividade e carga do Ollama

## Como validar mudanças no projeto?

```bash
npm run build
npm run test:core
```
