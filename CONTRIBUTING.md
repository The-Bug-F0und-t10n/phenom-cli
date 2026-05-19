# Contributing

## Fluxo recomendado

1. Crie branch de trabalho
2. Faça mudanças pequenas e testáveis
3. Execute:

```bash
npm run build
npm test
```

4. Abra PR com contexto e impacto

## Padrões

- TypeScript estrito
- Sem reescrever arquivo inteiro quando editar arquivo existente
- Preferir mudanças mínimas e explícitas
- Evitar código morto e utilitários não usados

## Onde alterar

- Tools: `src/tools.ts`
- Fluxo do agente: `src/agent.ts`
- Memória de sessão: `src/session-context.ts`
- Config: `src/config.ts`

## Checklist de PR

- [ ] Build passa
- [ ] Testes passam
- [ ] Docs atualizadas quando necessário
- [ ] Sem regressão de latência em fast mode
