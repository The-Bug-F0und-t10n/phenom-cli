const std = @import("std");
const fd_writer = @import("fd_writer.zig");

pub const RenderOptions = struct {
    color: bool = true,
    user_label: []const u8 = "user",
    terminal_columns: usize = 80,
    max_tool_sample_lines: usize = 20,
    max_diff_lines: usize = 2000,
};

pub fn AppendOnlyRenderer(comptime Writer: type) type {
    return struct {
        writer: Writer,
        options: RenderOptions,
        assistant_open: bool = false,
        thinking_open: bool = false,
        stream_needs_gutter: bool = true,
        thinking_needs_gutter: bool = true,
        last_block: BlockKind = .none,
        tool_seq: usize = 0,

        const Self = @This();

        const BlockKind = enum {
            none,
            user,
            assistant,
            thinking,
            tool,
            diff,
            status,
            done,
        };

        const user_bg = "\x1b[48;5;236m";
        const user_fg = "\x1b[38;5;252m";
        const reset = "\x1b[0m";
        const content_gutter_cols: usize = 1;

        pub fn init(writer: Writer, options: RenderOptions) Self {
            return .{ .writer = writer, .options = options };
        }

        pub fn user(self: *Self, text: []const u8) !void {
            try self.closeOpenBlocks();

            var prefix_buf: [96]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "> [{s}] ", .{self.options.user_label});

            try self.writer.writeAll("\n");
            try self.writeWrappedUserLine(prefix, text);
            try self.writer.writeAll("\n\n");
            self.last_block = .user;
        }

        pub fn assistantStart(self: *Self) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.assistant);
            self.assistant_open = true;
            self.stream_needs_gutter = true;
            self.last_block = .assistant;
        }

        pub fn assistantDelta(self: *Self, text: []const u8) !void {
            try self.writeContentStream(text);
        }

        pub fn thinkingDelta(self: *Self, text: []const u8) !void {
            if (!self.thinking_open) {
                var wrote_gap = false;
                if (self.assistant_open) {
                    try self.writer.writeAll("\n");
                    self.assistant_open = false;
                    wrote_gap = true;
                }
                if (!wrote_gap) try self.writer.writeAll("\n");
                try self.writeContentGutter();
                try self.writeCyan("│ ");
                try self.writeCyanBold("thinking");
                try self.writer.writeAll("\n");
                self.thinking_open = true;
                self.thinking_needs_gutter = true;
                self.last_block = .thinking;
            }

            var start: usize = 0;
            while (start < text.len) {
                if (text[start] == '\n') {
                    try self.writeDim("\n");
                    self.thinking_needs_gutter = true;
                    start += 1;
                    continue;
                }
                if (self.thinking_needs_gutter) {
                    try self.writeContentGutter();
                    try self.writeCyan("│ ");
                    self.thinking_needs_gutter = false;
                }
                const rel = std.mem.indexOfScalar(u8, text[start..], '\n');
                const end = if (rel) |idx| start + idx else text.len;
                try self.writeDim(text[start..end]);
                start = end;
            }
        }

        pub fn thinkingEnd(self: *Self) !void {
            if (!self.thinking_open) return;
            if (!self.thinking_needs_gutter) try self.writer.writeAll("\n");
            self.thinking_open = false;
            self.thinking_needs_gutter = true;
            try self.writer.writeAll("\n");
            self.assistant_open = true;
            self.stream_needs_gutter = true;
            self.last_block = .assistant;
        }

        pub fn toolSample(self: *Self, name: []const u8, sample: []const u8) !void {
            try self.toolSampleWithDetail(name, "", sample);
        }

        pub fn toolSampleWithDetail(self: *Self, name: []const u8, detail: []const u8, sample: []const u8) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.tool);
            self.tool_seq += 1;
            try self.writeContentGutter();
            try self.writeCyanBold("▸ ");
            try self.writeCyanBold(toolLabel(name));
            if (detail.len > 0) {
                try self.writeDim(": ");
                try self.writer.writeAll(detail);
            } else {
                try self.writer.writeAll(toolDetail(name));
            }
            try self.writer.writeAll("\n");
            try self.writeToolOutput(sample);
            self.last_block = .tool;
        }

        pub fn diff(self: *Self, path: []const u8, action: []const u8, content: []const u8) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.diff);
            try self.writeContentGutter();
            try self.writeYellowBold("  ◆ ");
            try self.writeYellowBold(path);
            try self.writeDim(" (");
            try self.writeYellowBold(action);
            try self.writeDim(")");
            try self.writer.writeAll("\n");
            try self.writeDiffPreview(content);
            self.last_block = .diff;
        }

        pub fn status(self: *Self, text: []const u8) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.status);
            try self.writeContentGutter();
            try self.writeDim(text);
            try self.writer.writeAll("\n");
            self.last_block = .status;
        }

        pub fn done(self: *Self) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.done);
            try self.writeContentGutter();
            try self.writeGreen("[done]");
            try self.writer.writeAll("\n");
            self.last_block = .done;
        }

        pub fn promptRow(self: *Self, prompt: []const u8) !void {
            const paint_cols = self.paintCols();
            const content_width = if (paint_cols > 2) paint_cols - 2 else 1;
            try self.paintInputRow("> ", prompt[0..@min(prompt.len, content_width)], paint_cols);
        }

        pub fn statusRow(self: *Self, label: []const u8, elapsed: []const u8) !void {
            try self.writeDim(label);
            try self.writeDim(" (");
            try self.writeDim(elapsed);
            try self.writeDim(" · esc to interrupt)");
        }

        fn closeOpenBlocks(self: *Self) !void {
            if (self.thinking_open) {
                try self.writer.writeAll("\n");
                self.thinking_open = false;
            }
            if (self.assistant_open) {
                try self.writer.writeAll("\n");
                self.assistant_open = false;
            }
        }

        fn blockGap(self: *Self, next: BlockKind) !void {
            if (self.last_block == .none) return;
            if (self.last_block == .user) return;
            _ = next;
            try self.writer.writeAll("\n");
        }

        fn writeWrappedUserLine(self: *Self, prefix: []const u8, text: []const u8) !void {
            const inner_width = self.userInnerWidth();
            var logical_start: usize = 0;
            var first_logical = true;
            while (logical_start <= text.len) {
                const rel = std.mem.indexOfScalar(u8, text[logical_start..], '\n');
                const logical_end = if (rel) |idx| logical_start + idx else text.len;
                const line = text[logical_start..logical_end];

                const active_prefix = if (first_logical) prefix else "";
                const virtual_len = active_prefix.len + line.len;
                var pos: usize = 0;
                var wrote_chunk = false;
                while (pos < virtual_len or !wrote_chunk) {
                    const take = if (pos < virtual_len) @min(inner_width, virtual_len - pos) else 0;
                    try self.writeContentGutter();
                    try self.writeUserVirtualLine(active_prefix, line, pos, take);
                    wrote_chunk = true;
                    pos += take;
                    if (pos < virtual_len) try self.writer.writeAll("\n");
                }

                first_logical = false;
                if (rel == null) break;
                try self.writer.writeAll("\n");
                logical_start = logical_end + 1;
            }
        }

        fn writeUserVirtualLine(self: *Self, prefix: []const u8, text: []const u8, pos: usize, take: usize) !void {
            const width = self.userInnerWidth();
            if (self.options.color) {
                try self.writer.writeAll(user_bg ++ user_fg);
            }
            try self.writeVirtualSegment(prefix, text, pos, take);
            if (take < width) try self.writeSpaces(width - take);
            try self.writer.writeAll(" ");
            if (self.options.color) try self.writer.writeAll(reset);
        }

        fn writeVirtualSegment(self: *Self, prefix: []const u8, text: []const u8, pos: usize, take: usize) !void {
            if (take == 0) return;
            const end = pos + take;
            if (pos < prefix.len) {
                const prefix_end = @min(prefix.len, end);
                try self.writer.writeAll(prefix[pos..prefix_end]);
            }
            if (end > prefix.len) {
                const text_start = if (pos > prefix.len) pos - prefix.len else 0;
                const text_end = @min(text.len, end - prefix.len);
                if (text_start < text_end) try self.writer.writeAll(text[text_start..text_end]);
            }
        }

        fn writeContentStream(self: *Self, text: []const u8) !void {
            for (text) |ch| {
                if (self.stream_needs_gutter) try self.writeContentGutter();
                const one = [1]u8{ch};
                try self.writer.writeAll(&one);
                self.stream_needs_gutter = ch == '\n';
            }
        }

        fn writeToolOutput(self: *Self, sample: []const u8) !void {
            if (sample.len == 0) {
                try self.writeDim("    └─ (no output, exit 0)");
                try self.writer.writeAll("\n");
                return;
            }
            var start: usize = 0;
            var seen: usize = 0;
            var shown: usize = 0;
            while (start <= sample.len) {
                const rel = std.mem.indexOfScalar(u8, sample[start..], '\n');
                const end = if (rel) |idx| start + idx else sample.len;
                if (end > start) {
                    seen += 1;
                    if (shown < self.options.max_tool_sample_lines) {
                        try self.writeContentGutter();
                        try self.writeDim("    │ ");
                        try self.writer.writeAll(sample[start..end]);
                        try self.writer.writeAll("\n");
                        shown += 1;
                    }
                }
                if (rel == null) break;
                start = end + 1;
            }
            if (seen > shown) {
                const hidden = seen - shown;
                try self.writeContentGutter();
                try self.writeDim("    └─ (");
                try self.writer.print("{} more line{s} truncated", .{ hidden, if (hidden == 1) "" else "s" });
                try self.writeDim(")");
                try self.writer.writeAll("\n");
            }
        }

        fn writeDiffPreview(self: *Self, content: []const u8) !void {
            var start: usize = 0;
            var seen: usize = 0;
            var shown: usize = 0;
            while (start <= content.len) {
                const rel = std.mem.indexOfScalar(u8, content[start..], '\n');
                const end = if (rel) |idx| start + idx else content.len;
                if (end > start) {
                    seen += 1;
                    if (shown < self.options.max_diff_lines) {
                        const line = content[start..end];
                        try self.writeDiffLine(line);
                        shown += 1;
                    }
                }
                if (rel == null) break;
                start = end + 1;
            }
            if (seen > shown) {
                try self.writeContentGutter();
                try self.writeDim("  ... ");
                try self.writer.print("{} more line{s} hidden from preview\n", .{ seen - shown, if (seen - shown == 1) "" else "s" });
            }
        }

        fn writeDiffLine(self: *Self, line: []const u8) !void {
            try self.writeContentGutter();
            if (std.mem.startsWith(u8, line, "@@")) {
                try self.writeCyan("  ");
                try self.writeCyan(line);
                try self.writer.writeAll("\n");
            } else if (std.mem.startsWith(u8, line, "+")) {
                try self.writeGreen("  + │ ");
                try self.writer.writeAll(line[1..]);
                try self.writer.writeAll("\n");
            } else if (std.mem.startsWith(u8, line, "-")) {
                try self.writeRed("  - │ ");
                try self.writer.writeAll(line[1..]);
                try self.writer.writeAll("\n");
            } else {
                try self.writeDim("    │ ");
                try self.writer.writeAll(line);
                try self.writer.writeAll("\n");
            }
        }

        fn writeSpaces(self: *Self, count: usize) !void {
            var i: usize = 0;
            while (i < count) : (i += 1) try self.writer.writeAll(" ");
        }

        fn writeContentGutter(self: *Self) !void {
            try self.writeSpaces(content_gutter_cols);
        }

        fn paintCols(self: *Self) usize {
            return @max(@as(usize, 1), self.options.terminal_columns -| 1);
        }

        fn contentWrapWidth(self: *Self) usize {
            return @max(@as(usize, 1), self.paintCols() -| content_gutter_cols);
        }

        fn userInnerWidth(self: *Self) usize {
            return @max(@as(usize, 8), @max(@as(usize, 12), self.contentWrapWidth()) - 1);
        }

        fn paintInputRow(self: *Self, prefix: []const u8, content: []const u8, cols: usize) !void {
            const used = @min(cols, prefix.len + content.len);
            if (self.options.color) try self.writer.writeAll(user_bg ++ user_fg);
            try self.writer.writeAll(prefix[0..@min(prefix.len, cols)]);
            if (prefix.len < cols) try self.writer.writeAll(content[0..@min(content.len, cols - prefix.len)]);
            if (used < cols) try self.writeSpaces(cols - used);
            if (self.options.color) try self.writer.writeAll(reset);
        }

        fn writeAnsi(self: *Self, code: []const u8, text: []const u8) !void {
            if (!self.options.color) {
                try self.writer.writeAll(text);
                return;
            }
            try self.writer.writeAll(code);
            try self.writer.writeAll(text);
            try self.writer.writeAll(reset);
        }

        fn writeCyan(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[36m", text);
        }

        fn writeCyanBold(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[36;1m", text);
        }

        fn writeDim(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[2m", text);
        }

        fn writeGreen(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[32m", text);
        }

        fn writeRed(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[31m", text);
        }

        fn writeYellowBold(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[33;1m", text);
        }
    };
}

fn toolLabel(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file_range")) return "Reading";
    if (std.mem.eql(u8, name, "apply_patch")) return "Patching";
    if (std.mem.eql(u8, name, "write_file")) return "Writing";
    if (std.mem.eql(u8, name, "run_code")) return "Running";
    return name;
}

fn toolDetail(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file_range")) return " file range";
    return "";
}

test "thinking renders cyan gutter and separates final output" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.thinkingDelta("interno");
    try renderer.thinkingEnd();
    try renderer.assistantDelta("final");

    const expected =
        \\
        \\ │ thinking
        \\ │ interno
        \\
        \\ final
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "thinking streamed by token keeps one gutter per logical line" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.thinkingDelta("O");
    try renderer.thinkingDelta(" usuario");
    try renderer.thinkingDelta(" esta\nok");
    try renderer.thinkingEnd();
    try renderer.assistantDelta("final");

    const expected =
        \\
        \\ │ thinking
        \\ │ O usuario esta
        \\ │ ok
        \\
        \\ final
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "thinking stream preserves utf8 text inside styled chunks" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true });
    try renderer.thinkingDelta("usuário em português");

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "usuário em português") != null);
}

