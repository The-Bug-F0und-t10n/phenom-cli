const std = @import("std");
const fd_writer = @import("fd_writer.zig");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
});

pub const InputEvent = union(enum) {
    none,
    submitted: []u8,
    closed,
    cancelled,
};

pub const TerminalSize = struct {
    rows: usize = 24,
    cols: usize = 80,
};

pub const BottomBarState = struct {
    color: bool = true,
    cols: usize = 80,
    status: ?[]const u8 = null,
    visualizer: ?[]const u8 = null,
    prompt: []const u8 = "",
    cursor: usize = 0,
    show_prompt: bool = true,
};

const user_bg = "\x1b[48;5;236m";
const user_fg = "\x1b[38;5;252m";
const reset = "\x1b[0m";
const dim = "\x1b[2m";
const green = "\x1b[32m";
const cyan = "\x1b[36m";
const max_prompt_rows: usize = 10;

pub const VisualizerMode = enum {
    idle,
    listening,
    thinking,
    working,
    responding,
};

pub fn visualizerFrame(mode: VisualizerMode, tick: usize) []const u8 {
    const idle = [_][]const u8{ "▁▁▁▁▁▁▁▁▁▁", "▁▁▁▁▁▁▁▁▁▁" };
    const listening = [_][]const u8{ "▁▂▃▂▁▂▃▂▁▂", "▂▃▄▃▂▃▄▃▂▃", "▁▂▃▄▃▂▁▂▃▂" };
    const thinking = [_][]const u8{ "▁▂▃▄▅▄▃▂▁▂", "▂▃▄▅▆▅▄▃▂▁", "▃▄▅▆▇▆▅▄▃▂", "▂▃▄▅▆▅▄▃▂▁" };
    const working = [_][]const u8{ "▃▆█▅▂▇█▆▃▅", "▅█▆▃▇█▅▂▆█", "█▆▃▅█▇▂▅█▆" };
    const responding = [_][]const u8{ "▁▃▅▇█▇▅▃▁▃", "▃▅▇█▇▅▃▁▃▅", "▅▇█▇▅▃▁▃▅▇", "▇█▇▅▃▁▃▅▇█" };
    return switch (mode) {
        .idle => idle[tick % idle.len],
        .listening => listening[tick % listening.len],
        .thinking => thinking[tick % thinking.len],
        .working => working[tick % working.len],
        .responding => responding[tick % responding.len],
    };
}

pub fn modeFromLabel(label: []const u8) VisualizerMode {
    if (containsIgnoreCase(label, "read") or containsIgnoreCase(label, "search") or containsIgnoreCase(label, "explor")) return .listening;
    if (containsIgnoreCase(label, "write") or containsIgnoreCase(label, "patch") or containsIgnoreCase(label, "run") or containsIgnoreCase(label, "test")) return .working;
    if (containsIgnoreCase(label, "respond")) return .responding;
    if (containsIgnoreCase(label, "think")) return .thinking;
    return .thinking;
}

pub fn bottomBarRows(prompt_rows: usize) usize {
    return 1 + 1 + @max(@as(usize, 1), @min(max_prompt_rows, prompt_rows)) + 1;
}

pub fn renderBottomBar(writer: anytype, state: BottomBarState) !usize {
    const paint_cols = @max(@as(usize, 1), state.cols -| 1);
    var rows_written: usize = 0;

    if (state.status) |status| {
        try writeStatus(writer, state.color, status, state.visualizer, paint_cols);
    } else {
        try writeSpaces(writer, paint_cols);
    }
    rows_written += 1;

    try writer.writeAll("\n");
    try paintInputBlank(writer, state.color, paint_cols);
    rows_written += 1;

    if (state.show_prompt) {
        const view = computePromptView(state.prompt, state.cursor, paint_cols);
        var i: usize = 0;
        while (i < view.line_count) : (i += 1) {
            try writer.writeAll("\n");
            const prefix: []const u8 = if (i == 0 and view.first_visible == 0) "> " else "  ";
            try paintInputRow(writer, state.color, prefix, view.storage[i], paint_cols);
            rows_written += 1;
        }
    } else {
        try writer.writeAll("\n");
        try paintInputBlank(writer, state.color, paint_cols);
        rows_written += 1;
    }

    try writer.writeAll("\n");
    try paintInputBlank(writer, state.color, paint_cols);
    rows_written += 1;
    return rows_written;
}

