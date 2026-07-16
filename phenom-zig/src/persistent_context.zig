const std = @import("std");
const model_context = @import("model_context.zig");

const max_file_bytes = 32 * 1024;
const default_max_entries = 24;
const default_max_entry_bytes = 240;
const max_promoted_entry_bytes = 240;

pub const PromotionTarget = enum {
    memory,
    skills,
};

pub const Promotion = struct {
    target: PromotionTarget,
    text: []const u8,
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    memory: std.ArrayList([]u8),
    skills: std.ArrayList([]u8),
    memory_path: ?[]u8 = null,
    skills_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Loaded {
        return .{
            .allocator = allocator,
            .memory = std.ArrayList([]u8).empty,
            .skills = std.ArrayList([]u8).empty,
        };
    }

    pub fn deinit(self: *Loaded) void {
        for (self.memory.items) |entry| self.allocator.free(entry);
        self.memory.deinit(self.allocator);
        for (self.skills.items) |entry| self.allocator.free(entry);
        self.skills.deinit(self.allocator);
        if (self.memory_path) |path| self.allocator.free(path);
        if (self.skills_path) |path| self.allocator.free(path);
    }
};

const LoadedFile = struct {
    path: []u8,
    content: []u8,

    fn deinit(self: LoadedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub fn loadFromCwd(allocator: std.mem.Allocator, io: std.Io) !Loaded {
    return loadFromDir(allocator, io, std.Io.Dir.cwd());
}

pub fn loadFromDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Loaded {
    var loaded = Loaded.init(allocator);
    errdefer loaded.deinit();

    if (try loadFirst(allocator, io, dir, &.{ "MEMORY.md", ".MEMORY.md" })) |file| {
        defer file.deinit(allocator);
        loaded.memory_path = try allocator.dupe(u8, file.path);
        try parseEntries(allocator, file.content, &loaded.memory, default_max_entries, default_max_entry_bytes);
    }

    if (try loadFirst(allocator, io, dir, &.{ "SKILLS.md", ".SKILL.md" })) |file| {
        defer file.deinit(allocator);
        loaded.skills_path = try allocator.dupe(u8, file.path);
        try parseEntries(allocator, file.content, &loaded.skills, default_max_entries, default_max_entry_bytes);
    }

    return loaded;
}

fn loadFirst(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, paths: []const []const u8) !?LoadedFile {
    for (paths) |path| {
        const content = dir.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        errdefer allocator.free(content);
        return .{
            .path = try allocator.dupe(u8, path),
            .content = content,
        };
    }
    return null;
}

fn parseEntries(
    allocator: std.mem.Allocator,
    content: []const u8,
    out: *std.ArrayList([]u8),
    max_entries: usize,
    max_entry_bytes: usize,
) !void {
    if (containsRawMarker(content)) return;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (out.items.len >= max_entries) break;
        const normalized = normalizeLine(line);
        if (normalized.len == 0) continue;
        const entry = try dupTruncated(allocator, normalized, max_entry_bytes);
        errdefer allocator.free(entry);
        try out.append(allocator, entry);
    }
}

fn normalizeLine(line: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t\r\n");
    while (trimmed.len > 0 and trimmed[0] == '#') {
        trimmed = std.mem.trim(u8, trimmed[1..], " \t\r\n");
    }
    if (std.mem.startsWith(u8, trimmed, "- ")) trimmed = std.mem.trim(u8, trimmed[2..], " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "* ")) trimmed = std.mem.trim(u8, trimmed[2..], " \t\r\n");
    return trimmed;
}

fn dupTruncated(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    const n = @min(text.len, max_bytes);
    if (text.len <= n) return allocator.dupe(u8, text);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..n]);
    try out.appendSlice(allocator, " [TRUNCATED]");
    return out.toOwnedSlice(allocator);
}

fn containsRawMarker(content: []const u8) bool {
    const forbidden = [_][]const u8{
        "---BEGIN CONTENT---",
        "[READ_FILE]",
        "[TOOL_EVENT]",
        "rawOutput",
        "raw_output",
        "rg --json",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, content, needle) != null) return true;
    }
    return false;
}

pub fn promoteFromCwd(allocator: std.mem.Allocator, io: std.Io, promotion: Promotion) ![]u8 {
    return promoteFromDir(allocator, io, std.Io.Dir.cwd(), promotion);
}

