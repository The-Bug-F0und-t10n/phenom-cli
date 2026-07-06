const std = @import("std");

const contracts = @import("contracts.zig");
const model_context = @import("model_context.zig");

pub const default_model_budget_limit: usize = 18 * 1024;
const min_remaining_budget: usize = 2200;
const max_anchor_bytes: usize = 260;
const max_active_evidence_bytes: usize = 12 * 1024;

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
        var blocks = try allocator.alloc(model_context.EvidenceBlock, self.entries.items.len);
        errdefer allocator.free(blocks);
        for (self.entries.items, 0..) |entry, i| {
            blocks[i] = .{ .text = entry.renderedText() };
        }
        return blocks;
    }

    pub fn renderedBytes(self: WorkingContext) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| total += entry.renderedBytes();
        return total;
    }

    pub fn remainingBudget(self: WorkingContext) usize {
        if (self.tool_budget_spent >= self.model_budget_limit) return 0;
        return self.model_budget_limit - self.tool_budget_spent;
    }

    pub fn hasBudgetForMoreEvidence(self: WorkingContext) bool {
        return self.remainingBudget() >= min_remaining_budget;
    }

    pub fn shouldAllowMoreEvidence(self: WorkingContext) bool {
        if (!self.hasBudgetForMoreEvidence()) return false;
        if (self.best_quality >= 82) return false;
        return true;
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
    defer std.testing.allocator.free(blocks);
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
    defer std.testing.allocator.free(blocks);

    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[EVIDENCE_ANCHOR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "full snippet text") == null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "README.md") != null);
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
    defer std.testing.allocator.free(blocks);
    try std.testing.expect(blocks[0].text.len < max_active_evidence_bytes + 64);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "[EVIDENCE_TRUNCATED]") != null);
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
