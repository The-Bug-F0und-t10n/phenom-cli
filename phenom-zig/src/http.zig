const std = @import("std");
const cli = @import("cli.zig");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

pub const LocalModelClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    backend: cli.Backend,
    model: []const u8,
    max_tokens: u16 = 160,
    thinking: cli.ThinkingMode = .auto,

    pub fn defaultPort(backend: cli.Backend) u16 {
        return if (backend == .ollama) 11434 else 8080;
    }

    pub fn pathForBackend(backend: cli.Backend) []const u8 {
        return if (backend == .ollama) "/api/chat" else "/completion";
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
        while (true) {
            const n_raw = c.read(fd, &buf, buf.len);
            if (n_raw < 0) return error.SocketReadFailed;
            const n: usize = @intCast(n_raw);
            if (n == 0) break;
            var data = buf[0..n];

            if (!headers_done) {
                try header_buffer.appendSlice(self.allocator, data);
                if (findHeaderEnd(header_buffer.items)) |idx| {
                    const headers = header_buffer.items[0..idx];
                    try ensureStatusOk(headers);
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

    fn buildBodyForInput(self: *LocalModelClient, input: InferenceInput) ![]u8 {
        const escaped_prompt = try jsonEscape(self.allocator, input.user_prompt);
        defer self.allocator.free(escaped_prompt);
        const escaped_context = if (input.model_context) |context| try jsonEscape(self.allocator, context) else null;
        defer if (escaped_context) |context| self.allocator.free(context);
        const escaped_model = try jsonEscape(self.allocator, self.model);
        defer self.allocator.free(escaped_model);

        return switch (self.backend) {
            .ollama => try self.buildOllamaBody(escaped_model, escaped_context, escaped_prompt, input.dialogue),
            .llamacpp => blk: {
                const resolved_thinking = resolveThinking(self.thinking, input.user_prompt);
                const generation_prefix = if (resolved_thinking == .on)
                    "<think>\n"
                else
                    "<think>\n\n</think>\n\n";
                const chat_prompt = try self.buildLlamaCppPrompt(input, generation_prefix);
                defer self.allocator.free(chat_prompt);
                const escaped_chat_prompt = try jsonEscape(self.allocator, chat_prompt);
                defer self.allocator.free(escaped_chat_prompt);
                break :blk try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"stream\":true,\"prompt\":\"{s}\",\"temperature\":0.2,\"n_predict\":{},\"stop\":[\"<|im_end|>\"]}}",
                    .{ escaped_chat_prompt, self.max_tokens },
                );
            },
        };
    }

    fn buildOllamaBody(self: *LocalModelClient, escaped_model: []const u8, escaped_context: ?[]const u8, escaped_prompt: []const u8, dialogue: []const ChatMessage) ![]u8 {
        var messages = std.ArrayList(u8).empty;
        defer messages.deinit(self.allocator);
        try messages.appendSlice(self.allocator, "{\"role\":\"system\",\"content\":\"Responda de forma direta, curta e no idioma do usuario. Nao mostre raciocinio.\"}");
        if (escaped_context) |context| {
            try messages.appendSlice(self.allocator, ",{\"role\":\"user\",\"content\":\"");
            try messages.appendSlice(self.allocator, context);
            try messages.appendSlice(self.allocator, "\"}");
        }
        for (dialogue) |message| {
            const escaped = try jsonEscape(self.allocator, message.content);
            defer self.allocator.free(escaped);
            try messages.appendSlice(self.allocator, ",{\"role\":\"");
            try messages.appendSlice(self.allocator, chatRoleName(message.role));
            try messages.appendSlice(self.allocator, "\",\"content\":\"");
            try messages.appendSlice(self.allocator, escaped);
            try messages.appendSlice(self.allocator, "\"}");
        }
        try messages.appendSlice(self.allocator, ",{\"role\":\"user\",\"content\":\"");
        try messages.appendSlice(self.allocator, escaped_prompt);
        try messages.appendSlice(self.allocator, "\"}");
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"model\":\"{s}\",\"stream\":true,\"messages\":[{s}],\"options\":{{\"temperature\":0.2,\"num_predict\":{}}}}}",
            .{ escaped_model, messages.items, self.max_tokens },
        );
    }

    fn buildLlamaCppPrompt(self: *LocalModelClient, input: InferenceInput, generation_prefix: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "<|im_start|>system\nResponda de forma direta, curta e no idioma do usuario. Quando thinking estiver habilitado, use o bloco <think> somente para raciocinio interno e finalize com resposta visivel fora dele.<|im_end|>\n");
        if (input.model_context) |context| {
            try appendChatMessage(&out, self.allocator, .user, context);
        }
        for (input.dialogue) |message| {
            try appendChatMessage(&out, self.allocator, message.role, message.content);
        }
        try appendChatMessage(&out, self.allocator, .user, input.user_prompt);
        try out.appendSlice(self.allocator, "<|im_start|>assistant\n");
        try out.appendSlice(self.allocator, generation_prefix);
        return out.toOwnedSlice(self.allocator);
    }
};

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
    model_context: ?[]const u8 = null,
    dialogue: []const ChatMessage = &.{},
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

pub fn resolveThinking(mode: cli.ThinkingMode, prompt: []const u8) cli.ThinkingMode {
    return switch (mode) {
        .on => .on,
        .off => .off,
        .auto => if (looksComplex(prompt)) .on else .off,
    };
}

