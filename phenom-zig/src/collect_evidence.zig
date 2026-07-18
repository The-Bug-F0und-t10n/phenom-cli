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
    need: ?[]const u8 = null,
    terms: ?[]const u8 = null,
    target_files: ?[]const u8 = null,
    scope_root: ?[]const u8 = null,
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

pub const CandidateItem = struct {
    id: []u8,
    path: []u8,
    start_line: usize,
    end_line: usize,
    score: i32,
    source: []u8,
    signature: []u8,
    preview: []u8,

    pub fn deinit(self: CandidateItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.source);
        allocator.free(self.signature);
        allocator.free(self.preview);
    }
};

pub const CandidateResult = struct {
    text: []u8,
    audit_text: []u8,
    model_bytes: usize,
    candidates: std.ArrayList(CandidateItem),

    pub fn deinit(self: *CandidateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.audit_text);
        for (self.candidates.items) |candidate| candidate.deinit(allocator);
        self.candidates.deinit(allocator);
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

pub fn executeCandidates(allocator: std.mem.Allocator, io: std.Io, args: Args) !CandidateResult {
    if (args.budget_bytes == 0) return error.InvalidEvidenceBudget;
    const strategy = contracts.resolveCollectEvidenceStrategy(args.strategy) orelse return error.InvalidStrategy;
    var search_terms = try renderSearchTerms(allocator, args);
    defer allocator.free(search_terms);
    if (search_terms.len == 0) {
        allocator.free(search_terms);
        search_terms = try allocator.dupe(u8, std.mem.trim(u8, args.task, " \t\r\n"));
    }
    if (search_terms.len == 0) return error.MissingTerms;
    var ranked = try evidence_ranker.rankForPrompt(allocator, io, search_terms, strategy, .{
        .max_ranges = 6,
        .max_lines_per_range = 48,
    });
    defer ranked.deinit(allocator);
    if (ranked.candidates.items.len == 0) return error.NoEvidenceCandidates;

    var candidates = std.ArrayList(CandidateItem).empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    for (ranked.candidates.items, 0..) |candidate, idx| {
        const signature_start = candidate.start_line;
        const signature_max_lines: usize = if (candidate.source == .symbol_ast or candidate.source == .module_entrypoint) 1 else candidate.end_line - candidate.start_line + 1;
        const signature_range = tools.readFileRange(allocator, candidate.path, signature_start, signature_max_lines, 32 * 1024) catch continue;
        defer signature_range.deinit(allocator);
        const signature = if (candidate.source == .symbol_ast or candidate.source == .module_entrypoint)
            firstLineAt(signature_range.text, signature_start)
        else
            selectCandidateLine(signature_range.text, signature_start, candidate.start_line, search_terms, candidate.path);
        const preview = candidate.reasons[0..@min(candidate.reasons.len, 160)];
        const item_start = candidate.start_line;
        const item_end = candidate.end_line;
        {
            var item = try makeCandidateItem(
                allocator,
                idx + 1,
                candidate.path,
                item_start,
                item_end,
                candidate.score,
                @tagName(candidate.source),
                signature.text,
                preview,
            );
            errdefer item.deinit(allocator);
            try candidates.append(allocator, item);
        }
    }
    if (candidates.items.len == 0) return error.NoEvidenceCandidatesReadable;

    const text = try renderCandidates(allocator, candidates.items);
    errdefer allocator.free(text);
    const audit_text = try std.fmt.allocPrint(
        allocator,
        "[TOOL_EVENT]\ntool=collect_evidence\nsuccess=true\nargs=stage=candidates strategy={s} intent_bytes={} terms_bytes={} candidates={} model_bytes={}\n{s}",
        .{ @tagName(strategy), if (args.intent) |value| value.len else 0, search_terms.len, candidates.items.len, text.len, ranked.audit_text },
    );
    errdefer allocator.free(audit_text);

    return .{
        .text = text,
        .audit_text = audit_text,
        .model_bytes = text.len,
        .candidates = candidates,
    };
}

fn isWorkspaceRootPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "./");
}

fn renderCandidates(allocator: std.mem.Allocator, candidates: []const CandidateItem) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[CANDIDATES]\nsource=definition_first temporary=true raw_context_persisted=false\n");
    for (candidates) |candidate| {
        const line = try std.fmt.allocPrint(
            allocator,
            "- {s} score={} source={s} path={s} range={}-{}\n  def: {s}\n  preview: {s}\n",
            .{
                candidate.id,
                candidate.score,
                candidate.source,
                candidate.path,
                candidate.start_line,
                candidate.end_line,
                candidate.signature,
                candidate.preview,
            },
        );
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

fn makeCandidateItem(
    allocator: std.mem.Allocator,
    ordinal: usize,
    path: []const u8,
    start_line: usize,
    end_line: usize,
    score: i32,
    source: []const u8,
    signature: []const u8,
    preview: []const u8,
) !CandidateItem {
    const id = try std.fmt.allocPrint(allocator, "C{}", .{ordinal});
    errdefer allocator.free(id);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);
    const owned_signature = try allocator.dupe(u8, signature);
    errdefer allocator.free(owned_signature);
    const owned_preview = try allocator.dupe(u8, preview);
    errdefer allocator.free(owned_preview);

    return .{
        .id = id,
        .path = owned_path,
        .start_line = start_line,
        .end_line = end_line,
        .score = score,
        .source = owned_source,
        .signature = owned_signature,
        .preview = owned_preview,
    };
}

const SelectedLine = struct {
    text: []const u8,
    line: usize,
};

