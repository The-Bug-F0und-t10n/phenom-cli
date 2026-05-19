#!/bin/bash

# Script de setup para o Phenom CLI

echo "🚀 Configurando Phenom CLI..."

# Verificar Node.js
if ! command -v node &> /dev/null; then
    echo "❌ Node.js não encontrado. Instale Node.js 18+ primeiro."
    exit 1
fi

echo "✓ Node.js encontrado: $(node --version)"

# Verificar Ollama
if ! command -v ollama &> /dev/null; then
    echo "⚠️  Ollama não encontrado no PATH"
    echo "   Certifique-se que está rodando em inference.local:11434"
else
    echo "✓ Ollama encontrado"
fi

# Instalar dependências
echo ""
echo "📦 Instalando dependências..."
npm install

# Criar diretórios necessários
echo ""
echo "📁 Criando diretórios..."
mkdir -p data/chroma
mkdir -p logs

# Copiar .env se não existir
if [ ! -f .env ]; then
    echo ""
    echo "📝 Criando arquivo .env..."
    cp .env.example .env
    echo "✓ Arquivo .env criado. Ajuste as configurações se necessário."
else
    echo "✓ Arquivo .env já existe"
fi

# Build
echo ""
echo "🔨 Compilando TypeScript..."
npm run build

echo ""
echo "✅ Setup concluído!"
echo ""
echo "Para começar:"
echo "  npm run dev chat          # Chat interativo"
echo "  npm run dev run \"query\"   # Comando único"
echo "  npm run dev config        # Ver configuração"
echo ""
