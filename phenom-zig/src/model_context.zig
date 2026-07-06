const std = @import("std");
const collect_evidence = @import("collect_evidence.zig");

pub const system_prompt_v1 =
    "You are Phenom, a code agent. Use only the provided contracts and evidence. " ++
    "Do not invent MEMORY or SKILLS. Ask for evidence when required before code changes.";

pub const EvidenceBlock = struct {
    text: []const u8,
};

pub const ModelTurnContext = struct {
    task: []const u8,
    mode: []const u8 = "code_micro",
    budget: []const u8 = "small",
    contracts: []const u8 = "",
    evidence: []const EvidenceBlock = &.{},
    memory: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    obligations: []const []const u8 = &.{},
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

    if (ctx.evidence.len > 0) {
        try out.appendSlice(allocator, "\n[EVIDENCE]\n");
        for (ctx.evidence, 0..) |entry, i| {
            const label = try std.fmt.allocPrint(allocator, "E{}:\n", .{i + 1});
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

    if (ctx.next_action.len > 0) {
        try out.appendSlice(allocator, "\n[NEXT_ACTION]\n");
        try out.appendSlice(allocator, ctx.next_action);
        if (!std.mem.endsWith(u8, ctx.next_action, "\n")) try out.append(allocator, '\n');
    }

    const rendered = try out.toOwnedSlice(allocator);
    errdefer allocator.free(rendered);
    try assertNoRawContextLeak(rendered);
    return rendered;
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

    const result = try collect_evidence.execute(std.testing.allocator, .{
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
