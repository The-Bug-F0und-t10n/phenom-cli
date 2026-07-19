const std = @import("std");
const contracts = @import("contracts.zig");

pub const ToolCall = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    session: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    need: ?[]const u8 = null,
    terms: ?[]const u8 = null,
    target_files: ?[]const u8 = null,
    scope_root: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    selected_candidate: ?[]const u8 = null,
    selected_candidates: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    context_ids: []const []const u8 = &.{},
    search: ?[]const u8 = null,
    searches: []const []const u8 = &.{},
    replace: ?[]const u8 = null,
    replaces: []const []const u8 = &.{},
    destination_path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    target: ?[]const u8 = null,
    text: ?[]const u8 = null,
    strategy: ?contracts.StrategyName = null,
    start_line: usize = 1,
    max_lines: usize = 12,
    compact: bool = false,
    requires_inspection: ?bool = null,
    requires_mutation: ?bool = null,
    requires_runtime_validation: ?bool = null,
    requires_browser_diagnostics: ?bool = null,
    requires_memory_promotion: ?bool = null,
    reason: ?[]const u8 = null,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |path| allocator.free(path);
        if (self.session) |session| allocator.free(session);
        if (self.scope) |scope| allocator.free(scope);
        if (self.intent) |intent| allocator.free(intent);
        if (self.need) |need| allocator.free(need);
        if (self.terms) |terms| allocator.free(terms);
        if (self.target_files) |target_files| allocator.free(target_files);
        if (self.scope_root) |scope_root| allocator.free(scope_root);
        if (self.stage) |stage| allocator.free(stage);
        if (self.selected_candidate) |selected_candidate| allocator.free(selected_candidate);
        if (self.selected_candidates) |selected_candidates| allocator.free(selected_candidates);
        if (self.operation) |operation| allocator.free(operation);
        if (self.context_id) |context_id| allocator.free(context_id);
        freeParamList(allocator, self.context_ids);
        if (self.search) |search| allocator.free(search);
        freeParamList(allocator, self.searches);
        if (self.replace) |replace| allocator.free(replace);
        freeParamList(allocator, self.replaces);
        if (self.destination_path) |destination_path| allocator.free(destination_path);
        if (self.content) |content| allocator.free(content);
        if (self.target) |target| allocator.free(target);
        if (self.text) |text| allocator.free(text);
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
    const session = normalizeOptionalText(parseParameter(body, "session"));
    const scope = normalizeOptionalText(parseParameter(body, "scope"));
    const intent = normalizeOptionalText(parseParameter(body, "intent"));
    const need = normalizeOptionalText(parseParameter(body, "need"));
    const terms = normalizeOptionalText(parseParameter(body, "terms"));
    const target_files = normalizeOptionalText(parseParameter(body, "targetFiles") orelse parseParameter(body, "target_files"));
    const scope_root = normalizeOptionalText(parseParameter(body, "scopeRoot") orelse parseParameter(body, "scope_root"));
    const stage = normalizeOptionalText(parseParameter(body, "stage"));
    const selected_candidate = normalizeOptionalText(parseParameter(body, "selectedCandidate") orelse parseParameter(body, "selected_candidate"));
    const selected_candidates = normalizeOptionalText(parseParameter(body, "selectedCandidates") orelse parseParameter(body, "selected_candidates"));
    const operation = normalizeOptionalText(parseParameter(body, "operation"));
    const context_id = normalizeOptionalText(parseParameter(body, "contextId") orelse parseParameter(body, "context_id"));
    const context_ids = try parseAllParameters(allocator, body, &.{ "contextId", "context_id" }, false);
    errdefer freeParamList(allocator, context_ids);
    const search = normalizeOptionalText(parseParameter(body, "search"));
    const searches = try parseAllParameters(allocator, body, &.{"search"}, false);
    errdefer freeParamList(allocator, searches);
    const replace = normalizeOptionalReplace(parseParameter(body, "replace"));
    const replaces = try parseAllParameters(allocator, body, &.{"replace"}, true);
    errdefer freeParamList(allocator, replaces);
    const destination_path = normalizeOptionalPath(parseParameter(body, "destinationPath") orelse parseParameter(body, "destination_path") orelse parseParameter(body, "destPath") orelse parseParameter(body, "dest"));
    const content = normalizeOptionalContent(parseParameter(body, "content"));
    const target = normalizeOptionalText(parseParameter(body, "target"));
    const text = normalizeOptionalText(parseParameter(body, "text"));
    const reason = normalizeOptionalText(parseParameter(body, "reason"));
    const strategy = try parseStrategyParameter(body);

    return .{
        .name = try allocator.dupe(u8, name),
        .path = if (path) |value| try allocator.dupe(u8, value) else null,
        .session = if (session) |value| try allocator.dupe(u8, value) else null,
        .scope = if (scope) |value| try allocator.dupe(u8, value) else null,
        .intent = if (intent) |value| try allocator.dupe(u8, value) else null,
        .need = if (need) |value| try allocator.dupe(u8, value) else null,
        .terms = if (terms) |value| try allocator.dupe(u8, value) else null,
        .target_files = if (target_files) |value| try allocator.dupe(u8, value) else null,
        .scope_root = if (scope_root) |value| try allocator.dupe(u8, value) else null,
        .stage = if (stage) |value| try allocator.dupe(u8, value) else null,
        .selected_candidate = if (selected_candidate) |value| try allocator.dupe(u8, value) else null,
        .selected_candidates = if (selected_candidates) |value| try allocator.dupe(u8, value) else null,
        .operation = if (operation) |value| try allocator.dupe(u8, value) else null,
        .context_id = if (context_id) |value| try allocator.dupe(u8, value) else null,
        .context_ids = context_ids,
        .search = if (search) |value| try allocator.dupe(u8, value) else null,
        .searches = searches,
        .replace = if (replace) |value| try allocator.dupe(u8, value) else null,
        .replaces = replaces,
        .destination_path = if (destination_path) |value| try allocator.dupe(u8, value) else null,
        .content = if (content) |value| try allocator.dupe(u8, value) else null,
        .target = if (target) |value| try allocator.dupe(u8, value) else null,
        .text = if (text) |value| try allocator.dupe(u8, value) else null,
        .strategy = strategy,
        .start_line = parseIntParameter(body, "start_line") orelse 1,
        .max_lines = parseIntParameter(body, "max_lines") orelse 12,
        .compact = parseBoolParameter(body, "compact") orelse false,
        .requires_inspection = parseBoolParameter(body, "requiresInspection"),
        .requires_mutation = parseBoolParameter(body, "requiresMutation"),
        .requires_runtime_validation = parseBoolParameter(body, "requiresRuntimeValidation"),
        .requires_browser_diagnostics = parseBoolParameter(body, "requiresBrowserDiagnostics"),
        .requires_memory_promotion = parseBoolParameter(body, "requiresMemoryPromotion"),
        .reason = if (reason) |value| try allocator.dupe(u8, value) else null,
    };
}

