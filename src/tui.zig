const std = @import("std");
const fd_writer = @import("fd_writer.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("time.h");
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
    status_right: ?[]const u8 = null,
    footer: ?[]const u8 = null,
    visualizer: ?[]const u8 = null,
    visualizer_mode: ?VisualizerMode = null,
    visualizer_tick: usize = 0,
    prompt: []const u8 = "",
    cursor: usize = 0,
    show_prompt: bool = true,
    prompt_line_limit: usize = 1,
};

const user_bg = "\x1b[48;5;236m";
const user_fg = "\x1b[38;5;252m";
const reset = "\x1b[0m";
const dim = "\x1b[2m";
const green = "\x1b[32m";
const cyan = "\x1b[36m";
const max_rendered_prompt_rows: usize = 10;

pub const VisualizerMode = enum {
    idle,
    listening,
    thinking,
    working,
    responding,
};

const VisualizerState = struct {
    energy: f64,
    density: f64,
    chaos: f64,
    spd_factor: f64,
};

const visualizer_blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
const noise_norm = 0.8110;
const flat_threshold = 0.05;
const cascade_sec = 1.0;
const ease_sec = 0.85;
const max_visualizer_cols = 512;

pub const MiniVisualizer = struct {
    width: usize = 20,
    mode: VisualizerMode = .idle,
    target: VisualizerState = visualizerState(.idle),
    snap: [max_visualizer_cols]VisualizerState = [_]VisualizerState{visualizerState(.idle)} ** max_visualizer_cols,
    transition_start_ms: i64 = 0,
    start_ms: i64 = 0,

    pub fn init(width: usize) MiniVisualizer {
        const now = monotonicMs();
        return .{
            .width = @max(@as(usize, 4), @min(max_visualizer_cols, width)),
            .transition_start_ms = now - @as(i64, @intFromFloat((cascade_sec + ease_sec) * 1000.0)),
            .start_ms = now,
        };
    }

    pub fn setMode(self: *MiniVisualizer, mode: VisualizerMode, now_ms: i64) void {
        if (mode == self.mode) return;
        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            self.snap[i] = self.effectiveStateFor(i, now_ms);
        }
        self.mode = mode;
        self.target = visualizerState(mode);
        self.transition_start_ms = now_ms;
    }

    pub fn setWidth(self: *MiniVisualizer, width: usize) void {
        const next = @max(@as(usize, 4), @min(max_visualizer_cols, width));
        if (next == self.width) return;
        if (next > self.width) {
            var i = self.width;
            while (i < next) : (i += 1) self.snap[i] = self.target;
        }
        self.width = next;
    }

    pub fn render(self: *MiniVisualizer, out: []u8, now_ms: i64) ![]const u8 {
        var pos: usize = 0;
        const t_anim = @as(f64, @floatFromInt(now_ms - self.start_ms)) / 1000.0;
        var x: usize = 0;
        while (x < self.width) : (x += 1) {
            const state = self.effectiveStateFor(x, now_ms);
            if (state.energy < flat_threshold) {
                try appendGlyph(out, &pos, if (state.energy < 0.000001) " " else "▁");
                continue;
            }
            const xf = @as(f64, @floatFromInt(x));
            const spd = 0.4 + state.energy * state.spd_factor;
            const nx1 = xf * 0.07 * state.density + t_anim * spd;
            const nx2 = xf * 0.12 * state.density + t_anim * spd * 1.2;
            const raw = rawNoise(nx1, nx2);
            const gamma = 0.25 + 4.5 * std.math.pow(f64, 1.0 - state.energy, 2.0);
            const jitter = if (state.chaos == 0.0)
                0.0
            else
                (std.math.sin(t_anim * 7.3 + xf * 1.7) + std.math.sin(t_anim * 4.1 + xf * 2.9)) * 0.25 * state.chaos;
            const value = clamp01(std.math.pow(f64, raw, gamma) + jitter);
            const idx: usize = @intFromFloat(@floor(value * @as(f64, @floatFromInt(visualizer_blocks.len - 1))));
            try appendGlyph(out, &pos, visualizer_blocks[idx]);
        }
        return out[0..pos];
    }

    fn effectiveStateFor(self: *MiniVisualizer, i: usize, now_ms: i64) VisualizerState {
        const denom = @max(self.width -| 1, 1);
        const delay = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(denom))) * cascade_sec;
        const elapsed = @as(f64, @floatFromInt(now_ms - self.transition_start_ms)) / 1000.0;
        const blend = easeSmooth((elapsed - delay) / ease_sec);
        return lerpState(self.snap[i], self.target, blend);
    }
};

fn visualizerState(mode: VisualizerMode) VisualizerState {
    return switch (mode) {
        .idle => .{ .energy = 0.02, .density = 1.0, .chaos = 0.00, .spd_factor = 0.0 },
        .listening => .{ .energy = 0.32, .density = 2.2, .chaos = 0.00, .spd_factor = 12.0 },
        .thinking => .{ .energy = 0.58, .density = 3.0, .chaos = 0.04, .spd_factor = 5.5 },
        .working => .{ .energy = 0.72, .density = 4.0, .chaos = 0.08, .spd_factor = 11.0 },
        .responding => .{ .energy = 0.95, .density = 4.8, .chaos = 0.01, .spd_factor = 8.5 },
    };
}

fn n1(x: f64) f64 {
    return std.math.sin(x * 0.35) * 0.60 + std.math.sin(x * 0.90) * 0.25 + std.math.sin(x * 1.70) * 0.15;
}

fn n2(x: f64) f64 {
    return std.math.sin(x * 0.55) * 0.50 + std.math.sin(x * 1.30) * 0.35 + std.math.sin(x * 2.10) * 0.15;
}

fn rawNoise(nx1: f64, nx2: f64) f64 {
    return @min((@abs(n1(nx1)) * 0.65 + @abs(n2(nx2)) * 0.35) / noise_norm, 1.0);
}

