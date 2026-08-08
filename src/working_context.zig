const std = @import("std");

const contracts = @import("contracts.zig");
const model_context = @import("model_context.zig");
const web_evidence_model = @import("web_evidence_model.zig");

pub const default_model_budget_limit: usize = 18 * 1024;
const min_remaining_budget: usize = 2200;
const max_anchor_bytes: usize = 260;
const max_active_evidence_bytes: usize = 4 * 1024;

pub const RememberArgs = struct {
    path: ?[]const u8 = null,
    terms: ?[]const u8 = null,
    strategy: contracts.StrategyName,
    start_line: usize,
    max_lines: usize,
    context_id: ?[]const u8 = null,
    evidence_text: []const u8,
    model_bytes: usize,
    quality_score: i32,
};

pub const WorkingEvidence = struct {
    id: []u8,
    path: []u8,
    terms: []u8,
    strategy: contracts.StrategyName,
    start_line: usize,
    max_lines: usize,
    context_id: []u8,
    evidence_text: []u8,
    anchor_text: []u8,
    model_bytes: usize,
    quality_score: i32,
    stale: bool = false,
    compacted: bool = false,

    fn deinit(self: WorkingEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.terms);
        allocator.free(self.context_id);
        allocator.free(self.evidence_text);
        allocator.free(self.anchor_text);
    }

    fn renderedText(self: WorkingEvidence) []const u8 {
        if (self.compacted or self.stale) return self.anchor_text;
        return self.evidence_text;
    }

    fn renderedBytes(self: WorkingEvidence) usize {
        return self.renderedText().len;
    }

    fn matches(self: WorkingEvidence, args: RememberArgs) bool {
        return std.mem.eql(u8, self.path, args.path orelse "<auto>") and
            std.mem.eql(u8, self.terms, args.terms orelse "") and
            self.strategy == args.strategy and
            self.start_line == args.start_line and
            self.max_lines == args.max_lines;
    }
};

