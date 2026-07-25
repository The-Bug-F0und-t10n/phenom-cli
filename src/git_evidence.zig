const std = @import("std");

const contracts = @import("contracts.zig");
const evidence = @import("evidence.zig");

pub const Args = struct {
    path: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    terms: ?[]const u8 = null,
    target_files: ?[]const u8 = null,
    scope_root: ?[]const u8 = null,
    strategy: contracts.StrategyName,
    budget_bytes: usize,
};

pub const Result = struct {
    context_id: []const u8,
    evidence_text: []u8,
    tool_event_audit_text: []u8,
    raw_bytes_read: usize,
    model_bytes: usize,
    quality_score: i32,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.context_id);
        allocator.free(self.evidence_text);
        allocator.free(self.tool_event_audit_text);
    }
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    if (args.budget_bytes == 0) return error.InvalidEvidenceBudget;
    return switch (args.strategy) {
        .diff => executeDiff(allocator, io, args),
        .history => executeHistory(allocator, io, args),
        .show => executeShow(allocator, io, args),
        .reflog => executeReflog(allocator, io, args),
        .@"unreachable" => executeUnreachable(allocator, io, args),
        else => error.InvalidGitEvidenceStrategy,
    };
}

fn executeDiff(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    const status = try runGitText(allocator, io, args.path, .status, args);
    defer allocator.free(status);
    const stat = try runGitText(allocator, io, args.path, .diff_stat, args);
    defer allocator.free(stat);
    const diff = try runGitText(allocator, io, args.path, .diff, args);
    defer allocator.free(diff);

    var excerpt = std.ArrayList(u8).empty;
    errdefer excerpt.deinit(allocator);
    try excerpt.appendSlice(allocator, "[GIT_STATUS]\n");
    try appendSectionOrEmpty(allocator, &excerpt, status);
    try excerpt.appendSlice(allocator, "\n[GIT_DIFF_STAT]\n");
    try appendSectionOrEmpty(allocator, &excerpt, stat);
    try excerpt.appendSlice(allocator, "\n[GIT_DIFF]\n");
    try appendBudgetedText(allocator, &excerpt, diff, args.budget_bytes);
    const excerpt_text = try excerpt.toOwnedSlice(allocator);
    return renderGitResult(allocator, args, "git_diff", "workspace", excerpt_text, status.len + stat.len + diff.len, 88);
}

fn executeHistory(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    const log = try runGitText(allocator, io, args.path, .history, args);
    defer allocator.free(log);
    const excerpt = try renderSingleSection(allocator, "[GIT_HISTORY]", log, args.budget_bytes);
    return renderGitResult(allocator, args, "git_history", args.path orelse "all", excerpt, log.len, if (log.len > 0) 82 else 35);
}

fn executeShow(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    const shown = try runGitText(allocator, io, args.path, .show, args);
    defer allocator.free(shown);
    const excerpt = try renderSingleSection(allocator, "[GIT_SHOW]", shown, args.budget_bytes);
    return renderGitResult(allocator, args, "git_show", args.terms orelse args.intent orelse "HEAD", excerpt, shown.len, if (shown.len > 0) 84 else 35);
}

fn executeReflog(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    const reflog = try runGitText(allocator, io, null, .reflog, args);
    defer allocator.free(reflog);
    const excerpt = try renderSingleSection(allocator, "[GIT_REFLOG]", reflog, args.budget_bytes);
    return renderGitResult(allocator, args, "git_reflog", "HEAD", excerpt, reflog.len, if (reflog.len > 0) 86 else 35);
}

fn executeUnreachable(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    const fsck = try runGitText(allocator, io, null, .@"unreachable", args);
    defer allocator.free(fsck);
    const excerpt = try renderSingleSection(allocator, "[GIT_UNREACHABLE]", fsck, args.budget_bytes);
    return renderGitResult(allocator, args, "git_unreachable", "objects", excerpt, fsck.len, if (fsck.len > 0) 78 else 35);
}

const GitCommand = enum { status, diff_stat, diff, history, show, reflog, @"unreachable" };

