const std = @import("std");

const contracts = @import("contracts.zig");
const fts_ranker = @import("fts_ranker.zig");
const symbol_ranker = @import("symbol_ranker.zig");
const workspace_inventory = @import("workspace_inventory.zig");

pub const CandidateSource = enum {
    prompt_path,
    module_entrypoint,
    symbol_ast,
    local_symbol_ast,
    rg,
    fts_bm25,
    fallback_scan,
    workspace_overview,
    keyword_discovery,
};

pub const RankBudget = struct {
    max_candidates: usize = 16,
    max_ranges: usize = 4,
    max_lines_per_range: usize = 80,
    window_before: usize = 12,
    window_after: usize = 24,
    max_rg_bytes: usize = 512 * 1024,
};

const collection_headroom_factor: usize = 4;

pub const EvidenceCandidate = struct {
    path: []u8,
    start_line: usize,
    end_line: usize,
    score: i32,
    source: CandidateSource,
    reasons: []u8,

    pub fn deinit(self: EvidenceCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.reasons);
    }
};

pub const RankingResult = struct {
    candidates: std.ArrayList(EvidenceCandidate),
    audit_text: []u8,
    rg_invocations: usize,
    rg_available: bool,
    fts_available: bool,
    fts_indexed_files: usize,
    symbol_available: bool,
    symbol_indexed_files: usize,
    symbols_seen: usize,

    pub fn deinit(self: *RankingResult, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |candidate| candidate.deinit(allocator);
        self.candidates.deinit(allocator);
        allocator.free(self.audit_text);
    }
};

const TermList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator) TermList {
        return .{ .allocator = allocator, .items = std.ArrayList([]u8).empty };
    }

    fn deinit(self: *TermList) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }

    fn add(self: *TermList, term: []const u8) !void {
        const cleaned = cleanTerm(term);
        if (cleaned.len < 3) return;
        if (!isSearchableTerm(cleaned)) return;
        for (self.items.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, cleaned)) return;
        }
        try self.items.append(self.allocator, try self.allocator.dupe(u8, cleaned));
    }
};

pub fn rankForPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !RankingResult {
    var terms = TermList.init(allocator);
    defer terms.deinit();
    try extractTerms(&terms, prompt, strategy);
    sortTermsBySpecificity(terms.items.items);

    var candidates = std.ArrayList(EvidenceCandidate).empty;
    errdefer freeCandidates(allocator, &candidates);

    var rg_invocations: usize = 0;
    var rg_available = true;
    var fts_available = true;
    var fts_indexed_files: usize = 0;
    var symbol_available = true;
    var symbol_indexed_files: usize = 0;
    var symbols_seen: usize = 0;

    // Phase 1: model terms against workspace path names.
    if (prompt.len > 0) {
        try collectPathNameCandidates(allocator, io, &candidates, terms.items.items, strategy, budget);
    }

    // Phase 2: syntax-aware symbols for strategy=symbol.
    if (strategy == .symbol and prompt.len > 0) {
        const symbol_result = collectSymbolCandidates(allocator, io, &candidates, prompt, budget) catch blk: {
            symbol_available = false;
            break :blk null;
        };
        if (symbol_result) |stats| {
            symbol_indexed_files = stats.indexed_files;
            symbols_seen = stats.symbol_count;
        }
    }

    // Phase 3: per-term rg for structured terms only (paths, code symbols, camelCase, etc.)
    for (terms.items.items) |term| {
        if (candidates.items.len >= collectionLimit(budget)) break;
        if (!isStructuredSearchTerm(term)) continue;
        collectRgCandidates(allocator, io, &candidates, term, strategy, budget) catch |err| switch (err) {
            error.RgUnavailable => {
                rg_available = false;
                try collectFallbackCandidates(allocator, io, &candidates, term, strategy, budget);
            },
            else => return err,
        };
        rg_invocations += 1;
    }

    // Phase 4: SQLite FTS5/BM25 over current workspace, using model-provided terms only.
    if ((candidates.items.len < collectionLimit(budget) or strategy == .symbol) and (strategy == .auto or strategy == .lexical or strategy == .symbol) and prompt.len > 0) {
        const fts_result = collectFtsCandidates(allocator, io, &candidates, prompt, budget, strategy == .symbol) catch |err| switch (err) {
            error.SqliteOpenFailed, error.SqliteExecFailed, error.SqlitePrepareFailed, error.SqliteBindFailed, error.SqliteStepFailed => blk: {
                fts_available = false;
                break :blk null;
            },
            else => return err,
        };
        if (fts_result) |indexed| fts_indexed_files = indexed;
    }

    // Phase 5: public module entrypoints from files already selected by path/rg/FTS/symbol evidence.
    if (strategy == .symbol and candidates.items.len > 0) {
        const entrypoint_stats = collectModuleEntrypointCandidates(allocator, io, &candidates, budget) catch blk: {
            symbol_available = false;
            break :blk null;
        };
        if (entrypoint_stats) |stats| {
            symbol_indexed_files += stats.indexed_files;
            symbols_seen += stats.symbol_count;
        }
    }

    // Phase 6: batch file discovery via plain keywords (single rg -l call for all NL-like words)
    if (candidates.items.len < collectionLimit(budget) and strategy == .auto) {
        try discoverFilesByKeywords(allocator, io, &candidates, terms.items.items, budget);
    }

    // Phase 7: path candidates from prompt text
    if (candidates.items.len == 0) {
        try addPromptPathCandidates(allocator, &candidates, prompt, strategy, budget);
    }

    // Phase 8: workspace overview fallback
    if (candidates.items.len == 0 and strategy == .auto) {
        try addWorkspaceOverviewCandidates(allocator, io, &candidates, budget);
    }

    sortCandidates(candidates.items);
    var merged = try mergeCandidates(allocator, candidates.items, budget);
    freeCandidates(allocator, &candidates);
    sortCandidates(merged.items);
    if (strategy == .symbol and merged.items.len > 0) {
        const local_stats = collectTopPathLocalSymbolCandidates(allocator, io, &merged, prompt, budget) catch blk: {
            symbol_available = false;
            break :blk null;
        };
        if (local_stats) |stats| {
            symbol_indexed_files += stats.indexed_files;
            symbols_seen += stats.symbol_count;
        }
        sortCandidates(merged.items);
    }
    trimCandidates(allocator, &merged, budget.max_ranges);

    const audit = try renderAudit(allocator, merged.items, terms.items.items, strategy, rg_invocations, rg_available, fts_available, fts_indexed_files, symbol_available, symbol_indexed_files, symbols_seen);
    errdefer allocator.free(audit);
    return .{
        .candidates = merged,
        .audit_text = audit,
        .rg_invocations = rg_invocations,
        .rg_available = rg_available,
        .fts_available = fts_available,
        .fts_indexed_files = fts_indexed_files,
        .symbol_available = symbol_available,
        .symbol_indexed_files = symbol_indexed_files,
        .symbols_seen = symbols_seen,
    };
}