fn easeSmooth(p: f64) f64 {
    const t = clamp01(p);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerpState(a: VisualizerState, b: VisualizerState, t: f64) VisualizerState {
    return .{
        .energy = a.energy * (1.0 - t) + b.energy * t,
        .density = a.density * (1.0 - t) + b.density * t,
        .chaos = a.chaos * (1.0 - t) + b.chaos * t,
        .spd_factor = a.spd_factor * (1.0 - t) + b.spd_factor * t,
    };
}

fn clamp01(value: f64) f64 {
    return @max(0.0, @min(1.0, value));
}

fn appendGlyph(out: []u8, pos: *usize, glyph: []const u8) !void {
    if (pos.* + glyph.len > out.len) return error.VisualizerBufferTooSmall;
    @memcpy(out[pos.* .. pos.* + glyph.len], glyph);
    pos.* += glyph.len;
}

pub fn lockTerminal(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

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

pub fn writeVisualizerFrame(writer: anytype, mode: VisualizerMode, tick: usize, width: usize) !void {
    const frame = visualizerFrame(mode, tick);
    if (width == 0) return;
    var i: usize = 0;
    while (i < width) : (i += 1) {
        const glyph_index = i % utf8Columns(frame);
        try writeUtf8GlyphAt(writer, frame, glyph_index);
    }
}

pub fn modeFromLabel(label: []const u8) VisualizerMode {
    if (containsIgnoreCase(label, "read") or containsIgnoreCase(label, "search") or containsIgnoreCase(label, "explor")) return .listening;
    if (containsIgnoreCase(label, "write") or containsIgnoreCase(label, "patch") or containsIgnoreCase(label, "run") or containsIgnoreCase(label, "test")) return .working;
    if (containsIgnoreCase(label, "respond")) return .responding;
    if (containsIgnoreCase(label, "think")) return .thinking;
    return .thinking;
}

pub fn bottomBarRows(prompt_rows: usize) usize {
    return 1 + 1 + 1 + @max(@as(usize, 1), prompt_rows) + 1 + 1;
}

pub fn renderBottomBar(writer: anytype, state: BottomBarState) !usize {
    const paint_cols = @max(@as(usize, 1), state.cols -| 1);
    var rows_written: usize = 0;

    try writeSpaces(writer, paint_cols);
    rows_written += 1;

    try writer.writeAll("\r\n");
    if (state.status) |status| {
        if (state.visualizer_mode) |mode| {
            try writeStatusDynamic(writer, state.color, status, state.status_right, mode, state.visualizer_tick, paint_cols);
        } else {
            try writeStatus(writer, state.color, status, state.status_right, state.visualizer, paint_cols);
        }
    } else if (state.status_right) |right| {
        try writeStatus(writer, state.color, "", right, null, paint_cols);
    } else {
        try writeSpaces(writer, paint_cols);
    }
    rows_written += 1;

    try writer.writeAll("\r\n");
    try paintInputBlank(writer, state.color, paint_cols);
    rows_written += 1;

    if (state.show_prompt) {
        var view = try computePromptViewLimited(std.heap.page_allocator, state.prompt, state.cursor, paint_cols, state.prompt_line_limit);
        defer view.deinit();
        var i: usize = 0;
        while (i < view.line_count) : (i += 1) {
            try writer.writeAll("\r\n");
            const prefix: []const u8 = if (i == 0 and view.first_visible == 0) "> " else "  ";
            try paintInputRow(writer, state.color, prefix, view.storage[i], paint_cols);
            rows_written += 1;
        }
    } else {
        try writer.writeAll("\r\n");
        try paintInputBlank(writer, state.color, paint_cols);
        rows_written += 1;
    }

    try writer.writeAll("\r\n");
    try paintInputBlank(writer, state.color, paint_cols);
    rows_written += 1;

    try writer.writeAll("\r\n");
    if (state.footer) |footer| {
        try writeFooter(writer, state.color, footer, paint_cols);
    } else {
        try paintInputBlank(writer, state.color, paint_cols);
    }
    rows_written += 1;
    return rows_written;
}

pub const PromptView = struct {
    allocator: std.mem.Allocator,
    storage: []const []const u8,
    line_count: usize = 1,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    first_visible: usize = 0,

    pub fn lines(self: PromptView) []const []const u8 {
        return self.storage;
    }

    pub fn deinit(self: *PromptView) void {
        self.allocator.free(self.storage);
    }
};

pub fn computePromptView(allocator: std.mem.Allocator, prompt: []const u8, cursor: usize, paint_cols: usize, line_limit: usize) !PromptView {
    return computePromptViewLimited(allocator, prompt, cursor, paint_cols, line_limit);
}

pub fn computePromptViewLimited(allocator: std.mem.Allocator, prompt: []const u8, cursor: usize, paint_cols: usize, line_limit: usize) !PromptView {
    const content_width = promptContentWidth(paint_cols);
    const WrappedLine = struct { start: usize, end: usize, logical_row: usize, col_start: usize };
    var wrapped = std.ArrayList(WrappedLine).empty;
    defer wrapped.deinit(allocator);

    var logical_row: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= prompt.len) : (i += 1) {
        if (i == prompt.len or prompt[i] == '\n') {
            const line = prompt[line_start..i];
            if (line.len == 0) {
                try wrapped.append(allocator, .{ .start = line_start, .end = line_start, .logical_row = logical_row, .col_start = 0 });
            } else {
                var part_start: usize = 0;
                while (part_start < line.len) {
                    const take = @min(content_width, line.len - part_start);
                    try wrapped.append(allocator, .{
                        .start = line_start + part_start,
                        .end = line_start + part_start + take,
                        .logical_row = logical_row,
                        .col_start = part_start,
                    });
                    part_start += take;
                }
            }
            logical_row += 1;
            line_start = i + 1;
        }
    }
    if (wrapped.items.len == 0) try wrapped.append(allocator, .{ .start = 0, .end = 0, .logical_row = 0, .col_start = 0 });

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
    const cursor_line_end = logicalLineEnd(prompt, safe_cursor);
    const cursor_line_columns = codepointCount(prompt[cursor_line_start..cursor_line_end]);
    const cursor_wrap = visualRowIndex(cursor_col_in_line, cursor_line_columns, content_width);
    var cursor_wrapped_row: usize = 0;
    var found_cursor = false;
    var w: usize = 0;
    while (w < wrapped.items.len) : (w += 1) {
        if (wrapped.items[w].logical_row == cursor_logical_row and wrapped.items[w].col_start / content_width == cursor_wrap) {
            cursor_wrapped_row = w;
            found_cursor = true;
            break;
        }
    }
    if (!found_cursor) cursor_wrapped_row = wrapped.items.len - 1;

    const safe_limit = @max(@as(usize, 1), line_limit);
    const visible_count = @min(safe_limit, wrapped.items.len);
    var first_visible: usize = 0;
    if (wrapped.items.len > safe_limit) {
        first_visible = @min(wrapped.items.len - safe_limit, (cursor_wrapped_row + 1) -| safe_limit);
    }
    const storage = try allocator.alloc([]const u8, visible_count);
    errdefer allocator.free(storage);

    var out_i: usize = 0;
    while (out_i < visible_count) : (out_i += 1) {
        const item = wrapped.items[first_visible + out_i];
        storage[out_i] = prompt[item.start..item.end];
    }
    return .{
        .allocator = allocator,
        .storage = storage,
        .line_count = visible_count,
        .cursor_row = if (cursor_wrapped_row >= first_visible) @min(visible_count - 1, cursor_wrapped_row - first_visible) else 0,
        .cursor_col = cursor_col_in_line - cursor_wrap * content_width,
        .first_visible = first_visible,
    };
}

pub const InputEditor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor: usize = 0,
    history: std.ArrayList([]u8),
    history_index: ?usize = null,
    draft: std.ArrayList(u8),
    pending: std.ArrayList(u8),
    escape_pending: std.ArrayList(u8),
    in_paste: bool = false,
    select_all: bool = false,
    preferred_column: ?usize = null,
    navigation_width: usize = std.math.maxInt(usize),

    pub fn init(allocator: std.mem.Allocator) InputEditor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).empty,
            .history = std.ArrayList([]u8).empty,
            .draft = std.ArrayList(u8).empty,
            .pending = std.ArrayList(u8).empty,
            .escape_pending = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *InputEditor) void {
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.draft.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.escape_pending.deinit(self.allocator);
    }

    pub fn feed(self: *InputEditor, data: []const u8) !InputEvent {
        if (self.pending.items.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(self.allocator);
            try combined.appendSlice(self.allocator, self.pending.items);
            try combined.appendSlice(self.allocator, data);
            self.pending.clearRetainingCapacity();
            return self.feed(combined.items);
        }
        if (self.escape_pending.items.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(self.allocator);
            try combined.appendSlice(self.allocator, self.escape_pending.items);
            try combined.appendSlice(self.allocator, data);
            self.escape_pending.clearRetainingCapacity();
            return self.feedReady(combined.items);
        }
        return self.feedReady(data);
    }

    fn feedReady(self: *InputEditor, data: []const u8) !InputEvent {
        var i: usize = 0;
        while (i < data.len) {
            const ch = data[i];
            if (ch == '\x1b') {
                const sequence_len = escapeSequenceLength(data[i..]) orelse {
                    try self.escape_pending.appendSlice(self.allocator, data[i..]);
                    return .none;
                };
                const sequence = data[i .. i + sequence_len];
                if (std.mem.eql(u8, sequence, "\x1b[200~")) {
                    self.in_paste = true;
                } else if (std.mem.eql(u8, sequence, "\x1b[201~")) {
                    self.in_paste = false;
                } else if (self.in_paste) {
                    for (sequence) |byte| try self.insertByte(byte);
                } else if (sequence.len == 2 and (sequence[1] == '\r' or sequence[1] == '\n')) {
                    try self.insertByte('\n');
                } else {
                    try self.handleEscape(sequence);
                }
                i += sequence_len;
                continue;
            }
            if (self.in_paste) {
                try self.insertByte(if (ch == '\r') '\n' else ch);
                i += 1;
                continue;
            }
            if (ch == 0x03) return .cancelled;
            if (ch == 0x04 and self.buffer.items.len == 0) return .closed;
            if (ch == 0x01) {
                self.selectAll();
                i += 1;
                continue;
            }
            if (ch == '\r' or ch == '\n') {
                if (i + 1 < data.len) try self.pending.appendSlice(self.allocator, data[i + 1 ..]);
                return .{ .submitted = try self.submit() };
            }
            if (ch == 0x7f or ch == 0x08) {
                self.backspace();
                i += 1;
                continue;
            }
            if (ch >= ' ' or ch == '\t') {
                try self.insertByte(ch);
            }
            i += 1;
        }
        return .none;
    }

    fn handleEscape(self: *InputEditor, sequence: []const u8) !void {
        const final = sequence[sequence.len - 1];
        if (final == 'A') {
            if (self.buffer.items.len == 0 or self.history_index != null) {
                try self.historyPrev();
            } else {
                self.moveVertical(-1);
            }
            return;
        }
        if (final == 'B') {
            if (self.history_index != null) {
                try self.historyNext();
            } else {
                self.moveVertical(1);
            }
            return;
        }
        if (final == 'C') {
            if (self.select_all) {
                self.cursor = self.buffer.items.len;
                self.select_all = false;
            } else {
                self.cursor = nextCodepointStart(self.buffer.items, self.cursor);
            }
            self.preferred_column = null;
            return;
        }
        if (final == 'D') {
            if (self.select_all) {
                self.cursor = 0;
                self.select_all = false;
            } else {
                self.cursor = prevCodepointStart(self.buffer.items, self.cursor);
            }
            self.preferred_column = null;
            return;
        }
        if (final == 'H') {
            self.cursor = 0;
            self.select_all = false;
            self.preferred_column = null;
            return;
        }
        if (final == 'F') {
            self.cursor = self.buffer.items.len;
            self.select_all = false;
            self.preferred_column = null;
            return;
        }
        if (std.mem.eql(u8, sequence, "\x1b[3~")) {
            self.deleteForward();
            return;
        }
        if (std.mem.eql(u8, sequence, "\x1b[13;2u") or std.mem.eql(u8, sequence, "\x1b[13;3u")) {
            try self.insertByte('\n');
            return;
        }
        if (std.mem.eql(u8, sequence, "\x1b[97;5u")) {
            self.selectAll();
        }
    }

    fn selectAll(self: *InputEditor) void {
        self.select_all = self.buffer.items.len > 0;
        self.cursor = self.buffer.items.len;
        self.preferred_column = null;
    }

    fn insertByte(self: *InputEditor, byte: u8) !void {
        self.deleteSelection();
        try self.buffer.insert(self.allocator, self.cursor, byte);
        self.cursor += 1;
        self.history_index = null;
        self.preferred_column = null;
    }

    fn backspace(self: *InputEditor) void {
        if (self.select_all) return self.deleteSelection();
        if (self.cursor == 0) return;
        const start = prevCodepointStart(self.buffer.items, self.cursor);
        self.buffer.replaceRange(self.allocator, start, self.cursor - start, &.{}) catch return;
        self.cursor = start;
        self.history_index = null;
        self.preferred_column = null;
    }

    fn deleteForward(self: *InputEditor) void {
        if (self.select_all) return self.deleteSelection();
        if (self.cursor >= self.buffer.items.len) return;
        const end = nextCodepointStart(self.buffer.items, self.cursor);
        self.buffer.replaceRange(self.allocator, self.cursor, end - self.cursor, &.{}) catch return;
        self.history_index = null;
        self.preferred_column = null;
    }

    fn deleteSelection(self: *InputEditor) void {
        if (!self.select_all) return;
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.select_all = false;
        self.history_index = null;
        self.preferred_column = null;
    }

    fn moveVertical(self: *InputEditor, direction: i8) void {
        self.select_all = false;
        const current_start = logicalLineStart(self.buffer.items, self.cursor);
        const current_end = logicalLineEnd(self.buffer.items, self.cursor);
        const line_columns = codepointCount(self.buffer.items[current_start..current_end]);
        const current_column = codepointCount(self.buffer.items[current_start..self.cursor]);
        const width = @max(@as(usize, 1), self.navigation_width);
        const current_row = visualRowIndex(current_column, line_columns, width);
        const desired = self.preferred_column orelse current_column - current_row * width;
        self.preferred_column = desired;
        if (direction < 0) {
            if (current_row > 0) {
                const target_column = @min((current_row - 1) * width + desired, current_row * width);
                self.cursor = cursorAtColumn(self.buffer.items, current_start, current_end, target_column);
                return;
            }
            if (current_start == 0) return;
            const target_end = current_start - 1;
            const target_start = logicalLineStart(self.buffer.items, target_end);
            const target_columns = codepointCount(self.buffer.items[target_start..target_end]);
            const target_row = visualRowIndex(target_columns, target_columns, width);
            self.cursor = cursorAtColumn(self.buffer.items, target_start, target_end, @min(target_row * width + desired, target_columns));
            return;
        }
        const last_row = visualRowIndex(line_columns, line_columns, width);
        if (current_row < last_row) {
            const target_column = @min((current_row + 1) * width + desired, line_columns);
            self.cursor = cursorAtColumn(self.buffer.items, current_start, current_end, target_column);
            return;
        }
        if (current_end == self.buffer.items.len) return;
        const target_start = current_end + 1;
        const target_end = logicalLineEnd(self.buffer.items, target_start);
        self.cursor = cursorAtColumn(self.buffer.items, target_start, target_end, desired);
    }

    fn submit(self: *InputEditor) ![]u8 {
        const line = try self.allocator.dupe(u8, self.buffer.items);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) {
            try self.pushHistory(trimmed);
        }
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.select_all = false;
        self.preferred_column = null;
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
        self.select_all = false;
        self.preferred_column = null;
    }

    pub fn loadHistoryNewestFirst(self: *InputEditor, lines: []const []const u8) !void {
        for (self.history.items) |item| self.allocator.free(item);
        self.history.clearRetainingCapacity();
        var i: usize = 0;
        while (i < lines.len and i < 200) : (i += 1) {
            const trimmed = std.mem.trim(u8, lines[i], " \t\r\n");
            if (trimmed.len == 0) continue;
            try self.history.append(self.allocator, try self.allocator.dupe(u8, trimmed));
        }
    }

    pub fn clearHistory(self: *InputEditor) void {
        for (self.history.items) |item| self.allocator.free(item);
        self.history.clearRetainingCapacity();
        self.history_index = null;
        self.draft.clearRetainingCapacity();
    }
};

