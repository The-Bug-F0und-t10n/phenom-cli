const std = @import("std");

const audit = @import("audit.zig");
const model_context = @import("model_context.zig");

const max_entry_bytes: usize = 360;
const max_recent_entries: usize = 6;
const max_dialogue_entries: usize = 4;
const max_topic_entries: usize = 12;
const max_dialogue_accum_bytes: usize = 1600;
const max_dialogue_entry_bytes: usize = 600;
const max_search_entries: usize = 6;
const max_thread_entries: usize = 8;
const max_thread_entry_bytes: usize = 520;
const min_long_summary_events: usize = 18;
const max_long_summary_turns: usize = 6;
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

const ThreadEntry = struct {
    label: []const u8,
    text: []u8,

    fn deinit(self: ThreadEntry, allocator: std.mem.Allocator) void {
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
    var turn_entries_start: usize = 0;
    var skip_current_turn = false;

    for (events, 0..) |event, idx| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            turn_entries_start = entries.items.len;
            skip_current_turn = current_prompt_index != null and idx == current_prompt_index.?;
            if (skip_current_turn) continue;
            try appendDialogueEntry(allocator, &entries, .user, event.body);
        } else if (std.mem.eql(u8, event.kind, "assistant_delta")) {
            if (skip_current_turn) continue;
            try appendDialogueEntry(allocator, &entries, .assistant, event.body);
        } else if (std.mem.eql(u8, event.kind, "turn_done")) {
            if (isFailedTurnDone(event.body)) {
                truncateDialogueEntries(allocator, &entries, turn_entries_start);
            }
            turn_entries_start = entries.items.len;
            skip_current_turn = false;
        }
    }

    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=sqlite_audit temporary=true raw_context_persisted=false not_evidence=true continuity_only=true\n");

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

fn appendRecentUserTopics(allocator: std.mem.Allocator, out: *std.ArrayList(u8), events: []const audit.AuditEvent, current_prompt: []const u8) !void {
    var topics = std.ArrayList([]u8).empty;
    defer freeOwnedSlices(allocator, &topics);

    var i = events.len;
    while (i > 0 and topics.items.len < max_topic_entries) {
        i -= 1;
        const event = events[i];
        if (!std.mem.eql(u8, event.kind, "turn_start")) continue;
        if (std.mem.eql(u8, event.body, current_prompt)) continue;
        const compact_body = try compactOneLine(allocator, event.body, max_entry_bytes);
        defer allocator.free(compact_body);
        const safe_body = try redactRawMarkers(allocator, compact_body);
        defer allocator.free(safe_body);
        if (safe_body.len == 0) continue;
        if (containsOwnedSlice(topics.items, safe_body)) continue;
        const owned = try allocator.dupe(u8, safe_body);
        errdefer allocator.free(owned);
        try topics.append(allocator, owned);
    }

    if (topics.items.len == 0) return;
    try out.appendSlice(allocator, "recent_user_topics:\n");
    for (topics.items, 0..) |topic, idx| {
        const prefix = try std.fmt.allocPrint(allocator, "- T{}: ", .{idx + 1});
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, topic);
        try out.append(allocator, '\n');
    }
}

fn containsOwnedSlice(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn freeOwnedSlices(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit(allocator);
}

fn resetOwnedSlice(allocator: std.mem.Allocator, target: *[]u8) !void {
    const empty = try allocator.alloc(u8, 0);
    allocator.free(target.*);
    target.* = empty;
}

pub fn isFailedTurnDone(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "status=expectation_failed") != null or
        std.mem.indexOf(u8, body, "status=model_error") != null or
        std.mem.indexOf(u8, body, "low_confidence=true") != null or
        std.mem.indexOf(u8, body, "refusal=true") != null;
}

