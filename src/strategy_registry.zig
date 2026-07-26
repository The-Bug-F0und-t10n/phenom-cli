const std = @import("std");

const contracts = @import("contracts.zig");
const evidence_collectors = @import("evidence_collectors.zig");
const web_rag = @import("web_rag.zig");

pub const ParameterKind = enum {
    text,
    path,
    url,
    source,
    strategy,
    boolean,
    bytes,
    line,
    line_count,
    candidate_id,
};

pub const ParameterSpec = struct {
    name: []const u8,
    kind: ParameterKind,
    required: bool = false,
};

pub const StrategyDescriptor = struct {
    id: []const u8,
    contract: contracts.ContractName,
    description: []const u8,
    source: contracts.SourceName,
    strategy: contracts.StrategyName,
    collector: evidence_collectors.CollectorKind,
    params: []const ParameterSpec,
    max_budget_bytes: usize,
    uses_contracts: []const contracts.ContractName = &.{},

    pub fn allowsParam(self: StrategyDescriptor, name: []const u8) bool {
        for (self.params) |param| {
            if (std.mem.eql(u8, param.name, name)) return true;
        }
        return false;
    }
};

pub const ResolveInput = struct {
    strategy_id: ?[]const u8 = null,
    source: contracts.SourceName = .auto,
    strategy: contracts.StrategyName = .auto,
    path: ?[]const u8 = null,
    target: ?[]const u8 = null,
    http_search: bool = false,
};

const params_micro_context = [_]ParameterSpec{
    .{ .name = "intent", .kind = .text, .required = true },
    .{ .name = "terms", .kind = .text, .required = true },
    .{ .name = "budget_bytes", .kind = .bytes },
    .{ .name = "compact", .kind = .boolean },
};

const params_path = [_]ParameterSpec{
    .{ .name = "path", .kind = .path, .required = true },
    .{ .name = "start_line", .kind = .line },
    .{ .name = "max_lines", .kind = .line_count },
    .{ .name = "budget_bytes", .kind = .bytes },
};

const params_candidates = [_]ParameterSpec{
    .{ .name = "intent", .kind = .text, .required = true },
    .{ .name = "terms", .kind = .text, .required = true },
    .{ .name = "stage", .kind = .text },
    .{ .name = "budget_bytes", .kind = .bytes },
};

const params_expand = [_]ParameterSpec{
    .{ .name = "selectedCandidate", .kind = .candidate_id, .required = true },
    .{ .name = "max_lines", .kind = .line_count },
};

const params_diagnostic = [_]ParameterSpec{
    .{ .name = "path", .kind = .path, .required = true },
    .{ .name = "budget_bytes", .kind = .bytes },
};

const params_git = [_]ParameterSpec{
    .{ .name = "source", .kind = .source },
    .{ .name = "strategy", .kind = .strategy },
    .{ .name = "intent", .kind = .text },
    .{ .name = "terms", .kind = .text },
    .{ .name = "path", .kind = .path },
    .{ .name = "budget_bytes", .kind = .bytes },
};

const params_web = [_]ParameterSpec{
    .{ .name = "target", .kind = .url, .required = true },
    .{ .name = "query", .kind = .text, .required = true },
    .{ .name = "httpSearch", .kind = .boolean, .required = true },
    .{ .name = "budget_bytes", .kind = .bytes },
};

pub const strategies = [_]StrategyDescriptor{
    .{
        .id = "collect_micro_context_for_simple_analysis",
        .contract = .collect_evidence,
        .description = "Collect a small ranked workspace context for a focused analytical question.",
        .source = .code,
        .strategy = .lexical,
        .collector = .ranked,
        .params = &params_micro_context,
        .max_budget_bytes = 6000,
    },
    .{
        .id = "collect_file_range",
        .contract = .collect_evidence,
        .description = "Collect a bounded file range with micro-context id for stale-safe edits.",
        .source = .file,
        .strategy = .path,
        .collector = .path,
        .params = &params_path,
        .max_budget_bytes = 3800,
    },
    .{
        .id = "collect_symbol_candidates",
        .contract = .collect_evidence,
        .description = "Collect candidate symbols before expanding one selected candidate.",
        .source = .code,
        .strategy = .symbol,
        .collector = .ranked,
        .params = &params_candidates,
        .max_budget_bytes = 6000,
    },
    .{
        .id = "collect_selected_candidate_context",
        .contract = .collect_evidence,
        .description = "Expand one model-selected C# candidate into evidence.",
        .source = .code,
        .strategy = .path,
        .collector = .path,
        .params = &params_expand,
        .max_budget_bytes = 6000,
    },
    .{
        .id = "collect_diagnostic_report",
        .contract = .collect_evidence,
        .description = "Collect syntax or runtime-adjacent diagnostics as bounded evidence.",
        .source = .diagnostic,
        .strategy = .diagnostic,
        .collector = .diagnostic,
        .params = &params_diagnostic,
        .max_budget_bytes = 6000,
    },
    .{
        .id = "collect_git_diff",
        .contract = .collect_evidence,
        .description = "Collect current Git status, diff stat, and diff without exposing git tools.",
        .source = .git,
        .strategy = .diff,
        .collector = .git,
        .params = &params_git,
        .max_budget_bytes = 12000,
    },
    .{
        .id = "collect_git_history",
        .contract = .collect_evidence,
        .description = "Collect repository history evidence.",
        .source = .git,
        .strategy = .history,
        .collector = .git,
        .params = &params_git,
        .max_budget_bytes = 12000,
    },
    .{
        .id = "collect_git_show",
        .contract = .collect_evidence,
        .description = "Collect one revision patch/stat using a bounded safe revision.",
        .source = .git,
        .strategy = .show,
        .collector = .git,
        .params = &params_git,
        .max_budget_bytes = 12000,
    },
    .{
        .id = "collect_git_reflog",
        .contract = .collect_evidence,
        .description = "Collect reflog evidence for deleted or moved commits.",
        .source = .git,
        .strategy = .reflog,
        .collector = .git,
        .params = &params_git,
        .max_budget_bytes = 12000,
    },
    .{
        .id = "collect_git_unreachable",
        .contract = .collect_evidence,
        .description = "Collect unreachable Git object evidence.",
        .source = .git,
        .strategy = .@"unreachable",
        .collector = .git,
        .params = &params_git,
        .max_budget_bytes = 12000,
    },
    .{
        .id = "search_web_distilled",
        .contract = .search_web,
        .description = "Fetch and distill web evidence from a model-selected query and target URL.",
        .source = .web,
        .strategy = .document_summary,
        .collector = .web,
        .params = &params_web,
        .max_budget_bytes = 12000,
        .uses_contracts = &.{.search_web},
    },
    .{
        .id = "collect_web_evidence_distilled",
        .contract = .collect_evidence,
        .description = "Collect evidence by delegating HTTP retrieval to the search_web contract.",
        .source = .web,
        .strategy = .document_summary,
        .collector = .web,
        .params = &params_web,
        .max_budget_bytes = 12000,
        .uses_contracts = &.{.search_web},
    },
};

