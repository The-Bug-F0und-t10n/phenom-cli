const std = @import("std");
const contracts = @import("contracts.zig");

pub const ContextProfile = enum {
    code_micro,
    session_recall,
    code_evidence,
    news_doc_log,
    document_summary,
    runtime_diagnostics,
};

pub const Domain = enum {
    code,
    session,
    news,
    document,
    runtime,
};

pub const ContractState = enum {
    initial,
    active_contract,
    after_search_session,
    after_collect_evidence,
};

pub const SelectInput = struct {
    enable_tool_loop: bool,
    domain: Domain = .code,
};

pub fn select(input: SelectInput) ContextProfile {
    if (!input.enable_tool_loop) return .code_micro;
    return switch (input.domain) {
        .code => .code_evidence,
        .session => .session_recall,
        .news => .news_doc_log,
        .document => .document_summary,
        .runtime => .runtime_diagnostics,
    };
}

pub fn modeName(profile: ContextProfile) []const u8 {
    return switch (profile) {
        .code_micro => "code_micro",
        .session_recall => "session_recall",
        .code_evidence => "code_evidence",
        .news_doc_log => "news_doc_log",
        .document_summary => "document_summary",
        .runtime_diagnostics => "runtime_diagnostics",
    };
}

pub fn toolSchema(profile: ContextProfile, state: ContractState) []const u8 {
    return switch (state) {
        .after_search_session, .after_collect_evidence => "",
        .active_contract => activeContractSchema(),
        .initial => switch (profile) {
            .code_micro => codeMicroSchema(),
            .session_recall => sessionRecallSchema(),
            .code_evidence => codeEvidenceSchema(),
            .news_doc_log => newsDocLogSchema(),
            .document_summary => documentSummarySchema(),
            .runtime_diagnostics => runtimeDiagnosticsSchema(),
        },
    };
}

pub fn codeMicroSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\No tool schema is active for this micro turn unless the controller provides one later.
    ;
}

pub fn sessionRecallSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\search_session(intent?, terms, scope=current|all, session?)
    \\First output: exactly one search_session tool call, not prose. SESSION_FOCUS is not evidence; use it only to choose retrieval keys.
    \\search_session returns retrieved candidates, not confirmed truth; judge direct support before using S# in final claims.
    \\intent states what session evidence to recover. terms are concrete keys: names, entities, symbols, paths, errors, decisions, or exact topic words. Do not use the user's vague request as terms.
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn codeEvidenceSchema() []const u8 {
    return initialRouterSchema();
}

pub fn initialRouterSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\set_operational_contract(contract=answer_only|collect_evidence|mutate_file|validate_work|inspect_runtime|search_web|rag_web|memory, strategyId?, query?, intent?, terms?, target?, budget_bytes?, requiresInspection?, requiresMutation?, requiresRuntimeValidation?, requiresBrowserDiagnostics?, requiresMemoryPromotion?, reason?)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Initial router. Answer directly when enough; otherwise emit one contract declaration or one search_session call. Controller never infers intent from prompt keywords.
    \\Use model-selected query/terms only: exact external fact/entity for search_web/rag_web, concrete workspace keys for collect_evidence, concrete prior-session keys for search_session, concise durable rule text for memory promotion.
    \\Declare before executors. Full executor schema appears only after the selected contract is active.
    \\<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>exact external fact or entity</parameter></function></tool_call>
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn activeContractSchema() []const u8 {
    return collectEvidenceActiveSchema();
}

pub fn workflowActiveSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\set_operational_contract(contract=answer_only|collect_evidence|mutate_file|validate_work|inspect_runtime|search_web|rag_web|memory, query?, intent?, terms?, target?, budget_bytes?, requiresInspection?, requiresMutation?, requiresRuntimeValidation?, requiresBrowserDiagnostics?, requiresMemoryPromotion?, reason?)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Workflow contract active. Select one operational contract or answer directly. Executors are unavailable until their specific contract is selected.
    ;
}

