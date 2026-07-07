const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const workspace_inventory = @import("workspace_inventory.zig");

const max_indexed_files: usize = 512;
const max_file_bytes: usize = 96 * 1024;

pub const Candidate = struct {
    path: []u8,
    line: usize,
    score: i32,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Result = struct {
    candidates: std.ArrayList(Candidate),
    indexed_files: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |candidate| candidate.deinit(allocator);
        self.candidates.deinit(allocator);
    }
};

pub fn rank(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    max_candidates: usize,
) !Result {
    const fts_query = try buildFtsQuery(allocator, query);
    defer allocator.free(fts_query);

    var candidates = std.ArrayList(Candidate).empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    if (fts_query.len == 0) return .{ .candidates = candidates, .indexed_files = 0 };

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);

    try exec(allocator, db, "create virtual table chunks using fts5(path unindexed, body, tokenize='unicode61');");
    const indexed = try indexWorkspace(allocator, io, db);
    try queryCandidates(allocator, db, fts_query, max_candidates, &candidates);
    return .{ .candidates = candidates, .indexed_files = indexed };
}

fn exec(allocator: std.mem.Allocator, db: ?*c.sqlite3, sql: []const u8) !void {
    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(db, z_sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return error.SqliteExecFailed;
    }
}

fn indexWorkspace(allocator: std.mem.Allocator, io: std.Io, db: ?*c.sqlite3) !usize {
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var inventory = try workspace_inventory.collect(allocator, io, max_indexed_files * 4);
    defer inventory.deinit(allocator);

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "insert into chunks(path, body) values (?1, ?2)";
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var indexed: usize = 0;
    for (inventory.paths.items) |path| {
        if (indexed >= max_indexed_files) break;
        const content = cwd.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch continue;
        defer allocator.free(content);
        if (!workspace_inventory.isTextBytes(content)) continue;
        try insertChunk(allocator, stmt, path, content);
        indexed += 1;
    }
    return indexed;
}

fn insertChunk(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, path: []const u8, body: []const u8) !void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const z_body = try allocator.dupeZ(u8, body);
    defer allocator.free(z_body);
    if (c.sqlite3_bind_text(stmt, 1, z_path.ptr, @as(c_int, @intCast(path.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_bind_text(stmt, 2, z_body.ptr, @as(c_int, @intCast(body.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn queryCandidates(
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    fts_query: []const u8,
    max_candidates: usize,
    out: *std.ArrayList(Candidate),
) !void {
    const sql =
        \\select path, body, bm25(chunks) as rank
        \\from chunks
        \\where chunks match ?1
        \\order by rank
        \\limit ?2
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const z_query = try allocator.dupeZ(u8, fts_query);
    defer allocator.free(z_query);
    if (c.sqlite3_bind_text(stmt, 1, z_query.ptr, @as(c_int, @intCast(fts_query.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_bind_int(stmt, 2, @as(c_int, @intCast(max_candidates))) != c.SQLITE_OK) return error.SqliteBindFailed;

    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
        const path = try dupeColumnText(allocator, stmt, 0);
        errdefer allocator.free(path);
        const body = columnText(stmt, 1);
        const rank_value = c.sqlite3_column_double(stmt, 2);
        const line = bestLineForQuery(body, fts_query);
        try out.append(allocator, .{
            .path = path,
            .line = line,
            .score = candidateScore(body, fts_query, rank_value),
        });
    }
}

fn buildFtsQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var first = true;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n\"'`()[]{}<>:;,.!?/\\|");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, "-_*");
        if (term.len < 3) continue;
        if (!isFtsTerm(term)) continue;
        if (!first) try out.appendSlice(allocator, " OR ");
        first = false;
        try appendQuotedFtsTerm(&out, allocator, term);
    }
    return out.toOwnedSlice(allocator);
}

fn appendQuotedFtsTerm(out: *std.ArrayList(u8), allocator: std.mem.Allocator, term: []const u8) !void {
    try out.append(allocator, '"');
    for (term) |byte| {
        if (byte == '"') continue;
        try out.append(allocator, byte);
    }
    try out.append(allocator, '"');
}

fn isFtsTerm(term: []const u8) bool {
    for (term) |byte| {
        if (byte >= 0x80) continue;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn bestLineForQuery(body: []const u8, fts_query: []const u8) usize {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fts_query, start, '"')) |open| {
        const term_start = open + 1;
        const close = std.mem.indexOfScalarPos(u8, fts_query, term_start, '"') orelse break;
        const term = fts_query[term_start..close];
        if (term.len > 0) {
            if (indexOfIgnoreCase(body, term)) |idx| return lineNumberAt(body, idx);
        }
        start = close + 1;
    }
    return 1;
}

fn candidateScore(body: []const u8, fts_query: []const u8, rank_value: f64) i32 {
    const coverage = quotedTermCoverage(body, fts_query);
    const bm25 = @min(@abs(rank_value) * 1_000_000.0, 12.0);
    return 36 + @as(i32, @intCast(coverage * 18)) + @as(i32, @intFromFloat(bm25));
}

fn quotedTermCoverage(body: []const u8, fts_query: []const u8) usize {
    var matched: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fts_query, start, '"')) |open| {
        const term_start = open + 1;
        const close = std.mem.indexOfScalarPos(u8, fts_query, term_start, '"') orelse break;
        const term = fts_query[term_start..close];
        if (term.len > 0 and indexOfIgnoreCase(body, term) != null) matched += 1;
        start = close + 1;
    }
    return matched;
}

fn columnText(stmt: ?*c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len_raw = c.sqlite3_column_bytes(stmt, column);
    if (len_raw <= 0) return "";
    return @as([*]const u8, @ptrCast(ptr))[0..@as(usize, @intCast(len_raw))];
}

fn dupeColumnText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, column: c_int) ![]u8 {
    return allocator.dupe(u8, columnText(stmt, column));
}

fn lineNumberAt(text: []const u8, idx: usize) usize {
    var line: usize = 1;
    for (text[0..@min(idx, text.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "fts bm25 ranks workspace files without raw output" {
    var result = try rank(std.testing.allocator, std.testing.io, "collect evidence ranking", 5);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.indexed_files > 0);
    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expect(result.candidates.items[0].path.len > 0);
}

test "fts query builder keeps model terms without stopwords" {
    const query = try buildFtsQuery(std.testing.allocator, "qual função monta collect_evidence?");
    defer std.testing.allocator.free(query);
    try std.testing.expect(std.mem.indexOf(u8, query, "\"collect_evidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "\"qual\"") != null);
}

test "best line parser does not split terms on OR letters" {
    const body = "alpha\nrenderer markdown\n";
    try std.testing.expectEqual(@as(usize, 2), bestLineForQuery(body, "\"renderer\" OR \"markdown\""));
}

test "candidate score prefers coverage of model terms" {
    const one = candidateScore("markdown only", "\"markdown\" OR \"diff\" OR \"output\"", -0.1);
    const three = candidateScore("markdown diff output", "\"markdown\" OR \"diff\" OR \"output\"", -0.1);
    try std.testing.expect(three > one);
}
