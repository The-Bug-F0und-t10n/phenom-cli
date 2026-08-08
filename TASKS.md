# Priority Max: Agent Runtime Reliability Plan

## Goal

Make `phenom-zig` operate as a reliable AI agent runtime with explicit states, contract-gated tools, source-grounded RAG, backend-normalized model events, and a thin CLI/TUI orchestration layer.

## Scope Model

- `AgentRuntime`: turn state machine and transition invariants.
- `ContractPolicy`: active contract, allowlist, obligations, and selected tool family.
- `ProtocolRepairPolicy`: bounded repairs for model protocol violations.
- `FinalizationGate`: mandatory checks before visible final answer.
- `EvidenceModel`: structured sources, evidence entries, claims, and claim support.
- `ModelGateway`: Ollama/llama.cpp adapters normalized into one stream event model.
- `Presentation`: renderer/TUI consumes classified events only; it does not infer protocol semantics from plain text.

## Evidence

- `src/main.zig` has 12,205 lines and owns turn orchestration, model calls, UI events, SQLite audit, tool dispatch, repair prompts, finalization checks, memory, RAG validation, and artifact saves.
- `src/main.zig:709` starts a chat turn but also creates renderer/event bus/audit DB/model client and handles local commands, model context, streaming, and tool-loop setup.
- `src/main.zig:1866` runs the tool loop and mixes envelope validation, duplicate handling, contract repair, direct `web_search` normalization, audit recording, and model retries.
- `src/main.zig:6348` handles deferred model calls and final-answer repairs with string markers like `[WEB_DOSSIER v1]`, `[ANSWER_REPAIR]`, and protocol leak detection.
- `src/main.zig:7227` stores working context, contract state, evidence counters, repair counters, session search state, retrieved skills, and candidates in one mutable state object.
- `src/http.zig:15` combines backend config, HTTP transport, request body construction, metadata probing, tokenizer accounting, and stream parsing.
- `src/http.zig:1215` normalizes Ollama/llama.cpp stream lines through ad hoc JSON-field extraction instead of backend-specific adapters.
- `src/web_rag.zig:586` renders source/evidence as text blocks, and `src/web_rag.zig:1190` extracts `source_url=` from text, making factual grounding too dependent on string formatting.
- `src/contracts.zig` and `src/tool_envelope.zig` are strong primitives already present; the fix should extract policy around them, not replace them.

## Implementation Steps

- [x] Extract `FinalizationGate` into a pure module with explicit obligations/counters and tests mirroring current `ToolLoopState.finalizationBlocker` behavior.
- [x] Extract `ProtocolRepairPolicy` so direct initial `web_search` normalization and rejected-tool repair decisions are explicit and testable.
- [x] Introduce `AgentState`/`Transition` as a pure state machine for the turn lifecycle.
- [x] Refactor `runToolLoopIterations` to apply state-machine transitions instead of owning policy decisions inline.
- [x] Split `ModelGateway` into backend adapters: Ollama request/stream parsing, llama.cpp request/stream parsing, token accounting, and shared normalized events.
- [x] Replace text-only web evidence with structured `SourceRef`, `EvidenceEntry`, `Claim`, and `ClaimSupport` objects.
- [x] Add a final-answer verifier that blocks unsupported external factual claims or marks them as uncertain before render.
- [x] Move renderer markdown/protocol classification behind typed presentation events so normal chat words are never colored as code by capitalization alone.
- [x] Separate `SessionContext`, `PersistentContext`, `PersonalMemory`, `WorkingContext`, and `ContextBudget` accounting.
- [ ] Keep `main.zig` as thin application wiring after each extraction.
  - [x] Extract initial model context assembly to `src/initial_model_context.zig`; keep compatibility wrappers in `main.zig`.
  - [x] Extract repair-context rendering to `src/repair_context.zig`; keep compatibility wrappers in `main.zig`.
  - [x] Extract pure tool-step policy to `src/tool_step_policy.zig`: operational phase routing, collect_evidence structural policy, candidate expansion helpers, and apply_patch argument validation.
  - [x] Extract `ToolLoopState` to `src/tool_loop_state.zig`, keeping runtime counters, scratch evidence, candidate/session caches, and finalization progress outside `main.zig`.
  - [x] Extract runtime inspection target normalization/rendering to `src/runtime_inspection.zig`.
  - [x] Extract syntax validation execution to `src/syntax_validation.zig`.
  - [x] Move apply_patch/validate_syntax/inspect_runtime repair and follow-up contexts to `src/repair_context.zig`.
  - [ ] Continue extracting impure tool-step execution wiring from `main.zig`.