fn escapeSequenceLength(data: []const u8) ?usize {
    if (data.len < 2) return null;
    if (data[1] == '\r' or data[1] == '\n') return 2;
    if (data[1] == 'O') return if (data.len >= 3) 3 else null;
    if (data[1] != '[') return 2;
    var index: usize = 2;
    while (index < data.len) : (index += 1) {
        if (data[index] >= 0x40 and data[index] <= 0x7e) return index + 1;
    }
    return null;
}

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
        terminal_rows: usize = 0,
        terminal_cols: usize = 0,
        attached: bool = false,
        last_status: ?[]const u8 = null,
        status_started_ms: i64 = 0,
        token_input: usize = 0,
        token_output: usize = 0,
        token_total: usize = 0,
        token_tps: ?f64 = null,
        has_token_usage: bool = false,
        context_used_tokens: usize = 0,
        context_limit_tokens: usize = 0,
        has_context_usage: bool = false,
        footer_model: []const u8 = "",
        cwd_buf: [4096]u8 = undefined,
        footer_cwd: []const u8 = "",
        visualizer_mode: VisualizerMode = .idle,
        visualizer_tick: usize = 0,
        visualizer: MiniVisualizer,
        show_prompt: bool = true,
        status_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        status_thread: ?std.Thread = null,
        cancel_input_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cancel_input_stdin_flags: c_int = -1,
        write_mutex: std.atomic.Mutex = .unlocked,

        const Self = @This();
        const DrawOptions = struct { status: ?[]const u8, show_prompt: bool, preserve_cursor: bool };

        pub fn init(allocator: std.mem.Allocator, writer: Writer, color: bool) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .color = color,
                .editor = InputEditor.init(allocator),
                .visualizer = MiniVisualizer.init(20),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stopInferenceCancelInput();
            self.stopStatusTicker();
            self.detach() catch {};
            self.editor.deinit();
        }

        pub fn mutex(self: *Self) *std.atomic.Mutex {
            return &self.write_mutex;
        }

        pub fn setFooterModel(self: *Self, model: []const u8) void {
            self.footer_model = model;
        }

        pub fn refreshFooterCwd(self: *Self) void {
            if (c.getcwd(&self.cwd_buf, self.cwd_buf.len)) |ptr| {
                const cwd = std.mem.span(ptr);
                self.footer_cwd = if (c.getenv("HOME")) |home_ptr|
                    abbreviateHomeInPlace(&self.cwd_buf, cwd, std.mem.span(home_ptr))
                else
                    cwd;
            } else {
                self.footer_cwd = "";
            }
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
            lockTerminal(&self.write_mutex);
            defer self.write_mutex.unlock();
            try self.writer.writeAll("\x1b[?7l\x1b[?2004h");
            try self.resyncScrollRegion();
            try self.drawUnlocked(.{ .status = null, .show_prompt = true, .preserve_cursor = false });
        }

        pub fn detach(self: *Self) !void {
            if (!self.attached and !self.raw_enabled) return;
            self.stopInferenceCancelInput();
            self.stopStatusTicker();
            lockTerminal(&self.write_mutex);
            defer self.write_mutex.unlock();
            try self.writer.writeAll("\x1b[r");
            try self.clearBottom();
            try self.writer.writeAll("\x1b[?2004l\x1b[?7h");
            if (self.raw_enabled) {
                _ = c.tcsetattr(self.stdin_fd, c.TCSAFLUSH, &self.original_termios);
                self.raw_enabled = false;
            }
            self.attached = false;
        }

        pub fn readLine(self: *Self) !?[]u8 {
            var buf: [64]u8 = undefined;
            while (true) {
                const size = terminalSize();
                self.editor.navigation_width = promptContentWidth(@max(@as(usize, 1), size.cols -| 1));
                const event = if (self.editor.pending.items.len > 0) blk: {
                    break :blk try self.editor.feed("");
                } else blk: {
                    var descriptor = c.pollfd{ .fd = self.stdin_fd, .events = c.POLLIN, .revents = 0 };
                    const poll_result = c.poll(&descriptor, 1, 100);
                    if (poll_result < 0) {
                        if (c.__errno_location().* == c.EINTR) continue;
                        return error.StdinReadFailed;
                    }
                    if (poll_result == 0) {
                        if (size.rows != self.terminal_rows or size.cols != self.terminal_cols) {
                            try self.draw(.{ .status = null, .show_prompt = true, .preserve_cursor = false });
                        }
                        continue;
                    }
                    const n_raw = c.read(self.stdin_fd, &buf, buf.len);
                    if (n_raw < 0) {
                        if (c.__errno_location().* == c.EINTR) continue;
                        return error.StdinReadFailed;
                    }
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
            lockTerminal(&self.write_mutex);
            defer self.write_mutex.unlock();
            const size = terminalSize();
            const last = @max(@as(usize, 1), size.rows -| self.bottom_rows);
            try self.writer.print("\x1b[{};1H", .{last});
        }

        pub fn showStatus(self: *Self, status: []const u8) !void {
            self.last_status = status;
            self.visualizer_mode = modeFromLabel(status);
            self.visualizer.setMode(self.visualizer_mode, monotonicMs());
            self.visualizer_tick +%= 1;
            self.show_prompt = false;
            try self.startStatusTicker();
            try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
        }

        pub fn clearTokenUsage(self: *Self) void {
            self.token_input = 0;
            self.token_output = 0;
            self.token_total = 0;
            self.token_tps = null;
            self.has_token_usage = false;
            self.context_used_tokens = 0;
            self.context_limit_tokens = 0;
            self.has_context_usage = false;
        }

        pub fn showTokenUsage(self: *Self, input: usize, output: usize, total: usize, tokens_per_second: ?f64) !void {
            self.token_input = input;
            self.token_output = output;
            self.token_total = total;
            self.token_tps = tokens_per_second;
            self.has_token_usage = true;
            if (self.last_status) |status| {
                self.visualizer_tick +%= 1;
                try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
            }
        }

        pub fn showContextUsage(self: *Self, used_tokens: usize, limit_tokens: usize) !void {
            self.context_used_tokens = used_tokens;
            self.context_limit_tokens = limit_tokens;
            self.has_context_usage = true;
            if (self.last_status == null) {
                self.last_status = "Thinking";
                self.visualizer_mode = .thinking;
                self.visualizer.setMode(.thinking, monotonicMs());
                self.show_prompt = false;
                try self.startStatusTicker();
            }
            const status = self.last_status orelse return;
            self.visualizer_tick +%= 1;
            try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
        }

        pub fn pulseStatus(self: *Self) !void {
            if (self.last_status) |status| {
                self.visualizer_tick +%= 1;
                try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
            }
        }

        pub fn showDone(self: *Self) !void {
            self.stopStatusTicker();
            self.last_status = "Worked for 0s";
            self.visualizer_mode = .idle;
            self.visualizer.setMode(.idle, monotonicMs());
            self.show_prompt = true;
            try self.draw(.{ .status = "Worked for 0s", .show_prompt = true, .preserve_cursor = false });
        }

        pub fn showPrompt(self: *Self) !void {
            self.stopStatusTicker();
            self.last_status = null;
            self.visualizer_mode = .idle;
            self.visualizer.setMode(.idle, monotonicMs());
            self.show_prompt = true;
            try self.draw(.{ .status = null, .show_prompt = true, .preserve_cursor = false });
        }

        pub fn startInferenceCancelInput(self: *Self, token: *std.atomic.Value(bool)) !void {
            if (!self.attached or !self.raw_enabled) return;
            if (self.cancel_input_running.load(.acquire)) return;
            token.store(false, .release);
            try self.enableRawNow();
            self.cancel_input_stdin_flags = c.fcntl(self.stdin_fd, c.F_GETFL, @as(c_int, 0));
            if (self.cancel_input_stdin_flags >= 0) {
                _ = c.fcntl(self.stdin_fd, c.F_SETFL, self.cancel_input_stdin_flags | c.O_NONBLOCK);
            }
            self.cancel_input_running.store(true, .release);
        }

        pub fn inferenceCancelFd(self: *Self) ?c_int {
            if (!self.cancel_input_running.load(.acquire)) return null;
            return self.stdin_fd;
        }

        pub fn stopInferenceCancelInput(self: *Self) void {
            if (!self.cancel_input_running.swap(false, .acq_rel)) return;
            if (self.cancel_input_stdin_flags >= 0) {
                _ = c.fcntl(self.stdin_fd, c.F_SETFL, self.cancel_input_stdin_flags);
                self.cancel_input_stdin_flags = -1;
            }
        }

        fn startStatusTicker(self: *Self) !void {
            if (self.status_running.swap(true, .acq_rel)) return;
            self.status_started_ms = monotonicMs();
            self.status_thread = try std.Thread.spawn(.{}, statusThreadMain, .{self});
        }

        fn enableRawNow(self: *Self) !void {
            var raw = self.original_termios;
            c.cfmakeraw(&raw);
            if (c.tcsetattr(self.stdin_fd, c.TCSANOW, &raw) != 0) return error.TermiosSetFailed;
        }

        fn stopStatusTicker(self: *Self) void {
            if (!self.status_running.swap(false, .acq_rel)) return;
            if (self.status_thread) |thread| {
                thread.join();
                self.status_thread = null;
            }
        }

        fn statusThreadMain(self: *Self) void {
            while (self.status_running.load(.acquire)) {
                _ = c.usleep(33 * 1000);
                if (!self.status_running.load(.acquire)) break;
                self.pulseStatus() catch {};
            }
        }

        fn draw(self: *Self, opts: DrawOptions) !void {
            lockTerminal(&self.write_mutex);
            defer self.write_mutex.unlock();
            try self.drawUnlocked(opts);
        }

        fn drawUnlocked(self: *Self, opts: DrawOptions) !void {
            if (!self.attached) return;
            const size = terminalSize();
            const paint_cols = @max(@as(usize, 1), size.cols -| 1);
            const max_footer_rows = @max(@as(usize, 1), size.rows -| 1);
            const max_prompt_lines = @min(max_rendered_prompt_rows, @max(@as(usize, 1), max_footer_rows -| 5));
            var view = try computePromptView(self.allocator, self.editor.buffer.items, self.editor.cursor, paint_cols, max_prompt_lines);
            defer view.deinit();
            const active_prompt_lines = if (opts.show_prompt) view.line_count else 1;
            const rows = @min(bottomBarRows(active_prompt_lines), max_footer_rows);
            const size_changed = size.rows != self.terminal_rows or size.cols != self.terminal_cols;
            if (rows != self.bottom_rows or size_changed) {
                const old_start = @max(@as(usize, 1), (size.rows -| self.bottom_rows) + 1);
                const new_start = @max(@as(usize, 1), (size.rows -| rows) + 1);
                const clear_start = @min(old_start, new_start);
                try self.writer.print("\x1b[r\x1b[{};1H\x1b[J", .{clear_start});
                self.prompt_rows = view.line_count;
                self.bottom_rows = rows;
                self.terminal_rows = size.rows;
                self.terminal_cols = size.cols;
                try self.resyncScrollRegionFor(size);
            }

            const status_row = @max(@as(usize, 1), (size.rows -| self.bottom_rows) + 1);
            var out = std.ArrayList(u8).empty;
            defer out.deinit(self.allocator);
            const bw = fd_writer.BufferWriter{ .allocator = self.allocator, .list = &out };
            var status_buf: [192]u8 = undefined;
            var footer_buf: [512]u8 = undefined;
            const status_text = if (opts.status) |status| self.formatStatus(status, &status_buf) else null;
            const footer = self.formatFooter(&footer_buf);
            var visualizer_buf: [max_visualizer_cols * 4]u8 = undefined;
            var visualizer_text: ?[]const u8 = null;
            if (status_text) |text| {
                if (opts.status != null and self.visualizer_mode != .idle) {
                    const visual_cols = visualizerWidth(text, paint_cols);
                    if (visual_cols > 0) {
                        self.visualizer.setWidth(visual_cols);
                        visualizer_text = try self.visualizer.render(&visualizer_buf, monotonicMs());
                    }
                }
            }
            if (opts.preserve_cursor) try bw.writeAll("\x1b7");
            try bw.print("\x1b[{};1H", .{status_row});
            _ = try renderBottomBar(bw, .{
                .color = self.color,
                .cols = size.cols,
                .status = status_text,
                .status_right = null,
                .footer = footer,
                .visualizer = visualizer_text,
                .visualizer_mode = null,
                .visualizer_tick = self.visualizer_tick,
                .prompt = self.editor.buffer.items,
                .cursor = self.editor.cursor,
                .show_prompt = opts.show_prompt,
                .prompt_line_limit = active_prompt_lines,
            });
            if (opts.preserve_cursor) {
                try bw.writeAll("\x1b8");
            } else if (opts.show_prompt) {
                const prompt_first_row = status_row + 3;
                const screen_col = @min(size.cols, @as(usize, 3) + view.cursor_col);
                const screen_row = @min(size.rows, prompt_first_row + view.cursor_row);
                try bw.print("\x1b[{};{}H", .{ screen_row, screen_col });
            }
            try self.writer.writeAll(out.items);
        }

        fn formatStatus(self: *Self, status: []const u8, buf: *[192]u8) []const u8 {
            if (!self.status_running.load(.acquire)) return status;
            if (std.mem.startsWith(u8, status, "Worked for")) return status;
            if (std.mem.indexOfScalar(u8, status, '(') != null) return status;
            const now = monotonicMs();
            const elapsed_ms: u64 = if (now > self.status_started_ms) @intCast(now - self.status_started_ms) else 0;
            const seconds = elapsed_ms / 1000;
            if (self.has_token_usage) {
                var in_buf: [24]u8 = undefined;
                var out_buf: [24]u8 = undefined;
                const in_text = formatTokenCount(&in_buf, self.token_input);
                const out_text = self.formatOutputTokenCount(&out_buf);
                if (self.token_tps) |tps| {
                    if (seconds < 60) {
                        return std.fmt.bufPrint(buf, "{s} ({}s · ↓ {s} in · ↑ {s} out · {d:.1} tok/s · esc to interrupt)", .{ status, seconds, in_text, out_text, tps }) catch status;
                    }
                    return std.fmt.bufPrint(buf, "{s} ({}m {}s · ↓ {s} in · ↑ {s} out · {d:.1} tok/s · esc to interrupt)", .{ status, seconds / 60, seconds % 60, in_text, out_text, tps }) catch status;
                }
                if (seconds < 60) {
                    return std.fmt.bufPrint(buf, "{s} ({}s · ↓ {s} in · ↑ {s} out · esc to interrupt)", .{ status, seconds, in_text, out_text }) catch status;
                }
                return std.fmt.bufPrint(buf, "{s} ({}m {}s · ↓ {s} in · ↑ {s} out · esc to interrupt)", .{ status, seconds / 60, seconds % 60, in_text, out_text }) catch status;
            }
            if (seconds < 60) {
                return std.fmt.bufPrint(buf, "{s} ({}s · esc to interrupt)", .{ status, seconds }) catch status;
            }
            return std.fmt.bufPrint(buf, "{s} ({}m {}s · esc to interrupt)", .{ status, seconds / 60, seconds % 60 }) catch status;
        }

        fn formatStatusRight(self: *Self, buf: *[48]u8) ?[]const u8 {
            if (!self.has_context_usage or self.context_limit_tokens == 0) return null;
            var used_buf: [24]u8 = undefined;
            var limit_buf: [24]u8 = undefined;
            const used = formatTokenCount(&used_buf, self.context_used_tokens);
            const limit = formatTokenCount(&limit_buf, self.context_limit_tokens);
            const raw_pct = (@as(f64, @floatFromInt(self.context_used_tokens)) * 100.0) / @as(f64, @floatFromInt(self.context_limit_tokens));
            const pct = @min(raw_pct, 100.0);
            return std.fmt.bufPrint(buf, "ctx {d:.1}% {s}/{s} tok", .{ pct, used, limit }) catch null;
        }

        fn formatFooter(self: *Self, buf: *[512]u8) []const u8 {
            var ctx_buf: [48]u8 = undefined;
            const context_text = self.formatStatusRight(&ctx_buf) orelse "ctx --";
            const model = if (self.footer_model.len > 0) self.footer_model else "model?";
            const cwd = if (self.footer_cwd.len > 0) self.footer_cwd else "cwd?";
            return std.fmt.bufPrint(buf, "{s} · cwd {s} · {s}", .{ model, cwd, context_text }) catch context_text;
        }

        fn formatOutputTokenCount(self: *Self, buf: *[24]u8) []const u8 {
            var used_buf: [24]u8 = undefined;
            const used = formatTokenCount(&used_buf, self.token_output);
            return std.fmt.bufPrint(buf, "{s}", .{used}) catch "?";
        }

        fn resyncScrollRegion(self: *Self) !void {
            if (!self.attached) return;
            const size = terminalSize();
            if (self.bottom_rows == 0) self.bottom_rows = bottomBarRows(self.prompt_rows);
            self.terminal_rows = size.rows;
            self.terminal_cols = size.cols;
            try self.resyncScrollRegionFor(size);
        }

        fn resyncScrollRegionFor(self: *Self, size: TerminalSize) !void {
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

fn abbreviateHomeInPlace(buffer: []u8, path: []const u8, home: []const u8) []const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
    if (path.len > home.len and path[home.len] != '/') return path;
    const suffix = path[home.len..];
    std.mem.copyForwards(u8, buffer[1 .. 1 + suffix.len], suffix);
    buffer[0] = '~';
    return buffer[0 .. 1 + suffix.len];
}

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

pub fn terminalSize() TerminalSize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        return .{ .rows = @intCast(ws.ws_row), .cols = @intCast(ws.ws_col) };
    }
    return .{};
}

