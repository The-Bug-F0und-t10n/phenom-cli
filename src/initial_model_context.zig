const std = @import("std");

const audit = @import("audit.zig");
const context_profile = @import("context_profile.zig");
const model_context = @import("model_context.zig");
const personal_memory = @import("personal_memory.zig");
const persistent_context = @import("persistent_context.zig");
const session_context = @import("session_context.zig");

pub const Options = struct {
    session: []const u8,
    prompt: []const u8,
    enable_tool_loop: bool,
    include_session_context: bool,
    model_context_enabled: bool,
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *audit.AuditDb,
    options: Options,
) !?[]u8 {
    const include_persistent = options.model_context_enabled or options.enable_tool_loop;
    if (!include_persistent and !options.enable_tool_loop) return null;

    var persistent = persistent_context.Loaded.init(allocator);
    defer persistent.deinit();
    if (include_persistent) persistent = try persistent_context.loadFromCwd(allocator, io);

    var session_events = if (options.include_session_context)
        try db.loadRecentSessionEvents(allocator, options.session, 240)
    else
        std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(allocator, &session_events);

    const focus_text = if (options.include_session_context)
        try loadMergedSessionFocus(allocator, db, options.session, options.prompt, session_events.items)
    else
        null;
    defer if (focus_text) |text| allocator.free(text);
    const focus_blocks = try session_context.toFocusBlocks(allocator, focus_text);
    defer allocator.free(focus_blocks);

    const recent_dialogue = try session_context.renderRecentDialogue(allocator, session_events.items, options.prompt);
    defer if (recent_dialogue) |text| allocator.free(text);
    const dialogue_blocks = try session_context.toDialogueBlocks(allocator, recent_dialogue);
    defer allocator.free(dialogue_blocks);

    const session_blocks = try session_context.toSessionBlocks(allocator, null);
    defer allocator.free(session_blocks);

    var personal_rows = if (options.enable_tool_loop or include_persistent)
        try db.searchPersonalMemory(allocator, options.prompt, null, 6)
    else
        std.ArrayList(personal_memory.Entry).empty;
    if ((options.enable_tool_loop or include_persistent) and personal_rows.items.len == 0) {
        audit.freePersonalMemory(allocator, &personal_rows);
        personal_rows = try db.loadRecentPersonalMemory(allocator, 6);
    }
    defer audit.freePersonalMemory(allocator, &personal_rows);
    const personal_text = try personal_memory.renderEntries(allocator, personal_rows.items, 2048);
    defer if (personal_text) |text| allocator.free(text);
    const personal_blocks = try toPersonalMemoryBlocks(allocator, personal_text);
    defer allocator.free(personal_blocks);

    if (!options.enable_tool_loop and persistent.memory.items.len == 0 and persistent.skills.items.len == 0 and personal_blocks.len == 0) return null;

    if (options.enable_tool_loop and initialTurnContextStateIsEmpty(persistent.memory.items, persistent.skills.items, personal_blocks, focus_blocks, dialogue_blocks, session_blocks)) {
        return try model_context.renderModelTurnContext(allocator, .{
            .task = options.prompt,
            .mode = "micro_turn",
            .budget = "micro",
        });
    }

    const profile = context_profile.select(.{
        .enable_tool_loop = options.enable_tool_loop,
    });
    return try model_context.renderModelTurnContext(allocator, .{
        .task = options.prompt,
        .mode = context_profile.modeName(profile),
        .contracts = context_profile.toolSchema(profile, .initial),
        .evidence = &[_]model_context.EvidenceBlock{},
        .focus = focus_blocks,
        .dialogue = dialogue_blocks,
        .session = session_blocks,
        .personal_memory = personal_blocks,
        .memory = persistent.memory.items,
        .skills = persistent.skills.items,
        .grounding = groundingRules(),
        .next_action_v1 = if (options.enable_tool_loop) .{
            .kind = .collect_context,
            .text = if (personal_blocks.len > 0)
                "Think first. If PERSONAL_MEMORY directly answers an owner fact/preference/request, answer from U# without search_session or workspace/source-code tools; otherwise use the smallest verifying read-only tool."
            else if (persistent.skills.items.len > 0)
                "Think first. Apply relevant [SKILLS] as active operating rules. Use MEMORY/SKILLS for local project/task context before generic answers; otherwise use the smallest verifying read-only tool."
            else if (persistent.memory.items.len > 0)
                "Think first. Use [MEMORY] as distilled local project/task context. Verify workspace/source-code claims with read-only tools when exact evidence is required."
            else
                "Think first. Use the smallest verifying read-only tool before low-confidence answers; ask only when exploration cannot reduce ambiguity.",
        } else .{
            .kind = .answer_directly,
            .text = "Apply persistent MEMORY/SKILLS only if relevant; answer the current user request directly.",
        },
    });
}

