const std = @import("std");

const micro_context = @import("micro_context.zig");
const tools = @import("tools.zig");
const working_context = @import("working_context.zig");

const max_patch_file_bytes: usize = 1024 * 1024;

pub const Operation = enum {
    edit,
    create,
    delete,
    rename,
};

pub const Hunk = struct {
    search: []const u8,
    replace: []const u8,
    context_id: ?[]const u8 = null,
};

pub const Args = struct {
    operation: Operation = .edit,
    path: []const u8,
    destination_path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    hunks: []const Hunk = &.{},
};

pub const Result = struct {
    text: []u8,
    audit_text: []u8,
    stale_checked: bool,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.audit_text);
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    context: *const working_context.WorkingContext,
) !Result {
    return switch (args.operation) {
        .edit => executeEdit(allocator, io, args, context),
        .create => executeCreate(allocator, io, args),
        .delete => executeDelete(allocator, io, args, context),
        .rename => executeRename(allocator, io, args, context),
    };
}

fn executeEdit(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    context: *const working_context.WorkingContext,
) !Result {
    if (args.hunks.len == 0) return error.EmptyPatchSearch;
    const validation_range = try tools.readFileRange(allocator, args.path, 1, 1, max_patch_file_bytes);
    defer validation_range.deinit(allocator);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, args.path, allocator, .limited(max_patch_file_bytes));
    defer allocator.free(content);

    var validated = std.ArrayList(ValidatedHunk).empty;
    defer validated.deinit(allocator);
    var search_bytes: usize = 0;
    var replace_bytes: usize = 0;
    for (args.hunks) |hunk| {
        if (hunk.search.len == 0) return error.EmptyPatchSearch;
        const context_id = hunk.context_id orelse return error.MissingPatchContextId;
        try validateFreshContext(allocator, args.path, context_id, context);

        const start = std.mem.indexOf(u8, content, hunk.search) orelse return error.PatchSearchNotFound;
        if (countOccurrences(content, hunk.search) > 1) return error.PatchSearchNotUnique;
        try validated.append(allocator, .{
            .start = start,
            .end = start + hunk.search.len,
            .replace = hunk.replace,
        });
        search_bytes += hunk.search.len;
        replace_bytes += hunk.replace.len;
    }
    sortValidatedHunks(validated.items);
    try ensureNonOverlapping(validated.items);

    const patched = try buildPatchedContent(allocator, content, validated.items);
    defer allocator.free(patched);
    try atomicWriteFile(allocator, io, args.path, patched);

    return try makeResult(allocator, .edit, args.path, null, args.hunks.len, search_bytes, replace_bytes, true);
}

fn executeCreate(allocator: std.mem.Allocator, io: std.Io, args: Args) !Result {
    const content = args.content orelse return error.MissingPatchContent;
    try validateNewPath(allocator, io, args.path);
    try atomicWriteFile(allocator, io, args.path, content);
    return try makeResult(allocator, .create, args.path, null, 0, 0, content.len, false);
}

fn executeDelete(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    context: *const working_context.WorkingContext,
) !Result {
    if (args.hunks.len != 1) return error.MissingPatchContextId;
    const context_id = args.hunks[0].context_id orelse return error.MissingPatchContextId;
    try validateFreshContext(allocator, args.path, context_id, context);
    try std.Io.Dir.cwd().deleteFile(io, args.path);
    return try makeResult(allocator, .delete, args.path, null, 0, 0, 0, true);
}

fn executeRename(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    context: *const working_context.WorkingContext,
) !Result {
    if (args.hunks.len != 1) return error.MissingPatchContextId;
    const destination_path = args.destination_path orelse return error.MissingPatchDestination;
    const context_id = args.hunks[0].context_id orelse return error.MissingPatchContextId;
    if (std.mem.eql(u8, args.path, destination_path)) return error.PatchDestinationSameAsSource;
    try validateFreshContext(allocator, args.path, context_id, context);
    try validateNewPath(allocator, io, destination_path);
    try std.Io.Dir.cwd().rename(args.path, std.Io.Dir.cwd(), destination_path, io);
    return try makeResult(allocator, .rename, args.path, destination_path, 0, 0, 0, true);
}

const ValidatedHunk = struct {
    start: usize,
    end: usize,
    replace: []const u8,
};

fn sortValidatedHunks(items: []ValidatedHunk) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].start > items[j].start) : (j -= 1) {
            std.mem.swap(ValidatedHunk, &items[j - 1], &items[j]);
        }
    }
}

fn ensureNonOverlapping(items: []const ValidatedHunk) !void {
    var previous_end: usize = 0;
    for (items, 0..) |item, idx| {
        if (idx > 0 and item.start < previous_end) return error.PatchHunksOverlap;
        previous_end = item.end;
    }
}

