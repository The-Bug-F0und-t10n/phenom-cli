const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const symbol_ranker = @import("symbol_ranker.zig");
const workspace_inventory = @import("workspace_inventory.zig");

const max_indexed_files: usize = 512;
const max_file_bytes: usize = 128 * 1024;
const max_symbol_lines: usize = 96;
const max_terms: usize = 24;

pub const Candidate = struct {
    path: []u8,
    symbol: []u8,
    start_line: usize,
    end_line: usize,
    score: i32,
    relation_count: usize,
    direct_symbol_match: bool,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.symbol);
    }
};

pub const Result = struct {
    candidates: std.ArrayList(Candidate),
    indexed_files: usize,
    nodes: usize,
    edges: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |candidate| candidate.deinit(allocator);
        self.candidates.deinit(allocator);
    }
};

const Symbol = struct {
    id: usize,
    path: []u8,
    name: []u8,
    signature: []u8,
    start_line: usize,
    end_line: usize,

    fn deinit(self: Symbol, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        allocator.free(self.signature);
    }
};

const Edge = struct {
    src: usize,
    dst: usize,
    kind: EdgeKind,
};

const EdgeKind = enum {
    calls,
    imports,
};

const Term = struct {
    text: []const u8,
};

pub fn rank(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    max_candidates: usize,
) !Result {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);
    try exec(allocator, db,
        \\create table nodes(id integer primary key, kind text not null, path text not null, name text not null, line integer not null, end_line integer not null);
        \\create table edges(kind text not null, src integer not null, dst integer not null);
    );

    var symbols = std.ArrayList(Symbol).empty;
    defer {
        for (symbols.items) |symbol| symbol.deinit(allocator);
        symbols.deinit(allocator);
    }
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);

    const indexed = try indexWorkspace(allocator, io, db, &symbols);
    try collectEdges(allocator, io, db, symbols.items, &edges);

    var candidates = std.ArrayList(Candidate).empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var terms_buf: [max_terms]Term = undefined;
    const terms = terms_buf[0..extractTerms(query, &terms_buf)];
    for (symbols.items) |symbol| {
        const scored = scoreSymbol(symbol, terms, edges.items);
        if (scored.score == 0) continue;
        try appendCandidate(allocator, &candidates, symbol, scored.score, relationCount(symbol.id, edges.items), scored.direct_symbol_match);
    }

    addImmediateNeighbors(allocator, &candidates, symbols.items, edges.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
    sortCandidates(candidates.items);
    trimCandidates(allocator, &candidates, max_candidates);

    return .{
        .candidates = candidates,
        .indexed_files = indexed,
        .nodes = symbols.items.len,
        .edges = edges.items.len,
    };
}

fn indexWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*c.sqlite3,
    symbols: *std.ArrayList(Symbol),
) !usize {
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var inventory = try workspace_inventory.collect(allocator, io, max_indexed_files * 4);
    defer inventory.deinit(allocator);

    var indexed: usize = 0;
    for (inventory.paths.items) |path| {
        if (indexed >= max_indexed_files) break;
        const content = cwd.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch continue;
        defer allocator.free(content);
        if (!workspace_inventory.isTextBytes(content)) continue;
        indexed += 1;
        try collectFileSymbols(allocator, db, symbols, path, content);
    }
    return indexed;
}

fn collectFileSymbols(
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    symbols: *std.ArrayList(Symbol),
    path: []const u8,
    content: []const u8,
) !void {
    var offset: usize = 0;
    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        defer {
            offset += line.len + 1;
            line_no += 1;
        }
        const symbol = parseSymbolLine(path, line, line_no, content[offset..]) orelse continue;
        const id = symbols.items.len + 1;
        var owned = Symbol{
            .id = id,
            .path = try allocator.dupe(u8, symbol.path),
            .name = try allocator.dupe(u8, symbol.name),
            .signature = try allocator.dupe(u8, symbol.signature),
            .start_line = symbol.start_line,
            .end_line = symbol.end_line,
        };
        errdefer owned.deinit(allocator);
        try insertNode(allocator, db, owned);
        try symbols.append(allocator, owned);
    }
}

const ParsedSymbol = struct {
    path: []const u8,
    name: []const u8,
    signature: []const u8,
    start_line: usize,
    end_line: usize,
};

