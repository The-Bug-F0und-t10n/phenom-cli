#!/bin/bash

# Teste Simplificado - Sem ChromaDB

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║           TESTE SIMPLIFICADO - PHENOM CLI v1.1.0                    ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Verificar Ollama
echo "🔍 Verificando Ollama..."
if ! curl -s http://inference.local:11434/api/tags > /dev/null 2>&1; then
    echo "❌ Ollama não acessível"
    exit 1
fi
echo "✅ Ollama conectado"
echo ""

# Criar projeto de teste
TEST_DIR="/tmp/finance-simple"
echo "📁 Criando projeto: $TEST_DIR"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Teste direto com curl (sem ChromaDB)
echo "═══════════════════════════════════════════════════════════════════════"
echo "TESTE 1: Criar package.json"
echo "───────────────────────────────────────────────────────────────────────"

RESPONSE=$(curl -s http://inference.local:11434/api/generate -d '{
  "model": "qwen2.5-coder:7b-instruct-q4_K_M",
  "prompt": "Crie um package.json para um projeto de finanças pessoais com Node.js, Express e TypeScript. Responda APENAS com o JSON, sem explicações.",
  "stream": false,
  "options": {
    "num_gpu": 5,
    "num_ctx": 2048,
    "temperature": 0.7
  }
}')

echo "$RESPONSE" | jq -r '.response' > package.json

if [ -f package.json ]; then
    echo "✅ package.json criado"
    cat package.json | head -20
else
    echo "❌ Falha ao criar package.json"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "TESTE 2: Criar servidor Express"
echo "───────────────────────────────────────────────────────────────────────"

RESPONSE=$(curl -s http://inference.local:11434/api/generate -d '{
  "model": "qwen2.5-coder:7b-instruct-q4_K_M",
  "prompt": "Crie um arquivo server.js com Express básico na porta 3000. Responda APENAS com o código JavaScript, sem explicações.",
  "stream": false,
  "options": {
    "num_gpu": 5,
    "num_ctx": 2048,
    "temperature": 0.7
  }
}')

echo "$RESPONSE" | jq -r '.response' > server.js

if [ -f server.js ]; then
    echo "✅ server.js criado"
    cat server.js | head -20
else
    echo "❌ Falha ao criar server.js"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "RELATÓRIO FINAL"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Arquivos criados:"
ls -lh
echo ""
echo "✅ Teste concluído!"
echo "📂 Projeto em: $TEST_DIR"
echo ""
