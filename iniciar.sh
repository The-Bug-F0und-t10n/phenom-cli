#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# Inicia o llama-server com o Qwen3.5-9B-Q5_K_M aplicando as mesmas regras
# e parâmetros que estavam no Modelfile do Ollama.
#
# COMO USAR:
#   1. Ajuste as 2 variáveis logo abaixo (LLAMA_SERVER e MODELO) se os
#      caminhos no seu PC forem diferentes.
#   2. Torne o script executável:   chmod +x iniciar.sh
#   3. Rode:                        ./iniciar.sh
#
# A porta 11434 é a mesma do Ollama — assim o phenom-cli-ts (npm run dev)
# conecta sem precisar mudar nada na configuração.
# ─────────────────────────────────────────────────────────────────────────

# Caminho do binário do llama-server (ajuste se o seu llama.cpp estiver em outro lugar)
LLAMA_SERVER="./llama.cpp/build/bin/llama-server"

# Caminho do arquivo .gguf do modelo (ajuste pro caminho real no seu PC)
MODELO="$HOME/models/Qwen3.5-9B.Q5_K_M.gguf"

# O regras.txt é a fonte das regras de identidade/comportamento. Elas NÃO
# são mais enviadas pelo cliente (o phenom-cli passou a mandar só o contexto
# dinâmico: cwd, projeto, plano, memória, schema de tools). As regras serão
# aplicadas no SERVIDOR via chat template do modelo — sem expor o arquivo por
# HTTP. As regras vão embutidas no chat-template.jinja (gerado a partir do
# regras.txt) e são aplicadas no servidor. Se editar regras.txt, re-sincronize
# o bloco dentro do chat-template.jinja e reinicie o servidor.
REGRAS="$(dirname "$0")/regras.txt"
TEMPLATE="$(dirname "$0")/chat-template.jinja"

# ─── Verificações básicas antes de tentar subir o servidor ───────────────

if [ ! -x "$LLAMA_SERVER" ]; then
  echo "ERRO: llama-server não encontrado ou não executável em: $LLAMA_SERVER"
  echo "Ajuste a variável LLAMA_SERVER no topo do script."
  exit 1
fi

if [ ! -f "$MODELO" ]; then
  echo "ERRO: modelo não encontrado em: $MODELO"
  echo "Ajuste a variável MODELO no topo do script."
  exit 1
fi

if [ ! -f "$REGRAS" ]; then
  echo "AVISO: $REGRAS não encontrado. O servidor sobe mesmo assim, mas o"
  echo "phenom-cli-ts vai precisar do arquivo pra montar o system prompt."
fi

# ─── Configuração explicada ──────────────────────────────────────────────
#
#   --host 127.0.0.1         só aceita conexões da própria máquina (seguro)
#   --port 11434             mesma porta padrão do Ollama (zero config no cliente)
#   -m $MODELO               arquivo .gguf do modelo
#   -a Qwen3.5-9B            alias do modelo na API: o phenom-cli-ts manda
#                            "Qwen3.5-9B" como model name nos requests, e o
#                            servidor responde sob esse nome.
#   --jinja                  habilita templates Jinja (necessário pra tool calling)
#
#   Sampling (mesmos valores do Modelfile do Ollama):
#   --temp 0.4               temperatura — baixa, determinístico pra tool args
#   --top-k 20               considera top-20 tokens em cada step
#   --top-p 0.9              nucleus sampling
#   --repeat-penalty 1.05    pena leve pra repetição
#
#   Runtime (também batendo com Modelfile):
#   -c 32768                 context window 32K (mesma coisa que num_ctx)
#   --parallel 1             1 slot só — dedica os 32K inteiros pra UMA
#                            inferência. Sem isso o default é 4 slots, cada
#                            um com 32K/4 = 8K, e tool calls com content
#                            grande são truncados no meio (erro de JSON
#                            parse mid-string).
#   -n -1                    n_predict ilimitado (até encher o contexto).
#                            Sem isso, alguns builds default pra 4096 que
#                            também corta tool calls longos.
#   -ngl 99                  -ngl -1 manda TUDO pra GPU; 99 é alias seguro
#                            (se seu hardware não couber, Ollama/llama.cpp
#                            faz partial offload automaticamente)
#   -b 512                   batch de 512 tokens (mesmo num_batch)
#   --threads 8              CPU threads (você tem i5-10400 = 6 cores / 12 threads)
#   --flash-attn             attention otimizada (menos memória, mais rápido)
#
#   KV cache em q8_0 (cabe melhor nos 8GB da RX 7600 sem perder qualidade):
#   --cache-type-k q8_0
#   --cache-type-v q8_0
#
# ─────────────────────────────────────────────────────────────────────────

echo "Iniciando llama-server..."
echo "  modelo : $MODELO"
echo "  regras : $REGRAS"
echo "  porta  : 11434"
echo ""

exec "$LLAMA_SERVER" \
  --host 127.0.0.1 \
  --port 11434 \
  -m "$MODELO" \
  -a Qwen3.5-9B \
  --jinja \
  --chat-template-file "$TEMPLATE" \
  --reasoning-format deepseek \
  --temp 0.4 \
  --top-k 20 \
  --top-p 0.9 \
  --repeat-penalty 1.05 \
  -c 32768 \
  --parallel 1 \
  -n -1 \
  -ngl 99 \
  --mlock \
  -b 512 \
  --threads 8 \
  --flash-attn \
  --cache-type-k q8_0 \
  --cache-type-v q8_0
# Notas sobre --jinja / --chat-template-file / --reasoning-format:
#   - --jinja é necessário para o servidor aceitar um template CUSTOM (sem ele,
#     só templates built-in passam na verificação).
#   - --chat-template-file aponta para o chat-template.jinja, que embute as
#     regras (server-side) e AINDA renderiza o system message do cliente (cwd,
#     tools schema etc.) — então o tool calling não quebra.
#   - --reasoning-format deepseek: extrai o <think>...</think> do modelo para o
#     campo reasoning_content. SEM isto, o default 'auto' tenta detectar pelo
#     template — e como este template é mínimo (sem a metadata de thinking do
#     Qwen), o auto NÃO extrai e o <think> vaza no content (aparece na resposta).
#     O phenom só trata reasoning quando vem em reasoning_content (api-client).
#   - Não usamos --skip-chat-parsing: em PHENOM_TOOLS_PROTOCOL=text o cliente não
#     manda `tools`, e este template não declara formato de tool — então o
#     servidor não parseia (nem trunca) tool calls; o <tool_call> fica no content
#     e o phenom parseia sozinho. O bug de truncamento do --jinja era no parsing
#     de tool calls, que aqui não acontece.
