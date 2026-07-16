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
    \\intent states what session evidence to recover. terms are concrete keys: names, entities, symbols, paths, errors, decisions, or exact topic words. Do not use the user's vague request as terms.
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn codeEvidenceSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\set_operational_contract(requiresInspection, requiresMutation, requiresRuntimeValidation, requiresBrowserDiagnostics, requiresMemoryPromotion?, reason?)
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol|diagnostic, stage=minimum|candidates|expand?, selectedCandidate?, selectedCandidates?, start_line=1, max_lines=12, compact=false)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Model chooses intent/terms; controller only executes. Prior-session claims require search_session and S#.
    \\collect_evidence without path: first decide intent, then terms=concrete code keys from reasoning. For function/type/symbol/file identity use stage=candidates, compare C#, then stage=expand selectedCandidate. Do not use auto overview for identity questions.
    \\search_session: first decide intent, then terms=concrete keys from SESSION_FOCUS/reasoning. Do not pass generic user words unless they are the remembered content.
    \\<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=requiresMemoryPromotion>false</parameter><parameter=reason>short reason</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=intent>compare source definitions</parameter><parameter=strategy>symbol</parameter><parameter=stage>candidates</parameter><parameter=terms>SymbolName FileName ErrorCode</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C1</parameter><parameter=max_lines>32</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=path>relative/path</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>12</parameter></function></tool_call>
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn activeContractSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol|diagnostic, stage=minimum|candidates|expand?, selectedCandidate?, selectedCandidates?, start_line=1, max_lines=12, compact=false)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Contract active. Do not call set_operational_contract again. Pathless collect_evidence needs intent+terms. For symbol identity use stage=candidates then stage=expand selectedCandidate. Do not use auto overview for identity questions.
    \\<tool_call><function=collect_evidence><parameter=intent>compare source definitions</parameter><parameter=strategy>symbol</parameter><parameter=stage>candidates</parameter><parameter=terms>SymbolName FileName ErrorCode</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C1</parameter><parameter=max_lines>32</parameter></function></tool_call>
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn activeContractSchemaFor(contract: contracts.ContractName) []const u8 {
    return switch (contract) {
        .mutate_file => mutateFileSchema(),
        .validate_work => validateWorkSchema(),
        .inspect_runtime => inspectRuntimeSchema(),
        .memory => memorySchema(),
        else => activeContractSchema(),
    };
}

pub fn mutateFileSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol|diagnostic, stage=minimum|candidates|expand?, selectedCandidate?, selectedCandidates?, start_line=1, max_lines=12, compact=false)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\apply_patch(operation=edit|create|delete|rename, path, destinationPath?, content?, contextId?, repeated search/replace?)
    \\Mutation contract active. Use collect_evidence first when editing/deleting/renaming. edit accepts repeated contextId/search/replace hunks; every search must be exact and unique in the original file. create requires content and refuses overwrite. delete/rename require fresh contextId. The controller rejects missing or stale patch context.
    \\<tool_call><function=apply_patch><parameter=operation>edit</parameter><parameter=path>relative/path</parameter><parameter=contextId>ctx_...</parameter><parameter=search>exact old text</parameter><parameter=replace>exact new text</parameter></function></tool_call>
    ;
}

pub fn validateWorkSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=diagnostic|path, start_line=1, max_lines=12)
    \\validate_syntax(path)
    \\Validation contract active. Only syntax validation is available in this Zig controller pass.
    \\<tool_call><function=validate_syntax><parameter=path>relative/path.zig</parameter></function></tool_call>
    ;
}

pub fn inspectRuntimeSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=diagnostic|path, start_line=1, max_lines=12)
    \\inspect_runtime(path?)
    \\Runtime inspection contract active. This pass returns controller capability evidence only; browser/runtime execution is not opened unless implemented by the controller.
    \\<tool_call><function=inspect_runtime><parameter=path>relative/path</parameter></function></tool_call>
    ;
}

pub fn memorySchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol|diagnostic, start_line=1, max_lines=12)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\promote_context(target=memory|skills, text)
    \\Memory contract active. Promote only explicit user-confirmed preferences, rules, or verified practical facts. Never promote raw tool output, E#/S# blocks, logs, patches, or unverified model guesses.
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
    \\Only valid output in this state is the XML tool_call below with one visible C# candidate. No prose. No analysis. C# candidates are not E# evidence.
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C1</parameter><parameter=max_lines>32</parameter></function></tool_call>
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

    const evidence = toolSchema(.code_evidence, .initial);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "first decide intent") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "Do not use auto overview for identity questions") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "generic user words") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "stage=candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "selectedCandidate") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "need?") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "targetFiles?") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "scopeRoot?") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "stage=minimum") != null);

    try std.testing.expectEqualStrings("", toolSchema(.code_evidence, .after_collect_evidence));
    try std.testing.expectEqualStrings("", toolSchema(.session_recall, .after_search_session));

    const expand = candidateExpandSchema();
    try std.testing.expect(std.mem.indexOf(u8, expand, "stage=expand") != null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "search_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "strategy=auto") == null);
}

test "contract schemas expose executor families only after contract selection" {
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
    try std.testing.expect(std.mem.indexOf(u8, memory, "apply_patch") == null);
}
