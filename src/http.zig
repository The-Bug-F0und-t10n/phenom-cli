const std = @import("std");
const cli = @import("cli.zig");
const system_prompt = @import("system_prompt.zig");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("netinet/in.h");
    @cInclude("poll.h");
    @cInclude("sys/socket.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const LocalModelClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    backend: cli.Backend,
    model: []const u8,
    thinking: cli.ThinkingMode = .auto,
    last_http_status: ?u16 = null,
    last_http_body_snippet: ?[]u8 = null,
    context_window: ?usize = null,
    tokenizer_available: bool = false,

    pub fn deinit(self: *LocalModelClient) void {
        self.clearLastHttpFailure();
    }

    pub fn defaultPort(backend: cli.Backend) u16 {
        return if (backend == .ollama) 11434 else 8080;
    }

    pub fn pathForBackend(backend: cli.Backend) []const u8 {
        return if (backend == .ollama) "/api/chat" else "/v1/chat/completions";
    }

    pub fn endpointSummary(self: *LocalModelClient, allocator: std.mem.Allocator) ![]u8 {
        const parsed = try parseHost(allocator, self.host, self.backend);
        defer parsed.deinit(allocator);
        return std.fmt.allocPrint(
            allocator,
            "http://{s}:{}{s}",
            .{ parsed.host, parsed.port, pathForBackend(self.backend) },
        );
    }

    pub fn probeMetadata(self: *LocalModelClient, allocator: std.mem.Allocator, baseline_text: []const u8) BackendMetadata {
        return switch (self.backend) {
            .llamacpp => probeLlamaCppMetadata(self, allocator, baseline_text),
            .ollama => probeOllamaMetadata(self, allocator),
        };
    }

    pub fn rememberMetadata(self: *LocalModelClient, metadata: BackendMetadata) void {
        self.context_window = metadata.context_window;
        self.tokenizer_available = std.mem.eql(u8, metadata.tokenizer, "available");
    }

    pub fn countInputTokens(self: *LocalModelClient, input: InferenceInput) ?usize {
        if (self.backend != .llamacpp or !self.tokenizer_available) return null;
        const stable_context = if (input.model_context) |context| stripVolatileTurnContextForPrompt(self.allocator, context) catch return null else null;
        defer if (stable_context) |context| self.allocator.free(context);
        var stable_input = input;
        stable_input.model_context = stable_context;
        const generation_prefix = switch (self.thinking) {
            .on => "<think>\n",
            .off => "<think>\n\n</think>\n\n",
            .auto => "",
        };
        const chat_prompt = self.buildLlamaCppPrompt(stable_input, generation_prefix) catch return null;
        defer self.allocator.free(chat_prompt);
        return self.countTextTokens(chat_prompt);
    }

    pub fn streamChat(
        self: *LocalModelClient,
        prompt: []const u8,
        sink: anytype,
    ) !void {
        try self.streamInference(.{ .user_prompt = prompt }, sink);
    }

    pub fn streamInference(
        self: *LocalModelClient,
        input: InferenceInput,
        sink: anytype,
    ) !void {
        self.clearLastHttpFailure();
        const parsed = try parseHost(self.allocator, self.host, self.backend);
        defer parsed.deinit(self.allocator);

        const fd = try tcpConnect(self.allocator, parsed.host, parsed.port);
        defer _ = c.close(fd);

        const body = try self.buildBodyForInput(input);
        defer self.allocator.free(body);

        const path = pathForBackend(self.backend);
        const request = try std.fmt.allocPrint(
            self.allocator,
            "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nAccept: */*\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{s}",
            .{ path, parsed.host, body.len, body },
        );
        defer self.allocator.free(request);
        try writeAll(fd, request);

        var header_buffer = std.ArrayList(u8).empty;
        defer header_buffer.deinit(self.allocator);
        var chunk_buffer = std.ArrayList(u8).empty;
        defer chunk_buffer.deinit(self.allocator);
        var line_buffer = std.ArrayList(u8).empty;
        defer line_buffer.deinit(self.allocator);

        var headers_done = false;
        var chunked = false;
        var buf: [4096]u8 = undefined;
        var cancel_input = StreamCancelInput{};
        while (true) {
            try waitReadableOrCancelled(fd, input.cancel, input.cancel_fd, &cancel_input);
            const n_raw = c.read(fd, &buf, buf.len);
            if (n_raw < 0) return error.SocketReadFailed;
            const n: usize = @intCast(n_raw);
            if (n == 0) break;
            var data = buf[0..n];

            if (!headers_done) {
                try header_buffer.appendSlice(self.allocator, data);
                if (findHeaderEnd(header_buffer.items)) |idx| {
                    const headers = header_buffer.items[0..idx];
                    try self.ensureStatusOkWithBody(fd, headers, header_buffer.items[idx + 4 ..]);
                    chunked = hasChunkedTransfer(headers);
                    headers_done = true;
                    data = header_buffer.items[idx + 4 ..];
                } else {
                    continue;
                }
            }

            if (data.len == 0) continue;
            if (chunked) {
                if (try feedChunked(self.allocator, &chunk_buffer, data, &line_buffer, sink)) break;
            } else {
                if (try feedLines(self.allocator, &line_buffer, data, sink)) break;
            }
        }

        _ = try flushLine(self.allocator, &line_buffer, sink);
    }

    fn buildBody(self: *LocalModelClient, prompt: []const u8) ![]u8 {
        return self.buildBodyForInput(.{ .user_prompt = prompt });
    }

    fn countTextTokens(self: *LocalModelClient, text: []const u8) ?usize {
        const parsed = parseHost(self.allocator, self.host, self.backend) catch return null;
        defer parsed.deinit(self.allocator);
        const escaped = jsonEscape(self.allocator, text) catch return null;
        defer self.allocator.free(escaped);
        const body = std.fmt.allocPrint(self.allocator, "{{\"content\":\"{s}\"}}", .{escaped}) catch return null;
        defer self.allocator.free(body);
        const response = requestHttp(self.allocator, parsed.host, parsed.port, "POST", "/tokenize", body, tokenizeResponseLimit(self.context_window)) catch return null;
        defer response.deinit(self.allocator);
        if (response.status < 200 or response.status >= 300) return null;
        return parseTokenizeCount(response.body);
    }

    pub fn httpFailureDetail(self: *LocalModelClient, allocator: std.mem.Allocator) !?[]u8 {
        const status = self.last_http_status orelse {
            if (self.last_http_body_snippet) |body| {
                return try std.fmt.allocPrint(allocator, "body=\"{s}\"", .{body});
            }
            return null;
        };
        if (self.last_http_body_snippet) |body| {
            return try std.fmt.allocPrint(allocator, "status={} body=\"{s}\"", .{ status, body });
        }
        return try std.fmt.allocPrint(allocator, "status={}", .{status});
    }

    fn clearLastHttpFailure(self: *LocalModelClient) void {
        self.last_http_status = null;
        if (self.last_http_body_snippet) |body| {
            self.allocator.free(body);
            self.last_http_body_snippet = null;
        }
    }

    fn ensureStatusOkWithBody(self: *LocalModelClient, fd: c_int, headers: []const u8, initial_body: []const u8) !void {
        const status = try parseHttpStatus(headers);
        if (status >= 200 and status < 300) return;
        self.last_http_status = status;
        self.last_http_body_snippet = try readFailureBodySnippet(self.allocator, fd, initial_body, 512);
        return error.HttpStatusNotOk;
    }

    fn buildBodyForInput(self: *LocalModelClient, input: InferenceInput) ![]u8 {
        const escaped_prompt = try jsonEscape(self.allocator, input.user_prompt);
        defer self.allocator.free(escaped_prompt);
        const selected_system_prompt = input.system_prompt orelse system_prompt.default_system_prompt;
        const escaped_system_prompt = try jsonEscape(self.allocator, selected_system_prompt);
        defer self.allocator.free(escaped_system_prompt);
        const stable_context = if (input.model_context) |context| try stripVolatileTurnContextForPrompt(self.allocator, context) else null;
        defer if (stable_context) |context| self.allocator.free(context);
        var stable_input = input;
        stable_input.model_context = stable_context;
        const escaped_context = if (stable_context) |context| try jsonEscape(self.allocator, context) else null;
        defer if (escaped_context) |context| self.allocator.free(context);
        const escaped_model = try jsonEscape(self.allocator, self.model);
        defer self.allocator.free(escaped_model);

        return switch (self.backend) {
            .ollama => try self.buildOllamaBody(escaped_model, escaped_system_prompt, escaped_context, escaped_prompt, input.dialogue, input.max_tokens),
            .llamacpp => try self.buildLlamaCppBody(
                escaped_model,
                escaped_system_prompt,
                escaped_context,
                escaped_prompt,
                input.dialogue,
                input.max_tokens,
                self.thinking,
            ),
        };
    }

    fn buildLlamaCppBody(
        self: *LocalModelClient,
        escaped_model: []const u8,
        escaped_system_prompt: []const u8,
        escaped_context: ?[]const u8,
        escaped_prompt: []const u8,
        dialogue: []const ChatMessage,
        max_tokens: u16,
        thinking: cli.ThinkingMode,
    ) ![]u8 {
        var messages = std.ArrayList(u8).empty;
        defer messages.deinit(self.allocator);
        try appendJsonMessages(self.allocator, &messages, escaped_system_prompt, escaped_context, escaped_prompt, dialogue);
        const token_limit = if (max_tokens == 0)
            ""
        else
            try std.fmt.allocPrint(self.allocator, ",\"max_tokens\":{}", .{max_tokens});
        defer if (max_tokens != 0) self.allocator.free(token_limit);
        const thinking_option = switch (thinking) {
            .auto => "",
            .on => ",\"chat_template_kwargs\":{\"enable_thinking\":true}",
            .off => ",\"chat_template_kwargs\":{\"enable_thinking\":false}",
        };
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"model\":\"{s}\",\"stream\":true,\"messages\":[{s}]{s},\"reasoning_format\":\"none\",\"stream_options\":{{\"include_usage\":true}}{s}}}",
            .{ escaped_model, messages.items, thinking_option, token_limit },
        );
    }

    fn buildOllamaBody(self: *LocalModelClient, escaped_model: []const u8, escaped_system_prompt: []const u8, escaped_context: ?[]const u8, escaped_prompt: []const u8, dialogue: []const ChatMessage, max_tokens: u16) ![]u8 {
        var messages = std.ArrayList(u8).empty;
        defer messages.deinit(self.allocator);
        try appendJsonMessages(self.allocator, &messages, escaped_system_prompt, escaped_context, escaped_prompt, dialogue);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"model\":\"{s}\",\"stream\":true,\"messages\":[{s}],\"options\":{{\"temperature\":0.2,\"num_predict\":{}}}}}",
            .{ escaped_model, messages.items, generationTokenLimit(max_tokens) },
        );
    }

    fn appendJsonMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(u8), escaped_system_prompt: []const u8, escaped_context: ?[]const u8, escaped_prompt: []const u8, dialogue: []const ChatMessage) !void {
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

    fn buildLlamaCppPrompt(self: *LocalModelClient, input: InferenceInput, generation_prefix: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "<|im_start|>system\n");
        try out.appendSlice(self.allocator, input.system_prompt orelse system_prompt.default_system_prompt);
        if (input.model_context) |context| {
            try out.appendSlice(self.allocator, "\n\n");
            try out.appendSlice(self.allocator, context);
        }
        try out.appendSlice(self.allocator, "<|im_end|>\n");
        for (input.dialogue) |message| {
            try appendChatMessage(&out, self.allocator, message.role, message.content);
        }
        try appendChatMessage(&out, self.allocator, .user, input.user_prompt);
        try out.appendSlice(self.allocator, "<|im_start|>assistant\n");
        try out.appendSlice(self.allocator, generation_prefix);
        return out.toOwnedSlice(self.allocator);
    }
};