pub fn collectEvidenceActiveSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(strategyId?, source=auto|file|code|git|web|diagnostic|rag?, intent?, need?, path?, target?, httpSearch=true|false?, query?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol|diagnostic|diff|history|show|reflog|unreachable, stage=overview|minimum|candidates|expand?, selectedCandidate?, selectedCandidates?, start_line=1, max_lines=12, compact=false)
    \\web_search(target?=http://host/path, query, budget_bytes?)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Contract active. set_operational_contract is allowed only for an explicit model-selected switch to a different contract after tool evidence changes the strategy; do not repeat the same contract. strategyId names a registered strategy descriptor; examples: collect_micro_context_for_simple_analysis, collect_symbol_candidates, collect_git_reflog, collect_web_evidence_distilled. Web retrieval runs only from a model-declared contract/query or a model web_search call. web_search accepts target=http://... plus query; if target is omitted, the controller uses the built-in search provider, or configured web_search_url/PHENOM_WEB_SEARCH_URL override, with the model-selected query. query must express the user's external evidence intent, not generic prompt text. collect_evidence uses web only with strategyId=collect_web_evidence_distilled or httpSearch=true and target=http://... plus query/intent/terms; missing or false httpSearch means no rag_web. Web results are distilled to small WEB_EVIDENCE before context insertion. source selects the internal collector family without exposing internal tools. Use strategyId=collect_git_reflog or source=git strategy=reflog for repository history evidence. Pathless workspace collect_evidence needs intent+terms unless source=git or stage=overview. Broad map -> stage=overview strategy=auto no terms. Symbol identity -> stage=candidates then stage=expand selectedCandidate. Do not use auto overview for identity questions.
    \\<tool_call><function=collect_evidence><parameter=strategyId>collect_micro_context_for_simple_analysis</parameter><parameter=intent>compare source definitions</parameter><parameter=terms>SymbolName FileName ErrorCode</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=intent>compare source definitions</parameter><parameter=strategy>symbol</parameter><parameter=stage>candidates</parameter><parameter=terms>SymbolName FileName ErrorCode</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=strategyId>collect_git_reflog</parameter><parameter=intent>recover deleted commit touching component</parameter><parameter=terms>SymbolName FileName</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C#</parameter><parameter=max_lines>32</parameter></function></tool_call>
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn activeContractSchemaFor(contract: contracts.ContractName) []const u8 {
    return switch (contract) {
        .workflow => workflowActiveSchema(),
        .answer_only => answerOnlySchema(),
        .collect_evidence => collectEvidenceActiveSchema(),
        .mutate_file => mutateFileSchema(),
        .validate_work => validateWorkSchema(),
        .inspect_runtime => inspectRuntimeSchema(),
        .search_web => searchWebSchema(),
        .memory => memorySchema(),
        else => activeContractSchema(),
    };
}

pub fn answerOnlySchema() []const u8 {
    return
    \\[TOOLS v1]
    \\No tool schema is active. Answer directly from the current conversation and clearly mark non-verified technical estimates when applicable.
    ;
}

pub fn mutateFileSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(strategyId?, source=auto|file|code|git|diagnostic|rag?, intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol|diagnostic|diff|history|show|reflog|unreachable, stage=minimum|candidates|expand?, selectedCandidate?, selectedCandidates?, start_line=1, max_lines=12, compact=false)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\apply_patch(operation=edit|create|delete|rename, path, destinationPath?, content?, contextId?, repeated search/replace?)
    \\set_operational_contract(contract=answer_only|collect_evidence|validate_work|inspect_runtime|search_web|memory, query?, reason?)
    \\Mutation contract active. Use collect_evidence first when editing/deleting/renaming. Use strategy=diff to inspect existing Git changes. edit accepts repeated contextId/search/replace hunks; every search must be exact and unique in the original file. create requires content and refuses overwrite. delete/rename require fresh contextId. The controller rejects missing or stale patch context. Use set_operational_contract only for an explicit switch to a different contract.
    \\<tool_call><function=apply_patch><parameter=operation>edit</parameter><parameter=path>relative/path</parameter><parameter=contextId>ctx_...</parameter><parameter=search>exact old text</parameter><parameter=replace>exact new text</parameter></function></tool_call>
    ;
}

pub fn validateWorkSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(strategyId?, source=diagnostic|file?, intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=diagnostic|path, start_line=1, max_lines=12)
    \\validate_syntax(path)
    \\set_operational_contract(contract=answer_only|collect_evidence|mutate_file|inspect_runtime|search_web|memory, query?, reason?)
    \\Validation contract active. Only syntax validation is available in this Zig controller pass. Use set_operational_contract only for an explicit switch to a different contract.
    \\<tool_call><function=validate_syntax><parameter=path>relative/path.zig</parameter></function></tool_call>
    ;
}

