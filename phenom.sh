#!/bin/bash
# Helper script para executar Phenom CLI no diretório correto

PHENOM_DIR="/home/ashirak/cli-ai/phenom-cli-ts"

echo "=========================================="
echo "Phenom CLI - Helper Script"
echo "=========================================="
echo ""
echo "Diretório atual: $(pwd)"
echo "Arquivos serão criados aqui: $(pwd)"
echo ""
echo "Pressione ENTER para continuar ou Ctrl+C para cancelar..."
read

cd "$PHENOM_DIR"
npm run tui