pub const RuntimeHttpResult = struct {
    target: []const u8,
    status: ?u16,
    server: ?[]const u8,
    body_snippet: []const u8,
    error_name: ?[]const u8 = null,

    pub fn deinit(self: RuntimeHttpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.server) |server| allocator.free(server);
        allocator.free(self.body_snippet);
    }
};

pub const BackendMetadata = struct {
    source: []const u8,
    tokenizer: []const u8,
    schema_baseline_tokens: ?usize,
    context_window: ?usize,
    detail: []const u8,

    pub fn deinit(self: BackendMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.tokenizer);
        allocator.free(self.detail);
    }
};

pub fn inspectHttpGet(allocator: std.mem.Allocator, target: []const u8) RuntimeHttpResult {
    return inspectHttpGetLimit(allocator, target, 2048);
}

pub fn inspectHttpGetLimit(allocator: std.mem.Allocator, target: []const u8, body_limit: usize) RuntimeHttpResult {
    return inspectHttpGetLimitCancel(allocator, target, body_limit, null);
}

pub fn inspectHttpGetLimitCancel(allocator: std.mem.Allocator, target: []const u8, body_limit: usize, cancel: ?*std.atomic.Value(bool)) RuntimeHttpResult {
    const parsed = parseHttpTarget(allocator, target) catch |err| {
        const normalized_target = if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://"))
            allocator.dupe(u8, target) catch unreachable
        else
            std.fmt.allocPrint(allocator, "http://{s}", .{target}) catch unreachable;
        return .{
            .target = normalized_target,
            .status = null,
            .server = null,
            .body_snippet = allocator.dupe(u8, "") catch unreachable,
            .error_name = @errorName(err),
        };
    };
    defer parsed.deinit(allocator);
    const normalized = parsed.render(allocator) catch unreachable;
    const response = requestHttpCancel(allocator, parsed.host, parsed.port, "GET", parsed.path, null, body_limit, cancel) catch |err| {
        return .{
            .target = normalized,
            .status = null,
            .server = null,
            .body_snippet = allocator.dupe(u8, "") catch unreachable,
            .error_name = @errorName(err),
        };
    };
    return .{
        .target = normalized,
        .status = response.status,
        .server = response.server,
        .body_snippet = response.body,
        .error_name = null,
    };
}

fn stripVolatileTurnContextForPrompt(allocator: std.mem.Allocator, context: []const u8) ![]u8 {
    const without_task = try stripTurnContextTaskLine(allocator, context);
    defer allocator.free(without_task);
    return removeTurnContextSection(allocator, without_task, "\n[RECENT_DIALOGUE]\n");
}

fn stripTurnContextTaskLine(allocator: std.mem.Allocator, context: []const u8) ![]u8 {
    const marker = "[TURN_CONTEXT v1]\n";
    if (!std.mem.startsWith(u8, context, marker)) return allocator.dupe(u8, context);
    if (!std.mem.startsWith(u8, context[marker.len..], "task: ")) return allocator.dupe(u8, context);
    const mode_marker = "\nmode: ";
    const mode_at = std.mem.indexOfPos(u8, context, marker.len, mode_marker) orelse {
        const next_line = std.mem.indexOfPos(u8, context, marker.len, "\n") orelse return allocator.dupe(u8, context);
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, marker);
        try out.appendSlice(allocator, context[next_line + 1 ..]);
        return out.toOwnedSlice(allocator);
    };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, marker);
    try out.appendSlice(allocator, context[mode_at + 1 ..]);
    return out.toOwnedSlice(allocator);
}

fn removeTurnContextSection(allocator: std.mem.Allocator, context: []const u8, marker: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, context, marker) orelse return allocator.dupe(u8, context);
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
    var end = context.len;
    for (markers) |next_marker| {
        const idx = std.mem.indexOfPos(u8, context, start + marker.len, next_marker) orelse continue;
        end = @min(end, idx);
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, context[0..start]);
    try out.appendSlice(allocator, context[end..]);
    return out.toOwnedSlice(allocator);
}

pub const ChatRole = enum {
    user,
    assistant,
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,
};

pub const InferenceInput = struct {
    user_prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    model_context: ?[]const u8 = null,
    dialogue: []const ChatMessage = &.{},
    max_tokens: u16 = 4096,
    cancel: ?*std.atomic.Value(bool) = null,
    cancel_fd: ?c_int = null,
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

pub const ProbeResult = struct {
    endpoint: []const u8,
    tcp_ok: bool,
    http_ok: bool,
    status: ?u16,
    server: ?[]const u8,
    error_name: ?[]const u8,

    pub fn deinit(self: ProbeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.endpoint);
        if (self.server) |server| allocator.free(server);
    }
};

pub const BackendFailureKind = enum {
    connect,
    http_status,
    protocol_parse,
    model_empty,
    model_think_only,
    stream_cancelled,
    stream_read,
    stream_write,
    unknown,
};