fn freeParamList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn parseParameter(body: []const u8, comptime name: []const u8) ?[]const u8 {
    const open = "<parameter=" ++ name ++ ">";
    const close = "</parameter>";
    const start = std.mem.indexOf(u8, body, open) orelse return null;
    const value_start = start + open.len;
    const end_rel = std.mem.indexOf(u8, body[value_start..], close) orelse return null;
    return std.mem.trim(u8, body[value_start .. value_start + end_rel], " \r\n\t");
}

fn parseAllParameters(
    allocator: std.mem.Allocator,
    body: []const u8,
    comptime names: []const []const u8,
    comptime keep_empty: bool,
) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |value| allocator.free(value);
        out.deinit(allocator);
    }

    inline for (names) |name| {
        const open = "<parameter=" ++ name ++ ">";
        const close = "</parameter>";
        var offset: usize = 0;
        while (std.mem.indexOf(u8, body[offset..], open)) |rel_start| {
            const start = offset + rel_start;
            const value_start = start + open.len;
            const end_rel = std.mem.indexOf(u8, body[value_start..], close) orelse break;
            const raw = std.mem.trim(u8, body[value_start .. value_start + end_rel], " \r\n\t");
            if (keep_empty or normalizeOptionalText(raw) != null) {
                try out.append(allocator, try allocator.dupe(u8, raw));
            }
            offset = value_start + end_rel + close.len;
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn normalizeOptionalPath(value: ?[]const u8) ?[]const u8 {
    return normalizeOptionalText(value);
}

fn normalizeOptionalReplace(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (std.ascii.eqlIgnoreCase(text, "null")) return null;
    if (std.ascii.eqlIgnoreCase(text, "undefined")) return null;
    return text;
}

fn normalizeOptionalContent(value: ?[]const u8) ?[]const u8 {
    return normalizeOptionalReplace(value);
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
        \\<parameter=intent>find CLI renderer implementation</parameter>
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
    try std.testing.expectEqualStrings("find CLI renderer implementation", call.intent.?);
    try std.testing.expectEqualStrings("CLI render output function", call.terms.?);
}

test "search session parses model-selected scope and session" {
    var output = try std.testing.allocator.dupe(u8,
        \\<tool_call>
        \\<function=search_session>
        \\<parameter=intent>recover prior layout decision</parameter>
        \\<parameter=terms>layout w-90 bootstrap</parameter>
        \\<parameter=scope>all</parameter>
        \\<parameter=session>old-session</parameter>
        \\</function>
        \\</tool_call>
    );
    defer std.testing.allocator.free(output);
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    output[80] = 'X';
    try std.testing.expectEqualStrings("search_session", call.name);
    try std.testing.expectEqualStrings("recover prior layout decision", call.intent.?);
    try std.testing.expectEqualStrings("layout w-90 bootstrap", call.terms.?);
    try std.testing.expectEqualStrings("all", call.scope.?);
    try std.testing.expectEqualStrings("old-session", call.session.?);
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

test "collect evidence parses definition candidate stage fields" {
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=stage>expand</parameter>
        \\<parameter=selectedCandidate>C2</parameter>
        \\<parameter=max_lines>32</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expectEqualStrings("expand", call.stage.?);
    try std.testing.expectEqualStrings("C2", call.selected_candidate.?);
    try std.testing.expectEqual(@as(usize, 32), call.max_lines);
}

test "collect evidence parses v2 search fields and plural selected candidates" {
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=intent>find patch target</parameter>
        \\<parameter=need>minimal editable range</parameter>
        \\<parameter=targetFiles>src/main.zig src/contracts.zig</parameter>
        \\<parameter=scopeRoot>src</parameter>
        \\<parameter=terms>apply_patch contract</parameter>
        \\<parameter=stage>minimum</parameter>
        \\<parameter=selectedCandidates>C2,C3</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("find patch target", call.intent.?);
    try std.testing.expectEqualStrings("minimal editable range", call.need.?);
    try std.testing.expectEqualStrings("src/main.zig src/contracts.zig", call.target_files.?);
    try std.testing.expectEqualStrings("src", call.scope_root.?);
    try std.testing.expectEqualStrings("apply_patch contract", call.terms.?);
    try std.testing.expectEqualStrings("minimum", call.stage.?);
    try std.testing.expectEqualStrings("C2,C3", call.selected_candidates.?);
}

test "apply patch parses context id search and replace" {
    const output =
        \\<tool_call>
        \\<function=apply_patch>
        \\<parameter=path>src/main.zig</parameter>
        \\<parameter=contextId>ctx_abcdef</parameter>
        \\<parameter=search>old text</parameter>
        \\<parameter=replace>new text</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("apply_patch", call.name);
    try std.testing.expectEqualStrings("src/main.zig", call.path.?);
    try std.testing.expectEqualStrings("ctx_abcdef", call.context_id.?);
    try std.testing.expectEqualStrings("old text", call.search.?);
    try std.testing.expectEqualStrings("new text", call.replace.?);
}

test "apply patch parses operation repeated hunks destination and content" {
    const output =
        \\<tool_call>
        \\<function=apply_patch>
        \\<parameter=operation>edit</parameter>
        \\<parameter=path>src/main.zig</parameter>
        \\<parameter=contextId>ctx_1</parameter>
        \\<parameter=search>old one</parameter>
        \\<parameter=replace>new one</parameter>
        \\<parameter=contextId>ctx_2</parameter>
        \\<parameter=search>old two</parameter>
        \\<parameter=replace></parameter>
        \\<parameter=destinationPath>src/renamed.zig</parameter>
        \\<parameter=content>pub fn main() void {}</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("edit", call.operation.?);
    try std.testing.expectEqualStrings("src/renamed.zig", call.destination_path.?);
    try std.testing.expectEqualStrings("pub fn main() void {}", call.content.?);
    try std.testing.expectEqual(@as(usize, 2), call.context_ids.len);
    try std.testing.expectEqual(@as(usize, 2), call.searches.len);
    try std.testing.expectEqual(@as(usize, 2), call.replaces.len);
    try std.testing.expectEqualStrings("ctx_1", call.context_ids[0]);
    try std.testing.expectEqualStrings("ctx_2", call.context_ids[1]);
    try std.testing.expectEqualStrings("", call.replaces[1]);
}

test "parses set operational contract fields and owns reason" {
    var output = try std.testing.allocator.dupe(u8,
        \\<tool_call>
        \\<function=set_operational_contract>
        \\<parameter=requiresInspection>true</parameter>
        \\<parameter=requiresMutation>true</parameter>
        \\<parameter=requiresRuntimeValidation>false</parameter>
        \\<parameter=requiresBrowserDiagnostics>false</parameter>
        \\<parameter=requiresMemoryPromotion>true</parameter>
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
    try std.testing.expectEqual(true, call.requires_memory_promotion.?);
    try std.testing.expectEqualStrings("Need focused evidence before a patch.", call.reason.?);
}

test "promote context parses target and text" {
    const output =
        \\<tool_call>
        \\<function=promote_context>
        \\<parameter=target>skills</parameter>
        \\<parameter=text>Prefer concise final answers.</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try parseFirst(std.testing.allocator, output)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("promote_context", call.name);
    try std.testing.expectEqualStrings("skills", call.target.?);
    try std.testing.expectEqualStrings("Prefer concise final answers.", call.text.?);
}
