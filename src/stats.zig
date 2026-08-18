const std = @import("std");

// Renders the `phenom stats` view: an aggregate report of session activity
// distilled from the SQLite audit trail (turns, token usage, tool calls,
// errors).
//
// Like `welcome.zig`, the rendering half is intentionally allocator-free and
// libc-free: it formats into stack buffers and writes to an `anytype` writer
// using plain `\n` line endings. The data model (`Report`) is filled by
// `audit.collectStats`, which owns the allocated strings and frees them via
// `Report.deinit`.

const reset = "\x1b[0m";
const c_dim = "\x1b[2m";
const c_bold = "\x1b[1m";
const c_accent = "\x1b[38;2;127;178;201m"; // soft cyan, echoes welcome/status tones
const c_violet = "\x1b[38;2;164;142;199m"; // soft violet
const c_yellow = "\x1b[38;2;226;203;139m"; // pastel yellow
const c_green = "\x1b[38;2;152;195;121m"; // soft green for healthy counters
const c_red = "\x1b[38;2;224;108;117m"; // soft red for errors

const Style = enum { plain, dim, accent, accent_bold, violet, yellow, green, red };

fn styleCode(style: Style) []const u8 {
    return switch (style) {
        .plain => "",
        .dim => c_dim,
        .accent => c_accent,
        .accent_bold => c_bold ++ c_accent,
        .violet => c_violet,
        .yellow => c_yellow,
        .green => c_green,
        .red => c_red,
    };
}

pub const Totals = struct {
    sessions: usize = 0,
    turns: usize = 0,
    tokens_in: usize = 0,
    tokens_out: usize = 0,
    tokens_total: usize = 0,
    tool_calls: usize = 0,
    errors: usize = 0,
    avg_tokens_per_second: ?f64 = null,
    first_activity_unix: ?i64 = null,
    last_activity_unix: ?i64 = null,
};

pub const SessionStat = struct {
    name: []const u8,
    turns: usize = 0,
    tokens_in: usize = 0,
    tokens_out: usize = 0,
    errors: usize = 0,
    last_activity_unix: ?i64 = null,
};

pub const ToolStat = struct {
    name: []const u8,
    count: usize = 0,
};

pub const Report = struct {
    totals: Totals = .{},
    sessions: []SessionStat = &.{},
    tools: []ToolStat = &.{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.sessions) |s| allocator.free(s.name);
        allocator.free(self.sessions);
        for (self.tools) |t| allocator.free(t.name);
        allocator.free(self.tools);
        self.* = .{};
    }
};

pub const RenderOptions = struct {
    color: bool = true,
    columns: usize = 80,
    // When set, the report was filtered to a single session; the multi-session
    // table is suppressed and the scope line names the session instead.
    session_filter: ?[]const u8 = null,
    version: []const u8 = "dev",
    db_path: []const u8 = ".phenom-zig/phenom.db",
};

// Caps so the view stays bounded no matter how large the audit trail grows.
const max_session_rows = 12;
const max_tool_rows = 8;
const bar_width = 18;

pub fn render(writer: anytype, report: Report, opts: RenderOptions) !void {
    const color = opts.color;

    // --- header ---
    try writer.writeAll("\n ");
    try writeStyled(writer, color, .accent_bold, "phenom");
    try writer.writeAll(" ");
    try writeStyled(writer, color, .accent, "stats");
    try writer.writeAll("  ");
    var vbuf: [48]u8 = undefined;
    const vline = std.fmt.bufPrint(&vbuf, "v{s}", .{opts.version}) catch opts.version;
    try writeStyled(writer, color, .dim, vline);
    try writer.writeAll("\n ");
    if (opts.session_filter) |s| {
        var sbuf: [160]u8 = undefined;
        const scope = std.fmt.bufPrint(&sbuf, "session {s}", .{s}) catch "session";
        try writeStyled(writer, color, .dim, scope);
    } else {
        try writeStyled(writer, color, .dim, "all sessions");
    }
    try writer.writeAll("\n\n");

    if (report.totals.turns == 0 and report.sessions.len == 0) {
        try writer.writeAll(" ");
        try writeStyled(writer, color, .yellow, "no activity recorded yet");
        try writer.writeAll("\n ");
        var pbuf: [256]u8 = undefined;
        const hint = std.fmt.bufPrint(&pbuf, "run `phenom chat` first (audit db: {s})", .{opts.db_path}) catch "run `phenom chat` first";
        try writeStyled(writer, color, .dim, hint);
        try writer.writeAll("\n\n");
        return;
    }

    try renderOverview(writer, report.totals, color, opts.columns);

    // --- per-session table (only meaningful when not filtered to one) ---
    if (opts.session_filter == null and report.sessions.len > 1) {
        try writer.writeAll("\n ");
        try writeStyled(writer, color, .dim, "by session");
        try writer.writeAll("\n");
        try renderSessionTable(writer, report.sessions, color);
    }

    // --- top tools bar chart ---
    if (report.tools.len > 0) {
        try writer.writeAll("\n ");
        try writeStyled(writer, color, .dim, "top tools");
        try writer.writeAll("\n");
        try renderToolBars(writer, report.tools, color);
    }

    try writer.writeAll("\n");
}

