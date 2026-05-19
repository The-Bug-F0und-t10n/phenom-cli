#!/usr/bin/env python3
"""
agent.py — Coding agent para Ollama
Dep: pip install openai

Modelos recomendados:
  código + tools   → qwen2.5-coder:7b, qwen2.5-coder:14b, llama3.1:8b
  código + thinking→ qwen3:8b, deepseek-r1:8b  (emitem <think> nativamente)
"""
import json, os, subprocess, difflib, re, urllib.request, urllib.parse
from html.parser import HTMLParser
from pathlib import Path
from openai import OpenAI

# ── config ─────────────────────────────────────────────────────────────────────
OLLAMA_URL = "http://localhost:11434/v1"
MODEL      = "qwen2.5-coder:7b"
MAX_TURNS      = 32      # guard: evita loop infinito de tool calls
TOOL_CTX_LIMIT = 12_000  # chars máximos de um tool result injetado no contexto

client = OpenAI(base_url=OLLAMA_URL, api_key="ollama")

# ── system prompt ─────────────────────────────────────────────────────────────
def make_system(cwd: str) -> str:
    return (
        "You are Phenom, a coding assistant with tool execution capabilities.\n"
        f"Working directory: {cwd}\n\n"
        "You have: read_file, write_file, patch_file, shell, rag_web.\n"
        "Use shell freely — rg, nl, find, wc, python, etc. — to inspect and act.\n"
        "Work autonomously until the task is complete, then report back."
    )

# ── tool schemas ───────────────────────────────────────────────────────────────
TOOLS = [
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Lê o conteúdo de um arquivo do disco.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Caminho do arquivo"}},
            "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "write_file",
        "description": "Cria ou sobrescreve um arquivo. Exibe diff automático.",
        "parameters": {"type": "object", "properties": {
            "path":    {"type": "string"},
            "content": {"type": "string"}},
            "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "patch_file",
        "description": "Substitui a 1ª ocorrência de old_str por new_str. Exibe diff automático.",
        "parameters": {"type": "object", "properties": {
            "path":    {"type": "string"},
            "old_str": {"type": "string"},
            "new_str": {"type": "string"}},
            "required": ["path", "old_str", "new_str"]}}},
    {"type": "function", "function": {
        "name": "shell",
        "description": "Executa um comando shell e retorna stdout + stderr.",
        "parameters": {"type": "object", "properties": {
            "cmd": {"type": "string"}},
            "required": ["cmd"]}}},
    {"type": "function", "function": {
        "name": "rag_web",
        "description": (
            "Busca informação na web. "
            "Passe uma query de busca OU uma URL direta (https://...) para ler a página."
        ),
        "parameters": {"type": "object", "properties": {
            "input": {"type": "string", "description": "Query de busca ou URL completa"}},
            "required": ["input"]}}},
]

# ── ANSI ───────────────────────────────────────────────────────────────────────
GREY   = "\033[90m"; RED    = "\033[91m"; GREEN  = "\033[92m"
YELLOW = "\033[93m"; CYAN   = "\033[96m"; BOLD   = "\033[1m"
DIM    = "\033[2m";  RESET  = "\033[0m"

# ── diff estilizado ────────────────────────────────────────────────────────────
def show_diff(path: str, old: str, new: str) -> None:
    a = old.splitlines(keepends=True)
    b = new.splitlines(keepends=True)
    diff = list(difflib.unified_diff(a, b, fromfile=f"a/{path}", tofile=f"b/{path}", lineterm=""))
    if not diff:
        return

    print(f"\n{BOLD}  ± {path}{RESET}")
    print(f"{DIM}  {'─' * 64}{RESET}")

    n_old = n_new = 0
    for ln in diff:
        if ln.startswith(("---", "+++")):
            print(f"  {DIM}{ln}{RESET}")
        elif ln.startswith("@@"):
            m = re.search(r"-(\d+).*\+(\d+)", ln)
            if m:
                n_old, n_new = int(m.group(1)) - 1, int(m.group(2)) - 1
            print(f"\n  {CYAN}{ln}{RESET}")
        elif ln.startswith("-"):
            n_old += 1
            print(f"  {RED}{n_old:>5} -{RESET}{RED} {ln[1:].rstrip()}{RESET}")
        elif ln.startswith("+"):
            n_new += 1
            print(f"  {GREEN}{n_new:>5} +{RESET}{GREEN} {ln[1:].rstrip()}{RESET}")
        else:
            n_old += 1; n_new += 1
            print(f"  {DIM}{n_new:>5}  │ {ln[1:].rstrip()}{RESET}")
    print()

