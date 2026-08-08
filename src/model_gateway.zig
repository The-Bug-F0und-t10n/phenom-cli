const std = @import("std");

const cli = @import("cli.zig");

pub const ChatRole = enum {
    user,
    assistant,
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,
};

pub const RequestInput = struct {
    model: []const u8,
    system_prompt: []const u8,
    model_context: ?[]const u8 = null,
    user_prompt: []const u8,
    dialogue: []const ChatMessage = &.{},
    max_tokens: u16 = 4096,
    thinking: cli.ThinkingMode = .auto,
};

pub const TokenUsage = struct {
    input: usize,
    output: usize,
    total: usize,
    tokens_per_second: ?f64 = null,
    final: bool = false,
};

pub const StopReason = enum {
    stop,
    length,
    unknown,
};

pub const CompletionStop = struct {
    reason: StopReason = .unknown,
};

pub const StreamLine = struct {
    reasoning_delta: ?[]u8 = null,
    visible_delta: ?[]u8 = null,
    completion_stop: ?CompletionStop = null,
    token_usage: ?TokenUsage = null,
    done: bool = false,

    pub fn deinit(self: *StreamLine, allocator: std.mem.Allocator) void {
        if (self.reasoning_delta) |delta| allocator.free(delta);
        if (self.visible_delta) |delta| allocator.free(delta);
    }

    fn hasSignal(self: StreamLine) bool {
        return self.reasoning_delta != null or
            self.visible_delta != null or
            self.completion_stop != null or
            self.token_usage != null or
            self.done;
    }
};

pub fn buildRequestBody(allocator: std.mem.Allocator, backend: cli.Backend, input: RequestInput) ![]u8 {
    const escaped_model = try jsonEscape(allocator, input.model);
    defer allocator.free(escaped_model);
    const escaped_system_prompt = try jsonEscape(allocator, input.system_prompt);
    defer allocator.free(escaped_system_prompt);
    const escaped_context = if (input.model_context) |context| try jsonEscape(allocator, context) else null;
    defer if (escaped_context) |context| allocator.free(context);
    const escaped_prompt = try jsonEscape(allocator, input.user_prompt);
    defer allocator.free(escaped_prompt);

    return switch (backend) {
        .ollama => try buildOllamaBody(
            allocator,
            escaped_model,
            escaped_system_prompt,
            escaped_context,
            escaped_prompt,
            input.dialogue,
            input.max_tokens,
        ),
        .llamacpp => try buildLlamaCppBody(
            allocator,
            escaped_model,
            escaped_system_prompt,
            escaped_context,
            escaped_prompt,
            input.dialogue,
            input.max_tokens,
            input.thinking,
        ),
    };
}

fn buildLlamaCppBody(
    allocator: std.mem.Allocator,
    escaped_model: []const u8,
    escaped_system_prompt: []const u8,
    escaped_context: ?[]const u8,
    escaped_prompt: []const u8,
    dialogue: []const ChatMessage,
    max_tokens: u16,
    thinking: cli.ThinkingMode,
) ![]u8 {
    var messages = std.ArrayList(u8).empty;
    defer messages.deinit(allocator);
    try appendJsonMessages(allocator, &messages, escaped_system_prompt, escaped_context, escaped_prompt, dialogue);
    const token_limit = if (max_tokens == 0)
        ""
    else
        try std.fmt.allocPrint(allocator, ",\"max_tokens\":{}", .{max_tokens});
    defer if (max_tokens != 0) allocator.free(token_limit);
    const thinking_option = switch (thinking) {
        .auto => "",
        .on => ",\"chat_template_kwargs\":{\"enable_thinking\":true}",
        .off => ",\"chat_template_kwargs\":{\"enable_thinking\":false}",
    };
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"stream\":true,\"messages\":[{s}]{s},\"reasoning_format\":\"none\",\"stream_options\":{{\"include_usage\":true}}{s}}}",
        .{ escaped_model, messages.items, thinking_option, token_limit },
    );
}