fn extractTerms(out: *TermList, prompt: []const u8, strategy: contracts.StrategyName) !void {
    _ = strategy;
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>:;,");
    while (it.next()) |raw| {
        try out.add(raw);
    }
}

fn collectRgCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    term: []const u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !void {
    const argv = [_][]const u8{
        "rg",
        "--line-number",
        "--column",
        "--no-heading",
        "--color",
        "never",
        "--max-count",
        "24",
        term,
        ".",
    };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(budget.max_rg_bytes),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.RgUnavailable,
        error.StreamTooLong => return,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (out.items.len >= collectionLimit(budget)) break;
        try parseRgLine(allocator, out, line, term, strategy, budget);
    }
}

fn parseRgLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(EvidenceCandidate),
    line: []const u8,
    term: []const u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !void {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return;
    const second_rel = std.mem.indexOfScalar(u8, line[first + 1 ..], ':') orelse return;
    const second = first + 1 + second_rel;
    const third_rel = std.mem.indexOfScalar(u8, line[second + 1 ..], ':') orelse return;
    const third = second + 1 + third_rel;
    const raw_path = normalizeRgPath(line[0..first]);
    if (!workspace_inventory.isWorkspacePath(raw_path)) return;
    const line_no = std.fmt.parseInt(usize, line[first + 1 .. second], 10) catch return;
    const text = line[third + 1 ..];
    const start = if (line_no > budget.window_before) line_no - budget.window_before else 1;
    const end = line_no + budget.window_after;
    const score = scoreMatch(raw_path, text, term, strategy);
    const reasons = try reasonText(allocator, raw_path, text, term, strategy);
    errdefer allocator.free(reasons);
    try out.append(allocator, .{
        .path = try allocator.dupe(u8, raw_path),
        .start_line = start,
        .end_line = @min(end, start + budget.max_lines_per_range - 1),
        .score = score,
        .source = .rg,
        .reasons = reasons,
    });
}

fn collectFallbackCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    term: []const u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !void {
    _ = strategy;
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var inventory = try workspace_inventory.collect(allocator, io, budget.max_candidates * 32);
    defer inventory.deinit(allocator);
    for (inventory.paths.items) |path| {
        if (out.items.len >= budget.max_candidates) break;
        const content = cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);
        if (!workspace_inventory.isTextBytes(content)) continue;
        if (std.mem.indexOf(u8, content, term)) |idx| {
            const line_no = lineNumberAt(content, idx);
            const start = if (line_no > budget.window_before) line_no - budget.window_before else 1;
            const reasons = try allocator.dupe(u8, "fallback_scan,exact_term_match");
            errdefer allocator.free(reasons);
            try out.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .start_line = start,
                .end_line = @min(line_no + budget.window_after, start + budget.max_lines_per_range - 1),
                .score = 35,
                .source = .fallback_scan,
                .reasons = reasons,
            });
        }
    }
}

