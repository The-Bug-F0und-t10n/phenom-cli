const std = @import("std");
const fd_writer = @import("fd_writer.zig");

pub const RenderOptions = struct {
    color: bool = true,
    user_label: []const u8 = "user",
    terminal_columns: usize = 80,
    max_tool_sample_lines: usize = 20,
    max_diff_lines: usize = 2000,
};

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn AppendOnlyRenderer(comptime Writer: type) type {
    return struct {
        writer: Writer,
        options: RenderOptions,
        assistant_open: bool = false,
        assistant_wrote_content: bool = false,
        suppress_next_block_gap: bool = false,
        thinking_open: bool = false,
        stream_needs_gutter: bool = true,
        thinking_needs_gutter: bool = true,
        thinking_col: usize = 0,
        markdown_pending: [8192]u8 = undefined,
        markdown_pending_len: usize = 0,
        markdown_in_code: bool = false,
        markdown_code_lang: [24]u8 = undefined,
        markdown_code_lang_len: usize = 0,
        markdown_table: [8192]u8 = undefined,
        markdown_table_len: usize = 0,
        markdown_table_rows: usize = 0,
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
        const tone_keyword = Rgb{ .r = 0xa4, .g = 0x8e, .b = 0xc7 };
        const tone_string = Rgb{ .r = 0x7f, .g = 0xa9, .b = 0x8f };
        const tone_number = Rgb{ .r = 0xcf, .g = 0xa0, .b = 0x6e };
        const tone_fn = Rgb{ .r = 0x7a, .g = 0x9c, .b = 0xc6 };
        const tone_type = Rgb{ .r = 0x7f, .g = 0xb2, .b = 0xc9 };
        const tone_comment = Rgb{ .r = 0x5f, .g = 0x6a, .b = 0x72 };
        const tone_text = Rgb{ .r = 0x9a, .g = 0xa6, .b = 0xb2 };
        const tone_preproc = Rgb{ .r = 0xd4, .g = 0xb9, .b = 0x7a };
        const diff_add_bg = Rgb{ .r = 0xed, .g = 0xf8, .b = 0xf0 };
        const diff_add_fg = Rgb{ .r = 0x2f, .g = 0x6f, .b = 0x45 };
        const diff_del_bg = Rgb{ .r = 0xff, .g = 0xf0, .b = 0xf0 };
        const diff_del_fg = Rgb{ .r = 0x8a, .g = 0x30, .b = 0x30 };
        const content_gutter_cols: usize = 1;

        pub fn init(writer: Writer, options: RenderOptions) Self {
            return .{ .writer = writer, .options = options };
        }

        pub fn setTerminalColumns(self: *Self, columns: usize) void {
            self.options.terminal_columns = @max(@as(usize, 1), columns);
        }

        pub fn user(self: *Self, text: []const u8) !void {
            try self.closeOpenBlocks();

            var prefix_buf: [96]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "> [{s}] ", .{self.options.user_label});

            try self.writer.writeAll("\n");
            try self.writeUserBlankLine();
            try self.writer.writeAll("\n");
            try self.writeWrappedUserLine(prefix, text);
            try self.writer.writeAll("\n");
            try self.writeUserBlankLine();
            try self.writer.writeAll("\n\n");
            self.last_block = .user;
        }

        pub fn assistantStart(self: *Self) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.assistant);
            self.assistant_open = true;
            self.assistant_wrote_content = false;
            self.stream_needs_gutter = true;
            self.last_block = .assistant;
        }

        pub fn assistantDelta(self: *Self, text: []const u8) !void {
            if (text.len > 0) self.assistant_wrote_content = true;
            try self.writeMarkdownStream(text);
        }

        pub fn thinkingDelta(self: *Self, text: []const u8) !void {
            if (!self.thinking_open) {
                var wrote_gap = false;
                if (self.assistant_open) {
                    try self.writer.writeAll("\n");
                    self.assistant_open = false;
                    wrote_gap = true;
                }
                if (!wrote_gap and self.last_block != .user) try self.writer.writeAll("\n");
                try self.writeContentGutter();
                try self.writeCyan("│ ");
                try self.writeCyanBold("thinking");
                try self.writer.writeAll("\n");
                self.thinking_open = true;
                self.thinking_needs_gutter = true;
                self.thinking_col = 0;
                self.last_block = .thinking;
            }

            var start: usize = 0;
            while (start < text.len) {
                if (text[start] == '\n') {
                    if (self.thinking_needs_gutter) try self.writeThinkingBlankLine();
                    try self.writeDim("\n");
                    self.thinking_needs_gutter = true;
                    self.thinking_col = 0;
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
                try self.writeWrappedThinkingText(text[start..end]);
                start = end;
            }
        }

        pub fn thinkingEnd(self: *Self) !void {
            if (!self.thinking_open) return;
            if (!self.thinking_needs_gutter) try self.writer.writeAll("\n");
            self.thinking_open = false;
            self.thinking_needs_gutter = true;
            self.thinking_col = 0;
            try self.writer.writeAll("\n");
            self.assistant_open = true;
            self.assistant_wrote_content = false;
            self.suppress_next_block_gap = true;
            self.stream_needs_gutter = true;
            self.last_block = .assistant;
        }

        pub fn toolSample(self: *Self, name: []const u8, sample: []const u8) !void {
            try self.toolSampleWithDetail(name, "", sample);
        }

        pub fn toolSampleWithDetail(self: *Self, name: []const u8, detail: []const u8, sample: []const u8) !void {
            try self.toolStart(name, detail);
            if (sample.len > 0) try self.toolOutput(sample);
        }

        pub fn toolStart(self: *Self, name: []const u8, detail: []const u8) !void {
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
            self.last_block = .tool;
        }

        pub fn toolOutput(self: *Self, sample: []const u8) !void {
            if (self.last_block != .tool) {
                try self.closeOpenBlocks();
                try self.blockGap(.tool);
            }
            try self.writeToolOutput(sample);
            self.last_block = .tool;
        }

        pub fn toolFailure(self: *Self, message: []const u8) !void {
            if (self.last_block != .tool) {
                try self.closeOpenBlocks();
                try self.blockGap(.tool);
            }
            try self.writeContentGutter();
            try self.writeRed("  ✗ ");
            try self.writer.writeAll(firstLine(message));
            try self.writer.writeAll("\n");
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
            try self.doneWithElapsed("0s");
        }

        pub fn doneWithElapsed(self: *Self, elapsed: []const u8) !void {
            try self.closeOpenBlocks();
            try self.blockGap(.done);
            try self.writeWorkedLine(elapsed);
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
                try self.flushMarkdown();
                if (self.assistant_wrote_content) try self.writer.writeAll("\n");
                self.assistant_open = false;
                self.assistant_wrote_content = false;
            }
        }

        fn blockGap(self: *Self, next: BlockKind) !void {
            if (self.suppress_next_block_gap) {
                self.suppress_next_block_gap = false;
                return;
            }
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

        fn writeUserBlankLine(self: *Self) !void {
            try self.writeContentGutter();
            if (self.options.color) try self.writer.writeAll(user_bg ++ user_fg);
            try self.writeSpaces(self.userInnerWidth() + 1);
            if (self.options.color) try self.writer.writeAll(reset);
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

        fn writeMarkdownStream(self: *Self, text: []const u8) !void {
            var start: usize = 0;
            while (start < text.len) {
                const rel = std.mem.indexOfScalar(u8, text[start..], '\n');
                const end = if (rel) |idx| start + idx else text.len;
                const chunk = text[start..end];
                const direct_plain = self.markdown_pending_len == 0 and !self.markdown_in_code and self.markdown_table_rows == 0 and !mayContainMarkdown(chunk);
                if (direct_plain) {
                    try self.writeContentStream(chunk);
                } else {
                    try self.appendMarkdownPending(chunk);
                }
                if (rel == null) break;
                if (direct_plain) {
                    try self.writer.writeAll("\n");
                    self.stream_needs_gutter = true;
                } else {
                    try self.renderMarkdownPending(true);
                }
                start = end + 1;
            }
        }

        fn appendMarkdownPending(self: *Self, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            if (bytes.len > self.markdown_pending.len - self.markdown_pending_len) {
                try self.flushMarkdownTables();
                if (self.markdown_pending_len > 0) {
                    try self.writeMarkdownLine(self.markdown_pending[0..self.markdown_pending_len], true);
                    self.markdown_pending_len = 0;
                }
                try self.writeContentStream(bytes);
                return;
            }
            @memcpy(self.markdown_pending[self.markdown_pending_len .. self.markdown_pending_len + bytes.len], bytes);
            self.markdown_pending_len += bytes.len;
        }

        fn renderMarkdownPending(self: *Self, newline: bool) !void {
            const line = self.markdown_pending[0..self.markdown_pending_len];
            self.markdown_pending_len = 0;
            if (!self.markdown_in_code and isMarkdownTableRow(line)) {
                try self.appendMarkdownTableRow(line);
                return;
            }
            try self.flushMarkdownTables();
            try self.writeMarkdownLine(line, newline);
        }

        fn flushMarkdown(self: *Self) !void {
            if (self.markdown_pending_len > 0) {
                try self.renderMarkdownPending(false);
            }
            try self.flushMarkdownTables();
        }

        fn appendMarkdownTableRow(self: *Self, line: []const u8) !void {
            if (self.markdown_table_len + line.len + 1 > self.markdown_table.len) {
                try self.flushMarkdownTables();
            }
            if (line.len + 1 > self.markdown_table.len - self.markdown_table_len) {
                try self.writeMarkdownLine(line, true);
                return;
            }
            @memcpy(self.markdown_table[self.markdown_table_len .. self.markdown_table_len + line.len], line);
            self.markdown_table_len += line.len;
            self.markdown_table[self.markdown_table_len] = '\n';
            self.markdown_table_len += 1;
            self.markdown_table_rows += 1;
        }

        fn flushMarkdownTables(self: *Self) !void {
            if (self.markdown_table_rows == 0) return;
            try self.writeMarkdownTable(self.markdown_table[0..self.markdown_table_len]);
            self.markdown_table_len = 0;
            self.markdown_table_rows = 0;
        }

        fn writeMarkdownLine(self: *Self, line: []const u8, newline: bool) !void {
            if (isFenceLine(line)) {
                try self.writeFenceLine(line);
                self.setMarkdownFence(line);
            } else if (self.markdown_in_code) {
                try self.writeCodeLine(line);
            } else {
                try self.writeMarkdownProseLine(line);
            }
            if (newline) try self.writer.writeAll("\n");
            self.stream_needs_gutter = true;
        }

        fn setMarkdownFence(self: *Self, line: []const u8) void {
            if (!self.markdown_in_code) {
                self.markdown_in_code = true;
                const lang = fenceLang(line);
                const len = @min(lang.len, self.markdown_code_lang.len);
                if (len > 0) @memcpy(self.markdown_code_lang[0..len], lang[0..len]);
                self.markdown_code_lang_len = len;
            } else {
                self.markdown_in_code = false;
                self.markdown_code_lang_len = 0;
            }
        }

        fn writeCodeLine(self: *Self, line: []const u8) !void {
            const lang = self.markdown_code_lang[0..self.markdown_code_lang_len];
            try self.writeContentGutter();
            if (isDiffLang(lang)) {
                if (std.mem.startsWith(u8, line, "+")) {
                    try self.writeRgbFgBg(diff_add_fg, diff_add_bg, "│ ");
                    try self.writeRgbFgBg(diff_add_fg, diff_add_bg, line);
                } else if (std.mem.startsWith(u8, line, "-")) {
                    try self.writeRgbFgBg(diff_del_fg, diff_del_bg, "│ ");
                    try self.writeRgbFgBg(diff_del_fg, diff_del_bg, line);
                } else if (std.mem.startsWith(u8, line, "@@")) {
                    try self.writeCyan("│ ");
                    try self.writeRgb(tone_fn, line);
                } else if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) {
                    try self.writeDim("│ ");
                    try self.writeRgb(tone_preproc, line);
                } else {
                    try self.writeDim("│ ");
                    try self.writeRgb(tone_text, line);
                }
                return;
            }
            try self.writeCyanDim("│ ");
            try self.writeHighlightedCode(line, lang);
        }

        fn writeFenceLine(self: *Self, line: []const u8) !void {
            const lang = fenceLang(line);
            const outgoing = self.markdown_code_lang[0..self.markdown_code_lang_len];
            const active_lang = if (!self.markdown_in_code) lang else outgoing;
            try self.writeContentGutter();
            if (isDiffLang(active_lang)) {
                try self.writeCyan("│ ");
            } else {
                try self.writeCyanDim("│ ");
            }
            const ticks_len = fenceTicksLen(line);
            try self.writeRgb(tone_preproc, line[0..ticks_len]);
            if (lang.len > 0) {
                const lang_start = fenceLangStart(line);
                if (ticks_len < lang_start) try self.writeRgb(tone_text, line[ticks_len..lang_start]);
                try self.writeRgb(tone_fn, lang);
                const rest_start = lang_start + lang.len;
                if (rest_start < line.len) try self.writeRgb(tone_text, line[rest_start..]);
            } else if (ticks_len < line.len) {
                try self.writeRgb(tone_text, line[ticks_len..]);
            }
        }

        fn writeMarkdownProseLine(self: *Self, line: []const u8) !void {
            const trimmed = trimLeft(line, " \t");
            const indent_len = line.len - trimmed.len;
            try self.writeContentGutter();
            if (line.len == 0) return;
            try self.writer.writeAll(line[0..indent_len]);
            if (headingLevel(trimmed) > 0) {
                try self.writeCyanBold(trimmed);
            } else if (isHorizontalRule(trimmed)) {
                try self.writeDim("────────────────────────────────────────────────");
            } else if (std.mem.startsWith(u8, trimmed, ">")) {
                try self.writeDim("│ ");
                const body = trimLeft(trimmed[1..], " ");
                try self.writeInlineMarkdown(body);
            } else if (unorderedBullet(trimmed)) |body| {
                try self.writeCyan("• ");
                try self.writeInlineMarkdown(body);
            } else if (orderedBullet(trimmed)) |parts| {
                try self.writeCyan(parts.marker);
                try self.writer.writeAll(" ");
                try self.writeInlineMarkdown(parts.body);
            } else if (isLooseDiffLine(trimmed)) {
                if (trimmed[0] == '+') try self.writeGreen(trimmed) else try self.writeRed(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "@@")) {
                try self.writeCyan(trimmed);
            } else {
                try self.writeInlineMarkdown(trimmed);
            }
        }

        fn writeMarkdownTable(self: *Self, table: []const u8) !void {
            var widths = [_]usize{0} ** 8;
            var col_count: usize = 0;
            var start: usize = 0;
            while (nextLine(table, &start)) |line| {
                if (isTableSeparator(line)) continue;
                var it = CellIterator.init(line);
                var col: usize = 0;
                while (it.next()) |cell| : (col += 1) {
                    if (col >= widths.len) break;
                    widths[col] = @max(widths[col], visibleMarkdownWidth(cell));
                }
                col_count = @max(col_count, col);
            }
            if (col_count == 0) return;
            try self.writeTableBorder("┌", "┬", "┐", widths[0..col_count]);
            start = 0;
            var row_index: usize = 0;
            while (nextLine(table, &start)) |line| {
                if (isTableSeparator(line)) continue;
                try self.writeContentGutter();
                try self.writeCyan("│ ");
                var it = CellIterator.init(line);
                var col: usize = 0;
                while (col < col_count) : (col += 1) {
                    const cell = if (it.next()) |value| value else "";
                    if (row_index == 0) try self.writeBoldInlineMarkdown(cell) else try self.writeInlineMarkdown(cell);
                    const width = visibleMarkdownWidth(cell);
                    if (width < widths[col]) try self.writeSpaces(widths[col] - width);
                    try self.writeCyan(" │ ");
                }
                try self.writer.writeAll("\n");
                if (row_index == 0) try self.writeTableBorder("├", "┼", "┤", widths[0..col_count]);
                row_index += 1;
            }
            try self.writeTableBorder("└", "┴", "┘", widths[0..col_count]);
        }

        fn writeTableBorder(self: *Self, left: []const u8, mid: []const u8, right: []const u8, widths: []const usize) !void {
            try self.writeContentGutter();
            try self.writeCyan(left);
            for (widths, 0..) |width, i| {
                var j: usize = 0;
                while (j < width + 2) : (j += 1) try self.writeCyan("─");
                if (i + 1 < widths.len) try self.writeCyan(mid);
            }
            try self.writeCyan(right);
            try self.writer.writeAll("\n");
        }

        fn writeBoldInlineMarkdown(self: *Self, text: []const u8) anyerror!void {
            if (self.options.color) try self.writer.writeAll("\x1b[1m");
            try self.writeInlineMarkdown(text);
            if (self.options.color) try self.writer.writeAll(reset);
        }

        fn writeInlineMarkdown(self: *Self, text: []const u8) anyerror!void {
            var i: usize = 0;
            while (i < text.len) {
                if (startsWithAt(text, i, "**")) {
                    if (std.mem.indexOf(u8, text[i + 2 ..], "**")) |rel| {
                        try self.writeBoldInlineMarkdown(text[i + 2 .. i + 2 + rel]);
                        i += rel + 4;
                        continue;
                    }
                }
                if (text[i] == '`') {
                    if (std.mem.indexOfScalar(u8, text[i + 1 ..], '`')) |rel| {
                        try self.writeYellowBold(text[i + 1 .. i + 1 + rel]);
                        i += rel + 2;
                        continue;
                    }
                }
                if (text[i] == '[') {
                    if (std.mem.indexOf(u8, text[i..], "](")) |mid_rel| {
                        const url_start = i + mid_rel + 2;
                        if (std.mem.indexOfScalar(u8, text[url_start..], ')')) |end_rel| {
                            try self.writeCyan(text[i + 1 .. i + mid_rel]);
                            try self.writeDim(" (");
                            try self.writeDim(text[url_start .. url_start + end_rel]);
                            try self.writeDim(")");
                            i = url_start + end_rel + 1;
                            continue;
                        }
                    }
                }
                const len = utf8ByteLen(text[i]);
                try self.writer.writeAll(text[i..@min(text.len, i + len)]);
                i += len;
            }
        }

        fn writeHighlightedCode(self: *Self, line: []const u8, lang: []const u8) !void {
            var i: usize = 0;
            while (i < line.len) {
                if (line[i] == '"' or line[i] == '\'' or line[i] == '`') {
                    const quote = line[i];
                    var end = i + 1;
                    while (end < line.len) : (end += 1) {
                        if (line[end] == quote and line[end - 1] != '\\') {
                            end += 1;
                            break;
                        }
                    }
                    try self.writeRgb(tone_string, line[i..@min(end, line.len)]);
                    i = @min(end, line.len);
                    continue;
                }
                if (std.mem.startsWith(u8, line[i..], "//") or std.mem.startsWith(u8, line[i..], "--") or line[i] == '#') {
                    try self.writeRgb(tone_comment, line[i..]);
                    break;
                }
                if (isIdentStart(line[i])) {
                    var end = i + 1;
                    while (end < line.len and isIdent(line[end])) : (end += 1) {}
                    const word = line[i..end];
                    if (isCodeKeyword(word, lang)) {
                        try self.writeRgb(tone_keyword, word);
                    } else if (isTypeToken(word)) {
                        try self.writeRgb(tone_type, word);
                    } else if (end < line.len and line[end] == '(') {
                        try self.writeRgb(tone_fn, word);
                    } else {
                        try self.writeRgb(tone_text, word);
                    }
                    i = end;
                    continue;
                }
                if (line[i] >= '0' and line[i] <= '9') {
                    var end = i + 1;
                    while (end < line.len and ((line[end] >= '0' and line[end] <= '9') or line[end] == '.')) : (end += 1) {}
                    try self.writeRgb(tone_number, line[i..end]);
                    i = end;
                    continue;
                }
                const len = utf8ByteLen(line[i]);
                try self.writeRgb(tone_text, line[i..@min(line.len, i + len)]);
                i += len;
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

        fn writeWrappedThinkingText(self: *Self, text: []const u8) !void {
            const width = self.thinkingTextWidth();
            var start: usize = 0;
            while (start < text.len) {
                if (self.thinking_col >= width) {
                    try self.writeDim("\n");
                    self.thinking_needs_gutter = true;
                    self.thinking_col = 0;
                }
                if (self.thinking_needs_gutter) {
                    try self.writeContentGutter();
                    try self.writeCyan("│ ");
                    self.thinking_needs_gutter = false;
                }
                const remaining_cols = width - self.thinking_col;
                var end = start;
                var cols: usize = 0;
                while (end < text.len and cols < remaining_cols) : (cols += 1) {
                    end = @min(text.len, end + utf8ByteLen(text[end]));
                }
                try self.writeDim(text[start..end]);
                self.thinking_col += cols;
                start = end;
            }
        }

        fn writeThinkingBlankLine(self: *Self) !void {
            try self.writeContentGutter();
            try self.writeCyan("│");
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

        fn writeWorkedLine(self: *Self, elapsed: []const u8) !void {
            const paint_cols = self.paintCols();
            var prefix_buf: [96]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "─ Worked for {s} ", .{elapsed});
            const shown_cols = try self.writeDimColumns(prefix, paint_cols);
            var i: usize = shown_cols;
            while (i < paint_cols) : (i += 1) try self.writeDim("─");
        }

        fn writeDimColumns(self: *Self, text: []const u8, max_cols: usize) !usize {
            var cols: usize = 0;
            var i: usize = 0;
            while (i < text.len and cols < max_cols) {
                const len = utf8ByteLen(text[i]);
                const end = @min(text.len, i + len);
                try self.writeDim(text[i..end]);
                i = end;
                cols += 1;
            }
            return cols;
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

        fn thinkingTextWidth(self: *Self) usize {
            return @max(@as(usize, 1), self.contentWrapWidth() -| 2);
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

        fn writeRgb(self: *Self, rgb: Rgb, text: []const u8) !void {
            if (!self.options.color) {
                try self.writer.writeAll(text);
                return;
            }
            try self.writer.print("\x1b[38;2;{};{};{}m{s}\x1b[0m", .{ rgb.r, rgb.g, rgb.b, text });
        }

        fn writeRgbBg(self: *Self, bg: Rgb, text: []const u8) !void {
            if (!self.options.color) {
                try self.writer.writeAll(text);
                return;
            }
            try self.writer.print("\x1b[48;2;{};{};{}m{s}\x1b[0m", .{ bg.r, bg.g, bg.b, text });
        }

        fn writeRgbFgBg(self: *Self, fg: Rgb, bg: Rgb, text: []const u8) !void {
            if (!self.options.color) {
                try self.writer.writeAll(text);
                return;
            }
            try self.writer.print("\x1b[38;2;{};{};{};48;2;{};{};{}m{s}\x1b[0m", .{ fg.r, fg.g, fg.b, bg.r, bg.g, bg.b, text });
        }

        fn writeCyan(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[36m", text);
        }

        fn writeCyanDim(self: *Self, text: []const u8) !void {
            try self.writeAnsi("\x1b[36;2m", text);
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

fn utf8ByteLen(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
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

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..@min(end, 200)];
}

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        count += 1;
        start += idx + needle.len;
    }
    return count;
}

fn isFenceLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```");
}

fn fenceLang(line: []const u8) []const u8 {
    if (!isFenceLine(line)) return "";
    const start = fenceLangStart(line);
    var i = start;
    while (i < line.len and isIdent(line[i])) : (i += 1) {}
    return line[start..i];
}

fn fenceTicksLen(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == '`') : (i += 1) {}
    return i;
}

fn fenceLangStart(line: []const u8) usize {
    var i = fenceTicksLen(line);
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn isDiffLang(lang: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lang, "diff") or std.ascii.eqlIgnoreCase(lang, "patch");
}

fn headingLevel(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    if (i == 0 or i > 6 or i >= line.len or line[i] != ' ') return 0;
    return i;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |c| {
        if (c != ch and c != ' ' and c != '\t') return false;
    }
    return true;
}

fn unorderedBullet(line: []const u8) ?[]const u8 {
    if (line.len < 3) return null;
    if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and (line[1] == ' ' or line[1] == '\t')) {
        return trimLeft(line[2..], " \t");
    }
    return null;
}

const OrderedBullet = struct {
    marker: []const u8,
    body: []const u8,
};

fn orderedBullet(line: []const u8) ?OrderedBullet {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0 or i + 1 >= line.len or line[i] != '.' or (line[i + 1] != ' ' and line[i + 1] != '\t')) return null;
    return .{ .marker = line[0 .. i + 1], .body = trimLeft(line[i + 2 ..], " \t") };
}

fn trimLeft(text: []const u8, strip: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and std.mem.indexOfScalar(u8, strip, text[i]) != null) : (i += 1) {}
    return text[i..];
}

