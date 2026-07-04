const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
});

pub const FileRange = struct {
    path: []const u8,
    start_line: usize,
    end_line: usize,
    hash: u64,
    text: []const u8,

    pub fn deinit(self: FileRange, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn readFileRange(
    allocator: std.mem.Allocator,
    path: []const u8,
    start_line: usize,
    max_lines: usize,
    max_bytes: usize,
) !FileRange {
    if (std.fs.path.isAbsolute(path)) return error.AbsolutePathDenied;
    if (std.mem.indexOf(u8, path, "..") != null) return error.PathTraversalDenied;

    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const mode = "rb";
    const file = c.fopen(z_path.ptr, mode.ptr) orelse return error.OpenFileFailed;
    defer _ = c.fclose(file);

    var raw = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer raw.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (raw.items.len < max_bytes) {
        const remaining = @min(buf.len, max_bytes - raw.items.len);
        const n = c.fread(&buf, 1, remaining, file);
        if (n == 0) break;
        try raw.appendSlice(allocator, buf[0..n]);
    }
    const raw_items = raw.items;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var line_no: usize = 1;
    var emitted: usize = 0;
    var iter = std.mem.splitScalar(u8, raw_items, '\n');
    while (iter.next()) |line| : (line_no += 1) {
        if (line_no < start_line) continue;
        if (emitted >= max_lines) break;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        emitted += 1;
    }

    const text = try out.toOwnedSlice(allocator);
    const hash = std.hash.Wyhash.hash(0, raw_items);
    return .{
        .path = path,
        .start_line = start_line,
        .end_line = if (emitted == 0) start_line else start_line + emitted - 1,
        .hash = hash,
        .text = text,
    };
}

test "read file range denies traversal" {
    try std.testing.expectError(error.PathTraversalDenied, readFileRange(std.testing.allocator, "../x", 1, 1, 1024));
}
