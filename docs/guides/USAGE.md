# Usage

## Modos

- `fast`: resposta direta e baixa latência
- `reasoning`: planejamento e execução passo a passo
- `assistant`: resposta com ferramentas sob demanda
- `plan`: gera plano sem executar
- `code_assistant`: modo padrão para coding/debug
- `jarvis`: modo orientado a autonomia controlada

## CLI

```bash
npm run dev chat
npm run dev run "investigue este erro"
npm run dev config
npm run tui
```

## Comandos no chat

- `/mode fast|reasoning|assistant|plan|code_assistant|jarvis`
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
