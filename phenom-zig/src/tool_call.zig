const std = @import("std");
const contracts = @import("contracts.zig");

pub const ToolCall = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    terms: ?[]const u8 = null,
    strategy: ?contracts.StrategyName = null,
    start_line: usize = 1,
    max_lines: usize = 12,
    compact: bool = false,
    requires_inspection: ?bool = null,
    requires_mutation: ?bool = null,
    requires_runtime_validation: ?bool = null,
    requires_browser_diagnostics: ?bool = null,
    reason: ?[]const u8 = null,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |path| allocator.free(path);
        if (self.terms) |terms| allocator.free(terms);
        if (self.reason) |reason| allocator.free(reason);
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
    const path = normalizeOptionalPath(parseParameter(body, "path"));
    const terms = normalizeOptionalText(parseParameter(body, "terms"));
    const reason = normalizeOptionalText(parseParameter(body, "reason"));
    const strategy = try parseStrategyParameter(body);

    return .{
        .name = try allocator.dupe(u8, name),
        .path = if (path) |value| try allocator.dupe(u8, value) else null,
        .terms = if (terms) |value| try allocator.dupe(u8, value) else null,
        .strategy = strategy,
        .start_line = parseIntParameter(body, "start_line") orelse 1,
        .max_lines = parseIntParameter(body, "max_lines") orelse 12,
        .compact = parseBoolParameter(body, "compact") orelse false,
        .requires_inspection = parseBoolParameter(body, "requiresInspection"),
        .requires_mutation = parseBoolParameter(body, "requiresMutation"),
        .requires_runtime_validation = parseBoolParameter(body, "requiresRuntimeValidation"),
        .requires_browser_diagnostics = parseBoolParameter(body, "requiresBrowserDiagnostics"),
        .reason = if (reason) |value| try allocator.dupe(u8, value) else null,
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

fn normalizeOptionalPath(value: ?[]const u8) ?[]const u8 {
    return normalizeOptionalText(value);
}

fn normalizeOptionalText(value: ?[]const u8) ?[]const u8 {
    const path = value orelse return null;
    if (path.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(path, "none")) return null;
    if (std.ascii.eqlIgnoreCase(path, "null")) return null;
    if (std.ascii.eqlIgnoreCase(path, "undefined")) return null;
    return path;
}

fn parseIntParameter(body: []const u8, comptime name: []const u8) ?usize {
    const value = parseParameter(body, name) orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn parseBoolParameter(body: []const u8, comptime name: []const u8) ?bool {
    const value = parseParameter(body, name) orelse return null;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return null;
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
    try std.testing.expect(call.terms == null);
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

test "collect evidence without path is parsed for repair" {
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>path</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expect(call.path == null);
    try std.testing.expectEqual(contracts.StrategyName.path, call.strategy.?);
}

test "collect evidence path none is treated as missing path" {
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>None</parameter>
        \\<parameter=strategy>auto</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expect(call.path == null);
    try std.testing.expectEqual(contracts.StrategyName.auto, call.strategy.?);
}

test "collect evidence owns model search terms" {
    var output = try std.testing.allocator.dupe(u8,
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>auto</parameter>
        \\<parameter=terms>CLI render output function</parameter>
        \\</function>
        \\</tool_call>
    );
    defer std.testing.allocator.free(output);
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    output[80] = 'X';
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expectEqualStrings("CLI render output function", call.terms.?);
}

test "collect evidence parses compact flag" {
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>auto</parameter>
        \\<parameter=terms>final narrow evidence</parameter>
        \\<parameter=compact>true</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expect(call.compact);
}

test "parses set operational contract fields and owns reason" {
    var output = try std.testing.allocator.dupe(u8,
        \\<tool_call>
        \\<function=set_operational_contract>
        \\<parameter=requiresInspection>true</parameter>
        \\<parameter=requiresMutation>true</parameter>
        \\<parameter=requiresRuntimeValidation>false</parameter>
        \\<parameter=requiresBrowserDiagnostics>false</parameter>
        \\<parameter=reason>Need focused evidence before a patch.</parameter>
        \\</function>
        \\</tool_call>
    );
    defer std.testing.allocator.free(output);
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    output[120] = 'X';
    try std.testing.expectEqualStrings("set_operational_contract", call.name);
    try std.testing.expectEqual(true, call.requires_inspection.?);
    try std.testing.expectEqual(true, call.requires_mutation.?);
    try std.testing.expectEqual(false, call.requires_runtime_validation.?);
    try std.testing.expectEqual(false, call.requires_browser_diagnostics.?);
    try std.testing.expectEqualStrings("Need focused evidence before a patch.", call.reason.?);
}
