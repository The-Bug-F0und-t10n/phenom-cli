const std = @import("std");
const fd_writer = @import("fd_writer.zig");
const render = @import("render.zig");

const c = @cImport({
    @cInclude("time.h");
});

pub const EventType = enum {
    user_message,
    agent_message,
    message_chunk,
    reasoning_chunk,
    tool_start,
    tool_result,
    tool_error,
    think_start,
    think_end,
    turn_done,
    context_update,
    token_update,
    file_diff,
    inference_cancel,
    clear_streaming,
    progress_update,
};

pub const ToolStart = struct {
    name: []const u8,
    detail: []const u8 = "",
};

pub const ToolResult = struct {
    name: []const u8,
    output: []const u8 = "",
    success: bool = true,
};

pub const ToolError = struct {
    name: []const u8,
    message: []const u8,
    output: []const u8 = "",
};

pub const FileDiff = struct {
    path: []const u8,
    action: []const u8,
    content: []const u8,
};

pub const TokenUpdate = struct {
    total: usize = 0,
    input: usize = 0,
    output: usize = 0,
    tokens_per_second: ?f64 = null,
};

pub const TurnDone = struct {
    elapsed_ms: ?u64 = null,
};

pub const ContextUpdate = struct {
    used_tokens: usize,
    limit_tokens: usize,
};

pub const Event = union(EventType) {
    user_message: []const u8,
    agent_message: []const u8,
    message_chunk: []const u8,
    reasoning_chunk: []const u8,
    tool_start: ToolStart,
    tool_result: ToolResult,
    tool_error: ToolError,
    think_start: []const u8,
    think_end: void,
    turn_done: TurnDone,
    context_update: ContextUpdate,
    token_update: TokenUpdate,
    file_diff: FileDiff,
    inference_cancel: []const u8,
    clear_streaming: void,
    progress_update: []const u8,
};

fn cloneEvent(allocator: std.mem.Allocator, event: Event) !Event {
    return switch (event) {
        .user_message => |text| .{ .user_message = try allocator.dupe(u8, text) },
        .agent_message => |text| .{ .agent_message = try allocator.dupe(u8, text) },
        .message_chunk => |text| .{ .message_chunk = try allocator.dupe(u8, text) },
        .reasoning_chunk => |text| .{ .reasoning_chunk = try allocator.dupe(u8, text) },
        .tool_start => |tool| .{ .tool_start = .{ .name = try allocator.dupe(u8, tool.name), .detail = try allocator.dupe(u8, tool.detail) } },
        .tool_result => |result| .{ .tool_result = .{ .name = try allocator.dupe(u8, result.name), .output = try allocator.dupe(u8, result.output), .success = result.success } },
        .tool_error => |tool| .{ .tool_error = .{ .name = try allocator.dupe(u8, tool.name), .message = try allocator.dupe(u8, tool.message), .output = try allocator.dupe(u8, tool.output) } },
        .think_start => |text| .{ .think_start = try allocator.dupe(u8, text) },
        .think_end => .{ .think_end = {} },
        .turn_done => |done| .{ .turn_done = done },
        .context_update => |update| .{ .context_update = update },
        .token_update => |update| .{ .token_update = update },
        .file_diff => |diff| .{ .file_diff = .{ .path = try allocator.dupe(u8, diff.path), .action = try allocator.dupe(u8, diff.action), .content = try allocator.dupe(u8, diff.content) } },
        .inference_cancel => |text| .{ .inference_cancel = try allocator.dupe(u8, text) },
        .clear_streaming => .{ .clear_streaming = {} },
        .progress_update => |text| .{ .progress_update = try allocator.dupe(u8, text) },
    };
}

fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    switch (event) {
        .user_message, .agent_message, .message_chunk, .reasoning_chunk, .think_start, .inference_cancel, .progress_update => |text| allocator.free(text),
        .tool_start => |tool| {
            allocator.free(tool.name);
            allocator.free(tool.detail);
        },
        .tool_result => |result| {
            allocator.free(result.name);
            allocator.free(result.output);
        },
        .tool_error => |tool| {
            allocator.free(tool.name);
            allocator.free(tool.message);
            allocator.free(tool.output);
        },
        .file_diff => |diff| {
            allocator.free(diff.path);
            allocator.free(diff.action);
            allocator.free(diff.content);
        },
        .think_end, .turn_done, .context_update, .token_update, .clear_streaming => {},
    }
}