fn isLooseDiffLine(line: []const u8) bool {
    return line.len > 1 and (line[0] == '+' or line[0] == '-') and line[1] != ' ' and line[1] != '\t' and !std.mem.startsWith(u8, line, "---");
}

fn startsWithAt(text: []const u8, index: usize, needle: []const u8) bool {
    return index <= text.len and text.len - index >= needle.len and std.mem.eql(u8, text[index .. index + needle.len], needle);
}

fn mayContainMarkdown(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "#`*_[]>|+-@") != null;
}

fn visibleMarkdownWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (startsWithAt(text, i, "**")) {
            i += 2;
            continue;
        }
        if (text[i] == '`' or text[i] == '*' or text[i] == '_') {
            i += 1;
            continue;
        }
        const len = utf8ByteLen(text[i]);
        i += len;
        width += 1;
    }
    return width;
}

fn nextLine(text: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= text.len) return null;
    const start = cursor.*;
    const rel = std.mem.indexOfScalar(u8, text[start..], '\n');
    const end = if (rel) |idx| start + idx else text.len;
    cursor.* = if (rel == null) text.len else end + 1;
    return text[start..end];
}

fn isTableSeparator(line: []const u8) bool {
    var saw_dash = false;
    for (line) |ch| {
        switch (ch) {
            '|', ':', ' ', '\t' => {},
            '-' => saw_dash = true,
            else => return false,
        }
    }
    return saw_dash;
}

