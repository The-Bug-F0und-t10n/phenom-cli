const std = @import("std");

const audit = @import("audit.zig");
const cli = @import("cli.zig");
const evidence = @import("evidence.zig");
const fd_writer = @import("fd_writer.zig");
const gate = @import("gate.zig");
const http = @import("http.zig");
const micro_context = @import("micro_context.zig");
const reasoning_filter = @import("reasoning_filter.zig");
const render = @import("render.zig");
const tool_call = @import("tool_call.zig");
const tool_loop = @import("tool_loop.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const config = cli.parseArgs(args_list.items) catch |err| {
        try cli.printUsage(fd_writer.FdWriter{ .fd = 2 });
        return err;
    };

    switch (config.command) {
        .help => try cli.printUsage(fd_writer.FdWriter{ .fd = 1 }),
        .version => try (fd_writer.FdWriter{ .fd = 1 }).print("phenom-zig spike 0.1.0\n", .{}),
        .chat => try runChat(allocator, config),
        .probe => try runProbe(allocator, config),
        .snapshot => try runSnapshot(),
    }
}

fn runProbe(allocator: std.mem.Allocator, config: cli.Config) !void {
    const stdout = fd_writer.FdWriter{ .fd = 1 };
    const result = http.probeBackend(allocator, config.host, config.backend);
    defer result.deinit(allocator);

    try stdout.writeAll("probe\n");
    try stdout.print("backend {s}\n", .{backendName(config.backend)});
    try stdout.print("endpoint {s}\n", .{result.endpoint});

    if (result.tcp_ok) {
        try stdout.writeAll("tcp success\n");
    } else {
        try stdout.print("tcp fail error={s}\n", .{result.error_name orelse "unknown"});
        try stdout.writeAll("result fail\n");
        std.process.exit(1);
    }

    if (result.http_ok) {
        try stdout.print("http success status={}\n", .{result.status orelse 0});
    } else {
        if (result.status) |status| {
            try stdout.print("http fail status={} error={s}\n", .{ status, result.error_name orelse "none" });
        } else {
            try stdout.print("http fail status=none error={s}\n", .{result.error_name orelse "unknown"});
        }
        try stdout.writeAll("result fail\n");
        std.process.exit(1);
    }

    if (result.server) |server| {
        try stdout.print("server {s}\n", .{server});
    }
    try stdout.writeAll("result success\n");
}

fn backendName(backend: cli.Backend) []const u8 {
    return switch (backend) {
        .ollama => "ollama",
        .llamacpp => "llamacpp",
    };
}

fn runChat(allocator: std.mem.Allocator, config: cli.Config) !void {
    const stdout = fd_writer.FdWriter{ .fd = 1 };
    if (!config.prompt_provided) return runInteractiveChat(allocator, config, stdout);
    try runChatTurn(allocator, config, stdout, config.prompt);
}

fn runInteractiveChat(allocator: std.mem.Allocator, config: cli.Config, stdout: fd_writer.FdWriter) !void {
    var ui = tui.TerminalUi(@TypeOf(stdout)).init(allocator, stdout, !config.no_color);
    var attached = false;
    defer if (attached) ui.deinit();

    ui.attach() catch |err| switch (err) {
        error.NotATty => {
            try cli.printUsage(fd_writer.FdWriter{ .fd = 2 });
            return error.MissingPrompt;
        },
        else => return err,
    };
    attached = true;
    try makeDirIfMissing(".phenom-zig");
    var db = try audit.AuditDb.open(allocator, ".phenom-zig/phenom.db");
    defer db.close();
    try loadHistoryFromDb(allocator, &db, &ui);

    while (true) {
        const line = ui.readLine() catch |err| switch (err) {
            error.Cancelled => return,
            else => return err,
        };
        const prompt = line orelse {
            ui.deinit();
            attached = false;
            try stdout.writeAll("Session saved. Use phenom chat to continue.\n");
            return;
        };
        defer allocator.free(prompt);
        if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
            try ui.showPrompt();
            continue;
        }
        const input = std.mem.trim(u8, prompt, " \t\r\n");
        try db.recordInputHistory(input);
        if (std.mem.eql(u8, input, "/exit")) {
            ui.deinit();
            attached = false;
            try stdout.writeAll("Session saved. Use phenom chat to continue.\n");
            return;
        }
        if (std.mem.eql(u8, input, "/reset")) {
            try ui.showPrompt();
            continue;
        }

        try ui.showStatus("Thinking (0s · esc to interrupt)");
        try ui.positionContent();
        try runChatTurnWithUi(allocator, config, stdout, prompt, &ui);
        try ui.showDone();
    }
}

