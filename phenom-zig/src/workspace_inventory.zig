const std = @import("std");

const max_git_ls_files_bytes: usize = 1024 * 1024;
const max_probe_bytes: usize = 4096;
const max_collection_multiplier: usize = 64;

pub const Source = enum {
    git,
    walk,
};

pub const Result = struct {
    paths: std.ArrayList([]u8),
    source: Source,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.deinit(allocator);
    }
};

pub fn collect(allocator: std.mem.Allocator, io: std.Io, max_paths: usize) !Result {
    if (try collectGit(allocator, io, max_paths)) |paths| {
        return .{ .paths = paths, .source = .git };
    }
    var paths = std.ArrayList([]u8).empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try collectWalk(allocator, io, max_paths, &paths);
    return .{ .paths = paths, .source = .walk };
}

fn collectGit(allocator: std.mem.Allocator, io: std.Io, max_paths: usize) !?std.ArrayList([]u8) {
    var paths = std.ArrayList([]u8).empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    if ((try collectGitCommand(allocator, io, &paths, &.{ "git", "ls-files", "-z" })) == null) return null;
    if (paths.items.len < max_paths) {
        _ = try collectGitCommand(allocator, io, &paths, &.{ "git", "ls-files", "-o", "--exclude-standard", "-z" });
    }
    if (paths.items.len == 0) {
        paths.deinit(allocator);
        return null;
    }
    sortPaths(paths.items);
    trimPaths(allocator, &paths, max_paths);
    return paths;
}

fn collectGitCommand(allocator: std.mem.Allocator, io: std.Io, paths: *std.ArrayList([]u8), argv: []const []const u8) !?void {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_git_ls_files_bytes),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    var it = std.mem.splitScalar(u8, result.stdout, 0);
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        if (!isWorkspacePath(raw)) continue;
        try appendUnique(paths, allocator, raw);
    }
}

fn collectWalk(allocator: std.mem.Allocator, io: std.Io, max_paths: usize, out: *std.ArrayList([]u8)) !void {
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{ .iterate = true });
    defer cwd.close(io);
    var walker = try cwd.walk(allocator);
    defer walker.deinit();

    const collection_limit = max_paths * max_collection_multiplier;
    while (try walker.next(io)) |entry| {
        if (out.items.len >= collection_limit) break;
        if (entry.kind != .file) continue;
        if (!isWorkspacePath(entry.path)) continue;
        if (!isTextFile(cwd, io, entry.path, allocator)) continue;
        try appendUnique(out, allocator, entry.path);
    }
    sortPaths(out.items);
    trimPaths(allocator, out, max_paths);
}

fn appendUnique(out: *std.ArrayList([]u8), allocator: std.mem.Allocator, path: []const u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try out.append(allocator, try allocator.dupe(u8, path));
}

fn sortPaths(paths: [][]u8) void {
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

fn trimPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8), max: usize) void {
    while (paths.items.len > max) {
        const removed = paths.pop().?;
        allocator.free(removed);
    }
}

fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |byte| {
        if (byte == '/') depth += 1;
    }
    return depth;
}

pub fn isWorkspacePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (isPhenomOperationalPart(part)) return false;
    }
    return true;
}

fn isPhenomOperationalPart(part: []const u8) bool {
    return std.mem.eql(u8, part, ".phenom-zig") or
        std.mem.eql(u8, part, ".phenom-context") or
        std.mem.eql(u8, part, ".phenom-sessions") or
        std.mem.eql(u8, part, ".phenom-history");
}

pub fn isTextBytes(bytes: []const u8) bool {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(bytes);
}

fn isTextFile(dir: std.Io.Dir, io: std.Io, path: []const u8, allocator: std.mem.Allocator) bool {
    const bytes = dir.readFileAlloc(io, path, allocator, .limited(max_probe_bytes)) catch return false;
    defer allocator.free(bytes);
    return isTextBytes(bytes);
}

test "workspace path policy rejects only unsafe or phenom operational paths" {
    try std.testing.expect(isWorkspacePath("src/main.py"));
    try std.testing.expect(isWorkspacePath("vendor/package/lib.rs"));
    try std.testing.expect(isWorkspacePath("node_modules/pkg/index.js"));
    try std.testing.expect(isWorkspacePath("zig-cache/o.zig"));
    try std.testing.expect(!isWorkspacePath("../secret.txt"));
    try std.testing.expect(!isWorkspacePath(".phenom-zig/phenom.db"));
}

test "text byte classifier is content based" {
    try std.testing.expect(isTextBytes("fn main() {}\n"));
    try std.testing.expect(isTextBytes("def main():\n    pass\n"));
    try std.testing.expect(!isTextBytes("abc\x00def"));
    try std.testing.expect(!isTextBytes("\xff\xfe"));
}