pub fn renderSessionFocus(allocator: std.mem.Allocator, focus_rows: []const audit.SessionFocus) !?[]u8 {
    if (focus_rows.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=sqlite_session_focus temporary=true raw_context_persisted=false operational_summary=true not_evidence=true\n");

    const start = if (focus_rows.len > max_topic_entries) focus_rows.len - max_topic_entries else 0;
    for (focus_rows[start..], 0..) |row, idx| {
        if (std.mem.indexOf(u8, row.flags, "low_confidence=true") != null) continue;
        const topic = try compactOneLine(allocator, row.topic, max_entry_bytes);
        defer allocator.free(topic);
        const facts = try compactOneLine(allocator, row.useful_facts, max_entry_bytes);
        defer allocator.free(facts);
        const safe_topic = try redactRawMarkers(allocator, topic);
        defer allocator.free(safe_topic);
        const safe_facts = try redactRawMarkers(allocator, facts);
        defer allocator.free(safe_facts);
        if (safe_topic.len == 0 and safe_facts.len == 0) continue;
        const prefix = try std.fmt.allocPrint(allocator, "- F{} quality={s} flags={s}\n", .{ idx + 1, row.quality, row.flags });
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        if (safe_topic.len > 0) {
            try out.appendSlice(allocator, "  topic: ");
            try out.appendSlice(allocator, safe_topic);
            try out.append(allocator, '\n');
        }
        if (safe_facts.len > 0) {
            try out.appendSlice(allocator, "  useful_facts: ");
            try out.appendSlice(allocator, safe_facts);
            try out.append(allocator, '\n');
        }
    }

    if (out.items.len == "source=sqlite_session_focus temporary=true raw_context_persisted=false operational_summary=true not_evidence=true\n".len) {
        out.deinit(allocator);
        return null;
    }
    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    return rendered;
}

pub fn renderFallbackSessionFocusFromEvents(allocator: std.mem.Allocator, events: []const audit.AuditEvent, current_prompt: []const u8) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=sqlite_audit_turn_starts temporary=true raw_context_persisted=false operational_summary=true not_evidence=true legacy_fallback=true\n");

    var topics = std.ArrayList([]u8).empty;
    defer freeOwnedSlices(allocator, &topics);
    var pending_topic: ?[]u8 = null;
    errdefer if (pending_topic) |topic| allocator.free(topic);
    var skip_current_turn = false;
    for (events) |event| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            if (pending_topic) |topic| try topics.append(allocator, topic);
            pending_topic = null;
            skip_current_turn = std.mem.eql(u8, event.body, current_prompt);
            if (!skip_current_turn) pending_topic = try allocator.dupe(u8, event.body);
        } else if (std.mem.eql(u8, event.kind, "turn_done")) {
            if (pending_topic) |topic| {
                if (!skip_current_turn and !isFailedTurnDone(event.body)) {
                    try topics.append(allocator, topic);
                } else {
                    allocator.free(topic);
                }
                pending_topic = null;
            }
            skip_current_turn = false;
        }
    }
    if (pending_topic) |topic| {
        try topics.append(allocator, topic);
        pending_topic = null;
    }

    var count: usize = 0;
    var i = topics.items.len;
    while (i > 0 and count < max_topic_entries) {
        i -= 1;
        const compact_body = try compactOneLine(allocator, topics.items[i], max_entry_bytes);
        defer allocator.free(compact_body);
        const safe_body = try redactRawMarkers(allocator, compact_body);
        defer allocator.free(safe_body);
        if (safe_body.len == 0) continue;
        const prefix = try std.fmt.allocPrint(allocator, "- F{} quality=legacy flags=answered=unknown\n  topic: ", .{count + 1});
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, safe_body);
        try out.append(allocator, '\n');
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