fn isMarkdownTableRow(line: []const u8) bool {
    if (isFenceLine(line)) return false;
    var in_code = false;
    var pipes: usize = 0;
    for (line) |ch| {
        if (ch == '`') in_code = !in_code;
        if (ch == '|' and !in_code) pipes += 1;
    }
    return pipes > 0;
}

const CellIterator = struct {
    line: []const u8,
    pos: usize = 0,
    end: usize = 0,

    fn init(line: []const u8) CellIterator {
        var start: usize = 0;
        var end = line.len;
        while (start < end and (line[start] == ' ' or line[start] == '\t' or line[start] == '|')) : (start += 1) {}
        while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '|')) : (end -= 1) {}
        return .{ .line = line, .pos = start, .end = end };
    }

    fn next(self: *CellIterator) ?[]const u8 {
        if (self.pos > self.end or self.pos == self.end) return null;
        const start = self.pos;
        var end = start;
        while (end < self.end and self.line[end] != '|') : (end += 1) {}
        self.pos = if (end < self.end) end + 1 else self.end;
        return std.mem.trim(u8, self.line[start..end], " \t");
    }
};

fn isIdentStart(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_';
}

fn isIdent(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9') or ch == '$' or ch == '-';
}

fn isTypeToken(word: []const u8) bool {
    return word.len > 0 and word[0] >= 'A' and word[0] <= 'Z';
}