pub const PromptView = struct {
    storage: [max_prompt_rows][]const u8 = [_][]const u8{""} ** max_prompt_rows,
    line_count: usize = 1,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    first_visible: usize = 0,

    pub fn lines(self: PromptView) []const []const u8 {
        return self.storage[0..self.line_count];
    }
};

pub fn computePromptView(prompt: []const u8, cursor: usize, paint_cols: usize) PromptView {
    const content_width = @max(@as(usize, 1), paint_cols -| 2);
    var view = PromptView{};
    var wrapped: [256]struct { start: usize, end: usize, logical_row: usize, col_start: usize } = undefined;
    var wrapped_len: usize = 0;

    var logical_row: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= prompt.len) : (i += 1) {
        if (i == prompt.len or prompt[i] == '\n') {
            const line = prompt[line_start..i];
            if (line.len == 0) {
                if (wrapped_len < wrapped.len) {
                    wrapped[wrapped_len] = .{ .start = line_start, .end = line_start, .logical_row = logical_row, .col_start = 0 };
                    wrapped_len += 1;
                }
            } else {
                var part_start: usize = 0;
                while (part_start < line.len) {
                    const take = @min(content_width, line.len - part_start);
                    if (wrapped_len < wrapped.len) {
                        wrapped[wrapped_len] = .{
                            .start = line_start + part_start,
                            .end = line_start + part_start + take,
                            .logical_row = logical_row,
                            .col_start = part_start,
                        };
                        wrapped_len += 1;
                    }
                    part_start += take;
                }
            }
            logical_row += 1;
            line_start = i + 1;
        }
    }
    if (wrapped_len == 0) {
        wrapped[0] = .{ .start = 0, .end = 0, .logical_row = 0, .col_start = 0 };
        wrapped_len = 1;
    }

    const safe_cursor = @min(cursor, prompt.len);
    var cursor_line_start: usize = 0;
    var cursor_logical_row: usize = 0;
    var j: usize = 0;
    while (j < safe_cursor) : (j += 1) {
        if (prompt[j] == '\n') {
            cursor_logical_row += 1;
            cursor_line_start = j + 1;
        }
    }
    const cursor_col_in_line = safe_cursor - cursor_line_start;
    const cursor_wrap = cursor_col_in_line / content_width;
    var cursor_wrapped_row: usize = 0;
    var found_cursor = false;
    var w: usize = 0;
    while (w < wrapped_len) : (w += 1) {
        if (wrapped[w].logical_row == cursor_logical_row and wrapped[w].col_start / content_width == cursor_wrap) {
            cursor_wrapped_row = w;
            found_cursor = true;
            break;
        }
    }
    if (!found_cursor) cursor_wrapped_row = wrapped_len - 1;

    const visible_count = @min(max_prompt_rows, wrapped_len);
    var first_visible: usize = 0;
    if (wrapped_len > max_prompt_rows) {
        first_visible = @min(wrapped_len - max_prompt_rows, cursor_wrapped_row);
    }
    view.first_visible = first_visible;
    view.line_count = visible_count;

    var out_i: usize = 0;
    while (out_i < visible_count) : (out_i += 1) {
        const item = wrapped[first_visible + out_i];
        view.storage[out_i] = prompt[item.start..item.end];
    }
    view.cursor_row = if (cursor_wrapped_row >= first_visible) @min(visible_count - 1, cursor_wrapped_row - first_visible) else 0;
    view.cursor_col = cursor_col_in_line % content_width;
    return view;
}