pub fn classifyStreamFailure(err: anyerror, status: ?u16) BackendFailureKind {
    if (status != null or err == error.HttpStatusNotOk) return .http_status;
    return switch (err) {
        error.GetAddrInfoFailed,
        error.ConnectFailed,
        error.SocketCreateFailed,
        error.InvalidIpv4Address,
        => .connect,

        error.SocketReadFailed,
        error.HttpHeadersMissing,
        error.HttpHeadersTooLarge,
        => .stream_read,

        error.SocketWriteFailed => .stream_write,

        error.InvalidHttpResponse,
        error.InvalidCharacter,
        error.Overflow,
        error.UnexpectedEndOfInput,
        => .protocol_parse,

        error.Cancelled => .stream_cancelled,
        else => .unknown,
    };
}

pub fn classifyModelOutput(stop_reason: StopReason, visible_bytes: usize, thinking_bytes: usize) ?BackendFailureKind {
    if (visible_bytes > 0) return null;
    if (thinking_bytes > 0) return .model_think_only;
    _ = stop_reason;
    return .model_empty;
}

pub fn probeBackend(allocator: std.mem.Allocator, host: []const u8, backend: cli.Backend) ProbeResult {
    const parsed = parseHost(allocator, host, backend) catch |err| {
        return .{
            .endpoint = std.fmt.allocPrint(allocator, "invalid-host:{s}", .{host}) catch unreachable,
            .tcp_ok = false,
            .http_ok = false,
            .status = null,
            .server = null,
            .error_name = @errorName(err),
        };
    };
    defer parsed.deinit(allocator);
    const path = probePathForBackend(backend);
    const endpoint = std.fmt.allocPrint(allocator, "http://{s}:{}{s}", .{ parsed.host, parsed.port, path }) catch unreachable;

    const fd = tcpConnect(allocator, parsed.host, parsed.port) catch |err| {
        return .{
            .endpoint = endpoint,
            .tcp_ok = false,
            .http_ok = false,
            .status = null,
            .server = null,
            .error_name = @errorName(err),
        };
    };
    defer _ = c.close(fd);

    const request = std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        .{ path, parsed.host },
    ) catch |err| {
        return .{
            .endpoint = endpoint,
            .tcp_ok = true,
            .http_ok = false,
            .status = null,
            .server = null,
            .error_name = @errorName(err),
        };
    };
    defer allocator.free(request);

    writeAll(fd, request) catch |err| {
        return .{
            .endpoint = endpoint,
            .tcp_ok = true,
            .http_ok = false,
            .status = null,
            .server = null,
            .error_name = @errorName(err),
        };
    };

    var header_buffer = std.ArrayList(u8).empty;
    defer header_buffer.deinit(allocator);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n_raw = c.read(fd, &buf, buf.len);
        if (n_raw < 0) {
            return .{
                .endpoint = endpoint,
                .tcp_ok = true,
                .http_ok = false,
                .status = null,
                .server = null,
                .error_name = "SocketReadFailed",
            };
        }
        const n: usize = @intCast(n_raw);
        if (n == 0) {
            return .{
                .endpoint = endpoint,
                .tcp_ok = true,
                .http_ok = false,
                .status = null,
                .server = null,
                .error_name = "HttpHeadersMissing",
            };
        }
        header_buffer.appendSlice(allocator, buf[0..n]) catch |err| {
            return .{
                .endpoint = endpoint,
                .tcp_ok = true,
                .http_ok = false,
                .status = null,
                .server = null,
                .error_name = @errorName(err),
            };
        };
        if (findHeaderEnd(header_buffer.items)) |idx| {
            const headers = header_buffer.items[0..idx];
            const status = parseHttpStatus(headers) catch null;
            const server = extractHeaderValue(allocator, headers, "Server") catch null;
            return .{
                .endpoint = endpoint,
                .tcp_ok = true,
                .http_ok = if (status) |code| code >= 200 and code < 300 else false,
                .status = status,
                .server = server,
                .error_name = null,
            };
        }
        if (header_buffer.items.len > 32 * 1024) {
            return .{
                .endpoint = endpoint,
                .tcp_ok = true,
                .http_ok = false,
                .status = null,
                .server = null,
                .error_name = "HttpHeadersTooLarge",
            };
        }
    }
}

fn probePathForBackend(backend: cli.Backend) []const u8 {
    return if (backend == .ollama) "/api/tags" else "/";
}

pub fn resolveThinking(mode: cli.ThinkingMode) cli.ThinkingMode {
    return mode;
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

const ParsedHost = struct {
    host: []const u8,
    port: u16,

    fn deinit(self: ParsedHost, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }
};

const ParsedHttpTarget = struct {
    host: []const u8,
    port: u16,
    path: []const u8,

    fn deinit(self: ParsedHttpTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }

    fn render(self: ParsedHttpTarget, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{s}:{}{s}", .{ self.host, self.port, self.path });
    }
};

fn parseHost(allocator: std.mem.Allocator, host: []const u8, backend: cli.Backend) !ParsedHost {
    var normalized = host;
    if (std.mem.startsWith(u8, normalized, "http://")) {
        normalized = normalized["http://".len..];
    }
    if (std.mem.endsWith(u8, normalized, "/")) {
        normalized = normalized[0 .. normalized.len - 1];
    }
    if (std.mem.indexOfScalar(u8, normalized, ':')) |idx| {
        return .{
            .host = try allocator.dupe(u8, normalized[0..idx]),
            .port = try std.fmt.parseInt(u16, normalized[idx + 1 ..], 10),
        };
    }
    return .{ .host = try allocator.dupe(u8, normalized), .port = LocalModelClient.defaultPort(backend) };
}

fn parseHttpTarget(allocator: std.mem.Allocator, raw_target: []const u8) !ParsedHttpTarget {
    var target = std.mem.trim(u8, raw_target, " \t\r\n");
    if (target.len == 0) return error.InvalidRuntimeTarget;
    if (std.mem.startsWith(u8, target, "https://")) return error.TlsRuntimeInspectionUnsupported;
    if (std.mem.startsWith(u8, target, "http://")) target = target["http://".len..];
    const slash = std.mem.indexOfScalar(u8, target, '/') orelse target.len;
    const authority = target[0..slash];
    if (authority.len == 0) return error.InvalidRuntimeTarget;
    const path_raw = if (slash < target.len) target[slash..] else "/";
    var port: u16 = 80;
    const host_part = if (std.mem.indexOfScalar(u8, authority, ':')) |idx| blk: {
        port = try std.fmt.parseInt(u16, authority[idx + 1 ..], 10);
        break :blk authority[0..idx];
    } else authority;
    if (host_part.len == 0) return error.InvalidRuntimeTarget;
    return .{
        .host = try allocator.dupe(u8, host_part),
        .port = port,
        .path = try allocator.dupe(u8, path_raw),
    };
}

const HttpResponse = struct {
    status: u16,
    server: ?[]const u8,
    body: []const u8,

    fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        if (self.server) |server| allocator.free(server);
        allocator.free(self.body);
    }
};

fn requestHttp(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    body_limit: usize,
) !HttpResponse {
    return requestHttpCancel(allocator, host, port, method, path, body, body_limit, null);
}

fn requestHttpCancel(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    body_limit: usize,
    cancel: ?*std.atomic.Value(bool),
) !HttpResponse {
    if (isCancelled(cancel)) return error.Cancelled;
    const fd = try tcpConnect(allocator, host, port);
    defer _ = c.close(fd);
    const request = if (body) |payload|
        try std.fmt.allocPrint(
            allocator,
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nAccept: */*\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{s}",
            .{ method, path, host, payload.len, payload },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\nAccept: */*\r\nConnection: close\r\n\r\n",
            .{ method, path, host },
        );
    defer allocator.free(request);
    try writeAll(fd, request);

    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);
    var buf: [2048]u8 = undefined;
    var cancel_input = StreamCancelInput{};
    while (response.items.len < body_limit + 32 * 1024) {
        try waitReadableOrCancelled(fd, cancel, null, &cancel_input);
        const n_raw = c.read(fd, &buf, buf.len);
        if (n_raw < 0) return error.SocketReadFailed;
        const n: usize = @intCast(n_raw);
        if (n == 0) break;
        try response.appendSlice(allocator, buf[0..n]);
    }
    const header_end = findHeaderEnd(response.items) orelse return error.HttpHeadersMissing;
    const headers = response.items[0..header_end];
    const status = try parseHttpStatus(headers);
    const server = extractHeaderValue(allocator, headers, "Server") catch null;
    errdefer if (server) |value| allocator.free(value);
    var body_out = std.ArrayList(u8).empty;
    errdefer body_out.deinit(allocator);
    try appendSanitizedSnippet(allocator, &body_out, response.items[header_end + 4 ..], body_limit);
    return .{ .status = status, .server = server, .body = try body_out.toOwnedSlice(allocator) };
}

