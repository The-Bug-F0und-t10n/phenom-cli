# Ollama Run Style Agent - Arquitetura

## Filosofia

O `ollama run` é simples, direto e rápido porque:
1. Não impõe protocolo artificial ao modelo
2. Não tem "agent loop" complexo
3. Não adiciona overhead de parsing/repair

## Problema Atual

O agente atual tem:
- Protocolo JSON manual que o modelo não segue consistentemente
- Loop de repair que polui o contexto
- Crescimento exponencial de mensagens de sistema
- Overhead de parsing em cada iteração

## Solução Proposta

### Modo Dual:
1. **Modo Agent** - Usa native tool calls do Ollama (mais robusto)
2. **Modo Direct** - Like `ollama run`, modelo gera comandos shell/scripts diretamente

### Implementação:

```typescript
// Modo 1: Direct (ollama run style)
// O modelo gera texto livre, agente executa commands shell direta

// Modo 2: Agent com native tools
// Usa tool_calls nativo do Ollama (mais confiável que JSON manual)
```

## Diferenças Chave

| Aspecto | Atual | Proposto |
|---------|-------|----------|
| Protocolo | JSON manual | Native tool calls ou direct |
| Loop repair | Sim, polui contexto | Removido |
| Mensagens sistema | A cada iteração | Apenas no início |
| Context growth | Linear+exponencial | Limitado |
| Parsing | JSON manual | Native Ollama |

## Prioridades

1. **Remover loop de repair** - Causa confusão
2. **Usar native tool calls** - Mais confiável que JSON manual
3. **Limitar crescimento de contexto** - Manter performance
4. **Modo direct opcional** - Para tasks simples