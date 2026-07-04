const std = @import("std");
const tools = @import("tools.zig");

pub const EvidenceEntry = struct {
    source: []const u8,
    kind: []const u8,
    range: []const u8,
    hash: u64,
    excerpt: []const u8,

    pub fn deinit(self: EvidenceEntry, allocator: std.mem.Allocator) void {
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
    const range_text = try std.fmt.allocPrint(allocator, "L{}-L{}", .{ range.start_line, range.end_line });
    const excerpt = try allocator.dupe(u8, range.text);
    return .{
        .source = range.path,
        .kind = "file_range",
        .range = range_text,
        .hash = range.hash,
        .excerpt = excerpt,
    };
}

test "evidence packet renders compact context" {
    var packet = EvidencePacket.init(std.testing.allocator);
    defer packet.deinit();
    try packet.add(.{
        .source = "src/main.zig",
        .kind = "file_range",
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