fn isCodeKeyword(word: []const u8, lang: []const u8) bool {
    const common = [_][]const u8{
        "const", "let", "var", "fn", "pub", "return", "if", "else", "for", "while", "switch", "case", "break", "continue",
        "try", "catch", "defer", "async", "await", "class", "struct", "enum", "interface", "type", "import", "export",
        "from", "as", "def", "lambda", "yield", "local", "function", "end", "then", "do", "select", "insert", "update",
        "delete", "where", "join", "create", "table",
    };
    _ = lang;
    for (common) |item| {
        if (std.ascii.eqlIgnoreCase(word, item)) return true;
    }
    return false;
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

test "thinking blank lines stay inside guttered component" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.thinkingDelta("primeiro\n\nsegundo\n\nterceiro");
    try renderer.thinkingEnd();
    try renderer.assistantDelta("final");

    const expected =
        \\
        \\ │ thinking
        \\ │ primeiro
        \\ │
        \\ │ segundo
        \\ │
        \\ │ terceiro
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

test "thinking wraps inside narrow terminal with gutter on continuation" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 12 });
    try renderer.thinkingDelta("abcdefghi");
    try renderer.thinkingEnd();
    try renderer.assistantDelta("final");

    const expected =
        \\
        \\ │ thinking
        \\ │ abcdefgh
        \\ │ i
        \\
        \\ final
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
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

    const expected = "\n                 \n > [user] ola    \n                 \n\n ok\n\n─ Worked for 0s ─\n";
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
        \\─ Worked for 0s ───────────────────────────────────────────────────────────────
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