pub const WorkingContext = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(WorkingEvidence),
    model_budget_limit: usize = default_model_budget_limit,
    tool_budget_spent: usize = 0,
    best_quality: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) WorkingContext {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(WorkingEvidence).empty,
        };
    }

    pub fn deinit(self: *WorkingContext) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn hasDuplicate(self: WorkingContext, args: RememberArgs) bool {
        for (self.entries.items) |entry| {
            if (entry.matches(args)) return true;
        }
        return false;
    }

    pub fn remember(self: *WorkingContext, args: RememberArgs) !void {
        if (self.hasDuplicate(args)) return error.DuplicateWorkingEvidence;
        const id = try std.fmt.allocPrint(self.allocator, "E{}", .{self.entries.items.len + 1});
        errdefer self.allocator.free(id);
        const path = try self.allocator.dupe(u8, args.path orelse "<auto>");
        errdefer self.allocator.free(path);
        const terms = try self.allocator.dupe(u8, args.terms orelse "");
        errdefer self.allocator.free(terms);
        const context_id = try self.allocator.dupe(u8, args.context_id orelse "");
        errdefer self.allocator.free(context_id);
        const evidence_text = try dupModelVisibleEvidence(self.allocator, args.evidence_text);
        errdefer self.allocator.free(evidence_text);
        try model_context.assertNoRawContextLeak(evidence_text);
        const anchor_text = try renderAnchor(self.allocator, id, path, terms, args.strategy, args.start_line, args.max_lines, context_id, evidence_text, args.quality_score);
        errdefer self.allocator.free(anchor_text);
        try model_context.assertNoRawContextLeak(anchor_text);

        try self.entries.append(self.allocator, .{
            .id = id,
            .path = path,
            .terms = terms,
            .strategy = args.strategy,
            .start_line = args.start_line,
            .max_lines = args.max_lines,
            .context_id = context_id,
            .evidence_text = evidence_text,
            .anchor_text = anchor_text,
            .model_bytes = args.model_bytes,
            .quality_score = args.quality_score,
        });
        self.tool_budget_spent = std.math.add(usize, self.tool_budget_spent, args.model_bytes) catch std.math.maxInt(usize);
        self.best_quality = @max(self.best_quality, args.quality_score);
        self.compactToBudget();
    }

    pub fn compactAll(self: *WorkingContext) void {
        for (self.entries.items) |*entry| entry.compacted = true;
    }

    pub fn renderEvidenceBlocks(self: WorkingContext, allocator: std.mem.Allocator) ![]model_context.EvidenceBlock {
        var non_web_count: usize = 0;
        var web_count: usize = 0;
        for (self.entries.items) |entry| {
            if (isWebEvidence(entry.renderedText())) {
                web_count += countWebEvidenceUnits(entry.renderedText());
            } else {
                non_web_count += 1;
            }
        }
        const block_count = non_web_count + if (web_count > 0) @as(usize, 1) else 0;
        var blocks = try allocator.alloc(model_context.EvidenceBlock, block_count);
        errdefer allocator.free(blocks);
        var index: usize = 0;
        for (self.entries.items) |entry| {
            if (isWebEvidence(entry.renderedText())) continue;
            blocks[index] = .{ .text = entry.renderedText() };
            index += 1;
        }
        if (web_count > 0) {
            blocks[index] = .{ .text = try self.renderWebDossier(allocator, web_count) };
        }
        return blocks;
    }

    pub fn freeRenderedEvidenceBlocks(allocator: std.mem.Allocator, blocks: []model_context.EvidenceBlock) void {
        for (blocks) |block| {
            if (std.mem.startsWith(u8, block.text, "[WEB_DOSSIER v1]")) allocator.free(@constCast(block.text));
        }
        allocator.free(blocks);
    }

    fn renderWebDossier(self: WorkingContext, allocator: std.mem.Allocator, web_count: usize) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "[WEB_DOSSIER v1]\n");
        try appendLine(&out, allocator, "fetches", try std.fmt.allocPrint(allocator, "{}", .{web_count}));
        try out.appendSlice(allocator, "rule=Use only quoted excerpt/source_url lines as factual support; gaps are evidence of insufficiency, not facts.\n");
        var idx: usize = 0;
        var gaps = std.ArrayList(u8).empty;
        defer gaps.deinit(allocator);
        for (self.entries.items) |entry| {
            const text = entry.renderedText();
            if (!isWebEvidence(text)) continue;
            var cursor: usize = 0;
            var rendered_block = false;
            while (nextWebEvidenceBlock(text, &cursor)) |block| {
                rendered_block = true;
                idx += 1;
                try appendWebDossierEntry(&out, &gaps, allocator, idx, entry, block);
            }
            if (!rendered_block) {
                idx += 1;
                try appendWebDossierEntry(&out, &gaps, allocator, idx, entry, text);
            }
        }
        if (gaps.items.len > 0) {
            try out.appendSlice(allocator, "GAPS:\n");
            try out.appendSlice(allocator, gaps.items);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn renderedBytes(self: WorkingContext) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| total += entry.renderedBytes();
        return total;
    }

    pub fn remainingBudget(self: WorkingContext) usize {
        const rendered = self.renderedBytes();
        if (rendered >= self.model_budget_limit) return 0;
        return self.model_budget_limit - rendered;
    }

    pub fn hasBudgetForMoreEvidence(self: WorkingContext) bool {
        return self.remainingBudget() >= min_remaining_budget;
    }

    pub fn shouldAllowMoreEvidence(self: WorkingContext) bool {
        return self.hasBudgetForMoreEvidence();
    }

    pub fn findByContextId(self: WorkingContext, context_id: []const u8) ?WorkingEvidence {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.context_id, context_id)) return entry;
        }
        return null;
    }

    fn compactToBudget(self: *WorkingContext) void {
        while (self.renderedBytes() > self.model_budget_limit) {
            var changed = false;
            if (self.entries.items.len == 0) return;
            const keep_latest = self.entries.items.len - 1;
            for (self.entries.items, 0..) |*entry, i| {
                if (i == keep_latest) continue;
                if (!entry.compacted) {
                    entry.compacted = true;
                    changed = true;
                    break;
                }
            }
            if (!changed) break;
        }
    }
};

fn isWebEvidence(text: []const u8) bool {
    return web_evidence_model.hasEvidence(text) or
        std.mem.indexOf(u8, text, "[WEB_DOSSIER v1]") != null;
}

fn countWebEvidenceUnits(text: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (nextWebEvidenceBlock(text, &cursor) != null) count += 1;
    if (count == 0 and std.mem.indexOf(u8, text, "[WEB_DOSSIER v1]") != null) return 1;
    return count;
}

fn nextWebEvidenceBlock(text: []const u8, cursor: *usize) ?[]const u8 {
    const marker = "[WEB_EVIDENCE]";
    const start = std.mem.indexOfPos(u8, text, cursor.*, marker) orelse return null;
    const body_start = start + marker.len;
    const end = std.mem.indexOfPos(u8, text, body_start, marker) orelse text.len;
    cursor.* = end;
    return text[start..end];
}