pub fn renderLongSessionSummary(allocator: std.mem.Allocator, events: []const audit.AuditEvent, current_prompt: []const u8) !?[]u8 {
    if (events.len < min_long_summary_events) return null;
    var lines = std.ArrayList([]u8).empty;
    defer freeOwnedSlices(allocator, &lines);
    var turn_user: ?[]u8 = null;
    var turn_assistant = try allocator.alloc(u8, 0);
    defer allocator.free(turn_assistant);
    var skip_current_turn = false;

    for (events) |event| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            if (turn_user) |owned| allocator.free(owned);
            turn_user = null;
            try resetOwnedSlice(allocator, &turn_assistant);
            skip_current_turn = std.mem.eql(u8, event.body, current_prompt);
            if (!skip_current_turn) turn_user = try allocator.dupe(u8, event.body);
        } else if (std.mem.eql(u8, event.kind, "assistant_delta")) {
            if (!skip_current_turn and turn_user != null) try appendBounded(allocator, &turn_assistant, event.body);
        } else if (std.mem.eql(u8, event.kind, "turn_done")) {
            if (!skip_current_turn and turn_user != null and !isFailedTurnDone(event.body)) {
                const line = try renderSummaryLine(allocator, turn_user.?, turn_assistant);
                errdefer allocator.free(line);
                if (line.len > 0) {
                    try lines.append(allocator, line);
                } else {
                    allocator.free(line);
                }
            }
            if (turn_user) |owned| allocator.free(owned);
            turn_user = null;
            try resetOwnedSlice(allocator, &turn_assistant);
            skip_current_turn = false;
        }
    }
    if (turn_user) |owned| allocator.free(owned);
    if (lines.items.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=sqlite_audit_long_session temporary=true raw_context_persisted=false operational_summary=true not_evidence=true long_session=true\n");
    const start = if (lines.items.len > max_long_summary_turns) lines.items.len - max_long_summary_turns else 0;
    for (lines.items[start..], 0..) |line, idx| {
        const prefix = try std.fmt.allocPrint(allocator, "- L{} ", .{idx + 1});
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    return rendered;
}

pub fn mergeSessionFocus(allocator: std.mem.Allocator, stored: ?[]const u8, fallback: ?[]const u8) !?[]u8 {
    if (stored == null and fallback == null) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (stored) |text| {
        try out.appendSlice(allocator, text);
        if (!std.mem.endsWith(u8, text, "\n")) try out.append(allocator, '\n');
    }
    if (fallback) |text| {
        try out.appendSlice(allocator, text);
        if (!std.mem.endsWith(u8, text, "\n")) try out.append(allocator, '\n');
    }
    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
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
    try out.appendSlice(allocator, "[SESSION_EVIDENCE]\nsource=sqlite_audit temporary=true raw_context_persisted=false retrieved_not_verified=true requires_model_judgment=true\n");

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
    try out.appendSlice(allocator, "[SESSION_EVIDENCE]\nsource=sqlite_audit_fts temporary=true raw_context_persisted=false semantic_search=fts5_bm25 unit=turn_context retrieved_not_verified=true requires_model_judgment=true\n");

    var rendered_signatures = std.ArrayList([]u8).empty;
    defer freeOwnedSlices(allocator, &rendered_signatures);
    var rendered_count: usize = 0;
    for (hits) |hit| {
        if (rendered_count >= max_search_entries) break;
        if (isFailedSearchHit(hit)) continue;
        const signature = try hitSignature(allocator, hit);
        defer allocator.free(signature);
        if (containsOwnedSlice(rendered_signatures.items, signature)) continue;
        const owned_signature = try allocator.dupe(u8, signature);
        errdefer allocator.free(owned_signature);
        try rendered_signatures.append(allocator, owned_signature);

        const prefix = try std.fmt.allocPrint(allocator, "- S{} score={d:.4} session={s} hit={s} event_id={}\n", .{
            rendered_count + 1,
            hit.score,
            hit.session,
            hit.kind,
            hit.event_id,
        });
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        try renderHitThread(allocator, &out, hit);
        rendered_count += 1;
    }
    if (rendered_count == 0) {
        try out.appendSlice(allocator, "- no session evidence matched model-provided terms\n");
    }

    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try model_context.assertNoRawContextLeak(rendered);
    return .{ .text = rendered, .matches = rendered_count };
}

fn isFailedSearchHit(hit: audit.SessionSearchHit) bool {
    for (hit.turn_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "turn_done") and isFailedTurnDone(event.body)) return true;
    }
    return false;
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

