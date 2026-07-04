const std = @import("std");
const tools = @import("tools.zig");

pub const MicroContext = struct {
    path: []const u8,
    start_line: usize,
    end_line: usize,
    hash: u64,

    pub fn fromFileRange(range: tools.FileRange) MicroContext {
        return .{
            .path = range.path,
            .start_line = range.start_line,
            .end_line = range.end_line,
            .hash = range.hash,
        };
    }

    pub fn render(self: MicroContext, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "[MICRO_CONTEXT path={s} lines={}-{} hash={x}]",
            .{ self.path, self.start_line, self.end_line, self.hash },
        );
    }
};

test "micro context renders path range and hash" {
    const ctx = MicroContext{
        .path = "README.md",
        .start_line = 1,
        .end_line = 3,
        .hash = 0xabc,
    };
    const rendered = try ctx.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("[MICRO_CONTEXT path=README.md lines=1-3 hash=abc]", rendered);
}
