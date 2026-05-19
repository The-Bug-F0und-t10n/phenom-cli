#!/bin/bash

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║           TESTE DIRETO - PHENOM CLI v1.1.0                           ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Criar projeto
TEST_DIR="/tmp/finance-direct"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "📁 Projeto: $TEST_DIR"
echo ""

# Teste 1: Gerar código com Ollama
echo "═══════════════════════════════════════════════════════════════════════"
echo "TESTE 1: Gerar package.json"
echo "───────────────────────────────────────────────────────────────────────"

curl -s http://inference.local:11434/api/generate -d '{
  "model": "qwen2.5-coder:7b-instruct-q4_K_M",
  "prompt": "Crie um package.json válido para projeto Node.js com Express. Responda APENAS o JSON.",
  "stream": false,
  "options": {"num_gpu": 5, "num_ctx": 1024}
}' | python3 -c "import sys, json; print(json.load(sys.stdin)['response'])" > package.json

echo "✅ Gerado"
echo "Conteúdo:"
cat package.json
echo ""

# Teste 2: Criar servidor
echo "═══════════════════════════════════════════════════════════════════════"
echo "TESTE 2: Gerar server.js"
echo "───────────────────────────────────────────────────────────────────────"

curl -s http://inference.local:11434/api/generate -d '{
  "model": "qwen2.5-coder:7b-instruct-q4_K_M",
  "prompt": "Crie um servidor Express básico em JavaScript na porta 3000. Responda APENAS o código.",
  "stream": false,
  "options": {"num_gpu": 5, "num_ctx": 1024}
}' | python3 -c "import sys, json; print(json.load(sys.stdin)['response'])" > server.js

echo "✅ Gerado"
echo "Conteúdo:"
cat server.js
echo ""

# Relatório
echo "═══════════════════════════════════════════════════════════════════════"
echo "RELATÓRIO"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "Arquivos criados:"
ls -lh
echo ""
echo "✅ Teste concluído!"
echo "📂 Projeto em: $TEST_DIR"