pub const InputEditor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor: usize = 0,
    history: std.ArrayList([]u8),
    history_index: ?usize = null,
    draft: std.ArrayList(u8),
    pending: std.ArrayList(u8),
    in_paste: bool = false,

    pub fn init(allocator: std.mem.Allocator) InputEditor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).empty,
            .history = std.ArrayList([]u8).empty,
            .draft = std.ArrayList(u8).empty,
            .pending = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *InputEditor) void {
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.draft.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    pub fn feed(self: *InputEditor, data: []const u8) !InputEvent {
        if (self.pending.items.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(self.allocator);
            try combined.appendSlice(self.allocator, self.pending.items);
            try combined.appendSlice(self.allocator, data);
            self.pending.clearRetainingCapacity();
            return self.feedReady(combined.items);
        }
        return self.feedReady(data);
    }

    fn feedReady(self: *InputEditor, data: []const u8) !InputEvent {
        var i: usize = 0;
        while (i < data.len) {
            if (std.mem.startsWith(u8, data[i..], "\x1b[200~")) {
                self.in_paste = true;
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, data[i..], "\x1b[201~")) {
                self.in_paste = false;
                i += 6;
                continue;
            }
            const ch = data[i];
            if (self.in_paste) {
                try self.insertByte(if (ch == '\r') '\n' else ch);
                i += 1;
                continue;
            }
            if (ch == 0x03) return .cancelled;
            if (ch == 0x04 and self.buffer.items.len == 0) return .closed;
            if (ch == '\r' or ch == '\n') {
                if (i + 1 < data.len) try self.pending.appendSlice(self.allocator, data[i + 1 ..]);
                return .{ .submitted = try self.submit() };
            }
            if (ch == 0x7f or ch == 0x08) {
                self.backspace();
                i += 1;
                continue;
            }
            if (ch == '\x1b' and i + 2 < data.len and data[i + 1] == '[') {
                const consumed = try self.handleCsi(data[i..]);
                if (consumed > 0) {
                    i += consumed;
                    continue;
                }
            }
            if (ch >= ' ' or ch == '\t') {
                try self.insertByte(ch);
            }
            i += 1;
        }
        return .none;
    }

    fn handleCsi(self: *InputEditor, data: []const u8) !usize {
        if (std.mem.startsWith(u8, data, "\x1b[A")) {
            try self.historyPrev();
            return 3;
        }
        if (std.mem.startsWith(u8, data, "\x1b[B")) {
            try self.historyNext();
            return 3;
        }
        if (std.mem.startsWith(u8, data, "\x1b[C")) {
            self.cursor = nextCodepointStart(self.buffer.items, self.cursor);
            return 3;
        }
        if (std.mem.startsWith(u8, data, "\x1b[D")) {
            self.cursor = prevCodepointStart(self.buffer.items, self.cursor);
            return 3;
        }
        if (std.mem.startsWith(u8, data, "\x1b[H")) {
            self.cursor = 0;
            return 3;
        }
        if (std.mem.startsWith(u8, data, "\x1b[F")) {
            self.cursor = self.buffer.items.len;
            return 3;
        }
        if (std.mem.startsWith(u8, data, "\x1b[3~")) {
            self.deleteForward();
            return 4;
        }
        return 0;
    }

    fn insertByte(self: *InputEditor, byte: u8) !void {
        try self.buffer.insert(self.allocator, self.cursor, byte);
        self.cursor += 1;
        self.history_index = null;
    }

    fn backspace(self: *InputEditor) void {
        if (self.cursor == 0) return;
        const start = prevCodepointStart(self.buffer.items, self.cursor);
        self.buffer.replaceRange(self.allocator, start, self.cursor - start, &.{}) catch return;
        self.cursor = start;
        self.history_index = null;
    }

    fn deleteForward(self: *InputEditor) void {
        if (self.cursor >= self.buffer.items.len) return;
        const end = nextCodepointStart(self.buffer.items, self.cursor);
        self.buffer.replaceRange(self.allocator, self.cursor, end - self.cursor, &.{}) catch return;
        self.history_index = null;
    }

    fn submit(self: *InputEditor) ![]u8 {
        const line = try self.allocator.dupe(u8, self.buffer.items);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) {
            try self.pushHistory(trimmed);
        }
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.history_index = null;
        self.draft.clearRetainingCapacity();
        return line;
    }

    fn pushHistory(self: *InputEditor, line: []const u8) !void {
        var i: usize = 0;
        while (i < self.history.items.len) {
            if (std.mem.eql(u8, self.history.items[i], line)) {
                self.allocator.free(self.history.orderedRemove(i));
                break;
            }
            i += 1;
        }
        const owned = try self.allocator.dupe(u8, line);
        try self.history.insert(self.allocator, 0, owned);
        while (self.history.items.len > 200) {
            self.allocator.free(self.history.pop().?);
        }
    }

    fn historyPrev(self: *InputEditor) !void {
        if (self.history.items.len == 0) return;
        if (self.history_index == null) {
            self.draft.clearRetainingCapacity();
            try self.draft.appendSlice(self.allocator, self.buffer.items);
            self.history_index = 0;
        } else if (self.history_index.? + 1 < self.history.items.len) {
            self.history_index.? += 1;
        }
        try self.replaceBuffer(self.history.items[self.history_index.?]);
    }

    fn historyNext(self: *InputEditor) !void {
        const idx = self.history_index orelse return;
        if (idx == 0) {
            self.history_index = null;
            try self.replaceBuffer(self.draft.items);
            return;
        }
        self.history_index = idx - 1;
        try self.replaceBuffer(self.history.items[self.history_index.?]);
    }

    fn replaceBuffer(self: *InputEditor, text: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, text);
        self.cursor = self.buffer.items.len;
    }
};

