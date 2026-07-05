const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
});

pub const FdWriter = struct {
    fd: i32,

    pub fn writeAll(self: FdWriter, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const written_raw = c.write(self.fd, rest.ptr, rest.len);
            if (written_raw < 0) return error.WriteFailed;
            const written: usize = @intCast(written_raw);
            rest = rest[written..];
        }
    }

    pub fn print(self: FdWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};

pub const BufferWriter = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn writeAll(self: BufferWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.writeAll(text);
    }
};

pub fn NewlineWriter(comptime Inner: type) type {
    return struct {
        inner: Inner,
        crlf: bool = false,
        prev_cr: bool = false,

        const Self = @This();

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            if (!self.crlf) {
                try self.inner.writeAll(bytes);
                if (bytes.len > 0) self.prev_cr = bytes[bytes.len - 1] == '\r';
                return;
            }

            var start: usize = 0;
            var i: usize = 0;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] != '\n') continue;
                if (i > start) try self.inner.writeAll(bytes[start..i]);
                const has_cr = if (i > 0) bytes[i - 1] == '\r' else self.prev_cr;
                if (!has_cr) try self.inner.writeAll("\r");
                try self.inner.writeAll("\n");
                self.prev_cr = false;
                start = i + 1;
            }
            if (start < bytes.len) {
                try self.inner.writeAll(bytes[start..]);
                self.prev_cr = bytes[bytes.len - 1] == '\r';
            }
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            var buf: [4096]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, fmt, args);
            try self.writeAll(text);
        }
    };
}

test "newline writer translates lf for raw terminal transcript" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const inner = BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var writer = NewlineWriter(@TypeOf(inner)){ .inner = inner, .crlf = true };
    try writer.writeAll("a\nb");
    try writer.writeAll("\r\nc\n");

    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\n", buffer.items);
}
