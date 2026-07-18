const std = @import("std");
const fd_writer = @import("fd_writer.zig");

const c = @cImport({
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
    visualizer: ?[]const u8 = null,
    visualizer_mode: ?VisualizerMode = null,
    visualizer_tick: usize = 0,
    prompt: []const u8 = "",
    cursor: usize = 0,
    show_prompt: bool = true,
    prompt_line_limit: usize = max_prompt_rows,
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
    return 1 + 1 + @max(@as(usize, 1), @min(max_prompt_rows, prompt_rows)) + 1;
}

pub fn renderBottomBar(writer: anytype, state: BottomBarState) !usize {
    const paint_cols = @max(@as(usize, 1), state.cols -| 1);
    var rows_written: usize = 0;

    if (state.status) |status| {
        if (state.visualizer_mode) |mode| {
            try writeStatusDynamic(writer, state.color, status, state.status_right, mode, state.visualizer_tick, paint_cols);
        } else {
            try writeStatus(writer, state.color, status, state.status_right, state.visualizer, paint_cols);
        }
    } else {
        try writeSpaces(writer, paint_cols);
    }
    rows_written += 1;

    try writer.writeAll("\r\n");
    try paintInputBlank(writer, state.color, paint_cols);
    rows_written += 1;

    if (state.show_prompt) {
        const view = computePromptViewLimited(state.prompt, state.cursor, paint_cols, state.prompt_line_limit);
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
    return computePromptViewLimited(prompt, cursor, paint_cols, max_prompt_rows);
}

pub fn computePromptViewLimited(prompt: []const u8, cursor: usize, paint_cols: usize, line_limit: usize) PromptView {
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

    const safe_limit = @max(@as(usize, 1), @min(max_prompt_rows, line_limit));
    const visible_count = @min(safe_limit, wrapped_len);
    var first_visible: usize = 0;
    if (wrapped_len > safe_limit) {
        first_visible = @min(wrapped_len - safe_limit, cursor_wrapped_row);
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
        terminal_rows: usize = 0,
        terminal_cols: usize = 0,
        attached: bool = false,
        last_status: ?[]const u8 = null,
        status_started_ms: i64 = 0,
        token_input: usize = 0,
        token_output: usize = 0,
        token_total: usize = 0,
        token_output_limit: ?usize = null,
        token_tps: ?f64 = null,
        has_token_usage: bool = false,
        context_used_bytes: usize = 0,
        context_limit_bytes: usize = 0,
        has_context_usage: bool = false,
        visualizer_mode: VisualizerMode = .idle,
        visualizer_tick: usize = 0,
        visualizer: MiniVisualizer,
        show_prompt: bool = true,
        status_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        status_thread: ?std.Thread = null,
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
            self.detach() catch {};
            self.editor.deinit();
        }

        pub fn mutex(self: *Self) *std.atomic.Mutex {
            return &self.write_mutex;
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
            try self.writer.writeAll("\x1b[?2004h");
            try self.resyncScrollRegion();
            try self.drawUnlocked(.{ .status = null, .show_prompt = true, .preserve_cursor = false });
        }

        pub fn detach(self: *Self) !void {
            if (!self.attached and !self.raw_enabled) return;
            self.stopStatusTicker();
            lockTerminal(&self.write_mutex);
            defer self.write_mutex.unlock();
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
            self.token_output_limit = null;
            self.token_tps = null;
            self.has_token_usage = false;
            self.context_used_bytes = 0;
            self.context_limit_bytes = 0;
            self.has_context_usage = false;
        }

        pub fn setTokenOutputLimit(self: *Self, limit: usize) void {
            self.token_output_limit = limit;
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

        pub fn showContextUsage(self: *Self, used_bytes: usize, limit_bytes: usize) !void {
            self.context_used_bytes = used_bytes;
            self.context_limit_bytes = limit_bytes;
            self.has_context_usage = true;
            if (self.last_status) |status| {
                self.visualizer_tick +%= 1;
                try self.draw(.{ .status = status, .show_prompt = false, .preserve_cursor = true });
            }
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

        fn startStatusTicker(self: *Self) !void {
            if (self.status_running.swap(true, .acq_rel)) return;
            self.status_started_ms = monotonicMs();
            self.status_thread = try std.Thread.spawn(.{}, statusThreadMain, .{self});
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
            const view = computePromptView(self.editor.buffer.items, self.editor.cursor, paint_cols);
            const max_footer_rows = @max(@as(usize, 1), size.rows -| 1);
            const max_prompt_lines = @max(@as(usize, 1), max_footer_rows -| 3);
            const active_prompt_lines = if (opts.show_prompt) @min(view.line_count, max_prompt_lines) else 1;
            const rows = @min(bottomBarRows(active_prompt_lines), max_footer_rows);
            const size_changed = size.rows != self.terminal_rows or size.cols != self.terminal_cols;
            if (rows != self.bottom_rows or size_changed) {
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
            var status_right_buf: [48]u8 = undefined;
            const status_text = if (opts.status) |status| self.formatStatus(status, &status_buf) else null;
            const status_right = self.formatStatusRight(&status_right_buf);
            var visualizer_buf: [max_visualizer_cols * 4]u8 = undefined;
            var visualizer_text: ?[]const u8 = null;
            if (status_text) |text| {
                if (opts.status != null and self.visualizer_mode != .idle and status_right == null) {
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
                .status_right = status_right,
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
                const prompt_first_row = status_row + 2;
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
                const limit_text = if (self.tokenOutputAtLimit()) " · max?" else "";
                if (self.token_tps) |tps| {
                    if (seconds < 60) {
                        return std.fmt.bufPrint(buf, "{s} ({}s · ↓ {s} in · ↑ {s} out{s} · {d:.1} tok/s · esc to interrupt)", .{ status, seconds, in_text, out_text, limit_text, tps }) catch status;
                    }
                    return std.fmt.bufPrint(buf, "{s} ({}m {}s · ↓ {s} in · ↑ {s} out{s} · {d:.1} tok/s · esc to interrupt)", .{ status, seconds / 60, seconds % 60, in_text, out_text, limit_text, tps }) catch status;
                }
                if (seconds < 60) {
                    return std.fmt.bufPrint(buf, "{s} ({}s · ↓ {s} in · ↑ {s} out{s} · esc to interrupt)", .{ status, seconds, in_text, out_text, limit_text }) catch status;
                }
                return std.fmt.bufPrint(buf, "{s} ({}m {}s · ↓ {s} in · ↑ {s} out{s} · esc to interrupt)", .{ status, seconds / 60, seconds % 60, in_text, out_text, limit_text }) catch status;
            }
            if (seconds < 60) {
                return std.fmt.bufPrint(buf, "{s} ({}s · esc to interrupt)", .{ status, seconds }) catch status;
            }
            return std.fmt.bufPrint(buf, "{s} ({}m {}s · esc to interrupt)", .{ status, seconds / 60, seconds % 60 }) catch status;
        }

        fn formatStatusRight(self: *Self, buf: *[48]u8) ?[]const u8 {
            if (!self.has_context_usage or self.context_limit_bytes == 0) return null;
            var used_buf: [24]u8 = undefined;
            var limit_buf: [24]u8 = undefined;
            const used = formatByteCount(&used_buf, self.context_used_bytes);
            const limit = formatByteCount(&limit_buf, self.context_limit_bytes);
            return std.fmt.bufPrint(buf, "ctx {s}/{s}", .{ used, limit }) catch null;
        }

        fn formatOutputTokenCount(self: *Self, buf: *[24]u8) []const u8 {
            var used_buf: [24]u8 = undefined;
            const used = formatTokenCount(&used_buf, self.token_output);
            if (self.token_output_limit) |limit| {
                var limit_buf: [24]u8 = undefined;
                const max = formatTokenCount(&limit_buf, limit);
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ used, max }) catch "?";
            }
            return std.fmt.bufPrint(buf, "{s}", .{used}) catch "?";
        }

        fn tokenOutputAtLimit(self: *Self) bool {
            const limit = self.token_output_limit orelse return false;
            return limit > 0 and self.token_output >= limit;
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
    const visual = visualizer orelse "";
    const right_text = right orelse "";
    const right_cols = utf8Columns(right_text);
    if (right_cols > 0 and right_cols + 1 >= width) {
        const clipped_right = right_text[0..utf8PrefixBytes(right_text, width)];
        const clipped_right_cols = utf8Columns(clipped_right);
        if (clipped_right_cols < width) try writeSpaces(writer, width - clipped_right_cols);
        if (color) try writer.writeAll(dim);
        try writer.writeAll(clipped_right);
        if (color) try writer.writeAll(reset);
        return;
    }
    const visual_gap: usize = if (visual.len > 0) 1 else 0;
    const visual_cols = utf8Columns(visual);
    const right_gap: usize = if (right_cols > 0) 1 else 0;
    const reserved_cols = visual_cols + visual_gap + right_cols + right_gap;
    const status_width = if (width > reserved_cols) width - reserved_cols else width;
    const clipped = status[0..utf8PrefixBytes(status, status_width)];
    const clipped_cols = utf8Columns(clipped);
    if (color) {
        if (std.mem.startsWith(u8, status, "Worked for")) try writer.writeAll(green) else try writer.writeAll(dim);
    }
    try writer.writeAll(clipped);
    if (color) try writer.writeAll(reset);
    if (visual.len > 0 and width > clipped_cols + visual_cols + right_cols + right_gap) {
        try writeSpaces(writer, width - clipped_cols - visual_cols - right_cols - right_gap);
        if (color) try writer.writeAll(cyan);
        try writer.writeAll(visual);
        if (color) try writer.writeAll(reset);
        if (right_cols > 0) try writeSpaces(writer, right_gap);
    } else if (right_cols > 0 and width >= clipped_cols + right_cols) {
        try writeSpaces(writer, width - clipped_cols - right_cols);
    } else if (right_cols == 0 and clipped_cols < width) {
        try writeSpaces(writer, width - clipped_cols);
    }
    if (right_cols > 0 and width >= right_cols) {
        if (color) try writer.writeAll(dim);
        try writer.writeAll(right_text);
        if (color) try writer.writeAll(reset);
    }
}

fn writeStatusDynamic(writer: anytype, color: bool, status: []const u8, right: ?[]const u8, mode: VisualizerMode, tick: usize, width: usize) !void {
    if (right != null) return writeStatus(writer, color, status, right, null, width);
    const min_visual_cols: usize = 4;
    const status_cols = @min(utf8Columns(status), width);
    const visual_cols = if (width > status_cols + 1 + min_visual_cols) width - status_cols - 1 else 0;
    const clipped = status[0..utf8PrefixBytes(status, width -| (visual_cols + if (visual_cols > 0) @as(usize, 1) else 0))];
    const clipped_cols = utf8Columns(clipped);
    if (color) try writer.writeAll(dim);
    try writer.writeAll(clipped);
    if (color) try writer.writeAll(reset);
    if (visual_cols > 0) {
        try writeSpaces(writer, width - clipped_cols - visual_cols);
        if (color) try writer.writeAll(cyan);
        try writeVisualizerFrame(writer, mode, tick, visual_cols);
        if (color) try writer.writeAll(reset);
    } else if (clipped_cols < width) {
        try writeSpaces(writer, width - clipped_cols);
    }
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
        "Thinking (3s  ▁▂▃\r\n" ++
        "                 \r\n" ++
        "> ola            \r\n" ++
        "                 ";
    try std.testing.expectEqualStrings(expected, buffer.items);
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

test "status bar shows output token limit when known" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var ui = TerminalUi(@TypeOf(writer)).init(std.testing.allocator, writer, false);
    defer ui.deinit();
    ui.status_running.store(true, .release);
    ui.status_started_ms = monotonicMs() - 1000;
    ui.setTokenOutputLimit(64);
    try ui.showTokenUsage(1200, 64, 1264, null);

    var status_buf: [192]u8 = undefined;
    const status = ui.formatStatus("Responding", &status_buf);
    try std.testing.expect(std.mem.indexOf(u8, status, "↑ 64/64 out") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "max?") != null);
}

test "status bar shows model context usage on the right" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var ui = TerminalUi(@TypeOf(writer)).init(std.testing.allocator, writer, false);
    defer ui.deinit();
    try ui.showContextUsage(8192, 24 * 1024);

    var right_buf: [48]u8 = undefined;
    const right = ui.formatStatusRight(&right_buf) orelse return error.ExpectedContextUsage;
    try std.testing.expectEqualStrings("ctx 8KiB/24KiB", right);
}

test "bottom bar keeps right status inside terminal width" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    _ = try renderBottomBar(writer, .{
        .color = false,
        .cols = 30,
        .status = "Thinking",
        .status_right = "ctx 8KiB/24KiB",
        .prompt = "",
        .cursor = 0,
        .show_prompt = false,
    });

    const first_line_end = std.mem.indexOf(u8, buffer.items, "\r\n") orelse return error.ExpectedStatusLine;
    try std.testing.expectEqualStrings("Thinking       ctx 8KiB/24KiB", buffer.items[0..first_line_end]);
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

test "prompt view honors small terminal line limit" {
    const view = computePromptViewLimited("abcdefghijkl", 12, 6, 2);
    try std.testing.expectEqual(@as(usize, 2), view.line_count);
    try std.testing.expectEqualStrings("efgh", view.storage[0]);
    try std.testing.expectEqualStrings("ijkl", view.storage[1]);
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
