const std = @import("std");
const model_context = @import("model_context.zig");

const max_file_bytes = 32 * 1024;
const default_max_entries = 24;
const default_max_entry_bytes = 240;
const max_promoted_entry_bytes = 240;
const max_managed_context_entries = 12;
const max_distilled_field_bytes = 220;
const managed_memory_begin = "<!-- PHENOM_MEMORY_CONTEXT_BEGIN -->";
const managed_memory_end = "<!-- PHENOM_MEMORY_CONTEXT_END -->";

pub const PromotionTarget = enum {
    memory,
    skills,
};

pub const Promotion = struct {
    target: PromotionTarget,
    text: []const u8,
};

pub const DistilledTurnContext = struct {
    task: []const u8,
    outcome: []const u8,
};

pub const SearchTarget = enum {
    memory,
    skills,
    both,
};

const SearchMatch = struct {
    index: usize,
    score: usize,
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
        if (isManagedMemoryMarker(normalized)) continue;
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

fn isManagedMemoryMarker(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "<!-- PHENOM_MEMORY_CONTEXT_");
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
        "[EVIDENCE]",
        "[SESSION_CONTEXT]",
        "[RECENT_DIALOGUE]",
        "<tool_call>",
        "rawOutput",
        "raw_output",
        "assistant_delta",
        "assistant_thinking_delta",
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

pub fn searchFromCwd(allocator: std.mem.Allocator, io: std.Io, target: SearchTarget, terms: []const u8, max_entries: usize) !Loaded {
    return searchFromDir(allocator, io, std.Io.Dir.cwd(), target, terms, max_entries);
}

pub fn searchFromDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, target: SearchTarget, terms: []const u8, max_entries: usize) !Loaded {
    if (std.mem.trim(u8, terms, " \t\r\n").len == 0) return error.MissingTerms;
    var loaded = try loadFromDir(allocator, io, dir);
    defer loaded.deinit();

    var result = Loaded.init(allocator);
    errdefer result.deinit();
    if (target == .memory or target == .both) {
        try appendRankedMatches(allocator, loaded.memory.items, terms, &result.memory, max_entries);
        if (loaded.memory_path) |path| result.memory_path = try allocator.dupe(u8, path);
    }
    if (target == .skills or target == .both) {
        try appendRankedMatches(allocator, loaded.skills.items, terms, &result.skills, max_entries);
        if (loaded.skills_path) |path| result.skills_path = try allocator.dupe(u8, path);
    }
    return result;
}

pub fn recordDistilledTurnFromCwd(allocator: std.mem.Allocator, io: std.Io, context: DistilledTurnContext) ![]u8 {
    return recordDistilledTurnFromDir(allocator, io, std.Io.Dir.cwd(), context);
}

pub fn recordDistilledTurnFromDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, context: DistilledTurnContext) ![]u8 {
    const task = try normalizeDistilledField(allocator, context.task);
    defer allocator.free(task);
    const outcome = try normalizeDistilledField(allocator, context.outcome);
    defer allocator.free(outcome);
    if (task.len == 0 and outcome.len == 0) {
        return allocator.dupe(u8, "target=memory path=MEMORY.md status=skipped reason=empty_distillation");
    }

    var entry = std.ArrayList(u8).empty;
    defer entry.deinit(allocator);
    try entry.appendSlice(allocator, "context:");
    if (task.len > 0) {
        try entry.appendSlice(allocator, " task=");
        try entry.appendSlice(allocator, task);
    }
    if (outcome.len > 0) {
        if (task.len > 0) try entry.appendSlice(allocator, ";");
        try entry.appendSlice(allocator, " visible_outcome=");
        try entry.appendSlice(allocator, outcome);
    }
    if (containsRawMarker(entry.items)) return error.RawContextPromotionDenied;

    const existing = dir.readFileAlloc(io, "MEMORY.md", allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);
    if (containsRawMarker(existing)) return error.RawContextPromotionDenied;

    var managed = std.ArrayList([]u8).empty;
    defer {
        for (managed.items) |line| allocator.free(line);
        managed.deinit(allocator);
    }
    try appendUniqueManagedEntry(allocator, &managed, entry.items);
    try appendExistingManagedEntries(allocator, existing, &managed);

    const base = try stripManagedMemorySection(allocator, existing);
    defer allocator.free(base);

    var next = std.ArrayList(u8).empty;
    defer next.deinit(allocator);
    const base_trimmed = std.mem.trim(u8, base, " \t\r\n");
    if (base_trimmed.len > 0) {
        try next.appendSlice(allocator, base_trimmed);
        try next.appendSlice(allocator, "\n\n");
    }
    try next.appendSlice(allocator, managed_memory_begin);
    try next.append(allocator, '\n');
    for (managed.items) |line| {
        try next.appendSlice(allocator, "- ");
        try next.appendSlice(allocator, line);
        try next.append(allocator, '\n');
    }
    try next.appendSlice(allocator, managed_memory_end);
    try next.append(allocator, '\n');

    try dir.writeFile(io, .{ .sub_path = "MEMORY.md.tmp", .data = next.items });
    try dir.rename("MEMORY.md.tmp", dir, "MEMORY.md", io);

    return std.fmt.allocPrint(allocator, "target=memory path=MEMORY.md status=distilled_context bytes={} entries={}", .{ entry.items.len, managed.items.len });
}

fn normalizeDistilledField(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var last_space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |byte| {
        if (out.items.len >= max_distilled_field_bytes) break;
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
    }
    const normalized = try out.toOwnedSlice(allocator);
    errdefer allocator.free(normalized);
    if (containsRawMarker(normalized)) return error.RawContextPromotionDenied;
    return normalized;
}