fn runChatTurn(allocator: std.mem.Allocator, config: cli.Config, stdout: fd_writer.FdWriter, prompt: []const u8) !void {
    try runChatTurnWithUi(allocator, config, stdout, prompt, null);
}

fn runChatTurnWithUi(allocator: std.mem.Allocator, config: cli.Config, stdout: fd_writer.FdWriter, prompt: []const u8, ui: anytype) !void {
    const size = tui.terminalSize();
    var renderer = render.AppendOnlyRenderer(@TypeOf(stdout)).init(stdout, .{ .color = !config.no_color, .terminal_columns = size.cols, .user_label = userLabel() });

    try makeDirIfMissing(".phenom-zig");
    var db = try audit.AuditDb.open(allocator, ".phenom-zig/phenom.db");
    defer db.close();

    try db.recordEvent(config.session, "turn_start", prompt);
    try renderer.user(prompt);

    if (config.demo_read_file) |path| {
        const allowed = gate.isAllowed("read_file_range", &.{"read_file_range"});
        if (!allowed) return error.ToolDenied;
        const range = try tools.readFileRange(allocator, path, 1, 12, 16 * 1024);
        defer range.deinit(allocator);
        const entry = try evidence.fromFileRange(allocator, range);
        var packet = evidence.EvidencePacket.init(allocator);
        defer packet.deinit();
        try packet.add(entry);
        const rendered = try packet.render(allocator);
        defer allocator.free(rendered);
        try db.recordEvent(config.session, "evidence", rendered);
        try renderer.toolSample("read_file_range", rendered);
    }

    try renderer.assistantStart();

    if (config.offline) {
        try renderer.assistantDelta("ok");
        try db.recordEvent(config.session, "assistant", "ok");
    } else {
        var client = http.LocalModelClient{
            .allocator = allocator,
            .host = config.host,
            .backend = config.backend,
            .model = config.model,
            .max_tokens = config.max_tokens,
            .thinking = config.thinking,
        };
        var sink = StreamSink(@TypeOf(&renderer)){
            .allocator = allocator,
            .renderer = &renderer,
            .db = &db,
            .session = config.session,
            .ui = ui,
            .filter = reasoning_filter.ReasoningFilter.init(allocator, http.resolveThinking(config.thinking, prompt) == .on),
            .visible = std.ArrayList(u8).empty,
            .visible_bytes = 0,
            .thinking_bytes = 0,
        };
        defer sink.deinit();
        client.streamChat(prompt, &sink) catch |err| {
            const endpoint = client.endpointSummary(allocator) catch "unknown-endpoint";
            defer if (!std.mem.eql(u8, endpoint, "unknown-endpoint")) allocator.free(endpoint);
            const message = try std.fmt.allocPrint(
                allocator,
                "model connection failed: {s} endpoint={s}",
                .{ @errorName(err), endpoint },
            );
            defer allocator.free(message);
            try renderer.status(message);
            try db.recordEvent(config.session, "model_error", @errorName(err));
            try renderer.done();
            if (config.fail_on_model_error) return err;
            return;
        };
        try sink.flush();
        if (sink.visible_bytes == 0) {
            try renderer.status("model emitted no visible final answer; reasoning was suppressed or generation ended inside <think>");
            try db.recordEvent(config.session, "empty_visible_answer", "reasoning_suppressed_or_unclosed");
        }
        if (config.expect_contains) |expected| {
            if (std.mem.indexOf(u8, sink.visible.items, expected) == null) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "fail expected visible text missing: {s}",
                    .{expected},
                );
                defer allocator.free(message);
                try renderer.status(message);
                try db.recordEvent(config.session, "expectation_failed", expected);
                try renderer.done();
                return error.ExpectedVisibleOutputMissing;
            }
            try db.recordEvent(config.session, "expectation_passed", expected);
            if (config.show_expect_status) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "success expected visible text found: {s}",
                    .{expected},
                );
                defer allocator.free(message);
                try renderer.status(message);
            }
        }
    }

    try renderer.done();
    try db.recordEvent(config.session, "turn_done", "ok");
}

