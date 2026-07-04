const std = @import("std");
const fd_writer = @import("fd_writer.zig");

pub const RenderOptions = struct {
    color: bool = true,
};

pub fn AppendOnlyRenderer(comptime Writer: type) type {
    return struct {
        writer: Writer,
        options: RenderOptions,
        assistant_open: bool = false,
        thinking_open: bool = false,

        pub fn init(writer: Writer, options: RenderOptions) @This() {
            return .{ .writer = writer, .options = options };
        }

        pub fn user(self: *@This(), text: []const u8) !void {
            try self.writer.writeAll("> user\n");
            try self.writer.writeAll(text);
            try self.writer.writeAll("\n\n");
        }

        pub fn assistantStart(self: *@This()) !void {
            try self.writer.writeAll("assistant\n");
            self.assistant_open = true;
        }

        pub fn assistantDelta(self: *@This(), text: []const u8) !void {
            try self.writer.writeAll(text);
        }

        pub fn thinkingDelta(self: *@This(), text: []const u8) !void {
            if (!self.thinking_open) {
                try self.writer.writeAll("thinking\n");
                self.thinking_open = true;
            }
            if (self.options.color) try self.writer.writeAll("\x1b[2m");
            try self.writer.writeAll(text);
            if (self.options.color) try self.writer.writeAll("\x1b[0m");
        }

        pub fn thinkingEnd(self: *@This()) !void {
            if (!self.thinking_open) return;
            try self.writer.writeAll("\n\nassistant\n");
            self.thinking_open = false;
        }

        pub fn toolSample(self: *@This(), name: []const u8, sample: []const u8) !void {
            if (self.assistant_open) {
                try self.writer.writeAll("\n\n");
                self.assistant_open = false;
            }
            try self.writer.print("tool {s}\n", .{name});
            try self.writer.writeAll(sample);
            try self.writer.writeAll("\n\n");
        }

        pub fn status(self: *@This(), text: []const u8) !void {
            if (self.thinking_open) try self.thinkingEnd();
            if (self.assistant_open) {
                try self.writer.writeAll("\n\n");
                self.assistant_open = false;
            }
            try self.writer.print("status {s}\n", .{text});
        }

        pub fn done(self: *@This()) !void {
            if (self.thinking_open) try self.thinkingEnd();
            if (self.assistant_open) {
                try self.writer.writeAll("\n\n");
            } else {
                try self.writer.writeAll("\n");
            }
            try self.writer.writeAll("done\n");
            self.assistant_open = false;
        }
    };
}

test "thinking renders dim and separates final output" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.thinkingDelta("interno");
    try renderer.thinkingEnd();
    try renderer.assistantDelta("final");

    const expected =
        \\assistant
        \\thinking
        \\interno
        \\
        \\assistant
        \\final
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "append only snapshot" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.user("ola");
    try renderer.assistantStart();
    try renderer.assistantDelta("ok");
    try renderer.done();

    const expected =
        \\> user
        \\ola
        \\
        \\assistant
        \\ok
        \\
        \\done
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "status after assistant delta starts on separate block" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.assistantDelta("PHENOM_REAL_7319");
    try renderer.status("success expected visible text found: PHENOM_REAL_7319");
    try renderer.done();

    const expected =
        \\assistant
        \\PHENOM_REAL_7319
        \\
        \\status success expected visible text found: PHENOM_REAL_7319
        \\
        \\done
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}