fn buildPatchedContent(allocator: std.mem.Allocator, content: []const u8, hunks: []const ValidatedHunk) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (hunks) |hunk| {
        try out.appendSlice(allocator, content[cursor..hunk.start]);
        try out.appendSlice(allocator, hunk.replace);
        cursor = hunk.end;
    }
    try out.appendSlice(allocator, content[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn validateFreshContext(
    allocator: std.mem.Allocator,
    target_path: []const u8,
    context_id: []const u8,
    context: *const working_context.WorkingContext,
) !void {
    const evidence = context.findByContextId(context_id) orelse return error.MicroContextNotFound;
    if (!std.mem.eql(u8, evidence.path, target_path)) return error.PatchContextPathMismatch;
    const current = try tools.readFileRange(allocator, evidence.path, evidence.start_line, evidence.max_lines, max_patch_file_bytes);
    defer current.deinit(allocator);
    const fresh = try micro_context.fromFileRange(allocator, current, "collect_evidence", max_patch_file_bytes);
    defer fresh.deinit(allocator);
    if (!std.mem.eql(u8, fresh.id, context_id)) return error.StaleMicroContext;
}

fn validateNewPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try validatePatchPath(path);
    if (try pathExists(allocator, io, path)) return error.PatchTargetExists;
    try validateParentInsideCwd(allocator, path);
}

fn pathExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    _ = io;
    const range = tools.readFileRange(allocator, path, 1, 1, 1) catch return false;
    range.deinit(allocator);
    return true;
}

fn validateParentInsideCwd(allocator: std.mem.Allocator, path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return error.AbsolutePathDenied;
    const parent = path[0..slash];
    if (parent.len == 0) return;
    const parent_range = tools.readFileRange(allocator, parent, 1, 1, 1) catch |err| switch (err) {
        error.OpenFileFailed => return,
        else => return err,
    };
    parent_range.deinit(allocator);
}

fn validatePatchPath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyPath;
    if (std.fs.path.isAbsolute(path)) return error.AbsolutePathDenied;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.PathTraversalDenied;
        if (std.mem.startsWith(u8, part, ".")) return error.HiddenPathDenied;
        if (isSensitivePathPart(part)) return error.SensitivePathDenied;
    }
}

fn isSensitivePathPart(part: []const u8) bool {
    return std.ascii.eqlIgnoreCase(part, "credentials.json") or
        std.ascii.eqlIgnoreCase(part, "secrets.json") or
        std.ascii.eqlIgnoreCase(part, "id_rsa") or
        std.ascii.eqlIgnoreCase(part, "id_ed25519") or
        containsIgnoreCase(part, "credential") or
        containsIgnoreCase(part, "secret") or
        containsIgnoreCase(part, "token");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn atomicWriteFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const hash = std.hash.Wyhash.hash(0, data);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.phenom-tmp-{x}", .{ path, hash });
    defer allocator.free(tmp_path);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

fn makeResult(
    allocator: std.mem.Allocator,
    operation: Operation,
    path: []const u8,
    destination_path: ?[]const u8,
    hunks: usize,
    search_bytes: usize,
    replace_bytes: usize,
    stale_checked: bool,
) !Result {
    const text = if (destination_path) |dest|
        try std.fmt.allocPrint(
            allocator,
            "[PATCH_RESULT]\npath={s}\ndestination_path={s}\noperation={s}\nstatus=applied\nhunks={}\nstale_checked={}\n",
            .{ path, dest, @tagName(operation), hunks, stale_checked },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "[PATCH_RESULT]\npath={s}\noperation={s}\nstatus=applied\nhunks={}\nstale_checked={}\n",
            .{ path, @tagName(operation), hunks, stale_checked },
        );
    errdefer allocator.free(text);
    const audit_text = if (destination_path) |dest|
        try std.fmt.allocPrint(
            allocator,
            "[TOOL_EVENT]\ntool=apply_patch\nsuccess=true\noperation={s}\npath={s}\ndestination_path={s}\nhunks={} search_bytes={} replace_bytes={} stale_checked={}\n",
            .{ @tagName(operation), path, dest, hunks, search_bytes, replace_bytes, stale_checked },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "[TOOL_EVENT]\ntool=apply_patch\nsuccess=true\noperation={s}\npath={s}\nhunks={} search_bytes={} replace_bytes={} stale_checked={}\n",
            .{ @tagName(operation), path, hunks, search_bytes, replace_bytes, stale_checked },
        );
    errdefer allocator.free(audit_text);
    return .{
        .text = text,
        .audit_text = audit_text,
        .stale_checked = stale_checked,
    };
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        count += 1;
        start += idx + needle.len;
    }
    return count;
}

test "apply patch requires exact unique search" {
    const path = "apply_patch_unique_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\none\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 2, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 2,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_unique_test.txt L1-L2 hash=1\none\none\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    try std.testing.expectError(error.PatchSearchNotUnique, execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .hunks = &.{.{ .search = "one", .replace = "two", .context_id = ctx.id }},
    }, &context));
}

test "apply patch requires context id before write" {
    const path = "apply_patch_missing_context_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\ntwo\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();

    try std.testing.expectError(error.MissingPatchContextId, execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .hunks = &.{.{ .search = "two", .replace = "dos" }},
    }, &context));

    const unchanged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("one\ntwo\n", unchanged);
}

