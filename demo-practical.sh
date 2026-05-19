#!/bin/bash

# Teste Prático do Phenom CLI
# Demonstração das capacidades do agente

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                      ║"
echo "║           DEMONSTRAÇÃO PRÁTICA - PHENOM CLI v1.1.0                  ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Verificar Ollama
echo "🔍 Verificando Ollama..."
if ! curl -s http://inference.local:11434/api/tags > /dev/null 2>&1; then
    echo "❌ Ollama não está acessível"
    exit 1
fi
echo "✅ Ollama conectado"
echo ""

# Criar projeto de teste
TEST_DIR="/tmp/finance-demo"
echo "📁 Criando projeto em: $TEST_DIR"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Inicializar git
git init -q
git config user.name "Phenom Demo"
git config user.email "demo@phenom.ai"

echo "✅ Projeto inicializado"
echo ""

# Função para testar o agente
test_agent() {
    local test_name="$1"
    local query="$2"
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "TESTE: $test_name"
    echo "───────────────────────────────────────────────────────────────────────"
    echo "Query: $query"
    echo "───────────────────────────────────────────────────────────────────────"
    echo ""
    
    cd /home/ashirak/cli-ai/phenom-cli-ts
    
    # Executar com timeout
    timeout 60 npm run dev run "$query" 2>&1 | head -100
    
    local exit_code=$?
    
    cd "$TEST_DIR"
    
    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "✅ Teste concluído"
    else
        echo ""
        echo "⚠️  Teste com timeout ou erro (código: $exit_code)"
    fi
    
    echo ""
    sleep 2
}

# TESTE 1: Criar estrutura básica
test_agent "Criar Estrutura do Projeto" \
"Crie um projeto Node.js simples com package.json contendo: name 'finance-app', version '1.0.0', scripts com 'start' e 'test', dependencies express e typescript. Crie também um arquivo README.md explicando o projeto."

# TESTE 2: Criar arquivo principal
test_agent "Criar Servidor Express" \
"Crie um arquivo server.js com um servidor Express básico na porta 3000 com rota GET / que retorna 'Finance App Running'. Adicione middleware para JSON e CORS."

# TESTE 3: Analisar código
test_agent "Analisar Código com Tree-sitter" \
"Use tree-sitter para analisar o arquivo server.js e listar todas as funções encontradas."

# TESTE 4: Criar documentação
test_agent "Gerar Documentação" \
"Crie um arquivo INSTALL.md em markdown com instruções de instalação: 1) pré-requisitos (Node.js 18+), 2) instalação (npm install), 3) execução (npm start), 4) testes (npm test). Use formatação markdown completa com headers, listas e código."

# TESTE 5: Git operations
echo "═══════════════════════════════════════════════════════════════════════"
echo "TESTE: Operações Git"
echo "───────────────────────────────────────────────────────────────────────"

cd "$TEST_DIR"
git add .
git commit -m "feat: implementação inicial do finance app" -q

echo "✅ Commit realizado"
echo ""
echo "📊 Status do Git:"
git log --oneline
echo ""
git status --short
echo ""

# Relatório final
echo "═══════════════════════════════════════════════════════════════════════"
echo "RELATÓRIO FINAL"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

echo "📊 Estatísticas:"
echo "  Arquivos criados: $(find . -type f -not -path './.git/*' | wc -l)"
echo "  Commits: $(git log --oneline | wc -l)"
echo ""

echo "📁 Arquivos criados:"
find . -type f -not -path './.git/*' | sort
echo ""

echo "📝 Conteúdo dos arquivos:"
echo "───────────────────────────────────────────────────────────────────────"
for file in $(find . -type f -not -path './.git/*' | sort); do
    echo ""
    echo "=== $file ==="
    cat "$file" | head -20
    echo ""
done

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                      ║"
echo "║                    ✅ DEMONSTRAÇÃO CONCLUÍDA                         ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📂 Projeto criado em: $TEST_DIR"
echo ""