# ── html → texto plano ─────────────────────────────────────────────────────────
class _Strip(HTMLParser):
    SKIP = {"script", "style", "nav", "header", "footer", "aside", "noscript"}
    def __init__(self):
        super().__init__(); self._buf: list[str] = []; self._depth = 0
    def handle_starttag(self, t, _):
        if t in self.SKIP: self._depth += 1
    def handle_endtag(self, t):
        if t in self.SKIP: self._depth = max(0, self._depth - 1)
    def handle_data(self, d):
        if not self._depth and d.strip(): self._buf.append(d.strip())
    def text(self) -> str:
        return re.sub(r"\s{2,}", " ", " ".join(self._buf))

def _html_to_text(raw: str) -> str:
    p = _Strip(); p.feed(raw); return p.text()[:6000]

# ── rag_web ────────────────────────────────────────────────────────────────────
def _http(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 agent/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read().decode(errors="replace")

def rag_web(inp: str) -> str:
    try:
        # URL direta → fetch + extrai texto
        if inp.startswith("http://") or inp.startswith("https://"):
            raw = _http(inp)
            return _html_to_text(raw) if "<html" in raw[:400].lower() else raw[:6000]

        # busca no DuckDuckGo instant answers
        q   = urllib.parse.quote_plus(inp)
        raw = _http(f"https://api.duckduckgo.com/?q={q}&format=json&no_html=1&skip_disambig=1")
        data = json.loads(raw)

        lines: list[str] = []
        if data.get("AbstractText"):
            lines.append(f"[Resumo] {data['AbstractText']}")
            if data.get("AbstractURL"):
                lines.append(f"Fonte: {data['AbstractURL']}")
        for item in data.get("Results", [])[:4]:
            if item.get("Text"):
                lines.append(f"→ {item['Text']}  ({item.get('FirstURL', '')})")
        for item in data.get("RelatedTopics", [])[:6]:
            if isinstance(item, dict) and item.get("Text"):
                lines.append(f"• {item['Text']}")

        return "\n".join(lines) if lines else (
            "DDG não retornou resultados úteis. "
            "Tente buscar a URL de documentação diretamente."
        )
    except Exception as e:
        return f"ERROR: {e}"

# ── executor de tools ──────────────────────────────────────────────────────────
def run_tool(name: str, inp: dict) -> str:
    match name:
        case "read_file":
            try:    return Path(inp["path"]).read_text(errors="replace")
            except Exception as e: return f"ERROR: {e}"

        case "write_file":
            try:
                p   = Path(inp["path"])
                old = p.read_text(errors="replace") if p.exists() else ""
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(inp["content"])
                show_diff(inp["path"], old, inp["content"])
                return f"ok: {p} ({len(inp['content'])} bytes)"
            except Exception as e: return f"ERROR: {e}"

        case "patch_file":
            try:
                p   = Path(inp["path"])
                old = p.read_text()
                if inp["old_str"] not in old:
                    return "ERROR: old_str não encontrado no arquivo"
                new = old.replace(inp["old_str"], inp["new_str"], 1)
                p.write_text(new)
                show_diff(inp["path"], old, new)
                return "ok: patch aplicado"
            except Exception as e: return f"ERROR: {e}"

        case "shell":
            try:
                r = subprocess.run(
                    inp["cmd"], shell=True, text=True,
                    capture_output=True, timeout=60,
                )
                return (r.stdout + r.stderr).strip() or "(sem output)"
            except subprocess.TimeoutExpired: return "ERROR: timeout (60s)"
            except Exception as e:            return f"ERROR: {e}"

        case "rag_web":
            return rag_web(inp["input"])

        case _:
            return f"ERROR: tool desconhecida '{name}'"

# ── stream com state machine para <think> e <plan> ────────────────────────────
# Cada tag tem: (label de abertura, cor do texto)
TAG = {
    "think": (f"{GREY}💭 thinking…{RESET}", GREY),
    "plan":  (f"{YELLOW}📋 micro-plan{RESET}", YELLOW),
}

def stream_response(messages: list[dict]) -> tuple[str, list[dict]]:
    """
    Streama a resposta do Ollama.
    - texto normal        → CYAN
    - <think>…</think>   → GREY  (raciocínio interno)
    - <plan>…</plan>     → YELLOW (micro-plano)
    - tool_calls          → acumula deltas e retorna ao final
    """
    stream = client.chat.completions.create(
        model=MODEL, messages=messages, tools=TOOLS,
        stream=True, temperature=0,
    )

    full_content = ""
    tc_acc: dict[int, dict] = {}          # acumulador de tool call deltas
    in_tag: str | None      = None        # tag atualmente aberta ("think"/"plan")
    pending                 = ""          # buffer de lookahead para detecção de tags
    LOOKAHEAD               = 20          # bytes de segurança no flush

    print(f"\n{CYAN}●{RESET} ", end="", flush=True)

    for chunk in stream:
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta

        # ── acumula deltas de tool_calls ──────────────────────────────────────
        if delta.tool_calls:
            for tc in delta.tool_calls:
                i = tc.index
                if i not in tc_acc:
                    tc_acc[i] = {"id": "", "name": "", "args": ""}
                if tc.id:         tc_acc[i]["id"]    = tc.id
                if tc.function:
                    tc_acc[i]["name"] += tc.function.name        or ""
                    tc_acc[i]["args"] += tc.function.arguments   or ""
            continue

        text = delta.content or ""
        if not text:
            continue
        full_content += text
        pending      += text

        # ── state machine: flush seguro enquanto detecta tags ─────────────────
        while True:
            if in_tag:
                close = f"</{in_tag}>"
                idx   = pending.find(close)
                if idx >= 0:
                    _, color = TAG[in_tag]
                    print(f"{color}{pending[:idx]}{RESET}", end="", flush=True)
                    print(f"\n{DIM}{'─' * 44}{RESET}\n{CYAN}●{RESET} ", end="", flush=True)
                    pending = pending[idx + len(close):]
                    in_tag  = None
                else:
                    safe = pending[:-LOOKAHEAD] if len(pending) > LOOKAHEAD else ""
                    if safe:
                        _, color = TAG[in_tag]
                        print(f"{color}{safe}{RESET}", end="", flush=True)
                        pending = pending[len(safe):]
                    break
            else:
                # localiza a tag de abertura mais próxima
                best_tag: str | None = None
                best_idx: int        = len(pending) + 1
                for tag in TAG:
                    i = pending.find(f"<{tag}>")
                    if 0 <= i < best_idx:
                        best_tag, best_idx = tag, i

                if best_tag is not None:
                    if best_idx > 0:
                        print(pending[:best_idx], end="", flush=True)
                    label, _ = TAG[best_tag]
                    print(f"\n{label}\n", flush=True)
                    pending = pending[best_idx + len(f"<{best_tag}>"):]
                    in_tag  = best_tag
                else:
                    safe = pending[:-LOOKAHEAD] if len(pending) > LOOKAHEAD else ""
                    if safe:
                        print(safe, end="", flush=True)
                        pending = pending[len(safe):]
                    break

    # flush final
    if pending:
        color = TAG[in_tag][1] if in_tag else ""
        print(f"{color}{pending}{RESET}", end="", flush=True)
    print()

    return full_content, [
        {"id": v["id"], "name": v["name"], "args": v["args"]}
        for v in tc_acc.values()
        if v["name"]
    ]

# ── agentic loop ──────────────────────────────────────────────────────────────
def agent(messages: list[dict], user_msg: str) -> None:
    """Appends user_msg to the shared session history and runs the tool loop."""
    messages.append({"role": "user", "content": user_msg})

    for turn in range(1, MAX_TURNS + 1):
        content, tool_calls = stream_response(messages)

        if not tool_calls:
            if content:
                messages.append({"role": "assistant", "content": content})
            break

        if turn == MAX_TURNS:
            print(f"{RED}  \u26a0 MAX_TURNS ({MAX_TURNS}) reached — stopping loop{RESET}")
            break

        print(f"{DIM}  [turn {turn}/{MAX_TURNS}]{RESET}")

        messages.append({
            "role":       "assistant",
            "content":    content or None,
            "tool_calls": [
                {
                    "id":       tc["id"],
                    "type":     "function",
                    "function": {"name": tc["name"], "arguments": tc["args"]},
                }
                for tc in tool_calls
            ],
        })

        for tc in tool_calls:
            try:    inp = json.loads(tc["args"])
            except: inp = {}

            print(f"\n{YELLOW}\u2699 {tc['name']}{RESET}  {DIM}{tc['args'][:110]}{RESET}")
            out = run_tool(tc["name"], inp)
            if tc["name"] not in ("write_file", "patch_file") or out.startswith("ERROR"):
                print(f"{DIM}  \u2192 {str(out)[:500]}{RESET}")

            # truncate before injecting — prevents context window overflow on large files
            ctx = str(out)
            if len(ctx) > TOOL_CTX_LIMIT:
                ctx = ctx[:TOOL_CTX_LIMIT] + f"\n…[truncated — {len(str(out))} chars total]"

            messages.append({
                "role":         "tool",
                "tool_call_id": tc["id"],
                "content":      ctx,
            })

# ── REPL ───────────────────────────────────────────────────────────────────────
def main() -> None:
    cwd = os.getcwd()
    # session-level history: system prompt is set once, persists across all inputs
    messages: list[dict] = [{"role": "system", "content": make_system(cwd)}]

    print(f"{BOLD}Phenom  |  {MODEL}  |  ctrl+c to quit{RESET}")
    print(f"{DIM}tools: read_file · write_file · patch_file · shell · rag_web{RESET}")
    print(f"{DIM}cwd:   {cwd}{RESET}\n")

    while True:
        try:
            q = input(f"{BOLD}>{RESET} ").strip()
            if q:
                agent(messages, q)
        except (KeyboardInterrupt, EOFError):
            print("\nbye")
            break
        except Exception as e:
            print(f"{RED}error: {e}{RESET}")

if __name__ == "__main__":
    main()