fn renderOverview(writer: anytype, totals: Totals, color: bool, columns: usize) !void {
    // Each formatted value keeps its own backing buffer so none clobber another.
    var g_sessions: [24]u8 = undefined;
    var g_turns: [24]u8 = undefined;
    var g_in: [24]u8 = undefined;
    var g_out: [24]u8 = undefined;
    var g_total: [24]u8 = undefined;
    var g_tools: [24]u8 = undefined;
    var g_errors: [24]u8 = undefined;
    var tps_buf: [24]u8 = undefined;
    var first_buf: [32]u8 = undefined;
    var last_buf: [32]u8 = undefined;

    const tps_text: []const u8 = if (totals.avg_tokens_per_second) |tps|
        std.fmt.bufPrint(&tps_buf, "{d:.1} tok/s", .{tps}) catch "—"
    else
        "—";

    const Row = struct { label: []const u8, value: []const u8, style: Style };
    const rows = [_]Row{
        .{ .label = "sessions", .value = groupUsize(&g_sessions, totals.sessions), .style = .plain },
        .{ .label = "turns", .value = groupUsize(&g_turns, totals.turns), .style = .accent },
        .{ .label = "tokens in", .value = groupUsize(&g_in, totals.tokens_in), .style = .plain },
        .{ .label = "tokens out", .value = groupUsize(&g_out, totals.tokens_out), .style = .plain },
        .{ .label = "tokens total", .value = groupUsize(&g_total, totals.tokens_total), .style = .violet },
        .{ .label = "throughput", .value = tps_text, .style = .plain },
        .{ .label = "tool calls", .value = groupUsize(&g_tools, totals.tool_calls), .style = .plain },
        .{ .label = "errors", .value = groupUsize(&g_errors, totals.errors), .style = if (totals.errors == 0) .green else .red },
        .{ .label = "first seen", .value = formatDay(&first_buf, totals.first_activity_unix), .style = .dim },
        .{ .label = "last seen", .value = formatDateTime(&last_buf, totals.last_activity_unix), .style = .dim },
    };

    const label_w = 13; // widest label + gap
    var value_w: usize = 0;
    for (rows) |r| value_w = @max(value_w, displayWidth(r.value));

    var inner = 2 + label_w + value_w + 2; // pad + label + value + pad
    const max_inner = if (columns > 6) columns - 3 else 24;
    if (inner > max_inner) inner = max_inner;
    if (inner < 30) inner = 30;

    try boxLine(writer, color, .top, inner);
    for (rows) |r| try overviewRow(writer, color, r.label, r.value, r.style, label_w, inner);
    try boxLine(writer, color, .bottom, inner);
}

fn overviewRow(writer: anytype, color: bool, label: []const u8, value: []const u8, value_style: Style, label_w: usize, inner: usize) !void {
    try writer.writeAll(" ");
    try writeStyled(writer, color, .dim, "│");
    try writer.writeAll("  ");
    var w: usize = 2;

    try writeStyled(writer, color, .dim, label);
    var lw = displayWidth(label);
    while (lw < label_w and w + lw < inner) : (lw += 1) try writer.writeAll(" ");
    w += @max(lw, label_w);

    const vw = displayWidth(value);
    if (w + vw <= inner) {
        try writeStyled(writer, color, value_style, value);
        w += vw;
    }
    while (w < inner) : (w += 1) try writer.writeAll(" ");
    try writeStyled(writer, color, .dim, "│");
    try writer.writeAll("\n");
}