fn collectPathNameCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    term_slice: []const []u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !void {
    var inventory = try workspace_inventory.collect(allocator, io, budget.max_candidates * 64);
    defer inventory.deinit(allocator);
    for (inventory.paths.items) |path| {
        if (out.items.len >= budget.max_candidates) break;
        var best_score: i32 = 0;
        for (term_slice, 0..) |term, term_index| {
            if (term.len < 3) continue;
            const exact = containsIgnoreCase(path, term);
            const fuzzy = fuzzyTextMatchScore(path, term);
            const tokenized = symbol_ranker.tokenizedIdentifierMatchScore(path, term, 6, 2);
            if (!exact and fuzzy == 0 and tokenized == 0) continue;
            var score: i32 = if (exact and isStructuredSearchTerm(term))
                900 + @as(i32, @intCast(@min(term.len, 48)))
            else if (exact)
                68 + @as(i32, @intCast(@min(term.len, 24)))
            else
                48 + @as(i32, @intCast(fuzzy));
            if (tokenized > 0) score = @max(score, 100 + @as(i32, @intCast(@min(tokenized, 160))));
            if (term_index < 3) score += 80 else if (term_index < 6) score += 40;
            best_score = @max(best_score, score);
        }
        if (best_score == 0) continue;
        const reasons = try std.fmt.allocPrint(allocator, "path_name_match,strategy={s}", .{@tagName(strategy)});
        errdefer allocator.free(reasons);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try out.append(allocator, .{
            .path = owned_path,
            .start_line = 1,
            .end_line = budget.max_lines_per_range,
            .score = best_score,
            .source = .prompt_path,
            .reasons = reasons,
        });
    }
}

fn discoverFilesByKeywords(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    term_slice: []const []u8,
    budget: RankBudget,
) !void {
    var plain_count: usize = 0;
    for (term_slice) |term| {
        if (isStructuredSearchTerm(term)) continue;
        plain_count += 1;
    }
    if (plain_count == 0) return;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "rg");
    try argv.append(allocator, "-c");
    try argv.append(allocator, "--color");
    try argv.append(allocator, "never");
    for (term_slice) |term| {
        if (isStructuredSearchTerm(term)) continue;
        try argv.append(allocator, "-e");
        try argv.append(allocator, term);
    }
    try argv.append(allocator, ".");

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(budget.max_rg_bytes),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.StreamTooLong => return,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        const path = normalizeRgPath(std.mem.trim(u8, line[0..colon], " \t\r\n"));
        const count = std.fmt.parseInt(usize, line[colon + 1 ..], 10) catch continue;
        if (count == 0) continue;
        if (!workspace_inventory.isWorkspacePath(path)) continue;
        if (out.items.len >= collectionLimit(budget)) break;
        const score: i32 = 40 + @as(i32, @intCast(@min(count * 3, 15)));
        const reasons = try std.fmt.allocPrint(allocator, "keyword_discovery,plain_keyword_match,count={}", .{count});
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .start_line = 1,
            .end_line = budget.max_lines_per_range,
            .score = score,
            .source = .keyword_discovery,
            .reasons = reasons,
        });
    }
}

fn addPromptPathCandidates(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(EvidenceCandidate),
    prompt: []const u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !void {
    _ = strategy;
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>:;,");
    while (it.next()) |raw| {
        if (!looksLikePath(raw) or !workspace_inventory.isWorkspacePath(raw)) continue;
        const reasons = try allocator.dupe(u8, "prompt_path_match");
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, raw),
            .start_line = 1,
            .end_line = budget.max_lines_per_range,
            .score = 55,
            .source = .prompt_path,
            .reasons = reasons,
        });
    }
}

fn collectFtsCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    terms: []const u8,
    budget: RankBudget,
    allow_extra: bool,
) !usize {
    var ranked = try fts_ranker.rank(allocator, io, terms, budget.max_candidates);
    defer ranked.deinit(allocator);
    _ = allow_extra;
    const max_out = collectionLimit(budget);
    for (ranked.candidates.items) |candidate| {
        if (out.items.len >= max_out) break;
        if (!workspace_inventory.isWorkspacePath(candidate.path)) continue;
        const start = if (candidate.line > budget.window_before) candidate.line - budget.window_before else 1;
        const reasons = try std.fmt.allocPrint(allocator, "fts5_bm25,indexed_files={}", .{ranked.indexed_files});
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, candidate.path),
            .start_line = start,
            .end_line = @min(candidate.line + budget.window_after, start + budget.max_lines_per_range - 1),
            .score = candidate.score,
            .source = .fts_bm25,
            .reasons = reasons,
        });
    }
    return ranked.indexed_files;
}

const SymbolStats = struct {
    indexed_files: usize,
    symbol_count: usize,
};

fn collectSymbolCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    terms: []const u8,
    budget: RankBudget,
) !SymbolStats {
    var ranked = try symbol_ranker.rank(allocator, io, terms, budget.max_candidates);
    defer ranked.deinit(allocator);
    for (ranked.candidates.items) |candidate| {
        if (out.items.len >= collectionLimit(budget)) break;
        if (!workspace_inventory.isWorkspacePath(candidate.path)) continue;
        const reasons = try std.fmt.allocPrint(allocator, "symbol_ast,symbol={s},indexed_files={},symbols={}", .{ candidate.symbol, ranked.indexed_files, ranked.symbol_count });
        errdefer allocator.free(reasons);
        const owned_path = try allocator.dupe(u8, candidate.path);
        errdefer allocator.free(owned_path);
        try out.append(allocator, .{
            .path = owned_path,
            .start_line = candidate.start_line,
            .end_line = @min(candidate.end_line, candidate.start_line + budget.max_lines_per_range - 1),
            .score = @min(candidate.score + 80, 1200),
            .source = .symbol_ast,
            .reasons = reasons,
        });
    }
    return .{ .indexed_files = ranked.indexed_files, .symbol_count = ranked.symbol_count };
}

