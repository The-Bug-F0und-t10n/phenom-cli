#!/bin/bash

# Script de verificação do ambiente

echo "🔍 Verificando ambiente Phenom CLI..."
echo ""

# Verificar Node.js
if command -v node &> /dev/null; then
    echo "✓ Node.js: $(node --version)"
else
    echo "✗ Node.js não encontrado"
fi

# Verificar npm
if command -v npm &> /dev/null; then
    echo "✓ npm: $(npm --version)"
else
    echo "✗ npm não encontrado"
fi

# Verificar Python
if command -v python3 &> /dev/null; then
    echo "✓ Python: $(python3 --version)"
else
    echo "✗ Python não encontrado"
fi

# Verificar pip
if command -v pip3 &> /dev/null; then
    echo "✓ pip: $(pip3 --version | cut -d' ' -f1-2)"
else
    echo "✗ pip não encontrado"
fi

echo ""
echo "🔍 Verificando dependências..."

# Carregar .env local se existir
if [ -f ".env" ]; then
    set -a
    source ./.env
    set +a
fi

normalize_ollama_host() {
    local host="$1"
    host="${host%/}"
    host="${host%/api/chat}"
    host="${host%/api/generate}"
    host="${host%/api/embeddings}"
    host="${host%/api/embed}"
    host="${host%/api/tags}"
    host="${host%/api}"
    host="${host%/v1/chat/completions}"
    host="${host%/v1/completions}"
    host="${host%/v1/embeddings}"
    host="${host%/v1}"
    printf '%s' "$host"
}

OLLAMA_BASE="$(normalize_ollama_host "${OLLAMA_HOST:-http://inference.local:11434}")"

# Verificar ChromaDB
if pip3 list 2>/dev/null | grep -q chromadb; then
    echo "✓ ChromaDB instalado"
else
    echo "⚠️  ChromaDB não instalado (execute: pip3 install chromadb)"
fi

# Verificar se ChromaDB está rodando
if curl -s http://localhost:8000/api/v1/heartbeat &> /dev/null; then
    echo "✓ ChromaDB server rodando"
else
    echo "⚠️  ChromaDB server não está rodando (execute: npm run chroma:start)"
fi

# Verificar Ollama
if curl -s "$OLLAMA_BASE/api/tags" &> /dev/null; then
    echo "✓ Ollama conectado"
else
    echo "⚠️  Ollama não acessível em $OLLAMA_BASE"
fi

echo ""
echo "📦 Verificando build..."

if [ -d "dist" ]; then
    echo "✓ Projeto compilado"
else
    echo "⚠️  Projeto não compilado (execute: npm run build)"
fi

echo ""
echo "✅ Verificação concluída!"
echo ""
echo "Para iniciar: npm run dev chat"
