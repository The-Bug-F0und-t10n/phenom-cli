const std = @import("std");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("errno.h");
    @cInclude("netinet/in.h");
    @cInclude("sqlite3.h");
    @cInclude("stdlib.h");
    @cInclude("sys/socket.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const Scenario = enum {
    initial_json_web,
    duplicate_web_json,
    web_query_intent_optimization,
    web_source_followup,
    web_cache_reuse,
    web_cache_expiry,
    web_query_fanout,
    web_provider_fanout,
    web_final_streaming,
    length_usage_continuation,
    web_length_continuation,
    web_multi_length_continuation,
    web_language,
    web_language_empty,
};

const SmokeError = error{
    AcceptFailed,
    BindFailed,
    ChildFailed,
    CompletionCountMismatch,
    ConnectFailed,
    ExpectedOutputMissing,
    ListenFailed,
    ProtocolLeak,
    RecvFailed,
    SendFailed,
    SocketFailed,
    SqliteOpenFailed,
    SqlitePrepareFailed,
    SqliteStepFailed,
    UnexpectedAudit,
};

const ServerState = struct {
    scenario: Scenario,
    fd: c_int,
    port: u16,
    completion_count: usize = 0,
    search_get_count: usize = 0,
    completion_buf: [4096]u8 = undefined,
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next();
    const raw_bin = it.next() orelse {
        writeFd(2, "usage: agent-flow-smoke <phenom-bin>\n");
        return error.InvalidArgs;
    };
    const bin = try absolutePath(allocator, raw_bin);
    defer allocator.free(bin);
    try runScenario(allocator, init.io, bin, .initial_json_web);
    try runScenario(allocator, init.io, bin, .duplicate_web_json);
    try runScenario(allocator, init.io, bin, .web_query_intent_optimization);
    try runScenario(allocator, init.io, bin, .web_source_followup);
    try runCacheReuseScenario(allocator, init.io, bin);
    try runCacheExpiryScenario(allocator, init.io, bin);
    try runScenario(allocator, init.io, bin, .web_query_fanout);
    try runScenario(allocator, init.io, bin, .web_provider_fanout);
    try runScenario(allocator, init.io, bin, .web_final_streaming);
    try runScenario(allocator, init.io, bin, .length_usage_continuation);
    try runScenario(allocator, init.io, bin, .web_length_continuation);
    try runScenario(allocator, init.io, bin, .web_multi_length_continuation);
    try runScenario(allocator, init.io, bin, .web_language);
    try runScenario(allocator, init.io, bin, .web_language_empty);
    writeFd(1, "agent-flow-smoke: ok\n");
}

fn writeFd(fd: c_int, text: []const u8) void {
    _ = c.write(fd, text.ptr, text.len);
}

fn monotonicMillis() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

fn dumpChildOutput(stdout: []const u8, stderr: []const u8) void {
    writeFd(2, "\n[agent-flow-smoke child stdout]\n");
    writeFd(2, stdout);
    writeFd(2, "\n[agent-flow-smoke child stderr]\n");
    writeFd(2, stderr);
    writeFd(2, "\n");
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const raw = c.realpath(z_path.ptr, null) orelse return error.FileNotFound;
    defer c.free(raw);
    return try allocator.dupe(u8, std.mem.span(raw));
}

