#!/bin/bash

# Script para parar ChromaDB server

if [ -f .chroma.pid ]; then
    PID=$(cat .chroma.pid)
    echo "🛑 Parando ChromaDB (PID: $PID)..."
    kill $PID 2>/dev/null
    rm .chroma.pid
    echo "✓ ChromaDB parado"
else
    echo "⚠️  Nenhum processo ChromaDB encontrado"
fi