pub fn toFocusBlocks(allocator: std.mem.Allocator, rendered: ?[]const u8) ![]model_context.FocusBlock {
    const text = rendered orelse return allocator.alloc(model_context.FocusBlock, 0);
    const blocks = try allocator.alloc(model_context.FocusBlock, 1);
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

fn truncateDialogueEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(DialogueEntry), new_len: usize) void {
    var i = new_len;
    while (i < entries.items.len) : (i += 1) {
        entries.items[i].deinit(allocator);
    }
    entries.shrinkRetainingCapacity(new_len);
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

fn renderSummaryLine(allocator: std.mem.Allocator, user: []const u8, assistant: []const u8) ![]u8 {
    const compact_user = try compactOneLine(allocator, user, max_entry_bytes);
    defer allocator.free(compact_user);
    const compact_assistant = try compactOneLine(allocator, assistant, max_entry_bytes);
    defer allocator.free(compact_assistant);
    const safe_user = try redactRawMarkers(allocator, compact_user);
    defer allocator.free(safe_user);
    const safe_assistant = try redactRawMarkers(allocator, compact_assistant);
    defer allocator.free(safe_assistant);
    if (safe_user.len == 0 and safe_assistant.len == 0) return allocator.alloc(u8, 0);
    return std.fmt.allocPrint(allocator, "user: {s} assistant: {s}", .{ safe_user, safe_assistant });
}

fn renderHitLine(allocator: std.mem.Allocator, hit: audit.SessionSearchHit) ![]u8 {
    const compact_body = try compactOneLine(allocator, hit.body, max_entry_bytes);
    defer allocator.free(compact_body);
    const safe_body = try redactRawMarkers(allocator, compact_body);
    defer allocator.free(safe_body);
    return std.fmt.allocPrint(allocator, "session={s} {s}: {s}", .{ hit.session, hit.kind, safe_body });
}

fn renderHitThread(allocator: std.mem.Allocator, out: *std.ArrayList(u8), hit: audit.SessionSearchHit) !void {
    if (hit.turn_events.items.len == 0) {
        const line = try renderHitLine(allocator, hit);
        defer allocator.free(line);
        try out.appendSlice(allocator, "  - ");
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        return;
    }
    var entries = std.ArrayList(ThreadEntry).empty;
    defer freeThreadEntries(allocator, &entries);
    for (hit.turn_events.items) |event| {
        try appendThreadEntry(allocator, &entries, sessionRoleLabel(event.kind), event.body);
    }

    const n = @min(entries.items.len, max_thread_entries);
    for (entries.items[0..n]) |entry| {
        const compact_body = try compactOneLine(allocator, entry.text, max_thread_entry_bytes);
        defer allocator.free(compact_body);
        const safe_body = try redactRawMarkers(allocator, compact_body);
        defer allocator.free(safe_body);
        if (safe_body.len == 0) continue;
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, entry.label);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, safe_body);
        try out.append(allocator, '\n');
    }
    if (entries.items.len > n) {
        try out.appendSlice(allocator, "  ... [THREAD_TRUNCATED]\n");
    }
}

fn appendThreadEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(ThreadEntry), label: []const u8, text: []const u8) !void {
    if (text.len == 0) return;
    if (entries.items.len > 0 and std.mem.eql(u8, entries.items[entries.items.len - 1].label, label)) {
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
    try entries.append(allocator, .{ .label = label, .text = owned });
}

fn freeThreadEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(ThreadEntry)) void {
    for (entries.items) |entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn sessionRoleLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "turn_start")) return "user";
    if (std.mem.eql(u8, kind, "assistant_delta")) return "assistant";
    if (std.mem.eql(u8, kind, "turn_done")) return "turn_done";
    return kind;
}

fn hitSignature(allocator: std.mem.Allocator, hit: audit.SessionSearchHit) ![]u8 {
    if (hit.turn_events.items.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ hit.session, hit.kind, hit.body });
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, hit.session);
    try out.append(allocator, '\x1f');
    for (hit.turn_events.items) |event| {
        try out.appendSlice(allocator, event.kind);
        try out.append(allocator, '\x1e');
        try out.appendSlice(allocator, event.body);
        try out.append(allocator, '\x1f');
    }
    return out.toOwnedSlice(allocator);
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
    try std.testing.expect(std.mem.indexOf(u8, result.text, "retrieved_not_verified=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "requires_model_judgment=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "groundedness") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "---BEGIN CONTENT---") == null);
}

test "session fts hits render as temporary bm25 evidence without raw markers" {
    var hits = std.ArrayList(audit.SessionSearchHit).empty;
    defer audit.freeSessionSearchHits(std.testing.allocator, &hits);
    var turn_events = std.ArrayList(audit.AuditEvent).empty;
    try turn_events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "falamos de renderer append-only"),
    });
    try turn_events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "o assunto amplo era copia direta em terminal"),
    });
    try hits.append(std.testing.allocator, .{
        .event_id = 7,
        .session = try std.testing.allocator.dupe(u8, "session-a"),
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre renderer [READ_FILE] append-only"),
        .score = 1.25,
        .turn_events = turn_events,
    });

    const result = try renderSearchHits(std.testing.allocator, hits.items);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "source=sqlite_audit_fts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "semantic_search=fts5_bm25") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "unit=turn_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "retrieved_not_verified=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "requires_model_judgment=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- S1 score=1.2500 session=session-a hit=assistant_delta event_id=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "user: falamos de renderer append-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "assistant: o assunto amplo era copia direta em terminal") != null);
}

