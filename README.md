# Phenom CLI

Agente CLI local para assistência de código/debug com execução de tools e integração com Ollama.

## Escopo atual

1. Provider único de inferência: **Ollama**.
2. Fluxo de tools com priorização de tool-calls nativos e fallback JSON estruturado.
3. Sessão persistente local (`.phenom-sessions`) e histórico de terminal (`.phenom-history`).

## Requisitos

1. Node.js 18+
2. Instância Ollama acessível
3. Modelos configurados em `.env`

## Setup

```bash
npm install
cp .env.example .env
npm run build
```

## Execução

```bash
npm run dev -- chat
npm run dev -- run "sua tarefa"
npm run dev -- config
npm run tui
```

## Testes

```bash
npm run build
npm test
npx tsx src/test-agent-tool-loop.ts
npx tsx src/test-plan.ts
```

Nota: parte da suíte depende de Ollama online.

## Documentação

1. [ARCHITECTURE.md](/home/ashirak/Projects/person/ai/cli-ai/phenom-cli-ts/ARCHITECTURE.md)
2. [docs/REFATORACAO_DEVLOG.md](/home/ashirak/Projects/person/ai/cli-ai/phenom-cli-ts/docs/REFATORACAO_DEVLOG.md)
3. `INSTALLATION.md`, `USAGE.md`, `CHANGELOG.md`

## Licença

MIT