fn buildOllamaBody(
    allocator: std.mem.Allocator,
    escaped_model: []const u8,
    escaped_system_prompt: []const u8,
    escaped_context: ?[]const u8,
    escaped_prompt: []const u8,
    dialogue: []const ChatMessage,
    max_tokens: u16,
) ![]u8 {
    var messages = std.ArrayList(u8).empty;
    defer messages.deinit(allocator);
    try appendJsonMessages(allocator, &messages, escaped_system_prompt, escaped_context, escaped_prompt, dialogue);
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"stream\":true,\"messages\":[{s}],\"options\":{{\"temperature\":0.2,\"num_predict\":{}}}}}",
        .{ escaped_model, messages.items, generationTokenLimit(max_tokens) },
    );
}

fn appendJsonMessages(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(u8),
    escaped_system_prompt: []const u8,
    escaped_context: ?[]const u8,
    escaped_prompt: []const u8,
    dialogue: []const ChatMessage,
) !void {
    try messages.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
    try messages.appendSlice(allocator, escaped_system_prompt);
    if (escaped_context) |context| {
        try messages.appendSlice(allocator, "\\n\\n");
        try messages.appendSlice(allocator, context);
    }
    try messages.appendSlice(allocator, "\"}");
    for (dialogue) |message| {
        const escaped = try jsonEscape(allocator, message.content);
        defer allocator.free(escaped);
        try messages.appendSlice(allocator, ",{\"role\":\"");
        try messages.appendSlice(allocator, chatRoleName(message.role));
        try messages.appendSlice(allocator, "\",\"content\":\"");
        try messages.appendSlice(allocator, escaped);
        try messages.appendSlice(allocator, "\"}");
    }
    try messages.appendSlice(allocator, ",{\"role\":\"user\",\"content\":\"");
    try messages.appendSlice(allocator, escaped_prompt);
    try messages.appendSlice(allocator, "\"}");
}

fn generationTokenLimit(max_tokens: u16) i32 {
    return if (max_tokens == 0) -1 else @intCast(max_tokens);
}

pub fn buildLlamaCppPrompt(allocator: std.mem.Allocator, input: RequestInput, generation_prefix: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<|im_start|>system\n");
    try out.appendSlice(allocator, input.system_prompt);
    if (input.model_context) |context| {
        try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, context);
    }
    try out.appendSlice(allocator, "<|im_end|>\n");
    for (input.dialogue) |message| {
        try appendChatMessage(&out, allocator, message.role, message.content);
    }
    try appendChatMessage(&out, allocator, .user, input.user_prompt);
    try out.appendSlice(allocator, "<|im_start|>assistant\n");
    try out.appendSlice(allocator, generation_prefix);
    return out.toOwnedSlice(allocator);
}

fn appendChatMessage(out: *std.ArrayList(u8), allocator: std.mem.Allocator, role: ChatRole, content: []const u8) !void {
    try out.appendSlice(allocator, "<|im_start|>");
    try out.appendSlice(allocator, chatRoleName(role));
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, content);
    try out.appendSlice(allocator, "<|im_end|>\n");
}

fn chatRoleName(role: ChatRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
    };
}

pub fn parseStreamLine(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
    backend: cli.Backend,
) !StreamLine {
    const normalized = normalizeStreamLine(raw_line) orelse return .{};
    if (normalized.done_marker) return .{ .done = true };
    return switch (backend) {
        .ollama => parseOllamaStreamJson(allocator, normalized.json_line),
        .llamacpp => parseLlamaCppStreamJson(allocator, normalized.json_line),
    };
}

pub fn parseAnyStreamLine(allocator: std.mem.Allocator, raw_line: []const u8) !StreamLine {
    const normalized = normalizeStreamLine(raw_line) orelse return .{};
    if (normalized.done_marker) return .{ .done = true };
    if (normalized.sse) return parseLlamaCppStreamJson(allocator, normalized.json_line);

    var ollama = try parseOllamaStreamJson(allocator, normalized.json_line);
    if (ollama.hasSignal()) return ollama;
    ollama.deinit(allocator);
    return parseLlamaCppStreamJson(allocator, normalized.json_line);
}

const NormalizedStreamLine = struct {
    json_line: []const u8 = "",
    done_marker: bool = false,
    sse: bool = false,
};

fn normalizeStreamLine(raw_line: []const u8) ?NormalizedStreamLine {
    const line = std.mem.trim(u8, raw_line, " \r\t");
    if (line.len == 0) return null;
    if (std.mem.eql(u8, line, "data: [DONE]")) return .{ .done_marker = true, .sse = true };
    if (std.mem.startsWith(u8, line, "data:")) {
        return .{
            .json_line = std.mem.trim(u8, line[5..], " \t"),
            .sse = true,
        };
    }
    return .{ .json_line = line };
}