fn probeLlamaCppMetadata(client: *LocalModelClient, allocator: std.mem.Allocator, baseline_text: []const u8) BackendMetadata {
    const parsed = parseHost(allocator, client.host, client.backend) catch |err| {
        return metadataUnavailable(allocator, "llamacpp", @errorName(err));
    };
    defer parsed.deinit(allocator);

    var context_window: ?usize = null;
    var detail = std.ArrayList(u8).empty;
    defer detail.deinit(allocator);
    if (requestHttp(allocator, parsed.host, parsed.port, "GET", "/props", null, 8192)) |props| {
        defer props.deinit(allocator);
        context_window = firstJsonUnsigned(props.body, &.{ "n_ctx", "n_ctx_train", "context_length" });
        detail.appendSlice(allocator, "props=ok") catch {};
    } else |err| {
        appendFmt(allocator, &detail, "props_error={s}", .{@errorName(err)}) catch {};
    }

    const escaped = jsonEscape(allocator, baseline_text) catch return metadataUnavailable(allocator, "llamacpp", "json_escape_failed");
    defer allocator.free(escaped);
    const body = std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{escaped}) catch return metadataUnavailable(allocator, "llamacpp", "alloc_failed");
    defer allocator.free(body);
    var tokenizer: []const u8 = "unavailable";
    var baseline_tokens: ?usize = null;
    if (requestHttp(allocator, parsed.host, parsed.port, "POST", "/tokenize", body, tokenizeResponseLimit(context_window))) |tok| {
        defer tok.deinit(allocator);
        if (tok.status >= 200 and tok.status < 300) {
            baseline_tokens = parseTokenizeCount(tok.body);
            tokenizer = if (baseline_tokens != null) "available" else "unavailable";
            detail.appendSlice(allocator, " tokenize=ok") catch {};
        } else {
            appendFmt(allocator, &detail, " tokenize_status={}", .{tok.status}) catch {};
        }
    } else |err| {
        appendFmt(allocator, &detail, " tokenize_error={s}", .{@errorName(err)}) catch {};
    }

    return .{
        .source = allocator.dupe(u8, "llamacpp") catch unreachable,
        .tokenizer = allocator.dupe(u8, tokenizer) catch unreachable,
        .schema_baseline_tokens = baseline_tokens,
        .context_window = context_window,
        .detail = detail.toOwnedSlice(allocator) catch unreachable,
    };
}

fn probeOllamaMetadata(client: *LocalModelClient, allocator: std.mem.Allocator) BackendMetadata {
    const parsed = parseHost(allocator, client.host, client.backend) catch |err| {
        return metadataUnavailable(allocator, "ollama", @errorName(err));
    };
    defer parsed.deinit(allocator);
    const escaped_model = jsonEscape(allocator, client.model) catch return metadataUnavailable(allocator, "ollama", "json_escape_failed");
    defer allocator.free(escaped_model);
    const body = std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\"}}", .{escaped_model}) catch return metadataUnavailable(allocator, "ollama", "alloc_failed");
    defer allocator.free(body);
    var context_window: ?usize = null;
    var detail = std.ArrayList(u8).empty;
    defer detail.deinit(allocator);
    if (requestHttp(allocator, parsed.host, parsed.port, "POST", "/api/show", body, 8192)) |show| {
        defer show.deinit(allocator);
        context_window = firstJsonUnsigned(show.body, &.{ "context_length", "num_ctx", "llama.context_length" });
        appendFmt(allocator, &detail, "show_status={}", .{show.status}) catch {};
    } else |err| {
        appendFmt(allocator, &detail, "show_error={s}", .{@errorName(err)}) catch {};
    }
    return .{
        .source = allocator.dupe(u8, "ollama") catch unreachable,
        .tokenizer = allocator.dupe(u8, "unavailable") catch unreachable,
        .schema_baseline_tokens = null,
        .context_window = context_window,
        .detail = detail.toOwnedSlice(allocator) catch unreachable,
    };
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn metadataUnavailable(allocator: std.mem.Allocator, source: []const u8, detail: []const u8) BackendMetadata {
    return .{
        .source = allocator.dupe(u8, source) catch unreachable,
        .tokenizer = allocator.dupe(u8, "unavailable") catch unreachable,
        .schema_baseline_tokens = null,
        .context_window = null,
        .detail = allocator.dupe(u8, detail) catch unreachable,
    };
}

fn firstJsonUnsigned(json: []const u8, comptime keys: []const []const u8) ?usize {
    inline for (keys) |key| {
        if (jsonUnsignedAfterKey(json, key)) |value| return value;
    }
    return null;
}

fn jsonUnsignedAfterKey(json: []const u8, key: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const colon_rel = std.mem.indexOfScalar(u8, json[idx + key.len ..], ':') orelse return null;
    var pos = idx + key.len + colon_rel + 1;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '"')) : (pos += 1) {}
    const start = pos;
    while (pos < json.len and std.ascii.isDigit(json[pos])) : (pos += 1) {}
    if (pos == start) return null;
    return std.fmt.parseInt(usize, json[start..pos], 10) catch null;
}

fn parseTokenizeCount(json: []const u8) ?usize {
    if (jsonUnsignedAfterKey(json, "n_tokens")) |value| return value;
    const marker = "\"tokens\"";
    const idx = std.mem.indexOf(u8, json, marker) orelse return null;
    const open_rel = std.mem.indexOfScalar(u8, json[idx + marker.len ..], '[') orelse return null;
    var pos = idx + marker.len + open_rel + 1;
    var count: usize = 0;
    var in_number = false;
    while (pos < json.len) : (pos += 1) {
        const byte = json[pos];
        if (byte == ']') {
            if (in_number) count += 1;
            return count;
        }
        if (std.ascii.isDigit(byte) or byte == '-') {
            in_number = true;
            continue;
        }
        if (in_number) {
            count += 1;
            in_number = false;
        }
    }
    return null;
}

fn tokenizeResponseLimit(context_window: ?usize) usize {
    const floor: usize = 64 * 1024;
    const ceiling: usize = 16 * 1024 * 1024;
    const window = context_window orelse 4096;
    if (window > (ceiling / 16)) return ceiling;
    return @max(floor, @min(ceiling, window * 16));
}

fn tcpConnect(allocator: std.mem.Allocator, host: []const u8, port: u16) !c_int {
    if (try tcpConnectIpv4Literal(allocator, host, port)) |fd| return fd;

    const z_host = try allocator.dupeZ(u8, host);
    defer allocator.free(z_host);
    var port_buf: [16]u8 = undefined;
    const z_port = try std.fmt.bufPrintZ(&port_buf, "{}", .{port});

    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;

    var result: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(z_host.ptr, z_port.ptr, &hints, &result) != 0) return error.GetAddrInfoFailed;
    defer c.freeaddrinfo(result);

    var it = result;
    while (it) |addr| : (it = addr.ai_next) {
        const fd = c.socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);
        if (fd < 0) continue;
        if (c.connect(fd, addr.ai_addr, addr.ai_addrlen) == 0) return fd;
        _ = c.close(fd);
    }
    return error.ConnectFailed;
}

fn tcpConnectIpv4Literal(allocator: std.mem.Allocator, host: []const u8, port: u16) !?c_int {
    const z_host = try allocator.dupeZ(u8, host);
    defer allocator.free(z_host);

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    const parsed = c.inet_pton(c.AF_INET, z_host.ptr, &addr.sin_addr);
    if (parsed == 0) return null;
    if (parsed < 0) return error.InvalidIpv4Address;

    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = c.close(fd);

    const sockaddr: *c.struct_sockaddr = @ptrCast(&addr);
    if (c.connect(fd, sockaddr, @sizeOf(c.struct_sockaddr_in)) != 0) return error.ConnectFailed;
    return fd;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n_raw = c.write(fd, rest.ptr, rest.len);
        if (n_raw < 0) return error.SocketWriteFailed;
        const n: usize = @intCast(n_raw);
        rest = rest[n..];
    }
}

fn findHeaderEnd(response: []const u8) ?usize {
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |idx| return idx;
    return null;
}

