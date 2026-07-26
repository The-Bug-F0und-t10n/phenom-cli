const std = @import("std");

// Welcome banner shown once at the top of an interactive `phenom chat` session.
//
// It is intentionally allocator-free and libc-free: it formats into stack
// buffers and writes to an `anytype` writer using plain `\n` line endings.
// The caller wraps the target writer in `fd_writer.NewlineWriter{ .crlf = true }`
// so the bytes land correctly inside the raw-mode scroll region; tests drive it
// with a plain buffer writer.

const logo = [3][]const u8{
    "┏━┓╻ ╻┏━╸┏┓╻┏━┓┏┳┓",
    "┣━┛┣━┫┣╸ ┃┗┫┃ ┃┃┃┃",
    "╹  ╹ ╹┗━╸╹ ╹┗━┛╹ ╹",
};

const tagline = "agente local · tool loop auditável";
const logo_gap = "   ";

const reset = "\x1b[0m";
const c_dim = "\x1b[2m";
const c_bold = "\x1b[1m";
const c_accent = "\x1b[38;2;127;178;201m"; // soft cyan, echoes the status/tool tones
const c_violet = "\x1b[38;2;164;142;199m"; // soft violet, echoes markdown keyword tone

const Style = enum { plain, dim, accent, accent_bold, violet };

fn styleCode(style: Style) []const u8 {
    return switch (style) {
        .plain => "",
        .dim => c_dim,
        .accent => c_accent,
        .accent_bold => c_bold ++ c_accent,
        .violet => c_violet,
    };
}

const Seg = struct { text: []const u8, style: Style };

pub const Info = struct {
    version: []const u8 = "dev",
    session: []const u8 = "default",
    model: []const u8 = "",
    backend: []const u8 = "",
    host: []const u8 = "",
    cwd: []const u8 = "",
    offline: bool = false,
    color: bool = true,
    columns: usize = 80,
};

pub fn render(writer: anytype, info: Info) !void {
    var model_buf: [256]u8 = undefined;
    const model_line: []const u8 = if (info.offline)
        "offline · stub local"
    else
        std.fmt.bufPrint(&model_buf, "{s}  ·  {s}@{s}", .{ info.model, info.backend, info.host }) catch info.model;

    var version_buf: [48]u8 = undefined;
    const version_line = std.fmt.bufPrint(&version_buf, "v{s}", .{info.version}) catch info.version;

    const info_rows = [_][]const Seg{
        &.{ .{ .text = "sessão  ", .style = .dim }, .{ .text = info.session, .style = .plain } },
        &.{ .{ .text = "modelo  ", .style = .dim }, .{ .text = model_line, .style = .plain } },
        &.{ .{ .text = "cwd     ", .style = .dim }, .{ .text = info.cwd, .style = .plain } },
    };
    const cmd_row = [_]Seg{
        .{ .text = "/help", .style = .violet },  .{ .text = "  comandos    ", .style = .dim },
        .{ .text = "/reset", .style = .violet }, .{ .text = "  limpa    ", .style = .dim },
        .{ .text = "/exit", .style = .violet },  .{ .text = "  sair", .style = .dim },
    };

    // Box interior width = widest content row + 2 left pad + 2 right pad,
    // clamped to the terminal so the border never wraps.
    var content_w: usize = rowWidth(&cmd_row);
    for (info_rows) |r| content_w = @max(content_w, rowWidth(r));
    var inner = content_w + 4;
    const max_inner = if (info.columns > 6) info.columns - 3 else 12;
    if (inner > max_inner) inner = max_inner;
    if (inner < 24) inner = 24;

    // --- logo + wordmark ---
    try writer.writeAll("\n");
    try writeIndent(writer);
    try writeStyled(writer, info.color, .accent, logo[0]);
    try writer.writeAll("\n");

    try writeIndent(writer);
    try writeStyled(writer, info.color, .accent, logo[1]);
    try writer.writeAll(logo_gap);
    try writeStyled(writer, info.color, .accent_bold, "phenom");
    try writer.writeAll("  ");
    try writeStyled(writer, info.color, .dim, version_line);
    try writer.writeAll("\n");

    try writeIndent(writer);
    try writeStyled(writer, info.color, .accent, logo[2]);
    try writer.writeAll(logo_gap);
    try writeStyled(writer, info.color, .dim, tagline);
    try writer.writeAll("\n\n");

    // --- info + command box ---
    try boxLine(writer, info.color, .top, inner);
    for (info_rows) |r| try boxRow(writer, info.color, r, inner);
    try boxLine(writer, info.color, .mid, inner);
    try boxRow(writer, info.color, &cmd_row, inner);
    try boxLine(writer, info.color, .bottom, inner);
    try writer.writeAll("\n");
}

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