fn userLabel() []const u8 {
    if (c.getenv("USER")) |value| {
        const span = std.mem.span(value);
        if (span.len > 0) return span;
    }
    return "user";
}

fn loadHistoryFromDb(allocator: std.mem.Allocator, db: *audit.AuditDb, ui: anytype) !void {
    var lines = try db.loadInputHistoryNewestFirst(allocator, 200);
    defer audit.freeHistoryLines(allocator, &lines);
    try ui.editor.loadHistoryNewestFirst(lines.items);
}

fn StreamSink(comptime RendererPtr: type) type {
    return struct {
        allocator: std.mem.Allocator,
        renderer: RendererPtr,
        db: *audit.AuditDb,
        session: []const u8,
        ui: ?*tui.TerminalUi(fd_writer.FdWriter),
        filter: reasoning_filter.ReasoningFilter,
        visible: std.ArrayList(u8),
        visible_bytes: usize,
        thinking_bytes: usize,

        pub fn deinit(ctx: *@This()) void {
            ctx.filter.deinit();
            ctx.visible.deinit(ctx.allocator);
        }

        pub fn onDelta(ctx: *@This(), delta: []const u8) !void {
            try ctx.filter.feed(delta, ctx);
        }

        pub fn flush(ctx: *@This()) !void {
            try ctx.filter.flush(ctx);
        }

        pub fn writeVisible(ctx: *@This(), visible: []const u8) !void {
            ctx.visible_bytes += visible.len;
            try ctx.visible.appendSlice(ctx.allocator, visible);
            try ctx.renderer.assistantDelta(visible);
            if (ctx.ui) |ui| try ui.pulseStatus();
            try ctx.db.recordEvent(ctx.session, "assistant_delta", visible);
        }

        pub fn writeThinking(ctx: *@This(), thinking: []const u8) !void {
            ctx.thinking_bytes += thinking.len;
            try ctx.renderer.thinkingDelta(thinking);
            if (ctx.ui) |ui| try ui.pulseStatus();
            try ctx.db.recordEvent(ctx.session, "assistant_thinking_delta", thinking);
        }

        pub fn endThinking(ctx: *@This()) !void {
            try ctx.renderer.thinkingEnd();
        }
    };
}

fn runSnapshot() !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.heap.page_allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.heap.page_allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.user("ola");
    try renderer.assistantStart();
    try renderer.assistantDelta("ok");
    try renderer.done();
    try (fd_writer.FdWriter{ .fd = 1 }).writeAll(buffer.items);
}

fn makeDirIfMissing(path: []const u8) !void {
    var buf: [256]u8 = undefined;
    if (path.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (c.mkdir(@ptrCast(&buf), 0o755) != 0) {
        if (c.__errno_location().* != c.EEXIST) return error.MkdirFailed;
    }
}

test {
    _ = audit;
    _ = cli;
    _ = evidence;
    _ = fd_writer;
    _ = gate;
    _ = http;
    _ = micro_context;
    _ = reasoning_filter;
    _ = render;
    _ = tool_call;
    _ = tool_loop;
    _ = tools;
    _ = tui;
}
