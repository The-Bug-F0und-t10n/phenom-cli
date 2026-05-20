# Installation

## 1) Pré-requisitos

- Node.js 18+
- Ollama disponível no host configurado

## 2) Setup

```bash
npm install
cp .env.example .env
npm run build
```

## 3) Ajuste de ambiente

Edite `.env` com os valores principais:

```bash
OLLAMA_HOST=http://inference.local:11434
OLLAMA_MODEL=qwen3.5-coder:latest
OLLAMA_NUM_CTX=8192
MAX_HISTORY=10
MODE=code_assistant
```

## 4) Verificação

```bash
npm run build
npm run test:core
npm run dev config
```

## 5) Primeira execução

```bash
npm run dev chat
```
