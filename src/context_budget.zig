const std = @import("std");

const model_context = @import("model_context.zig");

pub const max_model_context_send_bytes: usize = 24 * 1024;

pub const Input = struct {
    rendered: []const u8,
    system_prompt_bytes: usize,
    used_tokens: ?usize = null,
    limit_tokens: ?usize = null,
    tokenizer_available: bool = false,
};

pub const Evaluation = struct {
    buckets: model_context.ContextByteBuckets,
    used_tokens: ?usize,
    limit_tokens: ?usize,
    tokenizer_available: bool,

    pub fn contextSource(self: Evaluation) []const u8 {
        if (self.used_tokens != null and self.limit_tokens != null) return "backend_tokenizer";
        if (self.limit_tokens != null) return "backend_limit";
        return "unavailable";
    }
};

pub fn evaluate(input: Input) !Evaluation {
    try model_context.assertNoRawContextLeak(input.rendered);
    var buckets = model_context.measureRenderedContextBytes(input.rendered);
    buckets.system = input.system_prompt_bytes;
    if (input.used_tokens) |used| {
        if (input.limit_tokens) |limit| {
            if (used > limit) return error.ModelContextBudgetExceeded;
        }
    } else if (input.limit_tokens == null and buckets.total_context > max_model_context_send_bytes) {
        return error.ModelContextBudgetExceeded;
    }
    return .{
        .buckets = buckets,
        .used_tokens = input.used_tokens,
        .limit_tokens = input.limit_tokens,
        .tokenizer_available = input.tokenizer_available,
    };
}

pub fn renderAuditBody(allocator: std.mem.Allocator, evaluation: Evaluation) ![]u8 {
    const used_text = try optionalUsizeText(allocator, evaluation.used_tokens);
    defer allocator.free(used_text);
    const limit_text = try optionalUsizeText(allocator, evaluation.limit_tokens);
    defer allocator.free(limit_text);
    const percent_text = try optionalPercentText(allocator, evaluation.used_tokens, evaluation.limit_tokens);
    defer allocator.free(percent_text);
    const buckets = evaluation.buckets;
    return std.fmt.allocPrint(
        allocator,
        "pre_send=true tokenizer={s} token_estimate=false context_source={s} context_used_tokens={s} context_limit_tokens={s} context_used_percent={s} system_bytes={} header_bytes={} temporal_bytes={} contracts_bytes={} skills_bytes={} memory_bytes={} candidates_bytes={} evidence_bytes={} focus_bytes={} dialogue_bytes={} session_bytes={} obligations_bytes={} grounding_bytes={} next_action_bytes={} total_context_bytes={} fallback_context_limit_bytes={}",
        .{
            if (evaluation.tokenizer_available) "backend" else "unavailable",
            evaluation.contextSource(),
            used_text,
            limit_text,
            percent_text,
            buckets.system,
            buckets.header,
            buckets.temporal,
            buckets.contracts,
            buckets.skills,
            buckets.memory,
            buckets.candidates,
            buckets.evidence,
            buckets.focus,
            buckets.dialogue,
            buckets.session,
            buckets.obligations,
            buckets.grounding,
            buckets.next_action,
            buckets.total_context,
            max_model_context_send_bytes,
        },
    );
}

fn optionalUsizeText(allocator: std.mem.Allocator, value: ?usize) ![]const u8 {
    return if (value) |actual| try std.fmt.allocPrint(allocator, "{}", .{actual}) else try allocator.dupe(u8, "unknown");
}

fn optionalPercentText(allocator: std.mem.Allocator, used_tokens: ?usize, limit_tokens: ?usize) ![]const u8 {
    const used = used_tokens orelse return allocator.dupe(u8, "unknown");
    const limit = limit_tokens orelse return allocator.dupe(u8, "unknown");
    if (limit == 0) return allocator.dupe(u8, "unknown");
    const pct = (@as(f64, @floatFromInt(used)) * 100.0) / @as(f64, @floatFromInt(limit));
    return std.fmt.allocPrint(allocator, "{d:.1}", .{pct});
}

test "context budget evaluates tokenizer and fallback limits" {
    const rendered =
        \\[TURN_CONTEXT v1]
        \\task=hello
        \\mode=code_micro
        \\budget=small
    ;
    const ok = try evaluate(.{
        .rendered = rendered,
        .system_prompt_bytes = 123,
        .used_tokens = 12,
        .limit_tokens = 64,
        .tokenizer_available = true,
    });
    try std.testing.expectEqual(@as(usize, 123), ok.buckets.system);
    try std.testing.expectEqualStrings("backend_tokenizer", ok.contextSource());

    try std.testing.expectError(error.ModelContextBudgetExceeded, evaluate(.{
        .rendered = rendered,
        .system_prompt_bytes = 123,
        .used_tokens = 65,
        .limit_tokens = 64,
    }));
}

test "context budget audit body preserves bucket fields" {
    const evaluation = try evaluate(.{
        .rendered = "[TURN_CONTEXT v1]\ntask=hello\nmode=code_micro\nbudget=small\n\n[NEXT_ACTION]\nanswer\n",
        .system_prompt_bytes = 7,
        .used_tokens = null,
        .limit_tokens = null,
    });
    const body = try renderAuditBody(std.testing.allocator, evaluation);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "context_source=unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "next_action_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fallback_context_limit_bytes=24576") != null);
}
