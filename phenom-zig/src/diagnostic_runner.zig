const std = @import("std");

const evidence = @import("evidence.zig");
const tools = @import("tools.zig");

const max_diagnostic_file_bytes: usize = 256 * 1024;
const max_diagnostic_lines: usize = 200_000;

pub const Result = struct {
    entry: evidence.EvidenceEntry,
    audit_text: []u8,
    raw_bytes: usize,
    blocking_count: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        self.entry.deinit(allocator);
        allocator.free(self.audit_text);
    }
};

pub fn run(allocator: std.mem.Allocator, path: []const u8, budget_bytes: usize) !Result {
    if (!std.mem.endsWith(u8, path, ".zig")) return error.UnsupportedDiagnosticLanguage;
    const range = try tools.readFileRange(allocator, path, 1, max_diagnostic_lines, max_diagnostic_file_bytes);
    defer range.deinit(allocator);

    const source_z = try allocator.dupeZ(u8, range.text);
    defer allocator.free(source_z);
    var ast = try std.zig.Ast.parse(allocator, source_z, .zig);
    defer ast.deinit(allocator);

    const excerpt = try renderZigDiagnostics(allocator, ast, path, budget_bytes);
    errdefer allocator.free(excerpt);
    const source = try allocator.dupe(u8, path);
    errdefer allocator.free(source);
    const kind = try allocator.dupe(u8, "diagnostic");
    errdefer allocator.free(kind);
    const entry_range = try allocator.dupe(u8, "L1-*");
    errdefer allocator.free(entry_range);
    const entry = evidence.EvidenceEntry{
        .source = source,
        .kind = kind,
        .range = entry_range,
        .hash = range.hash,
        .excerpt = excerpt,
    };
    errdefer entry.deinit(allocator);

    const audit_text = try std.fmt.allocPrint(
        allocator,
        "[TOOL_EVENT]\ntool=collect_evidence\nsuccess=true\nargs=strategy=diagnostic path={s} parser=zig raw_bytes={} blocking={}\n",
        .{ path, range.text.len, ast.errors.len },
    );
    errdefer allocator.free(audit_text);

    return .{
        .entry = entry,
        .audit_text = audit_text,
        .raw_bytes = range.text.len,
        .blocking_count = ast.errors.len,
    };
}

fn renderZigDiagnostics(allocator: std.mem.Allocator, ast: std.zig.Ast, path: []const u8, budget_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[DIAGNOSTIC]\n");
    if (ast.errors.len == 0) {
        try out.appendSlice(allocator, "severity=info status=ok parser=zig errors=0\n");
    } else {
        for (ast.errors, 0..) |parse_error, i| {
            if (out.items.len >= budget_bytes) break;
            const loc = ast.tokenLocation(0, parse_error.token);
            const message = try renderParseError(allocator, ast, parse_error);
            defer allocator.free(message);
            const line = try std.fmt.allocPrint(
                allocator,
                "{}. severity=blocking path={s} line={} column={} parser=zig message={s}\n",
                .{ i + 1, path, loc.line + 1, loc.column + 1 + ast.errorOffset(parse_error), message },
            );
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
    }
    if (out.items.len > budget_bytes) {
        out.shrinkRetainingCapacity(budget_bytes);
        try out.appendSlice(allocator, "\n[TRUNCATED]\n");
    }
    return out.toOwnedSlice(allocator);
}

fn renderParseError(allocator: std.mem.Allocator, ast: std.zig.Ast, parse_error: std.zig.Ast.Error) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try ast.renderError(parse_error, &writer.writer);
    return writer.toOwnedSlice();
}

test "zig diagnostic reports parse error as blocking evidence" {
    const path = "diagnostic_bad_test.zig";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "pub fn broken( {\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try run(std.testing.allocator, path, 4096);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.blocking_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.entry.excerpt, "severity=blocking") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.entry.excerpt, path) != null);
}

test "zig diagnostic reports clean parse" {
    const path = "diagnostic_good_test.zig";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "pub fn ok() void {}\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try run(std.testing.allocator, path, 4096);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.blocking_count);
    try std.testing.expect(std.mem.indexOf(u8, result.entry.excerpt, "status=ok") != null);
}

test "diagnostic rejects unsupported language explicitly" {
    try std.testing.expectError(error.UnsupportedDiagnosticLanguage, run(std.testing.allocator, "README.md", 4096));
}
