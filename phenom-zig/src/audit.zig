const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

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
};