pub fn byId(id: []const u8) ?StrategyDescriptor {
    if (std.mem.eql(u8, id, "collect_micro_context_for_simple_analistic")) return byId("collect_micro_context_for_simple_analysis");
    for (strategies) |strategy| {
        if (std.mem.eql(u8, strategy.id, id)) return strategy;
    }
    return null;
}

pub fn resolveCollectEvidence(input: ResolveInput) !StrategyDescriptor {
    if (input.strategy_id) |id| {
        const descriptor = byId(id) orelse return error.InvalidStrategyId;
        if (descriptor.contract != .collect_evidence) return error.StrategyContractMismatch;
        return descriptor;
    }
    const collector = try evidence_collectors.resolve(.{
        .source = input.source,
        .strategy = input.strategy,
        .path = input.path,
        .target = input.target,
    });
    if (collector == .web and input.http_search) return byId("collect_web_evidence_distilled").?;
    return switch (collector) {
        .web => byId("collect_web_evidence_distilled").?,
        .diagnostic => byId("collect_diagnostic_report").?,
        .git => switch (input.strategy) {
            .diff => byId("collect_git_diff").?,
            .show => byId("collect_git_show").?,
            .reflog => byId("collect_git_reflog").?,
            .@"unreachable" => byId("collect_git_unreachable").?,
            else => byId("collect_git_history").?,
        },
        .path => byId("collect_file_range").?,
        .ranked => switch (input.strategy) {
            .symbol => byId("collect_symbol_candidates").?,
            else => byId("collect_micro_context_for_simple_analysis").?,
        },
    };
}

pub fn resolveSearchWeb(input: ResolveInput) !StrategyDescriptor {
    const descriptor = if (input.strategy_id) |id| byId(id) orelse return error.InvalidStrategyId else byId("search_web_distilled").?;
    if (descriptor.contract != .search_web) return error.StrategyContractMismatch;
    if (!web_rag.isHttpTarget(input.target orelse "")) return error.InvalidWebTarget;
    return descriptor;
}

test "strategy registry exposes descriptive collect evidence strategies" {
    const descriptor = byId("collect_micro_context_for_simple_analysis") orelse return error.MissingStrategy;
    try std.testing.expectEqual(contracts.ContractName.collect_evidence, descriptor.contract);
    try std.testing.expectEqual(contracts.SourceName.code, descriptor.source);
    try std.testing.expect(descriptor.allowsParam("terms"));
    try std.testing.expect(!descriptor.allowsParam("selectedCandidate"));
    const alias = byId("collect_micro_context_for_simple_analistic") orelse return error.MissingStrategy;
    try std.testing.expectEqualStrings(descriptor.id, alias.id);
}

test "git reflog strategy is a descriptor not a model visible git tool" {
    const descriptor = try resolveCollectEvidence(.{ .strategy_id = "collect_git_reflog" });
    try std.testing.expectEqual(contracts.ContractName.collect_evidence, descriptor.contract);
    try std.testing.expectEqual(contracts.SourceName.git, descriptor.source);
    try std.testing.expectEqual(contracts.StrategyName.reflog, descriptor.strategy);
    try std.testing.expectEqual(evidence_collectors.CollectorKind.git, descriptor.collector);
    try std.testing.expect(!contracts.isModelVisible("git_reflog"));
}

test "collect evidence can delegate web retrieval through search web contract" {
    const descriptor = try resolveCollectEvidence(.{
        .strategy_id = "collect_web_evidence_distilled",
        .target = "http://127.0.0.1/doc",
        .http_search = true,
    });
    try std.testing.expectEqual(contracts.ContractName.collect_evidence, descriptor.contract);
    try std.testing.expectEqual(contracts.ContractName.search_web, descriptor.uses_contracts[0]);
    try std.testing.expectEqual(evidence_collectors.CollectorKind.web, descriptor.collector);

    const search = try resolveSearchWeb(.{ .target = "http://127.0.0.1/doc" });
    try std.testing.expectEqual(contracts.ContractName.search_web, search.contract);
}
