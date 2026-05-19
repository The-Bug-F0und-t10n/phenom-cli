# Usage

## Modos

- `fast`: resposta direta e baixa latência
- `reasoning`: planejamento e execução passo a passo
- `assistant`: resposta com ferramentas sob demanda
- `plan`: gera plano sem executar

## CLI

```bash
npm run dev chat
npm run dev run "investigue este erro"
npm run dev search "intent extractor"
npm run dev topics
```

## Comandos no chat

- `/mode fast|reasoning|assistant|plan`
- `/search <query>`
- `/topics`
- `/reset`
- `/exit`

## Fluxos úteis

1. Debug local
```text
/mode reasoning
encontre a causa do timeout no agente
```

2. Consulta rápida
```text
/mode fast
liste os arquivos do diretório atual
```

3. Contexto de sessão
```text
salve como regra: nunca reescrever arquivo inteiro
/topics
```