fn appendExistingManagedEntries(allocator: std.mem.Allocator, content: []const u8, out: *std.ArrayList([]u8)) !void {
    const begin = std.mem.indexOf(u8, content, managed_memory_begin) orelse return;
    const body_start = begin + managed_memory_begin.len;
    const end_rel = std.mem.indexOf(u8, content[body_start..], managed_memory_end) orelse return;
    const body = content[body_start .. body_start + end_rel];
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (out.items.len >= max_managed_context_entries) return;
        const normalized = normalizeLine(line);
        if (normalized.len == 0 or isManagedMemoryMarker(normalized)) continue;
        if (!std.mem.startsWith(u8, normalized, "context:")) continue;
        try appendUniqueManagedEntry(allocator, out, normalized);
    }
}

fn appendUniqueManagedEntry(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), entry: []const u8) !void {
    const normalized = normalizeLine(entry);
    if (normalized.len == 0) return;
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, normalized)) return;
    }
    if (out.items.len >= max_managed_context_entries) return;
    const owned = try allocator.dupe(u8, normalized);
    errdefer allocator.free(owned);
    try out.append(allocator, owned);
}

fn stripManagedMemorySection(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, content, managed_memory_begin) orelse return allocator.dupe(u8, content);
    const body_start = begin + managed_memory_begin.len;
    const end_rel = std.mem.indexOf(u8, content[body_start..], managed_memory_end) orelse return allocator.dupe(u8, content);
    var after_end = body_start + end_rel + managed_memory_end.len;
    while (after_end < content.len and (content[after_end] == '\n' or content[after_end] == '\r')) : (after_end += 1) {}
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, content[0..begin]);
    try out.appendSlice(allocator, content[after_end..]);
    return out.toOwnedSlice(allocator);
}

fn appendRankedMatches(
    allocator: std.mem.Allocator,
    entries: []const []u8,
    terms: []const u8,
    out: *std.ArrayList([]u8),
    max_entries: usize,
) !void {
    var ranked = std.ArrayList(SearchMatch).empty;
    defer ranked.deinit(allocator);
    for (entries, 0..) |entry, index| {
        const score = matchScore(entry, terms);
        if (score == 0) continue;
        try ranked.append(allocator, .{ .index = index, .score = score });
    }
    std.mem.sort(SearchMatch, ranked.items, {}, struct {
        fn lessThan(_: void, a: SearchMatch, b: SearchMatch) bool {
            if (a.score == b.score) return a.index < b.index;
            return a.score > b.score;
        }
    }.lessThan);

    for (ranked.items) |item| {
        if (out.items.len >= max_entries) break;
        try out.append(allocator, try allocator.dupe(u8, entries[item.index]));
    }
}

fn matchScore(entry: []const u8, terms: []const u8) usize {
    var score: usize = 0;
    var it = std.mem.tokenizeAny(u8, terms, " \t\r\n.,;:()[]{}<>/\\|\"'");
    while (it.next()) |token| {
        const normalized = std.mem.trim(u8, token, "_-");
        if (normalized.len < 2) continue;
        if (indexOfIgnoreCase(entry, normalized) != null) score += normalized.len;
    }
    return score;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
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

test "promotion stores interpreted durable user rule in skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const audit_body = try promoteFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .target = .skills,
        .text = "Nao commitar sem rodar testes",
    });
    defer std.testing.allocator.free(audit_body);
    try std.testing.expect(std.mem.indexOf(u8, audit_body, "status=promoted") != null);

    const duplicate = try promoteFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .target = .skills,
        .text = "- Nao commitar sem rodar testes",
    });
    defer std.testing.allocator.free(duplicate);
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "status=duplicate") != null);

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.memory.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.skills.items.len);
    try std.testing.expectEqualStrings("Nao commitar sem rodar testes", loaded.skills.items[0]);
}

test "persistent context search returns only relevant memory and skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MEMORY.md", .data = "- protocolo local usa MEM_REAL_826\n- tema distante\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "SKILLS.md", .data = "- responder protocolo com SKILL_REAL_826\n- preferencia distante\n" });

    var result = try searchFromDir(std.testing.allocator, std.testing.io, tmp.dir, .both, "protocolo local continuar", 4);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.memory.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.skills.items.len);
    try std.testing.expectEqualStrings("protocolo local usa MEM_REAL_826", result.memory.items[0]);
    try std.testing.expectEqualStrings("responder protocolo com SKILL_REAL_826", result.skills.items[0]);
}

test "distilled project context writes bounded managed memory section" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MEMORY.md", .data = "- arquitetura existente\n" });

    const first = try recordDistilledTurnFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .task = "implementar memoria segura",
        .outcome = "criou resumo operacional",
    });
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "status=distilled_context") != null);

    const duplicate = try recordDistilledTurnFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .task = "implementar memoria segura",
        .outcome = "criou resumo operacional",
    });
    defer std.testing.allocator.free(duplicate);
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "entries=1") != null);

    var loaded = try loadFromDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.memory.items.len);
    try std.testing.expectEqualStrings("arquitetura existente", loaded.memory.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, loaded.memory.items[1], "context: task=implementar memoria segura") != null);
}

test "distilled project context rejects raw protocol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.RawContextPromotionDenied, recordDistilledTurnFromDir(std.testing.allocator, std.testing.io, tmp.dir, .{
        .task = "analisar",
        .outcome = "[EVIDENCE]\nraw",
    }));
}