fn writeStatus(writer: anytype, color: bool, status: []const u8, right: ?[]const u8, visualizer: ?[]const u8, width: usize) !void {
    if (width == 0) return;
    const pad = @min(@as(usize, 2), width);
    if (pad > 0) try writeSpaces(writer, pad);
    const inner_width = width - pad;
    if (inner_width == 0) return;
    const visual = visualizer orelse "";
    const right_text = right orelse "";
    const right_cols = utf8Columns(right_text);
    if (right_cols > 0 and right_cols + 1 >= inner_width) {
        const clipped_right = right_text[0..utf8PrefixBytes(right_text, inner_width)];
        const clipped_right_cols = utf8Columns(clipped_right);
        if (clipped_right_cols < inner_width) try writeSpaces(writer, inner_width - clipped_right_cols);
        if (color) try writer.writeAll(dim);
        try writer.writeAll(clipped_right);
        if (color) try writer.writeAll(reset);
        return;
    }
    const visual_gap: usize = if (visual.len > 0) 1 else 0;
    const visual_cols = utf8Columns(visual);
    const right_gap: usize = if (right_cols > 0) 1 else 0;
    const reserved_cols = visual_cols + visual_gap + right_cols + right_gap;
    const status_width = if (inner_width > reserved_cols) inner_width - reserved_cols else inner_width;
    const clipped = status[0..utf8PrefixBytes(status, status_width)];
    const clipped_cols = utf8Columns(clipped);
    if (color) {
        if (std.mem.startsWith(u8, status, "Worked for")) try writer.writeAll(green) else try writer.writeAll(dim);
    }
    try writer.writeAll(clipped);
    if (color) try writer.writeAll(reset);
    if (visual.len > 0 and inner_width > clipped_cols + visual_cols + right_cols + right_gap) {
        try writeSpaces(writer, inner_width - clipped_cols - visual_cols - right_cols - right_gap);
        if (color) try writer.writeAll(cyan);
        try writer.writeAll(visual);
        if (color) try writer.writeAll(reset);
        if (right_cols > 0) try writeSpaces(writer, right_gap);
    } else if (right_cols > 0 and inner_width >= clipped_cols + right_cols) {
        try writeSpaces(writer, inner_width - clipped_cols - right_cols);
    } else if (right_cols == 0 and clipped_cols < inner_width) {
        try writeSpaces(writer, inner_width - clipped_cols);
    }
    if (right_cols > 0 and inner_width >= right_cols) {
        if (color) try writer.writeAll(dim);
        try writer.writeAll(right_text);
        if (color) try writer.writeAll(reset);
    }
}

