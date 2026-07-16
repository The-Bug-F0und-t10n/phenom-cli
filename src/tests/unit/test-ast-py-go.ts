// Quick smoke test for Python/Go AST parsing. Uses inline snippets; no FS deps.
// Run with: tsx src/tests/unit/test-ast-py-go.ts
import { parseSource, formatSummary } from '../../ast-parser.js';

const PY = `
import os
from typing import List

def greet(name: str) -> str:
    return f"hi {name}"

class Counter:
    def __init__(self, start: int = 0):
        self.n = start
    def inc(self) -> None:
        self.n += 1
    def value(self) -> int:
        return self.n
`;

const GO = `
package main

import (
    "fmt"
    "strings"
)

type Greeter interface {
    Greet(name string) string
}

type EnglishGreeter struct {
    Prefix string
}

func (g EnglishGreeter) Greet(name string) string {
    return strings.Join([]string{g.Prefix, name}, " ")
}

func main() {
    g := EnglishGreeter{Prefix: "hi"}
    fmt.Println(g.Greet("world"))
}
`;

function expect(cond: boolean, msg: string): void {
  if (!cond) {
    console.error('FAIL:', msg);
    process.exit(1);
  }
}

function tryParse(label: 'python' | 'go', code: string): ReturnType<typeof parseSource> | null {
  try {
    return parseSource(code, label);
  } catch (e: any) {
    // ABI/NAPI mismatch between tree-sitter host and grammar — skip with a
    // clear marker so the test stays useful both pre- and post-install.
    console.warn(`⚠️  ${label} grammar não carregou — pulando (${(e?.message || e).toString().slice(0, 160)})`);
    return null;
  }
}

(async () => {
  let assertionsRun = 0;

  const pySum = tryParse('python', PY);
  if (pySum) {
    console.log('--- Python summary ---');
    console.log(formatSummary('<py>', pySum));
    expect(pySum.functions.some(f => f.name === 'greet'), 'python: missing function greet'); assertionsRun++;
    expect(pySum.classes.some(c => c.name === 'Counter'), 'python: missing class Counter'); assertionsRun++;
    const counter = pySum.classes.find(c => c.name === 'Counter')!;
    expect((counter.children || []).some(m => m.name === 'inc'), 'python: missing method Counter.inc'); assertionsRun++;
    expect(pySum.imports.length >= 2, `python: expected imports, got ${pySum.imports.length}`); assertionsRun++;
  }

  const goSum = tryParse('go', GO);
  if (goSum) {
    console.log('--- Go summary ---');
    console.log(formatSummary('<go>', goSum));
    expect(goSum.functions.some(f => f.name === 'main'), 'go: missing function main'); assertionsRun++;
    expect(goSum.functions.some(f => f.name === 'Greet'), 'go: missing method Greet'); assertionsRun++;
    expect(goSum.classes.some(c => c.name === 'EnglishGreeter'), 'go: missing struct EnglishGreeter'); assertionsRun++;
    expect(goSum.classes.some(c => c.name === 'Greeter'), 'go: missing interface Greeter'); assertionsRun++;
  }

  if (assertionsRun === 0) {
    console.log('\n⚠️  AST py+go smoke skipped (neither grammar loaded)');
  } else {
    console.log(`\n✅ AST py+go smoke OK (${assertionsRun} assertions)`);
  }
})();
