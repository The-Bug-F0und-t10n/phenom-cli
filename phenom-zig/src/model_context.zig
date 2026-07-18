const std = @import("std");
const collect_evidence = @import("collect_evidence.zig");

pub const system_prompt_v1 =
    "You are Phenom, a code agent. Use only provided contracts/evidence. " ++
    "Vague source-code task: infer intent, gather/compare evidence, refine gaps, answer with limits. " ++
    "Do not invent MEMORY or SKILLS.";

pub const EvidenceBlock = struct {
    text: []const u8,
};

pub const CandidateBlock = struct {
    text: []const u8,
};

pub const SessionBlock = struct {
    text: []const u8,
};

pub const DialogueBlock = struct {
    text: []const u8,
};

pub const FocusBlock = struct {
    text: []const u8,
};

pub const NextActionKind = enum {
    answer_directly,
    collect_context,
    repair_tool_call,
    validate_work,
};

pub const NextAction = struct {
    kind: NextActionKind,
    text: []const u8,
    required_tool_calls: u8 = 0,
};

pub const ContextByteBuckets = struct {
    system: usize = system_prompt_v1.len,
    header: usize = 0,
    contracts: usize = 0,
    skills: usize = 0,
    memory: usize = 0,
    candidates: usize = 0,
    evidence: usize = 0,
    focus: usize = 0,
    dialogue: usize = 0,
    session: usize = 0,
    obligations: usize = 0,
    grounding: usize = 0,
    next_action: usize = 0,
    total_context: usize = 0,
};

pub const ModelTurnContext = struct {
    task: []const u8,
    mode: []const u8 = "code_micro",
    budget: []const u8 = "small",
    contracts: []const u8 = "",
    candidates: []const CandidateBlock = &.{},
    evidence: []const EvidenceBlock = &.{},
    focus: []const FocusBlock = &.{},
    dialogue: []const DialogueBlock = &.{},
    session: []const SessionBlock = &.{},
    memory: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    obligations: []const []const u8 = &.{},
    grounding: []const []const u8 = &.{},
    next_action_v1: ?NextAction = null,
    next_action: []const u8 = "",
};

pub fn renderSystemPrompt(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, system_prompt_v1);
}

pub fn renderModelTurnContext(allocator: std.mem.Allocator, ctx: ModelTurnContext) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "[TURN_CONTEXT v1]\n");
    try appendLine(&out, allocator, "task", ctx.task);
    try appendLine(&out, allocator, "mode", ctx.mode);
    try appendLine(&out, allocator, "budget", ctx.budget);

    if (ctx.contracts.len > 0) {
        try out.appendSlice(allocator, "\n[CONTRACTS]\n");
        try out.appendSlice(allocator, ctx.contracts);
        if (!std.mem.endsWith(u8, ctx.contracts, "\n")) try out.append(allocator, '\n');
    }

    if (ctx.skills.len > 0) {
        try out.appendSlice(allocator, "\n[SKILLS]\n");
        try appendList(&out, allocator, ctx.skills);
    }

    if (ctx.memory.len > 0) {
        try out.appendSlice(allocator, "\n[MEMORY]\n");
        try appendList(&out, allocator, ctx.memory);
    }

    if (ctx.candidates.len > 0) {
        try out.appendSlice(allocator, "\n[CANDIDATES_CONTEXT]\n");
        try out.appendSlice(allocator, "C# candidates are temporary selection handles, not E# evidence. Expand one C# before final answer.\n");
        for (ctx.candidates, 0..) |entry, i| {
            const label = try std.fmt.allocPrint(allocator, "CANDIDATES{}:\n", .{i + 1});
            defer allocator.free(label);
            try out.appendSlice(allocator, label);
            try appendEvidenceText(&out, allocator, entry.text);
        }
    }

    if (ctx.evidence.len > 0) {
        try out.appendSlice(allocator, "\n[EVIDENCE]\n");
        for (ctx.evidence, 0..) |entry, i| {
            const label = try std.fmt.allocPrint(allocator, "E{}:\n", .{i + 1});
            defer allocator.free(label);
            try out.appendSlice(allocator, label);
            try appendEvidenceText(&out, allocator, entry.text);
        }
    }

    if (ctx.focus.len > 0) {
        try out.appendSlice(allocator, "\n[SESSION_FOCUS]\n");
        for (ctx.focus, 0..) |entry, i| {
            const label = try std.fmt.allocPrint(allocator, "F{}:\n", .{i + 1});
            defer allocator.free(label);
            try out.appendSlice(allocator, label);
            try appendEvidenceText(&out, allocator, entry.text);
        }
    }

    if (ctx.dialogue.len > 0) {
        try out.appendSlice(allocator, "\n[RECENT_DIALOGUE]\n");
        for (ctx.dialogue, 0..) |entry, i| {
            const label = try std.fmt.allocPrint(allocator, "D{}:\n", .{i + 1});
            defer allocator.free(label);
            try out.appendSlice(allocator, label);
            try appendEvidenceText(&out, allocator, entry.text);
        }
    }

    if (ctx.session.len > 0) {
        try out.appendSlice(allocator, "\n[SESSION_CONTEXT]\n");
        for (ctx.session, 0..) |entry, i| {
            const label = try std.fmt.allocPrint(allocator, "S{}:\n", .{i + 1});
            defer allocator.free(label);
            try out.appendSlice(allocator, label);
            try appendEvidenceText(&out, allocator, entry.text);
        }
    }

    if (ctx.obligations.len > 0) {
        try out.appendSlice(allocator, "\n[OBLIGATIONS]\n");
        for (ctx.obligations, 0..) |item, i| {
            const line = try std.fmt.allocPrint(allocator, "O{}: {s}\n", .{ i + 1, item });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
    }

    if (ctx.grounding.len > 0) {
        try out.appendSlice(allocator, "\n[GROUNDING]\n");
        try appendList(&out, allocator, ctx.grounding);
    }

    if (ctx.next_action_v1) |action| {
        try out.appendSlice(allocator, "\n[NEXT_ACTION]\n");
        const line = try std.fmt.allocPrint(allocator, "kind={s} required_tool_calls={} action={s}\n", .{ @tagName(action.kind), action.required_tool_calls, action.text });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    } else if (ctx.next_action.len > 0) {
        try out.appendSlice(allocator, "\n[NEXT_ACTION]\n");
        try out.appendSlice(allocator, ctx.next_action);
        if (!std.mem.endsWith(u8, ctx.next_action, "\n")) try out.append(allocator, '\n');
    }

    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try assertNoRawContextLeak(rendered);
    return rendered;
}

