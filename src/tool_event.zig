const std = @import("std");

const evidence = @import("evidence.zig");
const tools = @import("tools.zig");

pub const ToolEvent = struct {
    tool_name: []const u8,
    args_summary: []const u8,
    success: bool,
    path: []const u8,
    start_line: usize,
    end_line: usize,
    raw_output: []const u8,
    raw_hash: u64,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: ToolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.args_summary);
        allocator.free(self.path);
        allocator.free(self.raw_output);
        if (self.error_message) |message| allocator.free(message);
    }

    pub fn fromFileRange(
        allocator: std.mem.Allocator,
        tool_name: []const u8,
        args_summary: []const u8,
        range: tools.FileRange,
    ) !ToolEvent {
        const owned_tool_name = try allocator.dupe(u8, tool_name);
        errdefer allocator.free(owned_tool_name);
        const owned_args = try allocator.dupe(u8, args_summary);
        errdefer allocator.free(owned_args);
        const owned_path = try allocator.dupe(u8, range.path);
        errdefer allocator.free(owned_path);
        const raw_output = try allocator.dupe(u8, range.text);
        errdefer allocator.free(raw_output);

        return .{
            .tool_name = owned_tool_name,
            .args_summary = owned_args,
            .success = true,
            .path = owned_path,
            .start_line = range.start_line,
            .end_line = range.end_line,
            .raw_output = raw_output,
            .raw_hash = std.hash.Wyhash.hash(0, range.text),
        };
    }

    pub fn toEvidenceEntryBudgeted(self: ToolEvent, allocator: std.mem.Allocator, max_excerpt_bytes: usize) !evidence.EvidenceEntry {
        const range = tools.FileRange{
            .path = try allocator.dupe(u8, self.path),
            .start_line = self.start_line,
            .end_line = self.end_line,
            .total_lines = self.end_line - self.start_line + 1,
            .hash = self.raw_hash,
            .text = try allocator.dupe(u8, self.raw_output),
        };
        defer range.deinit(allocator);
        return evidence.fromFileRangeBudgeted(allocator, range, max_excerpt_bytes);
    }

    pub fn renderAuditSummary(self: ToolEvent, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "[TOOL_EVENT]\ntool={s}\nsuccess={}\nargs={s}\npath={s}\nlines={}-{}\nraw_bytes={}\nraw_hash={x}\nerror={s}\n",
            .{
                self.tool_name,
                self.success,
                self.args_summary,
                self.path,
                self.start_line,
                self.end_line,
                self.raw_output.len,
                self.raw_hash,
                self.error_message orelse "",
            },
        );
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(ToolEvent),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .events = std.ArrayList(ToolEvent).empty };
    }

    pub fn deinit(self: *Store) void {
        for (self.events.items) |event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn append(self: *Store, event: ToolEvent) !void {
        errdefer event.deinit(self.allocator);
        try self.events.append(self.allocator, event);
    }
};

test "tool event owns raw output while audit summary keeps only metadata" {
    const range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "README.md"),
        .start_line = 1,
        .end_line = 2,
        .total_lines = 2,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "alpha\nSECRET_RAW_TAIL\n"),
    };
    defer range.deinit(std.testing.allocator);

    const event = try ToolEvent.fromFileRange(std.testing.allocator, "collect_evidence", "strategy=path", range);
    defer event.deinit(std.testing.allocator);
    const audit = try event.renderAuditSummary(std.testing.allocator);
    defer std.testing.allocator.free(audit);

    try std.testing.expect(std.mem.indexOf(u8, event.raw_output, "SECRET_RAW_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "raw_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "raw_hash=") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "SECRET_RAW_TAIL") == null);
}

test "tool event distills raw output into budgeted evidence" {
    const range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "README.md"),
        .start_line = 1,
        .end_line = 2,
        .total_lines = 2,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "visible\nSECRET_RAW_TAIL\n"),
    };
    defer range.deinit(std.testing.allocator);

    const event = try ToolEvent.fromFileRange(std.testing.allocator, "collect_evidence", "strategy=path", range);
    defer event.deinit(std.testing.allocator);
    const entry = try event.toEvidenceEntryBudgeted(std.testing.allocator, "visible\n".len);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, entry.excerpt, "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.excerpt, "SECRET_RAW_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry.excerpt, "[TRUNCATED]") != null);
}

test "tool event store owns appended raw events" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const range = tools.FileRange{
        .path = try std.testing.allocator.dupe(u8, "README.md"),
        .start_line = 1,
        .end_line = 1,
        .total_lines = 1,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "raw\n"),
    };
    defer range.deinit(std.testing.allocator);

    try store.append(try ToolEvent.fromFileRange(std.testing.allocator, "collect_evidence", "strategy=path", range));

    try std.testing.expectEqual(@as(usize, 1), store.events.items.len);
    try std.testing.expectEqualStrings("raw\n", store.events.items[0].raw_output);
}
