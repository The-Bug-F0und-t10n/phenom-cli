const std = @import("std");

const http = @import("http.zig");

pub const Result = struct {
    target: []u8,
    evidence_text: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.evidence_text);
    }
};

pub fn execute(allocator: std.mem.Allocator, backend_host: []const u8, requested: ?[]const u8) !Result {
    const owned_target = try target(allocator, backend_host, requested);
    errdefer allocator.free(owned_target);
    const inspected = http.inspectHttpGet(allocator, owned_target);
    defer inspected.deinit(allocator);
    const evidence_text = try render(allocator, inspected);
    errdefer allocator.free(evidence_text);
    return .{
        .target = owned_target,
        .evidence_text = evidence_text,
    };
}

pub fn target(allocator: std.mem.Allocator, backend_host: []const u8, requested: ?[]const u8) ![]u8 {
    const raw = std.mem.trim(u8, requested orelse backend_host, " \t\r\n");
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) return allocator.dupe(u8, raw);
    if (std.mem.startsWith(u8, raw, "/")) return std.fmt.allocPrint(allocator, "http://{s}{s}", .{ backend_host, raw });
    return std.fmt.allocPrint(allocator, "http://{s}", .{raw});
}

pub fn render(allocator: std.mem.Allocator, result: http.RuntimeHttpResult) ![]u8 {
    const status = try optionalUsizeText(allocator, if (result.status) |value| @as(usize, @intCast(value)) else null);
    defer allocator.free(status);
    return std.fmt.allocPrint(
        allocator,
        "[RUNTIME_INSPECTION]\nsource=http_get raw_context_persisted=false target={s}\nstatus={s}\nserver={s}\nerror={s}\nbody_snippet={s}\n",
        .{
            result.target,
            status,
            result.server orelse "",
            result.error_name orelse "",
            result.body_snippet,
        },
    );
}

fn optionalUsizeText(allocator: std.mem.Allocator, value: ?usize) ![]const u8 {
    return if (value) |actual| try std.fmt.allocPrint(allocator, "{}", .{actual}) else try allocator.dupe(u8, "unknown");
}

test "runtime inspection target normalizes host path and url" {
    const from_path = try target(std.testing.allocator, "127.0.0.1:3000", "/health");
    defer std.testing.allocator.free(from_path);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000/health", from_path);

    const from_host = try target(std.testing.allocator, "127.0.0.1:3000", null);
    defer std.testing.allocator.free(from_host);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000", from_host);

    const from_url = try target(std.testing.allocator, "127.0.0.1:3000", "https://example.test/app");
    defer std.testing.allocator.free(from_url);
    try std.testing.expectEqualStrings("https://example.test/app", from_url);
}

test "runtime inspection render is model evidence" {
    const rendered = try render(std.testing.allocator, .{
        .target = "http://127.0.0.1:3000/health",
        .status = 200,
        .server = "test",
        .body_snippet = "ok",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[RUNTIME_INSPECTION]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "body_snippet=ok") != null);
}