fn boxRow(writer: anytype, color: bool, segs: []const Seg, inner: usize) !void {
    try writer.writeAll(" ");
    try writeStyled(writer, color, .dim, "│");
    var w: usize = 0;
    try writer.writeAll("  ");
    w += 2;
    for (segs) |seg| {
        const dw = displayWidth(seg.text);
        if (w + dw > inner) break; // defensive: never overflow a clamped box
        try writeStyled(writer, color, seg.style, seg.text);
        w += dw;
    }
    while (w < inner) : (w += 1) try writer.writeAll(" ");
    try writeStyled(writer, color, .dim, "│");
    try writer.writeAll("\n");
}

fn writeIndent(writer: anytype) !void {
    try writer.writeAll("  ");
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

fn rowWidth(segs: []const Seg) usize {
    var w: usize = 0;
    for (segs) |seg| w += displayWidth(seg.text);
    return w;
}

fn displayWidth(bytes: []const u8) usize {
    var cols: usize = 0;
    for (bytes) |b| {
        if ((b & 0b1100_0000) != 0b1000_0000) cols += 1;
    }
    return cols;
}

const fd_writer = @import("fd_writer.zig");

fn collectPlain(allocator: std.mem.Allocator, info: Info) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const writer = fd_writer.BufferWriter{ .allocator = allocator, .list = &out };
    try render(writer, info);
    return out;
}

test "welcome banner monochrome has no escape codes and shows key fields" {
    const alloc = std.testing.allocator;
    var out = try collectPlain(alloc, .{
        .version = "0.2.0-dev",
        .session = "dev",
        .model = "llama3.2",
        .backend = "ollama",
        .host = "127.0.0.1:11434",
        .cwd = "~/Projects/phenom-cli",
        .color = false,
        .columns = 80,
    });
    defer out.deinit(alloc);

    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "phenom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "v0.2.0-dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "sessão") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "ollama@127.0.0.1:11434") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "╯") != null);
}

test "welcome banner emits truecolor accent when color enabled" {
    const alloc = std.testing.allocator;
    var out = try collectPlain(alloc, .{
        .version = "0.2.0-dev",
        .session = "dev",
        .model = "llama3.2",
        .backend = "ollama",
        .host = "127.0.0.1:11434",
        .cwd = "/tmp",
        .color = true,
        .columns = 80,
    });
    defer out.deinit(alloc);

    try std.testing.expect(std.mem.indexOf(u8, out.items, c_accent) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, reset) != null);
}

test "welcome banner box borders align to a single width" {
    const alloc = std.testing.allocator;
    var out = try collectPlain(alloc, .{
        .version = "0.2.0-dev",
        .session = "trabalho",
        .model = "local",
        .backend = "llamacpp",
        .host = "127.0.0.1:8080",
        .cwd = "/home/dev/x",
        .color = false,
        .columns = 80,
    });
    defer out.deinit(alloc);

    // Every box row (starts with " │" or a corner) must share one display width.
    var it = std.mem.splitScalar(u8, out.items, '\n');
    var box_width: ?usize = null;
    while (it.next()) |line| {
        // Box rows carry no trailing padding (they end at the │ border or a
        // corner), so the raw line width is the border width.
        if (line.len == 0) continue;
        const is_box = std.mem.startsWith(u8, line, " ╭") or
            std.mem.startsWith(u8, line, " │") or
            std.mem.startsWith(u8, line, " ├") or
            std.mem.startsWith(u8, line, " ╰");
        if (!is_box) continue;
        const w = displayWidth(line);
        if (box_width) |expected| {
            try std.testing.expectEqual(expected, w);
        } else {
            box_width = w;
        }
    }
    try std.testing.expect(box_width != null);
}

test "welcome banner offline shows stub label" {
    const alloc = std.testing.allocator;
    var out = try collectPlain(alloc, .{
        .version = "0.2.0-dev",
        .session = "dev",
        .offline = true,
        .color = false,
        .columns = 80,
    });
    defer out.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "offline") != null);
}