fn looksComplex(prompt: []const u8) bool {
    if (prompt.len > 180) return true;
    const needles: []const []const u8 = &.{
        "codigo",
        "código",
        "bug",
        "erro",
        "stack",
        "trace",
        "patch",
        "arquivo",
        "implemente",
        "refator",
        "analise",
        "debug",
        "tool",
        "teste",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, prompt, needle) != null) return true;
    }
    return false;
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
    if (extractJsonStringField(json_line, "content")) |content| {
        const decoded = try jsonUnescape(allocator, content);
        defer allocator.free(decoded);
        try sink.onDelta(decoded);
    } else if (extractJsonStringField(json_line, "response")) |response| {
        const decoded = try jsonUnescape(allocator, response);
        defer allocator.free(decoded);
        try sink.onDelta(decoded);
    }
    return jsonBoolTrueField(json_line, "stop") or jsonBoolTrueField(json_line, "done");
}

fn extractJsonStringField(line: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 4 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + field.len], field);
    needle_buf[1 + field.len] = '"';
    needle_buf[2 + field.len] = ':';
    needle_buf[3 + field.len] = '"';
    const needle = needle_buf[0 .. field.len + 4];

    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = start + needle.len;
    const value_start = i;
    while (i < line.len) : (i += 1) {
        if (line[i] == '"' and (i == value_start or line[i - 1] != '\\')) return line[value_start..i];
    }
    return null;
}

fn jsonBoolTrueField(line: []const u8, field: []const u8) bool {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 3 > needle_buf.len) return false;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + field.len], field);
    needle_buf[1 + field.len] = '"';
    needle_buf[2 + field.len] = ':';
    const needle = needle_buf[0 .. field.len + 3];

    const start = std.mem.indexOf(u8, line, needle) orelse return false;
    var i = start + needle.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return std.mem.startsWith(u8, line[i..], "true");
}

fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
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

test "json unescape decodes common escapes" {
    const decoded = try jsonUnescape(std.testing.allocator, "a\\nb\\t\\\"c\\\"");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a\nb\t\"c\"", decoded);
}

test "http status parser rejects non 2xx" {
    try ensureStatusOk("HTTP/1.1 200 OK\r\nContent-Type: application/json");
    try std.testing.expectError(error.HttpStatusNotOk, ensureStatusOk("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain"));
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

test "llamacpp body uses qwopus chat template with thinking disabled" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .max_tokens = 64,
        .thinking = .off,
    };
    const body = try client.buildBody("ola");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<|im_start|>system") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<|im_start|>user") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<|im_start|>assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<think>\\n\\n</think>\\n\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stop\":[\"<|im_end|>\"]") != null);
}

test "llamacpp thinking on opens reasoning block" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .max_tokens = 64,
        .thinking = .on,
    };
    const body = try client.buildBody("analise este bug");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<|im_start|>assistant\\n<think>\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<think>\\n\\n</think>\\n\\n") == null);
}

test "ollama body can include model context as separate user message" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .ollama,
        .model = "phenom:latest",
        .max_tokens = 64,
        .thinking = .off,
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "corrija",
        .model_context = "[TURN_CONTEXT v1]\ntask: corrigir\n",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Responda de forma direta") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "corrija") != null);
    const context_idx = std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") orelse return error.MissingContext;
    const user_idx = std.mem.indexOf(u8, body, "corrija") orelse return error.MissingPrompt;
    try std.testing.expect(context_idx < user_idx);
}

test "ollama body includes recent dialogue as real chat roles" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .ollama,
        .model = "phenom:latest",
        .max_tokens = 64,
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
    try std.testing.expect(context_idx < prior_user_idx);
    try std.testing.expect(prior_user_idx < prior_assistant_idx);
    try std.testing.expect(prior_assistant_idx < current_idx);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\"") != null);
}

test "llamacpp body can include model context before user request" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .max_tokens = 64,
        .thinking = .off,
    };
    const body = try client.buildBodyForInput(.{
        .user_prompt = "corrija",
        .model_context = "[TURN_CONTEXT v1]\\ntask: corrigir\\n",
    });
    defer std.testing.allocator.free(body);

    const context_idx = std.mem.indexOf(u8, body, "[TURN_CONTEXT v1]") orelse return error.MissingContext;
    const user_idx = std.mem.indexOf(u8, body, "corrija") orelse return error.MissingPrompt;
    try std.testing.expect(context_idx < user_idx);
    try std.testing.expect(std.mem.indexOf(u8, body, "<|im_start|>assistant\\n<think>\\n\\n</think>\\n\\n") != null);
}

test "llamacpp body includes recent dialogue before current user request" {
    var client = LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:11434",
        .backend = .llamacpp,
        .model = "phenom:latest",
        .max_tokens = 64,
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
    try std.testing.expect(context_idx < prior_user_idx);
    try std.testing.expect(prior_user_idx < prior_assistant_idx);
    try std.testing.expect(prior_assistant_idx < current_idx);
}

test "thinking auto resolves simple prompt off and code prompt on" {
    try std.testing.expectEqual(cli.ThinkingMode.off, resolveThinking(.auto, "ola"));
    try std.testing.expectEqual(cli.ThinkingMode.on, resolveThinking(.auto, "analise este bug no codigo"));
}