fn collectModuleEntrypointCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    budget: RankBudget,
) !SymbolStats {
    var boosts = std.ArrayList(symbol_ranker.PathBoost).empty;
    defer boosts.deinit(allocator);
    for (out.items) |candidate| {
        if (candidate.source == .module_entrypoint) continue;
        try addPathBoost(allocator, &boosts, candidate.path, candidate.score, candidate.source);
    }
    sortPathBoosts(boosts.items);
    const boost_limit = @min(boosts.items.len, @max(@as(usize, 1), budget.max_ranges));
    var ranked = try symbol_ranker.rankEntrypointsForPaths(allocator, io, boosts.items[0..boost_limit], budget.max_candidates);
    defer ranked.deinit(allocator);
    for (ranked.candidates.items) |candidate| {
        if (!workspace_inventory.isWorkspacePath(candidate.path)) continue;
        const reasons = try std.fmt.allocPrint(allocator, "module_entrypoint,symbol={s},indexed_files={},symbols={}", .{ candidate.symbol, ranked.indexed_files, ranked.symbol_count });
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, candidate.path),
            .start_line = candidate.start_line,
            .end_line = @min(candidate.end_line, candidate.start_line + budget.max_lines_per_range - 1),
            .score = candidate.score,
            .source = .module_entrypoint,
            .reasons = reasons,
        });
    }
    return .{ .indexed_files = ranked.indexed_files, .symbol_count = ranked.symbol_count };
}

fn collectTopPathLocalSymbolCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    query: []const u8,
    budget: RankBudget,
) !SymbolStats {
    if (out.items.len == 0) return .{ .indexed_files = 0, .symbol_count = 0 };
    const anchor = localSymbolAnchor(out.items);
    const paths = [_]symbol_ranker.PathBoost{.{
        .path = anchor.path,
        .score = @min(anchor.score, 320),
        .corroboration_score = 0,
    }};
    var ranked = try symbol_ranker.rankLocalSymbolsForPaths(allocator, io, &paths, query, budget.max_candidates);
    defer ranked.deinit(allocator);
    for (ranked.candidates.items) |candidate| {
        if (!workspace_inventory.isWorkspacePath(candidate.path)) continue;
        const reasons = try std.fmt.allocPrint(allocator, "local_symbol_ast,symbol={s},indexed_files={},symbols={}", .{ candidate.symbol, ranked.indexed_files, ranked.symbol_count });
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, candidate.path),
            .start_line = candidate.start_line,
            .end_line = @min(candidate.end_line, candidate.start_line + budget.max_lines_per_range - 1),
            .score = candidate.score + 80,
            .source = .local_symbol_ast,
            .reasons = reasons,
        });
    }
    return .{ .indexed_files = ranked.indexed_files, .symbol_count = ranked.symbol_count };
}

fn localSymbolAnchor(candidates: []const EvidenceCandidate) EvidenceCandidate {
    for (candidates) |candidate| {
        if (candidate.source == .prompt_path) return candidate;
    }
    for (candidates) |candidate| {
        if (candidate.source == .module_entrypoint) return candidate;
    }
    return candidates[0];
}

fn addPathBoost(
    allocator: std.mem.Allocator,
    boosts: *std.ArrayList(symbol_ranker.PathBoost),
    path: []const u8,
    score: i32,
    source: CandidateSource,
) !void {
    const capped_score: i32 = switch (source) {
        .symbol_ast, .local_symbol_ast, .module_entrypoint => @min(score, 240),
        else => score,
    };
    const corroboration = if (source == .prompt_path) @min(capped_score, 240) else 0;
    for (boosts.items) |*boost| {
        if (!std.mem.eql(u8, boost.path, path)) continue;
        boost.score = @max(boost.score, capped_score);
        boost.corroboration_score = @max(boost.corroboration_score, corroboration);
        return;
    }
    try boosts.append(allocator, .{ .path = path, .score = capped_score, .corroboration_score = corroboration });
}

