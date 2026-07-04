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
