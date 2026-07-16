# Router Mode — Dual-Model Architecture (Devlog)

**Status:** 📋 Planned — not yet implemented. Blocked on prerequisites (see "When to resume" below).

**Last updated:** 2026-05-21

---

## 1. Vision

Mode router introduces a collaborative dual-model architecture inspired by the
**Planner / Worker / Critic** pattern (a.k.a. "Reflection pattern" in
multi-agent literature). Instead of one model doing everything, the work is
split between two specialized models that communicate through a structured
blueprint.

The user only ever sees output from the 9B model. The 7B coder runs as a
sub-agent under the 9B's orchestration.

## 2. Roles

| Role | Model | Responsibility |
|---|---|---|
| Planner + Critic + Narrator | **phenom (9B, qwen3.5 base)** | Analyzes the task, investigates the codebase ("the detective"), builds a precise blueprint (file paths, line ranges, problem statement, solution sketch), reviews every step the coder produces, narrates progress to the user. |
| Specialized Worker | **qwen2.5-coder:7b** | Receives the blueprint. Implements ONE step at a time. May consult web/RAG for updated documentation. Reports completion to the planner. Does NOT plan, does NOT investigate beyond what the blueprint says, does NOT decide what to build next. |

## 3. Hardware orchestration (RX 7600 8GB VRAM + 16GB RAM)

Both models combined ≈ 9.5 GB of weights → can't co-reside in 8 GB VRAM.
Solution: **swap GPU residency** based on whose turn it is, keeping the
inactive model warm in RAM (where both fit comfortably with ~6 GB headroom
for system + KV cache).

Ollama configuration:

```bash
export OLLAMA_MAX_LOADED_MODELS=1   # only one in VRAM at a time
export OLLAMA_KEEP_ALIVE=-1         # keep idle model in RAM (warm swap)
```

Realistic swap cost with the above config:

| Operation | First load (cold) | Subsequent swap (RAM-warm) |
|---|---|---|
| Load model into VRAM | 10–30 s | 1–2 s |

For a typical 5-step plan with review: ~5 × 4 swaps × 2 s = **~40 s of swap
overhead total** per multi-step task. Acceptable trade-off for the quality
gain from specialization.

## 4. Flow

```
┌───────────────────────────────────────────────────────────────┐
│  USER submits task                                            │
└───────────────────────┬───────────────────────────────────────┘
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  9B (on GPU)                                                  │
│   • Analyzes task                                             │
│   • Investigates codebase (grep_file, find_function,          │
│     read_file with micro-context)                             │
│   • Emits structured BLUEPRINT (JSON):                        │
│     {                                                         │
│       steps: [                                                │
│         { id, title, files: [path], lineRanges: [...],        │
│           problem, solution, acceptance }                     │
│       ]                                                       │
│     }                                                         │
│   • Hands off to 7B                                           │
└───────────────────────┬───────────────────────────────────────┘
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  SWAP: 9B → RAM, 7B → GPU (~2s warm)                          │
└───────────────────────┬───────────────────────────────────────┘
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  7B (on GPU) — single step at a time                          │
│   • Reads blueprint step N                                    │
│   • If needed: web_search for current docs/APIs               │
│   • Implements via apply_patch / write_file (block-based)     │
│   • validate_syntax after each block                          │
│   • Reports STEP_COMPLETE with diff summary                   │
└───────────────────────┬───────────────────────────────────────┘
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  SWAP: 7B → RAM, 9B → GPU (~2s warm)                          │
└───────────────────────┬───────────────────────────────────────┘
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  9B (on GPU) — REVIEW                                         │
│   • grep_file / read_file on the changed paths                │
│   • Checks: logic bugs, off-by-one, wrong references, missing │
│     error handling, regression in other paths                 │
│   • Decision:                                                 │
│     - OK    → mark step done, swap back to 7B for next step   │
│     - FIX:  → send free-form description of the bug back to   │
│              7B, retry counter++                              │
│     - GIVE_UP → after 3 FIX attempts, 9B takes over the step  │
│                  itself (fallback)                            │
└───────────────────────┬───────────────────────────────────────┘
                        ▼
                   (loop until all steps done)
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  9B narrates final summary to user                            │
└───────────────────────────────────────────────────────────────┘
```

## 5. Concerns & mitigations

### 5.1 Review loop runaway

**Risk:** 7B implements wrong → 9B rejects → 7B retries wrong differently
→ 9B rejects... infinite loop.

