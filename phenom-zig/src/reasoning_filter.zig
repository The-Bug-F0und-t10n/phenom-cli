const std = @import("std");

const open_tag = "<think>";
const close_tag = "</think>";

pub const ReasoningFilter = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8),
    in_thinking: bool = false,
    at_start: bool = true,

    pub fn init(allocator: std.mem.Allocator, start_in_thinking: bool) ReasoningFilter {
        return .{
            .allocator = allocator,
            .pending = std.ArrayList(u8).empty,
            .in_thinking = start_in_thinking,
            .at_start = !start_in_thinking,
        };
    }

    pub fn deinit(self: *ReasoningFilter) void {
        self.pending.deinit(self.allocator);
    }

    pub fn feed(self: *ReasoningFilter, delta: []const u8, sink: anytype) !void {
        try self.pending.appendSlice(self.allocator, delta);

        while (true) {
            if (self.in_thinking) {
                if (std.mem.indexOf(u8, self.pending.items, close_tag)) |idx| {
                    if (idx > 0) try sink.writeThinking(self.pending.items[0..idx]);
                    self.dropPrefix(idx + close_tag.len);
                    self.in_thinking = false;
                    try sink.endThinking();
                    continue;
                }

                const keep = suffixPrefixLen(self.pending.items, close_tag);
                const emit_len = self.pending.items.len - keep;
                if (emit_len > 0) {
                    try sink.writeThinking(self.pending.items[0..emit_len]);
                    self.dropPrefix(emit_len);
                }
                self.keepOnlySuffix(keep);
                return;
            }

            if (self.at_start) {
                const open_idx = std.mem.indexOf(u8, self.pending.items, open_tag);
                const close_idx = std.mem.indexOf(u8, self.pending.items, close_tag);

                if (open_idx != null and (close_idx == null or open_idx.? < close_idx.?)) {
                    self.at_start = false;
                } else if (close_idx) |idx| {
                    if (idx > 0) try sink.writeThinking(self.pending.items[0..idx]);
                    self.dropPrefix(idx + close_tag.len);
                    self.at_start = false;
                    try sink.endThinking();
                    continue;
                } else {
                    const keep = @max(suffixPrefixLen(self.pending.items, open_tag), suffixPrefixLen(self.pending.items, close_tag));
                    if (self.pending.items.len < 4096) return;
                    const emit_len = self.pending.items.len - keep;
                    if (emit_len > 0) {
                        try sink.writeVisible(self.pending.items[0..emit_len]);
                        self.dropPrefix(emit_len);
                    }
                    return;
                }
            }

            if (std.mem.indexOf(u8, self.pending.items, open_tag)) |idx| {
                if (idx > 0) try sink.writeVisible(self.pending.items[0..idx]);
                self.dropPrefix(idx + open_tag.len);
                self.in_thinking = true;
                continue;
            }

            const keep = suffixPrefixLen(self.pending.items, open_tag);
            const emit_len = self.pending.items.len - keep;
            if (emit_len > 0) {
                try sink.writeVisible(self.pending.items[0..emit_len]);
                self.dropPrefix(emit_len);
            }
            return;
        }
    }

    pub fn flush(self: *ReasoningFilter, sink: anytype) !void {
        if (self.in_thinking and self.pending.items.len > 0) {
            try sink.writeThinking(self.pending.items);
            try sink.endThinking();
        } else if (self.pending.items.len > 0) {
            try sink.writeVisible(self.pending.items);
        }
        self.pending.clearRetainingCapacity();
        self.in_thinking = false;
        self.at_start = false;
    }

    fn dropPrefix(self: *ReasoningFilter, count: usize) void {
        if (count >= self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            return;
        }
        const remaining = self.pending.items.len - count;
        std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[count..]);
        self.pending.shrinkRetainingCapacity(remaining);
    }

    fn keepOnlySuffix(self: *ReasoningFilter, count: usize) void {
        if (count >= self.pending.items.len) return;
        const start = self.pending.items.len - count;
        std.mem.copyForwards(u8, self.pending.items[0..count], self.pending.items[start..]);
        self.pending.shrinkRetainingCapacity(count);
    }
};