fn parseOllamaStreamJson(allocator: std.mem.Allocator, json_line: []const u8) !StreamLine {
    var line = StreamLine{};
    errdefer line.deinit(allocator);

    if (extractJsonStringField(json_line, "content") orelse extractJsonStringField(json_line, "response")) |content| {
        line.visible_delta = try jsonUnescape(allocator, content);
    }
    line.done = jsonBoolTrueField(json_line, "done");
    if (line.done) line.completion_stop = completionStopFromLine(json_line);
    line.token_usage = extractOllamaTokenUsage(json_line, line.done);
    return line;
}

fn parseLlamaCppStreamJson(allocator: std.mem.Allocator, json_line: []const u8) !StreamLine {
    var line = StreamLine{};
    errdefer line.deinit(allocator);

    if (extractJsonStringField(json_line, "reasoning_content")) |reasoning| {
        line.reasoning_delta = try jsonUnescape(allocator, reasoning);
    }
    if (extractJsonStringField(json_line, "content")) |content| {
        line.visible_delta = try jsonUnescape(allocator, content);
    }
    line.done = jsonBoolTrueField(json_line, "stop") or hasFinishReason(json_line);
    if (line.done) line.completion_stop = completionStopFromLine(json_line);
    line.token_usage = extractLlamaCppTokenUsage(json_line, line.done);
    return line;
}

fn extractOllamaTokenUsage(line: []const u8, final: bool) ?TokenUsage {
    return tokenUsageFromFields(line, final, &.{"prompt_eval_count"}, &.{"eval_count"});
}

fn extractLlamaCppTokenUsage(line: []const u8, final: bool) ?TokenUsage {
    return tokenUsageFromFields(
        line,
        final,
        &.{ "prompt_tokens", "tokens_evaluated", "n_prompt_tokens", "prompt_n" },
        &.{ "completion_tokens", "tokens_predicted", "predicted_n" },
    );
}

pub fn extractAnyTokenUsage(line: []const u8, final: bool) ?TokenUsage {
    return tokenUsageFromFields(
        line,
        final,
        &.{ "prompt_eval_count", "prompt_tokens", "tokens_evaluated", "n_prompt_tokens", "prompt_n" },
        &.{ "eval_count", "completion_tokens", "tokens_predicted", "predicted_n" },
    );
}

fn tokenUsageFromFields(
    line: []const u8,
    final: bool,
    input_fields: []const []const u8,
    output_fields: []const []const u8,
) ?TokenUsage {
    const input = firstUsizeField(line, input_fields) orelse return null;
    const output = firstUsizeField(line, output_fields) orelse return null;
    const total = std.math.add(usize, input, output) catch return null;
    const tps = extractJsonF64Field(line, "predicted_per_second") orelse
        tokensPerSecondFromEvalDuration(output, extractJsonU64Field(line, "eval_duration"));
    return .{
        .input = input,
        .output = output,
        .total = total,
        .tokens_per_second = tps,
        .final = final,
    };
}

fn firstUsizeField(line: []const u8, fields: []const []const u8) ?usize {
    for (fields) |field| {
        if (extractJsonUsizeField(line, field)) |value| return value;
    }
    return null;
}

fn tokensPerSecondFromEvalDuration(output: usize, duration_ns: ?u64) ?f64 {
    const ns = duration_ns orelse return null;
    if (output == 0 or ns == 0) return null;
    const seconds = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    if (seconds <= 0) return null;
    return @as(f64, @floatFromInt(output)) / seconds;
}

fn hasFinishReason(line: []const u8) bool {
    const value = extractJsonStringField(line, "finish_reason") orelse return false;
    return !std.mem.eql(u8, value, "null") and value.len > 0;
}