test "tool start announcement does not fake empty result" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.toolStart("read_file_range", "README.md");

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Reading: README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "no output") == null);
}

test "tool lifecycle appends result without duplicating announcement" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.toolStart("run_code", "zig build test");
    try renderer.toolOutput("$ zig build test    [cwd=. exit 0 3ms]\nok\n");

    const expected =
        \\ ▸ Running: zig build test
        \\     │ $ zig build test    [cwd=. exit 0 3ms]
        \\     │ ok
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(buffer.items, "▸ Running"));
}

test "tool failure renders codex style failure line" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.toolStart("run_code", "zig build test");
    try renderer.toolFailure("compile failed\nfull trace");

    const expected =
        \\ ▸ Running: zig build test
        \\   ✗ compile failed
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

test "ansi diff colors markers without saturated backgrounds" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true, .max_diff_lines = 4 });
    try renderer.diff("src/app.zig", "patched", "@@ -1 +1 @@\n-old value\n+new value\n context\n");

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[41") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[42") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[31m  - │ \x1b[0mold value") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[32m  + │ \x1b[0mnew value") != null);
}

test "codex style append only turn snapshot covers core blocks" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 42, .max_tool_sample_lines = 2, .max_diff_lines = 3 });
    try renderer.user("corrija o bug");
    try renderer.thinkingDelta("vou inspecionar\n\naplicar patch");
    try renderer.thinkingEnd();
    try renderer.toolStart("run_code", "zig build test");
    try renderer.toolOutput("$ zig build test\nok\n");
    try renderer.diff("src/app.zig", "patched", "@@ -1 +1 @@\n-old\n+new\n context\n");
    try renderer.assistantStart();
    try renderer.assistantDelta("Corrigido.");
    try renderer.done();

    const expected =
        "\n" ++
        "                                         \n" ++
        " > [user] corrija o bug                  \n" ++
        "                                         \n" ++
        "\n" ++
        " │ thinking\n" ++
        " │ vou inspecionar\n" ++
        " │\n" ++
        " │ aplicar patch\n" ++
        "\n" ++
        " ▸ Running: zig build test\n" ++
        "     │ $ zig build test\n" ++
        "     │ ok\n" ++
        "\n" ++
        "   ◆ src/app.zig (patched)\n" ++
        "   @@ -1 +1 @@\n" ++
        "   - │ old\n" ++
        "   + │ new\n" ++
        "   ... 1 more line hidden from preview\n" ++
        "\n" ++
        " Corrigido.\n" ++
        "\n" ++
        "─ Worked for 0s ─────────────────────────\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "ansi user bubble uses same palette constants as phenom cli ts" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true, .terminal_columns = 16 });
    try renderer.user("ola");

    const expected = "\n \x1b[48;5;236m\x1b[38;5;252m              \x1b[0m\n \x1b[48;5;236m\x1b[38;5;252m> [user] ola  \x1b[0m\n \x1b[48;5;236m\x1b[38;5;252m              \x1b[0m\n\n";
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