fn writeStatusDynamic(writer: anytype, color: bool, status: []const u8, right: ?[]const u8, mode: VisualizerMode, tick: usize, width: usize) !void {
    if (right != null) return writeStatus(writer, color, status, right, null, width);
    const pad = @min(@as(usize, 2), width);
    if (pad > 0) try writeSpaces(writer, pad);
    const inner_width = width - pad;
    if (inner_width == 0) return;
    const min_visual_cols: usize = 4;
    const status_cols = @min(utf8Columns(status), inner_width);
    const visual_cols = if (inner_width > status_cols + 1 + min_visual_cols) inner_width - status_cols - 1 else 0;
    const clipped = status[0..utf8PrefixBytes(status, inner_width -| (visual_cols + if (visual_cols > 0) @as(usize, 1) else 0))];
    const clipped_cols = utf8Columns(clipped);
    if (color) try writer.writeAll(dim);
    try writer.writeAll(clipped);
    if (color) try writer.writeAll(reset);
    if (visual_cols > 0) {
        try writeSpaces(writer, inner_width - clipped_cols - visual_cols);
        if (color) try writer.writeAll(cyan);
        try writeVisualizerFrame(writer, mode, tick, visual_cols);
        if (color) try writer.writeAll(reset);
    } else if (clipped_cols < inner_width) {
        try writeSpaces(writer, inner_width - clipped_cols);
    }
}