test "apply patch validates stale micro context before write" {
    const path = "apply_patch_stale_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\ntwo\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 2, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 2,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_stale_test.txt L1-L2 hash=1\none\ntwo\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\nchanged\n" });
    try std.testing.expectError(error.StaleMicroContext, execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .hunks = &.{.{ .search = "one", .replace = "uno", .context_id = ctx.id }},
    }, &context));
}

test "apply patch writes with fresh context id" {
    const path = "apply_patch_fresh_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one\ntwo\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 2, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 2,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_fresh_test.txt L1-L2 hash=1\none\ntwo\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .hunks = &.{.{ .search = "two", .replace = "dos", .context_id = ctx.id }},
    }, &context);
    defer result.deinit(std.testing.allocator);

    const updated = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("one\ndos\n", updated);
    try std.testing.expect(result.stale_checked);
}

test "apply patch applies multiple hunks atomically by original positions" {
    const path = "apply_patch_multi_hunk_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "alpha\nbeta\ngamma\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 3, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 3,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_multi_hunk_test.txt L1-L3 hash=1\nalpha\nbeta\ngamma\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .hunks = &.{
            .{ .search = "alpha", .replace = "beta", .context_id = ctx.id },
            .{ .search = "gamma", .replace = "delta", .context_id = ctx.id },
        },
    }, &context);
    defer result.deinit(std.testing.allocator);

    const updated = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("beta\nbeta\ndelta\n", updated);
}

test "apply patch does not write when one hunk is invalid" {
    const path = "apply_patch_multi_hunk_invalid_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "alpha\nbeta\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 2, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 2,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_multi_hunk_invalid_test.txt L1-L2 hash=1\nalpha\nbeta\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    try std.testing.expectError(error.PatchSearchNotFound, execute(std.testing.allocator, std.testing.io, .{
        .path = path,
        .hunks = &.{
            .{ .search = "alpha", .replace = "one", .context_id = ctx.id },
            .{ .search = "missing", .replace = "two", .context_id = ctx.id },
        },
    }, &context));

    const updated = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("alpha\nbeta\n", updated);
}

test "apply patch creates a new file without overwriting" {
    const path = "apply_patch_create_test.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .operation = .create,
        .path = path,
        .content = "new\n",
    }, &context);
    defer result.deinit(std.testing.allocator);

    const created = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(created);
    try std.testing.expectEqualStrings("new\n", created);
    try std.testing.expectError(error.PatchTargetExists, execute(std.testing.allocator, std.testing.io, .{
        .operation = .create,
        .path = path,
        .content = "overwrite\n",
    }, &context));
}

test "apply patch deletes with fresh context id" {
    const path = "apply_patch_delete_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "delete me\n" });

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 1, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 1,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_delete_test.txt L1-L1 hash=1\ndelete me\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .operation = .delete,
        .path = path,
        .hunks = &.{.{ .search = "", .replace = "", .context_id = ctx.id }},
    }, &context);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectError(error.OpenFileFailed, tools.readFileRange(std.testing.allocator, path, 1, 1, 1024));
}

test "apply patch renames with fresh context id and refuses existing destination" {
    const path = "apply_patch_rename_test.txt";
    const dest = "apply_patch_renamed_test.txt";
    const existing = "apply_patch_rename_existing_test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "rename me\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = existing, .data = "exists\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, dest) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, existing) catch {};

    var context = working_context.WorkingContext.init(std.testing.allocator);
    defer context.deinit();
    const range = try tools.readFileRange(std.testing.allocator, path, 1, 1, 1024);
    defer range.deinit(std.testing.allocator);
    const ctx = try micro_context.fromFileRange(std.testing.allocator, range, "collect_evidence", 1024);
    defer ctx.deinit(std.testing.allocator);
    try context.remember(.{
        .path = path,
        .strategy = .path,
        .start_line = 1,
        .max_lines = 1,
        .context_id = ctx.id,
        .evidence_text = "[EVIDENCE]\n- apply_patch_rename_test.txt L1-L1 hash=1\nrename me\n",
        .model_bytes = 80,
        .quality_score = 90,
    });

    try std.testing.expectError(error.PatchTargetExists, execute(std.testing.allocator, std.testing.io, .{
        .operation = .rename,
        .path = path,
        .destination_path = existing,
        .hunks = &.{.{ .search = "", .replace = "", .context_id = ctx.id }},
    }, &context));

    const result = try execute(std.testing.allocator, std.testing.io, .{
        .operation = .rename,
        .path = path,
        .destination_path = dest,
        .hunks = &.{.{ .search = "", .replace = "", .context_id = ctx.id }},
    }, &context);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectError(error.OpenFileFailed, tools.readFileRange(std.testing.allocator, path, 1, 1, 1024));
    const renamed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, dest, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(renamed);
    try std.testing.expectEqualStrings("rename me\n", renamed);
}
