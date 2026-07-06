const std = @import("std");

pub const ToolVisibility = enum {
    model_visible,
    internal_context,
};

pub const ToolSpec = struct {
    name: []const u8,
    visibility: ToolVisibility,
};

pub const manifest_version = "contracts.v1";

pub const ContractName = enum {
    collect_evidence,
    mutate_file,
    validate_work,
    inspect_runtime,
    session_context,
    memory,
    news,
    workflow,
};

pub const StrategyName = enum {
    auto,
    path,
    lexical,
    symbol,
    diagnostic,
    runtime,
    diff,
    semantic,
    news_table,
    document_summary,
};

pub const StrategySpec = struct {
    contract: ContractName,
    strategy: StrategyName,
    max_budget_bytes: usize,
};

pub const ContractSpec = struct {
    name: ContractName,
    endpoint: []const u8,
    allowed_tools: []const []const u8,
};

pub const ActiveContract = struct {
    name: ContractName,
    version: []const u8,
    allowed_tools: []const []const u8,

    pub fn allows(self: ActiveContract, tool_name: []const u8) bool {
        for (self.allowed_tools) |allowed| {
            if (std.mem.eql(u8, tool_name, allowed)) return true;
        }
        return false;
    }
};

pub const all_tools = [_]ToolSpec{
    .{ .name = "collect_evidence", .visibility = .model_visible },
    .{ .name = "read_file", .visibility = .internal_context },
    .{ .name = "path_exists", .visibility = .internal_context },
    .{ .name = "list_dir", .visibility = .internal_context },
    .{ .name = "write_file", .visibility = .internal_context },
    .{ .name = "create_file", .visibility = .internal_context },
    .{ .name = "apply_patch", .visibility = .internal_context },
    .{ .name = "delete_file", .visibility = .internal_context },
    .{ .name = "delete_dir", .visibility = .internal_context },
    .{ .name = "run_validation", .visibility = .internal_context },
    .{ .name = "validate_syntax", .visibility = .internal_context },
    .{ .name = "run_tests", .visibility = .internal_context },
    .{ .name = "run_code", .visibility = .internal_context },
    .{ .name = "browser_check", .visibility = .internal_context },
    .{ .name = "git_status", .visibility = .internal_context },
    .{ .name = "git_diff", .visibility = .internal_context },
    .{ .name = "git_log", .visibility = .internal_context },
    .{ .name = "date", .visibility = .internal_context },
    .{ .name = "get_session_context", .visibility = .internal_context },
    .{ .name = "list_session_files", .visibility = .internal_context },
    .{ .name = "set_operational_contract", .visibility = .internal_context },
    .{ .name = "build_task_context", .visibility = .internal_context },
    .{ .name = "get_context", .visibility = .internal_context },
    .{ .name = "get_minimal_context", .visibility = .internal_context },
    .{ .name = "project_map", .visibility = .internal_context },
    .{ .name = "parse_ast", .visibility = .internal_context },
    .{ .name = "grep_file", .visibility = .internal_context },
    .{ .name = "search_code", .visibility = .internal_context },
    .{ .name = "find_function", .visibility = .internal_context },
    .{ .name = "extract_block", .visibility = .internal_context },
    .{ .name = "who_calls", .visibility = .internal_context },
    .{ .name = "rag_status", .visibility = .internal_context },
    .{ .name = "rag_index", .visibility = .internal_context },
    .{ .name = "rag_search", .visibility = .internal_context },
    .{ .name = "web_search", .visibility = .internal_context },
    .{ .name = "get_civic_briefing", .visibility = .internal_context },
    .{ .name = "get_news_preferences", .visibility = .internal_context },
    .{ .name = "set_news_preferences", .visibility = .internal_context },
    .{ .name = "generate_pdf", .visibility = .internal_context },
    .{ .name = "update_memory", .visibility = .internal_context },
    .{ .name = "record_skill", .visibility = .internal_context },
    .{ .name = "record_skills", .visibility = .internal_context },
    .{ .name = "read_memory", .visibility = .internal_context },
    .{ .name = "read_skills", .visibility = .internal_context },
    .{ .name = "submit_plan", .visibility = .internal_context },
    .{ .name = "set_plan", .visibility = .internal_context },
    .{ .name = "list_pending_tasks", .visibility = .internal_context },
    .{ .name = "complete_step", .visibility = .internal_context },
    .{ .name = "lsp_status", .visibility = .internal_context },
    .{ .name = "install_lsp_server", .visibility = .internal_context },
    .{ .name = "start_background_command", .visibility = .internal_context },
    .{ .name = "background_status", .visibility = .internal_context },
    .{ .name = "background_stop", .visibility = .internal_context },
    .{ .name = "git_add", .visibility = .internal_context },
    .{ .name = "git_commit", .visibility = .internal_context },
};