test "assistant markdown renders code agent structure" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false, .terminal_columns = 80 });
    try renderer.assistantStart();
    try renderer.assistantDelta(
        \\# Plano
        \\- Corrigir `render.zig`
        \\1. Rodar [testes](zig-build-test)
        \\
        \\```zig
        \\const ok = true;
        \\try run();
        \\```
    );
    try renderer.doneWithElapsed("1s");

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " # Plano") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " • Corrigir render.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "1. Rodar testes (zig-build-test)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ ```zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ const ok = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ try run();") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ ```") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "─ Worked for 1s") != null);
}

test "assistant markdown renders diff fences without saturated backgrounds" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true });
    try renderer.assistantStart();
    try renderer.assistantDelta(
        \\```diff
        \\@@ -1,2 +1,2 @@
        \\-old
        \\+new
        \\ context
        \\```
    );
    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[41") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[42") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "@@ -1,2 +1,2 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "+new") != null);
}

test "assistant markdown buffers and renders tables as boxed output" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.assistantDelta(
        \\| Arquivo | Estado |
        \\| --- | --- |
        \\| src/render.zig | ok |
        \\Depois
    );
    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " ┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ Arquivo") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ src/render.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " └") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " Depois") != null);
}

test "assistant markdown split stream keeps incomplete markdown until flush" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.assistantDelta("Antes ");
    try renderer.assistantDelta("**ne");
    try renderer.assistantDelta("grito** e `co");
    try renderer.assistantDelta("de`");

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Antes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "**ne") == null);

    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "negrito e code") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "**negrito**") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "`code`") == null);
}

