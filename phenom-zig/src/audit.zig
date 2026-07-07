const std = @import("std");
const tool_event = @import("tool_event.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const AuditEvent = struct {
    kind: []u8,
    body: []u8,
    created_at_unix_s: ?i64 = null,

    pub fn deinit(self: *AuditEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.body);
    }
};

pub const SessionSearchHit = struct {
    session: []u8,
    kind: []u8,
    body: []u8,
    score: f64,
    created_at_unix_s: ?i64 = null,

    pub fn deinit(self: *SessionSearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.session);
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
        try audit.ensureSessionFts();
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

    fn ensureSessionFts(self: *AuditDb) !void {
        try self.exec(
            \\create virtual table if not exists events_fts using fts5(
            \\  session,
            \\  kind,
            \\  body,
            \\  created_at,
            \\  content='events',
            \\  content_rowid='id',
            \\  tokenize='unicode61'
            \\);
            \\create trigger if not exists events_ai after insert on events begin
            \\  insert into events_fts(rowid, session, kind, body, created_at)
            \\  values (new.id, new.session, new.kind, new.body, new.created_at);
            \\end;
            \\create trigger if not exists events_ad after delete on events begin
            \\  insert into events_fts(events_fts, rowid, session, kind, body, created_at)
            \\  values('delete', old.id, old.session, old.kind, old.body, old.created_at);
            \\end;
            \\create trigger if not exists events_au after update on events begin
            \\  insert into events_fts(events_fts, rowid, session, kind, body, created_at)
            \\  values('delete', old.id, old.session, old.kind, old.body, old.created_at);
            \\  insert into events_fts(rowid, session, kind, body, created_at)
            \\  values (new.id, new.session, new.kind, new.body, new.created_at);
            \\end;
        );
        try self.exec("insert into events_fts(events_fts) values('rebuild');");
    }

    pub fn recordToolEventSummary(self: *AuditDb, session: []const u8, event: tool_event.ToolEvent) !void {
        const body = try event.renderAuditSummary(self.allocator);
        defer self.allocator.free(body);
        try self.recordEvent(session, "tool_event", body);
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
            \\select kind, body, cast(strftime('%s', created_at) as integer)
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
            const created_at_unix_s = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) null else @as(i64, @intCast(c.sqlite3_column_int64(stmt, 2)));
            try events.append(allocator, .{ .kind = kind, .body = body, .created_at_unix_s = created_at_unix_s });
        }

        return events;
    }

    pub fn loadRecentSessionEvents(self: *AuditDb, allocator: std.mem.Allocator, session: []const u8, limit: usize) !std.ArrayList(AuditEvent) {
        if (limit > std.math.maxInt(c_int)) return error.EventLimitTooLarge;

        const sql =
            \\select kind, body, cast(strftime('%s', created_at) as integer)
            \\from (
            \\  select id, kind, body, created_at
            \\  from events
            \\  where session = ?1
            \\  order by id desc
            \\  limit ?2
            \\)
            \\order by id asc
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
            const created_at_unix_s = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) null else @as(i64, @intCast(c.sqlite3_column_int64(stmt, 2)));
            try events.append(allocator, .{ .kind = kind, .body = body, .created_at_unix_s = created_at_unix_s });
        }

        return events;
    }

    pub fn searchSessionEventsFts(
        self: *AuditDb,
        allocator: std.mem.Allocator,
        session: []const u8,
        terms: []const u8,
        current_prompt: []const u8,
        limit: usize,
    ) !std.ArrayList(SessionSearchHit) {
        return self.searchSessionEventsFtsScoped(allocator, session, terms, current_prompt, limit);
    }

    pub fn searchAllSessionEventsFts(
        self: *AuditDb,
        allocator: std.mem.Allocator,
        terms: []const u8,
        current_prompt: []const u8,
        limit: usize,
    ) !std.ArrayList(SessionSearchHit) {
        return self.searchSessionEventsFtsScoped(allocator, null, terms, current_prompt, limit);
    }

    fn searchSessionEventsFtsScoped(
        self: *AuditDb,
        allocator: std.mem.Allocator,
        session: ?[]const u8,
        terms: []const u8,
        current_prompt: []const u8,
        limit: usize,
    ) !std.ArrayList(SessionSearchHit) {
        if (limit > std.math.maxInt(c_int)) return error.EventLimitTooLarge;
        const query = try buildFtsQuery(allocator, terms);
        defer allocator.free(query);

        var hits = std.ArrayList(SessionSearchHit).empty;
        errdefer freeSessionSearchHits(allocator, &hits);
        if (query.len == 0) return hits;

        const sql =
            \\select e.session, e.kind, e.body, -bm25(events_fts) as rank_score, cast(strftime('%s', e.created_at) as integer)
            \\from events_fts
            \\join events e on e.id = events_fts.rowid
            \\where events_fts match ?1
            \\  and (?2 is null or e.session = ?2)
            \\  and e.body <> ?3
            \\  and e.kind in ('turn_start', 'assistant_delta', 'tool_start', 'working_context_add', 'tool_duplicate', 'turn_done')
            \\  and not (e.kind = 'tool_start' and e.body like 'search_session%')
            \\order by rank_score desc, e.id desc
            \\limit ?4
        ;
        const z_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(z_sql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const z_query = try self.allocator.dupeZ(u8, query);
        defer self.allocator.free(z_query);
        const z_session = if (session) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (z_session) |value| self.allocator.free(value);
        const z_prompt = try self.allocator.dupeZ(u8, current_prompt);
        defer self.allocator.free(z_prompt);

        if (c.sqlite3_bind_text(stmt, 1, z_query.ptr, @as(c_int, @intCast(query.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (z_session) |value| {
            const session_len = session.?.len;
            if (c.sqlite3_bind_text(stmt, 2, value.ptr, @as(c_int, @intCast(session_len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        } else if (c.sqlite3_bind_null(stmt, 2) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_text(stmt, 3, z_prompt.ptr, @as(c_int, @intCast(current_prompt.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_int(stmt, 4, @as(c_int, @intCast(limit))) != c.SQLITE_OK) return error.SqliteBindFailed;

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;

            const hit_session = try dupeColumnText(allocator, stmt, 0);
            errdefer allocator.free(hit_session);
            const kind = try dupeColumnText(allocator, stmt, 1);
            errdefer allocator.free(kind);
            const body = try dupeColumnText(allocator, stmt, 2);
            errdefer allocator.free(body);
            const score = c.sqlite3_column_double(stmt, 3);
            const created_at_unix_s = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL) null else @as(i64, @intCast(c.sqlite3_column_int64(stmt, 4)));
            try hits.append(allocator, .{ .session = hit_session, .kind = kind, .body = body, .score = score, .created_at_unix_s = created_at_unix_s });
        }

        return hits;
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

pub fn freeSessionSearchHits(allocator: std.mem.Allocator, hits: *std.ArrayList(SessionSearchHit)) void {
    for (hits.items) |*hit| hit.deinit(allocator);
    hits.deinit(allocator);
}

fn buildFtsQuery(allocator: std.mem.Allocator, terms: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, terms, " \t\r\n\"'`()[]{}<>:;,!?/\\|+=*&^%$#@~");
    var first = true;
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, ".-_");
        if (token.len == 0) continue;
        if (!first) try out.appendSlice(allocator, " OR ");
        first = false;
        try out.appendSlice(allocator, "body:");
        try out.append(allocator, '"');
        for (token) |byte| {
            if (byte == '"') try out.append(allocator, '"');
            try out.append(allocator, byte);
        }
        try out.appendSlice(allocator, "\"*");
    }
    return out.toOwnedSlice(allocator);
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

test "tool event audit summary stores metadata without raw output" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    const range = @import("tools.zig").FileRange{
        .path = try std.testing.allocator.dupe(u8, "README.md"),
        .start_line = 1,
        .end_line = 1,
        .total_lines = 1,
        .hash = 0,
        .text = try std.testing.allocator.dupe(u8, "VISIBLE\nSECRET_RAW_TAIL\n"),
    };
    defer range.deinit(std.testing.allocator);
    const event = try tool_event.ToolEvent.fromFileRange(std.testing.allocator, "collect_evidence", "strategy=path", range);
    defer event.deinit(std.testing.allocator);

    try db.recordToolEventSummary("s1", event);

    var events = try db.loadSessionEvents(std.testing.allocator, "s1", 20);
    defer freeAuditEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("tool_event", events.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "raw_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "raw_hash=") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "SECRET_RAW_TAIL") == null);
}

test "recent session events keep newest events in chronological order" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("s1", "turn_start", "old");
    try db.recordEvent("s1", "assistant_delta", "middle");
    try db.recordEvent("s1", "turn_start", "new");

    var events = try db.loadRecentSessionEvents(std.testing.allocator, "s1", 2);
    defer freeAuditEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("middle", events.items[0].body);
    try std.testing.expectEqualStrings("new", events.items[1].body);
}

test "session fts searches body by session and excludes current prompt" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("s1", "turn_start", "renderer append-only deve preservar copia direta");
    try db.recordEvent("s1", "assistant_delta", "acordo registrado sobre renderer append-only");
    try db.recordEvent("s1", "turn_start", "renderer append-only pergunta atual");
    try db.recordEvent("s2", "assistant_delta", "renderer append-only outra sessao");
    try db.recordEvent("s1", "model_context", "renderer append-only raw operational wrapper");
    try db.recordEvent("s1", "turn_start", "body sem termo alvo");

    var hits = try db.searchSessionEventsFts(std.testing.allocator, "s1", "renderer append-only", "renderer append-only pergunta atual", 10);
    defer freeSessionSearchHits(std.testing.allocator, &hits);

    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    for (hits.items) |hit| {
        try std.testing.expectEqualStrings("s1", hit.session);
        try std.testing.expect(std.mem.indexOf(u8, hit.body, "pergunta atual") == null);
        try std.testing.expect(std.mem.indexOf(u8, hit.body, "outra sessao") == null);
        try std.testing.expect(!std.mem.eql(u8, hit.kind, "model_context"));
    }
}

test "session fts does not match operational kind metadata" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("s1", "turn_start", "conteudo neutro");

    var hits = try db.searchSessionEventsFts(std.testing.allocator, "s1", "turn_start", "prompt atual", 10);
    defer freeSessionSearchHits(std.testing.allocator, &hits);

    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "session fts can search all sessions when the model asks for global recall" {
    var db = try AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("old-session", "turn_start", "falamos de w-90 bootstrap layout");
    try db.recordEvent("tool-noise", "tool_start", "search_session scope=all session= terms=w-90 bootstrap");
    try db.recordEvent("current-session", "turn_start", "pergunta atual sobre outro assunto");

    var hits = try db.searchAllSessionEventsFts(std.testing.allocator, "w-90 bootstrap", "prompt atual", 10);
    defer freeSessionSearchHits(std.testing.allocator, &hits);

    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqualStrings("old-session", hits.items[0].session);
    try std.testing.expect(std.mem.indexOf(u8, hits.items[0].body, "w-90 bootstrap") != null);
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
