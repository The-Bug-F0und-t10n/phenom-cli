const std = @import("std");

const contracts = @import("contracts.zig");
const diagnostic_runner = @import("diagnostic_runner.zig");
const evidence = @import("evidence.zig");
const evidence_ranker = @import("evidence_ranker.zig");
const micro_context = @import("micro_context.zig");
const tool_event = @import("tool_event.zig");
const tools = @import("tools.zig");

pub const Args = struct {
    path: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    terms: ?[]const u8 = null,
    task: []const u8 = "",
    strategy: contracts.StrategyName = .auto,
    start_line: usize = 1,
    max_lines: usize = 12,
    budget_bytes: usize = 3800,
};

pub const Result = struct {
    strategy: contracts.StrategyName,
    context_id: []const u8,
    evidence_text: []u8,
    micro_context_text: []u8,
    tool_event_audit_text: []u8,
    raw_bytes_read: usize,
    model_bytes: usize,
    quality_score: i32,
    range_count: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.context_id);
        allocator.free(self.evidence_text);
        allocator.free(self.micro_context_text);
        allocator.free(self.tool_event_audit_text);
    }
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    if (args.budget_bytes == 0) return error.InvalidEvidenceBudget;
    const strategy = contracts.resolveCollectEvidenceStrategy(args.strategy) orelse return error.InvalidStrategy;
    if (strategy == .diagnostic) return executeDiagnostic(allocator, args);
    if (args.path) |path| {
        if (isWorkspaceRootPath(path)) {
            var ranked_args = args;
            ranked_args.path = null;
            ranked_args.strategy = if (strategy == .path) .auto else strategy;
            return executeRanked(allocator, io, ranked_args, ranked_args.strategy);
        }
    }
    if (strategy == .path or args.path != null) return executePath(allocator, args, strategy);
    return executeRanked(allocator, io, args, strategy);
}

fn isWorkspaceRootPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "./");
}

fn executeDiagnostic(allocator: std.mem.Allocator, args: Args) !Result {
    const path = args.path orelse return error.MissingPath;
    const diagnostic = try diagnostic_runner.run(allocator, path, args.budget_bytes);
    defer diagnostic.deinit(allocator);

    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    const entry = try cloneEvidenceEntry(allocator, diagnostic.entry);
    try packet.add(entry);

    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);
    const micro_context_text = try allocator.dupe(u8, "");
    errdefer allocator.free(micro_context_text);
    const tool_event_audit_text = try allocator.dupe(u8, diagnostic.audit_text);
    errdefer allocator.free(tool_event_audit_text);
    const context_id = try std.fmt.allocPrint(allocator, "diag_{x}", .{diagnostic.entry.hash});
    errdefer allocator.free(context_id);

    return .{
        .strategy = .diagnostic,
        .context_id = context_id,
        .evidence_text = evidence_text,
        .micro_context_text = micro_context_text,
        .tool_event_audit_text = tool_event_audit_text,
        .raw_bytes_read = diagnostic.raw_bytes,
        .model_bytes = evidence_text.len,
        .quality_score = if (diagnostic.blocking_count == 0) 92 else 95,
        .range_count = 1,
    };
}

fn cloneEvidenceEntry(allocator: std.mem.Allocator, entry: evidence.EvidenceEntry) !evidence.EvidenceEntry {
    const source = try allocator.dupe(u8, entry.source);
    errdefer allocator.free(source);
    const kind = try allocator.dupe(u8, entry.kind);
    errdefer allocator.free(kind);
    const range = try allocator.dupe(u8, entry.range);
    errdefer allocator.free(range);
    const excerpt = try allocator.dupe(u8, entry.excerpt);
    errdefer allocator.free(excerpt);
    return .{
        .source = source,
        .kind = kind,
        .range = range,
        .hash = entry.hash,
        .excerpt = excerpt,
    };
}

fn executePath(allocator: std.mem.Allocator, args: Args, strategy: contracts.StrategyName) !Result {
    const path = args.path orelse return error.MissingPath;
    const range = try tools.readFileRange(allocator, path, args.start_line, args.max_lines, args.budget_bytes);
    defer range.deinit(allocator);

    const args_summary = try std.fmt.allocPrint(
        allocator,
        "strategy={s} path={s} start_line={} max_lines={} budget_bytes={}",
        .{ @tagName(if (strategy == .auto) .path else strategy), path, args.start_line, args.max_lines, args.budget_bytes },
    );
    defer allocator.free(args_summary);

    const event = try tool_event.ToolEvent.fromFileRange(allocator, "collect_evidence", args_summary, range);
    defer event.deinit(allocator);

    const entry = try event.toEvidenceEntryBudgeted(allocator, args.budget_bytes);
    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    try packet.add(entry);

    const ctx = try micro_context.fromFileRange(allocator, range, "collect_evidence", args.budget_bytes);
    defer ctx.deinit(allocator);

    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);
    const micro_context_text = try ctx.render(allocator);
    errdefer allocator.free(micro_context_text);
    const tool_event_audit_text = try event.renderAuditSummary(allocator);
    errdefer allocator.free(tool_event_audit_text);
    const context_id = try allocator.dupe(u8, ctx.id);
    errdefer allocator.free(context_id);

    return .{
        .strategy = if (strategy == .auto) .path else strategy,
        .context_id = context_id,
        .evidence_text = evidence_text,
        .micro_context_text = micro_context_text,
        .tool_event_audit_text = tool_event_audit_text,
        .raw_bytes_read = range.text.len,
        .model_bytes = evidence_text.len + micro_context_text.len,
        .quality_score = 72,
        .range_count = 1,
    };
}

