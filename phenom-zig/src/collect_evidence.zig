const std = @import("std");

const contracts = @import("contracts.zig");
const evidence = @import("evidence.zig");
const micro_context = @import("micro_context.zig");
const tools = @import("tools.zig");

pub const Args = struct {
    path: []const u8,
    strategy: contracts.StrategyName = .path,
    start_line: usize = 1,
    max_lines: usize = 12,
    budget_bytes: usize = 3800,
};

pub const Result = struct {
    strategy: contracts.StrategyName,
    context_id: []const u8,
    evidence_text: []u8,
    micro_context_text: []u8,
    raw_bytes_read: usize,
    model_bytes: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.context_id);
        allocator.free(self.evidence_text);
        allocator.free(self.micro_context_text);
    }
};

pub fn execute(allocator: std.mem.Allocator, args: Args) !Result {
    if (args.budget_bytes == 0) return error.InvalidEvidenceBudget;
    const strategy = contracts.resolveCollectEvidenceStrategy(args.strategy);
    if (strategy != .auto and strategy != .path) return error.StrategyNotImplemented;

    const range = try tools.readFileRange(allocator, args.path, args.start_line, args.max_lines, args.budget_bytes);
    defer range.deinit(allocator);

    const entry = try evidence.fromFileRangeBudgeted(allocator, range, args.budget_bytes);
    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    try packet.add(entry);

    const ctx = try micro_context.fromFileRange(allocator, range, "collect_evidence", args.budget_bytes);
    defer ctx.deinit(allocator);

    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);
    const micro_context_text = try ctx.render(allocator);
    errdefer allocator.free(micro_context_text);
    const context_id = try allocator.dupe(u8, ctx.id);
    errdefer allocator.free(context_id);

    return .{
        .strategy = if (strategy == .auto) .path else strategy,
        .context_id = context_id,
        .evidence_text = evidence_text,
        .micro_context_text = micro_context_text,
        .raw_bytes_read = range.text.len,
        .model_bytes = evidence_text.len + micro_context_text.len,
    };
}

test "collect evidence path returns budgeted evidence and micro context" {
    const result = try execute(std.testing.allocator, .{
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
    try std.testing.expect(result.model_bytes == result.evidence_text.len + result.micro_context_text.len);
}

test "collect evidence rejects unimplemented non path strategies explicitly" {
    try std.testing.expectError(error.StrategyNotImplemented, execute(std.testing.allocator, .{
        .path = "README.md",
        .strategy = .symbol,
    }));
}

test "collect evidence does not leak raw tail beyond budget" {
    const path = "collect_evidence_budget_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "alpha\nbeta\nSECRET_RAW_TAIL_SHOULD_NOT_LEAK\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try execute(std.testing.allocator, .{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 10,
        .budget_bytes = "alpha\nbeta\n".len,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "SECRET_RAW_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text, "SECRET_RAW_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[TRUNCATED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text, "[TRUNCATED]") != null);
}

test "collect evidence rejects zero budget" {
    try std.testing.expectError(error.InvalidEvidenceBudget, execute(std.testing.allocator, .{
        .path = "README.md",
        .budget_bytes = 0,
    }));
}
