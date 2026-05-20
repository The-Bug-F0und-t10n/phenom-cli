# Modelfile — phenom

## O que é

O `Modelfile` (na raiz do projeto) define o modelo `phenom` no Ollama. Ele encapsula três camadas:

1. **Base**: o modelo quantizado de origem.
2. **Comportamento**: regras de como o modelo deve trabalhar — baked no TEMPLATE, não no código TypeScript.
3. **Parâmetros de sampling**: ajustados para geração de código e tool calls.

## Por que o comportamento fica no TEMPLATE, não no SYSTEM

O Ollama possui dois mecanismos de system prompt:

| Mecanismo | Quando é aplicado |
|---|---|
| `SYSTEM` no Modelfile | Padrão para `ollama run`. Substituído quando a API envia uma mensagem `system`. |
| Texto hardcoded no `TEMPLATE` | Sempre injetado, em toda requisição, antes de qualquer coisa da API. |

O agente sempre envia sua própria mensagem `system` (com contexto de sessão dinâmico). Se o comportamento estivesse no `SYSTEM` do Modelfile, seria descartado a cada requisição do agente.

Ao colocar as regras de comportamento diretamente no bloco `<|im_start|>system` do `TEMPLATE`, elas são injetadas antes do `{{ .System }}` da API. O resultado final na janela de contexto é:

```
<|im_start|>system
[comportamento hardcoded do TEMPLATE — sempre presente]

[contexto dinâmico enviado pelo agente via API]
<|im_end|>
```

## Divisão de responsabilidades

### Modelfile TEMPLATE (estático, imutável por sessão)

- Identidade: "Você é Phenom, assistente de coding/debug"
- Como trabalhar: fluxo de bug → grep → read → patch → verify
- Regras de navegação: nunca ler arquivo inteiro com linha já conhecida
- Comportamento padrão: não narrar, chamar tool, reportar depois

### `buildSystemPrompt()` em `src/agent.ts` (dinâmico, por sessão)

- Working directory atual
- Sinais de projeto detectados (Node.js, TypeScript, etc.)
- Contexto de sessão (plano ativo, arquivos modificados)
- Lista de tools disponíveis (registro runtime)
- Protocolo de tool call (nativo vs JSON — depende das capacidades do modelo)

## Criar ou atualizar o modelo

```bash
ollama create phenom -f Modelfile
```

## Parâmetros de sampling

| Parâmetro | Valor | Motivo |
|---|---|---|
| `temperature` | 0.6 | Reduz ruído sem travar a criatividade. Original era 1.0 — alto demais para JSON estruturado. |
| `top_k` | 20 | Foco no núcleo de tokens prováveis. Bom para modelos com thinking — a fase de raciocínio já explora. |
| `top_p` | 0.9 | Corta a cauda de tokens improváveis. |
| `repeat_penalty` | 1.05 | Penalidade leve contra repetição verbatim. |
| `presence_penalty` | 0 | **Crítico: deve ser 0.** Valor alto (ex: 1.5) penaliza tokens já vistos no contexto — destrói tool calls JSON porque chaves como `"type"`, `"args"`, `"path"` aparecem constantemente e são penalizadas. |
| `num_ctx` | 32768 | Janela prática para sessões de coding com resultados de tools. Sobrescrito por `OLLAMA_NUM_CTX`. |

## Template ChatML

O template implementa o formato ChatML do Qwen3.5 com suporte a:

- **Thinking**: o modelo gera `<think>...</think>` no output; o `PARSER qwen3.5` extrai e expõe via callback de reasoning.
- **Native tool calls**: quando tools são enviadas via API, o bloco `{{ .Tools }}` formata as assinaturas e instrui o modelo a responder com `<tool_call>` XML.
- **Multi-turn**: mensagens de `user`, `assistant` e `tool` são formatadas com os tokens especiais `<|im_start|>` / `<|im_end|>`.

## Protocolo de tool call no agente

Para modelos **com** suporte a native tools (ex: `phenom`):
- Tools são enviadas via parâmetro `tools` da API.
- O modelo responde com `tool_calls` no formato OpenAI.
- A resposta final é plain text.

Para modelos **sem** suporte a native tools:
- Tools são listadas em texto no system prompt.
- O modelo responde com JSON: `{"type":"tool","toolName":"...","args":{...}}`
- A resposta final é plain text (sem wrapper JSON).

O wrapper `{"type":"final","content":"..."}` foi removido do protocolo pois modelos locais produzem JSON malformado com frequência, fazendo o parser descartar respostas válidas.