fn renderSessionTable(writer: anytype, sessions: []const SessionStat, color: bool) !void {
    const headers = [_][]const u8{ "session", "turns", "tok in", "tok out", "err" };
    const aligns = [_]Align{ .left, .right, .right, .right, .right };

    const n = @min(sessions.len, max_session_rows);
    var widths = [_]usize{ 0, 0, 0, 0, 0 };
    for (headers, 0..) |h, i| widths[i] = displayWidth(h);

    // Two passes: measure, then render. Cell text is regenerated identically.
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const s = sessions[idx];
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var b3: [24]u8 = undefined;
        var b4: [24]u8 = undefined;
        widths[0] = @max(widths[0], displayWidth(clampName(s.name)));
        widths[1] = @max(widths[1], displayWidth(groupUsize(&b1, s.turns)));
        widths[2] = @max(widths[2], displayWidth(groupUsize(&b2, s.tokens_in)));
        widths[3] = @max(widths[3], displayWidth(groupUsize(&b3, s.tokens_out)));
        widths[4] = @max(widths[4], displayWidth(groupUsize(&b4, s.errors)));
    }

    try tableBorder(writer, color, .top, &widths);
    try tableRow(writer, color, &headers, &aligns, &widths, .dim, .dim);
    try tableBorder(writer, color, .mid, &widths);

    idx = 0;
    while (idx < n) : (idx += 1) {
        const s = sessions[idx];
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var b3: [24]u8 = undefined;
        var b4: [24]u8 = undefined;
        const cells = [_][]const u8{
            clampName(s.name),
            groupUsize(&b1, s.turns),
            groupUsize(&b2, s.tokens_in),
            groupUsize(&b3, s.tokens_out),
            groupUsize(&b4, s.errors),
        };
        try tableRow(writer, color, &cells, &aligns, &widths, .accent, .plain);
    }
    try tableBorder(writer, color, .bottom, &widths);

    if (sessions.len > n) {
        var mbuf: [64]u8 = undefined;
        const more = std.fmt.bufPrint(&mbuf, " (+{d} more)", .{sessions.len - n}) catch "";
        try writer.writeAll(" ");
        try writeStyled(writer, color, .dim, more);
        try writer.writeAll("\n");
    }
}

fn clampName(name: []const u8) []const u8 {
    const max = 20;
    if (displayWidth(name) <= max) return name;
    return name[0..prefixByteLen(name, max)];
}

fn renderToolBars(writer: anytype, tools: []const ToolStat, color: bool) !void {
    const n = @min(tools.len, max_tool_rows);
    if (n == 0) return;

    var name_w: usize = 0;
    var max_count: usize = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        name_w = @max(name_w, displayWidth(tools[i].name));
        max_count = @max(max_count, tools[i].count);
    }

    i = 0;
    while (i < n) : (i += 1) {
        const t = tools[i];
        try writer.writeAll("   ");
        try writeStyled(writer, color, .accent, t.name);
        var pad = displayWidth(t.name);
        while (pad < name_w) : (pad += 1) try writer.writeAll(" ");
        try writer.writeAll("  ");

        const filled = (t.count * bar_width) / max_count;
        var f: usize = 0;
        if (color) try writer.writeAll(c_accent);
        while (f < filled) : (f += 1) try writer.writeAll("█");
        if (color) try writer.writeAll(reset);
        if (color) try writer.writeAll(c_dim);
        var e: usize = filled;
        while (e < bar_width) : (e += 1) try writer.writeAll("░");
        if (color) try writer.writeAll(reset);

        var cbuf: [24]u8 = undefined;
        const ctext = groupUsize(&cbuf, t.count);
        try writer.writeAll("  ");
        try writeStyled(writer, color, .plain, ctext);
        try writer.writeAll("\n");
    }
}

// ---- table + box drawing primitives (mirrors welcome.zig style) ----

const Align = enum { left, right };
const BoxLineKind = enum { top, mid, bottom };

