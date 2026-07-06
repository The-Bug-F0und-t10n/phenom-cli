const std = @import("std");
const tools = @import("tools.zig");

pub const EvidenceEntry = struct {
    source: []const u8,
    kind: []const u8,
    range: []const u8,
    hash: u64,
    excerpt: []const u8,

    pub fn deinit(self: EvidenceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.kind);
        allocator.free(self.range);
        allocator.free(self.excerpt);
    }
};

pub const EvidencePacket = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(EvidenceEntry),

    pub fn init(allocator: std.mem.Allocator) EvidencePacket {
        return .{ .allocator = allocator, .entries = std.ArrayList(EvidenceEntry).empty };
    }

    pub fn deinit(self: *EvidencePacket) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *EvidencePacket, entry: EvidenceEntry) !void {
        errdefer entry.deinit(self.allocator);
        try self.entries.append(self.allocator, entry);
    }

    pub fn render(self: *EvidencePacket, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "[EVIDENCE]\n");
        for (self.entries.items) |entry| {
            const line = try std.fmt.allocPrint(allocator, "- {s} {s} hash={x}\n", .{ entry.source, entry.range, entry.hash });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
            try out.appendSlice(allocator, entry.excerpt);
            if (!std.mem.endsWith(u8, entry.excerpt, "\n")) try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn fromFileRange(allocator: std.mem.Allocator, range: tools.FileRange) !EvidenceEntry {
    return fromFileRangeBudgeted(allocator, range, range.text.len);
}

pub fn fromFileRangeBudgeted(allocator: std.mem.Allocator, range: tools.FileRange, max_excerpt_bytes: usize) !EvidenceEntry {
    const range_text = try std.fmt.allocPrint(allocator, "L{}-L{}", .{ range.start_line, range.end_line });
    errdefer allocator.free(range_text);
    const source = try allocator.dupe(u8, range.path);
    errdefer allocator.free(source);
    const kind = try allocator.dupe(u8, "file_range");
    errdefer allocator.free(kind);
    const excerpt = try budgetedExcerpt(allocator, range.text, max_excerpt_bytes);
    errdefer allocator.free(excerpt);
    return .{
        .source = source,
        .kind = kind,
        .range = range_text,
        .hash = range.hash,
        .excerpt = excerpt,
    };
}

fn budgetedExcerpt(allocator: std.mem.Allocator, text: []const u8, max_excerpt_bytes: usize) ![]u8 {
    const n = @min(text.len, max_excerpt_bytes);
    if (text.len <= n) return allocator.dupe(u8, text);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..n]);
    if (!std.mem.endsWith(u8, out.items, "\n")) try out.append(allocator, '\n');
    try out.appendSlice(allocator, "[TRUNCATED]\n");
    return out.toOwnedSlice(allocator);
}

test "evidence packet renders compact context" {
    var packet = EvidencePacket.init(std.testing.allocator);
    defer packet.deinit();
    try packet.add(.{
        .source = try std.testing.allocator.dupe(u8, "src/main.zig"),
        .kind = try std.testing.allocator.dupe(u8, "file_range"),
        .range = try std.testing.allocator.dupe(u8, "L1-L2"),
        .hash = 123,
        .excerpt = try std.testing.allocator.dupe(u8, "const x = 1;\n"),
    });
    const rendered = try packet.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hash=7b") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "const x = 1;") != null);
}

test "from file range owns source kind range and excerpt" {
    var path = try std.testing.allocator.dupe(u8, "README.md");
    defer std.testing.allocator.free(path);
    var text = try std.testing.allocator.dupe(u8, "hello\n");
    defer std.testing.allocator.free(text);
    const range = tools.FileRange{
        .path = path,
        .start_line = 1,
        .end_line = 1,
        .total_lines = 1,
        .hash = 0x42,
        .text = text,
    };

    const entry = try fromFileRange(std.testing.allocator, range);
    defer entry.deinit(std.testing.allocator);

    path[0] = 'X';
    text[0] = 'X';

    try std.testing.expectEqualStrings("README.md", entry.source);
    try std.testing.expectEqualStrings("file_range", entry.kind);
    try std.testing.expectEqualStrings("L1-L1", entry.range);
    try std.testing.expectEqualStrings("hello\n", entry.excerpt);
}

test "from file range budget prevents raw tail leak" {
    const text = "visible\nhidden-tail\n";
    const range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "README.md"),
        .start_line = 1,
        .end_line = 2,
        .total_lines = 2,
        .hash = 0x42,
        .text = try std.testing.allocator.dupe(u8, text),
    };
    defer range.deinit(std.testing.allocator);

    const entry = try fromFileRangeBudgeted(std.testing.allocator, range, "visible\n".len);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, entry.excerpt, "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.excerpt, "hidden-tail") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry.excerpt, "[TRUNCATED]") != null);
}