pub fn TerminalUi(comptime Writer: type) type {
    return struct {
        allocator: std.mem.Allocator,
        stdin_fd: i32 = 0,
        writer: Writer,
        color: bool = true,
        editor: InputEditor,
        raw_enabled: bool = false,
        original_termios: c.termios = undefined,
        bottom_rows: usize = 0,
        prompt_rows: usize = 1,
        attached: bool = false,
        last_status: ?[]const u8 = null,
        visualizer_mode: VisualizerMode = .idle,
        visualizer_tick: usize = 0,
        show_prompt: bool = true,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, writer: Writer, color: bool) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .color = color,
                .editor = InputEditor.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.detach() catch {};
            self.editor.deinit();
        }

        pub fn attach(self: *Self) !void {
            if (self.attached) return;
            if (c.isatty(self.stdin_fd) != 1) return error.NotATty;
            if (c.tcgetattr(self.stdin_fd, &self.original_termios) != 0) return error.TermiosGetFailed;
            var raw = self.original_termios;
            c.cfmakeraw(&raw);
            if (c.tcsetattr(self.stdin_fd, c.TCSAFLUSH, &raw) != 0) return error.TermiosSetFailed;
            self.raw_enabled = true;
            self.attached = true;
            try self.writer.writeAll("\x1b[?2004h");
            try self.resyncScrollRegion();
            try self.draw(.{ .status = null, .show_prompt = true, .preserve_cursor = false });
        }

        pub fn detach(self: *Self) !void {
            if (!self.attached and !self.raw_enabled) return;
            try self.writer.writeAll("\x1b[r");
            try self.clearBottom();
            try self.writer.writeAll("\x1b[?2004l");
            if (self.raw_enabled) {
                _ = c.tcsetattr(self.stdin_fd, c.TCSAFLUSH, &self.original_termios);
                self.raw_enabled = false;
            }
            self.attached = false;
        }

        pub fn readLine(self: *Self) !?[]u8 {
            var buf: [64]u8 = undefined;
            while (true) {
                const event = if (self.editor.pending.items.len > 0) blk: {
                    break :blk try self.editor.feed("");
                } else blk: {
                    const n_raw = c.read(self.stdin_fd, &buf, buf.len);
                    if (n_raw < 0) return error.StdinReadFailed;
                    if (n_raw == 0) return null;
                    const n: usize = @intCast(n_raw);
                    break :blk try self.editor.feed(buf[0..n]);
                };
                switch (event) {
                    .none => try self.draw(.{ .status = null, .show_prompt = true, .preserve_cursor = false }),
                    .submitted => |line| return line,
                    .closed => return null,
                    .cancelled => return error.Cancelled,
                }
            }
        }

        pub fn positionContent(self: *Self) !void {
            if (!self.attached) return;
            const size = terminalSize();
            const last = @max(@as(usize, 1), size.rows -| self.bottom_rows);
            try self.writer.print("\x1b[{};1H", .{last});
        }

        pub fn showStatus(self: *Self, status: []const u8) !void {
            self.last_status = status;
            self.visualizer_mode = modeFromLabel(status);
            self.visualizer_tick +%= 1;
            self.show_prompt = false;
            try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
        }

        pub fn pulseStatus(self: *Self) !void {
            if (self.last_status) |status| {
                self.visualizer_tick +%= 1;
                try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
            }
        }

        pub fn showDone(self: *Self) !void {
            self.last_status = "[done]";
            self.visualizer_mode = .idle;
            self.show_prompt = true;
            try self.draw(.{ .status = "[done]", .show_prompt = true, .preserve_cursor = false });
        }

        pub fn showPrompt(self: *Self) !void {
            self.last_status = null;
            self.visualizer_mode = .idle;
            self.show_prompt = true;
            try self.draw(.{ .status = null, .show_prompt = true, .preserve_cursor = false });
        }

        fn draw(self: *Self, opts: struct { status: ?[]const u8, show_prompt: bool, preserve_cursor: bool }) !void {
            if (!self.attached) return;
            const size = terminalSize();
            const paint_cols = @max(@as(usize, 1), size.cols -| 1);
            const view = computePromptView(self.editor.buffer.items, self.editor.cursor, paint_cols);
            const active_prompt_lines = if (opts.show_prompt) view.line_count else 1;
            const rows = bottomBarRows(active_prompt_lines);
            if (rows != self.bottom_rows) {
                self.prompt_rows = view.line_count;
                self.bottom_rows = rows;
                try self.resyncScrollRegion();
            }

            const status_row = @max(@as(usize, 1), size.rows -| (1 + active_prompt_lines + 1));
            var out = std.ArrayList(u8).empty;
            defer out.deinit(self.allocator);
            const bw = fd_writer.BufferWriter{ .allocator = self.allocator, .list = &out };
            if (opts.preserve_cursor) try bw.writeAll("\x1b7");
            try bw.print("\x1b[{};1H", .{status_row});
            const frame = if (opts.status != null and self.visualizer_mode != .idle) visualizerFrame(self.visualizer_mode, self.visualizer_tick) else null;
            _ = try renderBottomBar(bw, .{
                .color = self.color,
                .cols = size.cols,
                .status = opts.status,
                .visualizer = frame,
                .prompt = self.editor.buffer.items,
                .cursor = self.editor.cursor,
                .show_prompt = opts.show_prompt,
            });
            if (opts.preserve_cursor) {
                try bw.writeAll("\x1b8");
            } else if (opts.show_prompt) {
                const prompt_first_row = status_row + 2;
                const screen_col = @min(size.cols, @as(usize, 3) + view.cursor_col);
                try bw.print("\x1b[{};{}H", .{ prompt_first_row + view.cursor_row, screen_col });
            }
            try self.writer.writeAll(out.items);
        }

        fn resyncScrollRegion(self: *Self) !void {
            if (!self.attached) return;
            const size = terminalSize();
            if (self.bottom_rows == 0) self.bottom_rows = bottomBarRows(self.prompt_rows);
            const last = @max(@as(usize, 1), size.rows -| self.bottom_rows);
            try self.writer.print("\x1b7\x1b[1;{}r\x1b8", .{last});
        }

        fn clearBottom(self: *Self) !void {
            const size = terminalSize();
            const rows = if (self.bottom_rows == 0) bottomBarRows(1) else self.bottom_rows;
            const start = @max(@as(usize, 1), size.rows -| rows) + 1;
            var r = start;
            while (r <= size.rows) : (r += 1) {
                try self.writer.print("\x1b[{};1H\x1b[2K", .{r});
            }
        }
    };
}