fn sortPathBoosts(boosts: []symbol_ranker.PathBoost) void {
    std.mem.sort(symbol_ranker.PathBoost, boosts, {}, struct {
        fn lessThan(_: void, a: symbol_ranker.PathBoost, b: symbol_ranker.PathBoost) bool {
            const a_score = a.score + a.corroboration_score;
            const b_score = b.score + b.corroboration_score;
            if (a_score != b_score) return a_score > b_score;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

fn addWorkspaceOverviewCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(EvidenceCandidate),
    budget: RankBudget,
) !void {
    var inventory = try workspace_inventory.collect(allocator, io, budget.max_candidates * 8);
    defer inventory.deinit(allocator);
    sortOverviewPaths(inventory.paths.items);

    const limit = @min(inventory.paths.items.len, budget.max_candidates);
    for (inventory.paths.items[0..limit]) |path| {
        const reasons = try allocator.dupe(u8, "workspace_overview_structure");
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .start_line = 1,
            .end_line = budget.max_lines_per_range,
            .score = overviewScore(path),
            .source = .workspace_overview,
            .reasons = reasons,
        });
    }
}

fn overviewScore(path: []const u8) i32 {
    const depth = pathDepth(path);
    var score: i32 = 48;
    score -= @as(i32, @intCast(@min(depth * 6, 30)));
    score -= @as(i32, @intCast(@min(path.len / 32, 12)));
    return score;
}

fn sortOverviewPaths(paths: [][]u8) void {
    std.mem.sort([]u8, paths, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_depth = pathDepth(a);
            const b_depth = pathDepth(b);
            if (a_depth != b_depth) return a_depth < b_depth;
            if (a.len != b.len) return a.len < b.len;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |byte| {
        if (byte == '/') depth += 1;
    }
    return depth;
}

pub fn mergeCandidates(
    allocator: std.mem.Allocator,
    candidates: []const EvidenceCandidate,
    budget: RankBudget,
) !std.ArrayList(EvidenceCandidate) {
    const sorted = try allocator.dupe(EvidenceCandidate, candidates);
    defer allocator.free(sorted);
    sortCandidates(sorted);

    var merged = std.ArrayList(EvidenceCandidate).empty;
    errdefer freeCandidates(allocator, &merged);
    for (sorted) |candidate| {
        var merged_existing = false;
        for (merged.items) |*existing| {
            if (!std.mem.eql(u8, existing.path, candidate.path)) continue;
            if (!rangesTouch(existing.start_line, existing.end_line, candidate.start_line, candidate.end_line)) continue;
            if (!canMergeCandidateSources(existing.*, candidate)) continue;
            existing.start_line = @min(existing.start_line, candidate.start_line);
            existing.end_line = @min(@max(existing.end_line, candidate.end_line), existing.start_line + budget.max_lines_per_range - 1);
            existing.score = @max(existing.score, candidate.score) + 4;
            if (std.mem.indexOf(u8, existing.reasons, candidate.reasons) == null) {
                const merged_reasons = try std.fmt.allocPrint(allocator, "{s};{s}", .{ existing.reasons, candidate.reasons });
                allocator.free(existing.reasons);
                existing.reasons = merged_reasons;
            }
            merged_existing = true;
            break;
        }
        if (merged_existing) continue;
        try merged.append(allocator, .{
            .path = try allocator.dupe(u8, candidate.path),
            .start_line = candidate.start_line,
            .end_line = candidate.end_line,
            .score = candidate.score,
            .source = candidate.source,
            .reasons = try allocator.dupe(u8, candidate.reasons),
        });
    }
    return merged;
}

fn canMergeCandidateSources(a: EvidenceCandidate, b: EvidenceCandidate) bool {
    if (isStructuralCandidateSource(a.source) or isStructuralCandidateSource(b.source)) {
        return a.source == b.source and a.start_line == b.start_line;
    }
    return true;
}

fn isStructuralCandidateSource(source: CandidateSource) bool {
    return source == .symbol_ast or source == .local_symbol_ast or source == .module_entrypoint;
}

pub fn adaptiveBudget(total_budget: usize, quality_score: i32, range_count: usize) usize {
    if (range_count == 0) return total_budget;
    const quality_factor: usize = if (quality_score >= 90) 3 else if (quality_score >= 65) 2 else 1;
    const per_range = @max(@as(usize, 512), total_budget / range_count);
    return @min(total_budget, per_range * quality_factor);
}

fn collectionLimit(budget: RankBudget) usize {
    return budget.max_candidates * collection_headroom_factor;
}

pub fn qualityEnough(score: i32) bool {
    return score >= 64;
}

fn scoreMatch(path: []const u8, text: []const u8, term: []const u8, strategy: contracts.StrategyName) i32 {
    _ = strategy;
    var score: i32 = 20;
    if (containsIgnoreCase(text, term)) score += 35;
    if (containsIgnoreCase(path, term)) score += 22;
    score += @as(i32, @intCast(fuzzyTextMatchScore(text, term) / 2));
    score += @as(i32, @intCast(fuzzyTextMatchScore(path, term)));
    return score;
}

fn reasonText(allocator: std.mem.Allocator, path: []const u8, text: []const u8, term: []const u8, strategy: contracts.StrategyName) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "rg");
    if (containsIgnoreCase(text, term)) try out.appendSlice(allocator, ",exact_term_match");
    if (containsIgnoreCase(path, term)) try out.appendSlice(allocator, ",path_match");
    if (strategy != .auto) {
        try out.appendSlice(allocator, ",strategy=");
        try out.appendSlice(allocator, @tagName(strategy));
    }
    return out.toOwnedSlice(allocator);
}

fn renderAudit(
    allocator: std.mem.Allocator,
    candidates: []const EvidenceCandidate,
    terms: []const []u8,
    strategy: contracts.StrategyName,
    rg_invocations: usize,
    rg_available: bool,
    fts_available: bool,
    fts_indexed_files: usize,
    symbol_available: bool,
    symbol_indexed_files: usize,
    symbols_seen: usize,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const header = try std.fmt.allocPrint(
        allocator,
        "[CANDIDATE_RANKING]\nstrategy={s}\nrg_invocations={}\nrg_available={}\nfts_available={}\nfts_indexed_files={}\nsymbol_available={}\nsymbol_indexed_files={}\nsymbols_seen={}\nterms={}\n",
        .{ @tagName(strategy), rg_invocations, rg_available, fts_available, fts_indexed_files, symbol_available, symbol_indexed_files, symbols_seen, terms.len },
    );
    defer allocator.free(header);
    try out.appendSlice(allocator, header);
    for (candidates, 0..) |candidate, i| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{}. {s} L{}-L{} score={} source={s} reasons={s}\n",
            .{ i + 1, candidate.path, candidate.start_line, candidate.end_line, candidate.score, @tagName(candidate.source), candidate.reasons },
        );
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