fn runScenario(allocator: std.mem.Allocator, io: std.Io, bin: []const u8, scenario: Scenario) !void {
    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "agent-flow-smoke: {s}\n", .{@tagName(scenario)}) catch unreachable;
    writeFd(1, label);

    var state = try startServer(scenario);
    var thread = try std.Thread.spawn(.{}, serverMain, .{&state});
    errdefer {
        _ = c.shutdown(state.fd, c.SHUT_RDWR);
        _ = c.close(state.fd);
        thread.join();
    }

    const work = try std.fmt.allocPrint(allocator, "/tmp/phenom-zig-agent-flow-smoke-{s}", .{@tagName(scenario)});
    defer allocator.free(work);
    std.Io.Dir.cwd().deleteTree(io, work) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work);

    const config = if (scenario == .web_provider_fanout)
        try std.fmt.allocPrint(allocator, "web_search_url = \"http://127.0.0.1:{}/search-empty?q={{query}};http://127.0.0.1:{}/search?q={{query}}\"\n", .{ state.port, state.port })
    else
        try std.fmt.allocPrint(allocator, "web_search_url = \"http://127.0.0.1:{}/search?q={{query}}\"\n", .{state.port});
    defer allocator.free(config);
    var work_dir = try std.Io.Dir.cwd().openDir(io, work, .{});
    defer work_dir.close(io);
    try work_dir.writeFile(io, .{ .sub_path = "config.toml", .data = config });

    const host = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{state.port});
    defer allocator.free(host);
    const session = @tagName(scenario);
    const prompt = scenarioPrompt(scenario);
    const expect = scenarioExpect(scenario);
    const thinking = if (scenario == .length_usage_continuation) "off" else "on";

    const argv = [_][]const u8{
        bin,
        "chat",
        "--backend",
        "llamacpp",
        "--host",
        host,
        "--model",
        "scripted",
        "--session",
        session,
        "--prompt",
        prompt,
        "--max-tokens",
        "512",
        "--thinking",
        thinking,
        "--expect-contains",
        expect,
        "--fail-on-model-error",
        "--no-color",
    };
    const started_ms = monotonicMillis();
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = work },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    const elapsed_ms = monotonicMillis() - started_ms;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.ChildFailed;
        },
        else => {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.ChildFailed;
        },
    }
    if (std.mem.indexOf(u8, result.stdout, expect) == null) {
        dumpChildOutput(result.stdout, result.stderr);
        return SmokeError.ExpectedOutputMissing;
    }
    if (containsAny(result.stdout, &.{ "\"tool_call\"", "```json", "[WEB_EVIDENCE_EMPTY]", "PHENOM_WEB_LANG_EN" })) {
        dumpChildOutput(result.stdout, result.stderr);
        return SmokeError.ProtocolLeak;
    }

    const db_path = try std.fmt.allocPrint(allocator, "{s}/.phenom-zig/phenom.db", .{work});
    defer allocator.free(db_path);
    try expectCount(allocator, db_path, "select count(*) from events where kind='tool_start' and body like 'web_search%'", expectedWebSearchStarts(scenario));
    try expectCount(allocator, db_path, "select count(*) from events where kind='assistant_delta' and (body like '%tool_call%' or body like '%WEB_EVIDENCE%' or body like '%```json%' or body like '%PHENOM_WEB_LANG_EN%')", 0);
    try expectCount(allocator, db_path, "select count(*) from events where kind='turn_error'", 0);
    if (isWebScenario(scenario)) {
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='turn_done' and body like '%used_evidence=true%'", 1);
    }
    if (scenario == .web_query_fanout) {
        try expectCount(allocator, db_path, "select count(*) from events where kind='web_search_fanout'", 1);
        if (state.search_get_count != 2) return SmokeError.UnexpectedAudit;
    }
    if (scenario == .web_provider_fanout) {
        try expectCount(allocator, db_path, "select count(*) from events where kind='web_search_fanout'", 1);
        if (state.search_get_count != 2) return SmokeError.UnexpectedAudit;
        if (elapsed_ms >= 900) return SmokeError.UnexpectedAudit;
    }
    if (scenario == .duplicate_web_json) {
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='answer_repair' and body='tool call emitted after tool phase closed'", 1);
    }
    if (scenario == .web_query_intent_optimization) {
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='web_query_optimization' and body like '%success=true%' and body like '%final_query=R36S especificacoes tecnicas console%'", 1);
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='tool_start' and body like 'web_search%' and body like '%R36S%20especificacoes%20tecnicas%20console%'", 1);
    }
    if (scenario == .web_final_streaming) {
        try expectCount(allocator, db_path, "select count(*) from events where kind='assistant_delta'", 1);
        try expectCount(allocator, db_path, "select count(*) from events where kind='answer_repair' and body='controller appended collected web sources'", 1);
    }
    if (scenario == .length_usage_continuation or scenario == .web_length_continuation) {
        if (contains(result.stdout, "generation limit") or contains(result.stdout, "token limit")) {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.ProtocolLeak;
        }
        try expectCount(allocator, db_path, "select count(*) from events where kind='answer_repair' and body='server length stop with partial visible answer'", 1);
        try expectCount(allocator, db_path, "select count(*) from events where kind='answer_repair_done' and body='server length continuation emitted visible answer'", 1);
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='assistant_delta' and body like '%CONTINUED%'", 1);
    }
    if (scenario == .web_multi_length_continuation) {
        if (contains(result.stdout, "generation limit") or contains(result.stdout, "token limit")) {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.ProtocolLeak;
        }
        try expectCount(allocator, db_path, "select count(*) from events where kind='answer_repair' and body='server length stop with partial visible answer'", 2);
        try expectCount(allocator, db_path, "select count(*) from events where kind='answer_repair_done' and body='server length continuation emitted visible answer'", 2);
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='assistant_delta' and body like '%PHENOM_WEB_MULTI_LENGTH_CONTINUED%'", 1);
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='assistant_delta' and body like '%MULTI_LENGTH_PARTIAL resposta web inicial%'", 1);
        try expectAtLeast(allocator, db_path, "select count(*) from events where kind='model_context' and body like '%mode: finalization_repair%' and body like '%source_url=http://127.0.0.1%'", 1);
        try expectCount(allocator, db_path, "select count(*) from events where kind='answer_repair_blocked'", 0);
        if (countOccurrences(result.stdout, "### Memoria RAM") != 1 or !contains(result.stdout, "/search")) {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.UnexpectedAudit;
        }
    }

    _ = c.shutdown(state.fd, c.SHUT_RDWR);
    _ = c.close(state.fd);
    thread.join();
}