pub const contract_specs = [_]ContractSpec{
    .{
        .name = .collect_evidence,
        .endpoint = "collect_evidence",
        .allowed_tools = &.{"collect_evidence"},
    },
};

pub const strategy_specs = [_]StrategySpec{
    .{ .contract = .collect_evidence, .strategy = .auto, .max_budget_bytes = 3800 },
    .{ .contract = .collect_evidence, .strategy = .path, .max_budget_bytes = 3800 },
    .{ .contract = .collect_evidence, .strategy = .lexical, .max_budget_bytes = 6000 },
    .{ .contract = .news, .strategy = .news_table, .max_budget_bytes = 24000 },
    .{ .contract = .inspect_runtime, .strategy = .document_summary, .max_budget_bytes = 24000 },
};

pub fn isModelVisible(name: []const u8) bool {
    for (all_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool.visibility == .model_visible;
    }
    return false;
}

pub fn isInternalContextTool(name: []const u8) bool {
    for (all_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool.visibility == .internal_context;
    }
    return false;
}

pub fn strategyAllowed(contract: ContractName, strategy: StrategyName) bool {
    for (strategy_specs) |spec| {
        if (spec.contract == contract and spec.strategy == strategy) return true;
    }
    return false;
}

pub fn resolveCollectEvidenceStrategy(requested: ?StrategyName) ?StrategyName {
    const strategy = requested orelse .auto;
    if (strategyAllowed(.collect_evidence, strategy)) return strategy;
    return null;
}

pub fn activeContract(name: ContractName) ?ActiveContract {
    for (contract_specs) |spec| {
        if (spec.name != name) continue;
        return .{
            .name = spec.name,
            .version = manifest_version,
            .allowed_tools = spec.allowed_tools,
        };
    }
    return null;
}

pub fn compactModelVisibleTools(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var first = true;
    for (all_tools) |tool| {
        if (tool.visibility != .model_visible) continue;
        if (!first) try out.appendSlice(allocator, ",");
        first = false;
        try out.appendSlice(allocator, tool.name);
    }
    return out.toOwnedSlice(allocator);
}

test "tool manifest keeps internal context tools hidden from model surface" {
    try std.testing.expect(isModelVisible("collect_evidence"));
    try std.testing.expect(!isModelVisible("apply_patch"));
    try std.testing.expect(isInternalContextTool("apply_patch"));
    try std.testing.expect(!isModelVisible("grep_file"));
    try std.testing.expect(isInternalContextTool("grep_file"));
    try std.testing.expect(isInternalContextTool("rag_search"));
    try std.testing.expect(isInternalContextTool("build_task_context"));
}

test "tool manifest includes referenced ts project tools" {
    try std.testing.expect(isInternalContextTool("read_file"));
    try std.testing.expect(isInternalContextTool("git_diff"));
    try std.testing.expect(isInternalContextTool("get_civic_briefing"));
    try std.testing.expect(isInternalContextTool("record_skills"));
    try std.testing.expect(isInternalContextTool("start_background_command"));
}

test "collect evidence accepts bounded strategies without expanding tool surface" {
    try std.testing.expect(strategyAllowed(.collect_evidence, .path));
    try std.testing.expect(strategyAllowed(.collect_evidence, .lexical));
    try std.testing.expect(!strategyAllowed(.collect_evidence, .semantic));
    try std.testing.expect(!strategyAllowed(.collect_evidence, .symbol));
    try std.testing.expect(!strategyAllowed(.collect_evidence, .news_table));
    try std.testing.expect(resolveCollectEvidenceStrategy(.news_table) == null);
}

test "active collect evidence contract comes from manifest allowlist" {
    const active = activeContract(.collect_evidence) orelse return error.MissingContract;
    try std.testing.expectEqualStrings(manifest_version, active.version);
    try std.testing.expect(active.allows("collect_evidence"));
    try std.testing.expect(!active.allows("content"));
    try std.testing.expect(!active.allows("grep_file"));
}

test "compact model visible tools excludes internal collectors" {
    const rendered = try compactModelVisibleTools(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "set_operational_contract") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "apply_patch") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "run_tests") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "grep_file") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "rag_search") == null);
}