fn freeCandidates(allocator: std.mem.Allocator, candidates: *std.ArrayList(EvidenceCandidate)) void {
    for (candidates.items) |candidate| candidate.deinit(allocator);
    candidates.deinit(allocator);
}

fn sortCandidates(candidates: []EvidenceCandidate) void {
    std.mem.sort(EvidenceCandidate, candidates, {}, struct {
        fn lessThan(_: void, a: EvidenceCandidate, b: EvidenceCandidate) bool {
            return candidatePrecedes(a, b);
        }
    }.lessThan);
}

fn candidatePrecedes(a: EvidenceCandidate, b: EvidenceCandidate) bool {
    if (a.score != b.score) return a.score > b.score;
    if (!std.mem.eql(u8, a.path, b.path)) return std.mem.lessThan(u8, a.path, b.path);
    return a.start_line < b.start_line;
}

fn sortTermsBySpecificity(terms: [][]u8) void {
    std.mem.sort([]u8, terms, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_code = std.mem.indexOfScalar(u8, a, '_') != null or looksLikePath(a);
            const b_code = std.mem.indexOfScalar(u8, b, '_') != null or looksLikePath(b);
            if (a_code != b_code) return a_code;
            return a.len > b.len;
        }
    }.lessThan);
}

fn trimCandidates(allocator: std.mem.Allocator, candidates: *std.ArrayList(EvidenceCandidate), max: usize) void {
    if (candidates.items.len <= max) return;

    var selected: usize = 0;
    var i: usize = 0;
    while (i < candidates.items.len and selected < max) : (i += 1) {
        if (sourceAlreadySelected(candidates.items[0..selected], candidates.items[i].source)) continue;
        std.mem.swap(EvidenceCandidate, &candidates.items[selected], &candidates.items[i]);
        selected += 1;
    }

    while (selected < max) : (selected += 1) {
        var best: ?usize = null;
        i = selected + 1;
        while (i < candidates.items.len) : (i += 1) {
            if (sourceCount(candidates.items[0..selected], candidates.items[i].source) >= preferredSourceLimit(candidates.items[i].source)) continue;
            if (best == null or candidatePrecedes(candidates.items[i], candidates.items[best.?])) best = i;
        }
        if (sourceCount(candidates.items[0..selected], candidates.items[selected].source) < preferredSourceLimit(candidates.items[selected].source)) {
            if (best == null or candidatePrecedes(candidates.items[selected], candidates.items[best.?])) best = selected;
        }
        if (best == null) {
            best = selected;
            i = selected + 1;
            while (i < candidates.items.len) : (i += 1) {
                if (candidatePrecedes(candidates.items[i], candidates.items[best.?])) best = i;
            }
        }
        std.mem.swap(EvidenceCandidate, &candidates.items[selected], &candidates.items[best.?]);
    }

    while (candidates.items.len > selected) {
        const removed = candidates.pop().?;
        removed.deinit(allocator);
    }
}

fn sourceAlreadySelected(candidates: []const EvidenceCandidate, source: CandidateSource) bool {
    for (candidates) |candidate| {
        if (candidate.source == source) return true;
    }
    return false;
}

fn sourceCount(candidates: []const EvidenceCandidate, source: CandidateSource) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.source == source) count += 1;
    }
    return count;
}

fn preferredSourceLimit(source: CandidateSource) usize {
    return switch (source) {
        .local_symbol_ast => 3,
        .symbol_ast => 1,
        .module_entrypoint => 1,
        else => 1,
    };
}

fn rangesTouch(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
    return a_start <= b_end + 1 and b_start <= a_end + 1;
}

fn normalizeRgPath(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

fn looksLikePath(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, '/') != null) return true;
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return false;
    return dot > 0 and dot + 1 < text.len;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fuzzyTextMatchScore(haystack: []const u8, term: []const u8) usize {
    if (term.len < 5 or haystack.len < 5) return 0;
    const common = longestAsciiFoldedTermPrefixInHaystack(haystack, term);
    if (common < 5) return 0;
    return common * 6;
}

fn longestAsciiFoldedTermPrefixInHaystack(haystack: []const u8, term: []const u8) usize {
    var best: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        var term_start: usize = 0;
        while (term_start < term.len) : (term_start += 1) {
            var n: usize = 0;
            while (i + n < haystack.len and term_start + n < term.len and asciiFold(haystack[i + n]) == asciiFold(term[term_start + n])) : (n += 1) {}
            if (term_start > 0 and n < 6) continue;
            best = @max(best, n);
        }
    }
    return best;
}

fn asciiFold(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

fn cleanTerm(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n\"'`()[]{}<>:;,.!?");
}