fn runCacheReuseScenario(allocator: std.mem.Allocator, io: std.Io, bin: []const u8) !void {
    writeFd(1, "agent-flow-smoke: web_cache_reuse\n");

    var state = try startServer(.web_cache_reuse);
    var thread = try std.Thread.spawn(.{}, serverMain, .{&state});
    errdefer {
        _ = c.shutdown(state.fd, c.SHUT_RDWR);
        _ = c.close(state.fd);
        thread.join();
    }

    const work = "/tmp/phenom-zig-agent-flow-smoke-web_cache_reuse";
    std.Io.Dir.cwd().deleteTree(io, work) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work);

    const config = try std.fmt.allocPrint(allocator, "web_search_url = \"http://127.0.0.1:{}/search?q={{query}}\"\n", .{state.port});
    defer allocator.free(config);
    var work_dir = try std.Io.Dir.cwd().openDir(io, work, .{});
    defer work_dir.close(io);
    try work_dir.writeFile(io, .{ .sub_path = "config.toml", .data = config });

    const host = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{state.port});
    defer allocator.free(host);
    const prompt = scenarioPrompt(.web_cache_reuse);
    const expect = scenarioExpect(.web_cache_reuse);

    try runChatOnce(allocator, io, bin, work, host, "web_cache_reuse_a", prompt, expect);
    try runChatOnce(allocator, io, bin, work, host, "web_cache_reuse_b", prompt, expect);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/.phenom-zig/phenom.db", .{work});
    defer allocator.free(db_path);
    try expectCount(allocator, db_path, "select count(*) from events where kind='web_cache_store'", 1);
    try expectCount(allocator, db_path, "select count(*) from events where kind='web_cache_hit'", 1);
    try expectCount(allocator, db_path, "select count(*) from events where kind='turn_error'", 0);
    if (state.search_get_count != 1) return SmokeError.UnexpectedAudit;

    _ = c.shutdown(state.fd, c.SHUT_RDWR);
    _ = c.close(state.fd);
    thread.join();
}

fn runCacheExpiryScenario(allocator: std.mem.Allocator, io: std.Io, bin: []const u8) !void {
    writeFd(1, "agent-flow-smoke: web_cache_expiry\n");

    var state = try startServer(.web_cache_expiry);
    var thread = try std.Thread.spawn(.{}, serverMain, .{&state});
    errdefer {
        _ = c.shutdown(state.fd, c.SHUT_RDWR);
        _ = c.close(state.fd);
        thread.join();
    }

    const work = "/tmp/phenom-zig-agent-flow-smoke-web_cache_expiry";
    std.Io.Dir.cwd().deleteTree(io, work) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work);

    const config = try std.fmt.allocPrint(allocator, "web_search_url = \"http://127.0.0.1:{}/search?q={{query}}\"\n", .{state.port});
    defer allocator.free(config);
    var work_dir = try std.Io.Dir.cwd().openDir(io, work, .{});
    defer work_dir.close(io);
    try work_dir.writeFile(io, .{ .sub_path = "config.toml", .data = config });

    const host = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{state.port});
    defer allocator.free(host);
    const prompt = scenarioPrompt(.web_cache_expiry);
    const expect = scenarioExpect(.web_cache_expiry);

    try runChatOnce(allocator, io, bin, work, host, "web_cache_expiry_a", prompt, expect);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/.phenom-zig/phenom.db", .{work});
    defer allocator.free(db_path);
    try execSql(allocator, db_path, "update web_cache set created_at=datetime('now','-8 hours')");
    try runChatOnce(allocator, io, bin, work, host, "web_cache_expiry_b", prompt, expect);

    try expectCount(allocator, db_path, "select count(*) from events where kind='web_cache_store'", 2);
    try expectCount(allocator, db_path, "select count(*) from events where kind='web_cache_hit'", 0);
    try expectCount(allocator, db_path, "select count(*) from events where kind='web_cache_stale'", 1);
    try expectCount(allocator, db_path, "select count(*) from events where kind='turn_error'", 0);
    if (state.search_get_count != 2) return SmokeError.UnexpectedAudit;

    _ = c.shutdown(state.fd, c.SHUT_RDWR);
    _ = c.close(state.fd);
    thread.join();
}

fn runChatOnce(allocator: std.mem.Allocator, io: std.Io, bin: []const u8, work: []const u8, host: []const u8, session: []const u8, prompt: []const u8, expect: []const u8) !void {
    const argv = [_][]const u8{
        bin,
        "chat",
        "--backend",
        "llamacpp",
        "--host",
        host,
        "--model",
        "scripted",
        "--session",
        session,
        "--prompt",
        prompt,
        "--max-tokens",
        "512",
        "--thinking",
        "on",
        "--expect-contains",
        expect,
        "--fail-on-model-error",
        "--no-color",
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = work },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.ChildFailed;
        },
        else => {
            dumpChildOutput(result.stdout, result.stderr);
            return SmokeError.ChildFailed;
        },
    }
    if (std.mem.indexOf(u8, result.stdout, expect) == null) {
        dumpChildOutput(result.stdout, result.stderr);
        return SmokeError.ExpectedOutputMissing;
    }
    if (containsAny(result.stdout, &.{ "\"tool_call\"", "```json", "[WEB_EVIDENCE_EMPTY]", "PHENOM_WEB_LANG_EN" })) {
        dumpChildOutput(result.stdout, result.stderr);
        return SmokeError.ProtocolLeak;
    }
}

fn startServer(scenario: Scenario) !ServerState {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return SmokeError.SocketFailed;
    errdefer _ = c.close(fd);

    var yes: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));

    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = @intCast(c.AF_INET);
    addr.sin_port = c.htons(0);
    addr.sin_addr.s_addr = c.htonl(0x7f000001);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) != 0) return SmokeError.BindFailed;
    if (c.listen(fd, 32) != 0) return SmokeError.ListenFailed;

    var actual: c.sockaddr_in = undefined;
    var actual_len: c.socklen_t = @sizeOf(c.sockaddr_in);
    if (c.getsockname(fd, @ptrCast(&actual), &actual_len) != 0) return SmokeError.SocketFailed;
    return .{ .scenario = scenario, .fd = fd, .port = c.ntohs(actual.sin_port) };
}