pub fn inspectRuntimeSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(strategyId?, source=diagnostic|file|web?, intent?, need?, path?, target?, httpSearch=true|false?, query?, targetFiles?, scopeRoot?, terms?, strategy=diagnostic|path, start_line=1, max_lines=12)
    \\web_search(target?=http://host/path, query, budget_bytes?)
    \\inspect_runtime(target? http://host:port/path or path?)
    \\set_operational_contract(contract=answer_only|collect_evidence|mutate_file|validate_work|search_web|memory, query?, reason?)
    \\Runtime inspection contract active. inspect_runtime performs bounded HTTP GET for runtime status/body. web_search is model-called only, needs a query matching the user's external-evidence intent, and returns distilled WEB_EVIDENCE for answer grounding. If target is omitted, the built-in search provider is used; configured web_search_url/PHENOM_WEB_SEARCH_URL overrides it. collect_evidence URL fetch requires httpSearch=true. HTTPS/DOM/browser automation is not available in this pass. Use set_operational_contract only for an explicit switch to a different contract.
    \\<tool_call><function=inspect_runtime><parameter=target>http://127.0.0.1:3000/health</parameter></function></tool_call>
    ;
}

pub fn searchWebSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\web_search(strategyId=search_web_distilled?, target?=http://host/path, query, budget_bytes?)
    \\set_operational_contract(contract=answer_only|collect_evidence|mutate_file|validate_work|inspect_runtime|memory, reason?)
    \\search_web contract active. Web retrieval is model-called or contract-declared only. query must express the user's external evidence intent as a narrow search phrase. If the contract was declared with query, the controller may already execute this web_search before asking again. When verifying or identifying a named entity/fact, include the exact requested entity/fact in query so the source can confirm or refute it. Refined queries must not add guessed roles, categories, locations, nationality, platform, biography, or accusations unless those details are in USER_TASK or current E# evidence. Similar names, adjacent topics, partial matches, and "probably the same" are not evidence. If target is omitted, the built-in search provider is used; configured web_search_url/PHENOM_WEB_SEARCH_URL overrides it. Only include target when the user supplied an explicit HTTP/HTTPS URL or the current E# evidence already contains one. Return distilled WEB_EVIDENCE, not raw page text. Do not ask permission for another search while search_web is active; emit a non-duplicated grounded web_search or answer that evidence is insufficient. Use set_operational_contract only to switch to a different contract after web evidence changes the operational strategy.
    \\<tool_call><function=web_search><parameter=strategyId>search_web_distilled</parameter><parameter=query>specific user intent</parameter></function></tool_call>
    ;
}

pub fn memorySchema() []const u8 {
    return
    \\[TOOLS v1]
    \\search_persistent_context(target=memory|skills|both, terms, intent?, budget_bytes?)
    \\promote_context(target=memory|skills, text)
    \\set_operational_contract(contract=answer_only|collect_evidence|mutate_file|validate_work|inspect_runtime|search_web, query?, reason?)
    \\Memory contract active. Search MEMORY/SKILLS by model-selected terms before applying existing local durable facts/rules. Retrieved SKILLS are active response rules when relevant. If the user asks for a local rule/preference/protocol, answer only from directly retrieved MEMORY/SKILLS entries; do not add adjacent advice, generic best practices, or inferred extras. Promote explicit user-confirmed future-turn rules/preferences/operational constraints to skills as one concise interpreted imperative. Promote verified reusable project/workdir facts to memory. Never promote raw tool output, E#/S# blocks, logs, patches, unverified model guesses, or one-off task instructions. If the user wording is not durable enough to persist, ask/answer without promotion. Use set_operational_contract only for an explicit switch to a different contract.
    \\<tool_call><function=search_persistent_context><parameter=target>both</parameter><parameter=terms>specific local rule preference protocol fact</parameter></function></tool_call>
    \\<tool_call><function=promote_context><parameter=target>skills</parameter><parameter=text>Prefer concise final answers.</parameter></function></tool_call>
    ;
}

pub fn newsDocLogSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\Context profile: news_doc_log. Do not reduce news, documents, or logs to code micro-context. Use a structured dossier/table contract when the executor is available.
    ;
}

pub fn documentSummarySchema() []const u8 {
    return
    \\[TOOLS v1]
    \\Context profile: document_summary. Use hierarchical summary evidence, not editable code micro-context.
    ;
}

pub fn runtimeDiagnosticsSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\Context profile: runtime_diagnostics. Use diagnostic/runtime evidence, not source identity candidates.
    ;
}

pub fn candidateExpandSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(stage=expand, selectedCandidate, max_lines=32)
    \\Only valid output in this state is one XML tool_call, or one visible line SELECTED_CANDIDATE: C#. Choose the best visible C# candidate for the task. Replace C# with that candidate ID. No prose. No analysis. C# candidates are not E# evidence.
    \\When the task asks which function/type/file and a visible source=local_symbol_ast or source=symbol_ast candidate has a concrete def: fn/type/file matching the task, prefer it over a broad source=module_entrypoint container.
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C#</parameter><parameter=max_lines>32</parameter></function></tool_call>
    ;
}