pub const Handler = struct {
    ctx: *anyopaque,
    call: *const fn (*anyopaque, Event) anyerror!void,
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(Handler),

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(Handler).empty,
        };
    }

    pub fn deinit(self: *EventBus) void {
        self.handlers.deinit(self.allocator);
    }

    pub fn on(self: *EventBus, ctx: *anyopaque, call: *const fn (*anyopaque, Event) anyerror!void) !void {
        try self.handlers.append(self.allocator, .{ .ctx = ctx, .call = call });
    }

    pub fn emit(self: *EventBus, event: Event) !void {
        for (self.handlers.items) |handler| {
            try handler.call(handler.ctx, event);
        }
    }
};

pub fn RendererEventSink(comptime RendererPtr: type) type {
    return struct {
        renderer: RendererPtr,
        allocator: ?std.mem.Allocator = null,
        write_mutex: ?*std.atomic.Mutex = null,
        terminal_columns: ?*const fn () usize = null,
        terminal_rows: ?*const fn () usize = null,
        layout_ctx: ?*anyopaque = null,
        content_row: ?*const fn (*anyopaque) usize = null,
        prepare_redraw_ctx: ?*anyopaque = null,
        prepare_redraw: ?*const fn (*anyopaque) anyerror!void = null,
        history: std.ArrayList(Event) = .empty,
        rendered_columns: usize = 0,
        rendered_rows: usize = 0,
        assistant_started: bool = false,
        turn_started_ms: i64 = 0,

        const Self = @This();

        pub fn handleOpaque(ctx: *anyopaque, event: Event) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.handle(event);
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator orelse return;
            for (self.history.items) |event| freeEvent(allocator, event);
            self.history.deinit(allocator);
        }

        pub fn handle(self: *Self, event: Event) !void {
            if (self.write_mutex) |mutex| {
                lockTerminal(mutex);
                defer mutex.unlock();
            }
            try self.redrawIfNeededUnlocked();
            try self.render(event);
            if (self.allocator) |allocator| try self.history.append(allocator, try cloneEvent(allocator, event));
        }

        pub fn redrawIfNeeded(self: *Self) !void {
            if (self.write_mutex) |mutex| {
                lockTerminal(mutex);
                defer mutex.unlock();
            }
            try self.redrawIfNeededUnlocked();
        }

        pub fn redrawIfNeededAssumeLocked(self: *Self) !void {
            try self.redrawIfNeededUnlocked();
        }

        fn redrawIfNeededUnlocked(self: *Self) !void {
            const columns = if (self.terminal_columns) |current| current() else 0;
            const rows = if (self.terminal_rows) |current| current() else 0;
            const size_changed = (columns > 0 and self.rendered_columns > 0 and columns != self.rendered_columns) or
                (rows > 0 and self.rendered_rows > 0 and rows != self.rendered_rows);
            if (size_changed and self.history.items.len > 0) {
                if (self.prepare_redraw_ctx) |ctx| {
                    if (self.prepare_redraw) |prepare| {
                        self.renderer.resetForRedraw(columns);
                        try prepare(ctx);
                    } else {
                        try self.renderer.redrawStart(columns);
                    }
                } else {
                    try self.renderer.redrawStart(columns);
                    if (self.layout_ctx) |ctx| {
                        if (self.content_row) |current| try self.renderer.positionAtRow(current(ctx));
                    }
                }
                self.assistant_started = false;
                self.turn_started_ms = 0;
                for (self.history.items) |recorded| try self.render(recorded);
            } else if (columns > 0) {
                self.renderer.setTerminalColumns(columns);
            }
            if (columns > 0) self.rendered_columns = columns;
            if (rows > 0) self.rendered_rows = rows;
        }

        fn render(self: *Self, event: Event) !void {
            switch (event) {
                .user_message => |text| {
                    if (self.turn_started_ms == 0) self.turn_started_ms = monotonicMillis();
                    try self.renderer.user(text);
                },
                .think_start => {
                    self.assistant_started = false;
                    self.turn_started_ms = monotonicMillis();
                },
                .message_chunk, .agent_message => |text| {
                    try self.ensureAssistantStarted();
                    try self.renderer.assistantDelta(text);
                },
                .reasoning_chunk => |text| try self.renderer.thinkingDelta(text),
                .tool_start => |tool| try self.renderer.toolStart(tool.name, tool.detail),
                .tool_result => |result| {
                    if (!result.success) {
                        try self.renderer.toolFailure(if (result.output.len > 0) result.output else "failed");
                        return;
                    }
                    try self.renderer.toolOutput(result.output);
                },
                .tool_error => |tool| {
                    const message = if (tool.output.len > 0) tool.output else tool.message;
                    if (tool.message.len > 0) try self.renderer.toolStart(tool.name, tool.message);
                    try self.renderer.toolFailure(message);
                },
                .file_diff => |diff| try self.renderer.diff(diff.path, diff.action, diff.content),
                .inference_cancel => |reason| try self.renderer.status(reason),
                .progress_update => |message| try self.renderer.status(message),
                .token_update => {},
                .context_update => {},
                .clear_streaming => {},
                .think_end => {
                    try self.renderer.thinkingEnd();
                },
                .turn_done => |done| {
                    try self.finish(done.elapsed_ms);
                },
            }
        }

        fn ensureAssistantStarted(self: *Self) !void {
            if (self.assistant_started) return;
            try self.renderer.assistantStart();
            self.assistant_started = true;
        }

        fn finish(self: *Self, stored_elapsed_ms: ?u64) !void {
            var elapsed_buf: [32]u8 = undefined;
            const elapsed_ms = stored_elapsed_ms orelse elapsedMillisSince(self.turn_started_ms);
            const elapsed = formatElapsedMillis(&elapsed_buf, elapsed_ms);
            try self.renderer.doneWithElapsed(elapsed);
            self.assistant_started = false;
            self.turn_started_ms = 0;
        }
    };
}

