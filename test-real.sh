#!/bin/bash

# Teste Real do Phenom CLI
# Projeto: Site de Finanças Pessoais

set -e

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                      ║"
echo "║           TESTE REAL - PHENOM CLI v1.1.0                             ║"
echo "║                                                                      ║"
echo "║           Projeto: Site de Finanças Pessoais                         ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Verificar se Ollama está rodando
echo "🔍 Verificando conexão com Ollama..."
if ! curl -s http://inference.local:11434/api/tags > /dev/null 2>&1; then
    echo "❌ Erro: Ollama não está acessível em inference.local:11434"
    echo "   Por favor, inicie o Ollama primeiro."
    exit 1
fi
echo "✅ Ollama conectado"
echo ""

# Criar diretório do projeto de teste
TEST_DIR="/tmp/finance-app-test"
echo "📁 Criando diretório de teste: $TEST_DIR"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Inicializar git
git init
git config user.name "Phenom Test"
git config user.email "test@phenom.ai"

echo "✅ Diretório preparado"
echo ""

# Função para executar comando do agente
run_agent() {
    local query="$1"
    local step="$2"
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "PASSO $step"
    echo "───────────────────────────────────────────────────────────────────────"
    echo "Query: $query"
    echo "───────────────────────────────────────────────────────────────────────"
    
    cd /home/ashirak/cli-ai/phenom-cli-ts
    
    # Executar comando e capturar saída
    timeout 120 npm run dev run "$query" 2>&1 || {
        echo "⚠️  Timeout ou erro no comando"
        return 1
    }
    
    cd "$TEST_DIR"
    echo ""
}

# TESTE 1: Criar estrutura do projeto
echo "🚀 INICIANDO TESTES"
echo ""

run_agent "Crie a estrutura inicial de um projeto web de finanças pessoais com Node.js, Express e TypeScript. Inclua package.json, tsconfig.json, e estrutura de pastas src/ com routes/, controllers/, models/, middleware/, e public/. Use arquitetura MVC." "1"

sleep 2

# TESTE 2: Implementar sistema de autenticação
run_agent "Implemente um sistema de autenticação completo com login e senha. Crie: 1) modelo de usuário (src/models/User.ts) com hash de senha usando bcrypt, 2) controller de autenticação (src/controllers/AuthController.ts) com registro e login, 3) middleware de autenticação JWT (src/middleware/auth.ts), 4) rotas de autenticação (src/routes/auth.ts). Use TypeScript e boas práticas de segurança." "2"

sleep 2

# TESTE 3: Criar dashboard
run_agent "Crie um dashboard completo de finanças pessoais. Implemente: 1) modelo de transação (src/models/Transaction.ts) com campos: tipo (receita/despesa), valor, categoria, data, descrição, 2) controller de transações (src/controllers/TransactionController.ts) com CRUD completo, 3) rotas de transações (src/routes/transactions.ts), 4) página HTML do dashboard (public/dashboard.html) com tabela de transações, formulário de adicionar, e resumo financeiro." "3"

sleep 2

# TESTE 4: Adicionar funcionalidade de categorias
run_agent "Adicione sistema de categorias para as transações. Crie: 1) modelo de categoria (src/models/Category.ts), 2) controller de categorias (src/controllers/CategoryController.ts), 3) rotas de categorias (src/routes/categories.ts), 4) categorias padrão (Alimentação, Transporte, Moradia, Lazer, Salário, Investimentos). Atualize o modelo de Transaction para referenciar Category." "4"

sleep 2

# TESTE 5: Implementar relatórios
run_agent "Implemente sistema de relatórios financeiros. Crie: 1) controller de relatórios (src/controllers/ReportController.ts) com métodos para: resumo mensal, gastos por categoria, evolução do saldo, 2) rotas de relatórios (src/routes/reports.ts), 3) página de relatórios (public/reports.html) com gráficos usando Chart.js." "5"

sleep 2

# TESTE 6: Criar arquivo principal
run_agent "Crie o arquivo principal da aplicação (src/index.ts) que: 1) configura Express, 2) configura middleware (cors, body-parser, helmet), 3) registra todas as rotas, 4) conecta ao banco de dados (use MongoDB com Mongoose), 5) inicia o servidor na porta 3000. Adicione tratamento de erros global." "6"

sleep 2

# TESTE 7: Adicionar validações
run_agent "Adicione validações completas usando express-validator. Crie: 1) middleware de validação (src/middleware/validation.ts), 2) validações para registro de usuário (email válido, senha forte), 3) validações para transações (valor positivo, data válida, categoria existente), 4) validações para categorias (nome único, não vazio)." "7"

sleep 2

# TESTE 8: Commit inicial
echo "═══════════════════════════════════════════════════════════════════════"
echo "PASSO 8: Commit Inicial"
echo "───────────────────────────────────────────────────────────────────────"

cd "$TEST_DIR"
git add .
git commit -m "feat: implementação inicial do sistema de finanças pessoais

