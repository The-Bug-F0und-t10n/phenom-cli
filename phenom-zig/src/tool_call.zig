const std = @import("std");

pub const ToolCall = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    start_line: usize = 1,
    max_lines: usize = 12,
};

pub fn parseFirst(output: []const u8) ?ToolCall {
    const call_start = std.mem.indexOf(u8, output, "<tool_call>") orelse return null;
    const call_end = std.mem.indexOf(u8, output[call_start..], "</tool_call>") orelse return null;
    const body = output[call_start + "<tool_call>".len .. call_start + call_end];

    const fn_marker = "<function=";
    const fn_start = std.mem.indexOf(u8, body, fn_marker) orelse return null;
    const name_start = fn_start + fn_marker.len;
    const name_end = std.mem.indexOfScalar(u8, body[name_start..], '>') orelse return null;
    const name = std.mem.trim(u8, body[name_start .. name_start + name_end], " \r\n\t");

    return .{
        .name = name,
        .path = parseParameter(body, "path"),
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
        \\</function>
        \\</tool_call>
    ;
    const call = parseFirst(output) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("read_file_range", call.name);
    try std.testing.expectEqualStrings("README.md", call.path.?);
    try std.testing.expectEqual(@as(usize, 2), call.start_line);
    try std.testing.expectEqual(@as(usize, 5), call.max_lines);
}

test "plain text is not a tool call" {
    try std.testing.expect(parseFirst("ola") == null);
}
