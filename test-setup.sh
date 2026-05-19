#!/bin/bash

# Script de teste rápido do Phenom CLI

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           TESTE RÁPIDO - PHENOM CLI COM RAG                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# 1. Verificar ambiente
echo "📋 Passo 1: Verificando ambiente..."
./check-env.sh
echo ""

# 2. Testar agente sem RAG
echo "🤖 Passo 2: Testando agente sem RAG..."
echo "   Executando: npm run dev config"
npm run dev config
echo ""

# 3. Instruções para habilitar RAG
echo "📚 Passo 3: Para habilitar RAG (opcional):"
echo ""
echo "   a) Instalar ChromaDB:"
echo "      pip3 install chromadb"
echo ""
echo "   b) Iniciar servidor:"
echo "      npm run chroma:start"
echo ""
echo "   c) Verificar se está rodando:"
echo "      curl http://localhost:8000/api/v1/heartbeat"
echo ""
echo "   d) Testar novamente:"
echo "      npm run dev chat"
echo ""

# 4. Comandos úteis
echo "💡 Comandos úteis:"
echo ""
echo "   Iniciar chat:        npm run dev chat"
echo "   Executar comando:    npm run dev run \"sua pergunta\""
echo "   Indexar código:      npm run dev index /caminho"
echo "   Buscar no código:    npm run dev search \"query\""
echo "   Ver configuração:    npm run dev config"
echo ""
echo "   Iniciar ChromaDB:    npm run chroma:start"
echo "   Parar ChromaDB:      npm run chroma:stop"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    TESTE CONCLUÍDO ✅                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
