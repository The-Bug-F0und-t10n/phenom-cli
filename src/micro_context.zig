const std = @import("std");
const tools = @import("tools.zig");

pub const default_max_records = 200;

pub const MicroContext = struct {
    id: []const u8,
    path: []const u8,
    start_line: usize,
    end_line: usize,
    total_lines: usize,
    sha256: []const u8,
    source_tool: []const u8,
    budget_bytes: usize,
    excerpt: []const u8,
    truncated: bool,

    pub fn deinit(self: MicroContext, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.sha256);
        allocator.free(self.source_tool);
        allocator.free(self.excerpt);
    }

    pub fn render(self: MicroContext, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const header = try std.fmt.allocPrint(
            allocator,
            "[MICRO_CONTEXT id={s} path={s} lines={}-{} total_lines={} sha256={s} source_tool={s} budget_bytes={}]\n",
            .{ self.id, self.path, self.start_line, self.end_line, self.total_lines, self.sha256, self.source_tool, self.budget_bytes },
        );
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        try appendBudgeted(&out, allocator, self.excerpt, self.budget_bytes);
        if (self.truncated) try out.appendSlice(allocator, "\n[TRUNCATED]\n");
        if (!std.mem.endsWith(u8, out.items, "\n")) try out.append(allocator, '\n');
        return out.toOwnedSlice(allocator);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(MicroContext),
    max_records: usize = default_max_records,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .records = std.ArrayList(MicroContext).empty };
    }

    pub fn deinit(self: *Registry) void {
        for (self.records.items) |record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    pub fn remember(self: *Registry, context: MicroContext) !void {
        errdefer context.deinit(self.allocator);
        if (self.max_records == 0) return error.InvalidRegistryLimit;
        if (self.records.items.len >= self.max_records) {
            const oldest = self.records.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        try self.records.append(self.allocator, context);
    }

    pub fn find(self: *const Registry, id: []const u8) ?MicroContext {
        for (self.records.items) |record| {
            if (std.mem.eql(u8, record.id, id)) return record;
        }
        return null;
    }

    pub fn validateFresh(self: *const Registry, allocator: std.mem.Allocator, id: []const u8) !void {
        const record = self.find(id) orelse return error.MicroContextNotFound;
        const max_lines = record.end_line - record.start_line + 1;
        const fresh = try tools.readFileRange(allocator, record.path, record.start_line, max_lines, record.budget_bytes);
        defer fresh.deinit(allocator);
        const fresh_context = try fromFileRange(allocator, fresh, record.source_tool, record.budget_bytes);
        defer fresh_context.deinit(allocator);
        if (!std.mem.eql(u8, record.sha256, fresh_context.sha256)) return error.StaleMicroContext;
    }
};

pub fn fromFileRange(
    allocator: std.mem.Allocator,
    range: tools.FileRange,
    source_tool: []const u8,
    budget_bytes: usize,
) !MicroContext {
    const normalized = try normalizeForHash(allocator, range.text);
    defer allocator.free(normalized);
    const digest = try sha256HexAlloc(allocator, normalized);
    errdefer allocator.free(digest);
    const id = try makeId(allocator, range.path, range.start_line, range.end_line, normalized);
    errdefer allocator.free(id);
    const excerpt = try budgetedDup(allocator, range.text, budget_bytes);
    errdefer allocator.free(excerpt);
    const path = try allocator.dupe(u8, range.path);
    errdefer allocator.free(path);
    const tool = try allocator.dupe(u8, source_tool);
    errdefer allocator.free(tool);
    return .{
        .id = id,
        .path = path,
        .start_line = range.start_line,
        .end_line = range.end_line,
        .total_lines = range.total_lines,
        .sha256 = digest,
        .source_tool = tool,
        .budget_bytes = budget_bytes,
        .excerpt = excerpt,
        .truncated = range.text.len > budget_bytes,
    };
}

fn makeId(allocator: std.mem.Allocator, path: []const u8, start_line: usize, end_line: usize, text: []const u8) ![]u8 {
    const seed = try std.fmt.allocPrint(allocator, "{s}:{}:{}:{s}", .{ path, start_line, end_line, text });
    defer allocator.free(seed);
    const digest = try sha256HexAlloc(allocator, seed);
    defer allocator.free(digest);
    return std.fmt.allocPrint(allocator, "ctx_{s}", .{digest[0..16]});
}

fn sha256HexAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn normalizeForHash(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') continue;
            try out.append(allocator, '\n');
            continue;
        }
        try out.append(allocator, text[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn budgetedDup(allocator: std.mem.Allocator, text: []const u8, budget_bytes: usize) ![]u8 {
    const n = @min(text.len, budget_bytes);
    return allocator.dupe(u8, text[0..n]);
}

fn appendBudgeted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, budget_bytes: usize) !void {
    const n = @min(text.len, budget_bytes);
    try out.appendSlice(allocator, text[0..n]);
    if (text.len > n) try out.appendSlice(allocator, "\n[TRUNCATED]\n");
}

test "micro context renders id sha path range source and budgeted excerpt" {
    const range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "README.md"),
        .start_line = 1,
        .end_line = 2,
        .total_lines = 3,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "alpha\nbeta\ngamma\n"),
    };
    defer range.deinit(std.testing.allocator);
    const ctx = try fromFileRange(std.testing.allocator, range, "read_file_range", 11);
    defer ctx.deinit(std.testing.allocator);
    const rendered = try ctx.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, ctx.id, "ctx_"));
    try std.testing.expectEqual(@as(usize, 64), ctx.sha256.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source_tool=read_file_range") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha\nbeta") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "gamma") == null);
}

test "micro context registry evicts oldest and finds fresh records" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.max_records = 1;

    const first_range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "a.zig"),
        .start_line = 1,
        .end_line = 1,
        .total_lines = 1,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "one\n"),
    };
    defer first_range.deinit(std.testing.allocator);
    const first = try fromFileRange(std.testing.allocator, first_range, "read_file_range", 128);
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    try registry.remember(first);

    const second_range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "b.zig"),
        .start_line = 1,
        .end_line = 1,
        .total_lines = 1,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "two\n"),
    };
    defer second_range.deinit(std.testing.allocator);
    const second = try fromFileRange(std.testing.allocator, second_range, "read_file_range", 128);
    const second_id = try std.testing.allocator.dupe(u8, second.id);
    defer std.testing.allocator.free(second_id);
    try registry.remember(second);

    try std.testing.expect(registry.find(first_id) == null);
    try std.testing.expect(registry.find(second_id) != null);
}

test "micro context detects stale file range" {
    const path = "micro_context_stale_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\ntwo\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 2, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try fromFileRange(std.testing.allocator, range, "read_file_range", 1024);
    const id = try std.testing.allocator.dupe(u8, ctx.id);
    defer std.testing.allocator.free(id);
    try registry.remember(ctx);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\nchanged\n" });
    try std.testing.expectError(error.StaleMicroContext, registry.validateFresh(std.testing.allocator, id));
}