fn parseSymbolLine(path: []const u8, line: []const u8, line_no: usize, tail: []const u8) ?ParsedSymbol {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var text = stripPrefix(trimmed, "pub ") orelse trimmed;
    text = stripPrefix(text, "export ") orelse text;
    if (stripPrefix(text, "fn ")) |rest| return parsed(path, takeIdentifier(rest), trimmed, line_no, tail);
    if (stripPrefix(text, "const ")) |rest| {
        const name = takeIdentifier(rest);
        if (name.len == 0) return null;
        const after_name = std.mem.trim(u8, rest[name.len..], " \t");
        if (std.mem.startsWith(u8, after_name, "= @import(") or std.mem.startsWith(u8, after_name, "= @cImport(")) return null;
        return parsed(path, name, trimmed, line_no, tail);
    }
    if (stripPrefix(text, "function ")) |rest| return parsed(path, takeIdentifier(rest), trimmed, line_no, tail);
    if (stripPrefix(text, "class ")) |rest| return parsed(path, takeIdentifier(rest), trimmed, line_no, tail);
    return null;
}

fn parsed(path: []const u8, name: []const u8, signature: []const u8, line_no: usize, tail: []const u8) ?ParsedSymbol {
    if (name.len == 0) return null;
    return .{ .path = path, .name = name, .signature = signature, .start_line = line_no, .end_line = estimateEndLine(line_no, tail) };
}

fn collectEdges(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*c.sqlite3,
    symbols: []const Symbol,
    edges: *std.ArrayList(Edge),
) !void {
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var current_path: []const u8 = "";
    var content: []u8 = "";
    defer if (content.len > 0) allocator.free(content);
    var import_paths = std.ArrayList([]u8).empty;
    defer {
        for (import_paths.items) |path| allocator.free(path);
        import_paths.deinit(allocator);
    }

    for (symbols) |src| {
        if (!std.mem.eql(u8, current_path, src.path)) {
            if (content.len > 0) allocator.free(content);
            for (import_paths.items) |path| allocator.free(path);
            import_paths.clearRetainingCapacity();
            content = cwd.readFileAlloc(io, src.path, allocator, .limited(max_file_bytes)) catch {
                content = "";
                current_path = src.path;
                continue;
            };
            current_path = src.path;
            try collectImportTargets(allocator, src.path, content, &import_paths);
        }
        const body = sliceLines(content, src.start_line, src.end_line);
        if (firstSymbolForPath(symbols, src.path)) |module_symbol| {
            if (module_symbol.id == src.id) {
                for (import_paths.items) |target_path| {
                    const imported = firstSymbolForPath(symbols, target_path) orelse continue;
                    try appendEdge(allocator, db, edges, .{ .src = src.id, .dst = imported.id, .kind = .imports });
                }
            }
        }
        for (symbols) |dst| {
            if (src.id == dst.id) continue;
            if (!std.mem.eql(u8, src.path, dst.path)) continue;
            if (containsCall(body, dst.name)) {
                try appendEdge(allocator, db, edges, .{ .src = src.id, .dst = dst.id, .kind = .calls });
            }
        }
    }
}

fn collectImportTargets(allocator: std.mem.Allocator, current_path: []const u8, content: []const u8, out: *std.ArrayList([]u8)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, "@import(\"")) |idx| {
            const path_start = idx + "@import(\"".len;
            const path_end = std.mem.indexOfScalarPos(u8, line, path_start, '"') orelse break;
            const raw = line[path_start..path_end];
            start = path_end + 1;
            if (!std.mem.endsWith(u8, raw, ".zig")) continue;
            const target = try resolveImportPath(allocator, current_path, raw);
            errdefer allocator.free(target);
            if (!workspace_inventory.isWorkspacePath(target)) {
                allocator.free(target);
                continue;
            }
            if (containsOwnedPath(out.items, target)) {
                allocator.free(target);
                continue;
            }
            try out.append(allocator, target);
        }
    }
}

fn resolveImportPath(allocator: std.mem.Allocator, current_path: []const u8, raw: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, raw, "./") or std.mem.startsWith(u8, raw, "../")) {
        const slash = std.mem.lastIndexOfScalar(u8, current_path, '/') orelse return normalizeRelativePath(allocator, raw);
        const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path[0..slash], raw });
        defer allocator.free(joined);
        return normalizeRelativePath(allocator, joined);
    }
    if (std.mem.indexOfScalar(u8, raw, '/') != null) return allocator.dupe(u8, raw);
    const slash = std.mem.lastIndexOfScalar(u8, current_path, '/') orelse return allocator.dupe(u8, raw);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path[0..slash], raw });
}

fn normalizeRelativePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return allocator.dupe(u8, path);
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    return std.mem.join(allocator, "/", parts.items);
}