test "append only snapshot matches phenom cli ts plain surface" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 18 });
    try renderer.user("ola");
    try renderer.assistantStart();
    try renderer.assistantDelta("ok");
    try renderer.done();

    const expected = "\n > [user] ola    \n\n ok\n\n [done]\n";
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
        \\ PHENOM_REAL_7319
        \\
        \\ success expected visible text found: PHENOM_REAL_7319
        \\
        \\ [done]
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "tool sample uses phenom cli ts tool announcement and output gutter" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .max_tool_sample_lines = 2 });
    try renderer.toolSample("read_file_range", "a\nb\nc\n");

    const expected =
        \\ ▸ Reading file range
        \\     │ a
        \\     │ b
        \\     └─ (1 more line truncated)
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "tool sample renders command detail like phenom cli ts" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .max_tool_sample_lines = 1 });
    try renderer.toolSampleWithDetail("run_code", "ls -la ~/.config/nvim", "$ ls -la ~/.config/nvim    [cwd=. exit 0 3ms]\nfile\n");

    const expected =
        \\ ▸ Running: ls -la ~/.config/nvim
        \\     │ $ ls -la ~/.config/nvim    [cwd=. exit 0 3ms]
        \\     └─ (1 more line truncated)
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "diff preview uses soft markers and truncation" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .max_diff_lines = 3 });
    try renderer.diff("src/app.zig", "patched", "@@ -1 +1 @@\n-old\n+new\n context\n+hidden\n");

    const expected =
        \\   ◆ src/app.zig (patched)
        \\   @@ -1 +1 @@
        \\   - │ old
        \\   + │ new
        \\   ... 2 more lines hidden from preview
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "ansi user bubble uses same palette constants as phenom cli ts" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true, .terminal_columns = 16 });
    try renderer.user("ola");

    const expected = "\n \x1b[48;5;236m\x1b[38;5;252m> [user] ola  \x1b[0m\n\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "prompt row uses phenom cli ts input palette and prefix" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true, .terminal_columns = 16 });
    try renderer.promptRow("ola");

    const expected = "\x1b[48;5;236m\x1b[38;5;252m> ola          \x1b[0m";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "status row uses phenom cli ts active prose shape" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.statusRow("Thinking", "3s");

    try std.testing.expectEqualStrings("Thinking (3s · esc to interrupt)", buffer.items);
}
