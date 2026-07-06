const std = @import("std");
const evidence = @import("evidence.zig");
const gate = @import("gate.zig");
const micro_context = @import("micro_context.zig");
const tool_call = @import("tool_call.zig");
const tools = @import("tools.zig");

pub const ToolLoopResult = struct {
    executed: bool,
    rejected: bool,
    evidence_text: ?[]u8 = null,
    micro_context_text: ?[]u8 = null,

    pub fn deinit(self: ToolLoopResult, allocator: std.mem.Allocator) void {
        if (self.evidence_text) |text| allocator.free(text);
        if (self.micro_context_text) |text| allocator.free(text);
    }
};

pub fn runOnce(
    allocator: std.mem.Allocator,
    model_output: []const u8,
    allowed_tools: []const []const u8,
) !ToolLoopResult {
    const call = (try tool_call.parseFirst(allocator, model_output)) orelse return .{
        .executed = false,
        .rejected = false,
    };
    defer call.deinit(allocator);

    if (!gate.isAllowed(call.name, allowed_tools)) {
        return .{ .executed = false, .rejected = true };
    }

    if (std.mem.eql(u8, call.name, "read_file_range")) {
        const path = call.path orelse return error.MissingPath;
        const range = try tools.readFileRange(allocator, path, call.start_line, call.max_lines, 16 * 1024);
        defer range.deinit(allocator);

        const entry = try evidence.fromFileRange(allocator, range);
        var packet = evidence.EvidencePacket.init(allocator);
        defer packet.deinit();
        try packet.add(entry);

        const ctx = try micro_context.fromFileRange(allocator, range, "read_file_range", 16 * 1024);
        defer ctx.deinit(allocator);
        return .{
            .executed = true,
            .rejected = false,
            .evidence_text = try packet.render(allocator),
            .micro_context_text = try ctx.render(allocator),
        };
    }

    return .{ .executed = false, .rejected = true };
}

test "tool loop executes announced read_file_range into evidence and micro context" {
    const output =
        \\<tool_call>
        \\<function=read_file_range>
        \\<parameter=path>
        \\README.md
        \\</parameter>
        \\<parameter=start_line>
        \\1
        \\</parameter>
        \\<parameter=max_lines>
        \\3
        \\</parameter>
        \\</function>
        \\</tool_call>
    ;
    const result = try runOnce(std.testing.allocator, output, &.{"read_file_range"});
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.executed);
    try std.testing.expect(!result.rejected);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text.?, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.micro_context_text.?, "[MICRO_CONTEXT") != null);
}

test "tool loop rejects unannounced tool before execution" {
    const output =
        \\<tool_call>
        \\<function=shell>
        \\<parameter=path>
        \\README.md
        \\</parameter>
        \\</function>
        \\</tool_call>
    ;
    const result = try runOnce(std.testing.allocator, output, &.{"read_file_range"});
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.executed);
    try std.testing.expect(result.rejected);
}