fn appendWebDossierEntry(
    out: *std.ArrayList(u8),
    gaps: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    idx: usize,
    entry: WorkingEvidence,
    text: []const u8,
) !void {
    const label = try std.fmt.allocPrint(allocator, "W{}:\n", .{idx});
    defer allocator.free(label);
    try out.appendSlice(allocator, label);
    if (web_evidence_model.parseFirst(text)) |web| {
        try appendParsedWebDossierEntry(out, gaps, allocator, idx, entry, web);
    } else {
        try appendLegacyWebDossierEntry(out, gaps, allocator, idx, entry, text);
    }
}

fn appendParsedWebDossierEntry(
    out: *std.ArrayList(u8),
    gaps: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    idx: usize,
    entry: WorkingEvidence,
    web: web_evidence_model.ParsedEvidenceEntry,
) !void {
    if (web.target.len > 0) {
        try appendKV(out, allocator, "target", web.target, 360);
    } else {
        try appendKV(out, allocator, "target", entry.path, 360);
    }
    if (web.query.len > 0) {
        try appendKV(out, allocator, "query", web.query, 240);
    } else if (entry.terms.len > 0) {
        try appendKV(out, allocator, "query", entry.terms, 240);
    }
    try appendIntKV(out, allocator, "quality", entry.quality_score);
    if (web.status.len > 0) try appendKV(out, allocator, "status", web.status, 40);
    if (web.source_domain.len > 0) try appendKV(out, allocator, "source_domain", web.source_domain, 120);
    var sources = web.sourceIterator();
    while (sources.next()) |source| {
        try appendKV(out, allocator, "source_url", source.url, 360);
    }
    if (web.title.len > 0) try appendKV(out, allocator, "title", web.title, 240);
    if (web.excerpt) |excerpt| {
        const trimmed = std.mem.trim(u8, excerpt, " \t\r\n");
        if (trimmed.len > 0) {
            try appendKV(out, allocator, "excerpt", trimmed, 700);
        } else {
            try appendGap(gaps, allocator, idx, "empty_excerpt");
        }
    } else {
        try appendGap(gaps, allocator, idx, "missing_excerpt");
    }
}

fn appendLegacyWebDossierEntry(
    out: *std.ArrayList(u8),
    gaps: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    idx: usize,
    entry: WorkingEvidence,
    text: []const u8,
) !void {
    if (webFieldValue(text, "target")) |target| {
        try appendKV(out, allocator, "target", target, 360);
    } else {
        try appendKV(out, allocator, "target", entry.path, 360);
    }
    if (webFieldValue(text, "query")) |query| {
        try appendKV(out, allocator, "query", query, 240);
    } else if (entry.terms.len > 0) {
        try appendKV(out, allocator, "query", entry.terms, 240);
    }
    try appendIntKV(out, allocator, "quality", entry.quality_score);
    try appendWebField(out, allocator, text, "status", 40);
    try appendWebField(out, allocator, text, "source_domain", 120);
    try appendWebField(out, allocator, text, "source_url", 360);
    try appendWebField(out, allocator, text, "title", 240);
    if (webFieldValue(text, "excerpt")) |excerpt| {
        const trimmed = std.mem.trim(u8, excerpt, " \t\r\n");
        if (trimmed.len > 0) {
            try appendKV(out, allocator, "excerpt", trimmed, 700);
        } else {
            try appendGap(gaps, allocator, idx, "empty_excerpt");
        }
    } else {
        try appendGap(gaps, allocator, idx, "missing_excerpt");
    }
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    defer allocator.free(value);
    try out.appendSlice(allocator, key);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, value);
    try out.append(allocator, '\n');
}

fn appendIntKV(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: i32) !void {
    const text = try std.fmt.allocPrint(allocator, "{}", .{value});
    defer allocator.free(text);
    try appendKV(out, allocator, key, text, 32);
}

fn appendKV(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, max_bytes: usize) !void {
    try out.appendSlice(allocator, key);
    try out.append(allocator, '=');
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    try appendClippedOneLine(out, allocator, trimmed, max_bytes);
    try out.append(allocator, '\n');
}

fn appendWebField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, key: []const u8, max_bytes: usize) !void {
    if (webFieldValue(text, key)) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) try appendKV(out, allocator, key, trimmed, max_bytes);
    }
}

fn appendGap(out: *std.ArrayList(u8), allocator: std.mem.Allocator, index: usize, reason: []const u8) !void {
    const line = try std.fmt.allocPrint(allocator, "- W{} {s}\n", .{ index, reason });
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn webFieldValue(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len < key.len + 1) continue;
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        if (trimmed[key.len] != '=') continue;
        return trimmed[key.len + 1 ..];
    }
    return null;
}

