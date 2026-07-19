const std = @import("std");

pub fn isAllowed(tool_name: []const u8, allowed: []const []const u8) bool {
    for (allowed) |name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

test "tool not announced never executes" {
    const allowed = &.{ "read_file_range" };
    try std.testing.expect(isAllowed("read_file_range", allowed));
    try std.testing.expect(!isAllowed("shell", allowed));
    try std.testing.expect(!isAllowed("content", allowed));
}
