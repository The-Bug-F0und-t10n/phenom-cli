# Docs Migration Map

Este arquivo registra a consolidação da documentação antiga para o novo conjunto conciso.

## Documentos canônicos (atuais)

- `README.md` - visão geral e comandos principais
- `INSTALLATION.md` - instalação e setup
- `USAGE.md` - uso operacional
- `ARCHITECTURE.md` - arquitetura resumida
- `FAQ.md` - dúvidas frequentes
- `CONTRIBUTING.md` - contribuição
- `CHANGELOG.md` - histórico de mudanças

## Migração (antigo -> novo)

| Antigo | Novo destino |
|---|---|
| `QUICKSTART.md` / `QUICKSTART.txt` | `README.md`, `USAGE.md` |
| `README-RAG.md`, `SOLUCAO-RAG.md`, `CHROMADB-AUTO-INIT.md` | `ARCHITECTURE.md`, `FAQ.md` |
| `INDEX.md` | `README.md` |
| `TUI-IMPLEMENTATION.md` | `ARCHITECTURE.md` |
| `FEATURES_v1.1.md`, `RELEASE_NOTES_v1.1.0.md` | `CHANGELOG.md` |
| `TEST_INSTRUCTIONS.md`, `TEST_RESULTS.md`, `TESTE-REPORT.md` | `README.md` (seção Testes) |
| `PROJECT_*`, `FINAL_*`, `RELATORIO-*`, `RESUMO-*`, `IMPLEMENTACAO-*`, `CORRECAO-*`, `MODO-DELIBERATIVO.md`, `ONDE-ARQUIVOS-SAO-CRIADOS.md` | Removidos (histórico redundante) |

## Política aplicada

- Priorizar uma única fonte de verdade por assunto.
- Remover documentos de status temporário e relatórios duplicados.
- Manter conteúdo operacional em arquivos curtos e objetivos.