fn appendClippedOneLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) !void {
    var written: usize = 0;
    var last_space = false;
    for (text) |byte| {
        if (written >= max_bytes) break;
        const normalized: u8 = switch (byte) {
            '\n', '\r', '\t' => ' ',
            else => byte,
        };
        if (normalized == ' ') {
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
        }
        try out.append(allocator, normalized);
        written += 1;
    }
}

fn renderAnchor(
    allocator: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    terms: []const u8,
    strategy: contracts.StrategyName,
    start_line: usize,
    max_lines: usize,
    context_id: []const u8,
    evidence_text: []const u8,
    quality_score: i32,
) ![]u8 {
    const summary = firstUsefulLine(evidence_text);
    const clipped_summary = summary[0..@min(summary.len, max_anchor_bytes)];
    return std.fmt.allocPrint(
        allocator,
        "[EVIDENCE_ANCHOR]\nid={s} path={s} terms={s} strategy={s} range={}-{} context_id={s} quality={} summary={s}",
        .{ id, path, terms, @tagName(strategy), start_line, start_line + max_lines - 1, context_id, quality_score, clipped_summary },
    );
}

fn firstUsefulLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "[EVIDENCE]")) continue;
        return trimmed;
    }
    return "no evidence summary";
}

fn dupModelVisibleEvidence(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= max_active_evidence_bytes) return allocator.dupe(u8, text);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..max_active_evidence_bytes]);
    try out.appendSlice(allocator, "\n[EVIDENCE_TRUNCATED]\n");
    return out.toOwnedSlice(allocator);
}

test "working context stores different model-directed evidence and blocks duplicate" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.remember(.{
        .terms = "render context",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_a",
        .evidence_text = "[EVIDENCE]\n- src/a.zig L1-L2 hash=a\nrender context\n",
        .model_bytes = 120,
        .quality_score = 40,
    });
    try ctx.remember(.{
        .terms = "collect evidence",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_b",
        .evidence_text = "[EVIDENCE]\n- src/b.zig L3-L4 hash=b\ncollect evidence\n",
        .model_bytes = 130,
        .quality_score = 50,
    });
    try std.testing.expectError(error.DuplicateWorkingEvidence, ctx.remember(.{
        .terms = "collect evidence",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_b",
        .evidence_text = "[EVIDENCE]\n- duplicate\n",
        .model_bytes = 50,
        .quality_score = 1,
    }));

    try std.testing.expectEqual(@as(usize, 2), ctx.entries.items.len);
}

test "working context compacts old full evidence into anchor" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.model_budget_limit = 280;

    try ctx.remember(.{
        .terms = "first",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_first",
        .evidence_text = "[EVIDENCE]\n- first.zig L1-L2 hash=a\n" ++ "x" ** 420,
        .model_bytes = 420,
        .quality_score = 10,
    });
    try ctx.remember(.{
        .terms = "second",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_second",
        .evidence_text = "[EVIDENCE]\n- second.zig L1-L2 hash=b\nshort\n",
        .model_bytes = 80,
        .quality_score = 20,
    });

    const blocks = try ctx.renderEvidenceBlocks(std.testing.allocator);
    defer WorkingContext.freeRenderedEvidenceBlocks(std.testing.allocator, blocks);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[EVIDENCE_ANCHOR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "x" ** 200) == null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[1].text, "second.zig") != null);
}

test "working context compact all removes full snippets from model visible blocks" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.remember(.{
        .path = "README.md",
        .strategy = .path,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_readme",
        .evidence_text = "[EVIDENCE]\n- README.md L1-L12 hash=abc\nfull snippet text\n",
        .model_bytes = 120,
        .quality_score = 72,
    });
    ctx.compactAll();
    const blocks = try ctx.renderEvidenceBlocks(std.testing.allocator);
    defer WorkingContext.freeRenderedEvidenceBlocks(std.testing.allocator, blocks);

    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[EVIDENCE_ANCHOR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "full snippet text") == null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "README.md") != null);
}

test "working context permits refinement by budget not ranking score" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.remember(.{
        .terms = "renderer",
        .strategy = .symbol,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_symbol",
        .evidence_text = "[EVIDENCE]\n- build.zig L1-L12 hash=abc\npub fn build() void {}\n",
        .model_bytes = 128,
        .quality_score = 116,
    });

    try std.testing.expect(ctx.shouldAllowMoreEvidence());
}