fn boxLine(writer: anytype, color: bool, kind: BoxLineKind, inner: usize) !void {
    const corners = switch (kind) {
        .top => [2][]const u8{ "╭", "╮" },
        .mid => [2][]const u8{ "├", "┤" },
        .bottom => [2][]const u8{ "╰", "╯" },
    };
    try writer.writeAll(" ");
    if (color) try writer.writeAll(c_dim);
    try writer.writeAll(corners[0]);
    var i: usize = 0;
    while (i < inner) : (i += 1) try writer.writeAll("─");
    try writer.writeAll(corners[1]);
    if (color) try writer.writeAll(reset);
    try writer.writeAll("\n");
}

fn tableBorder(writer: anytype, color: bool, kind: BoxLineKind, widths: []const usize) !void {
    const parts = switch (kind) {
        .top => [3][]const u8{ "╭", "┬", "╮" },
        .mid => [3][]const u8{ "├", "┼", "┤" },
        .bottom => [3][]const u8{ "╰", "┴", "╯" },
    };
    try writer.writeAll(" ");
    if (color) try writer.writeAll(c_dim);
    try writer.writeAll(parts[0]);
    for (widths, 0..) |w, i| {
        var j: usize = 0;
        while (j < w + 2) : (j += 1) try writer.writeAll("─");
        if (i + 1 < widths.len) try writer.writeAll(parts[1]);
    }
    try writer.writeAll(parts[2]);
    if (color) try writer.writeAll(reset);
    try writer.writeAll("\n");
}

fn tableRow(
    writer: anytype,
    color: bool,
    cells: []const []const u8,
    aligns: []const Align,
    widths: []const usize,
    first_style: Style,
    rest_style: Style,
) !void {
    try writer.writeAll(" ");
    try writeStyled(writer, color, .dim, "│");
    for (cells, 0..) |cell, i| {
        const w = widths[i];
        const dw = displayWidth(cell);
        const style: Style = if (i == 0) first_style else rest_style;
        try writer.writeAll(" ");
        if (aligns[i] == .right) {
            var pad: usize = dw;
            while (pad < w) : (pad += 1) try writer.writeAll(" ");
            try writeStyled(writer, color, style, cell);
        } else {
            try writeStyled(writer, color, style, cell);
            var pad: usize = dw;
            while (pad < w) : (pad += 1) try writer.writeAll(" ");
        }
        try writer.writeAll(" ");
        try writeStyled(writer, color, .dim, "│");
    }
    try writer.writeAll("\n");
}

fn writeStyled(writer: anytype, color: bool, style: Style, text: []const u8) !void {
    if (!color or style == .plain) {
        try writer.writeAll(text);
        return;
    }
    try writer.writeAll(styleCode(style));
    try writer.writeAll(text);
    try writer.writeAll(reset);
}

fn displayWidth(bytes: []const u8) usize {
    var cols: usize = 0;
    for (bytes) |b| {
        if ((b & 0b1100_0000) != 0b1000_0000) cols += 1;
    }
    return cols;
}

fn prefixByteLen(bytes: []const u8, max_columns: usize) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < bytes.len and columns < max_columns) : (columns += 1) {
        index += std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
    }
    return @min(index, bytes.len);
}

// Formats an unsigned integer with thin thousands separators: 12340 -> "12,340".
fn groupUsize(buf: []u8, value: usize) []const u8 {
    var digits: [20]u8 = undefined;
    var n = value;
    var d: usize = 0;
    if (n == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (n > 0) : (n /= 10) {
            digits[d] = @as(u8, '0') + @as(u8, @intCast(n % 10));
            d += 1;
        }
    }
    // digits currently least-significant first; emit most-significant first
    // with a comma before every group of three counted from the right. The
    // number of digits still to write (including the current one) is `i`, so a
    // separator precedes any non-leading digit where `i` is a multiple of 3.
    var out: usize = 0;
    var i: usize = d;
    while (i > 0) {
        i -= 1;
        if (out > 0 and (i + 1) % 3 == 0) {
            if (out >= buf.len) break;
            buf[out] = ',';
            out += 1;
        }
        if (out >= buf.len) break;
        buf[out] = digits[i];
        out += 1;
    }
    return buf[0..out];
}

