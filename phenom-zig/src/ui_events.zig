const std = @import("std");

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
    token_update: TokenUpdate,
    file_diff: FileDiff,
    inference_cancel: []const u8,
    clear_streaming: void,
    progress_update: []const u8,
};

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
        write_mutex: ?*std.atomic.Mutex = null,
        terminal_columns: ?*const fn () usize = null,
        assistant_started: bool = false,
        turn_started_ms: i64 = 0,

        const Self = @This();

        pub fn handleOpaque(ctx: *anyopaque, event: Event) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.handle(event);
        }

        pub fn handle(self: *Self, event: Event) !void {
            if (self.write_mutex) |mutex| {
                lockTerminal(mutex);
                defer mutex.unlock();
            }
            if (self.terminal_columns) |columns| self.renderer.setTerminalColumns(columns());
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
                .clear_streaming => {},
                .think_end => {
                    try self.finish(null);
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

test "renderer sink maps chat events to transcript" {
    const fd_writer = @import("fd_writer.zig");
    const render = @import("render.zig");

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });

    var sink = RendererEventSink(@TypeOf(&renderer)){ .renderer = &renderer };
    try sink.handle(.{ .user_message = "ola" });
    try sink.handle(.{ .think_start = "Thinking" });
    try sink.handle(.{ .message_chunk = "resposta" });
    try sink.handle(.{ .think_end = {} });

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "> [user] ola") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "resposta") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Worked for") != null);
}
