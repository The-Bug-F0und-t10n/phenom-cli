const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const AuditEvent = struct {
    kind: []u8,
    body: []u8,

    pub fn deinit(self: *AuditEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.body);
    }
};

pub const AuditDb = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !AuditDb {
        var db: ?*c.sqlite3 = null;
        const z_path = try allocator.dupeZ(u8, path);
        defer allocator.free(z_path);

        if (c.sqlite3_open(z_path.ptr, &db) != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return error.SqliteOpenFailed;
        }

        var audit = AuditDb{ .allocator = allocator, .db = db };
        try audit.exec(
            \\create table if not exists events (
            \\  id integer primary key autoincrement,
            \\  session text not null,
            \\  kind text not null,
            \\  body text not null,
            \\  created_at text not null default current_timestamp
            \\);
        );
        try audit.exec(
            \\create table if not exists input_history (
            \\  id integer primary key autoincrement,
            \\  line text not null,
            \\  created_at text not null default current_timestamp
            \\);
            \\create index if not exists input_history_line_id_idx on input_history(line, id);
        );
        return audit;
    }

    pub fn close(self: *AuditDb) void {
        if (self.db) |handle| {
            _ = c.sqlite3_close(handle);
            self.db = null;
        }
    }

    fn exec(self: *AuditDb, sql: []const u8) !void {
        const z_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(z_sql);
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, z_sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return error.SqliteExecFailed;
        }
    }

    pub fn recordEvent(self: *AuditDb, session: []const u8, kind: []const u8, body: []const u8) !void {
        const sql = "insert into events(session, kind, body) values (?1, ?2, ?3)";
        const z_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(z_sql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const z_session = try self.allocator.dupeZ(u8, session);
        defer self.allocator.free(z_session);
        const z_kind = try self.allocator.dupeZ(u8, kind);
        defer self.allocator.free(z_kind);
        const z_body = try self.allocator.dupeZ(u8, body);
        defer self.allocator.free(z_body);

        if (c.sqlite3_bind_text(stmt, 1, z_session.ptr, @as(c_int, @intCast(session.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_text(stmt, 2, z_kind.ptr, @as(c_int, @intCast(kind.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_text(stmt, 3, z_body.ptr, @as(c_int, @intCast(body.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn recordInputHistory(self: *AuditDb, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed.len > std.math.maxInt(c_int)) return error.HistoryLineTooLarge;

        {
            const sql = "insert into input_history(line) values (?1)";
            const z_sql = try self.allocator.dupeZ(u8, sql);
            defer self.allocator.free(z_sql);

            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            const z_line = try self.allocator.dupeZ(u8, trimmed);
            defer self.allocator.free(z_line);
            if (c.sqlite3_bind_text(stmt, 1, z_line.ptr, @as(c_int, @intCast(trimmed.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
        }

        try self.exec(
            \\delete from input_history
            \\where id not in (
            \\  select id from (
            \\    select max(id) as id
            \\    from input_history
            \\    group by line
            \\    order by max(id) desc
            \\    limit 200
            \\  )
            \\);
        );
    }

    pub fn loadInputHistoryNewestFirst(self: *AuditDb, allocator: std.mem.Allocator, limit: usize) !std.ArrayList([]u8) {
        if (limit > std.math.maxInt(c_int)) return error.HistoryLimitTooLarge;

        const sql =
            \\select line
            \\from (
            \\  select line, max(id) as last_id
            \\  from input_history
            \\  group by line
            \\)
            \\order by last_id desc
            \\limit ?1
        ;
        const z_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(z_sql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int(stmt, 1, @as(c_int, @intCast(limit))) != c.SQLITE_OK) return error.SqliteBindFailed;

        var lines = std.ArrayList([]u8).empty;
        errdefer freeHistoryLines(allocator, &lines);

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;

            const ptr = c.sqlite3_column_text(stmt, 0) orelse return error.SqliteColumnFailed;
            const len_raw = c.sqlite3_column_bytes(stmt, 0);
            if (len_raw < 0) return error.SqliteColumnFailed;
            const bytes = @as([*]const u8, @ptrCast(ptr))[0..@as(usize, @intCast(len_raw))];
            const owned = try allocator.dupe(u8, bytes);
            errdefer allocator.free(owned);
            try lines.append(allocator, owned);
        }

        return lines;
    }

    pub fn loadSessionEvents(self: *AuditDb, allocator: std.mem.Allocator, session: []const u8, limit: usize) !std.ArrayList(AuditEvent) {
        if (limit > std.math.maxInt(c_int)) return error.EventLimitTooLarge;

        const sql =
            \\select kind, body
            \\from events
            \\where session = ?1
            \\order by id asc
            \\limit ?2
        ;
        const z_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(z_sql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const z_session = try self.allocator.dupeZ(u8, session);
        defer self.allocator.free(z_session);

        if (c.sqlite3_bind_text(stmt, 1, z_session.ptr, @as(c_int, @intCast(session.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_int(stmt, 2, @as(c_int, @intCast(limit))) != c.SQLITE_OK) return error.SqliteBindFailed;

        var events = std.ArrayList(AuditEvent).empty;
        errdefer freeAuditEvents(allocator, &events);

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;

            const kind = try dupeColumnText(allocator, stmt, 0);
            errdefer allocator.free(kind);
            const body = try dupeColumnText(allocator, stmt, 1);
            errdefer allocator.free(body);
            try events.append(allocator, .{ .kind = kind, .body = body });
        }

        return events;
    }
};

pub fn freeHistoryLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}

pub fn freeAuditEvents(allocator: std.mem.Allocator, events: *std.ArrayList(AuditEvent)) void {
    for (events.items) |*event| event.deinit(allocator);
    events.deinit(allocator);
}

fn dupeColumnText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, column: c_int) ![]u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return error.SqliteColumnFailed;
    const len_raw = c.sqlite3_column_bytes(stmt, column);
    if (len_raw < 0) return error.SqliteColumnFailed;
    const bytes = @as([*]const u8, @ptrCast(ptr))[0..@as(usize, @intCast(len_raw))];
    return allocator.dupe(u8, bytes);
}

test "input history loads newest distinct sqlite lines" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordInputHistory("primeiro");
    try db.recordInputHistory("segundo");
    try db.recordInputHistory("primeiro");

    var lines = try db.loadInputHistoryNewestFirst(std.testing.allocator, 200);
    defer freeHistoryLines(std.testing.allocator, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("primeiro", lines.items[0]);
    try std.testing.expectEqualStrings("segundo", lines.items[1]);
}

test "session events load in insertion order" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("s1", "turn_start", "ola");
    try db.recordEvent("s2", "turn_start", "ignore");
    try db.recordEvent("s1", "assistant_delta", "ok");

    var events = try db.loadSessionEvents(std.testing.allocator, "s1", 20);
    defer freeAuditEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("turn_start", events.items[0].kind);
    try std.testing.expectEqualStrings("ola", events.items[0].body);
    try std.testing.expectEqualStrings("assistant_delta", events.items[1].kind);
    try std.testing.expectEqualStrings("ok", events.items[1].body);
}

test "input history trims to newest 200 distinct lines" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var i: usize = 0;
    while (i < 205) : (i += 1) {
        const line = try std.fmt.allocPrint(std.testing.allocator, "line-{d}", .{i});
        defer std.testing.allocator.free(line);
        try db.recordInputHistory(line);
    }

    var lines = try db.loadInputHistoryNewestFirst(std.testing.allocator, 500);
    defer freeHistoryLines(std.testing.allocator, &lines);

    try std.testing.expectEqual(@as(usize, 200), lines.items.len);
    try std.testing.expectEqualStrings("line-204", lines.items[0]);
    try std.testing.expectEqualStrings("line-5", lines.items[199]);
}
