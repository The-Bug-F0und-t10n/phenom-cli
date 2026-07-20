const std = @import("std");

const contracts = @import("contracts.zig");
const tool_call = @import("tool_call.zig");

pub const Source = enum {
    text_protocol,
};

pub const ParseStrategy = enum {
    qwopus_xml,
};

pub const State = enum {
    accepted,
    rejected,
};

pub const RejectionReason = enum {
    tool_not_advertised,
    invalid_strategy,
    parse_error,
};

pub const ToolCallEnvelope = struct {
    raw_name: []u8,
    source: Source,
    parse_strategy: ParseStrategy,
    state: State,
    contract: contracts.ContractName,
    rejection_reason: ?RejectionReason = null,
    call: ?tool_call.ToolCall = null,

    pub fn deinit(self: ToolCallEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_name);
        if (self.call) |call| call.deinit(allocator);
    }

    pub fn takeCall(self: *ToolCallEnvelope) ?tool_call.ToolCall {
        const call = self.call orelse return null;
        self.call = null;
        return call;
    }

    pub fn auditText(self: ToolCallEnvelope) []const u8 {
        return switch (self.state) {
            .accepted => "accepted",
            .rejected => switch (self.rejection_reason orelse .parse_error) {
                .tool_not_advertised => "rejected/tool_not_advertised",
                .invalid_strategy => "rejected/invalid_strategy",
                .parse_error => "rejected/parse_error",
            },
        };
    }

    pub fn renderAudit(self: ToolCallEnvelope, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "contract={s} version={s} source={s} parse={s} raw_name={s} state={s}",
            .{ @tagName(self.contract), contracts.manifest_version, @tagName(self.source), @tagName(self.parse_strategy), self.raw_name, self.auditText() },
        );
    }

    pub fn fromAcceptedCall(
        allocator: std.mem.Allocator,
        active_contract: contracts.ActiveContract,
        call: tool_call.ToolCall,
    ) !ToolCallEnvelope {
        errdefer call.deinit(allocator);
        const raw_name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(raw_name);
        return .{
            .raw_name = raw_name,
            .source = .text_protocol,
            .parse_strategy = .qwopus_xml,
            .state = .accepted,
            .contract = active_contract.name,
            .call = call,
        };
    }
};

pub fn parseFirst(
    allocator: std.mem.Allocator,
    output: []const u8,
    active_contract: contracts.ActiveContract,
) !?ToolCallEnvelope {
    const parsed = tool_call.parseFirst(allocator, output) catch |err| switch (err) {
        error.InvalidStrategy => return try rejectedParse(allocator, active_contract, .invalid_strategy),
        else => return try rejectedParse(allocator, active_contract, .parse_error),
    };
    const call = parsed orelse return null;
    errdefer call.deinit(allocator);

    if (!active_contract.allows(call.name)) {
        return try rejectedCall(allocator, active_contract, call, .tool_not_advertised);
    }
    if (call.strategy) |strategy| {
        if (!contracts.strategyAllowed(active_contract.name, strategy)) {
            return try rejectedCall(allocator, active_contract, call, .invalid_strategy);
        }
    }

    return try ToolCallEnvelope.fromAcceptedCall(allocator, active_contract, call);
}

fn rejectedCall(
    allocator: std.mem.Allocator,
    active_contract: contracts.ActiveContract,
    call: tool_call.ToolCall,
    reason: RejectionReason,
) !ToolCallEnvelope {
    const raw_name = try allocator.dupe(u8, call.name);
    call.deinit(allocator);
    return .{
        .raw_name = raw_name,
        .source = .text_protocol,
        .parse_strategy = .qwopus_xml,
        .state = .rejected,
        .contract = active_contract.name,
        .rejection_reason = reason,
    };
}

fn rejectedParse(
    allocator: std.mem.Allocator,
    active_contract: contracts.ActiveContract,
    reason: RejectionReason,
) !?ToolCallEnvelope {
    return .{
        .raw_name = try allocator.dupe(u8, "<parse_error>"),
        .source = .text_protocol,
        .parse_strategy = .qwopus_xml,
        .state = .rejected,
        .contract = active_contract.name,
        .rejection_reason = reason,
    };
}