fn serverMain(state: *ServerState) void {
    const max: usize = switch (state.scenario) {
        .initial_json_web => 4,
        .duplicate_web_json => 5,
        .web_query_intent_optimization => 4,
        .web_source_followup => 9,
        .web_cache_reuse => 7,
        .web_cache_expiry => 7,
        .web_query_fanout => 5,
        .web_provider_fanout => 5,
        .web_final_streaming => 5,
        .length_usage_continuation => 2,
        .web_length_continuation => 5,
        .web_multi_length_continuation => 5,
        .web_language => 4,
        .web_language_empty => 7,
    };
    while (@atomicLoad(usize, &state.completion_count, .seq_cst) < max) {
        var addr: c.sockaddr_in = undefined;
        var addr_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const client = c.accept(state.fd, @ptrCast(&addr), &addr_len);
        if (client < 0) return;
        if (state.scenario == .web_provider_fanout) {
            const thread = std.Thread.spawn(.{}, handleClientThread, .{ state, client }) catch {
                _ = c.close(client);
                return;
            };
            thread.detach();
        } else {
            handleClient(state, client) catch {};
            _ = c.close(client);
        }
    }
}

fn handleClientThread(state: *ServerState, client: c_int) void {
    handleClient(state, client) catch {};
    _ = c.close(client);
}

fn handleClient(state: *ServerState, client: c_int) !void {
    var buffer: [128 * 1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, buffer[0..len], "\r\n\r\n") == null) {
        const n = c.recv(client, buffer[len..].ptr, buffer.len - len, 0);
        if (n <= 0) return SmokeError.RecvFailed;
        len += @intCast(n);
        if (len == buffer.len) return SmokeError.RecvFailed;
    }
    const header_end = (std.mem.indexOf(u8, buffer[0..len], "\r\n\r\n") orelse return SmokeError.RecvFailed) + 4;
    const body_len = contentLength(buffer[0..header_end]);
    while (len < header_end + body_len) {
        const n = c.recv(client, buffer[len..].ptr, buffer.len - len, 0);
        if (n <= 0) return SmokeError.RecvFailed;
        len += @intCast(n);
    }

    const request = buffer[0..len];
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return SmokeError.RecvFailed;
    const first_line = request[0..first_line_end];
    if (std.mem.startsWith(u8, first_line, "GET /props ")) {
        return send(client, "200 OK", "application/json", "{\"n_ctx\":65536}");
    }
    if (std.mem.startsWith(u8, first_line, "POST /tokenize ")) {
        return send(client, "200 OK", "application/json", "{\"tokens\":[1,2,3,4,5,6,7,8]}");
    }
    if (std.mem.startsWith(u8, first_line, "GET /search")) {
        const search_count = @atomicRmw(usize, &state.search_get_count, .Add, 1, .seq_cst) + 1;
        return send(client, "200 OK", "text/html", searchHtml(state, first_line, search_count));
    }
    if (std.mem.startsWith(u8, first_line, "GET /source ")) {
        return send(client, "200 OK", "text/html", sourceHtml(state.scenario));
    }
    if (std.mem.startsWith(u8, first_line, "GET /source-empty ")) {
        return send(client, "200 OK", "text/html", sourceEmptyHtml(state.scenario));
    }
    if (std.mem.startsWith(u8, first_line, "POST /v1/chat/completions ")) {
        const prompt = request[header_end .. header_end + body_len];
        const text = completionText(state, prompt);
        const completion_count = @atomicRmw(usize, &state.completion_count, .Add, 1, .seq_cst);
        const requested_tokens = requestedMaxTokens(prompt) orelse 512;
        if (state.scenario == .length_usage_continuation and completion_count == 0) {
            return sendSseWithUsage(client, text, 64, requested_tokens);
        }
        if (state.scenario == .web_length_continuation and contains(text, "Resposta web parcial")) {
            return sendSseWithUsage(client, text, 64, requested_tokens);
        }
        if (state.scenario == .web_multi_length_continuation and contains(text, "MULTI_LENGTH_PARTIAL")) {
            return sendSseWithUsage(client, text, 64, requested_tokens);
        }
        if (state.scenario == .web_final_streaming and contains(text, "PHENOM_WEB_FINAL_STREAMED")) {
            return sendSseChunkedText(client, text, 300);
        }
        return sendSse(client, text);
    }
    return send(client, "404 Not Found", "text/plain", "not found");
}

fn requestedMaxTokens(request_body: []const u8) ?usize {
    for ([_][]const u8{ "\"n_predict\":", "\"max_tokens\":" }) |marker| {
        const start = (std.mem.indexOf(u8, request_body, marker) orelse continue) + marker.len;
        var end = start;
        while (end < request_body.len and std.ascii.isDigit(request_body[end])) : (end += 1) {}
        if (end > start) return std.fmt.parseInt(usize, request_body[start..end], 10) catch null;
    }
    return null;
}

fn completionText(state: *ServerState, prompt: []const u8) []const u8 {
    return switch (state.scenario) {
        .initial_json_web => initialJsonCompletion(prompt),
        .duplicate_web_json => duplicateWebCompletion(prompt),
        .web_query_intent_optimization => queryIntentOptimizationCompletion(prompt),
        .web_source_followup => sourceFollowupCompletion(state, prompt),
        .web_cache_reuse, .web_cache_expiry => cacheReuseCompletion(prompt),
        .web_query_fanout => queryFanoutCompletion(prompt),
        .web_provider_fanout => providerFanoutCompletion(prompt),
        .web_final_streaming => webFinalStreamingCompletion(prompt),
        .length_usage_continuation => lengthUsageContinuationCompletion(prompt),
        .web_length_continuation => webLengthContinuationCompletion(prompt),
        .web_multi_length_continuation => webMultiLengthContinuationCompletion(state, prompt),
        .web_language => languageCompletion(prompt, false, state.completion_count),
        .web_language_empty => languageCompletion(prompt, true, state.completion_count),
    };
}

