# Relatório de alinhamento técnico

Data: 31 de julho de 2026

## Escopo consolidado

Este ciclo tratou dois problemas estruturais independentes:

1. Respostas interrompidas por limite de geração não eram continuadas até uma conclusão real e podiam perder a seção final de fontes.
2. O editor interativo não permitia compor consultas multiline pelo teclado e tinha limites internos que afetavam a visualização de entradas extensas.

## Respostas interrompidas

### Alterações

- Continuação iterativa enquanto o backend encerrar por comprimento, sem teto artificial de `max_tokens` no cliente quando configurado como zero.
- Continuação baseada na cauda literal da resposta para reduzir repetição entre inferências.
- Detecção de progresso para impedir ciclos sem avanço.
- Estado final `incomplete_length` quando o backend continuar encerrando por comprimento.
- Recuperação da seção `Sources` coletada pelo Web RAG quando o texto final não a emitir.
- Testes de fluxo para múltiplas continuações, deduplicação e preservação de fontes.
- Teste real de 100 interações sequenciais para perfis padrão, intermediário e avançado em `tools/check_real_three_level_100_turns.sh`.

### Critério de aceite posterior

- Executar o teste de 300 turnos contra o backend de produção escolhido.
- Arquivar saída, latência, motivo de parada e divergências por turno.
- Não classificar coerência ou ausência de alucinação apenas por igualdade textual; revisar fatos verificáveis e contratos de ferramenta.

## Entrada multiline

### Alterações

- `Alt+Enter` e sequências CSI-u modificadas inserem nova linha.
- Enter simples continua enviando a consulta.
- Bracketed paste preserva linhas vazias, indentação e UTF-8.
- Buffer da consulta permanece sem limite artificial de linhas.
- Viewport renderiza no máximo 10 linhas e rola internamente acompanhando o cursor.
- Removido o antigo teto interno de 256 linhas processadas pelo viewport.

### Evidências executadas

- Suíte completa: `zig build test` aprovada.
- Testes de viewport no início, meio e fim aprovados.
- Teste PTY real em `tools/check_multiline_tty_flow.py` aprovado com 1.003 linhas e 30.017 bytes.
- O backend recebeu uma única requisição contendo o prompt completo, comparado byte a byte.

## Binários

- Build: `zig-out/bin/phenom`
- Instalação: `/home/ashirak/.local/bin/phenom`
- SHA-256 validado antes destes commits: `55ab7140c19ff96470c6fb9913b6ee0b0c79ec46a988e952b2ea7895b9d021f0`

## Pontos para próximo alinhamento

- Definir se `Alt+Enter` será a combinação oficial documentada ou se o CLI habilitará explicitamente um protocolo avançado de teclado para distinguir `Shift+Enter` em mais terminais.
- Definir indicadores visuais opcionais de conteúdo acima e abaixo do viewport de 10 linhas.
- Executar e revisar o teste real de 300 turnos no backend-alvo; o script existe, mas custo, modelo e endpoint devem ser escolhidos conscientemente.
- Decidir política operacional para respostas que permaneçam em `incomplete_length` após continuações sem progresso.
