# FAQ

## Qual modo devo usar?

- `fast` para perguntas curtas
- `reasoning` para implementação/debug/refatoração
- `assistant` para respostas com pesquisa pontual
- `plan` para só planejar

## Como listar topics da sessão?

Use:

```bash
npm run dev topics
```

ou no chat:

```text
/topics
```

## Onde ficam instruções/regras do usuário?

No arquivo `data/session-context.json`, por tópico.

## O sistema consulta prompts anteriores?

Sim. A recuperação usa `ripgrep` no armazenamento de sessão quando há relação com o contexto atual.

## Timeout no agente: o que fazer?

1. Rode `npm test`
2. Use `MODE=fast` para diagnósticos iniciais
3. Verifique conectividade e carga do Ollama

## Como validar mudanças no projeto?

```bash
npm run build
npm test
```
