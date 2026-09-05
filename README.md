# Phenom Zig

---

# Status do Projeto

**Discontinuado.**

O Phenom explorou uma estratégia agressiva de minimização de contexto para agentes de coding locais: fornecer ao modelo a menor quantidade de evidência necessária para realizar uma operação de inferência.

A exploração da abordagem foi bem-sucedida, porém sua implementação não se comportou como esperado. A redução agressiva de contexto aumentou significativamente a complexidade do backend e, em diversas tarefas, degradou o raciocínio do modelo, especialmente em fluxos como `web_rag` e na interpretação da intenção do usuário.

A tentativa de corrigir esses efeitos exigiria a introdução de novas abstrações para compensar as limitações criadas pela própria estratégia de minimização, tornando a arquitetura progressivamente mais complexa e difícil de manter.

O projeto foi descontinuado após atingir esse trade-off.

---

O Phenom Zig é o binário Zig/C do projeto Phenom: um agente local de terminal com CLI/TUI, streaming para modelos locais, renderer Markdown append-only, auditoria SQLite, memória operacional de sessão e tool loop controlado por contratos.

O projeto é voltado ao uso local-first, com backends como Ollama e llama.cpp. A proposta central é executar conversas, recuperação de contexto e ações de código com evidência destilada, limites auditáveis e separação explícita entre diálogo, memória persistente, microcontexto e outputs de ferramentas.

## Principais recursos

* CLI com comandos `chat`, `probe`, `snapshot`, `version` e `help`.
* TUI append-only, sem alternate screen, com recuperação de sessão ao reabrir o binário.
* Renderer Markdown com headings, listas, code blocks, diff, tabelas com quebra interna de células e output de tools.
* Streaming HTTP local para Ollama (`/api/chat`) e llama.cpp (`/v1/chat/completions`) com o template nativo do GGUF.
* Filtro de reasoning para blocos `<think>...</think>`.
* Auditoria SQLite em `.phenom-zig/phenom.db`.
* Recuperação de sessão por eventos recentes, `SESSION_FOCUS`, FTS5/BM25 e resumo operacional de sessões longas.
* Tool loop com allowlist por contrato operacional.
* `collect_evidence`, `search_session`, `apply_patch`, `validate_syntax`, `promote_context` e perfis de contexto.
* Perfis de system prompt stock (`stock` e `strict`) com override local por `Phenom.md`.
* Orçamento pre-send de contexto do modelo, com limite atual de 24 KiB e rejeição de marcadores brutos.

## Desenvolvimento

O Phenom foi desenvolvido utilizando **AI-assisted programming** como parte do processo de engenharia.

A IA foi utilizada como ferramenta de implementação, exploração, refatoração e iteração. A definição da arquitetura, dos requisitos, das hipóteses experimentais, das decisões técnicas e a validação dos resultados permaneceram sob responsabilidade do autor.

Essa abordagem foi particularmente adequada ao objetivo do projeto: explorar diferentes estratégias para controle e minimização de contexto em agentes locais, observando não apenas o comportamento do código, mas também o comportamento do próprio modelo diante das restrições impostas pela arquitetura.

## Requisitos

* Linux ou ambiente POSIX compatível.
* Zig 0.16.0 disponível no `PATH`.
* `sqlite3` e headers de desenvolvimento.
* Opcional: Ollama ou llama.cpp ativo para inferência real.

### Debian/Ubuntu

```bash
sudo apt-get install sqlite3 libsqlite3-dev
```

## Instalação rápida

Build e instalação local:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast
```

O build instala:

* `zig-out/bin/phenom`
* `~/.local/bin/phenom`
* `~/.config/phenom/config.toml` mesclado a partir de `../config.toml`

### Verificação

```bash
phenom version
phenom chat --offline --session dev --prompt "responda somente: ok"
```

## Uso básico

### Chat com backend real

```bash
phenom chat --backend ollama --host 127.0.0.1:11434 --model llama3.2 --prompt "olá"
phenom chat --backend llamacpp --host 127.0.0.1:8080 --model local --prompt "olá"
```

### Modo interativo

```bash
phenom chat --session trabalho
```

### Probe sem inferência

```bash
phenom probe --backend ollama --host 127.0.0.1:11434
phenom probe --backend llamacpp --host 127.0.0.1:8080
```

## Documentação

* [Índice geral](doc/INDEX.md)
* [Instalação](doc/INSTALL.md)
* [Build e testes](doc/BUILD.md)
* [Flags e configuração](doc/FLAGS.md)

## Dados locais

O projeto grava estado operacional no diretório de trabalho:

* `.phenom-zig/phenom.db`: eventos, histórico de input, FTS e foco de sessão.
* `MEMORY.md` e `SKILLS.md`: memória persistente textual, somente quando promovida explicitamente.
* `zig-out/`, `.zig-cache/`, `zig-cache/`: artefatos de build/cache.

O audit SQLite não deve ser tratado como memória persistente do modelo. Ele é uma trilha operacional para restauração, busca, diagnóstico e prova de fluxo.

## Validação

### Suite offline

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test
```

### Smokes reais

Exigem um backend ativo:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build real-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL

ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build real-alignment-smoke -Dreal-backend=llamacpp -Dreal-host=HOST:PORT -Dreal-model=MODEL
```

---

> **Nota:** o projeto foi mantido público como registro do experimento e das decisões arquiteturais exploradas durante seu desenvolvimento.