pub fn measureRenderedContextBytes(rendered: []const u8) ContextByteBuckets {
    const markers = [_][]const u8{
        "\n[CONTRACTS]\n",
        "\n[SKILLS]\n",
        "\n[MEMORY]\n",
        "\n[CANDIDATES_CONTEXT]\n",
        "\n[EVIDENCE]\n",
        "\n[SESSION_FOCUS]\n",
        "\n[RECENT_DIALOGUE]\n",
        "\n[SESSION_CONTEXT]\n",
        "\n[OBLIGATIONS]\n",
        "\n[GROUNDING]\n",
        "\n[NEXT_ACTION]\n",
    };
    var buckets = ContextByteBuckets{ .total_context = rendered.len };
    buckets.header = firstBlockStart(rendered, markers[0..]);
    buckets.contracts = sectionLen(rendered, "\n[CONTRACTS]\n", markers[0..]);
    buckets.skills = sectionLen(rendered, "\n[SKILLS]\n", markers[0..]);
    buckets.memory = sectionLen(rendered, "\n[MEMORY]\n", markers[0..]);
    buckets.candidates = sectionLen(rendered, "\n[CANDIDATES_CONTEXT]\n", markers[0..]);
    buckets.evidence = sectionLen(rendered, "\n[EVIDENCE]\n", markers[0..]);
    buckets.focus = sectionLen(rendered, "\n[SESSION_FOCUS]\n", markers[0..]);
    buckets.dialogue = sectionLen(rendered, "\n[RECENT_DIALOGUE]\n", markers[0..]);
    buckets.session = sectionLen(rendered, "\n[SESSION_CONTEXT]\n", markers[0..]);
    buckets.obligations = sectionLen(rendered, "\n[OBLIGATIONS]\n", markers[0..]);
    buckets.grounding = sectionLen(rendered, "\n[GROUNDING]\n", markers[0..]);
    buckets.next_action = sectionLen(rendered, "\n[NEXT_ACTION]\n", markers[0..]);
    return buckets;
}

pub fn assertNoRawContextLeak(rendered: []const u8) !void {
    const forbidden = [_][]const u8{
        "---BEGIN CONTENT---",
        "[READ_FILE]",
        "rawOutput",
        "raw_output",
        "rg --json",
        "SECRET_RAW_TAIL",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, rendered, needle) != null) return error.RawContextLeak;
    }
}

fn firstBlockStart(rendered: []const u8, markers: []const []const u8) usize {
    var first = rendered.len;
    for (markers) |marker| {
        const idx = std.mem.indexOf(u8, rendered, marker) orelse continue;
        if (idx < first) first = idx;
    }
    return first;
}

fn sectionLen(rendered: []const u8, marker: []const u8, markers: []const []const u8) usize {
    const start = std.mem.indexOf(u8, rendered, marker) orelse return 0;
    var end = rendered.len;
    for (markers) |next_marker| {
        const idx = std.mem.indexOfPos(u8, rendered, start + marker.len, next_marker) orelse continue;
        if (idx < end) end = idx;
    }
    return end - start;
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, value);
    try out.append(allocator, '\n');
}