pub fn initialTurnContextStateIsEmpty(
    memory: []const []const u8,
    skills: []const []const u8,
    personal: []const model_context.PersonalMemoryBlock,
    focus: []const model_context.FocusBlock,
    dialogue: []const model_context.DialogueBlock,
    session: []const model_context.SessionBlock,
) bool {
    return memory.len == 0 and skills.len == 0 and personal.len == 0 and focus.len == 0 and dialogue.len == 0 and session.len == 0;
}

pub fn toPersonalMemoryBlocks(allocator: std.mem.Allocator, rendered: ?[]const u8) ![]model_context.PersonalMemoryBlock {
    const text = rendered orelse return allocator.alloc(model_context.PersonalMemoryBlock, 0);
    const blocks = try allocator.alloc(model_context.PersonalMemoryBlock, 1);
    blocks[0] = .{ .text = text };
    return blocks;
}

pub fn loadMergedSessionFocus(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    prompt: []const u8,
    session_events: []const audit.AuditEvent,
) !?[]u8 {
    var focus_rows = try db.loadRecentSessionFocus(allocator, session, 16);
    defer audit.freeSessionFocus(allocator, &focus_rows);
    const stored_focus_text = try session_context.renderSessionFocusForPrompt(allocator, focus_rows.items, prompt);
    defer if (stored_focus_text) |text| allocator.free(text);
    const fallback_focus_text = try session_context.renderFallbackSessionFocusFromEvents(allocator, session_events, prompt);
    defer if (fallback_focus_text) |text| allocator.free(text);
    const long_summary_text = try session_context.renderLongSessionSummary(allocator, session_events, prompt);
    defer if (long_summary_text) |text| allocator.free(text);
    const fallback_context_text = try session_context.mergeSessionFocus(allocator, fallback_focus_text, long_summary_text);
    defer if (fallback_context_text) |text| allocator.free(text);
    return try session_context.mergeSessionFocus(allocator, stored_focus_text, fallback_context_text);
}

pub fn groundingRules() []const []const u8 {
    return &.{
        "Workspace/source-code claims cite E#; owner memory U# is not workspace/source-code evidence.",
        "Quote only text present in E#/S#; explain outside quote/code blocks.",
        "[CONTRACTS], [GROUNDING], and tool schemas are instructions, not evidence.",
        "[PERSONAL_MEMORY] U# is sufficient evidence for owner preferences/profile/constraints; use remembered_personal_value or owner_<kind>.<key> for owner facts.",
        "[MEMORY] is distilled project/task context and visible outcomes; use it to stay centered, but verify exact workspace/source-code claims with E#.",
        "[SKILLS] are active local operating rules when relevant; do not contradict retrieved or loaded SKILLS.",
        "Source-code identity claims need identifier/declaration/callsite in E#.",
        "[RECENT_DIALOGUE] gives continuity; [SESSION_FOCUS] routes only. Exact prior-session claims need S#.",
        "S# entries are candidates; judge relevance and direct support before using them.",
        "Near/partial matches are not evidenced exact entity/fact claims; refine retrieval or state not evidenced.",
        "If E#/S# shows a tool ran, report observed status/error/evidence instead of unavailable.",
        "Named/obscure entities/current/existence facts absent from dialogue, MEMORY/SKILLS, SESSION_CONTEXT, E#, or stable knowledge need search_web/rag_web before unknown/no-records.",
        "For vague workspace/code tasks, infer intent, split targets, and use collect_evidence terms as retrieval keys.",
        "If workspace/code context is required and collect_evidence is available, call it before saying context is unavailable.",
        "If web_search fails operationally, report status/error; do not invent a replacement URL.",
        "search_session intent says what to recover; terms are retrieval keys.",
        "If prior conversation context is required and search_session is available, call it before saying history is unavailable.",
        "If no E#/S# supports a workspace or exact prior-session claim, say it is not evidenced.",
        "Answer in user's language unless USER_TASK asks otherwise; translate or summarize evidence.",
        "When answering a local rule/preference/protocol from retrieved MEMORY/SKILLS, use only directly retrieved entry; no generic best practices.",
        "Low confidence: verify with available read-only tools before generic clarification.",
        "External factual uncertainty needs search_web/rag_web; no plausibility as fact.",
        "External retrieval unavailable/failed/no support: state limitation; do not invent.",
        "Estimates need explicit request or estimate label; never as verified facts.",
    };
}

test "initial turn context empty check covers all blocks" {
    try std.testing.expect(initialTurnContextStateIsEmpty(&.{}, &.{}, &.{}, &.{}, &.{}, &.{}));
    const personal = [_]model_context.PersonalMemoryBlock{.{ .text = "U1 kind=preference value=test" }};
    try std.testing.expect(!initialTurnContextStateIsEmpty(&.{}, &.{}, &personal, &.{}, &.{}, &.{}));
}