fn hasChunkedTransfer(headers: []const u8) bool {
    return std.mem.indexOf(u8, headers, "Transfer-Encoding: chunked") != null or
        std.mem.indexOf(u8, headers, "transfer-encoding: chunked") != null;
}

fn ensureStatusOk(headers: []const u8) !void {
    const status = try parseHttpStatus(headers);
    if (status < 200 or status >= 300) return error.HttpStatusNotOk;
}

fn readFailureBodySnippet(allocator: std.mem.Allocator, fd: c_int, initial_body: []const u8, max_len: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendSanitizedSnippet(allocator, &out, initial_body, max_len);
    var buf: [256]u8 = undefined;
    while (out.items.len < max_len) {
        const n_raw = c.read(fd, &buf, @min(buf.len, max_len - out.items.len));
        if (n_raw < 0) return error.SocketReadFailed;
        const n: usize = @intCast(n_raw);
        if (n == 0) break;
        try appendSanitizedSnippet(allocator, &out, buf[0..n], max_len);
    }
    return out.toOwnedSlice(allocator);
}

fn appendSanitizedSnippet(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8, max_len: usize) !void {
    for (bytes) |byte| {
        if (out.items.len >= max_len) break;
        const safe = if (byte == '\r' or byte == '\n' or byte == '\t')
            ' '
        else switch (byte) {
            0...31, 127 => '?',
            else => byte,
        };
        try out.append(allocator, safe);
    }
}

fn isCancelled(cancel: ?*std.atomic.Value(bool)) bool {
    const token = cancel orelse return false;
    return token.load(.acquire);
}

const stream_esc_cancel_delay_ms: i64 = 100;

const StreamCancelInput = struct {
    pending_esc: bool = false,
    pending_started_ms: i64 = 0,

    fn feed(self: *StreamCancelInput, data: []const u8, now_ms: i64) bool {
        if (self.flushExpired(now_ms)) return true;
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            const ch = data[i];
            if (self.pending_esc) {
                self.pending_esc = false;
                if (ch == '[' or ch == 'O') continue;
                return true;
            }
            if (ch == 0x03) return true;
            if (ch != '\x1b') continue;
            if (i + 1 >= data.len) {
                self.pending_esc = true;
                self.pending_started_ms = now_ms;
                return false;
            }
            const next = data[i + 1];
            if (next == '[' or next == 'O') {
                i += 1;
                continue;
            }
            return true;
        }
        return false;
    }

    fn flushExpired(self: *StreamCancelInput, now_ms: i64) bool {
        if (!self.pending_esc) return false;
        if (now_ms - self.pending_started_ms < stream_esc_cancel_delay_ms) return false;
        self.pending_esc = false;
        return true;
    }
};

fn waitReadableOrCancelled(fd: c_int, cancel: ?*std.atomic.Value(bool), cancel_fd: ?c_int, cancel_input: *StreamCancelInput) !void {
    var cancel_buf: [32]u8 = undefined;
    while (true) {
        if (isCancelled(cancel)) return error.Cancelled;
        if (cancel_input.flushExpired(monotonicMs())) return error.Cancelled;
        var pfds = [_]c.pollfd{
            .{
                .fd = fd,
                .events = c.POLLIN,
                .revents = 0,
            },
            .{
                .fd = cancel_fd orelse -1,
                .events = c.POLLIN,
                .revents = 0,
            },
        };
        const count: c.nfds_t = if (cancel_fd == null) 1 else 2;
        const rc = c.poll(&pfds, count, 25);
        if (rc < 0) return error.SocketReadFailed;
        if (rc == 0) continue;
        if (cancel_fd != null and (pfds[1].revents & c.POLLIN) != 0) {
            const n_raw = c.read(pfds[1].fd, &cancel_buf, cancel_buf.len);
            if (n_raw > 0) {
                const n: usize = @intCast(n_raw);
                if (cancel_input.feed(cancel_buf[0..n], monotonicMs())) return error.Cancelled;
            }
        }
        if (isCancelled(cancel)) return error.Cancelled;
        if ((pfds[0].revents & c.POLLIN) != 0) return;
        if ((pfds[0].revents & (c.POLLHUP | c.POLLERR)) != 0) return;
    }
}

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

fn waitReadableOrCancelledForTest(fd: c_int, cancel: ?*std.atomic.Value(bool)) !void {
    var cancel_input = StreamCancelInput{};
    return waitReadableOrCancelled(fd, cancel, null, &cancel_input);
}

fn parseHttpStatus(headers: []const u8) !u16 {
    const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse headers.len;
    const first_line = headers[0..first_line_end];
    if (!std.mem.startsWith(u8, first_line, "HTTP/")) return error.InvalidHttpResponse;
    const first_space = std.mem.indexOfScalar(u8, first_line, ' ') orelse return error.InvalidHttpResponse;
    if (first_line.len < first_space + 4) return error.InvalidHttpResponse;
    return std.fmt.parseInt(u16, first_line[first_space + 1 .. first_space + 4], 10);
}

fn extractHeaderValue(allocator: std.mem.Allocator, headers: []const u8, name: []const u8) !?[]const u8 {
    var start: usize = 0;
    while (start < headers.len) {
        const rel_end = std.mem.indexOf(u8, headers[start..], "\r\n") orelse headers.len - start;
        const line = headers[start .. start + rel_end];
        if (line.len > name.len + 1 and std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            const value = std.mem.trim(u8, line[name.len + 1 ..], " \t");
            return try allocator.dupe(u8, value);
        }
        start += rel_end + 2;
    }
    return null;
}

fn feedChunked(
    allocator: std.mem.Allocator,
    chunk_buffer: *std.ArrayList(u8),
    data: []const u8,
    line_buffer: *std.ArrayList(u8),
    sink: anytype,
) !bool {
    try chunk_buffer.appendSlice(allocator, data);
    while (chunk_buffer.items.len > 0) {
        const line_end = std.mem.indexOf(u8, chunk_buffer.items, "\r\n") orelse break;
        const size_text = chunk_buffer.items[0..line_end];
        const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const size = try std.fmt.parseInt(usize, size_text[0..semi], 16);
        if (size == 0) return true;
        const start = line_end + 2;
        const end = start + size;
        if (chunk_buffer.items.len < end + 2) break;
        if (try feedLines(allocator, line_buffer, chunk_buffer.items[start..end], sink)) return true;
        const consumed = end + 2;
        const remaining = chunk_buffer.items.len - consumed;
        std.mem.copyForwards(u8, chunk_buffer.items[0..remaining], chunk_buffer.items[consumed..]);
        chunk_buffer.shrinkRetainingCapacity(remaining);
    }
    return false;
}

fn feedLines(
    allocator: std.mem.Allocator,
    line_buffer: *std.ArrayList(u8),
    data: []const u8,
    sink: anytype,
) !bool {
    try line_buffer.appendSlice(allocator, data);
    while (std.mem.indexOfScalar(u8, line_buffer.items, '\n')) |idx| {
        const done = try processModelLine(allocator, line_buffer.items[0..idx], sink);
        const consumed = idx + 1;
        const remaining = line_buffer.items.len - consumed;
        std.mem.copyForwards(u8, line_buffer.items[0..remaining], line_buffer.items[consumed..]);
        line_buffer.shrinkRetainingCapacity(remaining);
        if (done) return true;
    }
    return false;
}

fn flushLine(allocator: std.mem.Allocator, line_buffer: *std.ArrayList(u8), sink: anytype) !bool {
    if (line_buffer.items.len == 0) return false;
    const done = try processModelLine(allocator, line_buffer.items, sink);
    line_buffer.clearRetainingCapacity();
    return done;
}

fn processModelLine(allocator: std.mem.Allocator, raw_line: []const u8, sink: anytype) !bool {
    const line = std.mem.trim(u8, raw_line, " \r\t");
    if (line.len == 0) return false;
    if (std.mem.eql(u8, line, "data: [DONE]")) return true;
    const json_line = if (std.mem.startsWith(u8, line, "data:")) std.mem.trim(u8, line[5..], " \t") else line;
    if (extractJsonStringField(json_line, "reasoning_content")) |reasoning| {
        const decoded = try jsonUnescape(allocator, reasoning);
        defer allocator.free(decoded);
        try emitReasoningDelta(sink, decoded);
    }
    if (extractJsonStringField(json_line, "content")) |content| {
        const decoded = try jsonUnescape(allocator, content);
        defer allocator.free(decoded);
        try sink.onDelta(decoded);
    } else if (extractJsonStringField(json_line, "response")) |response| {
        const decoded = try jsonUnescape(allocator, response);
        defer allocator.free(decoded);
        try sink.onDelta(decoded);
    }
    const done = jsonBoolTrueField(json_line, "stop") or jsonBoolTrueField(json_line, "done") or hasFinishReason(json_line);
    if (done) try emitCompletionStop(sink, completionStopFromLine(json_line));
    if (extractTokenUsage(json_line, done)) |usage| try emitTokenUsage(sink, usage);
    return done;
}

