const std = @import("std");

const audit = @import("audit.zig");
const model_context = @import("model_context.zig");

const max_entry_bytes: usize = 360;
const max_recent_entries: usize = 6;
const max_dialogue_entries: usize = 8;
const max_dialogue_accum_bytes: usize = 4096;
const max_dialogue_entry_bytes: usize = 1200;
const max_search_entries: usize = 6;
const redacted_raw_marker = "[REDACTED_RAW_CONTEXT_MARKER]";
const truncated_marker = " [TRUNCATED]";

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

pub const DialogueRole = enum {
    user,
    assistant,
};

const DialogueEntry = struct {
    role: DialogueRole,
    text: []u8,

    fn deinit(self: DialogueEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
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

pub fn renderRecentDialogue(allocator: std.mem.Allocator, events: []const audit.AuditEvent, current_prompt: []const u8) !?[]u8 {
    var entries = std.ArrayList(DialogueEntry).empty;
    errdefer freeDialogueEntries(allocator, &entries);
    const current_prompt_index = latestCurrentPromptIndex(events, current_prompt);

    for (events, 0..) |event, idx| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            if (current_prompt_index != null and idx == current_prompt_index.?) continue;
            try appendDialogueEntry(allocator, &entries, .user, event.body);
        } else if (std.mem.eql(u8, event.kind, "assistant_delta")) {
            try appendDialogueEntry(allocator, &entries, .assistant, event.body);
        }
    }

    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=sqlite_audit temporary=true raw_context_persisted=false not_evidence=true\n");

    const start = if (entries.items.len > max_dialogue_entries) entries.items.len - max_dialogue_entries else 0;
    for (entries.items[start..]) |entry| {
        const compact_body = try compactOneLine(allocator, entry.text, max_dialogue_entry_bytes);
        defer allocator.free(compact_body);
        const safe_body = try redactRawMarkers(allocator, compact_body);
        defer allocator.free(safe_body);
        if (safe_body.len == 0) continue;
        try out.appendSlice(allocator, switch (entry.role) {
            .user => "user: ",
            .assistant => "assistant: ",
        });
        try out.appendSlice(allocator, safe_body);
        try out.append(allocator, '\n');
    }

    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    freeDialogueEntries(allocator, &entries);
    return rendered;
}