pub fn terminalSize() TerminalSize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        return .{ .rows = @intCast(ws.ws_row), .cols = @intCast(ws.ws_col) };
    }
    return .{};
}

fn writeStatus(writer: anytype, color: bool, status: []const u8, visualizer: ?[]const u8, width: usize) !void {
    const visual = visualizer orelse "";
    const visual_gap: usize = if (visual.len > 0) 1 else 0;
    const visual_cols = utf8Columns(visual);
    const status_width = if (width > visual_cols + visual_gap) width - visual_cols - visual_gap else width;
    const clipped = status[0..utf8PrefixBytes(status, status_width)];
    const clipped_cols = utf8Columns(clipped);
    if (color) {
        if (std.mem.eql(u8, status, "[done]")) try writer.writeAll(green) else try writer.writeAll(dim);
    }
    try writer.writeAll(clipped);
    if (color) try writer.writeAll(reset);
    if (visual.len > 0 and width > clipped_cols + visual_cols) {
        try writeSpaces(writer, width - clipped_cols - visual_cols);
        if (color) try writer.writeAll(cyan);
        try writer.writeAll(visual);
        if (color) try writer.writeAll(reset);
    } else if (clipped_cols < width) {
        try writeSpaces(writer, width - clipped_cols);
    }
}

fn paintInputRow(writer: anytype, color: bool, prefix: []const u8, content: []const u8, width: usize) !void {
    if (color) try writer.writeAll(user_bg ++ user_fg);
    const used = @min(width, prefix.len + content.len);
    try writer.writeAll(prefix[0..@min(prefix.len, width)]);
    if (prefix.len < width) try writer.writeAll(content[0..@min(content.len, width - prefix.len)]);
    if (used < width) try writeSpaces(writer, width - used);
    if (color) try writer.writeAll(reset);
}

