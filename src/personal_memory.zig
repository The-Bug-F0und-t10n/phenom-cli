const std = @import("std");

pub const max_key_bytes: usize = 80;
pub const max_value_bytes: usize = 360;
pub const max_entities_bytes: usize = 240;
const rendered_header =
    "source=sqlite_personal_memory durable=true personal_owner=true owner_memory_evidence=true raw_context_persisted=false not_workspace_or_external_evidence=true\n";

pub const Kind = enum {
    preference,
    profile,
    project,
    decision,
    constraint,
    correction,
    goal,
};

pub const Entry = struct {
    id: i64,
    kind: []u8,
    key: []u8,
    value: []u8,
    entities: []u8,
    confidence: []u8,
    created_at_unix_s: ?i64 = null,
    score: f64 = 0,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.key);
        allocator.free(self.value);
        allocator.free(self.entities);
        allocator.free(self.confidence);
    }
};

pub const Candidate = struct {
    kind: Kind,
    key: []u8,
    value: []u8,
    confidence: []const u8,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub fn parseKind(raw: []const u8) ?Kind {
    if (std.ascii.eqlIgnoreCase(raw, "preference")) return .preference;
    if (std.ascii.eqlIgnoreCase(raw, "profile")) return .profile;
    if (std.ascii.eqlIgnoreCase(raw, "project")) return .project;
    if (std.ascii.eqlIgnoreCase(raw, "decision")) return .decision;
    if (std.ascii.eqlIgnoreCase(raw, "constraint")) return .constraint;
    if (std.ascii.eqlIgnoreCase(raw, "correction")) return .correction;
    if (std.ascii.eqlIgnoreCase(raw, "goal")) return .goal;
    return null;
}

pub fn confidenceIsValid(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "confirmed") or
        std.mem.eql(u8, raw, "inferred") or
        std.mem.eql(u8, raw, "uncertain");
}

pub fn normalizeAlloc(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var written: usize = 0;
    var last_space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |byte| {
        if (written >= max_bytes) break;
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
        written += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn validateText(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyPersonalMemory;
    if (containsRawMarker(trimmed)) return error.RawPersonalMemoryDenied;
}

pub fn containsRawMarker(content: []const u8) bool {
    const forbidden = [_][]const u8{
        "---BEGIN CONTENT---",
        "[READ_FILE]",
        "[TOOL_EVENT]",
        "[EVIDENCE]",
        "[SESSION_EVIDENCE]",
        "[WEB_EVIDENCE]",
        "<tool_call>",
        "rawOutput",
        "raw_output",
        "assistant_thinking_delta",
        "rg --json",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, content, needle) != null) return true;
    }
    return false;
}

pub fn hashHex(allocator: std.mem.Allocator, kind: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    try appendLowerTrimmed(&joined, allocator, kind);
    try joined.append(allocator, 0);
    try appendLowerTrimmed(&joined, allocator, key);
    try joined.append(allocator, 0);
    try appendLowerTrimmed(&joined, allocator, value);
    const hash = std.hash.Wyhash.hash(0, joined.items);
    return std.fmt.allocPrint(allocator, "{x}", .{hash});
}

fn appendLowerTrimmed(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (std.mem.trim(u8, text, " \t\r\n")) |byte| {
        try out.append(allocator, std.ascii.toLower(byte));
    }
}

pub fn extractEntities(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendEntitiesFromText(allocator, &out, key);
    try appendEntitiesFromText(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn appendEntitiesFromText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,;:()[]{}<>\"'");
    while (it.next()) |raw| {
        if (out.items.len >= max_entities_bytes) return;
        const token = std.mem.trim(u8, raw, ".!?");
        if (!looksLikeEntity(token)) continue;
        if (containsEntity(out.items, token)) continue;
        if (out.items.len > 0) try out.append(allocator, ' ');
        const remaining = max_entities_bytes - out.items.len;
        try out.appendSlice(allocator, token[0..@min(token.len, remaining)]);
    }
}

fn looksLikeEntity(token: []const u8) bool {
    if (token.len < 3) return false;
    if (token[0] >= 'A' and token[0] <= 'Z') return true;
    return std.mem.indexOfAny(u8, token, "_-.0123456789") != null;
}

fn containsEntity(existing: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, existing, ' ');
    while (it.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item, token)) return true;
    }
    return false;
}