fn writeFooter(writer: anytype, color: bool, footer: []const u8, width: usize) !void {
    if (width == 0) return;
    const clipped = footer[0..utf8PrefixBytes(footer, width)];
    const clipped_cols = utf8Columns(clipped);
    if (color) try writer.writeAll(dim);
    try writer.writeAll(clipped);
    if (clipped_cols < width) try writeSpaces(writer, width - clipped_cols);
    if (color) try writer.writeAll(reset);
}

fn visualizerWidth(status: []const u8, width: usize) usize {
    const min_visual_cols: usize = 4;
    const status_cols = @min(utf8Columns(status), width);
    if (width > status_cols + 1 + min_visual_cols) return width - status_cols - 1;
    return 0;
}

fn formatTokenCount(buf: *[24]u8, value: usize) []const u8 {
    if (value < 1000) return std.fmt.bufPrint(buf, "{}", .{value}) catch "0";
    const whole = value / 1000;
    const frac = (value % 1000) / 100;
    if (value < 10_000 and frac > 0) return std.fmt.bufPrint(buf, "{}.{}k", .{ whole, frac }) catch "0";
    if (value < 1_000_000) return std.fmt.bufPrint(buf, "{}k", .{whole}) catch "0";
    const m_whole = value / 1_000_000;
    const m_frac = (value % 1_000_000) / 100_000;
    if (m_frac > 0) return std.fmt.bufPrint(buf, "{}.{}m", .{ m_whole, m_frac }) catch "0";
    return std.fmt.bufPrint(buf, "{}m", .{m_whole}) catch "0";
}

fn formatByteCount(buf: *[24]u8, value: usize) []const u8 {
    if (value < 1024) return std.fmt.bufPrint(buf, "{}B", .{value}) catch "0B";
    const kb = value / 1024;
    const kb_frac = ((value % 1024) * 10) / 1024;
    if (kb < 10 and kb_frac > 0) return std.fmt.bufPrint(buf, "{}.{}KiB", .{ kb, kb_frac }) catch "0B";
    if (kb < 1024) return std.fmt.bufPrint(buf, "{}KiB", .{kb}) catch "0B";
    const mb = kb / 1024;
    const mb_frac = ((kb % 1024) * 10) / 1024;
    if (mb_frac > 0) return std.fmt.bufPrint(buf, "{}.{}MiB", .{ mb, mb_frac }) catch "0B";
    return std.fmt.bufPrint(buf, "{}MiB", .{mb}) catch "0B";
}