fn executeRanked(allocator: std.mem.Allocator, io: std.Io, args: Args, strategy: contracts.StrategyName) !Result {
    const search_terms = args.terms orelse "";
    const audit_task = if (search_terms.len > 0) search_terms else "workspace_overview";
    var ranked = try evidence_ranker.rankForPrompt(allocator, io, search_terms, strategy, .{
        .max_ranges = adaptiveRangeLimit(args.budget_bytes),
        .max_lines_per_range = adaptiveLineLimit(args.budget_bytes),
    });
    defer ranked.deinit(allocator);
    if (ranked.candidates.items.len == 0) return error.NoEvidenceCandidates;

    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    var micro_contexts = std.ArrayList(micro_context.MicroContext).empty;
    defer {
        for (micro_contexts.items) |ctx| ctx.deinit(allocator);
        micro_contexts.deinit(allocator);
    }

    var raw_bytes_read: usize = 0;
    var best_quality: i32 = 0;
    const fair_range_budget = @max(@as(usize, 512), args.budget_bytes / ranked.candidates.items.len);
    const per_range_budget = @min(evidence_ranker.adaptiveBudget(args.budget_bytes, ranked.candidates.items[0].score, ranked.candidates.items.len), fair_range_budget);
    var evidence_budget_remaining = args.budget_bytes;

    for (ranked.candidates.items) |candidate| {
        if (evidence_budget_remaining == 0) break;
        best_quality = @max(best_quality, candidate.score);
        const max_lines = candidate.end_line - candidate.start_line + 1;
        const range_budget = @min(per_range_budget, evidence_budget_remaining);
        const range = tools.readFileRange(allocator, candidate.path, candidate.start_line, max_lines, range_budget) catch continue;
        defer range.deinit(allocator);
        if (containsForbiddenModelMarker(range.text)) continue;
        raw_bytes_read += range.text.len;
        try packet.add(try evidence.fromFileRangeBudgeted(allocator, range, range_budget));
        try micro_contexts.append(allocator, try micro_context.fromFileRange(allocator, range, "collect_evidence", range_budget));
        evidence_budget_remaining -|= range_budget;
    }
    if (packet.entries.items.len == 0) return error.NoEvidenceCandidatesReadable;

    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);
    const micro_context_text = try renderMicroContexts(allocator, micro_contexts.items);
    errdefer allocator.free(micro_context_text);
    const first_context_id = try allocator.dupe(u8, micro_contexts.items[0].id);
    errdefer allocator.free(first_context_id);
    const tool_event_audit_text = try renderRankedAudit(allocator, strategy, args.intent, audit_task, args.budget_bytes, ranked.audit_text, packet.entries.items.len, raw_bytes_read, best_quality);
    errdefer allocator.free(tool_event_audit_text);

    return .{
        .strategy = strategy,
        .context_id = first_context_id,
        .evidence_text = evidence_text,
        .micro_context_text = micro_context_text,
        .tool_event_audit_text = tool_event_audit_text,
        .raw_bytes_read = raw_bytes_read,
        .model_bytes = evidence_text.len + micro_context_text.len,
        .quality_score = best_quality,
        .range_count = packet.entries.items.len,
    };
}

fn containsForbiddenModelMarker(text: []const u8) bool {
    const forbidden = [_][]const u8{
        "---BEGIN CONTENT---",
        "[READ_FILE]",
        "rawOutput",
        "raw_output",
        "SECRET_RAW_TAIL",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn renderMicroContexts(allocator: std.mem.Allocator, contexts: []const micro_context.MicroContext) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (contexts) |ctx| {
        const rendered = try ctx.render(allocator);
        defer allocator.free(rendered);
        try out.appendSlice(allocator, rendered);
    }
    return out.toOwnedSlice(allocator);
}

fn renderRankedAudit(
    allocator: std.mem.Allocator,
    strategy: contracts.StrategyName,
    intent: ?[]const u8,
    task: []const u8,
    budget_bytes: usize,
    ranking_audit: []const u8,
    range_count: usize,
    raw_bytes_read: usize,
    quality_score: i32,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "[TOOL_EVENT]\ntool=collect_evidence\nsuccess=true\nargs=strategy={s} intent_bytes={} task_bytes={} budget_bytes={} ranges={} raw_bytes={} quality_score={}\n{s}",
        .{ @tagName(strategy), if (intent) |value| value.len else 0, task.len, budget_bytes, range_count, raw_bytes_read, quality_score, ranking_audit },
    );
}