## Verification Run

- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-global-cache bin/zig-x86_64-linux-0.16.0/zig test src/finalization_gate.zig` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-global-cache bin/zig-x86_64-linux-0.16.0/zig test src/protocol_repair_policy.zig` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-global-cache bin/zig-x86_64-linux-0.16.0/zig test src/agent_state.zig` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-global-cache bin/zig-x86_64-linux-0.16.0/zig test src/model_gateway.zig` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-global-cache bin/zig-x86_64-linux-0.16.0/zig test src/http.zig -lc` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/web_evidence_model.zig` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/web_rag.zig -lc` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/final_claim_verifier.zig` passed.
- Focused `src/main.zig` web tests passed for empty excerpts, successful web close, source follow-up, empty-source fallback, final web dossier rendering, and final claim verification.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/ui_events.zig -lc` passed.
- Focused `src/main.zig` stream/renderer tests passed for deferred stream sink, final stream guard, and renderer sink replay.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/context_budget.zig -lc -lsqlite3` passed.
- Focused `src/main.zig` model context budget tests passed.
- Focused `src/main.zig` tests passed for runtime outcome transitions, plain URL non-synthesis, think-only repair suppression, missing evidence repair, initial rejected-tool repair, clarification soft repair, and finalization blocking.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/initial_model_context.zig -lc -lsqlite3` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/repair_context.zig -lc -lsqlite3` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/tool_step_policy.zig -lc -lsqlite3` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/tool_loop_state.zig -lc -lsqlite3` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/runtime_inspection.zig -lc -lsqlite3` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/syntax_validation.zig -lc -lsqlite3` passed.
- `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag bin/zig-x86_64-linux-0.16.0/zig test src/repair_context.zig -lc -lsqlite3` passed after extracting tool-step repair/follow-up contexts.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "initial model context"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "tool loop schema"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "repair"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "empty web evidence repair"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "pathless collect evidence"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "candidate expansion"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "apply patch"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "validate_syntax"` passed compile/bootstrap.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "tool loop state"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "turn progress"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "workflow starts"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "runtime outcome"` passed.
- From `/tmp` to avoid ignored local `MEMORY.md`: `ZIG_GLOBAL_CACHE_DIR=/tmp/phenom-zig-cache-rag /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/bin/zig-x86_64-linux-0.16.0/zig test /home/ashirak/Projects/person/ai/cli-ai/phenom-cli/phenom-zig/src/main.zig -lc -lsqlite3 --test-filter "inspect_runtime"` passed compile/bootstrap.
- `git diff --check` passed.
- Full `src/main.zig` in repo cwd: 585/589 passed; 4 context tests failed because ignored local `MEMORY.md` is present in cwd.
- `zig test src/main.zig -lc -lsqlite3`
- `zig build test`
- `git diff --check`
- `sh tools/check_initial_json_web_search_normalization_flow.sh ./zig-out/bin/phenom`
- `sh tools/check_web_rag_flow.sh ./zig-out/bin/phenom`
- `sh tools/check_query_web_rag_flow.sh ./zig-out/bin/phenom`
- `sh tools/check_required_tool_repair_flow.sh ./zig-out/bin/phenom`
- `sh tools/check_think_only_finalization.sh ./zig-out/bin/phenom`
- `python3 tools/check_cli_streaming_flow.py ./zig-out/bin/phenom`
- Regression batch for plaintext `search_session` recovery:
  - `zig build`
  - `zig build test` passed from repo cwd with local untracked `MEMORY.md` present.
  - `zig test src/final_claim_verifier.zig`
  - `zig test src/initial_model_context.zig -lc -lsqlite3`
  - `zig test tools/scripted_backend.zig -lc`
  - Focused `src/main.zig` tests passed for plaintext session recovery and finalization contract-switch recovery.
  - `sh tools/check_plaintext_session_flow.sh ./zig-out/bin/phenom` passed with both `llamacpp` and `ollama` adapters.
  - Tool-flow smokes passed for parse-error repair, required-tool repair, agent patch, simple greeting, think-only finalization, web RAG, query web RAG, ambiguous web continuity, linear web/workspace conversation, git evidence, artifact create, `PHENOM.md` prompt, user-rule promotion, memory persistence, personal memory, and 100-turn personal-memory ambiguity.