**Mitigation:**
- Hard cap of **3 FIX retries per step**
- On 3rd failure: 9B takes over the step directly (`give_up` fallback)
- Track failure-mode signatures to detect "same bug being reintroduced"

### 5.2 Context coordination

Each model has its own `num_ctx`. The blueprint passed from 9B to 7B
plus the working file diffs must fit in the 7B's context (qwen2.5-coder:7b
default is 32K, configurable).

**Mitigation:**
- Blueprint is **JSON, minimalist**: only file paths + line ranges + 1-2
  sentence problem/solution. No file bodies inlined.
- 7B is expected to call `read_file` with the ranges from the blueprint
  to fetch only what it needs (preserves micro-context discipline).
- 9B review only loads the **diff** + adjacent lines, not full files.

### 5.3 Swap overhead

See section 3. Acceptable with `OLLAMA_KEEP_ALIVE=-1`.

### 5.4 Coder Modelfile rules

The 7B coder needs strict rules to NOT plan and NOT investigate beyond the
blueprint. Otherwise it duplicates work the 9B already did. Draft rules:

```
1. Single-step focus. Implement exactly the step described in the blueprint.
   Do not invent additional changes, do not "improve" things outside the
   step's scope.

2. Read what the blueprint references, nothing more. The blueprint gives
   you file paths and line ranges. Use read_file with those exact ranges.
   Do not grep the codebase to "understand the project" — the planner
   already did that.

3. Block-based execution. Same R3 rules from the main Modelfile: large
   files in focused blocks, validate_syntax after each block, run_tests
   after the last block of a file.

4. When blocked, report — don't guess. If the blueprint is ambiguous or
   the code doesn't match the planner's description, emit STEP_BLOCKED
   with the discrepancy and stop. Don't improvise.

5. May consult web for docs. web_search is allowed for current API docs,
   library signatures, framework idioms. NOT for project-specific
   knowledge (use blueprint).

6. Path invariance + R1-R8 inherited from main Modelfile.
```

## 6. User decisions captured (2026-05-21)

| Question | Decision |
|---|---|
| How to start | **F1 → F2 → F3 → F4 sequential** — each phase tested before the next. |
| Feedback format from 9B to 7B on rejection | **Free-form prose description + suggestion** — flexible, light on context. |
| Trigger mechanism | **Both: manual flag + env var override.** `PHENOM_ROUTER=auto` enables auto-detect; `PHENOM_ROUTER=manual` requires explicit `/router on`; `PHENOM_ROUTER=off` disables entirely. |

## 7. Phased implementation plan

### Phase 1 — Infrastructure

- [ ] New `Modelfile.coder` for `qwen2.5-coder:7b` with the 6 rules in §5.4
- [ ] Build the coder model: `ollama create phenom-coder -f Modelfile.coder`
- [ ] Config keys: `config.ollama.routerMode` ('auto'/'manual'/'off'),
      `config.ollama.coderModel` (default `phenom-coder:latest`)
- [ ] Env var `PHENOM_ROUTER` parsed by `config.ts`
- [ ] Model swap helper in `src/ollama-client.ts` — wraps Ollama's
      `/api/generate` with `keep_alive` semantics, exposes
      `swapToCoder()` / `swapToPlanner()`
- [ ] Status bar indicator: which model is currently active (small badge
      after the wave visualizer, e.g. ` [9B]` or ` [7B]`)
- [ ] `/router` slash command in `src/index.ts` to toggle manually
- [ ] Test plan: load each model independently, swap 5 times, measure
      cold-vs-warm load times, confirm OLLAMA_MAX_LOADED_MODELS=1
      actually unloads previous

### Phase 2 — Blueprint format + handoff

- [ ] Define TypeScript types in `src/router/blueprint.ts`:
      ```ts
      interface Blueprint {
        intent: string;
        steps: BlueprintStep[];
      }
      interface BlueprintStep {
        id: string;
        title: string;
        files: Array<{ path: string; lineRanges?: Array<[number, number]> }>;
        problem: string;
        solution: string;
        acceptance: string;
      }
      ```
- [ ] 9B prompt template that emits Blueprint JSON
- [ ] Blueprint parser + validator (reject malformed JSON, complain to 9B)
- [ ] 7B prompt template that receives a single BlueprintStep + project
      context (minimal — Memory sections + skill matches)
- [ ] Use case `src/use-cases/run-router-loop.ts` orchestrating:
      plan → for each step → execute → return