fn containsOwnedPath(paths: []const []u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

fn appendEdge(allocator: std.mem.Allocator, db: ?*c.sqlite3, edges: *std.ArrayList(Edge), edge: Edge) !void {
    for (edges.items) |existing| {
        if (existing.src == edge.src and existing.dst == edge.dst and existing.kind == edge.kind) return;
    }
    try insertEdge(allocator, db, edge);
    try edges.append(allocator, edge);
}

fn insertNode(allocator: std.mem.Allocator, db: ?*c.sqlite3, symbol: Symbol) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "insert into nodes(id, kind, path, name, line, end_line) values (?1, 'symbol', ?2, ?3, ?4, ?5)";
    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    if (c.sqlite3_prepare_v2(db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, @as(i64, @intCast(symbol.id))) != c.SQLITE_OK) return error.SqliteBindFailed;
    try bindText(allocator, stmt, 2, symbol.path);
    try bindText(allocator, stmt, 3, symbol.name);
    if (c.sqlite3_bind_int64(stmt, 4, @as(i64, @intCast(symbol.start_line))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_bind_int64(stmt, 5, @as(i64, @intCast(symbol.end_line))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn insertEdge(allocator: std.mem.Allocator, db: ?*c.sqlite3, edge: Edge) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "insert into edges(kind, src, dst) values (?1, ?2, ?3)";
    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    if (c.sqlite3_prepare_v2(db, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(allocator, stmt, 1, @tagName(edge.kind));
    if (c.sqlite3_bind_int64(stmt, 2, @as(i64, @intCast(edge.src))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_bind_int64(stmt, 3, @as(i64, @intCast(edge.dst))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn bindText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    _ = allocator;
    if (c.sqlite3_bind_text(stmt, index, text.ptr, @as(c_int, @intCast(text.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
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

const SymbolScore = struct {
    score: i32,
    direct_symbol_match: bool,
};

fn scoreSymbol(symbol: Symbol, terms: []const Term, edges: []const Edge) SymbolScore {
    var score: i32 = 0;
    var direct_symbol_match = false;
    for (terms, 0..) |term, index| {
        const weight: i32 = if (index < 3) 2 else 1;
        if (std.ascii.eqlIgnoreCase(symbol.name, term.text)) {
            direct_symbol_match = true;
            score += 180 * weight;
        }
        if (containsIgnoreCase(symbol.name, term.text)) {
            direct_symbol_match = true;
            score += 90 * weight;
        }
        if (containsIgnoreCase(symbol.path, term.text)) score += 52 * weight;
        const symbol_token_score = symbol_ranker.tokenizedIdentifierMatchScore(symbol.name, term.text, 20, 5);
        if (symbol_token_score > 0) direct_symbol_match = true;
        score += @as(i32, @intCast(symbol_token_score)) * weight;
        score += @as(i32, @intCast(symbol_ranker.tokenizedIdentifierMatchScore(symbol.path, term.text, 8, 2))) * weight;
    }
    if (score == 0) return .{ .score = 0, .direct_symbol_match = false };
    if (direct_symbol_match) {
        score += 480;
        score += @as(i32, @intCast(@min(relationCount(symbol.id, edges) * 8, 64)));
    } else {
        score = @divTrunc(score, 2);
    }
    return .{ .score = score, .direct_symbol_match = direct_symbol_match };
}

fn addImmediateNeighbors(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    symbols: []const Symbol,
    edges: []const Edge,
) !void {
    const original_len = candidates.items.len;
    var index: usize = 0;
    while (index < original_len) : (index += 1) {
        const candidate = candidates.items[index];
        const seed = symbolByPathAndName(symbols, candidate.path, candidate.symbol) orelse continue;
        for (edges) |edge| {
            const neighbor_id = if (edge.src == seed.id) edge.dst else if (edge.dst == seed.id) edge.src else continue;
            const neighbor = symbolById(symbols, neighbor_id) orelse continue;
            try appendCandidate(allocator, candidates, neighbor, @max(@as(i32, 40), @divTrunc(candidate.score, 2)), relationCount(neighbor.id, edges), false);
        }
    }
}

fn appendCandidate(allocator: std.mem.Allocator, out: *std.ArrayList(Candidate), symbol: Symbol, score: i32, relations: usize, direct_symbol_match: bool) !void {
    for (out.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, symbol.path) or !std.mem.eql(u8, existing.symbol, symbol.name)) continue;
        existing.score = @max(existing.score, score);
        existing.relation_count = @max(existing.relation_count, relations);
        existing.direct_symbol_match = existing.direct_symbol_match or direct_symbol_match;
        return;
    }
    try out.append(allocator, .{
        .path = try allocator.dupe(u8, symbol.path),
        .symbol = try allocator.dupe(u8, symbol.name),
        .start_line = symbol.start_line,
        .end_line = symbol.end_line,
        .score = score,
        .relation_count = relations,
        .direct_symbol_match = direct_symbol_match,
    });
}

fn extractTerms(query: []const u8, out: []Term) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n\"'`()[]{}<>:;,.!?/\\|");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, "-_*");
        if (term.len < 3 or count >= out.len) continue;
        out[count] = .{ .text = term };
        count += 1;
    }
    return count;
}

fn relationCount(id: usize, edges: []const Edge) usize {
    var count: usize = 0;
    for (edges) |edge| {
        if (edge.src == id or edge.dst == id) count += 1;
    }
    return count;
}

fn symbolById(symbols: []const Symbol, id: usize) ?Symbol {
    for (symbols) |symbol| {
        if (symbol.id == id) return symbol;
    }
    return null;
}

fn firstSymbolForPath(symbols: []const Symbol, path: []const u8) ?Symbol {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.path, path)) return symbol;
    }
    return null;
}

fn symbolByPathAndName(symbols: []const Symbol, path: []const u8, name: []const u8) ?Symbol {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.path, path) and std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn containsCall(body: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, body, start, name)) |idx| {
        const after = idx + name.len;
        if (after < body.len and body[after] == '(' and (idx == 0 or !isIdentByte(body[idx - 1]))) return true;
        start = after;
    }
    return false;
}

fn sliceLines(content: []const u8, start_line: usize, end_line: usize) []const u8 {
    var line_no: usize = 1;
    var start: usize = 0;
    var end: usize = content.len;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (line_no == start_line) {
            start = i;
            break;
        }
        if (content[i] == '\n') line_no += 1;
    }
    while (i < content.len) : (i += 1) {
        if (line_no > end_line) {
            end = i;
            break;
        }
        if (content[i] == '\n') line_no += 1;
    }
    return content[start..end];
}

fn sortCandidates(candidates: []Candidate) void {
    std.mem.sort(Candidate, candidates, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.relation_count != b.relation_count) return a.relation_count > b.relation_count;
            if (!std.mem.eql(u8, a.path, b.path)) return std.mem.lessThan(u8, a.path, b.path);
            return a.start_line < b.start_line;
        }
    }.lessThan);
}