pub fn promoteFromDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, promotion: Promotion) ![]u8 {
    const normalized = normalizeLine(promotion.text);
    if (normalized.len == 0) return error.EmptyPromotion;
    if (normalized.len > max_promoted_entry_bytes) return error.PromotionTooLarge;
    if (containsRawMarker(normalized)) return error.RawContextPromotionDenied;
    const path = switch (promotion.target) {
        .memory => "MEMORY.md",
        .skills => "SKILLS.md",
    };

    const existing = dir.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    if (entryExists(existing, normalized)) {
        return std.fmt.allocPrint(allocator, "target={s} path={s} status=duplicate bytes={}", .{ @tagName(promotion.target), path, normalized.len });
    }

    var next = std.ArrayList(u8).empty;
    defer next.deinit(allocator);
    try next.appendSlice(allocator, existing);
    if (next.items.len > 0 and !std.mem.endsWith(u8, next.items, "\n")) try next.append(allocator, '\n');
    try next.appendSlice(allocator, "- ");
    try next.appendSlice(allocator, normalized);
    try next.append(allocator, '\n');

    const tmp_path = switch (promotion.target) {
        .memory => "MEMORY.md.tmp",
        .skills => "SKILLS.md.tmp",
    };
    try dir.writeFile(io, .{ .sub_path = tmp_path, .data = next.items });
    try dir.rename(tmp_path, dir, path, io);

    return std.fmt.allocPrint(allocator, "target={s} path={s} status=promoted bytes={}", .{ @tagName(promotion.target), path, normalized.len });
}

fn entryExists(content: []const u8, normalized: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, normalizeLine(line), normalized)) return true;
    }
    return false;
}

test "persistent context absent files yields empty memory and skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.memory.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.items.len);
    try std.testing.expect(loaded.memory_path == null);
    try std.testing.expect(loaded.skills_path == null);
}

test "persistent context prefers MEMORY.md over dot fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".MEMORY.md", .data = "- fallback\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MEMORY.md", .data = "- primary\n" });

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("MEMORY.md", loaded.memory_path.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.memory.items.len);
    try std.testing.expectEqualStrings("primary", loaded.memory.items[0]);
}

test "persistent context loads dot memory and skills fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".MEMORY.md", .data = "# Facts\n- Projeto usa Zig\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".SKILL.md", .data = "- Nunca use any\n" });

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();

    try std.testing.expectEqualStrings(".MEMORY.md", loaded.memory_path.?);
    try std.testing.expectEqualStrings(".SKILL.md", loaded.skills_path.?);
    try std.testing.expectEqualStrings("Facts", loaded.memory.items[0]);
    try std.testing.expectEqualStrings("Projeto usa Zig", loaded.memory.items[1]);
    try std.testing.expectEqualStrings("Nunca use any", loaded.skills.items[0]);
}

test "persistent context rejects raw tool output files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "MEMORY.md",
        .data = "valid\n---BEGIN CONTENT---\nSECRET_RAW_TAIL\n",
    });

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.memory.items.len);
}

test "persistent context renders through model context only when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "SKILLS.md", .data = "- Nunca use any\n" });

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    const rendered = try model_context.renderModelTurnContext(std.testing.allocator, .{
        .task = "continuar",
        .memory = loaded.memory.items,
        .skills = loaded.skills.items,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Nunca use any") != null);
}

test "promotion writes memory atomically and deduplicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try promoteFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .target = .memory,
        .text = "Projeto usa EvidencePacket compacto",
    });
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "status=promoted") != null);

    const duplicate = try promoteFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .target = .memory,
        .text = "Projeto usa EvidencePacket compacto",
    });
    defer std.testing.allocator.free(duplicate);
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "status=duplicate") != null);

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Projeto usa EvidencePacket compacto", loaded.memory.items[0]);
}

test "promotion separates skills and rejects raw tool output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const audit_body = try promoteFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .target = .skills,
        .text = "Nunca use any",
    });
    defer std.testing.allocator.free(audit_body);
    try std.testing.expect(std.mem.indexOf(u8, audit_body, "target=skills") != null);

    try std.testing.expectError(error.RawContextPromotionDenied, promoteFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .target = .memory,
        .text = "[TOOL_EVENT]\nraw",
    }));

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.memory.items.len);
    try std.testing.expectEqualStrings("Nunca use any", loaded.skills.items[0]);
}
