const std = @import("std");

const apply_patch_tool = @import("apply_patch_tool.zig");
const audit = @import("audit.zig");
const contracts = @import("contracts.zig");
const strategy_registry = @import("strategy_registry.zig");
const tool_call = @import("tool_call.zig");

pub const max_pathless_collect_budget: usize = 6 * 1024;

pub fn phaseForTool(name: []const u8) audit.OperationalPhase {
    if (std.mem.eql(u8, name, "set_operational_contract")) return .contract;
    if (std.mem.eql(u8, name, "collect_evidence")) return .evidence;
    if (std.mem.eql(u8, name, "search_session")) return .evidence;
    if (std.mem.eql(u8, name, "search_persistent_context")) return .evidence;
    if (std.mem.eql(u8, name, "search_personal_memory")) return .evidence;
    if (std.mem.eql(u8, name, "apply_patch")) return .mutation;
    if (std.mem.eql(u8, name, "promote_context")) return .mutation;
    if (std.mem.eql(u8, name, "promote_personal_memory")) return .mutation;
    if (std.mem.eql(u8, name, "forget_personal_memory")) return .mutation;
    if (std.mem.eql(u8, name, "validate_syntax")) return .validation;
    if (std.mem.eql(u8, name, "inspect_runtime")) return .validation;
    if (std.mem.eql(u8, name, "web_search")) return .evidence;
    return .evidence;
}

pub fn collectEvidenceHasSearchText(call: *const tool_call.ToolCall) bool {
    return hasNonEmptyText(call.intent) or hasNonEmptyText(call.terms) or hasNonEmptyText(call.need) or hasNonEmptyText(call.target_files) or hasNonEmptyText(call.scope_root);
}

pub fn collectEvidenceSourceIs(call: *const tool_call.ToolCall, source: contracts.SourceName) bool {
    return collectEvidenceCallSource(call) == source;
}

pub fn collectEvidenceCallSource(call: *const tool_call.ToolCall) contracts.SourceName {
    if (call.strategy_id) |strategy_id| {
        if (strategy_registry.byId(strategy_id)) |descriptor| return descriptor.source;
    }
    return call.source orelse .auto;
}

pub fn collectEvidenceHasSearchPlaceholder(call: *const tool_call.ToolCall) bool {
    if (call.intent) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.terms) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.need) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.target_files) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.scope_root) |value| if (isSchemaPlaceholderText(value)) return true;
    return false;
}

pub fn hasNonEmptyText(value: ?[]const u8) bool {
    const text = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return text.len > 0;
}

pub fn isSchemaPlaceholderText(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const placeholders = [_][]const u8{
        "specific retrieval keys",
        "specific keys",
        "evidence to recover",
        "SymbolName FileName ErrorCode",
        "TopicName EntityName DecisionKey",
        "ConcreteSymbolOrPathTerms",
        "target files",
        "scope root",
    };
    for (placeholders) |placeholder| {
        if (std.ascii.eqlIgnoreCase(trimmed, placeholder)) return true;
    }
    return false;
}

pub fn collectEvidenceExecutionBudget(path: ?[]const u8, remaining_budget: usize) usize {
    if (path != null) return remaining_budget;
    return @min(remaining_budget, max_pathless_collect_budget);
}

pub fn isCollectEvidenceStage(call: *const tool_call.ToolCall, stage: []const u8) bool {
    const raw = call.stage orelse return false;
    return std.ascii.eqlIgnoreCase(raw, stage);
}

pub fn expandedCandidateNextAction(allow_more_evidence: bool, weak_evidence: bool) []const u8 {
    if (allow_more_evidence and weak_evidence) {
        return "The expanded candidate evidence is weak or generic. Emit one more collect_evidence call with a different selectedCandidate or refined intent+terms before answering.";
    }
    if (allow_more_evidence) {
        return "Answer only if cited E# directly covers the request. If the task is broad and this candidate covers only a fragment, emit one more collect_evidence call; do not ask permission. If naming a called/related function whose declaration is not in E#, collect it first.";
    }
    return "Answer using only cited E# evidence from the expanded candidate. If evidence is insufficient, say what is evidenced and what is not. Do not call tools again.";
}

pub fn candidateExpansionLineLimit(requested_max_lines: usize, candidate_start_line: usize, candidate_end_line: usize) usize {
    const candidate_lines = candidate_end_line - candidate_start_line + 1;
    const requested_lines = if (requested_max_lines == 12) @as(usize, 32) else requested_max_lines;
    return @min(requested_lines, candidate_lines);
}

pub fn firstSelectedCandidate(selected_candidates: ?[]const u8) ?[]const u8 {
    var raw = selected_candidates orelse return null;
    raw = std.mem.trim(u8, raw, " \t\r\n");
    if (raw.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, raw, " ,;\t\r\n");
    return it.next();
}