- [ ] Test plan: 9B produces a valid blueprint for a small task, 7B
      executes step 1 and reports completion, no review yet

### Phase 3 — Review loop

- [ ] After each 7B step, swap to 9B and run review with:
      - The blueprint step that was implemented
      - The diff (via `git diff HEAD` or brain's file-diff tracker)
      - Surrounding context (read_file ranges around changes)
- [ ] 9B emits `STEP_OK`, `STEP_FIX <description>`, or `STEP_GIVE_UP`
- [ ] Retry counter per step; max 3 FIX before `give_up`
- [ ] On `give_up`: 9B takes over the step (executes write/patch itself,
      bypassing 7B)
- [ ] Telemetry: log retries per step into `.MEMORY.md` Insights so the
      pattern of "what kinds of tasks 7B keeps failing on" becomes visible
      across sessions
- [ ] Test plan: scenario with intentional bug seed → 9B catches it →
      7B fixes → 9B re-reviews → OK

### Phase 4 — Polish

- [ ] UX: only 9B narration reaches the user's CLI output. 7B's tool calls
      and internal chatter render as collapsed indicators (e.g.
      `[coder: writing src/foo.ts (block 2/4) ✓]` one line per event,
      no diff dump unless 7B fails)
- [ ] Web search tool implementation (`src/tools/registrars/web-tools.ts`)
      — uses a search API (Brave, DuckDuckGo, or similar). Whitelist for
      coder model only; not enabled for general use to avoid abuse
- [ ] Auto-detect intent of code-touching tasks for `PHENOM_ROUTER=auto`
      mode — this REQUIRES a heuristic (user previously asked to minimise
      heuristics, so this needs explicit go-ahead)
- [ ] Metrics dashboard: `/router stats` shows last N tasks with
      steps OK/FIX/GIVE_UP counts, time per step, swap overhead

## 8. Open questions (to resolve before resuming)

1. **Web search backend.** Which API? Brave is free with key, DuckDuckGo
   needs scraping (fragile). Cost vs reliability trade-off.

2. **Blueprint expiration.** If 9B builds a blueprint and the codebase
   changes (user runs git pull mid-session), the line numbers in the
   blueprint become stale. Should the blueprint be re-validated by 9B
   before each step? Or only when the planner detects a mismatch?

3. **Auto-detect heuristic.** User previously stated "deixar muita
   heurística é ruim, o modelo deve decidir qual tool usar". Auto-detect
   of code-intent contradicts this. Default to MANUAL mode and only build
   auto-detect if specifically requested later.

4. **Failure attribution.** When `give_up` fires, was it 7B that's bad at
   this kind of task, or was the blueprint unclear? Need feedback loop
   into 9B's planning prompt.

5. **Coder context budget.** qwen2.5-coder:7b at 32K context with q8 KV
   cache. Does it fit our hardware budget AT THE SAME TIME as the 9B's
   KV cache (in RAM)? Math:
   - 9B q4 weights: 5.5 GB (in RAM when swapped out)
   - 7B q4 weights: 4.0 GB (in VRAM when active)
   - 9B KV cache q8 @ 32K: ~1.3 GB (in RAM)
   - 7B KV cache q8 @ 32K: ~0.9 GB (in VRAM)
   - VRAM total active: 4.0 + 0.9 = 4.9 GB ✅
   - RAM total: 5.5 + 1.3 + system (~3 GB) = 9.8 GB of 16 ✅

## 9. When to resume

This devlog is parked until ONE of the following is true:

- [ ] Single-model workflow is stable enough (block-based, memory,
      skills, visualizer all polished, no urgent fixes)
- [ ] User explicitly requests router mode work to start
- [ ] qwen2.5-coder:7b has been pulled and benchmarked locally
      (`ollama pull qwen2.5-coder:7b` + manual test that it follows
      single-step instructions reliably)

## 10. Cross-references

- `Modelfile` — main 9B configuration. Adding a `Modelfile.coder` would
  live alongside it.
- `src/use-cases/run-tool-loop.ts` — the current single-model loop. The
  router loop would be a peer use-case (`run-router-loop.ts`), selected
  by the agent based on `config.ollama.routerMode`.
- `src/tools/registrars/memory-tools.ts` — `update_memory` and
  `record_skill` should work the same way under router mode (only the
  9B calls them).
- `.MEMORY.md` rules section — the `PHENOM_ROUTER` env var semantics
  should be documented there once shipped.