fn paintInputRow(writer: anytype, color: bool, prefix: []const u8, content: []const u8, width: usize) !void {
    if (color) try writer.writeAll(user_bg ++ user_fg);
    const prefix_len = @min(prefix.len, width);
    const content_len = @min(content.len, (width - prefix_len) -| 1);
    const used = prefix_len + content_len;
    try writer.writeAll(prefix[0..prefix_len]);
    try writer.writeAll(content[0..content_len]);
    if (used < width) try writeSpaces(writer, width - used);
    if (color) try writer.writeAll(reset);
}

fn promptContentWidth(paint_cols: usize) usize {
    return @max(@as(usize, 1), paint_cols -| 3);
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

fn logicalLineStart(bytes: []const u8, cursor: usize) usize {
    var index = @min(cursor, bytes.len);
    while (index > 0) : (index -= 1) {
        if (bytes[index - 1] == '\n') break;
    }
    return index;
}

fn logicalLineEnd(bytes: []const u8, cursor: usize) usize {
    return std.mem.indexOfScalarPos(u8, bytes, @min(cursor, bytes.len), '\n') orelse bytes.len;
}

fn codepointCount(bytes: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < bytes.len) : (count += 1) cursor = nextCodepointStart(bytes, cursor);
    return count;
}

fn visualRowIndex(column: usize, line_columns: usize, width: usize) usize {
    if (line_columns == 0) return 0;
    return @min(column / width, (line_columns - 1) / width);
}

fn cursorAtColumn(bytes: []const u8, start: usize, end: usize, column: usize) usize {
    var cursor = start;
    var current: usize = 0;
    while (cursor < end and current < column) : (current += 1) cursor = nextCodepointStart(bytes, cursor);
    return @min(cursor, end);
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

fn writeUtf8GlyphAt(writer: anytype, bytes: []const u8, glyph_index: usize) !void {
    var idx: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const start = i;
        i += 1;
        while (i < bytes.len and (bytes[i] & 0b1100_0000) == 0b1000_0000) : (i += 1) {}
        if (idx == glyph_index) {
            try writer.writeAll(bytes[start..i]);
            return;
        }
        idx += 1;
    }
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

test "input editor uses history only from explicit empty state" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    switch (try editor.feed("anterior\r")) {
        .submitted => |line| std.testing.allocator.free(line),
        else => return error.ExpectedSubmit,
    }
    try std.testing.expectEqual(InputEvent.none, try editor.feed("rascunho"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqualStrings("rascunho", editor.buffer.items);

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x01\x7f\x1b[A"));
    try std.testing.expectEqualStrings("anterior", editor.buffer.items);
}

test "input editor clears history" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    switch (try editor.feed("primeiro\r")) {
        .submitted => |line| std.testing.allocator.free(line),
        else => return error.ExpectedSubmit,
    }
    editor.clearHistory();
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqualStrings("", editor.buffer.items);
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

test "input editor preserves multiline keyboard input until plain enter" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expectEqual(InputEvent.none, try editor.feed("primeira\x1b\r  segunda\x1b[13;2u\x1b\rquarta"));
    switch (try editor.feed("\r")) {
        .submitted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("primeira\n  segunda\n\nquarta", line);
        },
        else => return error.ExpectedSubmit,
    }
}

test "input editor navigates multiline rows and preserves desired column" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[200~abcde\nxy\n12345\x1b[201~"));
    try std.testing.expectEqual(@as(usize, 14), editor.cursor);

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqual(@as(usize, 8), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[B"));
    try std.testing.expectEqual(@as(usize, 8), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[B"));
    try std.testing.expectEqual(@as(usize, 14), editor.cursor);

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[D\x1b[A"));
    try std.testing.expectEqual(@as(usize, 8), editor.cursor);
}

test "input editor navigates soft wrapped visual rows" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();
    editor.navigation_width = 5;

    try std.testing.expectEqual(InputEvent.none, try editor.feed("abcdefghijkl"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A"));
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[B"));
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("X"));
    try std.testing.expectEqualStrings("abcdefgXhijkl", editor.buffer.items);
}

test "input editor arrow navigation edits multiline text at cursor" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[200~um\ndois\ntrês\x1b[201~"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[A\x1b[D"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("!"));
    try std.testing.expectEqualStrings("um\ndoi!s\ntrês", editor.buffer.items);
}

test "input editor accepts fragmented CSI and SS3 arrows" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[200~abcde\nxy\n12345\x1b[201~"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("[A"));
    try std.testing.expectEqual(@as(usize, 8), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1bO"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("A"));
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[1;1D"));
    try std.testing.expectEqual(InputEvent.none, try editor.feed("X"));
    try std.testing.expectEqualStrings("abcdXe\nxy\n12345", editor.buffer.items);
}

test "input editor ctrl a selection deletes or replaces all text" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[200~primeira\nsegunda\x1b[201~\x01"));
    try std.testing.expect(editor.select_all);
    try std.testing.expectEqual(InputEvent.none, try editor.feed(&.{0x7f}));
    try std.testing.expectEqualStrings("", editor.buffer.items);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);

    try std.testing.expectEqual(InputEvent.none, try editor.feed("antigo\x01novo"));
    try std.testing.expectEqualStrings("novo", editor.buffer.items);
    try std.testing.expect(!editor.select_all);
}

test "input editor preserves thousand line bracketed paste" {
    var editor = InputEditor.init(std.testing.allocator);
    defer editor.deinit();
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);

    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[200~"));
    for (0..1000) |index| {
        if (index > 0) {
            try expected.append(std.testing.allocator, '\n');
            try std.testing.expectEqual(InputEvent.none, try editor.feed("\r"));
        }
        var line_buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "linha {d:0>4}", .{index});
        try expected.appendSlice(std.testing.allocator, line);
        try std.testing.expectEqual(InputEvent.none, try editor.feed(line));
    }
    try std.testing.expectEqual(InputEvent.none, try editor.feed("\x1b[201~"));
    switch (try editor.feed("\r")) {
        .submitted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings(expected.items, line);
        },
        else => return error.ExpectedSubmit,
    }
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
        "                 \r\n" ++
        "  Thinking (3 ▁▂▃\r\n" ++
        "                 \r\n" ++
        "> ola            \r\n" ++
        "                 \r\n" ++
        "                 ";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "every full prompt line preserves one trailing column" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    _ = try renderBottomBar(writer, .{
        .color = false,
        .cols = 10,
        .prompt = "123456\nabcdef",
        .cursor = 13,
        .show_prompt = true,
        .prompt_line_limit = 2,
    });

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "> 123456 \r\n  abcdef ") != null);
}

test "status bar formats real token usage without accumulating" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var ui = TerminalUi(@TypeOf(writer)).init(std.testing.allocator, writer, false);
    defer ui.deinit();
    ui.status_running.store(true, .release);
    ui.status_started_ms = monotonicMs() - 3000;
    try ui.showTokenUsage(3900, 12, 3912, 7.5);

    var status_buf: [192]u8 = undefined;
    const status = ui.formatStatus("Thinking", &status_buf);
    try std.testing.expect(std.mem.indexOf(u8, status, "↓ 3.9k in") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "↑ 12 out") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "7.5 tok/s") != null);

    try ui.showTokenUsage(4000, 13, 4013, null);
    const updated = ui.formatStatus("Thinking", &status_buf);
    try std.testing.expect(std.mem.indexOf(u8, updated, "↓ 4k in") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "↑ 13 out") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "3.9k") == null);
}

test "status bar does not fabricate output token limit" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var ui = TerminalUi(@TypeOf(writer)).init(std.testing.allocator, writer, false);
    defer ui.deinit();
    ui.status_running.store(true, .release);
    ui.status_started_ms = monotonicMs() - 1000;
    try ui.showTokenUsage(1200, 64, 1264, null);

    var status_buf: [192]u8 = undefined;
    const status = ui.formatStatus("Responding", &status_buf);
    try std.testing.expect(std.mem.indexOf(u8, status, "↑ 64 out") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "max?") == null);
}

test "footer shows model cwd and context usage" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var ui = TerminalUi(@TypeOf(writer)).init(std.testing.allocator, writer, false);
    defer ui.deinit();
    ui.setFooterModel("llama3.2");
    ui.footer_cwd = "/tmp/project";
    try ui.showContextUsage(8192, 24 * 1024);

    var footer_buf: [512]u8 = undefined;
    const footer = ui.formatFooter(&footer_buf);
    try std.testing.expectEqualStrings("llama3.2 · cwd /tmp/project · ctx 33.3% 8.1k/24k tok", footer);
}

test "footer cwd abbreviates only the exact home path" {
    var buffer: [128]u8 = undefined;
    const path = "/home/alice/project";
    @memcpy(buffer[0..path.len], path);
    try std.testing.expectEqualStrings("~/project", abbreviateHomeInPlace(&buffer, buffer[0..path.len], "/home/alice"));

    const sibling = "/home/alice2/project";
    @memcpy(buffer[0..sibling.len], sibling);
    try std.testing.expectEqualStrings(sibling, abbreviateHomeInPlace(&buffer, buffer[0..sibling.len], "/home/alice"));
}

test "context usage starts thinking status when shown before model tokens" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var ui = TerminalUi(@TypeOf(writer)).init(std.testing.allocator, writer, false);
    defer ui.deinit();

    try ui.showContextUsage(737, 65_536);

    try std.testing.expectEqualStrings("Thinking", ui.last_status orelse return error.ExpectedStatus);
    var footer_buf: [512]u8 = undefined;
    const footer = ui.formatFooter(&footer_buf);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 1.1% 737/65k tok") != null);
}