fn emitReasoningDelta(sink: anytype, reasoning: []const u8) !void {
    const Sink = @TypeOf(sink);
    switch (@typeInfo(Sink)) {
        .pointer => |ptr| {
            if (@hasDecl(ptr.child, "onReasoningDelta")) try sink.onReasoningDelta(reasoning);
        },
        else => {
            if (@hasDecl(Sink, "onReasoningDelta")) try sink.onReasoningDelta(reasoning);
        },
    }
}

fn emitCompletionStop(sink: anytype, stop: CompletionStop) !void {
    const Sink = @TypeOf(sink);
    switch (@typeInfo(Sink)) {
        .pointer => |ptr| {
            if (@hasDecl(ptr.child, "onCompletionStop")) try sink.onCompletionStop(stop);
        },
        else => {
            if (@hasDecl(Sink, "onCompletionStop")) try sink.onCompletionStop(stop);
        },
    }
}

fn emitTokenUsage(sink: anytype, usage: TokenUsage) !void {
    const Sink = @TypeOf(sink);
    switch (@typeInfo(Sink)) {
        .pointer => |ptr| {
            if (@hasDecl(ptr.child, "onTokenUsage")) try sink.onTokenUsage(usage);
        },
        else => {
            if (@hasDecl(Sink, "onTokenUsage")) try sink.onTokenUsage(usage);
        },
    }
}

fn extractTokenUsage(line: []const u8, final: bool) ?TokenUsage {
    const input = extractJsonUsizeField(line, "prompt_eval_count") orelse
        extractJsonUsizeField(line, "prompt_tokens") orelse
        extractJsonUsizeField(line, "tokens_evaluated") orelse
        extractJsonUsizeField(line, "n_prompt_tokens") orelse
        extractJsonUsizeField(line, "prompt_n") orelse
        return null;
    const output = extractJsonUsizeField(line, "eval_count") orelse
        extractJsonUsizeField(line, "completion_tokens") orelse
        extractJsonUsizeField(line, "tokens_predicted") orelse
        extractJsonUsizeField(line, "predicted_n") orelse
        return null;
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

fn tokensPerSecondFromEvalDuration(output: usize, duration_ns: ?u64) ?f64 {
    const ns = duration_ns orelse return null;
    if (output == 0 or ns == 0) return null;
    const seconds = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    if (seconds <= 0) return null;
    return @as(f64, @floatFromInt(output)) / seconds;
}

fn extractJsonUsizeField(line: []const u8, field: []const u8) ?usize {
    const value = extractJsonU64Field(line, field) orelse return null;
    return std.math.cast(usize, value);
}

fn extractJsonU64Field(line: []const u8, field: []const u8) ?u64 {
    const number = extractJsonNumberSlice(line, field) orelse return null;
    return std.fmt.parseInt(u64, number, 10) catch null;
}

fn extractJsonF64Field(line: []const u8, field: []const u8) ?f64 {
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

fn extractJsonStringField(line: []const u8, field: []const u8) ?[]const u8 {
    var i = jsonFieldValueStart(line, field) orelse return null;
    if (i >= line.len or line[i] != '"') return null;
    i += 1;
    const value_start = i;
    while (i < line.len) : (i += 1) {
        if (line[i] == '"' and (i == value_start or line[i - 1] != '\\')) return line[value_start..i];
    }
    return null;
}

fn jsonBoolTrueField(line: []const u8, field: []const u8) bool {
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

fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

fn jsonUnescape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

test "extract ollama content field" {
    const line = "{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":false}";
    const value = extractJsonStringField(line, "content") orelse return error.NoContent;
    try std.testing.expectEqualStrings("ok", value);
}

test "extract json fields with protocol whitespace" {
    const content_line = "data: { \"choices\": [ { \"delta\": { \"content\" : \"ok\" } } ], \"usage\" : { \"prompt_tokens\" : 3, \"completion_tokens\" : 2 } }";
    const content = extractJsonStringField(content_line, "content") orelse return error.NoContent;
    try std.testing.expectEqualStrings("ok", content);
    try std.testing.expectEqual(@as(usize, 3), extractJsonUsizeField(content_line, "prompt_tokens") orelse return error.NoUsage);
    try std.testing.expect(jsonBoolTrueField("{ \"done\" : true }", "done"));
}

test "extract llama cpp sse content field" {
    const line = "data: {\"content\":\"ola\\n\"}";
    var calls: usize = 0;
    const Ctx = struct {
        calls: *usize,
        pub fn onDelta(self: *@This(), delta: []const u8) !void {
            self.calls.* += 1;
            try std.testing.expectEqualStrings("ola\n", delta);
        }
    };
    var ctx = Ctx{ .calls = &calls };
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(!try feedLines(std.testing.allocator, &line_buffer, line, &ctx));
    try std.testing.expect(!try flushLine(std.testing.allocator, &line_buffer, &ctx));
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "openai reasoning content reaches reasoning sink before visible content" {
    const lines =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"pensando\"},\"finish_reason\":null}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"resposta\"},\"finish_reason\":\"stop\"}]}\n";
    var reasoning = std.ArrayList(u8).empty;
    defer reasoning.deinit(std.testing.allocator);
    var visible = std.ArrayList(u8).empty;
    defer visible.deinit(std.testing.allocator);
    const Ctx = struct {
        reasoning: *std.ArrayList(u8),
        visible: *std.ArrayList(u8),
        ended: bool = false,
        pub fn onReasoningDelta(self: *@This(), delta: []const u8) !void {
            try self.reasoning.appendSlice(std.testing.allocator, delta);
            self.ended = true;
        }
        pub fn onDelta(self: *@This(), delta: []const u8) !void {
            try std.testing.expect(self.ended);
            try self.visible.appendSlice(std.testing.allocator, delta);
        }
    };
    var ctx = Ctx{ .reasoning = &reasoning, .visible = &visible };
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(try feedLines(std.testing.allocator, &line_buffer, lines, &ctx));
    try std.testing.expectEqualStrings("pensando", reasoning.items);
    try std.testing.expectEqualStrings("resposta", visible.items);
}

test "llamacpp stop true ends stream after visible content" {
    const line = "data: {\"content\":\"PHENOM_REAL_7319\",\"stop\":true}\n";
    var seen = std.ArrayList(u8).empty;
    defer seen.deinit(std.testing.allocator);
    const Ctx = struct {
        seen: *std.ArrayList(u8),
        pub fn onDelta(self: *@This(), delta: []const u8) !void {
            try self.seen.appendSlice(std.testing.allocator, delta);
        }
    };
    var ctx = Ctx{ .seen = &seen };
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(try feedLines(std.testing.allocator, &line_buffer, line, &ctx));
    try std.testing.expectEqualStrings("PHENOM_REAL_7319", seen.items);
}

test "llamacpp stopped limit exposes completion stop reason" {
    const line = "data: {\"content\":\"cortado\",\"stop\":true,\"stopped_limit\":true,\"tokens_predicted\":32,\"tokens_evaluated\":10}\n";
    var seen = std.ArrayList(u8).empty;
    defer seen.deinit(std.testing.allocator);
    var reason: StopReason = .unknown;
    const Ctx = struct {
        seen: *std.ArrayList(u8),
        reason: *StopReason,
        pub fn onDelta(self: *@This(), delta: []const u8) !void {
            try self.seen.appendSlice(std.testing.allocator, delta);
        }
        pub fn onCompletionStop(self: *@This(), stop: CompletionStop) !void {
            self.reason.* = stop.reason;
        }
        pub fn onTokenUsage(_: *@This(), _: TokenUsage) !void {}
    };
    var ctx = Ctx{ .seen = &seen, .reason = &reason };
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(try feedLines(std.testing.allocator, &line_buffer, line, &ctx));
    try std.testing.expectEqualStrings("cortado", seen.items);
    try std.testing.expectEqual(StopReason.length, reason);
}

test "ollama done true ends stream without visible content" {
    const line = "{\"done\":true}\n";
    const Ctx = struct {
        pub fn onDelta(_: *@This(), _: []const u8) !void {
            return error.UnexpectedDelta;
        }
    };
    var ctx = Ctx{};
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(try feedLines(std.testing.allocator, &line_buffer, line, &ctx));
}

test "ollama final stream emits real token usage without estimates" {
    const line = "{\"done\":true,\"prompt_eval_count\":10,\"eval_count\":20,\"eval_duration\":2000000000}\n";
    const Ctx = struct {
        usage: ?TokenUsage = null,
        pub fn onDelta(_: *@This(), _: []const u8) !void {
            return error.UnexpectedDelta;
        }
        pub fn onTokenUsage(self: *@This(), usage: TokenUsage) !void {
            self.usage = usage;
        }
    };
    var ctx = Ctx{};
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(try feedLines(std.testing.allocator, &line_buffer, line, &ctx));
    const usage = ctx.usage orelse return error.MissingTokenUsage;
    try std.testing.expectEqual(@as(usize, 10), usage.input);
    try std.testing.expectEqual(@as(usize, 20), usage.output);
    try std.testing.expectEqual(@as(usize, 30), usage.total);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), usage.tokens_per_second orelse return error.MissingTps, 0.001);
    try std.testing.expect(usage.final);
}

test "openai compatible usage emits real token usage" {
    const line = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}\n";
    const Ctx = struct {
        usage: ?TokenUsage = null,
        pub fn onDelta(_: *@This(), _: []const u8) !void {}
        pub fn onTokenUsage(self: *@This(), usage: TokenUsage) !void {
            self.usage = usage;
        }
    };
    var ctx = Ctx{};
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(std.testing.allocator);
    try std.testing.expect(try feedLines(std.testing.allocator, &line_buffer, line, &ctx));
    const usage = ctx.usage orelse return error.MissingTokenUsage;
    try std.testing.expectEqual(@as(usize, 3), usage.input);
    try std.testing.expectEqual(@as(usize, 1), usage.output);
    try std.testing.expectEqual(@as(usize, 4), usage.total);
    try std.testing.expect(usage.tokens_per_second == null);
    try std.testing.expect(usage.final);
}

