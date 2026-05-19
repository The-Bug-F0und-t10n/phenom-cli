#!/bin/bash

# Script de demonstração do Phenom CLI

echo "🎬 Demonstração do Phenom CLI"
echo "=============================="
echo ""

# Verificar se está configurado
if [ ! -f .env ]; then
    echo "❌ Arquivo .env não encontrado. Execute ./setup.sh primeiro."
    exit 1
fi

echo "📋 Configuração atual:"
npm run dev config
echo ""

echo "Pressione ENTER para continuar..."
read

echo ""
echo "🧪 Executando testes..."
npm run dev -- tsx src/test.ts
echo ""

echo "Pressione ENTER para continuar..."
read

echo ""
echo "💬 Exemplo 1: Modo Fast (resposta rápida)"
echo "Query: 'O que é TypeScript?'"
echo ""
npm run dev run "O que é TypeScript?" -- -m fast
echo ""

echo "Pressione ENTER para continuar..."
read

echo ""
echo "💬 Exemplo 2: Modo Deep (com planejamento)"
echo "Query: 'Explique o padrão Observer'"
echo ""
npm run dev run "Explique o padrão Observer" -- -m deep
echo ""

echo "Pressione ENTER para continuar..."
read

echo ""
echo "🔍 Exemplo 3: Busca de código"
echo "Indexando diretório src/..."
npm run dev index ./src
echo ""
echo "Buscando: 'função de estado'"
npm run dev search "função de estado"
echo ""

echo "Pressione ENTER para continuar..."
read

echo ""
echo "✅ Demonstração concluída!"
echo ""
echo "Para usar o chat interativo:"
echo "  npm run dev chat"
echo ""
echo "Comandos disponíveis no chat:"
echo "  /mode fast|deep  - Altera modo"
echo "  /index <path>    - Indexa repositório"
echo "  /search <query>  - Busca código"
echo "  /reset           - Reseta sessão"
echo "  /exit            - Sai"
echo ""
