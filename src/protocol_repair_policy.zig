const std = @import("std");

const contracts = @import("contracts.zig");
const tool_call = @import("tool_call.zig");
const tool_envelope = @import("tool_envelope.zig");

pub const InitialRejectedToolAction = enum {
    none,
    normalize_direct_web_search_to_contract,
    request_initial_contract_selection,
};

pub const direct_web_search_normalization_reason = "initial router normalized direct web_search to search_web contract";
pub const plaintext_web_intent_repair_reason = "initial router repaired plaintext web intent";

pub fn classifyInitialRejectedTool(
    active_contract: contracts.ActiveContract,
    rejection_reason: ?tool_envelope.RejectionReason,
    raw_name: []const u8,
) InitialRejectedToolAction {
    if (active_contract.name != .workflow) return .none;
    if ((rejection_reason orelse return .none) != .tool_not_advertised) return .none;
    if (std.mem.eql(u8, raw_name, "web_search")) return .normalize_direct_web_search_to_contract;
    return .request_initial_contract_selection;
}

pub fn declaredWebQuery(call: *const tool_call.ToolCall) ?[]const u8 {
    if (call.terms) |terms| {
        const trimmed = std.mem.trim(u8, terms, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    if (call.intent) |intent| {
        const trimmed = std.mem.trim(u8, intent, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

pub fn searchWebContractCallFromDirect(allocator: std.mem.Allocator, direct_call: *const tool_call.ToolCall) !tool_call.ToolCall {
    var call = tool_call.ToolCall{
        .name = try allocator.dupe(u8, "set_operational_contract"),
        .contract = .search_web,
    };
    errdefer call.deinit(allocator);

    if (direct_call.target) |target| call.target = try allocator.dupe(u8, target);
    if (declaredWebQuery(direct_call)) |query| call.terms = try allocator.dupe(u8, query);
    if (direct_call.intent) |intent| call.intent = try allocator.dupe(u8, intent);
    call.budget_bytes = direct_call.budget_bytes;
    if (direct_call.strategy_id) |strategy_id| call.strategy_id = try allocator.dupe(u8, strategy_id);
    call.reason = try allocator.dupe(u8, direct_web_search_normalization_reason);
    return call;
}

pub fn plaintextWebIntentNeedsRepair(visible: []const u8) bool {
    const text = std.mem.trim(u8, visible, " \t\r\n");
    if (text.len == 0) return false;
    const has_search_verb =
        containsIgnoreCase(text, "pesquis") or
        containsIgnoreCase(text, "search");
    const has_external_scope =
        containsIgnoreCase(text, "web") or
        containsIgnoreCase(text, "internet") or
        containsIgnoreCase(text, "online");
    return has_search_verb and has_external_scope;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "initial workflow web_search rejection becomes contract normalization" {
    const active = contracts.activeContract(.workflow) orelse return error.MissingContract;
    try std.testing.expectEqual(
        InitialRejectedToolAction.normalize_direct_web_search_to_contract,
        classifyInitialRejectedTool(active, .tool_not_advertised, "web_search"),
    );
    try std.testing.expectEqual(
        InitialRejectedToolAction.request_initial_contract_selection,
        classifyInitialRejectedTool(active, .tool_not_advertised, "collect_evidence"),
    );
    try std.testing.expectEqual(
        InitialRejectedToolAction.none,
        classifyInitialRejectedTool(active, .parse_error, "web_search"),
    );
}

test "non-workflow rejected tools are not initial router repairs" {
    const active = contracts.activeContract(.search_web) orelse return error.MissingContract;
    try std.testing.expectEqual(
        InitialRejectedToolAction.none,
        classifyInitialRejectedTool(active, .tool_not_advertised, "collect_evidence"),
    );
}

test "direct web_search contract call preserves declared search data" {
    var direct = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "web_search"),
        .target = try std.testing.allocator.dupe(u8, "https://example.com/search?q=zig"),
        .terms = try std.testing.allocator.dupe(u8, "  Zig release notes  "),
        .intent = try std.testing.allocator.dupe(u8, "verify current Zig version"),
        .budget_bytes = 2048,
        .strategy_id = try std.testing.allocator.dupe(u8, "document_summary"),
    };
    defer direct.deinit(std.testing.allocator);

    const contract_call = try searchWebContractCallFromDirect(std.testing.allocator, &direct);
    defer contract_call.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("set_operational_contract", contract_call.name);
    try std.testing.expectEqual(contracts.ContractName.search_web, contract_call.contract.?);
    try std.testing.expectEqualStrings("https://example.com/search?q=zig", contract_call.target.?);
    try std.testing.expectEqualStrings("Zig release notes", contract_call.terms.?);
    try std.testing.expectEqualStrings("verify current Zig version", contract_call.intent.?);
    try std.testing.expectEqual(@as(usize, 2048), contract_call.budget_bytes.?);
    try std.testing.expectEqualStrings("document_summary", contract_call.strategy_id.?);
    try std.testing.expectEqualStrings(direct_web_search_normalization_reason, contract_call.reason.?);
}

test "plaintext web intent is a repair signal, not synthesized contract args" {
    try std.testing.expect(plaintextWebIntentNeedsRepair("Preciso pesquisar na web para identificar quem e Aurora Vela."));
    try std.testing.expect(plaintextWebIntentNeedsRepair("I need to search the web to identify Aurora Vela."));
    try std.testing.expect(!plaintextWebIntentNeedsRepair("Veja https://example.com antes de responder."));
    try std.testing.expect(!plaintextWebIntentNeedsRepair("Aurora Vela e uma pesquisadora ficticia."));
}