test "token usage is absent when backend provides no real counters" {
    try std.testing.expect(extractTokenUsage("{\"done\":true}", true) == null);
    try std.testing.expect(extractTokenUsage("{\"done\":true,\"prompt_eval_count\":10}", true) == null);
}

test "token usage distinguishes streaming update from final counters" {
    const update = extractTokenUsage("{\"content\":\"x\",\"tokens_evaluated\":8,\"tokens_predicted\":1}", false) orelse return error.MissingTokenUsage;
    try std.testing.expect(!update.final);
    const final = extractTokenUsage("{\"stop\":true,\"tokens_evaluated\":8,\"tokens_predicted\":2}", true) orelse return error.MissingTokenUsage;
    try std.testing.expect(final.final);
}

test "json unescape decodes common escapes" {
    const decoded = try jsonUnescape(std.testing.allocator, "a\\nb\\t\\\"c\\\"");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a\nb\t\"c\"", decoded);
}

test "json escape replaces malformed utf8 before request body" {
    const escaped = try jsonEscape(std.testing.allocator, "ok\xfffim");
    defer std.testing.allocator.free(escaped);

    try std.testing.expectEqualStrings("ok\\uFFFDfim", escaped);
    try std.testing.expect(std.unicode.utf8ValidateSlice(escaped));
}

test "llamacpp request body is valid utf8 when context has malformed bytes" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "olola",
        .model_context = "[TURN_CONTEXT v1]\ntask: removido\nmode: a\xffb\n",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.unicode.utf8ValidateSlice(body));
    try std.testing.expect(std.mem.indexOf(u8, body, "\\uFFFD") != null);
}

test "http status parser rejects non 2xx" {
    try ensureStatusOk("HTTP/1.1 200 OK\r\nContent-Type: application/json");
    try std.testing.expectError(error.HttpStatusNotOk, ensureStatusOk("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain"));
}

test "http failure detail includes status and body snippet" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .last_http_status = 400,
        .last_http_body_snippet = try std.testing.allocator.dupe(u8, "{\"error\":\"bad request\"}"),
    };
    defer client.deinit();

    const detail = (try client.httpFailureDetail(std.testing.allocator)).?;
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings("status=400 body=\"{\"error\":\"bad request\"}\"", detail);
}

test "http failure body snippet is sanitized and bounded" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try appendSanitizedSnippet(std.testing.allocator, &out, "a\nb\tc\x01d", 6);
    try std.testing.expectEqualStrings("a b c?", out.items);
}

test "probe backend path avoids inference endpoint" {
    try std.testing.expectEqualStrings("/", probePathForBackend(.llamacpp));
    try std.testing.expectEqualStrings("/api/tags", probePathForBackend(.ollama));
}

test "parse http status and server header for probe" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: llama.cpp\r\n";
    try std.testing.expectEqual(@as(u16, 200), try parseHttpStatus(headers));
    const server = (try extractHeaderValue(std.testing.allocator, headers, "server")).?;
    defer std.testing.allocator.free(server);
    try std.testing.expectEqualStrings("llama.cpp", server);
}

test "runtime target parser accepts local http url and rejects https" {
    const parsed = try parseHttpTarget(std.testing.allocator, "http://127.0.0.1:18080/health");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 18080), parsed.port);
    try std.testing.expectEqualStrings("/health", parsed.path);
    try std.testing.expectError(error.TlsRuntimeInspectionUnsupported, parseHttpTarget(std.testing.allocator, "https://example.com/"));
}

test "backend metadata parsers extract context and tokenize count without estimates" {
    try std.testing.expectEqual(@as(?usize, 4096), firstJsonUnsigned("{\"default_generation_settings\":{\"n_ctx\":4096}}", &.{"n_ctx"}));
    try std.testing.expectEqual(@as(?usize, 5), parseTokenizeCount("{\"tokens\":[1,2,3,4,5]}"));
    try std.testing.expectEqual(@as(?usize, 7), parseTokenizeCount("{\"n_tokens\":7}"));
    try std.testing.expectEqual(@as(?usize, 8192), firstJsonUnsigned("{\"model_info\":{\"llama.context_length\":8192}}", &.{"llama.context_length"}));
}

test "tokenize response limit fits real prompt token arrays" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), tokenizeResponseLimit(null));
    try std.testing.expect(tokenizeResponseLimit(65_536) > 8192);
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), tokenizeResponseLimit(2_000_000));
}

test "llamacpp body delegates formatting to native chat template" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const body = try client.buildBody("ola");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_format\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<|im_start|>") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\"") == null);
}

test "llamacpp prompt keeps persistent session focus and excludes volatile current task" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const context_a =
        "[TURN_CONTEXT v1]\n" ++
        "task: primeira pergunta\n" ++
        "mode: code_evidence\n" ++
        "budget: small\n\n" ++
        "[CONTRACTS]\nrouter\n\n" ++
        "[SESSION_FOCUS]\nF1:\n  old focus A\n\n" ++
        "[RECENT_DIALOGUE]\nD1:\n  user: old A\n\n" ++
        "[NEXT_ACTION]\nanswer\n";
    const context_b =
        "[TURN_CONTEXT v1]\n" ++
        "task: segunda pergunta\n" ++
        "mode: code_evidence\n" ++
        "budget: small\n\n" ++
        "[CONTRACTS]\nrouter\n\n" ++
        "[SESSION_FOCUS]\nF1:\n  old focus B\n\n" ++
        "[RECENT_DIALOGUE]\nD1:\n  user: old B\n\n" ++
        "[NEXT_ACTION]\nanswer\n";
    const body_a = try client.buildBodyForInput(.{
        .user_prompt = "primeira pergunta",
        .model_context = context_a,
    });
    defer std.testing.allocator.free(body_a);
    const body_b = try client.buildBodyForInput(.{
        .user_prompt = "segunda pergunta",
        .model_context = context_b,
    });
    defer std.testing.allocator.free(body_b);

    try std.testing.expect(std.mem.indexOf(u8, body_a, "task: primeira pergunta") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "task: segunda pergunta") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "old focus A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "[RECENT_DIALOGUE]") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "mode: code_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "\"messages\":[") != null);
}

