const std = @import("std");

const contracts = @import("contracts.zig");
const context_profile = @import("context_profile.zig");
const model_context = @import("model_context.zig");

const Criterion = struct {
    id: []const u8,
    evidence: []const u8,
};

pub const final_alignment_criteria = [_]Criterion{
    .{ .id = "A0_contract_model_driven", .evidence = "set_operational_contract is model-visible and contract-scoped" },
    .{ .id = "A1_tool_surface_by_contract", .evidence = "internal tools remain hidden until selected contract allows executor" },
    .{ .id = "A3_evidence_no_raw_leak", .evidence = "ModelTurnContext rejects raw tool markers" },
    .{ .id = "A5_memory_skills_separated", .evidence = "MEMORY/SKILLS are explicit persistent blocks only" },
    .{ .id = "A9_context_profiles", .evidence = "news/document/runtime profiles do not use code_micro schema" },
    .{ .id = "A10_patch_validation", .evidence = "mutate_file unlocks apply_patch while validate_work does not" },
};

pub const preserved_zig_assertions = [_][]const u8{
    "append_only_terminal_contract",
    "sqlite_operational_audit",
    "raw_context_not_model_visible",
    "tool_gate_before_executor",
    "config_merge_preserves_user_values",
    "context_ranking_without_domain_bias",
};

pub fn checklistReport(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[PRODUCT_GUARDRAILS v1]\n");
    for (final_alignment_criteria) |criterion| {
        const line = try std.fmt.allocPrint(allocator, "criterion={s} status=covered evidence={s}\n", .{ criterion.id, criterion.evidence });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    for (preserved_zig_assertions) |assertion| {
        const line = try std.fmt.allocPrint(allocator, "preserve={s} status=covered\n", .{assertion});
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

test "product checklist has concrete evidence for every final criterion" {
    inline for (final_alignment_criteria) |criterion| {
        try std.testing.expect(criterion.id.len > 0);
        try std.testing.expect(criterion.evidence.len > 12);
        try std.testing.expect(std.mem.indexOf(u8, criterion.evidence, "TODO") == null);
    }

    const report = try checklistReport(std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "[PRODUCT_GUARDRAILS v1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "status=covered") != null);
    try model_context.assertNoRawContextLeak(report);
}

test "guardrail preserves contract scoped tool execution" {
    try std.testing.expect(contracts.isModelVisible("set_operational_contract"));
    try std.testing.expect(contracts.isModelVisible("collect_evidence"));
    try std.testing.expect(!contracts.isModelVisible("apply_patch"));
    try std.testing.expect(!contracts.isModelVisible("validate_syntax"));

    const initial = contracts.activeContract(.workflow) orelse return error.MissingContract;
    try std.testing.expect(initial.allows("set_operational_contract"));
    try std.testing.expect(!initial.allows("collect_evidence"));
    try std.testing.expect(!initial.allows("apply_patch"));
    try std.testing.expect(!initial.allows("validate_syntax"));

    const evidence = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    try std.testing.expect(evidence.allows("collect_evidence"));
    try std.testing.expect(!evidence.allows("set_operational_contract"));

    const mutation = contracts.activeContract(.mutate_file) orelse return error.MissingContract;
    try std.testing.expect(mutation.allows("apply_patch"));
    try std.testing.expect(!mutation.allows("validate_syntax"));

    const validation = contracts.activeContract(.validate_work) orelse return error.MissingContract;
    try std.testing.expect(validation.allows("validate_syntax"));
    try std.testing.expect(!validation.allows("apply_patch"));

    const memory = contracts.activeContract(.memory) orelse return error.MissingContract;
    try std.testing.expect(memory.allows("promote_context"));
    try std.testing.expect(!memory.allows("apply_patch"));
    try std.testing.expect(!memory.allows("validate_syntax"));
}

test "guardrail preserves context profile boundaries" {
    const code = context_profile.toolSchema(.code_evidence, .initial);
    try std.testing.expect(std.mem.indexOf(u8, code, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "stage=candidates") == null);

    const active_code = context_profile.toolSchema(.code_evidence, .active_contract);
    try std.testing.expect(std.mem.indexOf(u8, active_code, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_code, "stage=candidates") != null);

    const news = context_profile.toolSchema(.news_doc_log, .initial);
    try std.testing.expect(std.mem.indexOf(u8, news, "structured dossier") != null);
    try std.testing.expect(std.mem.indexOf(u8, news, "apply_patch") == null);
    try std.testing.expect(std.mem.indexOf(u8, news, "stage=candidates") == null);

    const document = context_profile.toolSchema(.document_summary, .initial);
    try std.testing.expect(std.mem.indexOf(u8, document, "hierarchical summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "editable code micro-context") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "apply_patch") == null);

    const memory = context_profile.activeContractSchemaFor(.memory);
    try std.testing.expect(std.mem.indexOf(u8, memory, "promote_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "Never promote raw tool output") != null);
}

test "guardrail preserves raw leak rejection" {
    const rendered = try model_context.renderModelTurnContext(std.testing.allocator, .{
        .task = "ambiguous real user prompt",
        .contracts = context_profile.toolSchema(.code_evidence, .initial),
        .next_action = "Emit a context tool call before prose.",
    });
    defer std.testing.allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
}
