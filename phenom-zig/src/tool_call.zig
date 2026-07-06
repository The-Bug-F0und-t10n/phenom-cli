const std = @import("std");
const contracts = @import("contracts.zig");

pub const ToolCall = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    strategy: ?contracts.StrategyName = null,
    start_line: usize = 1,
    max_lines: usize = 12,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |path| allocator.free(path);
    }
};

pub fn parseFirst(allocator: std.mem.Allocator, output: []const u8) !?ToolCall {
    const call_start = std.mem.indexOf(u8, output, "<tool_call>") orelse return null;
    const call_end = std.mem.indexOf(u8, output[call_start..], "</tool_call>") orelse return null;
    const body = output[call_start + "<tool_call>".len .. call_start + call_end];

    const fn_marker = "<function=";
    const fn_start = std.mem.indexOf(u8, body, fn_marker) orelse return null;
    const name_start = fn_start + fn_marker.len;
    const name_end = std.mem.indexOfScalar(u8, body[name_start..], '>') orelse return null;
    const name = std.mem.trim(u8, body[name_start .. name_start + name_end], " \r\n\t");
    const path = parseParameter(body, "path");
    const strategy = try parseStrategyParameter(body);

    return .{
        .name = try allocator.dupe(u8, name),
        .path = if (path) |value| try allocator.dupe(u8, value) else null,
        .strategy = strategy,
        .start_line = parseIntParameter(body, "start_line") orelse 1,
        .max_lines = parseIntParameter(body, "max_lines") orelse 12,
    };
}

fn parseParameter(body: []const u8, comptime name: []const u8) ?[]const u8 {
    const open = "<parameter=" ++ name ++ ">";
    const close = "</parameter>";
    const start = std.mem.indexOf(u8, body, open) orelse return null;
    const value_start = start + open.len;
    const end_rel = std.mem.indexOf(u8, body[value_start..], close) orelse return null;
    return std.mem.trim(u8, body[value_start .. value_start + end_rel], " \r\n\t");
}

fn parseIntParameter(body: []const u8, comptime name: []const u8) ?usize {
    const value = parseParameter(body, name) orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn parseStrategyParameter(body: []const u8) !?contracts.StrategyName {
    const value = parseParameter(body, "strategy") orelse return null;
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "path")) return .path;
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "symbol")) return .symbol;
    if (std.mem.eql(u8, value, "diagnostic")) return .diagnostic;
    if (std.mem.eql(u8, value, "runtime")) return .runtime;
    if (std.mem.eql(u8, value, "diff")) return .diff;
    if (std.mem.eql(u8, value, "semantic")) return .semantic;
    if (std.mem.eql(u8, value, "news_table")) return .news_table;
    if (std.mem.eql(u8, value, "document_summary")) return .document_summary;
    return error.InvalidStrategy;
}

test "parses qwopus xml tool call" {
    const output =
        \\Vou consultar o arquivo.
        \\<tool_call>
        \\<function=read_file_range>
        \\<parameter=path>
        \\README.md
        \\</parameter>
        \\<parameter=start_line>
        \\2
        \\</parameter>
        \\<parameter=max_lines>
        \\5
        \\</parameter>
        \\<parameter=strategy>
        \\path
        \\</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("read_file_range", call.name);
    try std.testing.expectEqualStrings("README.md", call.path.?);
    try std.testing.expectEqual(contracts.StrategyName.path, call.strategy.?);
    try std.testing.expectEqual(@as(usize, 2), call.start_line);
    try std.testing.expectEqual(@as(usize, 5), call.max_lines);
}

test "plain text is not a tool call" {
    try std.testing.expect((try parseFirst(std.testing.allocator, "ola")) == null);
}

test "parsed tool call owns name and path" {
    var output = try std.testing.allocator.dupe(u8,
        \\<tool_call>
        \\<function=read_file_range>
        \\<parameter=path>README.md</parameter>
        \\</function>
        \\</tool_call>
    );
    defer std.testing.allocator.free(output);
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    output[16] = 'X';
    try std.testing.expectEqualStrings("read_file_range", call.name);
    try std.testing.expectEqualStrings("README.md", call.path.?);
}

test "invalid strategy is not silently converted to path" {
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>README.md</parameter>
        \\<parameter=strategy>made_up</parameter>
        \\</function>
        \\</tool_call>
    ;
    try std.testing.expectError(error.InvalidStrategy, parseFirst(std.testing.allocator, output));
}