fn formatTokenCount(buf: *[24]u8, value: usize) []const u8 {
    if (value >= 1_000_000) {
        const whole = value / 1_000_000;
        const tenth = (value % 1_000_000) / 100_000;
        if (tenth == 0) return std.fmt.bufPrint(buf, "{}m", .{whole}) catch "?";
        return std.fmt.bufPrint(buf, "{}.{}m", .{ whole, tenth }) catch "?";
    }
    if (value >= 10_000) return std.fmt.bufPrint(buf, "{}k", .{value / 1000}) catch "?";
    if (value >= 1000) {
        const whole = value / 1000;
        const tenth = (value % 1000) / 100;
        if (tenth == 0) return std.fmt.bufPrint(buf, "{}k", .{whole}) catch "?";
        return std.fmt.bufPrint(buf, "{}.{}k", .{ whole, tenth }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{}", .{value}) catch "?";
}

pub fn elapsedMillisSince(start_ms: i64) u64 {
    if (start_ms <= 0) return 0;
    const now = monotonicMillis();
    if (now <= start_ms) return 0;
    return @intCast(now - start_ms);
}

pub fn monotonicMillis() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

pub fn formatElapsedMillis(buf: *[32]u8, elapsed_ms: u64) []const u8 {
    const total_seconds = elapsed_ms / 1000;
    const minutes = total_seconds / 60;
    const seconds = total_seconds % 60;
    if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{}m {}s", .{ minutes, seconds }) catch "0s";
    }
    return std.fmt.bufPrint(buf, "{}s", .{seconds}) catch "0s";
}

fn lockTerminal(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

var test_terminal_columns: usize = 80;

fn testTerminalColumns() usize {
    return test_terminal_columns;
}

test "event bus dispatches events in registration order" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const State = struct {
        value: usize = 0,

        fn addOne(ctx: *anyopaque, event: Event) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .user_message) state.value = state.value * 10 + 1;
        }

        fn addTwo(ctx: *anyopaque, event: Event) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .user_message) state.value = state.value * 10 + 2;
        }
    };

    var state = State{};
    try bus.on(&state, State.addOne);
    try bus.on(&state, State.addTwo);
    try bus.emit(.{ .user_message = "ola" });

    try std.testing.expectEqual(@as(usize, 12), state.value);
}