fn completionStopFromLine(line: []const u8) CompletionStop {
    if (jsonBoolTrueField(line, "stopped_limit") or jsonBoolTrueField(line, "truncated")) return .{ .reason = .length };
    if (extractJsonStringField(line, "stop_type")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "limit") or std.ascii.eqlIgnoreCase(value, "length")) return .{ .reason = .length };
        if (std.ascii.eqlIgnoreCase(value, "eos") or std.ascii.eqlIgnoreCase(value, "word") or std.ascii.eqlIgnoreCase(value, "stop")) return .{ .reason = .stop };
    }
    if (extractJsonStringField(line, "done_reason")) |value| return .{ .reason = stopReasonFromText(value) };
    if (extractJsonStringField(line, "finish_reason")) |value| return .{ .reason = stopReasonFromText(value) };
    return .{};
}

fn stopReasonFromText(value: []const u8) StopReason {
    if (std.ascii.eqlIgnoreCase(value, "length") or std.ascii.eqlIgnoreCase(value, "max_tokens") or std.ascii.eqlIgnoreCase(value, "limit")) return .length;
    if (std.ascii.eqlIgnoreCase(value, "stop") or std.ascii.eqlIgnoreCase(value, "eos")) return .stop;
    return .unknown;
}

pub fn extractJsonUsizeField(line: []const u8, field: []const u8) ?usize {
    const value = extractJsonU64Field(line, field) orelse return null;
    return std.math.cast(usize, value);
}

pub fn extractJsonU64Field(line: []const u8, field: []const u8) ?u64 {
    const number = extractJsonNumberSlice(line, field) orelse return null;
    return std.fmt.parseInt(u64, number, 10) catch null;
}

pub fn extractJsonF64Field(line: []const u8, field: []const u8) ?f64 {
    const number = extractJsonNumberSlice(line, field) orelse return null;
    return std.fmt.parseFloat(f64, number) catch null;
}

fn extractJsonNumberSlice(line: []const u8, field: []const u8) ?[]const u8 {
    var i = jsonFieldValueStart(line, field) orelse return null;
    const value_start = i;
    if (i < line.len and line[i] == '-') return null;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (!std.ascii.isDigit(ch) and ch != '.') break;
    }
    if (i == value_start) return null;
    return line[value_start..i];
}

pub fn extractJsonStringField(line: []const u8, field: []const u8) ?[]const u8 {
    var i = jsonFieldValueStart(line, field) orelse return null;
    if (i >= line.len or line[i] != '"') return null;
    i += 1;
    const value_start = i;
    while (i < line.len) : (i += 1) {
        if (line[i] == '"' and (i == value_start or line[i - 1] != '\\')) return line[value_start..i];
    }
    return null;
}

pub fn jsonBoolTrueField(line: []const u8, field: []const u8) bool {
    const i = jsonFieldValueStart(line, field) orelse return false;
    return std.mem.startsWith(u8, line[i..], "true");
}

fn jsonFieldValueStart(line: []const u8, field: []const u8) ?usize {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 2 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + field.len], field);
    needle_buf[1 + field.len] = '"';
    const needle = needle_buf[0 .. field.len + 2];

    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = start + needle.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r')) : (i += 1) {}
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r')) : (i += 1) {}
    return i;
}

pub fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch < 0x20 and ch != '\n' and ch != '\r' and ch != '\t') {
            try appendJsonByteEscape(allocator, &out, ch);
            i += 1;
            continue;
        }
        switch (ch) {
            '\\' => {
                try out.appendSlice(allocator, "\\\\");
                i += 1;
            },
            '"' => {
                try out.appendSlice(allocator, "\\\"");
                i += 1;
            },
            '\n' => {
                try out.appendSlice(allocator, "\\n");
                i += 1;
            },
            '\r' => {
                try out.appendSlice(allocator, "\\r");
                i += 1;
            },
            '\t' => {
                try out.appendSlice(allocator, "\\t");
                i += 1;
            },
            0x80...0xff => {
                const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    try out.appendSlice(allocator, "\\uFFFD");
                    i += 1;
                    continue;
                };
                const end = i + len;
                if (end > text.len) {
                    try out.appendSlice(allocator, "\\uFFFD");
                    i += 1;
                    continue;
                }
                _ = std.unicode.utf8Decode(text[i..end]) catch {
                    try out.appendSlice(allocator, "\\uFFFD");
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, text[i..end]);
                i = end;
            },
            else => {
                try out.append(allocator, ch);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendJsonByteEscape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) !void {
    const hex = "0123456789abcdef";
    try out.appendSlice(allocator, "\\u00");
    try out.append(allocator, hex[byte >> 4]);
    try out.append(allocator, hex[byte & 0x0f]);
}