fn initialJsonCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "Londrina PR Brasil onde fica localização estado";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=Londrina PR Brasil onde fica localização estado\ntitle=Londrina Location\nexcerpt=Londrina fica no norte do Paraná, na região Sul do Brasil.";
    if (contains(prompt, "tool phase is closed")) return "Londrina fica no norte do Paraná, na região Sul do Brasil.\nPHENOM_INITIAL_JSON_WEB_OK";
    return "I'll search for the exact location of Londrina in Brazil. json { \"tool_call\": { \"name\": \"search_web\", \"arguments\": { \"query\": \"Londrina PR Brasil onde fica localização estado\" } } }";
}

fn duplicateWebCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "irradiacao solar media Londrina PR kWh m2 dia";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=irradiacao solar media Londrina PR kWh m2 dia\ntitle=Londrina Solar\nexcerpt=Irradiacao solar em Londrina: 4,8 kWh/m2/dia.";
    if (contains(prompt, "tool call after the tool phase was closed")) return "A evidencia coletada informa irradiacao solar em Londrina de 4,8 kWh/m2/dia.\nPHENOM_WEB_JSON_NORMALIZED";
    if (contains(prompt, "tool phase is closed")) return "Vou pesquisar de novo. json { \"tool_call\": { \"name\": \"search_web\", \"arguments\": { \"query\": \"irradiacao solar media Londrina PR Atlas Solarimetrico INPE\" } } }";
    return "preciso pesquisar\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>irradiacao solar media Londrina PR kWh m2 dia</parameter><parameter=reason>buscar dado externo solicitado</parameter></function></tool_call>";
}

fn queryIntentOptimizationCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S especificacoes tecnicas console";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=R36S especificacoes tecnicas console\ntitle=R36S Specs\nexcerpt=Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.";
    if (contains(prompt, "tool phase is closed")) return "Specs verificadas: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.\nPHENOM_WEB_QUERY_INTENT_OPTIMIZED";
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn cacheReuseCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S especificacoes tecnicas console cache";
    if (contains(prompt, "tool phase is closed")) return "Specs verificadas via evidencia: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.\nPHENOM_WEB_CACHE_REUSED";
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S especificacoes tecnicas console cache</parameter><parameter=reason>buscar e reutilizar evidencia externa</parameter></function></tool_call>";
}

fn queryFanoutCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S especificacoes tecnicas console processador memoria tela resolucao sistema bateria armazenamento";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=R36S especificacoes tecnicas console processador memoria tela resolucao sistema bateria armazenamento\ntitle=R36S Fanout Specs\nexcerpt=Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.";
    if (contains(prompt, "R36S Fanout Specs") or (contains(prompt, "[WEB_DOSSIER v1]") and contains(prompt, "RK3326"))) return "Specs verificadas por fan-out: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.\nPHENOM_WEB_QUERY_FANOUT";
    if (contains(prompt, "[WEB_DOSSIER v1]")) return "refinar busca\n</think>\n\n<tool_call><function=web_search><parameter=query>R36S Fanout Specs RK3326 RAM tela 480x320</parameter></function></tool_call>";
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S especificacoes tecnicas console processador memoria tela resolucao sistema bateria armazenamento</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn providerFanoutCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S provider specs";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=R36S provider specs\ntitle=R36S Provider Specs\nexcerpt=Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.";
    if (contains(prompt, "R36S Provider Specs") or (contains(prompt, "[WEB_DOSSIER v1]") and contains(prompt, "RK3326"))) return "Specs verificadas por provider fan-out: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.\nPHENOM_WEB_PROVIDER_FANOUT";
    if (contains(prompt, "[WEB_DOSSIER v1]")) return "refinar provider\n</think>\n\n<tool_call><function=web_search><parameter=query>R36S provider specs RK3326 RAM tela 480x320</parameter></function></tool_call>";
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S provider specs</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn webFinalStreamingCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S streaming specs";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=R36S streaming specs\ntitle=R36S Streaming Specs\nsource_url=http://127.0.0.1/search\nexcerpt=Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.";
    if (contains(prompt, "[WEB_DOSSIER v1]") or contains(prompt, "tool phase is closed")) {
        return "STREAM_A aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa STREAM_B bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nFonte: http://127.0.0.1/search\nPHENOM_WEB_FINAL_STREAMED";
    }
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S streaming specs</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn lengthUsageContinuationCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "Previous visible answer stopped because the server reached the generation length limit") or contains(prompt, "mode: finalization_repair")) {
        return "a e finalizada pelo proprio modelo.\nPHENOM_LENGTH_USAGE_CONTINUED";
    }
    return "Resposta longa parcial que para no meio da palavr";
}

