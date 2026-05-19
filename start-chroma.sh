#!/bin/bash

# Script para iniciar ChromaDB server

echo "🚀 Iniciando ChromaDB server..."

# Verificar se ChromaDB está instalado
if ! command -v chroma &> /dev/null; then
    echo "⚠️  ChromaDB não encontrado. Instalando..."
    pip3 install chromadb
fi

# Criar diretório de dados se não existir
mkdir -p ./data/chroma

# Iniciar ChromaDB server
echo "✓ Iniciando servidor na porta 8000..."
chroma run --path ./data/chroma --port 8000 &

CHROMA_PID=$!
echo "✓ ChromaDB rodando (PID: $CHROMA_PID)"
echo $CHROMA_PID > .chroma.pid

echo ""
echo "Para parar o servidor: kill \$(cat .chroma.pid)"