fn appendList(out: *std.ArrayList(u8), allocator: std.mem.Allocator, items: []const []const u8) !void {
    for (items) |item| {
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, item);
        if (!std.mem.endsWith(u8, item, "\n")) try out.append(allocator, '\n');
    }
}

fn appendEvidenceText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[EVIDENCE]")) continue;
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}

test "system prompt stays compact and stable" {
    const prompt = try renderSystemPrompt(std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(prompt.len < 240);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "infer intent") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "refine gaps") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Do not invent MEMORY or SKILLS") != null);
}

test "model context omits absent memory skills and evidence blocks" {
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "analisar bug",
        .contracts = "tools: collect_evidence,apply_patch",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[TURN_CONTEXT v1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[CONTRACTS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE]") == null);
}

test "model context renders evidence obligations and next action" {
    const evidence_blocks = [_]EvidenceBlock{.{ .text =
        \\[EVIDENCE]
        \\- src/main.zig L1-L2 hash=abc
        \\const x = 1;
    }};
    const obligations = [_][]const u8{"validate syntax before final"};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "corrigir bug",
        .contracts = "tools: collect_evidence",
        .evidence = &evidence_blocks,
        .obligations = &obligations,
        .next_action = "Use collect_evidence if range is stale.",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "E1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "src/main.zig L1-L2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "O1: validate syntax") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[NEXT_ACTION]") != null);
}

test "model context renders typed next action and byte buckets" {
    const evidence_blocks = [_]EvidenceBlock{.{ .text = "packet_version=v1\n- E1 kind=file_range source=src/main.zig range=L1-L1 status=ok confidence=medium hash=1\nconst x = 1;" }};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "corrigir",
        .contracts = "tools: collect_evidence",
        .evidence = &evidence_blocks,
        .next_action_v1 = .{
            .kind = .collect_context,
            .required_tool_calls = 1,
            .text = "emit one collect_evidence call before prose",
        },
    });
    defer std.testing.allocator.free(rendered);

    const buckets = measureRenderedContextBytes(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "kind=collect_context required_tool_calls=1") != null);
    try std.testing.expect(buckets.system == system_prompt_v1.len);
    try std.testing.expect(buckets.contracts > 0);
    try std.testing.expect(buckets.evidence > 0);
    try std.testing.expect(buckets.next_action > 0);
    try std.testing.expectEqual(rendered.len, buckets.header + buckets.contracts + buckets.evidence + buckets.next_action);
}

test "model context renders candidates outside evidence" {
    const candidate_blocks = [_]CandidateBlock{.{ .text =
        \\[CANDIDATES]
        \\- C1 path=src/render.zig
    }};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "selecionar funcao",
        .contracts = "tools: collect_evidence",
        .candidates = &candidate_blocks,
        .next_action = "expand C1",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[CANDIDATES_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "C# candidates are temporary") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "C1 path=src/render.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "E1:") == null);
}

test "model context renders temporary session context separately from memory" {
    const session_blocks = [_]SessionBlock{.{ .text = "turn_start: lembre do renderer append-only" }};
    const grounding = [_][]const u8{"Claims about session history must cite S#."};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "continuar",
        .session = &session_blocks,
        .grounding = &grounding,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "S1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "renderer append-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[GROUNDING]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
}

test "model context renders recent dialogue separately from session evidence" {
    const dialogue_blocks = [_]DialogueBlock{.{ .text = "source=sqlite_audit temporary=true raw_context_persisted=false not_evidence=true\nuser: pergunta\nassistant: resposta" }};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "continuar",
        .dialogue = &dialogue_blocks,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[RECENT_DIALOGUE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "user: pergunta") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "assistant: resposta") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_CONTEXT]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
}

test "model context includes memory and skills only when explicitly provided" {
    const memory = [_][]const u8{"Projeto usa Zig 0.16."};
    const skills = [_][]const u8{"Nunca use any."};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "continuar",
        .memory = &memory,
        .skills = &skills,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Projeto usa Zig 0.16.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Nunca use any.") != null);
}

test "model context rejects raw markers" {
    const evidence_blocks = [_]EvidenceBlock{.{ .text = "safe\n---BEGIN CONTENT---\nraw\n" }};
    try std.testing.expectError(error.RawContextLeak, renderModelTurnContext(std.testing.allocator, .{
        .task = "x",
        .evidence = &evidence_blocks,
    }));
}

test "model context accepts collect evidence output without raw tail" {
    const path = "model_context_collect_evidence_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "alpha\nbeta\nSECRET_RAW_TAIL\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try collect_evidence.execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .budget_bytes = "alpha\nbeta\n".len,
        .max_lines = 10,
    });
    defer result.deinit(std.testing.allocator);
    const evidence_blocks = [_]EvidenceBlock{.{ .text = result.evidence_text }};
    const rendered = try renderModelTurnContext(std.testing.allocator, .{
        .task = "prove anti raw leak",
        .evidence = &evidence_blocks,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "SECRET_RAW_TAIL") == null);
}
