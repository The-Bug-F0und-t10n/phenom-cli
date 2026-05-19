#!/bin/bash

# Visualização da estrutura do projeto

echo "📁 Estrutura do Phenom CLI"
echo "=========================="
echo ""

echo "📂 Diretório raiz:"
ls -lh | grep -v node_modules | grep -v dist

echo ""
echo "📂 Diretório src/:"
ls -lh src/

echo ""
echo "📊 Estatísticas:"
echo "  Arquivos TypeScript: $(find src -name "*.ts" | wc -l)"
echo "  Linhas de código: $(find src -name "*.ts" -exec cat {} \; | wc -l)"
echo "  Arquivos de documentação: $(find . -maxdepth 1 -name "*.md" | wc -l)"
echo "  Total de arquivos: $(find . -type f -not -path '*/node_modules/*' -not -path '*/.git/*' | wc -l)"

echo ""
echo "📚 Documentação disponível:"
ls -1 *.md 2>/dev/null || echo "  Nenhum arquivo .md encontrado"

echo ""
echo "🔧 Scripts disponíveis:"
ls -1 *.sh 2>/dev/null || echo "  Nenhum script .sh encontrado"

echo ""
echo "✅ Projeto completo e pronto para uso!"