fn formatDay(buf: []u8, unix: ?i64) []const u8 {
    const secs = unix orelse return "—";
    if (secs < 0) return "—";
    const es = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(secs)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch "—";
}

fn formatDateTime(buf: []u8, unix: ?i64) []const u8 {
    const secs = unix orelse return "—";
    if (secs < 0) return "—";
    const es = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(secs)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch "—";
}

// ---------------------------------------------------------------------------
// tests

const fd_writer = @import("fd_writer.zig");

fn collectPlain(allocator: std.mem.Allocator, report: Report, opts: RenderOptions) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const writer = fd_writer.BufferWriter{ .allocator = allocator, .list = &out };
    try render(writer, report, opts);
    return out;
}

test "groupUsize inserts thousands separators" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", groupUsize(&buf, 0));
    try std.testing.expectEqualStrings("42", groupUsize(&buf, 42));
    try std.testing.expectEqualStrings("1,234", groupUsize(&buf, 1234));
    try std.testing.expectEqualStrings("12,340", groupUsize(&buf, 12340));
    try std.testing.expectEqualStrings("1,000,000", groupUsize(&buf, 1000000));
}

test "formatDay renders a UTC calendar date" {
    var buf: [32]u8 = undefined;
    // 2026-08-02T00:00:00Z = 1785628800
    try std.testing.expectEqualStrings("2026-08-02", formatDay(&buf, 1785628800));
    try std.testing.expectEqualStrings("—", formatDay(&buf, null));
}

test "stats empty report shows a friendly hint and no escapes when monochrome" {
    const alloc = std.testing.allocator;
    var out = try collectPlain(alloc, .{}, .{ .color = false, .columns = 80 });
    defer out.deinit(alloc);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "no activity recorded yet") != null);
}

test "stats overview shows totals and boxes" {
    const alloc = std.testing.allocator;
    var sessions = [_]SessionStat{
        .{ .name = "default", .turns = 30, .tokens_in = 9000, .tokens_out = 6000, .errors = 0 },
        .{ .name = "trabalho", .turns = 12, .tokens_in = 3340, .tokens_out = 2210, .errors = 1 },
    };
    var tools = [_]ToolStat{
        .{ .name = "collect_evidence", .count = 18 },
        .{ .name = "search_session", .count = 9 },
    };
    const report = Report{
        .totals = .{
            .sessions = 2,
            .turns = 42,
            .tokens_in = 12340,
            .tokens_out = 8210,
            .tokens_total = 20550,
            .tool_calls = 27,
            .errors = 1,
            .avg_tokens_per_second = 14.2,
            .first_activity_unix = 1785974400,
            .last_activity_unix = 1785974400,
        },
        .sessions = &sessions,
        .tools = &tools,
    };
    var out = try collectPlain(alloc, report, .{ .color = false, .columns = 80 });
    defer out.deinit(alloc);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "phenom stats") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "all sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "20,550") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "12,340") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "14.2 tok/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "by session") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "trabalho") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "top tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "╭") != null);
}

test "stats filtered to one session hides the multi-session table" {
    const alloc = std.testing.allocator;
    var sessions = [_]SessionStat{
        .{ .name = "trabalho", .turns = 12, .tokens_in = 3340, .tokens_out = 2210, .errors = 0 },
    };
    const report = Report{
        .totals = .{ .sessions = 1, .turns = 12, .tokens_in = 3340, .tokens_out = 2210, .tokens_total = 5550, .errors = 0 },
        .sessions = &sessions,
        .tools = &.{},
    };
    var out = try collectPlain(alloc, report, .{ .color = false, .columns = 80, .session_filter = "trabalho" });
    defer out.deinit(alloc);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "session trabalho") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "by session") == null);
}

test "stats truecolor path emits accent and reset" {
    const alloc = std.testing.allocator;
    const report = Report{
        .totals = .{ .sessions = 1, .turns = 3, .tokens_in = 10, .tokens_out = 5, .tokens_total = 15 },
        .sessions = &.{},
        .tools = &.{},
    };
    var out = try collectPlain(alloc, report, .{ .color = true, .columns = 80 });
    defer out.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, out.items, c_accent) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, reset) != null);
}