fn paintInputBlank(writer: anytype, color: bool, width: usize) !void {
    if (color) try writer.writeAll(user_bg ++ user_fg);
    try writeSpaces(writer, width);
    if (color) try writer.writeAll(reset);
}

fn writeSpaces(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeAll(" ");
}

fn prevCodepointStart(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var i = cursor - 1;
    while (i > 0 and (bytes[i] & 0b1100_0000) == 0b1000_0000) : (i -= 1) {}
    return i;
}

fn nextCodepointStart(bytes: []const u8, cursor: usize) usize {
    if (cursor >= bytes.len) return bytes.len;
    var i = cursor + 1;
    while (i < bytes.len and (bytes[i] & 0b1100_0000) == 0b1000_0000) : (i += 1) {}
    return i;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn utf8Columns(bytes: []const u8) usize {
    var cols: usize = 0;
    for (bytes) |byte| {
        if ((byte & 0b1100_0000) != 0b1000_0000) cols += 1;
    }
    return cols;
}

fn utf8PrefixBytes(bytes: []const u8, max_cols: usize) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and cols < max_cols) {
        const start = i;
        i += 1;
        while (i < bytes.len and (bytes[i] & 0b1100_0000) == 0b1000_0000) : (i += 1) {}
        _ = start;
        cols += 1;
    }
    return i;
}

test "input editor submits and keeps utf8 backspace intact" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expectEqual(InputEvent.none, try editor.feed("olá"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed(&.{0x7f}));
    const event = try editor.feed("\r");
    switch (event) {
        .submitted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("ol", line);
        },
        else => return error.ExpectedSubmit,
    }
}

test "input editor history navigation" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    switch (try editor.feed("primeiro\r")) {
        .submitted => |line| std.testing.allocator.free(line),
        else => return error.ExpectedSubmit,
    }
    switch (try editor.feed("segundo\r")) {
        .submitted => |line| std.testing.allocator.free(line),
        else => return error.ExpectedSubmit,
    }
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqualStrings("segundo", editor.buffer.items);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqualStrings("primeiro", editor.buffer.items);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[B"));
    try std.testing.expectEqualStrings("segundo", editor.buffer.items);
}

test "input editor preserves bytes after submit for next read" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    switch (try editor.feed("ola\r\x04")) {
        .submitted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("ola", line);
        },
        else => return error.ExpectedSubmit,
    }
    try std.testing.expectEqual(InputEvent.closed, try editor.feed(""));
}

test "bottom bar snapshot matches prompt and status surface" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    _ = try renderBottomBar(writer, .{
        .color = false,
        .cols = 18,
        .status = "Thinking (3s · esc to interrupt)",
        .visualizer = "▁▂▃",
        .prompt = "ola",
        .cursor = 3,
        .show_prompt = true,
    });

    const expected =
        "Thinking (3s  ▁▂▃\n" ++
        "                 \n" ++
        "> ola            \n" ++
        "                 ";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "prompt view wraps and keeps cursor in visible window" {
    const view = computePromptView("abcdefghi", 9, 6);
    try std.testing.expectEqual(@as(usize, 3), view.line_count);
    try std.testing.expectEqualStrings("abcd", view.storage[0]);
    try std.testing.expectEqualStrings("efgh", view.storage[1]);
    try std.testing.expectEqualStrings("i", view.storage[2]);
    try std.testing.expectEqual(@as(usize, 2), view.cursor_row);
    try std.testing.expectEqual(@as(usize, 1), view.cursor_col);
}

test "visualizer frame and mode mapping are deterministic" {
    try std.testing.expectEqualStrings("▁▂▃▄▅▄▃▂▁▂", visualizerFrame(.thinking, 0));
    try std.testing.expectEqual(VisualizerMode.working, modeFromLabel("Patching files"));
    try std.testing.expectEqual(VisualizerMode.listening, modeFromLabel("Reading context"));
}