test "assistant markdown plain newline does not add phantom gutter" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.assistantDelta("primeira\nsegunda");
    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "primeira \n") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " primeira\n segunda\n") != null);
}

test "assistant markdown code uses phenom cli ts 24 bit syntax palette" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true });
    try renderer.assistantStart();
    try renderer.assistantDelta(
        \\```ts
        \\const value = "ok";
        \\run(value);
        \\```
    );
    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;212;185;122m```") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;122;156;198mts") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;164;142;199mconst") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;127;169;143m\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;122;156;198mrun") != null);
}

test "assistant markdown diff uses readable codex style foreground and background" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = true });
    try renderer.assistantStart();
    try renderer.assistantDelta(
        \\```diff
        \\--- a/file.zig
        \\+++ b/file.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\```
    );
    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;47;111;69;48;2;237;248;240m+new") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;138;48;48;48;2;255;240;240m-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;47;111;69;48;2;237;248;240m│ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[38;2;138;48;48;48;2;255;240;240m│ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[41") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[42") == null);
}

test "assistant markdown spaced fence language renders once" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };
    var renderer = AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.assistantStart();
    try renderer.assistantDelta(
        \\``` ts
        \\const ok = true;
        \\```
    );
    try renderer.done();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ ``` ts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "tss") == null);
}