pub fn renderEntries(allocator: std.mem.Allocator, entries: []const Entry, budget_bytes: usize) !?[]u8 {
    if (entries.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, rendered_header);
    var rendered: usize = 0;
    for (entries) |entry| {
        if (out.items.len >= budget_bytes) break;
        const line = try std.fmt.allocPrint(
            allocator,
            "- U{} remembered_personal_value={s} owner_{s}.{s}={s} confidence={s} personal_owner=true\n",
            .{ entry.id, entry.value, entry.kind, entry.key, entry.value, entry.confidence },
        );
        defer allocator.free(line);
        if (out.items.len + line.len > budget_bytes) {
            try out.appendSlice(allocator, "- [CONTEXT_BUCKET_TRUNCATED bucket=personal_memory]\n");
            break;
        }
        try out.appendSlice(allocator, line);
        rendered += 1;
    }
    if (rendered == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn parseModelCandidate(allocator: std.mem.Allocator, output: []const u8) !?Candidate {
    const start = std.mem.indexOfScalar(u8, output, '{') orelse return null;
    const end = jsonObjectEnd(output, start) orelse return error.InvalidPersonalMemoryJson;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, output[start..end], .{}) catch return error.InvalidPersonalMemoryJson;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidPersonalMemoryJson,
    };
    const remember = jsonBoolField(root, "remember") orelse return error.InvalidPersonalMemoryJson;
    if (!remember) return null;
    const raw_kind = jsonStringField(root, "kind") orelse return error.InvalidPersonalMemoryJson;
    const kind = parseKind(raw_kind) orelse return error.InvalidPersonalMemoryKind;
    const raw_key = jsonStringField(root, "key") orelse return error.InvalidPersonalMemoryJson;
    const raw_value = jsonStringField(root, "value") orelse return error.InvalidPersonalMemoryJson;
    const raw_confidence = jsonStringField(root, "confidence") orelse "confirmed";
    const confidence = canonicalConfidence(raw_confidence) orelse return error.InvalidPersonalMemoryConfidence;
    return try buildCandidate(allocator, kind, raw_key, raw_value, confidence);
}

fn jsonObjectEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
        } else if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBoolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn canonicalConfidence(raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "confirmed")) return "confirmed";
    if (std.mem.eql(u8, raw, "inferred")) return "inferred";
    if (std.mem.eql(u8, raw, "uncertain")) return "uncertain";
    return null;
}

fn buildCandidate(allocator: std.mem.Allocator, kind: Kind, key: []const u8, value: []const u8, confidence: []const u8) !Candidate {
    const normalized_key = try normalizeKeyAlloc(allocator, key, max_key_bytes);
    errdefer allocator.free(normalized_key);
    const normalized_value = try normalizeAlloc(allocator, value, max_value_bytes);
    errdefer allocator.free(normalized_value);
    try validateText(normalized_key);
    try validateText(normalized_value);
    return .{
        .kind = kind,
        .key = normalized_key,
        .value = normalized_value,
        .confidence = confidence,
    };
}

fn normalizeKeyAlloc(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var last_sep = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |byte| {
        if (out.items.len >= max_bytes) break;
        const lower = std.ascii.toLower(byte);
        const normalized: u8 = if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9'))
            lower
        else
            '_';
        if (normalized == '_') {
            if (last_sep or out.items.len == 0) continue;
            last_sep = true;
        } else {
            last_sep = false;
        }
        try out.append(allocator, normalized);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

test "personal memory normalizes and denies raw context" {
    const normalized = try normalizeAlloc(std.testing.allocator, "  prefiro\nrespostas curtas  ", 80);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("prefiro respostas curtas", normalized);
    try std.testing.expectError(error.RawPersonalMemoryDenied, validateText("[EVIDENCE]\nraw"));
}

test "personal memory parses model extractor candidate" {
    var candidate = (try parseModelCandidate(
        std.testing.allocator,
        \\{"remember":true,"kind":"profile","key":"Persönlicher Validierungscode","value":"PMEM100","confidence":"confirmed"}
    )).?;
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.profile, candidate.kind);
    try std.testing.expectEqualStrings("pers_nlicher_validierungscode", candidate.key);
    try std.testing.expectEqualStrings("PMEM100", candidate.value);
}

test "personal memory parser skips model-declared non memories" {
    try std.testing.expect((try parseModelCandidate(std.testing.allocator, "{\"remember\":false}")) == null);
}

test "personal memory parser rejects raw context markers" {
    try std.testing.expectError(
        error.RawPersonalMemoryDenied,
        parseModelCandidate(std.testing.allocator, "{\"remember\":true,\"kind\":\"profile\",\"key\":\"raw\",\"value\":\"[EVIDENCE] x\",\"confidence\":\"confirmed\"}"),
    );
}

test "personal memory renders bounded entries" {
    var entries = [_]Entry{.{
        .id = 1,
        .kind = try std.testing.allocator.dupe(u8, "preference"),
        .key = try std.testing.allocator.dupe(u8, "response_style"),
        .value = try std.testing.allocator.dupe(u8, "respostas curtas"),
        .entities = try std.testing.allocator.dupe(u8, ""),
        .confidence = try std.testing.allocator.dupe(u8, "confirmed"),
    }};
    defer entries[0].deinit(std.testing.allocator);
    const rendered = (try renderEntries(std.testing.allocator, &entries, 2048)).?;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source=sqlite_personal_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "remembered_personal_value=respostas curtas") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "owner_preference.response_style=respostas curtas") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "respostas curtas") != null);
}