fn webLengthContinuationCompletion(prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S especificacoes tecnicas console";
    if (contains(prompt, "Previous visible answer stopped because the server reached the generation length limit") or contains(prompt, "mode: finalization_repair")) {
        return "a e finalizada pelo proprio modelo.\nPHENOM_WEB_LENGTH_CONTINUED";
    }
    if (contains(prompt, "[WEB_DOSSIER v1]") or contains(prompt, "tool phase is closed")) {
        return "Resposta web parcial que para no meio da palavr";
    }
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S especificacoes tecnicas console</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn webMultiLengthContinuationCompletion(state: *ServerState, prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S especificacoes tecnicas console multi length";
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=R36S especificacoes tecnicas console multi length\ntitle=R36S Specs\nsource_url=http://127.0.0.1/search\nexcerpt=Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.";
    if (contains(prompt, "mode: finalization_repair") and state.completion_count <= 3) {
        return "### Processador\n• RK3326\n### Memoria RAM\n• 1GB RAM\n### Tela\nMULTI_LENGTH_PARTIAL resposta web inicial cortada no meio da frase com um prefixo suficientemente longo para reproduzir repeticao de continuacao em respostas medias e longas. continuacao ainda incompleta no meio da frase ";
    }
    if (contains(prompt, "mode: finalization_repair")) {
        return std.fmt.bufPrint(&state.completion_buf, "finalizada pelo modelo.\nFonte: http://127.0.0.1:{}/search\nPHENOM_WEB_MULTI_LENGTH_CONTINUED", .{state.port}) catch unreachable;
    }
    if (contains(prompt, "[WEB_DOSSIER v1]") or contains(prompt, "tool phase is closed")) {
        return "### Memoria RAM\n• 1GB RAM\n### Tela\nMULTI_LENGTH_PARTIAL resposta web inicial cortada no meio da frase com um prefixo suficientemente longo para reproduzir repeticao de continuacao em respostas medias e longas. ";
    }
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S especificacoes tecnicas console multi length</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn sourceFollowupCompletion(state: *ServerState, prompt: []const u8) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) return "R36S especificacoes tecnicas RK3326 RAM tela";
    if (contains(prompt, "WEB_EVIDENCE_INPUT") and modelWebTargetContains(prompt, "/source-empty")) {
        return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/source-empty\nstatus=200\nquery=R36S especificacoes tecnicas RK3326 RAM tela\ntitle=R36S Empty\nsource_url=http://127.0.0.1/source-empty\nexcerpt=";
    }
    if (contains(prompt, "WEB_EVIDENCE_INPUT") and modelWebTargetContains(prompt, "/source")) {
        return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/source\nstatus=200\nquery=R36S especificacoes tecnicas RK3326 RAM tela\ntitle=R36S Specs\nsource_url=http://127.0.0.1/source\nexcerpt=Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.";
    }
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) {
        return std.fmt.bufPrint(
            &state.completion_buf,
            "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=R36S especificacoes tecnicas RK3326 RAM tela\ntitle=R36S results\nsource_url=http://127.0.0.1:{}/source-empty\nsource_url=http://127.0.0.1:{}/source\nexcerpt=result=1 title=R36S Specs snippet=Dados tecnicos do console R36S",
            .{ state.port, state.port },
        ) catch unreachable;
    }
    if (contains(prompt, "tool phase is closed")) return "Specs verificadas: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.\nPHENOM_WEB_SOURCE_FOLLOWED";
    return "preciso pesquisar specs\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>R36S especificacoes tecnicas RK3326 RAM tela</parameter><parameter=reason>buscar dados tecnicos externos</parameter></function></tool_call>";
}

fn modelWebTargetContains(prompt: []const u8, needle: []const u8) bool {
    return modelWebTargetContainsWithMarker(prompt, "[MODEL_WEB_TARGET]\n", "\n", needle) or
        modelWebTargetContainsWithMarker(prompt, "[MODEL_WEB_TARGET]\\n", "\\n", needle);
}

fn modelWebTargetContainsWithMarker(prompt: []const u8, marker: []const u8, line_end_marker: []const u8, needle: []const u8) bool {
    const start = (std.mem.indexOf(u8, prompt, marker) orelse return false) + marker.len;
    const end = if (std.mem.indexOfPos(u8, prompt, start, line_end_marker)) |rel| rel else prompt.len;
    return contains(prompt[start..end], needle);
}

fn languageCompletion(prompt: []const u8, empty: bool, completion_count: usize) []const u8 {
    if (contains(prompt, "MODEL_DECLARED_QUERY")) {
        if (empty and completion_count > 3) return "solar off-grid house cost components batteries inverter panels";
        return "solar off-grid house cost batteries inverter panels";
    }
    if (contains(prompt, "WEB_EVIDENCE_INPUT")) {
        if (empty and completion_count < 5) return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=solar off-grid house cost batteries inverter panels\ntitle=Solar Cost\nexcerpt=";
        return "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1/search\nstatus=200\nquery=solar off-grid house cost batteries inverter panels\ntitle=Solar Cost\nexcerpt=Solar off-grid systems require batteries, inverter, panels, and charge controllers.";
    }
    if (contains(prompt, "tool phase is closed")) return "user-lang-a: soma-bateria soma-inversor soma-painel soma-controlador.\nPHENOM_WEB_LANG_USER";
    if (empty and contains(prompt, "excerpt=")) return "refinar busca vazia\n</think>\n\n<tool_call><function=web_search><parameter=query>solar off-grid house cost components batteries inverter panels</parameter></function></tool_call>";
    if (contains(prompt, "source language")) return "user-lang-a: soma-bateria soma-inversor soma-painel soma-controlador.\nPHENOM_WEB_LANG_USER";
    return "precisa de evidencia externa\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=query>solar off-grid house cost batteries inverter panels</parameter><parameter=reason>estimar custo externo com evidencia</parameter></function></tool_call>";
}

