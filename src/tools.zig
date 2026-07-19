const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const stale_hash_bytes = 64 * 1024;

pub const FileRange = struct {
    path: []const u8,
    start_line: usize,
    end_line: usize,
    total_lines: usize,
    hash: u64,
    text: []const u8,

    pub fn deinit(self: FileRange, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
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
    if (start_line == 0) return error.InvalidStartLine;
    try validateModelPath(path);

    const real_path = realPathInsideCwd(allocator, path) catch return error.OpenFileFailed;
    allocator.free(real_path);

    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const mode: [*:0]const u8 = "rb";
    const file = c.fopen(z_path.ptr, mode) orelse return error.OpenFileFailed;
    defer _ = c.fclose(file);

    var raw = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer raw.deinit(allocator);
    var buf: [4096]u8 = undefined;
    const read_limit = @max(max_bytes, stale_hash_bytes);
    var saw_byte = false;
    var newline_count: usize = 0;
    var last_was_newline = false;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        saw_byte = true;
        for (buf[0..n]) |byte| {
            if (byte == '\n') newline_count += 1;
        }
        last_was_newline = buf[n - 1] == '\n';

        if (raw.items.len < read_limit) {
            const remaining = read_limit - raw.items.len;
            try raw.appendSlice(allocator, buf[0..@min(n, remaining)]);
        }
    }
    const total_lines = if (!saw_byte) 0 else newline_count + @intFromBool(!last_was_newline);
    const hash_len = @min(raw.items.len, stale_hash_bytes);
    const hash = std.hash.Wyhash.hash(0, raw.items[0..hash_len]);

    // ponytail: hash first 64 KiB; upgrade to full-file streaming hash when stale checks need whole-file guarantees.
    const visible_items = raw.items;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var line_no: usize = 1;
    var emitted: usize = 0;
    var truncated = false;
    var iter = std.mem.splitScalar(u8, visible_items, '\n');
    while (iter.next()) |line| : (line_no += 1) {
        if (line_no < start_line) continue;
        if (emitted >= max_lines) break;
        if (out.items.len >= max_bytes) {
            truncated = true;
            break;
        }
        const remaining = max_bytes - out.items.len;
        const line_part = line[0..@min(line.len, remaining)];
        try out.appendSlice(allocator, line_part);
        if (out.items.len >= max_bytes) {
            truncated = true;
            break;
        }
        try out.append(allocator, '\n');
        emitted += 1;
        if (line_part.len < line.len) {
            truncated = true;
            break;
        }
    }
    if (truncated) try out.appendSlice(allocator, "[TRUNCATED]\n");

    const text = try out.toOwnedSlice(allocator);
    return .{
        .path = try allocator.dupe(u8, path),
        .start_line = start_line,
        .end_line = if (emitted == 0) start_line else start_line + emitted - 1,
        .total_lines = total_lines,
        .hash = hash,
        .text = text,
    };
}

fn validateModelPath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyPath;
    if (std.fs.path.isAbsolute(path)) return error.AbsolutePathDenied;

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.PathTraversalDenied;
        if (std.mem.startsWith(u8, part, ".")) return error.HiddenPathDenied;
        if (isSensitivePathPart(part)) return error.SensitivePathDenied;
    }
}

fn isSensitivePathPart(part: []const u8) bool {
    return std.ascii.eqlIgnoreCase(part, "credentials.json") or
        std.ascii.eqlIgnoreCase(part, "secrets.json") or
        std.ascii.eqlIgnoreCase(part, "id_rsa") or
        std.ascii.eqlIgnoreCase(part, "id_ed25519") or
        containsIgnoreCase(part, "credential") or
        containsIgnoreCase(part, "secret") or
        containsIgnoreCase(part, "token");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn realPathInsideCwd(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdFailed;
    const cwd_real = std.mem.span(cwd_ptr);

    var target_buf: [4096]u8 = undefined;
    const target_ptr = c.realpath(z_path.ptr, &target_buf) orelse return error.RealPathFailed;
    const target_real = try allocator.dupe(u8, std.mem.span(target_ptr));
    errdefer allocator.free(target_real);

    if (std.mem.eql(u8, cwd_real, target_real)) return target_real;
    if (target_real.len <= cwd_real.len) return error.PathEscapesSandbox;
    if (!std.mem.eql(u8, target_real[0..cwd_real.len], cwd_real)) return error.PathEscapesSandbox;
    if (target_real[cwd_real.len] != std.fs.path.sep) return error.PathEscapesSandbox;
    return target_real;
}

test "read file range denies traversal" {
    try std.testing.expectError(error.PathTraversalDenied, readFileRange(std.testing.allocator, "../x", 1, 1, 1024));
}

test "path validation rejects traversal components but not substring dots" {
    try std.testing.expectError(error.PathTraversalDenied, readFileRange(std.testing.allocator, "foo/../../bar", 1, 1, 1024));
    try std.testing.expectError(error.OpenFileFailed, readFileRange(std.testing.allocator, "foo..txt", 1, 1, 1024));
    try std.testing.expectError(error.OpenFileFailed, readFileRange(std.testing.allocator, "valid..path", 1, 1, 1024));
}

test "model file reads deny hidden and sensitive paths" {
    try std.testing.expectError(error.HiddenPathDenied, readFileRange(std.testing.allocator, ".env", 1, 1, 1024));
    try std.testing.expectError(error.SensitivePathDenied, readFileRange(std.testing.allocator, "config/credentials.json", 1, 1, 1024));
}

test "start line is explicitly one based" {
    try std.testing.expectError(error.InvalidStartLine, readFileRange(std.testing.allocator, "README.md", 0, 1, 1024));
}

test "read file range finds later lines with small byte budget" {
    const path = "tools-range-budget-test.txt";
    var content = std.ArrayList(u8).empty;
    defer content.deinit(std.testing.allocator);
    for (1..90) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "line {}\n", .{i});
        defer std.testing.allocator.free(line);
        try content.appendSlice(std.testing.allocator, line);
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = content.items,
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const range = try readFileRange(std.testing.allocator, path, 77, 1, 16);
    defer range.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 77), range.start_line);
    try std.testing.expectEqual(@as(usize, 77), range.end_line);
    try std.testing.expect(std.mem.indexOf(u8, range.text, "line 77") != null);
}

test "file range owns returned path" {
    const original = try std.testing.allocator.dupe(u8, "README.md");
    defer std.testing.allocator.free(original);
    const range = try readFileRange(std.testing.allocator, original, 1, 1, 128);
    defer range.deinit(std.testing.allocator);
    original[0] = 'X';
    try std.testing.expectEqualStrings("README.md", range.path);
}

test "hash is stable across visible byte windows" {
    const small = try readFileRange(std.testing.allocator, "README.md", 1, 1, 32);
    defer small.deinit(std.testing.allocator);
    const larger = try readFileRange(std.testing.allocator, "README.md", 1, 1, 4096);
    defer larger.deinit(std.testing.allocator);
    try std.testing.expectEqual(small.hash, larger.hash);
}