fn selectCandidateLine(text: []const u8, start_line: usize, target_line: usize, terms: []const u8, path: []const u8) SelectedLine {
    var best = SelectedLine{ .text = firstNonEmptyLine(text), .line = start_line };
    var best_score: usize = 0;
    var best_distance: usize = std.math.maxInt(usize);
    var saw_best = false;
    var line_no = start_line;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const score = lineTermScore(trimmed, terms) + linePathStemScore(trimmed, path);
        const distance = if (line_no > target_line) line_no - target_line else target_line - line_no;
        if (!saw_best or score > best_score or (score == best_score and distance < best_distance) or (score == best_score and distance == best_distance and score > 0 and trimmed.len < best.text.len)) {
            best = .{ .text = trimmed, .line = line_no };
            best_score = score;
            best_distance = distance;
            saw_best = true;
        }
    }
    return best;
}

fn firstNonEmptyLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return "<empty definition>";
}

fn firstLineAt(text: []const u8, start_line: usize) SelectedLine {
    var it = std.mem.splitScalar(u8, text, '\n');
    if (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) return .{ .text = trimmed, .line = start_line };
    }
    return .{ .text = firstNonEmptyLine(text), .line = start_line };
}

fn lineTermScore(line: []const u8, terms: []const u8) usize {
    var score: usize = 0;
    var it = std.mem.tokenizeAny(u8, terms, " \t\r\n\"'`()[]{}<>:;,./\\|");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, "-_*");
        if (term.len < 2) continue;
        if (containsIgnoreCase(line, term)) score += term.len;
    }
    return score;
}

fn linePathStemScore(line: []const u8, path: []const u8) usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const file = if (slash == 0) path else path[slash + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;
    const stem = file[0..dot];
    if (stem.len < 3) return 0;
    if (!containsIgnoreCase(line, stem)) return 0;
    return stem.len;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
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

pub fn cloneEvidenceEntry(allocator: std.mem.Allocator, entry: evidence.EvidenceEntry) !evidence.EvidenceEntry {
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
    const search_terms = try renderSearchTerms(allocator, args);
    defer allocator.free(search_terms);
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

fn renderSearchTerms(allocator: std.mem.Allocator, args: Args) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendSearchPart(&out, allocator, args.terms);
    try appendSearchPart(&out, allocator, args.need);
    try appendSearchPart(&out, allocator, args.target_files);
    try appendSearchPart(&out, allocator, args.scope_root);
    try appendSearchPart(&out, allocator, args.intent);
    return out.toOwnedSlice(allocator);
}

fn appendSearchPart(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: ?[]const u8) !void {
    const text = std.mem.trim(u8, value orelse return, " \t\r\n");
    if (text.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, text);
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
        "[TOOL_EVENT]\ntool=collect_evidence\nsuccess=true\nargs=strategy={s} intent_bytes={} search_bytes={} budget_bytes={} ranges={} raw_bytes={} quality_score={}\n{s}",
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

test "collect evidence v2 fields contribute to model-selected search terms" {
    const search_terms = try renderSearchTerms(std.testing.allocator, .{
        .intent = "find contract executor",
        .need = "mutation gate",
        .terms = "apply_patch",
        .target_files = "src/main.zig",
        .scope_root = "src",
    });
    defer std.testing.allocator.free(search_terms);
    try std.testing.expect(std.mem.indexOf(u8, search_terms, "apply_patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_terms, "mutation gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_terms, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_terms, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_terms, "find contract executor") != null);
}

test "collect evidence candidates returns definitions without evidence body" {
    var result = try executeCandidates(std.testing.allocator, std.testing.io, .{
        .intent = "find renderer definition candidates",
        .terms = "AppendOnlyRenderer render",
        .strategy = .symbol,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[CANDIDATES]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[EVIDENCE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "\n[MICRO_CONTEXT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "raw_context_persisted=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "C1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.audit_text, "stage=candidates") != null);
    try std.testing.expect(result.model_bytes == result.text.len);
}

test "collect evidence candidates render module entrypoint signature" {
    var result = try executeCandidates(std.testing.allocator, std.testing.io, .{
        .intent = "find collect_evidence executor",
        .terms = "collect_evidence funcao responsavel coleta evidencias",
        .strategy = .symbol,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "source=module_entrypoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "def: pub fn execute(") != null);
}

test "collect evidence candidates can fall back to task when model omits terms" {
    var result = try executeCandidates(std.testing.allocator, std.testing.io, .{
        .task = "collect_evidence funcao responsavel coleta evidencias",
        .strategy = .symbol,
        .budget_bytes = 6000,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "source=module_entrypoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "def: pub fn execute(") != null);
}

test "candidate line selection follows model terms inside ranked range" {
    const selected = selectCandidateLine(
        \\unrelated header
        \\const alpha = 1;
        \\pub fn renderCliOutput() void {}
        \\footer
    , 41, 43, "renderCliOutput output", "src/render.zig");
    try std.testing.expectEqual(@as(usize, 43), selected.line);
    try std.testing.expectEqualStrings("pub fn renderCliOutput() void {}", selected.text);
}

test "candidate line selection can use candidate path stem without language lists" {
    const selected = selectCandidateLine(
        \\terminal_columns: usize = 80,
        \\max_tool_sample_lines: usize = 20,
        \\pub fn AppendOnlyRenderer(comptime Writer: type) type {
    , 7, 11, "funcao responsavel cli projeto", "src/render.zig");
    try std.testing.expectEqual(@as(usize, 9), selected.line);
    try std.testing.expectEqualStrings("pub fn AppendOnlyRenderer(comptime Writer: type) type {", selected.text);
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