fn runGitText(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8, command: GitCommand, args: Args) ![]u8 {
    return switch (command) {
        .status => if (path) |p|
            try runProcess(allocator, io, &.{ "git", "status", "--short", "--", p }, 16 * 1024)
        else
            try runProcess(allocator, io, &.{ "git", "status", "--short" }, 16 * 1024),
        .diff_stat => if (path) |p|
            try runProcess(allocator, io, &.{ "git", "diff", "--stat", "--", p }, 16 * 1024)
        else
            try runProcess(allocator, io, &.{ "git", "diff", "--stat" }, 16 * 1024),
        .diff => if (path) |p|
            try runProcess(allocator, io, &.{ "git", "diff", "--", p }, 512 * 1024)
        else
            try runProcess(allocator, io, &.{ "git", "diff" }, 512 * 1024),
        .history => if (path) |p|
            try runProcess(allocator, io, &.{ "git", "log", "--all", "--decorate", "--oneline", "--", p }, 64 * 1024)
        else
            try runProcess(allocator, io, &.{ "git", "log", "--all", "--decorate", "--oneline", "-n", "80" }, 64 * 1024),
        .show => blk: {
            const rev = safeRevision(args.terms) orelse safeRevision(args.intent) orelse "HEAD";
            if (path) |p| {
                break :blk try runProcess(allocator, io, &.{ "git", "show", "--stat", "--patch", "--", p }, 128 * 1024);
            }
            break :blk try runProcess(allocator, io, &.{ "git", "show", "--stat", "--patch", rev }, 128 * 1024);
        },
        .reflog => try runProcess(allocator, io, &.{ "git", "reflog", "--date=iso", "--all", "-n", "80" }, 64 * 1024),
        .@"unreachable" => try runProcess(allocator, io, &.{ "git", "fsck", "--unreachable", "--no-reflogs" }, 64 * 1024),
    };
}

fn safeRevision(value: ?[]const u8) ?[]const u8 {
    const text = std.mem.trim(u8, value orelse return null, " \t\r\n");
    if (text.len == 0 or text.len > 80) return null;
    for (text) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '/' or byte == '.' or byte == '@' or byte == '{' or byte == '}';
        if (!ok) return null;
    }
    return text;
}

fn runProcess(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdout_limit: usize) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.GitUnavailable,
        error.StreamTooLong => return error.GitOutputTooLarge,
        else => return err,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0 and result.stdout.len == 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
    return result.stdout;
}

fn renderSingleSection(allocator: std.mem.Allocator, header: []const u8, text: []const u8, budget_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, header);
    try out.append(allocator, '\n');
    try appendSectionOrEmpty(allocator, &out, text);
    if (out.items.len > budget_bytes) {
        out.shrinkRetainingCapacity(budget_bytes);
        try out.appendSlice(allocator, "\n[TRUNCATED]\n");
    }
    return out.toOwnedSlice(allocator);
}

fn renderGitResult(
    allocator: std.mem.Allocator,
    args: Args,
    kind: []const u8,
    range: []const u8,
    excerpt_text: []u8,
    raw_bytes_read: usize,
    quality_score: i32,
) !Result {
    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    var entry_committed = false;
    var entry = evidence.EvidenceEntry{
        .source = try allocator.dupe(u8, "git"),
        .kind = try allocator.dupe(u8, kind),
        .range = try allocator.dupe(u8, range),
        .hash = std.hash.Wyhash.hash(0, excerpt_text),
        .excerpt = excerpt_text,
    };
    errdefer if (!entry_committed) entry.deinit(allocator);
    try packet.add(entry);
    entry_committed = true;

    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);
    const tool_event_audit_text = try std.fmt.allocPrint(
        allocator,
        "[TOOL_EVENT]\ntool=collect_evidence\nsuccess=true\nargs=source=git strategy={s} kind={s} path={s} intent_bytes={} terms_bytes={} raw_bytes={} model_bytes={} budget_bytes={}\n",
        .{ @tagName(args.strategy), kind, args.path orelse "", if (args.intent) |value| value.len else 0, if (args.terms) |value| value.len else 0, raw_bytes_read, evidence_text.len, args.budget_bytes },
    );
    errdefer allocator.free(tool_event_audit_text);
    const context_id = try std.fmt.allocPrint(allocator, "git_{x}", .{std.hash.Wyhash.hash(0, evidence_text)});
    errdefer allocator.free(context_id);

    return .{
        .context_id = context_id,
        .evidence_text = evidence_text,
        .tool_event_audit_text = tool_event_audit_text,
        .raw_bytes_read = raw_bytes_read,
        .model_bytes = evidence_text.len,
        .quality_score = quality_score,
    };
}

fn appendSectionOrEmpty(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len == 0) {
        try out.appendSlice(allocator, "(empty)\n");
        return;
    }
    try appendBudgetedText(allocator, out, text, 2048);
}

fn appendBudgetedText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max_bytes: usize) !void {
    const n = @min(text.len, max_bytes);
    try out.appendSlice(allocator, text[0..n]);
    if (!std.mem.endsWith(u8, out.items, "\n")) try out.append(allocator, '\n');
    if (text.len > n) try out.appendSlice(allocator, "[TRUNCATED]\n");
}

test "safe revision accepts refs and hashes only" {
    try std.testing.expectEqualStrings("HEAD@{1}", safeRevision("HEAD@{1}").?);
    try std.testing.expectEqualStrings("abc123", safeRevision("abc123").?);
    try std.testing.expect(safeRevision("HEAD; rm -rf .") == null);
    try std.testing.expect(safeRevision("abc def") == null);
}
