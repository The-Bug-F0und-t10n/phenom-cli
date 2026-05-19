#!/bin/bash

# Teste Real Simplificado - Verificação de Conectividade

echo "🔍 Teste de Conectividade com Ollama"
echo "======================================"
echo ""

# Testar conexão
echo "1. Testando conexão com inference.local:11434..."
if curl -s http://inference.local:11434/api/tags > /dev/null 2>&1; then
    echo "✅ Ollama está acessível"
else
    echo "❌ Ollama NÃO está acessível"
    echo ""
    echo "Por favor, verifique:"
    echo "  1. Ollama está rodando?"
    echo "  2. O host 'inference.local' está correto?"
    echo "  3. A porta 11434 está aberta?"
    echo ""
    exit 1
fi

echo ""
echo "2. Listando modelos disponíveis..."
curl -s http://inference.local:11434/api/tags | head -20

echo ""
echo ""
echo "3. Testando geração de texto..."
curl -s http://inference.local:11434/api/generate -d '{
  "model": "qwen2.5-coder:7b-instruct-q4_K_M",
  "prompt": "Responda apenas: OK",
  "stream": false
}' | head -20

echo ""
echo ""
echo "✅ Teste de conectividade concluído!"
echo ""
echo "Para executar o teste completo:"
echo "  ./test-real.sh"