test "session fts renderer deduplicates repeated hits from same turn" {
    var hits = std.ArrayList(audit.SessionSearchHit).empty;
    defer audit.freeSessionSearchHits(std.testing.allocator, &hits);

    var first_turn = std.ArrayList(audit.AuditEvent).empty;
    try first_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1"),
    });
    try first_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre genealogia em Mateus 1"),
    });
    var second_turn = std.ArrayList(audit.AuditEvent).empty;
    try second_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1"),
    });
    try second_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre genealogia em Mateus 1"),
    });

    try hits.append(std.testing.allocator, .{
        .event_id = 1,
        .session = try std.testing.allocator.dupe(u8, "default"),
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1"),
        .score = 10,
        .turn_events = first_turn,
    });
    try hits.append(std.testing.allocator, .{
        .event_id = 2,
        .session = try std.testing.allocator.dupe(u8, "default"),
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre genealogia em Mateus 1"),
        .score = 9,
        .turn_events = second_turn,
    });

    const result = try renderSearchHits(std.testing.allocator, hits.items);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(result.text, "- S"));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "assistant: falamos sobre genealogia em Mateus 1") != null);
}

test "session fts renderer merges tokenized assistant deltas inside turn context" {
    var hits = std.ArrayList(audit.SessionSearchHit).empty;
    defer audit.freeSessionSearchHits(std.testing.allocator, &hits);
    var turn = std.ArrayList(audit.AuditEvent).empty;
    try turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1"),
    });
    try turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Você"),
    });
    try turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, " provavelmente"),
    });
    try turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, " quis dizer Mateus 1"),
    });

    try hits.append(std.testing.allocator, .{
        .event_id = 3,
        .session = try std.testing.allocator.dupe(u8, "default"),
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Mateus 1"),
        .score = 3,
        .turn_events = turn,
    });

    const result = try renderSearchHits(std.testing.allocator, hits.items);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), countNeedle(result.text, "assistant:"));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "assistant: Você provavelmente quis dizer Mateus 1") != null);
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

test "session focus renders confirmed summaries and skips low confidence rows" {
    var rows = std.ArrayList(audit.SessionFocus).empty;
    defer audit.freeSessionFocus(std.testing.allocator, &rows);
    try rows.append(std.testing.allocator, .{
        .topic = try std.testing.allocator.dupe(u8, "Mateus 1 / matematica perfeita"),
        .user_intent = try std.testing.allocator.dupe(u8, "user_prompt"),
        .useful_facts = try std.testing.allocator.dupe(u8, "perguntou sobre Matheus 1 na biblia"),
        .quality = try std.testing.allocator.dupe(u8, "confirmed"),
        .flags = try std.testing.allocator.dupe(u8, "answered=true low_confidence=false"),
    });
    try rows.append(std.testing.allocator, .{
        .topic = try std.testing.allocator.dupe(u8, "negativa ruim"),
        .user_intent = try std.testing.allocator.dupe(u8, "user_prompt"),
        .useful_facts = try std.testing.allocator.dupe(u8, "nao tenho acesso"),
        .quality = try std.testing.allocator.dupe(u8, "uncertain"),
        .flags = try std.testing.allocator.dupe(u8, "answered=true refusal=true low_confidence=true"),
    });

    const rendered = (try renderSessionFocus(std.testing.allocator, rows.items)) orelse return error.MissingFocus;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_FOCUS]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "operational_summary=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Matheus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "negativa ruim") == null);
}

test "session focus merge keeps stored focus and legacy topics" {
    const merged = (try mergeSessionFocus(
        std.testing.allocator,
        "source=sqlite_session_focus temporary=true raw_context_persisted=false operational_summary=true not_evidence=true\n- F1 quality=confirmed\n  topic: projeto atual\n",
        "source=sqlite_audit_turn_starts temporary=true raw_context_persisted=false operational_summary=true not_evidence=true legacy_fallback=true\n- F1 quality=legacy flags=answered=unknown\n  topic: Mateus 1\n",
    )) orelse return error.MissingFocus;
    defer std.testing.allocator.free(merged);

    try std.testing.expect(std.mem.indexOf(u8, merged, "topic: projeto atual") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "topic: Mateus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "raw_context_persisted=false") != null);
}

test "fallback session focus skips failed completed turns" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_start"), .body = try std.testing.allocator.dupe(u8, "assunto confirmado") });
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_done"), .body = try std.testing.allocator.dupe(u8, "status=ok low_confidence=false") });
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_start"), .body = try std.testing.allocator.dupe(u8, "assunto falho") });
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_done"), .body = try std.testing.allocator.dupe(u8, "status=ok low_confidence=true") });

    const rendered = (try renderFallbackSessionFocusFromEvents(std.testing.allocator, events.items, "pedido atual")) orelse return error.MissingFocus;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "assunto confirmado") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "assunto falho") == null);
}