test "announced collect evidence is accepted" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>README.md</parameter>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.accepted, envelope.state);
    try std.testing.expect(envelope.call != null);
    try std.testing.expectEqualStrings("collect_evidence", envelope.raw_name);
}

test "tool not announced is rejected before execution" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=content>
        \\<parameter=path>README.md</parameter>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.rejected, envelope.state);
    try std.testing.expectEqual(RejectionReason.tool_not_advertised, envelope.rejection_reason.?);
    try std.testing.expect(envelope.call == null);
    try std.testing.expectEqualStrings("content", envelope.raw_name);
}

test "announced session search is accepted" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=search_session>
        \\<parameter=terms>groundedness citations</parameter>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.accepted, envelope.state);
    try std.testing.expect(envelope.call != null);
    try std.testing.expectEqualStrings("search_session", envelope.raw_name);
    try std.testing.expectEqualStrings("groundedness citations", envelope.call.?.terms.?);
}

test "set operational contract is accepted as model-visible controller tool" {
    const active = contracts.activeContract(.workflow) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=set_operational_contract>
        \\<parameter=requiresInspection>true</parameter>
        \\<parameter=requiresMutation>false</parameter>
        \\<parameter=requiresRuntimeValidation>false</parameter>
        \\<parameter=requiresBrowserDiagnostics>false</parameter>
        \\<parameter=reason>Need evidence before final answer.</parameter>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.accepted, envelope.state);
    try std.testing.expect(envelope.call != null);
    try std.testing.expectEqualStrings("set_operational_contract", envelope.raw_name);
    try std.testing.expectEqual(true, envelope.call.?.requires_inspection.?);
}

test "mutation executor is rejected before contract and accepted by mutation contract" {
    const initial = contracts.activeContract(.workflow) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=apply_patch>
        \\<parameter=path>README.md</parameter>
        \\</function>
        \\</tool_call>
    ;
    var rejected = (try parseFirst(std.testing.allocator, output, initial)) orelse return error.NoToolCall;
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.rejected, rejected.state);
    try std.testing.expectEqual(RejectionReason.tool_not_advertised, rejected.rejection_reason.?);

    const mutation = contracts.activeContract(.mutate_file) orelse return error.MissingContract;
    var accepted = (try parseFirst(std.testing.allocator, output, mutation)) orelse return error.NoToolCall;
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.accepted, accepted.state);
    try std.testing.expectEqualStrings("apply_patch", accepted.raw_name);
}

test "invalid strategy is a rejected envelope" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>made_up</parameter>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.rejected, envelope.state);
    try std.testing.expectEqual(RejectionReason.invalid_strategy, envelope.rejection_reason.?);
}

test "inactive collect evidence strategy is rejected by active contract" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>semantic</parameter>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.rejected, envelope.state);
    try std.testing.expectEqual(RejectionReason.invalid_strategy, envelope.rejection_reason.?);
}

test "persistent promotion only runs under memory contract" {
    const initial = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=promote_context>
        \\<parameter=target>skills</parameter>
        \\<parameter=text>Prefer concise answers.</parameter>
        \\</function>
        \\</tool_call>
    ;
    var rejected = (try parseFirst(std.testing.allocator, output, initial)) orelse return error.NoToolCall;
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.rejected, rejected.state);
    try std.testing.expectEqual(RejectionReason.tool_not_advertised, rejected.rejection_reason.?);

    const memory = contracts.activeContract(.memory) orelse return error.MissingContract;
    var accepted = (try parseFirst(std.testing.allocator, output, memory)) orelse return error.NoToolCall;
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.accepted, accepted.state);
    try std.testing.expectEqualStrings("promote_context", accepted.raw_name);
    try std.testing.expectEqualStrings("skills", accepted.call.?.target.?);
}

test "envelope audit records contract source parser name and state" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const output =
        \\<tool_call>
        \\<function=collect_evidence>
        \\</function>
        \\</tool_call>
    ;
    var envelope = (try parseFirst(std.testing.allocator, output, active)) orelse return error.NoToolCall;
    defer envelope.deinit(std.testing.allocator);
    const audit = try envelope.renderAudit(std.testing.allocator);
    defer std.testing.allocator.free(audit);
    try std.testing.expect(std.mem.indexOf(u8, audit, "contract=collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "version=contracts.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "source=text_protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "parse=qwopus_xml") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "raw_name=collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "state=accepted") != null);
}
