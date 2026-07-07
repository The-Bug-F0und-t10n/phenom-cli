const std = @import("std");

const audit = @import("audit.zig");
const model_context = @import("model_context.zig");

const max_entry_bytes: usize = 360;
const max_recent_entries: usize = 6;
const max_search_entries: usize = 6;
const redacted_raw_marker = "[REDACTED_RAW_CONTEXT_MARKER]";

pub const SearchResult = struct {
    text: []u8,
    matches: usize,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const Candidate = struct {
    event_index: usize,
    score: usize,
};

pub fn renderRecent(allocator: std.mem.Allocator, events: []const audit.AuditEvent, current_prompt: []const u8) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var count: usize = 0;

    var i = events.len;
    while (i > 0 and count < max_recent_entries) {
        i -= 1;
        const event = events[i];
        if (!isUsefulSessionEvent(event.kind)) continue;
        if (std.mem.eql(u8, event.kind, "turn_start") and std.mem.eql(u8, event.body, current_prompt)) continue;
        const line = try renderEventLine(allocator, event);
        defer allocator.free(line);
        if (line.len == 0) continue;
        try appendSessionLine(&out, allocator, line);
        count += 1;
    }

    if (count == 0) {
        out.deinit(allocator);
        return null;
    }
    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    return rendered;
}

pub fn search(allocator: std.mem.Allocator, events: []const audit.AuditEvent, terms: []const u8) !SearchResult {
    var candidates = std.ArrayList(Candidate).empty;
    defer candidates.deinit(allocator);

    for (events, 0..) |event, i| {
        if (!isUsefulSessionEvent(event.kind)) continue;
        const score = scoreEvent(event, terms);
        if (score == 0) continue;
        try candidates.append(allocator, .{ .event_index = i, .score = score });
    }

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.event_index > b.event_index;
        }
    }.lessThan);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[SESSION_EVIDENCE]\nsource=sqlite_audit temporary=true raw_context_persisted=false\n");

    const n = @min(candidates.items.len, max_search_entries);
    if (n == 0) {
        try out.appendSlice(allocator, "- no session evidence matched model-provided terms\n");
    } else {
        for (candidates.items[0..n], 0..) |candidate, idx| {
            const line = try renderEventLine(allocator, events[candidate.event_index]);
            defer allocator.free(line);
            const prefix = try std.fmt.allocPrint(allocator, "- S{} score={} ", .{ idx + 1, candidate.score });
            defer allocator.free(prefix);
            try out.appendSlice(allocator, prefix);
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    return .{ .text = rendered, .matches = n };
}

pub fn toSessionBlocks(allocator: std.mem.Allocator, rendered: ?[]const u8) ![]model_context.SessionBlock {
    const text = rendered orelse return allocator.alloc(model_context.SessionBlock, 0);
    const blocks = try allocator.alloc(model_context.SessionBlock, 1);
    blocks[0] = .{ .text = text };
    return blocks;
}

fn isUsefulSessionEvent(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "turn_start") or
        std.mem.eql(u8, kind, "assistant_delta") or
        std.mem.eql(u8, kind, "tool_start") or
        std.mem.eql(u8, kind, "working_context_add") or
        std.mem.eql(u8, kind, "tool_duplicate") or
        std.mem.eql(u8, kind, "turn_done");
}

fn scoreEvent(event: audit.AuditEvent, terms: []const u8) usize {
    var score: usize = 0;
    var it = std.mem.tokenizeAny(u8, terms, " \t\r\n\"'`()[]{}<>:;,");
    while (it.next()) |term| {
        if (term.len == 0) continue;
        if (indexOfIgnoreCase(event.body, term) != null) score += term.len;
        if (indexOfIgnoreCase(event.kind, term) != null) score += term.len;
    }
    return score;
}

fn renderEventLine(allocator: std.mem.Allocator, event: audit.AuditEvent) ![]u8 {
    const compact_body = try compactOneLine(allocator, event.body, max_entry_bytes);
    defer allocator.free(compact_body);
    const safe_body = try redactRawMarkers(allocator, compact_body);
    defer allocator.free(safe_body);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ event.kind, safe_body });
}

fn appendSessionLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    try out.appendSlice(allocator, "- ");
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn compactOneLine(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var written: usize = 0;
    var last_space = false;
    for (text) |byte| {
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
    if (text.len > max_bytes) try out.appendSlice(allocator, " [TRUNCATED]");
    return out.toOwnedSlice(allocator);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn redactRawMarkers(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const markers = [_][]const u8{
        "---BEGIN CONTENT---",
        "[READ_FILE]",
        "rawOutput",
        "raw_output",
        "rg --json",
        "SECRET_RAW_TAIL",
    };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    while (start < text.len) {
        var next_index: ?usize = null;
        var next_marker: []const u8 = "";
        for (markers) |marker| {
            if (std.mem.indexOf(u8, text[start..], marker)) |relative| {
                const absolute = start + relative;
                if (next_index == null or absolute < next_index.?) {
                    next_index = absolute;
                    next_marker = marker;
                }
            }
        }
        const index = next_index orelse {
            try out.appendSlice(allocator, text[start..]);
            break;
        };
        try out.appendSlice(allocator, text[start..index]);
        try out.appendSlice(allocator, redacted_raw_marker);
        start = index + next_marker.len;
    }
    return out.toOwnedSlice(allocator);
}

test "recent session context is temporary and excludes current prompt" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "primeiro pedido"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre renderer append-only"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "pedido atual"),
    });

    const rendered = (try renderRecent(std.testing.allocator, events.items, "pedido atual")) orelse return error.MissingSessionContext;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "renderer append-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pedido atual") == null);
}

test "session search uses model provided terms and does not leak raw markers" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "discutimos groundedness e citacoes"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "model_context"),
        .body = try std.testing.allocator.dupe(u8, "---BEGIN CONTENT--- raw"),
    });

    const result = try search(std.testing.allocator, events.items, "groundedness citacoes");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.matches);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "groundedness") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "---BEGIN CONTENT---") == null);
}

test "session context redacts raw markers from useful events" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "safe ---BEGIN CONTENT--- tail"),
    });

    const rendered = (try renderRecent(std.testing.allocator, events.items, "atual")) orelse return error.MissingSessionContext;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "---BEGIN CONTENT---") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, redacted_raw_marker) != null);
}
