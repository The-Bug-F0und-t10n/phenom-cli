const std = @import("std");

const contracts = @import("contracts.zig");

pub const CandidateSource = enum {
    prompt_path,
    rg,
    fallback_scan,
};

pub const RankBudget = struct {
    max_candidates: usize = 16,
    max_ranges: usize = 4,
    max_lines_per_range: usize = 80,
    window_before: usize = 12,
    window_after: usize = 24,
    max_rg_bytes: usize = 96 * 1024,
};

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
        if (isStopWord(cleaned)) return;
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
    for (terms.items.items) |term| {
        if (candidates.items.len >= budget.max_candidates) break;
        collectRgCandidates(allocator, io, &candidates, term, strategy, budget) catch |err| switch (err) {
            error.RgUnavailable => {
                rg_available = false;
                try collectFallbackCandidates(allocator, io, &candidates, term, strategy, budget);
            },
            else => return err,
        };
        rg_invocations += 1;
    }

    if (candidates.items.len == 0) {
        try addPromptPathCandidates(allocator, &candidates, prompt, strategy, budget);
    }

    sortCandidates(candidates.items);
    var merged = try mergeCandidates(allocator, candidates.items, budget);
    freeCandidates(allocator, &candidates);
    sortCandidates(merged.items);
    trimCandidates(allocator, &merged, budget.max_ranges);

    const audit = try renderAudit(allocator, merged.items, terms.items.items, strategy, rg_invocations, rg_available);
    errdefer allocator.free(audit);
    return .{
        .candidates = merged,
        .audit_text = audit,
        .rg_invocations = rg_invocations,
        .rg_available = rg_available,
    };
}

fn extractTerms(out: *TermList, prompt: []const u8, strategy: contracts.StrategyName) !void {
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>:;,");
    while (it.next()) |raw| {
        try out.add(raw);
        if (std.mem.indexOfScalar(u8, raw, '_') == null and raw.len >= 4) {
            var snake_buf: [128]u8 = undefined;
            const snake = makeSnake(raw, &snake_buf);
            try out.add(snake);
        }
    }

    if (std.mem.indexOf(u8, prompt, "tool loop") != null) try out.add("tool_loop");
    if (std.mem.indexOf(u8, prompt, "tool call") != null) try out.add("tool_call");
    if (std.mem.indexOf(u8, prompt, "collect evidence") != null) try out.add("collect_evidence");

    switch (strategy) {
        .diagnostic => {
            try out.add("error");
            try out.add("fail");
            try out.add("diagnostic");
        },
        .runtime => {
            try out.add("audit");
            try out.add("recordEvent");
            try out.add("tool_event");
        },
        .diff => {
            try out.add("diff");
            try out.add("patch");
        },
        .symbol => {
            try out.add("pub");
            try out.add("fn");
        },
        else => {},
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
        "--glob",
        "!{.git,zig-cache,zig-out,node_modules,bin}/**",
        term,
        ".",
    };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(budget.max_rg_bytes),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.RgUnavailable,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (out.items.len >= budget.max_candidates) break;
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
    if (skipPath(raw_path)) return;
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
    var cwd = std.Io.Dir.cwd();
    var walker = try cwd.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (out.items.len >= budget.max_candidates) break;
        if (entry.kind != .file) continue;
        if (skipPath(entry.path)) continue;
        if (!looksLikeTextCode(entry.path)) continue;
        const content = cwd.readFileAlloc(io, entry.path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);
        if (std.mem.indexOf(u8, content, term)) |idx| {
            const line_no = lineNumberAt(content, idx);
            const start = if (line_no > budget.window_before) line_no - budget.window_before else 1;
            const reasons = try allocator.dupe(u8, "fallback_scan,exact_term_match");
            errdefer allocator.free(reasons);
            try out.append(allocator, .{
                .path = try allocator.dupe(u8, entry.path),
                .start_line = start,
                .end_line = @min(line_no + budget.window_after, start + budget.max_lines_per_range - 1),
                .score = 35 + strategyBonus(strategy),
                .source = .fallback_scan,
                .reasons = reasons,
            });
        }
    }
}

fn addPromptPathCandidates(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(EvidenceCandidate),
    prompt: []const u8,
    strategy: contracts.StrategyName,
    budget: RankBudget,
) !void {
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>:;,");
    while (it.next()) |raw| {
        if (!looksLikePath(raw) or skipPath(raw)) continue;
        const reasons = try allocator.dupe(u8, "prompt_path_match");
        errdefer allocator.free(reasons);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, raw),
            .start_line = 1,
            .end_line = budget.max_lines_per_range,
            .score = 55 + strategyBonus(strategy),
            .source = .prompt_path,
            .reasons = reasons,
        });
    }
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
            existing.start_line = @min(existing.start_line, candidate.start_line);
            existing.end_line = @min(@max(existing.end_line, candidate.end_line), existing.start_line + budget.max_lines_per_range - 1);
            existing.score = @max(existing.score, candidate.score) + 4;
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