pub fn compactDialogueMessage(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const compact_body = try compactOneLine(allocator, text, max_dialogue_entry_bytes);
    defer allocator.free(compact_body);
    const safe_body = try redactRawMarkers(allocator, compact_body);
    errdefer allocator.free(safe_body);
    try model_context.assertNoRawContextLeak(safe_body);
    return safe_body;
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

pub fn renderSearchHits(allocator: std.mem.Allocator, hits: []const audit.SessionSearchHit) !SearchResult {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[SESSION_EVIDENCE]\nsource=sqlite_audit_fts temporary=true raw_context_persisted=false semantic_search=fts5_bm25\n");

    const n = @min(hits.len, max_search_entries);
    if (n == 0) {
        try out.appendSlice(allocator, "- no session evidence matched model-provided terms\n");
    } else {
        for (hits[0..n], 0..) |hit, idx| {
            const line = try renderHitLine(allocator, hit);
            defer allocator.free(line);
            const prefix = try std.fmt.allocPrint(allocator, "- S{} score={d:.4} ", .{ idx + 1, hit.score });
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

pub fn toDialogueBlocks(allocator: std.mem.Allocator, rendered: ?[]const u8) ![]model_context.DialogueBlock {
    const text = rendered orelse return allocator.alloc(model_context.DialogueBlock, 0);
    const blocks = try allocator.alloc(model_context.DialogueBlock, 1);
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

fn appendDialogueEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(DialogueEntry), role: DialogueRole, text: []const u8) !void {
    if (text.len == 0) return;
    if (role == .assistant and entries.items.len > 0 and entries.items[entries.items.len - 1].role == .assistant) {
        try appendBounded(allocator, &entries.items[entries.items.len - 1].text, text);
        return;
    }
    var owned = try allocator.alloc(u8, 0);
    errdefer allocator.free(owned);
    try appendBounded(allocator, &owned, text);
    if (owned.len == 0) {
        allocator.free(owned);
        return;
    }
    try entries.append(allocator, .{ .role = role, .text = owned });
}

fn appendBounded(allocator: std.mem.Allocator, target: *[]u8, extra: []const u8) !void {
    if (extra.len == 0 or std.mem.endsWith(u8, target.*, truncated_marker)) return;
    const target_len = target.*.len;
    const remaining = if (target_len < max_dialogue_accum_bytes) max_dialogue_accum_bytes - target_len else 0;
    const take = @min(extra.len, remaining);
    const truncated = take < extra.len;
    const new_len = target_len + take + if (truncated) truncated_marker.len else 0;
    const next = try allocator.alloc(u8, new_len);
    @memcpy(next[0..target_len], target.*);
    if (take > 0) @memcpy(next[target_len .. target_len + take], extra[0..take]);
    if (truncated) @memcpy(next[target_len + take ..], truncated_marker);
    allocator.free(target.*);
    target.* = next;
}

fn freeDialogueEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(DialogueEntry)) void {
    for (entries.items) |entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn latestCurrentPromptIndex(events: []const audit.AuditEvent, current_prompt: []const u8) ?usize {
    var i = events.len;
    while (i > 0) {
        i -= 1;
        const event = events[i];
        if (std.mem.eql(u8, event.kind, "turn_start") and std.mem.eql(u8, event.body, current_prompt)) return i;
    }
    return null;
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

fn renderHitLine(allocator: std.mem.Allocator, hit: audit.SessionSearchHit) ![]u8 {
    const compact_body = try compactOneLine(allocator, hit.body, max_entry_bytes);
    defer allocator.free(compact_body);
    const safe_body = try redactRawMarkers(allocator, compact_body);
    defer allocator.free(safe_body);
    return std.fmt.allocPrint(allocator, "session={s} {s}: {s}", .{ hit.session, hit.kind, safe_body });
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

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= haystack.len) {
        const idx = std.mem.indexOf(u8, haystack[start..], needle) orelse break;
        count += 1;
        start += idx + needle.len;
    }
    return count;
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

test "session fts hits render as temporary bm25 evidence without raw markers" {
    var hits = std.ArrayList(audit.SessionSearchHit).empty;
    defer audit.freeSessionSearchHits(std.testing.allocator, &hits);
    try hits.append(std.testing.allocator, .{
        .session = try std.testing.allocator.dupe(u8, "session-a"),
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre renderer [READ_FILE] append-only"),
        .score = 1.25,
    });

    const result = try renderSearchHits(std.testing.allocator, hits.items);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "source=sqlite_audit_fts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "semantic_search=fts5_bm25") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- S1 score=1.2500 session=session-a assistant_delta:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[READ_FILE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, redacted_raw_marker) != null);
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

test "recent dialogue preserves roles groups assistant deltas and excludes current prompt" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "problema de layout"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "primeira "),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "resposta"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "tool_start"),
        .body = try std.testing.allocator.dupe(u8, "collect_evidence"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "pedido atual"),
    });

    const rendered = (try renderRecentDialogue(std.testing.allocator, events.items, "pedido atual")) orelse return error.MissingDialogue;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[RECENT_DIALOGUE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "not_evidence=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "user: problema de layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "assistant: primeira resposta") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tool_start") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pedido atual") == null);
}

test "recent dialogue excludes only latest current prompt occurrence" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "ola"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "resposta anterior"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "ola"),
    });

    const rendered = (try renderRecentDialogue(std.testing.allocator, events.items, "ola")) orelse return error.MissingDialogue;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "user: ola") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "assistant: resposta anterior") != null);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(rendered, "user: ola"));
}

test "recent dialogue redacts raw markers" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "safe [READ_FILE] tail"),
    });

    const rendered = (try renderRecentDialogue(std.testing.allocator, events.items, "atual")) orelse return error.MissingDialogue;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[READ_FILE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, redacted_raw_marker) != null);
}