pub fn parsePatchOperation(value: ?[]const u8) !apply_patch_tool.Operation {
    const operation = value orelse return .edit;
    if (std.ascii.eqlIgnoreCase(operation, "edit")) return .edit;
    if (std.ascii.eqlIgnoreCase(operation, "create")) return .create;
    if (std.ascii.eqlIgnoreCase(operation, "delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(operation, "rename")) return .rename;
    return error.InvalidPatchOperation;
}

pub fn buildPatchArgs(
    allocator: std.mem.Allocator,
    operation: apply_patch_tool.Operation,
    path: []const u8,
    call: *const tool_call.ToolCall,
) !apply_patch_tool.Args {
    return switch (operation) {
        .edit => .{
            .operation = .edit,
            .path = path,
            .hunks = try buildEditHunks(allocator, call),
        },
        .create => .{
            .operation = .create,
            .path = path,
            .content = call.content orelse return error.MissingPatchContent,
            .hunks = &.{},
        },
        .delete => .{
            .operation = .delete,
            .path = path,
            .hunks = try buildContextOnlyHunk(allocator, call),
        },
        .rename => .{
            .operation = .rename,
            .path = path,
            .destination_path = call.destination_path orelse return error.MissingPatchDestination,
            .hunks = try buildContextOnlyHunk(allocator, call),
        },
    };
}

fn buildEditHunks(allocator: std.mem.Allocator, call: *const tool_call.ToolCall) ![]const apply_patch_tool.Hunk {
    const searches = call.searches;
    const replaces = call.replaces;
    if (searches.len == 0) return error.MissingPatchSearch;
    if (searches.len != replaces.len) return error.PatchHunkCountMismatch;
    if (call.context_ids.len != 1 and call.context_ids.len != searches.len) return error.PatchContextCountMismatch;

    const hunks = try allocator.alloc(apply_patch_tool.Hunk, searches.len);
    errdefer allocator.free(hunks);
    for (searches, 0..) |search, idx| {
        hunks[idx] = .{
            .search = search,
            .replace = replaces[idx],
            .context_id = if (call.context_ids.len == 1) call.context_ids[0] else call.context_ids[idx],
        };
    }
    return hunks;
}

fn buildContextOnlyHunk(allocator: std.mem.Allocator, call: *const tool_call.ToolCall) ![]const apply_patch_tool.Hunk {
    const context_id = if (call.context_ids.len > 0) call.context_ids[0] else return error.MissingPatchContextId;
    const hunks = try allocator.alloc(apply_patch_tool.Hunk, 1);
    hunks[0] = .{ .search = "", .replace = "", .context_id = context_id };
    return hunks;
}

test "tool names map to operational phases" {
    try std.testing.expectEqual(audit.OperationalPhase.contract, phaseForTool("set_operational_contract"));
    try std.testing.expectEqual(audit.OperationalPhase.mutation, phaseForTool("apply_patch"));
    try std.testing.expectEqual(audit.OperationalPhase.validation, phaseForTool("validate_syntax"));
    try std.testing.expectEqual(audit.OperationalPhase.evidence, phaseForTool("collect_evidence"));
}

test "collect evidence search and budget policy is structural" {
    var call = tool_call.ToolCall{
        .name = "collect_evidence",
        .stage = "overview",
        .terms = "specific retrieval keys",
    };
    try std.testing.expect(collectEvidenceHasSearchText(&call));
    try std.testing.expect(collectEvidenceHasSearchPlaceholder(&call));
    try std.testing.expect(isCollectEvidenceStage(&call, "overview"));
    try std.testing.expectEqual(@as(usize, max_pathless_collect_budget), collectEvidenceExecutionBudget(null, 18 * 1024));
    try std.testing.expectEqual(@as(usize, 512), collectEvidenceExecutionBudget(null, 512));
    try std.testing.expectEqual(@as(usize, 18 * 1024), collectEvidenceExecutionBudget("src/main.zig", 18 * 1024));
}

test "candidate expansion helpers stay bounded" {
    try std.testing.expectEqual(@as(usize, 15), candidateExpansionLineLimit(32, 77, 91));
    try std.testing.expectEqual(@as(usize, 8), candidateExpansionLineLimit(8, 77, 91));
    try std.testing.expectEqualStrings("C2", firstSelectedCandidate("C2,C3").?);
    try std.testing.expectEqualStrings("C4", firstSelectedCandidate(" C4 C5 ").?);
    try std.testing.expect(firstSelectedCandidate(null) == null);
    try std.testing.expect(std.mem.indexOf(u8, expandedCandidateNextAction(false, false), "Do not call tools again") != null);
}

test "patch call policy validates operation and hunks" {
    try std.testing.expectEqual(apply_patch_tool.Operation.edit, try parsePatchOperation(null));
    try std.testing.expectEqual(apply_patch_tool.Operation.rename, try parsePatchOperation("rename"));
    try std.testing.expectError(error.InvalidPatchOperation, parsePatchOperation("copy"));

    const context_ids = [_][]const u8{"ctx_a"};
    const searches = [_][]const u8{ "old a", "old b" };
    const replaces = [_][]const u8{ "new a", "new b" };
    const edit_call = tool_call.ToolCall{
        .name = "apply_patch",
        .context_ids = &context_ids,
        .searches = &searches,
        .replaces = &replaces,
    };
    const edit = try buildPatchArgs(std.testing.allocator, .edit, "src/main.zig", &edit_call);
    defer std.testing.allocator.free(edit.hunks);
    try std.testing.expectEqual(@as(usize, 2), edit.hunks.len);
    try std.testing.expectEqualStrings("ctx_a", edit.hunks[1].context_id.?);

    const bad_call = tool_call.ToolCall{
        .name = "apply_patch",
        .context_ids = &context_ids,
        .searches = &searches,
        .replaces = &.{},
    };
    try std.testing.expectError(error.PatchHunkCountMismatch, buildPatchArgs(std.testing.allocator, .edit, "src/main.zig", &bad_call));
}