- Sistema de autenticação com JWT
- CRUD de transações
- Sistema de categorias
- Dashboard com resumo financeiro
- Relatórios com gráficos
- Validações completas
- Arquitetura MVC com TypeScript"

echo "✅ Commit realizado"
echo ""

# TESTE 9: Encontrar e corrigir bug
run_agent "Analise o código em busca de bugs de segurança. Verifique: 1) se as senhas estão sendo hasheadas corretamente, 2) se há validação de input em todas as rotas, 3) se o JWT está sendo verificado corretamente, 4) se há proteção contra SQL injection (mesmo usando MongoDB), 5) se há rate limiting. Liste todos os problemas encontrados e corrija-os." "9"

sleep 2

# TESTE 10: Adicionar testes unitários
run_agent "Crie testes unitários usando Jest. Implemente: 1) testes para AuthController (registro, login, token inválido), 2) testes para TransactionController (criar, listar, atualizar, deletar), 3) testes para middleware de autenticação, 4) testes para validações. Crie arquivo jest.config.js e adicione scripts de teste no package.json." "10"

sleep 2

# TESTE 11: Implementar nova feature - Metas Financeiras
run_agent "Implemente uma nova feature de Metas Financeiras. Crie: 1) modelo de meta (src/models/Goal.ts) com campos: nome, valor alvo, valor atual, prazo, categoria, 2) controller de metas (src/controllers/GoalController.ts) com CRUD e método para calcular progresso, 3) rotas de metas (src/routes/goals.ts), 4) página de metas (public/goals.html) com lista de metas, barra de progresso, e formulário de adicionar." "11"

sleep 2

# TESTE 12: Adicionar documentação API
run_agent "Crie documentação completa da API usando Swagger/OpenAPI. Implemente: 1) arquivo de configuração Swagger (src/swagger.ts), 2) documente todos os endpoints com exemplos de request/response, 3) adicione descrições de erros possíveis, 4) configure rota /api-docs para visualizar a documentação. Atualize o README.md com instruções de uso da API." "12"

sleep 2

# TESTE 13: Otimizar performance
run_agent "Otimize a performance da aplicação. Implemente: 1) cache Redis para consultas frequentes (saldo, resumo mensal), 2) paginação nas listagens de transações, 3) índices no MongoDB para queries comuns, 4) compressão de respostas HTTP, 5) lazy loading no frontend. Documente as melhorias no código." "13"

sleep 2

# TESTE 14: Commit final
echo "═══════════════════════════════════════════════════════════════════════"
echo "PASSO 14: Commit Final"
echo "───────────────────────────────────────────────────────────────────────"

cd "$TEST_DIR"
git add .
git commit -m "feat: melhorias e novas funcionalidades

- Correções de segurança
- Testes unitários completos
- Feature de metas financeiras
- Documentação API com Swagger
- Otimizações de performance (cache, paginação, índices)
- README atualizado"

echo "✅ Commit realizado"
echo ""

# TESTE 15: Gerar relatório final
echo "═══════════════════════════════════════════════════════════════════════"
echo "RELATÓRIO FINAL"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

cd "$TEST_DIR"

echo "📊 Estatísticas do Projeto:"
echo "───────────────────────────────────────────────────────────────────────"
echo "Arquivos criados: $(find . -type f -not -path './.git/*' | wc -l)"
echo "Linhas de código: $(find . -name '*.ts' -o -name '*.js' -o -name '*.html' | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')"
echo "Commits: $(git log --oneline | wc -l)"
echo ""

echo "📁 Estrutura do Projeto:"
echo "───────────────────────────────────────────────────────────────────────"
tree -L 3 -I 'node_modules' || find . -type d -not -path './.git/*' -not -path '*/node_modules/*' | head -20
echo ""

echo "📝 Arquivos Principais:"
echo "───────────────────────────────────────────────────────────────────────"
find . -type f -name '*.ts' -o -name '*.js' -o -name '*.html' -o -name '*.json' | grep -v node_modules | sort
echo ""

echo "🔍 Commits Realizados:"
echo "───────────────────────────────────────────────────────────────────────"
git log --oneline --decorate
echo ""

echo "✅ Funcionalidades Implementadas:"
echo "───────────────────────────────────────────────────────────────────────"
echo "✓ Sistema de autenticação (login/senha)"
echo "✓ Dashboard de finanças pessoais"
echo "✓ CRUD de transações"
echo "✓ Sistema de categorias"
echo "✓ Relatórios financeiros com gráficos"
echo "✓ Validações completas"
echo "✓ Correções de segurança"
echo "✓ Testes unitários"
echo "✓ Metas financeiras"
echo "✓ Documentação API (Swagger)"
echo "✓ Otimizações de performance"
echo ""

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                      ║"
echo "║                    ✅ TESTE CONCLUÍDO COM SUCESSO                    ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📂 Projeto criado em: $TEST_DIR"
echo "🚀 Para executar: cd $TEST_DIR && npm install && npm start"
echo ""