test "request body sets generation token limit for supported backends" {
    var llama_client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const llama_body = try llama_client.buildBodyForInput(.{ .user_prompt = "explique com detalhes", .max_tokens = 128 });
    defer std.testing.allocator.free(llama_body);
    try std.testing.expect(std.mem.indexOf(u8, llama_body, "\"max_tokens\":128") != null);

    var ollama_client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .ollama,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const ollama_body = try ollama_client.buildBodyForInput(.{ .user_prompt = "explique com detalhes", .max_tokens = 96 });
    defer std.testing.allocator.free(ollama_body);
    try std.testing.expect(std.mem.indexOf(u8, ollama_body, "\"num_predict\":96") != null);
}

test "zero generation token limit asks supported backends for unlimited generation" {
    var llama_client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const llama_body = try llama_client.buildBodyForInput(.{ .user_prompt = "explique com detalhes", .max_tokens = 0 });
    defer std.testing.allocator.free(llama_body);
    try std.testing.expect(std.mem.indexOf(u8, llama_body, "\"max_tokens\"") == null);

    var ollama_client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .ollama,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const ollama_body = try ollama_client.buildBodyForInput(.{ .user_prompt = "explique com detalhes", .max_tokens = 0 });
    defer std.testing.allocator.free(ollama_body);
    try std.testing.expect(std.mem.indexOf(u8, ollama_body, "\"num_predict\":-1") != null);
}

test "llamacpp thinking on uses native template argument" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .on,
    };
    const body = try client.buildBody("analise este bug");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<think>") == null);
}

test "llamacpp thinking auto leaves native template policy unset" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .auto,
    };
    const simple = try client.buildBody("ola");
    defer std.testing.allocator.free(simple);
    const complex = try client.buildBody("analise este bug no codigo");
    defer std.testing.allocator.free(complex);
    try std.testing.expect(std.mem.indexOf(u8, simple, "chat_template_kwargs") == null);
    try std.testing.expect(std.mem.indexOf(u8, complex, "chat_template_kwargs") == null);
}

test "ollama body includes model context in system message" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .ollama,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "corrija",
        .model_context = "[TURN_CONTEXT v1]\ntask: corrigir\n",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Model decides when contracts/tools are needed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "task: corrigir") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "corrija") != null);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(body, "\"role\":\"user\""));
    const context_idx = std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") orelse return error.MissingContext;
    const user_idx = std.mem.indexOf(u8, body, "corrija") orelse return error.MissingPrompt;
    try std.testing.expect(context_idx < user_idx);
}

test "backend request can use custom system prompt template" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "ola",
        .system_prompt = "CUSTOM_SYSTEM_TEMPLATE",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "CUSTOM_SYSTEM_TEMPLATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Model decides when contracts/tools are needed") == null);
}

test "ollama body includes recent dialogue as real chat roles" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .ollama,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const dialogue = [_]ChatMessage{
        .{ .role = .user, .content = "qual e meu nome?" },
        .{ .role = .assistant, .content = "Voce aparece como ashirak." },
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "e agora?",
        .model_context = "[TURN_CONTEXT v1]\n",
        .dialogue = &dialogue,
    });
    defer std.testing.allocator.free(body);

    const context_idx = std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") orelse return error.MissingContext;
    const prior_user_idx = std.mem.indexOf(u8, body, "qual e meu nome?") orelse return error.MissingPriorUser;
    const prior_assistant_idx = std.mem.indexOf(u8, body, "Voce aparece como ashirak.") orelse return error.MissingPriorAssistant;
    const current_idx = std.mem.indexOf(u8, body, "e agora?") orelse return error.MissingPrompt;
    try std.testing.expectEqual(@as(usize, 2), countNeedle(body, "\"role\":\"user\""));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(body, "\"role\":\"assistant\""));
    try std.testing.expect(context_idx < prior_user_idx);
    try std.testing.expect(prior_user_idx < prior_assistant_idx);
    try std.testing.expect(prior_assistant_idx < current_idx);
}

test "llamacpp body can include model context before user request" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "corrija",
        .model_context = "[TURN_CONTEXT v1]\ntask: corrigir\nmode: code_evidence\n",
    });
    defer std.testing.allocator.free(body);

    const context_idx = std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") orelse return error.MissingContext;
    const user_idx = std.mem.indexOf(u8, body, "corrija") orelse return error.MissingPrompt;
    try std.testing.expectEqual(@as(usize, 1), countNeedle(body, "\"role\":\"user\""));
    try std.testing.expect(context_idx < user_idx);
    try std.testing.expect(std.mem.indexOf(u8, body, "task: corrigir") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mode: code_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":false") != null);
}

test "llamacpp body includes recent dialogue before current user request" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .thinking = .off,
    };
    const dialogue = [_]ChatMessage{
        .{ .role = .user, .content = "qual e meu nome?" },
        .{ .role = .assistant, .content = "Voce aparece como ashirak." },
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "da google?",
        .model_context = "[TURN_CONTEXT v1]\\n",
        .dialogue = &dialogue,
    });
    defer std.testing.allocator.free(body);

    const context_idx = std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") orelse return error.MissingContext;
    const prior_user_idx = std.mem.indexOf(u8, body, "qual e meu nome?") orelse return error.MissingPriorUser;
    const prior_assistant_idx = std.mem.indexOf(u8, body, "Voce aparece como ashirak.") orelse return error.MissingPriorAssistant;
    const current_idx = std.mem.indexOf(u8, body, "da google?") orelse return error.MissingPrompt;
    try std.testing.expectEqual(@as(usize, 2), countNeedle(body, "\"role\":\"user\""));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(body, "\"role\":\"assistant\""));
    try std.testing.expect(context_idx < prior_user_idx);
    try std.testing.expect(prior_user_idx < prior_assistant_idx);
    try std.testing.expect(prior_assistant_idx < current_idx);
}

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= haystack.len) {
        const idx = std.mem.indexOf(u8, haystack[start..], needle) orelse break;
        count += 1;
        start += idx + needle.len;
    }
    return count;
}

test "thinking auto remains backend native without prompt classification" {
    try std.testing.expectEqual(cli.ThinkingMode.auto, resolveThinking(.auto));
}

test "cancel token stops socket wait before polling fd" {
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, waitReadableOrCancelledForTest(-1, &cancel));
}

test "stream cancel input distinguishes esc from csi keys" {
    var input = StreamCancelInput{};
    try std.testing.expect(input.feed(&.{0x03}, 0));

    input = .{};
    try std.testing.expect(!input.feed("\x1b[A", 0));
    try std.testing.expect(!input.flushExpired(200));

    input = .{};
    try std.testing.expect(!input.feed("\x1b", 1000));
    try std.testing.expect(!input.flushExpired(1099));
    try std.testing.expect(input.flushExpired(1100));

    input = .{};
    try std.testing.expect(!input.feed("\x1b", 2000));
    try std.testing.expect(!input.feed("[A", 2001));
    try std.testing.expect(!input.flushExpired(2200));

    input = .{};
    try std.testing.expect(input.feed("\x1bx", 0));
}

test "cancel fd interrupts socket wait" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    const byte = [_]u8{0x03};
    try std.testing.expect(c.write(fds[1], &byte, byte.len) == byte.len);

    var input = StreamCancelInput{};
    try std.testing.expectError(error.Cancelled, waitReadableOrCancelled(-1, null, fds[0], &input));
}

test "backend failure classifier separates transport status protocol and model output" {
    try std.testing.expectEqual(BackendFailureKind.connect, classifyStreamFailure(error.ConnectFailed, null));
    try std.testing.expectEqual(BackendFailureKind.connect, classifyStreamFailure(error.GetAddrInfoFailed, null));
    try std.testing.expectEqual(BackendFailureKind.http_status, classifyStreamFailure(error.HttpStatusNotOk, 404));
    try std.testing.expectEqual(BackendFailureKind.protocol_parse, classifyStreamFailure(error.InvalidHttpResponse, null));
    try std.testing.expectEqual(BackendFailureKind.stream_read, classifyStreamFailure(error.SocketReadFailed, null));
    try std.testing.expectEqual(BackendFailureKind.stream_cancelled, classifyStreamFailure(error.Cancelled, null));
    try std.testing.expectEqual(BackendFailureKind.model_empty, classifyModelOutput(.stop, 0, 0).?);
    try std.testing.expectEqual(BackendFailureKind.model_think_only, classifyModelOutput(.length, 0, 12).?);
    try std.testing.expect(classifyModelOutput(.stop, 1, 12) == null);
}