## Design Rules

- No big rewrite; each step must preserve behavior and move one policy boundary out of `main.zig`.
- No new dependencies for state machine, contracts, parsing, or RAG modeling.
- Prefer pure functions and value objects over runtime interfaces unless two real adapters already exist.
- Every extracted policy must carry focused tests before changing call sites.
- Repairs are allowed, but must return structured `RepairDecision`; they must not be hidden as incidental string checks in the controller.
- Final answers must pass a gate after tool phase closes.
- Web/RAG answers must cite normalized sources when factual claims depend on external evidence.
- Backend differences must normalize before entering the agent runtime.

# Personal Memory Implementation Plan

## Goal

Make `phenom-zig` remember its personal owner across sessions without adding dependencies, cloud services, vector databases, or multi-user identity.

## Scope Model

- `PERSONAL_MEMORY`: durable memory about the agent owner.
- `SESSION_FOCUS`: current-session operational continuity.
- `MEMORY.md`: durable workspace/project facts.
- `SKILLS.md`: durable local operating rules.
- `events`: audit trail, not direct model-visible memory.

## Implementation Steps

- [x] Add `personal_memory` and `personal_memory_fts` to SQLite in `src/audit.zig`.
- [x] Add `src/personal_memory.zig` for validation, normalization, hashing, entity hints, rendering, and strict model-extractor JSON parsing.
- [x] Add audit APIs: `recordPersonalMemory`, `searchPersonalMemory`, `forgetPersonalMemory`, `loadRecentPersonalMemory`, and cleanup helpers.
- [x] Add `[PERSONAL_MEMORY]` to `src/model_context.zig` with its own byte bucket.
- [x] Load relevant personal memory inside `buildInitialModelContext` in `src/main.zig`.
- [x] Add model-visible tools in `src/contracts.zig`: `search_personal_memory`, `promote_personal_memory`, `forget_personal_memory`.
- [x] Extend `src/context_profile.zig` memory schema with personal-memory tool rules.
- [x] Extend `src/tool_call.zig` with `kind`, `key`, `value`, `confidence`, and `id` parsing.
- [x] Add tool-loop executors in `src/main.zig` for personal-memory search, promotion, and forget.
- [x] Replace phrase-based extraction with a model-backed post-turn extractor that emits one strict JSON object; Zig only validates, normalizes, dedupes, and rejects raw context.
- [x] Add `tools/check_personal_memory_flow.sh`.
- [x] Add a `personal-memory-flow-smoke` build step in `build.zig`.
- [x] Verify with focused Zig tests and smoke scripts.

Verification run:

- `zig test src/personal_memory.zig`
- `zig test src/tool_call.zig`
- `zig test src/context_profile.zig`
- `zig test src/model_context.zig -lc -lsqlite3`
- `zig test src/audit.zig -lc -lsqlite3`
- `zig build test`
- `zig build personal-memory-flow-smoke`
- `zig build personal-memory-ambiguity-100-smoke`
- `sh tools/check_real_personal_memory_100.sh ./zig-out/bin/phenom`
- `PHENOM_REAL_PERSONAL_MEMORY_THINKING=on PHENOM_REAL_PERSONAL_MEMORY_100_DIR=/tmp/phenom-real-personal-memory-100-thinking sh tools/check_real_personal_memory_100.sh ./zig-out/bin/phenom`
- `PHENOM_REAL_PERSONAL_MEMORY_THINKING=on PHENOM_REAL_PERSONAL_MEMORY_100_DIR=/tmp/phenom-real-personal-memory-100-german-thinking sh tools/check_real_personal_memory_100.sh ./zig-out/bin/phenom`

100-turn ambiguity proof:

- Real CLI binary executed 100 ambiguous cross-session turns.
- Prompts did not restate the stored tokens `respostas`, `curtas`, or `portugues`.
- SQLite proof: `contexts=100`, `memory_hits=100`, `raw_leaks=0`, `deduped=1`.

100-turn real-model proof:

- Real backend: `llamacpp` at `inference.local:11434`.
- Real model: `phenom:latest`.
- Stored owner memory: `meu codigo pessoal de validacao e PMEM100`.
- Prompts never included `PMEM100`; only CLI expectation checked it.
- Result with `thinking=off`: `contexts=122`, `memory_hits=115`, `assistant_hits=100`, `raw_leaks=0`, `stored=1`, `retries=15`.
- Result with `thinking=on`: `contexts=145`, `memory_hits=140`, `assistant_hits=102`, `raw_leaks=0`, `stored=1`, `retries=7`.
- Result with German seed and `thinking=on`: seed prompt `Merke dir: Mein persönlicher Validierungscode ist PMEM100.`, stored as `profile.personal_validation_code=PMEM100`, `contexts=149`, `memory_hits=141`, `assistant_hits=103`, `raw_leaks=0`, `stored=1`, `retries=10`.
- Thinking-specific fix: render generic `remembered_personal_value`, keep `[PERSONAL_MEMORY]` in think-only finalization repair, and make owner-memory U# outrank workspace/source-code evidence for owner facts.

## Design Rules

- No `user_id`; `phenom-zig` is personal-use only.
- No SDK Mem0 integration.
- No embeddings, vector DB, spaCy, fastembed, graph DB, or dashboard in the first cut.
- Memory storage is ADD-only except `forget`, which marks records inactive.
- Never persist raw tool output, E#/S# blocks, logs, patches, hidden reasoning, or full transcripts.
- Exact duplicate prevention uses a normalized hash.
- Retrieval uses FTS5/BM25 plus confidence and recency ordering.

## MEMORY/SKILLS Reliability Addendum

- [x] Treat `SKILLS.md` as active local operating rules when loaded or retrieved.
- [x] Treat `MEMORY.md` as distilled project/task context: active work, visible outcomes, decisions, and verified project facts that keep the model centered.
- [x] Load `MEMORY.md`/`SKILLS.md` during the tool loop when present, without relying on `PHENOM_MODEL_CONTEXT_V1`.
- [x] Keep `PERSONAL_MEMORY` separate as mem0-like owner memory in SQLite.
- [x] Store automatic project-task distillation only in a bounded managed section of `MEMORY.md`.
- [x] Reject raw tool output, evidence blocks, session dialogue blocks, tool calls, logs, patches, and hidden reasoning from durable `MEMORY.md`/`SKILLS.md`.
- [x] Block or repair final answers that deny loaded/retrieved `MEMORY.md`/`SKILLS.md`.
- [x] Prove the regression where retrieved `SKILLS.md` said `Nao commitar sem rodar testes` but the model answered that no local rule existed.

Verification run:

- `zig test src/persistent_context.zig -lc -lsqlite3`
- `zig build test`
- `zig build`
- `git diff --check`
- `sh tools/check_user_rule_promotion_flow.sh ./zig-out/bin/phenom`
- `sh tools/check_memory_persistence.sh ./zig-out/bin/phenom`
- `sh tools/check_personal_memory_flow.sh ./zig-out/bin/phenom`
- `sh tools/check_personal_memory_ambiguity_100.sh ./zig-out/bin/phenom`
- `sh tools/check_artifact_create_flow.sh ./zig-out/bin/phenom`

## References

- `src/persistent_context.zig`: local durable project memory and skills.
- `src/audit.zig`: SQLite audit, `session_focus`, `events_fts`, FTS search patterns.
- `src/session_context.zig`: model-visible session evidence rendering.
- `src/model_context.zig`: bounded context buckets and raw-context leak checks.
- `src/contracts.zig`: model-visible tool registry and active contract allowlists.
- `src/context_profile.zig`: tool schemas shown to the model.
- `src/tool_call.zig`: XML/JSON tool-call parsing.
- `src/main.zig`: initial context assembly and tool-loop execution.