test "working context caps oversized active evidence before model rendering" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.remember(.{
        .terms = "large",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .context_id = "ctx_large",
        .evidence_text = "[EVIDENCE]\n- huge.zig L1-L12 hash=abc\n" ++ "x" ** (max_active_evidence_bytes + 2048),
        .model_bytes = max_active_evidence_bytes + 2048,
        .quality_score = 30,
    });
    const blocks = try ctx.renderEvidenceBlocks(std.testing.allocator);
    defer WorkingContext.freeRenderedEvidenceBlocks(std.testing.allocator, blocks);
    try std.testing.expect(blocks[0].text.len < max_active_evidence_bytes + 64);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[EVIDENCE_TRUNCATED]") != null);
}

test "working context remaining budget uses rendered compacted bytes" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.model_budget_limit = 5000;

    try ctx.remember(.{
        .path = "large.zig",
        .terms = "large",
        .strategy = .path,
        .start_line = 1,
        .max_lines = 1,
        .context_id = "ctx_large",
        .evidence_text = "x" ** 10000,
        .model_bytes = 10000,
        .quality_score = 20,
    });
    ctx.compactAll();

    try std.testing.expect(ctx.tool_budget_spent > ctx.model_budget_limit);
    try std.testing.expect(ctx.renderedBytes() < ctx.model_budget_limit);
    try std.testing.expect(ctx.remainingBudget() > 0);
    try std.testing.expect(ctx.shouldAllowMoreEvidence());
}

test "working context rejects raw model leak markers" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectError(error.RawContextLeak, ctx.remember(.{
        .terms = "raw",
        .strategy = .auto,
        .start_line = 1,
        .max_lines = 12,
        .evidence_text = "[EVIDENCE]\n---BEGIN CONTENT---\nsecret\n",
        .model_bytes = 50,
        .quality_score = 1,
    }));
}

test "working context consolidates web evidence into dossier with gaps" {
    var ctx = WorkingContext.init(std.testing.allocator);
    defer ctx.deinit();

    const fanout_packet =
        \\[EVIDENCE]
        \\E1:
        \\  [WEB_EVIDENCE]
        \\  status=200
        \\  query=R36S specs broad
        \\  source_url=https://search.test/weak
        \\  title=No Direct Support
        \\  source_domain=search.test
        \\  excerpt=No Direct Support.
        \\E2:
        \\  [WEB_EVIDENCE]
        \\  status=200
        \\  query=R36S specs short
        \\  source_url=https://search.test/strong
        \\  title=R36S Fanout Specs
        \\  source_domain=search.test
        \\  excerpt=R36S usa RK3326 e 1GB RAM.
    ;
    try ctx.remember(.{
        .path = "web_fanout:https://search.test/?q=r36s",
        .terms = "R36S specs",
        .strategy = .document_summary,
        .start_line = 1,
        .max_lines = 1,
        .context_id = "web_fanout",
        .evidence_text = fanout_packet,
        .model_bytes = fanout_packet.len,
        .quality_score = 88,
    });
    try ctx.remember(.{
        .path = "https://search.test/?q=r36s",
        .terms = "R36S specs",
        .strategy = .document_summary,
        .start_line = 1,
        .max_lines = 1,
        .context_id = "web_a",
        .evidence_text = "[WEB_EVIDENCE]\nstatus=200\nquery=R36S specs\nsource_url=https://example.test/r36s\ntitle=R36S specs\nsource_domain=example.test\nexcerpt=R36S usa RK3326 e 1GB RAM.\n",
        .model_bytes = 180,
        .quality_score = 88,
    });
    try ctx.remember(.{
        .path = "https://empty.test/",
        .terms = "R36S specs",
        .strategy = .document_summary,
        .start_line = 1,
        .max_lines = 1,
        .context_id = "web_b",
        .evidence_text = "[WEB_EVIDENCE]\nstatus=200\nsource_url=https://empty.test/\nexcerpt=\n",
        .model_bytes = 80,
        .quality_score = 20,
    });

    const blocks = try ctx.renderEvidenceBlocks(std.testing.allocator);
    defer WorkingContext.freeRenderedEvidenceBlocks(std.testing.allocator, blocks);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[WEB_DOSSIER v1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "fetches=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[WEB_EVIDENCE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "W2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "source_url=https://search.test/strong") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "source_url=https://example.test/r36s") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "excerpt=R36S usa RK3326 e 1GB RAM.") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "GAPS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "- W4 empty_excerpt") != null);
}
