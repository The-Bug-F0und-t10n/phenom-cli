const std = @import("std");

const contracts = @import("contracts.zig");
const web_rag = @import("web_rag.zig");

pub const CollectorKind = enum {
    web,
    diagnostic,
    git,
    path,
    ranked,
};

pub const ResolveArgs = struct {
    source: contracts.SourceName = .auto,
    strategy: contracts.StrategyName = .auto,
    path: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

pub fn resolve(args: ResolveArgs) !CollectorKind {
    if (args.source == .web) return .web;
    if (args.source == .diagnostic) return .diagnostic;
    if (args.source == .git) return .git;
    if (args.source == .file) return .path;
    if (args.source == .code or args.source == .rag) return .ranked;

    if (isHttpArg(args.target) or isHttpArg(args.path)) return .web;
    return switch (args.strategy) {
        .diagnostic => .diagnostic,
        .diff, .history, .show, .reflog, .@"unreachable" => .git,
        .path => .path,
        else => if (args.path != null) .path else .ranked,
    };
}

fn isHttpArg(value: ?[]const u8) bool {
    return if (value) |text| web_rag.isHttpTarget(text) else false;
}

test "resolver keeps legacy collect evidence behavior" {
    try std.testing.expectEqual(CollectorKind.web, try resolve(.{ .target = "http://127.0.0.1/a" }));
    try std.testing.expectEqual(CollectorKind.diagnostic, try resolve(.{ .strategy = .diagnostic, .path = "src/main.zig" }));
    try std.testing.expectEqual(CollectorKind.git, try resolve(.{ .strategy = .diff }));
    try std.testing.expectEqual(CollectorKind.path, try resolve(.{ .path = "README.md" }));
    try std.testing.expectEqual(CollectorKind.ranked, try resolve(.{ .strategy = .symbol }));
}

test "resolver honors model selected source for nonlinear strategy shifts" {
    try std.testing.expectEqual(CollectorKind.git, try resolve(.{ .source = .git, .strategy = .reflog }));
    try std.testing.expectEqual(CollectorKind.ranked, try resolve(.{ .source = .code, .strategy = .symbol }));
    try std.testing.expectEqual(CollectorKind.path, try resolve(.{ .source = .file, .path = "README.md", .strategy = .auto }));
}