test "long session summary keeps successful turns and skips current or failed turns" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const prompt = try std.fmt.allocPrint(std.testing.allocator, "tema antigo {}", .{i});
        try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_start"), .body = prompt });
        const answer = try std.fmt.allocPrint(std.testing.allocator, "resumo util {}", .{i});
        try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "assistant_delta"), .body = answer });
        try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_done"), .body = try std.testing.allocator.dupe(u8, "status=ok low_confidence=false") });
    }
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_start"), .body = try std.testing.allocator.dupe(u8, "turno falho") });
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "assistant_delta"), .body = try std.testing.allocator.dupe(u8, "nao tenho acesso") });
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_done"), .body = try std.testing.allocator.dupe(u8, "status=ok low_confidence=true") });
    try events.append(std.testing.allocator, .{ .kind = try std.testing.allocator.dupe(u8, "turn_start"), .body = try std.testing.allocator.dupe(u8, "pedido atual ambiguo") });

    const rendered = (try renderLongSessionSummary(std.testing.allocator, events.items, "pedido atual ambiguo")) orelse return error.MissingLongSummary;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "long_session=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tema antigo 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tema antigo 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "turno falho") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pedido atual ambiguo") == null);
}

test "session search hits skip failed turn contexts by metadata" {
    var hits = std.ArrayList(audit.SessionSearchHit).empty;
    defer audit.freeSessionSearchHits(std.testing.allocator, &hits);

    var failed_turn = std.ArrayList(audit.AuditEvent).empty;
    try failed_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "pergunta de memoria"),
    });
    try failed_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "resposta operacional ruim"),
    });
    try failed_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_done"),
        .body = try std.testing.allocator.dupe(u8, "status=ok low_confidence=true refusal=true"),
    });
    try hits.append(std.testing.allocator, .{
        .event_id = 10,
        .session = try std.testing.allocator.dupe(u8, "default"),
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "resposta operacional ruim"),
        .score = 10,
        .turn_events = failed_turn,
    });

    var confirmed_turn = std.ArrayList(audit.AuditEvent).empty;
    try confirmed_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "Mateus 1"),
    });
    try confirmed_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre Mateus 1"),
    });
    try confirmed_turn.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_done"),
        .body = try std.testing.allocator.dupe(u8, "status=ok low_confidence=false"),
    });
    try hits.append(std.testing.allocator, .{
        .event_id = 20,
        .session = try std.testing.allocator.dupe(u8, "default"),
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre Mateus 1"),
        .score = 8,
        .turn_events = confirmed_turn,
    });

    const rendered = try renderSearchHits(std.testing.allocator, hits.items);
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), rendered.matches);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "resposta operacional ruim") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "falamos sobre Mateus 1") != null);
}

test "recent dialogue excludes long topic trail; session focus owns recall map" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1 na biblia"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre Mateus 1"),
    });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const prompt = try std.fmt.allocPrint(std.testing.allocator, "turno curto {}", .{i});
        try events.append(std.testing.allocator, .{
            .kind = try std.testing.allocator.dupe(u8, "turn_start"),
            .body = prompt,
        });
        try events.append(std.testing.allocator, .{
            .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
            .body = try std.testing.allocator.dupe(u8, "ok"),
        });
    }
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "eu estava falando sobre o que com voce?"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Nao tenho acesso ao historico."),
    });

    const rendered = (try renderRecentDialogue(std.testing.allocator, events.items, "eu estava falando sobre o que com voce?")) orelse return error.MissingDialogue;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "recent_user_topics:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "user: qual a matematica perfeita") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "continuity_only=true") != null);
}

test "recent dialogue excludes failed turn assistant output by audit status" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1 na biblia"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre Mateus 1"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_done"),
        .body = try std.testing.allocator.dupe(u8, "status=ok elapsed_ms=1000"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "eu estava falando sobre o que com voce?"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Nao tenho acesso ao historico."),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_done"),
        .body = try std.testing.allocator.dupe(u8, "status=expectation_failed elapsed_ms=8000"),
    });

    const rendered = (try renderRecentDialogue(std.testing.allocator, events.items, "eu estava falando sobre o que com voce?")) orelse return error.MissingDialogue;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "falamos sobre Mateus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Nao tenho acesso") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "recent_user_topics:") == null);
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