fn searchHtml(state: *ServerState, request_line: []const u8, search_count: usize) []const u8 {
    return switch (state.scenario) {
        .initial_json_web => "<html><head><title>Londrina Location</title></head><body><p>Londrina fica no norte do Paraná, na região Sul do Brasil.</p></body></html>",
        .duplicate_web_json => "<html><head><title>Londrina Solar</title></head><body><p>Irradiacao solar em Londrina: 4,8 kWh/m2/dia.</p></body></html>",
        .web_query_intent_optimization => "<html><head><title>R36S Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>",
        .web_cache_reuse, .web_cache_expiry => "<html><head><title>R36S Cached Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>",
        .web_query_fanout => if (search_count == 1)
            "<html><head><title>No Direct Support</title></head><body><p>Pagina sem dados relacionados.</p></body></html>"
        else
            "<html><head><title>R36S Fanout Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>",
        .web_provider_fanout => providerFanoutHtml(request_line),
        .web_final_streaming => "<html><head><title>R36S Streaming Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>",
        .web_length_continuation => "<html><head><title>R36S Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>",
        .web_multi_length_continuation => "<html><head><title>R36S Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>",
        .length_usage_continuation => "<html><head><title>unused</title></head><body></body></html>",
        .web_source_followup => std.fmt.bufPrint(
            &state.completion_buf,
            "<html><head><title>R36S results</title></head><body><article><a href=\"http://127.0.0.1:{}/source-empty\">R36S Specs empty</a><p>Dados tecnicos do console R36S.</p></article><article><a href=\"http://127.0.0.1:{}/source\">R36S Specs source</a><p>Ficha tecnica do console R36S.</p></article></body></html>",
            .{ state.port, state.port },
        ) catch unreachable,
        .web_language => "<html><head><title>Solar Cost</title></head><body><p>Solar off-grid systems require batteries, inverter, panels, and charge controllers.</p></body></html>",
        .web_language_empty => if (contains(request_line, "components"))
            "<html><head><title>Solar Cost</title></head><body><p>Solar off-grid systems require batteries, inverter, panels, and charge controllers.</p></body></html>"
        else
            "<html><head><title>No Direct Support</title></head><body><p>Pagina sem dados relacionados.</p></body></html>",
    };
}

fn providerFanoutHtml(request_line: []const u8) []const u8 {
    if (contains(request_line, "/search-empty")) {
        _ = c.usleep(1_000_000);
        return "<html><head><title>No Provider Support</title></head><body><p>Pagina sem dados relacionados.</p></body></html>";
    }
    return "<html><head><title>R36S Provider Specs</title></head><body><p>Console R36S: RK3326, 1GB RAM, tela IPS 3.5 polegadas 480x320.</p></body></html>";
}

fn sourceHtml(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .web_source_followup =>
        \\<html><head>
        \\<title>Ficha tecnica completa do Console Portatil R36S</title>
        \\<meta name="description" content="Console R36S com Linux, processador RK3326, 1GB RAM e tela IPS.">
        \\<script type="application/ld+json">{"name":"Console Portatil R36S","processor":"RK3326","memory":"1GB RAM","display":"IPS 3.5 polegadas 480x320"}</script>
        \\</head><body>
        \\<table><tr><td>CPU</td><td>RK3326 quad-core</td></tr><tr><td>Memoria</td><td>1GB RAM</td></tr><tr><td>Tela</td><td>IPS 3.5 polegadas 480x320</td></tr></table>
        \\</body></html>
        ,
        else => "not found",
    };
}

fn sourceEmptyHtml(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .web_source_followup => "<html><head><title>R36S Empty</title></head><body><p>Pagina sem specs capturaveis.</p></body></html>",
        else => "not found",
    };
}

fn scenarioPrompt(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .initial_json_web => "onde fica localizado Londrina no Brasil , pesquise na internet",
        .duplicate_web_json => "como media a irradiacao solar em Londrina - PR, pesquise na internet. Responda contendo PHENOM_WEB_JSON_NORMALIZED.",
        .web_query_intent_optimization => "busque as especificacoes tecnicas do console R36S. pesquise na internet. Responda contendo PHENOM_WEB_QUERY_INTENT_OPTIMIZED.",
        .web_source_followup => "busque as informacoes tecnicas do console R36S. pesquise na internet. Responda contendo PHENOM_WEB_SOURCE_FOLLOWED.",
        .web_cache_reuse, .web_cache_expiry => "busque as especificacoes tecnicas do console R36S. pesquise na internet. Responda contendo PHENOM_WEB_CACHE_REUSED.",
        .web_query_fanout => "busque as especificacoes tecnicas do console R36S. pesquise na internet. Responda contendo PHENOM_WEB_QUERY_FANOUT.",
        .web_provider_fanout => "busque as especificacoes tecnicas do console R36S em provedores web. pesquise na internet. Responda contendo PHENOM_WEB_PROVIDER_FANOUT.",
        .web_final_streaming => "busque as especificacoes tecnicas do console R36S. pesquise na internet. Responda resposta media contendo PHENOM_WEB_FINAL_STREAMED.",
        .length_usage_continuation => "responda uma frase longa e termine contendo PHENOM_LENGTH_USAGE_CONTINUED.",
        .web_length_continuation => "busque as especificacoes tecnicas do console R36S. pesquise na internet. Responda contendo PHENOM_WEB_LENGTH_CONTINUED.",
        .web_multi_length_continuation => "busque as especificacoes tecnicas do console R36S. pesquise na internet. Responda contendo PHENOM_WEB_MULTI_LENGTH_CONTINUED.",
        .web_language, .web_language_empty => "Usuario esta usando o idioma operacional 'user-lang-a'. Pesquise e explique nesse idioma operacional o que entra no custo de uma casa off-grid solar. Responda contendo PHENOM_WEB_LANG_USER.",
    };
}