test "renderer sink keeps context usage out of final worked line" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 80 });
    var sink = RendererEventSink(@TypeOf(&renderer)){ .renderer = &renderer };

    try sink.handle(.{ .user_message = "ola" });
    try sink.handle(.{ .context_update = .{ .used_tokens = 737, .limit_tokens = 65_536 } });
    try sink.handle(.{ .message_chunk = "ok" });
    try sink.handle(.{ .turn_done = .{ .elapsed_ms = 5000 } });

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Worked for 5s") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "ctx 1.1% 737/65k tok") == null);
}

test "renderer sink maps chat events to transcript" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });

    var sink = RendererEventSink(@TypeOf(&renderer)){ .renderer = &renderer };
    try sink.handle(.{ .user_message = "ola" });
    try sink.handle(.{ .think_start = "Thinking" });
    try sink.handle(.{ .message_chunk = "resposta" });
    try sink.handle(.{ .think_end = {} });
    try sink.handle(.{ .turn_done = .{ .elapsed_ms = 0 } });

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "> [user] ola") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "resposta") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Worked for") != null);
}

test "renderer sink replays responsive components after resize" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 40 });
    var sink = RendererEventSink(@TypeOf(&renderer)){
        .renderer = &renderer,
        .allocator = std.testing.allocator,
        .terminal_columns = testTerminalColumns,
    };
    defer sink.deinit();

    test_terminal_columns = 40;
    try sink.handle(.{ .user_message = "consulta responsiva longa" });
    try sink.handle(.{ .message_chunk = "| Nome | Descricao |\n| --- | --- |\n| A | texto longo dentro da celula |\n" });
    test_terminal_columns = 20;
    try sink.handle(.{ .progress_update = "redimensionado" });

    const redraw_sequence = "\x1b[3J\x1b[H\x1b[2J";
    const redraw = std.mem.lastIndexOf(u8, buffer.items, redraw_sequence) orelse return error.ExpectedRedraw;
    const replay = buffer.items[redraw + redraw_sequence.len ..];
    try std.testing.expect(std.mem.indexOf(u8, replay, "> [user] consulta") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "│ Nome") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "│      │ longo") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "redimensionado") != null);
}

test "renderer sink reflows assistant text after horizontal resize" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 40 });
    var sink = RendererEventSink(@TypeOf(&renderer)){
        .renderer = &renderer,
        .allocator = std.testing.allocator,
        .terminal_columns = testTerminalColumns,
    };
    defer sink.deinit();

    test_terminal_columns = 40;
    try sink.handle(.{ .user_message = "consulta" });
    try sink.handle(.{ .message_chunk = "abcdefghijklmnopqrstuvwxyz" });
    test_terminal_columns = 12;
    try sink.redrawIfNeeded();

    const redraw_sequence = "\x1b[3J\x1b[H\x1b[2J";
    const redraw = std.mem.lastIndexOf(u8, buffer.items, redraw_sequence) orelse return error.ExpectedRedraw;
    const replay = buffer.items[redraw + redraw_sequence.len ..];
    try std.testing.expect(std.mem.indexOf(u8, replay, " abcdefghij\n klmnopqrst\n uvwxyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, " abcdefghijklmnopqrstuvwxyz") == null);
}

test "renderer sink uses prepared redraw without full screen clear" {
    const State = struct {
        buffer: *std.ArrayList(u8),

        fn prepare(ctx: *anyopaque) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            try state.buffer.appendSlice(std.testing.allocator, "\x1b[1;1H\x1b[2K\x1b[9;1H");
        }
    };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 40 });
    var state = State{ .buffer = &buffer };
    var sink = RendererEventSink(@TypeOf(&renderer)){
        .renderer = &renderer,
        .allocator = std.testing.allocator,
        .terminal_columns = testTerminalColumns,
        .prepare_redraw_ctx = &state,
        .prepare_redraw = State.prepare,
    };
    defer sink.deinit();

    test_terminal_columns = 40;
    try sink.handle(.{ .user_message = "consulta" });
    try sink.handle(.{ .message_chunk = "resposta" });
    test_terminal_columns = 20;
    try sink.redrawIfNeeded();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[2J") == null);
    const prepared = std.mem.lastIndexOf(u8, buffer.items, "\x1b[9;1H") orelse return error.ExpectedPreparedRedraw;
    const replay = std.mem.indexOfPos(u8, buffer.items, prepared, "> [user] consulta") orelse return error.ExpectedReplay;
    try std.testing.expect(replay > prepared);
}