fn isSearchableTerm(term: []const u8) bool {
    return isStructuredSearchTerm(term) or isPlainKeyword(term);
}

fn isPlainKeyword(term: []const u8) bool {
    if (term.len < 3) return false;
    for (term) |byte| {
        if (byte < 0x80 and !std.ascii.isAlphabetic(byte) and byte != '_') return false;
    }
    return true;
}

fn isStructuredSearchTerm(term: []const u8) bool {
    if (looksLikePath(term)) return true;
    if (std.mem.indexOfScalar(u8, term, '_') != null) return true;
    if (std.mem.indexOfScalar(u8, term, '.') != null) return true;
    if (std.mem.indexOfScalar(u8, term, '-') != null) return true;
    if (hasUpperAfterLower(term)) return true;
    if (looksLikeDiagnosticToken(term)) return true;
    return false;
}

fn hasUpperAfterLower(term: []const u8) bool {
    var saw_lower = false;
    for (term) |byte| {
        if (std.ascii.isLower(byte)) saw_lower = true;
        if (saw_lower and std.ascii.isUpper(byte)) return true;
    }
    return false;
}

fn looksLikeDiagnosticToken(term: []const u8) bool {
    if (std.mem.endsWith(u8, term, "Error")) return true;
    if (std.mem.endsWith(u8, term, "Failed")) return true;
    if (std.mem.endsWith(u8, term, "Leak")) return true;
    if (std.mem.indexOf(u8, term, "error.") != null) return true;
    return false;
}

fn lineNumberAt(text: []const u8, idx: usize) usize {
    var line: usize = 1;
    for (text[0..@min(idx, text.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

test "merge candidates combines adjacent and overlapping ranges" {
    const input = [_]EvidenceCandidate{
        .{
            .path = try std.testing.allocator.dupe(u8, "src/main.zig"),
            .start_line = 10,
            .end_line = 20,
            .score = 50,
            .source = .rg,
            .reasons = try std.testing.allocator.dupe(u8, "a"),
        },
        .{
            .path = try std.testing.allocator.dupe(u8, "src/main.zig"),
            .start_line = 21,
            .end_line = 30,
            .score = 60,
            .source = .rg,
            .reasons = try std.testing.allocator.dupe(u8, "b"),
        },
    };
    defer for (input) |candidate| candidate.deinit(std.testing.allocator);
    var merged = try mergeCandidates(std.testing.allocator, &input, .{ .max_lines_per_range = 80 });
    defer freeCandidates(std.testing.allocator, &merged);
    try std.testing.expectEqual(@as(usize, 1), merged.items.len);
    try std.testing.expectEqual(@as(usize, 10), merged.items[0].start_line);
    try std.testing.expectEqual(@as(usize, 30), merged.items[0].end_line);
}

test "merge candidates preserves module entrypoint range" {
    const input = [_]EvidenceCandidate{
        .{
            .path = try std.testing.allocator.dupe(u8, "src/fts_ranker.zig"),
            .start_line = 1,
            .end_line = 48,
            .score = 100,
            .source = .fts_bm25,
            .reasons = try std.testing.allocator.dupe(u8, "fts"),
        },
        .{
            .path = try std.testing.allocator.dupe(u8, "src/fts_ranker.zig"),
            .start_line = 49,
            .end_line = 96,
            .score = 300,
            .source = .module_entrypoint,
            .reasons = try std.testing.allocator.dupe(u8, "module_entrypoint,symbol=rank"),
        },
    };
    defer for (input) |candidate| candidate.deinit(std.testing.allocator);
    var merged = try mergeCandidates(std.testing.allocator, &input, .{ .max_lines_per_range = 80 });
    defer freeCandidates(std.testing.allocator, &merged);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqual(CandidateSource.module_entrypoint, merged.items[0].source);
    try std.testing.expectEqual(@as(usize, 49), merged.items[0].start_line);
}

test "symbol ranking promotes public entrypoints from relevant modules" {
    var result = try rankForPrompt(std.testing.allocator, std.testing.io, "collect_evidence funcao responsavel coleta evidencias", .symbol, .{
        .max_ranges = 6,
        .max_lines_per_range = 48,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expectEqualStrings("src/collect_evidence.zig", result.candidates.items[0].path);
    try std.testing.expect(result.candidates.items[0].start_line < 120);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates.items[0].reasons, "module_entrypoint") != null);
}

test "trim candidates preserves source diversity before filling by score" {
    var candidates = std.ArrayList(EvidenceCandidate).empty;
    defer freeCandidates(std.testing.allocator, &candidates);

    try candidates.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "a.zig"),
        .start_line = 1,
        .end_line = 2,
        .score = 100,
        .source = .symbol_ast,
        .reasons = try std.testing.allocator.dupe(u8, "symbol"),
    });
    try candidates.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "b.zig"),
        .start_line = 1,
        .end_line = 2,
        .score = 99,
        .source = .symbol_ast,
        .reasons = try std.testing.allocator.dupe(u8, "symbol"),
    });
    try candidates.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "c.zig"),
        .start_line = 1,
        .end_line = 2,
        .score = 10,
        .source = .rg,
        .reasons = try std.testing.allocator.dupe(u8, "rg"),
    });

    trimCandidates(std.testing.allocator, &candidates, 2);

    try std.testing.expectEqual(@as(usize, 2), candidates.items.len);
    try std.testing.expectEqual(CandidateSource.symbol_ast, candidates.items[0].source);
    try std.testing.expectEqual(CandidateSource.rg, candidates.items[1].source);
}