fn adaptiveRangeLimit(budget_bytes: usize) usize {
    if (budget_bytes >= 12000) return 5;
    if (budget_bytes >= 7000) return 4;
    return 3;
}

fn adaptiveLineLimit(budget_bytes: usize) usize {
    if (budget_bytes >= 12000) return 140;
    if (budget_bytes >= 7000) return 100;
    return 72;
}

test "collect evidence path returns budgeted evidence and micro context" {
    const result = try execute(std.testing.allocator, std.testing.io, .{
        .path = "README.md",
        .strategy = .path,
        .start_line = 1,
        .max_lines = 6,
        .budget_bytes = 96,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(contracts.StrategyName.path, result.strategy);
    try std.testing.expect(std.mem.startsWith(u8, result.context_id, "ctx_"));
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text, "[MICRO_CONTEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "[TOOL_EVENT]") != null);
    try std.testing.expect(result.model_bytes == result.evidence_text.len + result.micro_context_text.len);
    try std.testing.expectEqual(@as(usize, 1), result.range_count);
}

test "collect evidence ranked lexical uses rg candidates and audit without raw rg output" {
    const result = try execute(std.testing.allocator, std.testing.io, .{
        .task = "user prompt should not be the search query",
        .terms = "collect_evidence execute",
        .strategy = .lexical,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.range_count > 0);
    try std.testing.expect(result.quality_score > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "[CANDIDATE_RANKING]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "---BEGIN CONTENT---") == null);
}

test "collect evidence rejects inactive strategies instead of falling back" {
    const strategies = [_]contracts.StrategyName{ .semantic, .runtime, .diff };
    for (strategies) |strategy| {
        try std.testing.expectError(error.InvalidStrategy, execute(std.testing.allocator, std.testing.io, .{
            .task = "collect_evidence tool_event diff error",
            .strategy = strategy,
            .budget_bytes = 6000,
        }));
    }
}

test "collect evidence diagnostic strategy returns syntax evidence" {
    const path = "collect_diagnostic_bad.zig";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "pub fn broken( {\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .strategy = .diagnostic,
        .budget_bytes = 4096,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(contracts.StrategyName.diagnostic, result.strategy);
    try std.testing.expect(result.quality_score >= 90);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[DIAGNOSTIC]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "severity=blocking") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "strategy=diagnostic") != null);
}

test "collect evidence symbol strategy uses structural symbols" {
    const result = try execute(std.testing.allocator, std.testing.io, .{
        .terms = "AppendOnlyRenderer",
        .strategy = .symbol,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(contracts.StrategyName.symbol, result.strategy);
    try std.testing.expect(result.range_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "source=symbol_ast") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "src/render.zig") != null);
}

test "collect evidence ranked output skips forbidden raw marker ranges" {
    const result = try execute(std.testing.allocator, std.testing.io, .{
        .task = "user prompt should not drive search",
        .terms = "RawContextLeak collect_evidence",
        .strategy = .auto,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "---BEGIN CONTENT---") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text, "---BEGIN CONTENT---") == null);
}

test "collect evidence auto without model terms uses structural overview" {
    const result = try execute(std.testing.allocator, std.testing.io, .{
        .task = "o que este projeto implementa em cwd",
        .strategy = .auto,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.range_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "terms=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "workspace_overview") != null);
}

test "collect evidence workspace root path uses ranked overview not empty file" {
    const result = try execute(std.testing.allocator, std.testing.io, .{
        .path = ".",
        .strategy = .path,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(contracts.StrategyName.auto, result.strategy);
    try std.testing.expect(result.range_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "- . L1-L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "workspace_overview") != null);
}

test "collect evidence does not leak raw tail beyond budget" {
    const path = "collect_evidence_budget_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "alpha\nbeta\nSECRET_RAW_TAIL_SHOULD_NOT_LEAK\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 10,
        .budget_bytes = "alpha\nbeta\n".len,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "SECRET_RAW_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text, "SECRET_RAW_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "SECRET_RAW_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_event_audit_text, "raw_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[TRUNCATED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text, "[TRUNCATED]") != null);
}

test "collect evidence rejects zero budget" {
    try std.testing.expectError(error.InvalidEvidenceBudget, execute(std.testing.allocator, std.testing.io, .{
        .path = "README.md",
        .budget_bytes = 0,
    }));
}