pub fn jsonUnescape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try out.append(allocator, text[i]);
            continue;
        }

        i += 1;
        if (i >= text.len) {
            try out.append(allocator, '\\');
            break;
        }

        switch (text[i]) {
            '\\' => try out.append(allocator, '\\'),
            '"' => try out.append(allocator, '"'),
            '/' => try out.append(allocator, '/'),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0c),
            'u' => {
                if (i + 4 >= text.len) return error.InvalidUnicodeEscape;
                const code = try std.fmt.parseInt(u21, text[i + 1 .. i + 5], 16);
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(code, &buf);
                try out.appendSlice(allocator, buf[0..len]);
                i += 4;
            },
            else => |ch| try out.append(allocator, ch),
        }
    }

    return out.toOwnedSlice(allocator);
}

test "ollama adapter normalizes visible delta and final usage" {
    var line = try parseStreamLine(std.testing.allocator, "{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":true,\"prompt_eval_count\":10,\"eval_count\":20,\"eval_duration\":2000000000}", .ollama);
    defer line.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ok", line.visible_delta.?);
    try std.testing.expect(line.done);
    try std.testing.expectEqual(@as(usize, 10), line.token_usage.?.input);
    try std.testing.expectEqual(@as(usize, 20), line.token_usage.?.output);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), line.token_usage.?.tokens_per_second.?, 0.001);
    try std.testing.expect(line.token_usage.?.final);
}

test "llamacpp adapter normalizes reasoning visible stop and usage" {
    var line = try parseStreamLine(std.testing.allocator, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"pensando\",\"content\":\"resposta\"},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}", .llamacpp);
    defer line.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("pensando", line.reasoning_delta.?);
    try std.testing.expectEqualStrings("resposta", line.visible_delta.?);
    try std.testing.expect(line.done);
    try std.testing.expectEqual(StopReason.length, line.completion_stop.?.reason);
    try std.testing.expectEqual(@as(usize, 3), line.token_usage.?.input);
    try std.testing.expectEqual(@as(usize, 1), line.token_usage.?.output);
}

test "sse done marker becomes normalized completion" {
    const line = try parseStreamLine(std.testing.allocator, "data: [DONE]", .llamacpp);
    try std.testing.expect(line.done);
    try std.testing.expect(line.visible_delta == null);
    try std.testing.expect(line.completion_stop == null);
}

test "request adapters build backend-specific chat bodies" {
    const dialogue = [_]ChatMessage{
        .{ .role = .user, .content = "pergunta antiga" },
        .{ .role = .assistant, .content = "resposta antiga" },
    };
    const base = RequestInput{
        .model = "phenom:latest",
        .system_prompt = "SYSTEM",
        .model_context = "[TURN_CONTEXT v1]",
        .user_prompt = "ola",
        .dialogue = &dialogue,
        .max_tokens = 96,
        .thinking = .off,
    };

    const ollama = try buildRequestBody(std.testing.allocator, .ollama, base);
    defer std.testing.allocator.free(ollama);
    try std.testing.expect(std.mem.indexOf(u8, ollama, "\"num_predict\":96") != null);
    try std.testing.expect(std.mem.indexOf(u8, ollama, "\"role\":\"assistant\"") != null);

    const llama = try buildRequestBody(std.testing.allocator, .llamacpp, base);
    defer std.testing.allocator.free(llama);
    try std.testing.expect(std.mem.indexOf(u8, llama, "\"max_tokens\":96") != null);
    try std.testing.expect(std.mem.indexOf(u8, llama, "\"enable_thinking\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, llama, "\"reasoning_format\":\"none\"") != null);
}

test "llamacpp prompt adapter preserves raw roles for tokenizer accounting" {
    const dialogue = [_]ChatMessage{.{ .role = .assistant, .content = "resposta anterior" }};
    const prompt = try buildLlamaCppPrompt(std.testing.allocator, .{
        .model = "phenom:latest",
        .system_prompt = "SYSTEM",
        .model_context = "CONTEXT",
        .user_prompt = "agora",
        .dialogue = &dialogue,
    }, "<think>\n");
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "<|im_start|>system") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<|im_start|>assistant\nresposta anterior") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "<think>\n"));
}