test "profile selection uses operational state only" {
    try std.testing.expectEqual(ContextProfile.code_micro, select(.{ .enable_tool_loop = false }));
    try std.testing.expectEqual(ContextProfile.code_evidence, select(.{ .enable_tool_loop = true }));
    try std.testing.expectEqual(ContextProfile.session_recall, select(.{ .enable_tool_loop = true, .domain = .session }));
    try std.testing.expectEqual(ContextProfile.news_doc_log, select(.{ .enable_tool_loop = true, .domain = .news }));
    try std.testing.expectEqual(ContextProfile.document_summary, select(.{ .enable_tool_loop = true, .domain = .document }));
    try std.testing.expectEqual(ContextProfile.runtime_diagnostics, select(.{ .enable_tool_loop = true, .domain = .runtime }));
}

test "schemas are state scoped" {
    const recall = toolSchema(.session_recall, .initial);
    try std.testing.expect(std.mem.indexOf(u8, recall, "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "collect_evidence") == null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "set_operational_contract") == null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "intent states what session evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "concrete keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "not confirmed truth") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "judge direct support") != null);

    const evidence = toolSchema(.code_evidence, .initial);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "Initial router") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "Controller never infers intent from prompt keywords") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "Use model-selected query/terms only") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "Full executor schema appears only after") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "exact external fact or entity") != null);
    try std.testing.expect(evidence.len < 1500);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "stage=overview") == null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "stage=candidates") == null);

    const active_evidence = toolSchema(.code_evidence, .active_contract);
    try std.testing.expect(std.mem.indexOf(u8, active_evidence, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_evidence, "stage=candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_evidence, "selectedCandidate") != null);

    try std.testing.expectEqualStrings("", toolSchema(.code_evidence, .after_collect_evidence));
    try std.testing.expectEqualStrings("", toolSchema(.session_recall, .after_search_session));

    const expand = candidateExpandSchema();
    try std.testing.expect(std.mem.indexOf(u8, expand, "stage=expand") != null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "best visible C# candidate") != null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "source=local_symbol_ast") != null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "selectedCandidate>C1") == null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "search_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "strategy=auto") == null);

    const memory = memorySchema();
    try std.testing.expect(std.mem.indexOf(u8, memory, "Retrieved SKILLS are active response rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "answer only from directly retrieved MEMORY/SKILLS entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "generic best practices") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "future-turn rules/preferences/operational constraints") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "one concise interpreted imperative") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "one-off task instructions") != null);
}

test "contract schemas expose executor families only after contract selection" {
    const workflow = activeContractSchemaFor(.workflow);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "Workflow contract active") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "Initial router") == null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "Executors are unavailable") != null);

    const collect = activeContractSchemaFor(.collect_evidence);
    try std.testing.expect(std.mem.indexOf(u8, collect, "Contract active") != null);
    try std.testing.expect(std.mem.indexOf(u8, collect, "collect_evidence(") != null);
    try std.testing.expect(std.mem.indexOf(u8, collect, "stage=candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, collect, "apply_patch") == null);

    const mutation = activeContractSchemaFor(.mutate_file);
    try std.testing.expect(std.mem.indexOf(u8, mutation, "apply_patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, mutation, "contextId") != null);
    try std.testing.expect(std.mem.indexOf(u8, mutation, "delete/rename require fresh contextId") != null);
    try std.testing.expect(std.mem.indexOf(u8, mutation, "refuses overwrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, mutation, "validate_syntax") == null);

    const validation = activeContractSchemaFor(.validate_work);
    try std.testing.expect(std.mem.indexOf(u8, validation, "validate_syntax") != null);
    try std.testing.expect(std.mem.indexOf(u8, validation, "apply_patch") == null);

    const runtime = activeContractSchemaFor(.inspect_runtime);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "inspect_runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "apply_patch") == null);

    const news = toolSchema(.news_doc_log, .initial);
    try std.testing.expect(std.mem.indexOf(u8, news, "structured dossier") != null);

    const memory = activeContractSchemaFor(.memory);
    try std.testing.expect(std.mem.indexOf(u8, memory, "promote_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "Never promote raw tool output") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "<parameter=target>skills</parameter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "interpreted") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "inferred extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "apply_patch") == null);

    const web = activeContractSchemaFor(.search_web);
    try std.testing.expect(std.mem.indexOf(u8, web, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "PHENOM_WEB_SEARCH_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "Only include target when the user supplied") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "contract was declared with query") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "exact requested entity/fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "must not add guessed roles") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "Do not ask permission for another search") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "Similar names") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "not evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "127.0.0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, web, "<parameter=query>specific user intent</parameter>") != null);
}
