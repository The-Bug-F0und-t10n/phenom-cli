#!/bin/bash

# Quick start script

echo "🚀 Phenom CLI - Quick Start"
echo ""

# Check if setup was run
if [ ! -d "node_modules" ]; then
    echo "📦 Primeira execução detectada. Executando setup..."
    ./setup.sh
fi

# Check if .env exists
if [ ! -f ".env" ]; then
    echo "📝 Criando .env..."
    cp .env.example .env
fi

# Start chat
echo ""
echo "🎯 Iniciando chat interativo..."
echo ""
npm run dev chat