test "ranking with rg finds collect evidence implementation without raw output audit" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "collect_evidence execute", .lexical, .{ .max_ranges = 3 });
    defer ranked.deinit(std.testing.allocator);
    try std.testing.expect(ranked.candidates.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "[CANDIDATE_RANKING]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "rg_invocations=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "---BEGIN CONTENT---") == null);
}

test "ranking still uses rg when path-name candidates saturate first slots" {
    const term = "ambiguous" ++ "_" ++ "symbol";
    var decoy_bufs: [6][64]u8 = undefined;
    var decoys: [6][]const u8 = undefined;
    for (&decoy_bufs, 0..) |*buf, i| {
        decoys[i] = try std.fmt.bufPrint(buf, "{s}_decoy_{}.txt", .{ term, i + 1 });
    }
    for (decoys) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "decoy\n" });
    }
    defer for (decoys) |path| std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const target = "zz_rg_target.txt";
    var target_data_buf: [96]u8 = undefined;
    const target_data = try std.fmt.bufPrint(&target_data_buf, "fn {s}() void {{}}\n", .{term});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = target, .data = target_data });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, target) catch {};

    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, term, .lexical, .{ .max_candidates = 4, .max_ranges = 4 });
    defer ranked.deinit(std.testing.allocator);

    try std.testing.expect(ranked.rg_invocations > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "source=rg") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, target) != null);
}

test "auto ranking discovers files via plain keywords when no structured terms exist" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "Analise esse projeto de forma breve", .auto, .{ .max_ranges = 3 });
    defer ranked.deinit(std.testing.allocator);
    try std.testing.expect(ranked.candidates.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "keyword_discovery") != null or
        std.mem.indexOf(u8, ranked.audit_text, "fts5_bm25") != null or
        std.mem.indexOf(u8, ranked.audit_text, "workspace_overview") != null);
}

test "ranking can use sqlite fts bm25 without semantic model" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "renderer markdown diff", .lexical, .{ .max_ranges = 4 });
    defer ranked.deinit(std.testing.allocator);
    try std.testing.expect(ranked.candidates.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "fts_available=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "fts_indexed_files=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "---BEGIN CONTENT---") == null);
}

test "ranking uses model terms against workspace paths without preferred file list" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "render", .lexical, .{ .max_ranges = 4 });
    defer ranked.deinit(std.testing.allocator);
    try std.testing.expect(ranked.candidates.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "path_name_match") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "src/render.zig") != null);
}

test "symbol ranking uses fts corroboration for conceptual renderer query" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "CLI renderer output statusbar markdown diff", .symbol, .{ .max_ranges = 4 });
    defer ranked.deinit(std.testing.allocator);
    try std.testing.expect(ranked.candidates.items.len > 0);
    try std.testing.expect(ranked.fts_indexed_files > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "fts_indexed_files=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "source=symbol_ast") != null);
}

test "symbol ranking includes local functions from strong matched files" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "no renderer qual funcao faz a tabela aparecer cite evidencia", .symbol, .{ .max_ranges = 6 });
    defer ranked.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "source=local_symbol_ast") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "flushMarkdownTables") != null);
}

test "term extraction keeps structured symbols and plain keywords" {
    var terms = TermList.init(std.testing.allocator);
    defer terms.deinit();
    try extractTerms(&terms, "Use collect_evidence com strategy auto sem path para RawContextLeak", .auto);
    sortTermsBySpecificity(terms.items.items);

    try std.testing.expect(hasTerm(terms.items.items, "collect_evidence"));
    try std.testing.expect(hasTerm(terms.items.items, "RawContextLeak"));
    try std.testing.expect(hasTerm(terms.items.items, "Use"));
    try std.testing.expect(hasTerm(terms.items.items, "strategy"));
    try std.testing.expect(hasTerm(terms.items.items, "path"));
}

test "ranking score does not privilege language extension or penalize tests" {
    const code_score = scoreMatch("src/app.zig", "needle here", "needle", .lexical);
    const test_score = scoreMatch("tests/app.test.ts", "needle here", "needle", .lexical);
    try std.testing.expectEqual(code_score, test_score);
}

test "inactive strategy names do not inject synthetic search terms" {
    var terms = TermList.init(std.testing.allocator);
    defer terms.deinit();
    try extractTerms(&terms, "corrija este problema", .symbol);
    try std.testing.expect(!hasTerm(terms.items.items, "pub"));
    try std.testing.expect(!hasTerm(terms.items.items, "fn"));
}

test "adaptive budget scales by quality and range count" {
    try std.testing.expect(adaptiveBudget(6000, 95, 3) > adaptiveBudget(6000, 40, 3));
    try std.testing.expect(qualityEnough(80));
    try std.testing.expect(!qualityEnough(30));
}

fn hasTerm(terms: []const []u8, needle: []const u8) bool {
    for (terms) |term| {
        if (std.mem.eql(u8, term, needle)) return true;
    }
    return false;
}