fn suffixPrefixLen(text: []const u8, pattern: []const u8) usize {
    const max = @min(text.len, pattern.len - 1);
    var len = max;
    while (len > 0) : (len -= 1) {
        if (std.mem.eql(u8, text[text.len - len ..], pattern[0..len])) return len;
    }
    return 0;
}

test "classifies complete think block" {
    var visible = std.ArrayList(u8).empty;
    defer visible.deinit(std.testing.allocator);
    var thinking = std.ArrayList(u8).empty;
    defer thinking.deinit(std.testing.allocator);
    const Sink = struct {
        visible: *std.ArrayList(u8),
        thinking: *std.ArrayList(u8),
        pub fn writeVisible(self: *@This(), text: []const u8) !void {
            try self.visible.appendSlice(std.testing.allocator, text);
        }
        pub fn writeThinking(self: *@This(), text: []const u8) !void {
            try self.thinking.appendSlice(std.testing.allocator, text);
        }
        pub fn endThinking(_: *@This()) !void {
        }
    };

    var sink = Sink{ .visible = &visible, .thinking = &thinking };
    var filter = ReasoningFilter.init(std.testing.allocator, false);
    defer filter.deinit();

    try filter.feed("Oi <think>hidden</think> bom dia", &sink);
    try filter.flush(&sink);
    try std.testing.expectEqualStrings("Oi  bom dia", visible.items);
    try std.testing.expectEqualStrings("hidden", thinking.items);
}

test "classifies split think tags across deltas" {
    var visible = std.ArrayList(u8).empty;
    defer visible.deinit(std.testing.allocator);
    var thinking = std.ArrayList(u8).empty;
    defer thinking.deinit(std.testing.allocator);
    const Sink = struct {
        visible: *std.ArrayList(u8),
        thinking: *std.ArrayList(u8),
        pub fn writeVisible(self: *@This(), text: []const u8) !void {
            try self.visible.appendSlice(std.testing.allocator, text);
        }
        pub fn writeThinking(self: *@This(), text: []const u8) !void {
            try self.thinking.appendSlice(std.testing.allocator, text);
        }
        pub fn endThinking(_: *@This()) !void {
        }
    };

    var sink = Sink{ .visible = &visible, .thinking = &thinking };
    var filter = ReasoningFilter.init(std.testing.allocator, false);
    defer filter.deinit();

    try filter.feed("Oi <thi", &sink);
    try filter.feed("nk>hidden</thi", &sink);
    try filter.feed("nk> bom", &sink);
    try filter.flush(&sink);
    try std.testing.expectEqualStrings("Oi  bom", visible.items);
    try std.testing.expectEqualStrings("hidden", thinking.items);
}

test "classifies reasoning when close tag arrives without open tag" {
    var visible = std.ArrayList(u8).empty;
    defer visible.deinit(std.testing.allocator);
    var thinking = std.ArrayList(u8).empty;
    defer thinking.deinit(std.testing.allocator);
    const Sink = struct {
        visible: *std.ArrayList(u8),
        thinking: *std.ArrayList(u8),
        pub fn writeVisible(self: *@This(), text: []const u8) !void {
            try self.visible.appendSlice(std.testing.allocator, text);
        }
        pub fn writeThinking(self: *@This(), text: []const u8) !void {
            try self.thinking.appendSlice(std.testing.allocator, text);
        }
        pub fn endThinking(_: *@This()) !void {
        }
    };

    var sink = Sink{ .visible = &visible, .thinking = &thinking };
    var filter = ReasoningFilter.init(std.testing.allocator, false);
    defer filter.deinit();

    try filter.feed("raciocinio", &sink);
    try filter.feed("</think>\nfinal", &sink);
    try filter.flush(&sink);
    try std.testing.expectEqualStrings("\nfinal", visible.items);
    try std.testing.expectEqualStrings("raciocinio", thinking.items);
}
