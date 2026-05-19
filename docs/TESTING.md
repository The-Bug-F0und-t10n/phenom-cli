# Testing Strategy

## Objetivo

Separar validação determinística de regressão (offline) da validação dependente de infraestrutura Ollama (online).

## Suites

1. `npm run test:offline`
   - Alias de `test:core`.
   - Não depende de servidor Ollama ativo.
   - Inclui parser fallback, use-cases, registrars, stream parser, capabilities e fixtures Qwen/Ollama.

2. `npm run test:online`
   - Alias de `test:real`.
   - Exige Ollama acessível e modelo configurado.
   - Valida inferência real ponta a ponta.

## Critério mínimo para merge

1. `npm run build` verde.
2. `npm run test:offline` verde.
3. Quando houver mudança em integração de modelo/tool-call: `npm run test:online` verde em ambiente com Ollama disponível.
