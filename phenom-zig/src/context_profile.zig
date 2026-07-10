const std = @import("std");

pub const ContextProfile = enum {
    code_micro,
    session_recall,
    code_evidence,
    news_doc_log,
};

pub const ContractState = enum {
    initial,
    active_contract,
    after_search_session,
    after_collect_evidence,
};

pub const SelectInput = struct {
    enable_tool_loop: bool,
};

pub fn select(input: SelectInput) ContextProfile {
    if (!input.enable_tool_loop) return .code_micro;
    return .code_evidence;
}

pub fn modeName(profile: ContextProfile) []const u8 {
    return switch (profile) {
        .code_micro => "code_micro",
        .session_recall => "session_recall",
        .code_evidence => "code_evidence",
        .news_doc_log => "news_doc_log",
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
            .news_doc_log => "",
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
    \\set_operational_contract(requiresInspection, requiresMutation, requiresRuntimeValidation, requiresBrowserDiagnostics, reason?)
    \\collect_evidence(intent?, path?, terms?, strategy=auto|path|lexical|symbol|diagnostic, stage=candidates|expand?, selectedCandidate?, start_line=1, max_lines=12, compact=false)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Model chooses intent/terms; controller only executes. Prior-session claims require search_session and S#.
    \\collect_evidence without path: first decide intent, then terms=concrete code keys from reasoning. For function/type/symbol/file identity use stage=candidates, compare C#, then stage=expand selectedCandidate. Do not use auto overview for identity questions.
    \\search_session: first decide intent, then terms=concrete keys from SESSION_FOCUS/reasoning. Do not pass generic user words unless they are the remembered content.
    \\<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>short reason</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=intent>compare source definitions</parameter><parameter=strategy>symbol</parameter><parameter=stage>candidates</parameter><parameter=terms>SymbolName FileName ErrorCode</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C1</parameter><parameter=max_lines>32</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=path>relative/path</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>12</parameter></function></tool_call>
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn activeContractSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, path?, terms?, strategy=auto|path|lexical|symbol|diagnostic, stage=candidates|expand?, selectedCandidate?, start_line=1, max_lines=12, compact=false)
    \\search_session(intent?, terms, scope=current|all, session?)
    \\Contract active. Do not call set_operational_contract again. Pathless collect_evidence needs intent+terms. For symbol identity use stage=candidates then stage=expand selectedCandidate. Do not use auto overview for identity questions.
    \\<tool_call><function=collect_evidence><parameter=intent>compare source definitions</parameter><parameter=strategy>symbol</parameter><parameter=stage>candidates</parameter><parameter=terms>SymbolName FileName ErrorCode</parameter></function></tool_call>
    \\<tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C1</parameter><parameter=max_lines>32</parameter></function></tool_call>
    \\<tool_call><function=search_session><parameter=intent>recover prior decision</parameter><parameter=terms>TopicName EntityName DecisionKey</parameter><parameter=scope>current</parameter></function></tool_call>
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

    try std.testing.expectEqualStrings("", toolSchema(.code_evidence, .after_collect_evidence));
    try std.testing.expectEqualStrings("", toolSchema(.session_recall, .after_search_session));

    const expand = candidateExpandSchema();
    try std.testing.expect(std.mem.indexOf(u8, expand, "stage=expand") != null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "search_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, expand, "strategy=auto") == null);
}