pub fn adaptiveBudget(total_budget: usize, quality_score: i32, range_count: usize) usize {
    if (range_count == 0) return total_budget;
    const quality_factor: usize = if (quality_score >= 90) 3 else if (quality_score >= 65) 2 else 1;
    const per_range = @max(@as(usize, 512), total_budget / range_count);
    return @min(total_budget, per_range * quality_factor);
}

pub fn qualityEnough(score: i32) bool {
    return score >= 64;
}

fn scoreMatch(path: []const u8, text: []const u8, term: []const u8, strategy: contracts.StrategyName) i32 {
    var score: i32 = 20 + strategyBonus(strategy);
    if (containsIgnoreCase(text, term)) score += 35;
    if (containsIgnoreCase(path, term)) score += 18;
    if (looksLikeDefinition(text, term)) score += 30;
    if (std.mem.endsWith(u8, path, ".zig")) score += 8;
    if (containsIgnoreCase(path, term)) score += 22;
    if (containsIgnoreCase(path, "test") or std.mem.indexOf(u8, text, "test \"") != null) score -= 25;
    if (skipPath(path)) score -= 80;
    return score;
}

fn strategyBonus(strategy: contracts.StrategyName) i32 {
    return switch (strategy) {
        .symbol => 12,
        .semantic => 10,
        .diagnostic, .runtime, .diff => 8,
        .lexical, .auto => 6,
        else => 0,
    };
}

fn reasonText(allocator: std.mem.Allocator, path: []const u8, text: []const u8, term: []const u8, strategy: contracts.StrategyName) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "rg");
    if (containsIgnoreCase(text, term)) try out.appendSlice(allocator, ",exact_term_match");
    if (containsIgnoreCase(path, term)) try out.appendSlice(allocator, ",path_match");
    if (looksLikeDefinition(text, term)) try out.appendSlice(allocator, ",symbol_definition_match");
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
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const header = try std.fmt.allocPrint(
        allocator,
        "[CANDIDATE_RANKING]\nstrategy={s}\nrg_invocations={}\nrg_available={}\nterms={}\n",
        .{ @tagName(strategy), rg_invocations, rg_available, terms.len },
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
            if (a.score != b.score) return a.score > b.score;
            if (!std.mem.eql(u8, a.path, b.path)) return std.mem.lessThan(u8, a.path, b.path);
            return a.start_line < b.start_line;
        }
    }.lessThan);
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
    while (candidates.items.len > max) {
        const removed = candidates.pop().?;
        removed.deinit(allocator);
    }
}

fn rangesTouch(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
    return a_start <= b_end + 1 and b_start <= a_end + 1;
}

fn normalizeRgPath(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

fn skipPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, ".git/") != null or
        std.mem.indexOf(u8, path, "zig-cache/") != null or
        std.mem.indexOf(u8, path, "zig-out/") != null or
        std.mem.indexOf(u8, path, "node_modules/") != null or
        std.mem.indexOf(u8, path, "/bin/") != null or
        std.mem.startsWith(u8, path, "bin/");
}

fn looksLikePath(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '/') != null or
        std.mem.endsWith(u8, text, ".zig") or
        std.mem.endsWith(u8, text, ".ts") or
        std.mem.endsWith(u8, text, ".md");
}

fn looksLikeTextCode(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".json") or
        std.mem.endsWith(u8, path, ".toml");
}

fn looksLikeDefinition(text: []const u8, term: []const u8) bool {
    return (std.mem.indexOf(u8, text, "fn ") != null or std.mem.indexOf(u8, text, "const ") != null or std.mem.indexOf(u8, text, "pub const ") != null) and
        containsIgnoreCase(text, term);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn cleanTerm(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n\"'`()[]{}<>:;,.!?");
}

fn isStopWord(term: []const u8) bool {
    const words = [_][]const u8{
        "use",
        "com",
        "sem",
        "para",
        "por",
        "que",
        "uma",
        "sobre",
        "achar",
        "depois",
        "responda",
        "exatamente",
        "evidencia",
        "evidência",
        "strategy",
        "path",
        "auto",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(term, word)) return true;
    }
    return false;
}

fn makeSnake(raw: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (raw) |byte| {
        if (n >= buf.len) break;
        buf[n] = if (byte == '-' or byte == ' ') '_' else std.ascii.toLower(byte);
        n += 1;
    }
    return buf[0..n];
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

test "ranking with rg finds collect evidence implementation without raw output audit" {
    var ranked = try rankForPrompt(std.testing.allocator, std.testing.io, "collect_evidence execute", .lexical, .{ .max_ranges = 3 });
    defer ranked.deinit(std.testing.allocator);
    try std.testing.expect(ranked.candidates.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "[CANDIDATE_RANKING]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "rg_invocations=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.audit_text, "---BEGIN CONTENT---") == null);
}

test "adaptive budget scales by quality and range count" {
    try std.testing.expect(adaptiveBudget(6000, 95, 3) > adaptiveBudget(6000, 40, 3));
    try std.testing.expect(qualityEnough(80));
    try std.testing.expect(!qualityEnough(30));
}
