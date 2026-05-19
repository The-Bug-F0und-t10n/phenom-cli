# Plano: Migrar para Tools Nativas do Ollama

## Contexto

O usuário solicitou que o agente seja "organicamente compatível" com o modelo, usando:
1. **Thinking nativo** - já suportado pelo ollama-client
2. **Tool calling nativo** - precisa ser implementado
3. **Serialização de output** - todo JSON convertido para output visual padronizado

## Problema Atual

- Agent usa protocolo JSON customizado `{"type":"tool","toolName":"...","args":{...}}`
- Modelo não tem suporte nativo a esse protocolo
- JSON aparece no output ao invés de ser serializado
- Thinking não aparece completamente
- Ferramentas não são assíncronas com a resposta

## Solução: Usar API Nativa do Ollama

### 1. Formato de Tools do Ollama

```typescript
{
  type: 'function',
  function: {
    name: 'write_file',
    description: 'Create NEW file with complete content',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'File path' },
        content: { type: 'string', description: 'File content' }
      },
      required: ['path', 'content']
    }
  }
}
```

### 2. Resposta do Modelo

```typescript
{
  message: {
    role: 'assistant',
    content: 'texto markdown',
    thinking: 'raciocínio interno (opcional)',
    tool_calls: [
      {
        id: 'call_123',
        type: 'function',
        function: {
          name: 'write_file',
          arguments: { path: '...', content: '...' }
        }
      }
    ]
  }
}
```

### 3. Mudanças Necessárias

#### A. ollama-client.ts
- ✅ Adicionar parâmetro `tools?: any[]` em `chat()` e `chatStream()`
- ✅ Passar tools na chamada da API
- ✅ Retornar resposta completa (não só content)

#### B. agent.ts
- Criar método `getToolDefinitions()` que converte tools do ToolSystem para formato Ollama
- Modificar `runToolLoop()` para:
  1. Passar tools na chamada do LLM
  2. Processar `message.tool_calls` ao invés de parsear JSON
  3. Adicionar mensagens com role `tool` ao histórico
- Remover `parseToolLoopResponse()` e lógica de JSON customizado
- Simplificar system prompt (sem protocolo JSON)

#### C. Serialização de Output
- Thinking: já emitido automaticamente pelo ollama-client
- Tool calls: formatar como `🔧 tool_name\n  arg: value`
- Content: renderizar markdown
- Diffs: já formatados pelas tools

### 4. Implementação

```typescript
// agent.ts - getToolDefinitions()
private getToolDefinitions(): any[] {
  return this.toolSystem.listTools().map(tool => ({
    type: 'function',
    function: {
      name: tool.name,
      description: tool.description,
      parameters: {
        type: 'object',
        properties: this.getToolParameters(tool.name),
        required: this.getRequiredParameters(tool.name)
      }
    }
  }));
}

// agent.ts - runToolLoop() simplificado
private async runToolLoop(userInput: string): Promise<string> {
  const tools = this.getToolDefinitions();
  
  for (let iteration = 0; iteration < 100; iteration++) {
    const messages = this.buildMessages(userInput);
    const response = await this.llm.chat(messages, tools);
    
    // Processar tool_calls nativos
    if (response.message.tool_calls?.length > 0) {
      for (const call of response.message.tool_calls) {
        const result = await this.executeToolWithEvents(
          call.function.name,
          call.function.arguments
        );
        
        // Adicionar resultado com role 'tool'
        this.state.addMessage({
          role: 'tool',
          tool_call_id: call.id,
          content: JSON.stringify(result),
          timestamp: Date.now()
        });
      }
      continue;
    }
    
    // Resposta final
    if (response.message.content) {
      return response.message.content;
    }
  }
}
```

### 5. Benefícios

- ✅ Thinking aparece automaticamente
- ✅ Tool calls nativos (mais confiáveis)
- ✅ Sem parsing de JSON customizado
- ✅ Compatível com padrão da indústria
- ✅ Menos código, mais simples
- ✅ Streaming funciona naturalmente

### 6. Verificação

1. Testar thinking aparecendo no output
2. Testar tool calls sendo executados
3. Testar diff colorido no write_file
4. Testar scroll incremental
5. Testar streaming fluido

## Status

- ✅ ollama-client.ts modificado
- ⏳ agent.ts precisa ser refatorado
- ⏳ Definir schema de parâmetros das tools
- ⏳ Testar integração completa