test "bottom bar keeps context out of top status" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    _ = try renderBottomBar(writer, .{
        .color = false,
        .cols = 40,
        .status = "Thinking",
        .footer = "llama3.2 · cwd /tmp/project · ctx 33.3% 8.1k/24k tok",
        .prompt = "",
        .cursor = 0,
        .show_prompt = false,
    });

    const first_line_end = std.mem.indexOf(u8, buffer.items, "\r\n") orelse return error.ExpectedTopPad;
    try std.testing.expectEqualStrings("                                       ", buffer.items[0..first_line_end]);
    const status_start = first_line_end + "\r\n".len;
    const status_rel_end = std.mem.indexOf(u8, buffer.items[status_start..], "\r\n") orelse return error.ExpectedStatusLine;
    const status_line = buffer.items[status_start..][0..status_rel_end];
    try std.testing.expectEqualStrings("  Thinking                             ", status_line);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "llama3.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "ctx") == null);
}

test "bottom bar shows footer below prompt while idle" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    _ = try renderBottomBar(writer, .{
        .color = false,
        .cols = 40,
        .status = null,
        .footer = "local · cwd /tmp/project · ctx 1.1% 737/65k tok",
        .prompt = "proxima query",
        .cursor = 12,
        .show_prompt = true,
    });

    var it = std.mem.splitSequence(u8, buffer.items, "\r\n");
    _ = it.next() orelse return error.ExpectedTopPad;
    _ = it.next() orelse return error.ExpectedStatusLine;
    _ = it.next() orelse return error.ExpectedPromptPad;
    const prompt = it.next() orelse return error.ExpectedPrompt;
    const lower_pad = it.next() orelse return error.ExpectedLowerPad;
    const footer = it.next() orelse return error.ExpectedFooter;
    try std.testing.expectEqualStrings("> proxima query                        ", prompt);
    try std.testing.expectEqualStrings("                                       ", lower_pad);
    try std.testing.expect(std.mem.startsWith(u8, footer, "local · cwd /tmp/project · ctx 1.1%"));
}

test "prompt view wraps and keeps cursor in visible window" {
    var view = try computePromptView(std.testing.allocator, "abcdefghi", 9, 6, 10);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 3), view.line_count);
    try std.testing.expectEqualStrings("abc", view.storage[0]);
    try std.testing.expectEqualStrings("def", view.storage[1]);
    try std.testing.expectEqualStrings("ghi", view.storage[2]);
    try std.testing.expectEqual(@as(usize, 2), view.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), view.cursor_col);
}

test "prompt view honors small terminal line limit" {
    var view = try computePromptViewLimited(std.testing.allocator, "abcdefghijkl", 12, 6, 2);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 2), view.line_count);
    try std.testing.expectEqualStrings("ghi", view.storage[0]);
    try std.testing.expectEqualStrings("jkl", view.storage[1]);
}

test "prompt view has no hidden 256 line truncation" {
    var prompt = std.ArrayList(u8).empty;
    defer prompt.deinit(std.testing.allocator);
    for (0..1000) |index| {
        if (index > 0) try prompt.append(std.testing.allocator, '\n');
        try prompt.appendSlice(std.testing.allocator, "x");
    }
    var view = try computePromptViewLimited(std.testing.allocator, prompt.items, prompt.items.len, 80, max_rendered_prompt_rows);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 10), view.line_count);
    try std.testing.expectEqual(@as(usize, 990), view.first_visible);
    try std.testing.expectEqual(@as(usize, 9), view.cursor_row);
}

test "prompt viewport scrolls around cursor with ten rendered lines" {
    const prompt = "00\n01\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12\n13\n14";

    var start = try computePromptViewLimited(std.testing.allocator, prompt, 0, 80, max_rendered_prompt_rows);
    defer start.deinit();
    try std.testing.expectEqual(@as(usize, 0), start.first_visible);
    try std.testing.expectEqualStrings("00", start.storage[0]);
    try std.testing.expectEqualStrings("09", start.storage[9]);

    const middle_cursor = std.mem.indexOf(u8, prompt, "10") orelse return error.ExpectedLine;
    var middle = try computePromptViewLimited(std.testing.allocator, prompt, middle_cursor, 80, max_rendered_prompt_rows);
    defer middle.deinit();
    try std.testing.expectEqual(@as(usize, 1), middle.first_visible);
    try std.testing.expectEqual(@as(usize, 9), middle.cursor_row);
    try std.testing.expectEqualStrings("01", middle.storage[0]);
    try std.testing.expectEqualStrings("10", middle.storage[9]);

    var end = try computePromptViewLimited(std.testing.allocator, prompt, prompt.len, 80, max_rendered_prompt_rows);
    defer end.deinit();
    try std.testing.expectEqual(@as(usize, 5), end.first_visible);
    try std.testing.expectEqual(@as(usize, 9), end.cursor_row);
    try std.testing.expectEqualStrings("05", end.storage[0]);
    try std.testing.expectEqualStrings("14", end.storage[9]);
}

test "visualizer frame and mode mapping are deterministic" {
    try std.testing.expectEqualStrings("▁▂▃▄▅▄▃▂▁▂", visualizerFrame(.thinking, 0));
    try std.testing.expectEqual(VisualizerMode.working, modeFromLabel("Patching files"));
    try std.testing.expectEqual(VisualizerMode.listening, modeFromLabel("Reading context"));
}

test "mini visualizer renders baseline idle and active wave" {
    var visualizer = MiniVisualizer.init(8);
    var buf: [128]u8 = undefined;
    const now = monotonicMs();
    const idle = try visualizer.render(&buf, now);
    try std.testing.expectEqual(@as(usize, 8), utf8Columns(idle));
    try std.testing.expect(std.mem.indexOf(u8, idle, "▁") != null);

    visualizer.setMode(.responding, now);
    const active = try visualizer.render(&buf, now + 3000);
    try std.testing.expectEqual(@as(usize, 8), utf8Columns(active));
    try std.testing.expect(active.len > 0);
}

test "mini visualizer resizes without stale width" {
    var visualizer = MiniVisualizer.init(6);
    visualizer.setWidth(12);
    var buf: [256]u8 = undefined;
    const frame = try visualizer.render(&buf, monotonicMs());
    try std.testing.expectEqual(@as(usize, 12), utf8Columns(frame));
}