fn trimCandidates(allocator: std.mem.Allocator, candidates: *std.ArrayList(Candidate), max: usize) void {
    while (candidates.items.len > max) {
        const removed = candidates.pop().?;
        removed.deinit(allocator);
    }
}

fn estimateEndLine(start_line: usize, tail: []const u8) usize {
    var line: usize = start_line;
    var seen_open = false;
    var depth: isize = 0;
    for (tail) |byte| {
        if (byte == '\n') line += 1;
        if (byte == '{') {
            seen_open = true;
            depth += 1;
        } else if (byte == '}') {
            depth -= 1;
            if (seen_open and depth <= 0) return @min(line, start_line + max_symbol_lines - 1);
        }
        if (line >= start_line + max_symbol_lines - 1) return line;
    }
    return @min(line, start_line + max_symbol_lines - 1);
}

fn stripPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

fn takeIdentifier(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and isIdentByte(text[end])) : (end += 1) {}
    return text[0..end];
}

fn isIdentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "caveman graph ranks symbols and saves relations in sqlite" {
    var result = try rank(std.testing.allocator, std.testing.io, "collect evidence candidates execute", 16);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.indexed_files > 0);
    try std.testing.expect(result.nodes > 0);
    try std.testing.expect(result.edges > 0);
    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expect(hasCandidate(result.candidates.items, "src/collect_evidence.zig", "executeCandidates"));
}

test "caveman graph keeps direct symbol match above structural neighbors" {
    var result = try rank(std.testing.allocator, std.testing.io, "executeCandidates", 6);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expectEqualStrings("src/collect_evidence.zig", result.candidates.items[0].path);
    try std.testing.expectEqualStrings("executeCandidates", result.candidates.items[0].symbol);
}

test "caveman graph resolves local zig imports" {
    var imports = std.ArrayList([]u8).empty;
    defer {
        for (imports.items) |path| std.testing.allocator.free(path);
        imports.deinit(std.testing.allocator);
    }

    try collectImportTargets(std.testing.allocator, "src/main.zig", "const audit = @import(\"audit.zig\");\nconst http = @import(\"./http.zig\");\nconst cfg = @import(\"../config.zig\");\nconst std = @import(\"std\");\n", &imports);
    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    try std.testing.expectEqualStrings("src/audit.zig", imports.items[0]);
    try std.testing.expectEqualStrings("src/http.zig", imports.items[1]);
    try std.testing.expectEqualStrings("config.zig", imports.items[2]);
}

fn hasCandidate(candidates: []const Candidate, path: []const u8, symbol: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.path, path) and std.mem.eql(u8, candidate.symbol, symbol)) return true;
    }
    return false;
}
