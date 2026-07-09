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
        \\search_session(terms, scope=current|all, session?)
        \\This profile is active because prior-session recall may be required. Your first output in this profile must be exactly one search_session tool call, not prose. SESSION_FOCUS is not evidence; use it only to choose terms from your current reasoning.
        \\Format current session:
        \\<tool_call><function=search_session><parameter=terms>prior fact to recover</parameter><parameter=scope>current</parameter></function></tool_call>
        \\Format all sessions:
        \\<tool_call><function=search_session><parameter=terms>prior fact to recover</parameter><parameter=scope>all</parameter></function></tool_call>
    ;
}

pub fn codeEvidenceSchema() []const u8 {
    return
        \\[TOOLS v1]
        \\set_operational_contract(requiresInspection, requiresMutation, requiresRuntimeValidation, requiresBrowserDiagnostics, reason?)
        \\collect_evidence(path?, terms?, strategy=auto|path|lexical|symbol|diagnostic, start_line=1, max_lines=12, compact=false)
        \\search_session(terms, scope=current|all, session?)
        \\The model decides search intent. The controller only executes announced contracts and returns evidence. SESSION_FOCUS is not evidence; use it only to choose whether search_session is needed.
        \\Any claim about prior conversation/session content must call search_session first and cite returned S# evidence. Do not answer that session history is unavailable while search_session is advertised.
        \\Format contract:
        \\<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>short reason</parameter></function></tool_call>
        \\Format evidence:
        \\<tool_call><function=collect_evidence><parameter=strategy>auto</parameter><parameter=terms>what to find</parameter></function></tool_call>
        \\Format path:
        \\<tool_call><function=collect_evidence><parameter=path>relative/path</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>12</parameter></function></tool_call>
        \\Format session:
        \\<tool_call><function=search_session><parameter=terms>prior fact to recover</parameter><parameter=scope>current</parameter></function></tool_call>
    ;
}

pub fn activeContractSchema() []const u8 {
    return
        \\[TOOLS v1]
        \\collect_evidence(path?, terms?, strategy=auto|path|lexical|symbol|diagnostic, start_line=1, max_lines=12, compact=false)
        \\search_session(terms, scope=current|all, session?)
        \\The operational contract is active. Do not call set_operational_contract again.
        \\Format evidence:
        \\<tool_call><function=collect_evidence><parameter=strategy>auto</parameter><parameter=terms>what to find</parameter></function></tool_call>
        \\Format session:
        \\<tool_call><function=search_session><parameter=terms>prior fact to recover</parameter><parameter=scope>current</parameter></function></tool_call>
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

    const evidence = toolSchema(.code_evidence, .initial);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "set_operational_contract") != null);

    try std.testing.expectEqualStrings("", toolSchema(.code_evidence, .after_collect_evidence));
    try std.testing.expectEqualStrings("", toolSchema(.session_recall, .after_search_session));
}