fn scenarioExpect(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .initial_json_web => "PHENOM_INITIAL_JSON_WEB_OK",
        .duplicate_web_json => "PHENOM_WEB_JSON_NORMALIZED",
        .web_query_intent_optimization => "PHENOM_WEB_QUERY_INTENT_OPTIMIZED",
        .web_source_followup => "PHENOM_WEB_SOURCE_FOLLOWED",
        .web_cache_reuse, .web_cache_expiry => "PHENOM_WEB_CACHE_REUSED",
        .web_query_fanout => "PHENOM_WEB_QUERY_FANOUT",
        .web_provider_fanout => "PHENOM_WEB_PROVIDER_FANOUT",
        .web_final_streaming => "PHENOM_WEB_FINAL_STREAMED",
        .length_usage_continuation => "PHENOM_LENGTH_USAGE_CONTINUED",
        .web_length_continuation => "PHENOM_WEB_LENGTH_CONTINUED",
        .web_multi_length_continuation => "PHENOM_WEB_MULTI_LENGTH_CONTINUED",
        .web_language, .web_language_empty => "PHENOM_WEB_LANG_USER",
    };
}

fn isWebScenario(scenario: Scenario) bool {
    return expectedWebSearchStarts(scenario) > 0;
}

fn expectedWebSearchStarts(scenario: Scenario) i64 {
    return switch (scenario) {
        .web_language_empty => 2,
        .web_source_followup => 3,
        .length_usage_continuation => 0,
        .web_length_continuation => 1,
        .web_multi_length_continuation => 1,
        else => 1,
    };
}

fn sendSse(client: c_int, text: []const u8) !void {
    var body_buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&body_buf);
    try stream.print("data: {{\"content\":\"", .{});
    try appendJsonStringBytes(&stream, text);
    try stream.print("\",\"stop\":true}}\n\n", .{});
    try send(client, "200 OK", "text/event-stream", stream.buffered());
}

fn sendSseWithUsage(client: c_int, text: []const u8, input_tokens: usize, output_tokens: usize) !void {
    var body_buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&body_buf);
    try stream.print("data: {{\"content\":\"", .{});
    try appendJsonStringBytes(&stream, text);
    try stream.print("\",\"done\":true,\"prompt_eval_count\":{},\"eval_count\":{}}}\n\n", .{ input_tokens, output_tokens });
    try send(client, "200 OK", "text/event-stream", stream.buffered());
}

fn sendSseChunkedText(client: c_int, text: []const u8, chunk_bytes: usize) !void {
    var body_buf: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&body_buf);
    var index: usize = 0;
    while (index < text.len) {
        const end = @min(index + chunk_bytes, text.len);
        try stream.print("data: {{\"content\":\"", .{});
        try appendJsonStringBytes(&stream, text[index..end]);
        if (end == text.len) {
            try stream.print("\",\"stop\":true}}\n\n", .{});
        } else {
            try stream.print("\"}}\n\n", .{});
        }
        index = end;
    }
    try send(client, "200 OK", "text/event-stream", stream.buffered());
}

fn send(client: c_int, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nServer: phenom-zig-agent-flow-smoke\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try sendAll(client, header);
    try sendAll(client, body);
}

fn sendAll(client: c_int, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.send(client, data[offset..].ptr, data.len - offset, 0);
        if (n <= 0) return SmokeError.SendFailed;
        offset += @intCast(n);
    }
}

fn appendJsonStringBytes(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
}

fn contentLength(header: []const u8) usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10) catch 0;
        }
    }
    return 0;
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (contains(text, needle)) return true;
    return false;
}

fn countOccurrences(text: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, text[offset..], needle)) |index| {
        count += 1;
        offset += index + needle.len;
    }
    return count;
}

fn expectCount(allocator: std.mem.Allocator, db_path: []const u8, sql: []const u8, expected: i64) !void {
    const got = try sqlScalar(allocator, db_path, sql);
    if (got != expected) return SmokeError.UnexpectedAudit;
}

fn expectAtLeast(allocator: std.mem.Allocator, db_path: []const u8, sql: []const u8, expected: i64) !void {
    const got = try sqlScalar(allocator, db_path, sql);
    if (got < expected) return SmokeError.UnexpectedAudit;
}

fn sqlScalar(allocator: std.mem.Allocator, db_path: []const u8, sql: []const u8) !i64 {
    const z_path = try allocator.dupeZ(u8, db_path);
    defer allocator.free(z_path);
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(z_path.ptr, &db) != c.SQLITE_OK) return SmokeError.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);

    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return SmokeError.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return SmokeError.SqliteStepFailed;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

fn execSql(allocator: std.mem.Allocator, db_path: []const u8, sql: []const u8) !void {
    const z_path = try allocator.dupeZ(u8, db_path);
    defer allocator.free(z_path);
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(z_path.ptr, &db) != c.SQLITE_OK) return SmokeError.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);

    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(db, z_sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return SmokeError.SqliteStepFailed;
    }
}
