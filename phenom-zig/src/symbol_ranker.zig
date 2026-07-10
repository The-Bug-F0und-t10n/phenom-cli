const std = @import("std");

const workspace_inventory = @import("workspace_inventory.zig");

const max_indexed_files: usize = 512;
const max_file_bytes: usize = 128 * 1024;
const max_symbol_lines: usize = 96;
const candidate_headroom: usize = 128;

pub const Candidate = struct {
    path: []u8,
    symbol: []u8,
    start_line: usize,
    end_line: usize,
    score: i32,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.symbol);
    }
};

pub const Result = struct {
    candidates: std.ArrayList(Candidate),
    indexed_files: usize,
    symbol_count: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |candidate| candidate.deinit(allocator);
        self.candidates.deinit(allocator);
    }
};

const Symbol = struct {
    path: []const u8,
    name: []const u8,
    line: usize,
    end_line: usize,
    signature: []const u8,
    top_level: bool,
};

pub fn rank(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    max_candidates: usize,
) !Result {
    var out = std.ArrayList(Candidate).empty;
    errdefer {
        for (out.items) |candidate| candidate.deinit(allocator);
        out.deinit(allocator);
    }

    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var inventory = try workspace_inventory.collect(allocator, io, max_indexed_files * 4);
    defer inventory.deinit(allocator);

    var indexed: usize = 0;
    var symbols: usize = 0;
    for (inventory.paths.items) |path| {
        if (indexed >= max_indexed_files) break;
        const content = cwd.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch continue;
        defer allocator.free(content);
        if (!workspace_inventory.isTextBytes(content)) continue;
        indexed += 1;
        try collectFileSymbols(allocator, &out, path, content, query, max_candidates, &symbols);
    }

    sortCandidates(out.items);
    trimCandidates(allocator, &out, max_candidates);
    return .{ .candidates = out, .indexed_files = indexed, .symbol_count = symbols };
}

fn collectFileSymbols(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Candidate),
    path: []const u8,
    content: []const u8,
    query: []const u8,
    max_candidates: usize,
    symbol_count: *usize,
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
        symbol_count.* += 1;
        const score = scoreSymbol(symbol, query);
        if (score == 0) continue;
        if (out.items.len >= max_candidates * candidate_headroom) continue;
        const owned_path = try allocator.dupe(u8, symbol.path);
        errdefer allocator.free(owned_path);
        const owned_symbol = try allocator.dupe(u8, symbol.name);
        errdefer allocator.free(owned_symbol);
        try out.append(allocator, .{
            .path = owned_path,
            .symbol = owned_symbol,
            .start_line = symbol.line,
            .end_line = symbol.end_line,
            .score = score,
        });
    }
}

fn parseSymbolLine(path: []const u8, line: []const u8, line_no: usize, tail: []const u8) ?Symbol {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const top_level = line.len == trimmed.len;
    if (std.mem.endsWith(u8, path, ".zig")) return parseZigSymbol(path, trimmed, line_no, tail, top_level);
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".js")) return parseJsTsSymbol(path, trimmed, line_no, tail, top_level);
    return null;
}

fn parseZigSymbol(path: []const u8, line: []const u8, line_no: usize, tail: []const u8, top_level: bool) ?Symbol {
    var text = stripPrefix(line, "pub ") orelse line;
    text = stripPrefix(text, "export ") orelse text;
    if (stripPrefix(text, "fn ")) |rest| {
        const name = takeIdentifier(rest);
        if (name.len == 0) return null;
        return .{ .path = path, .name = name, .line = line_no, .end_line = estimateEndLine(line_no, tail), .signature = line, .top_level = top_level };
    }
    if (stripPrefix(text, "const ")) |rest| {
        const name = takeIdentifier(rest);
        if (name.len == 0) return null;
        const after_name = std.mem.trim(u8, rest[name.len..], " \t");
        if (std.mem.startsWith(u8, after_name, "= @import(") or std.mem.startsWith(u8, after_name, "= @cImport(")) return null;
        return .{ .path = path, .name = name, .line = line_no, .end_line = estimateEndLine(line_no, tail), .signature = line, .top_level = top_level };
    }
    return null;
}

fn parseJsTsSymbol(path: []const u8, line: []const u8, line_no: usize, tail: []const u8, top_level: bool) ?Symbol {
    var text = stripPrefix(line, "export ") orelse line;
    text = stripPrefix(text, "default ") orelse text;
    if (stripPrefix(text, "async function ")) |rest| return namedJsSymbol(path, rest, line_no, tail, line, top_level);
    if (stripPrefix(text, "function ")) |rest| return namedJsSymbol(path, rest, line_no, tail, line, top_level);
    if (stripPrefix(text, "class ")) |rest| return namedJsSymbol(path, rest, line_no, tail, line, top_level);
    if (stripPrefix(text, "const ")) |rest| return namedJsSymbol(path, rest, line_no, tail, line, top_level);
    if (stripPrefix(text, "let ")) |rest| return namedJsSymbol(path, rest, line_no, tail, line, top_level);
    if (stripPrefix(text, "var ")) |rest| return namedJsSymbol(path, rest, line_no, tail, line, top_level);
    return null;
}

fn namedJsSymbol(path: []const u8, rest: []const u8, line_no: usize, tail: []const u8, signature: []const u8, top_level: bool) ?Symbol {
    const name = takeIdentifier(rest);
    if (name.len == 0) return null;
    return .{ .path = path, .name = name, .line = line_no, .end_line = estimateEndLine(line_no, tail), .signature = signature, .top_level = top_level };
}

fn scoreSymbol(symbol: Symbol, query: []const u8) i32 {
    var score: i32 = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n\"'`()[]{}<>:;,./\\|");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, "-_*");
        if (term.len < 2) continue;
        if (std.ascii.eqlIgnoreCase(symbol.name, term)) score += @as(i32, @intCast(@min(term.len * 8, 96)));
        if (containsIgnoreCase(symbol.name, term)) {
            score += @as(i32, @intCast(@min(term.len * 5, 48)));
            score += symbolSpecificityBonus(symbol.name, term);
        }
        if (containsIgnoreCase(symbol.signature, term)) score += @as(i32, @intCast(@min(term.len * 3, 30)));
        if (containsIgnoreCase(symbol.path, term)) score += @as(i32, @intCast(@min(term.len * 7, 56)));
        score += @as(i32, @intCast(fuzzyTextMatchScore(symbol.name, term)));
        score += @as(i32, @intCast(fuzzyTextMatchScore(symbol.signature, term) / 2));
        score += @as(i32, @intCast(fuzzyTextMatchScore(symbol.path, term)));
    }
    if (score > 0 and symbol.top_level) score += 80;
    return score;
}

fn symbolSpecificityBonus(symbol_name: []const u8, term: []const u8) i32 {
    if (symbol_name.len <= term.len) return 0;
    return @as(i32, @intCast(@min(symbol_name.len - term.len, 24)));
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

fn sortCandidates(candidates: []Candidate) void {
    std.mem.sort(Candidate, candidates, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.score != b.score) return a.score > b.score;
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

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fuzzyTextMatchScore(haystack: []const u8, term: []const u8) usize {
    if (term.len < 5 or haystack.len < 5) return 0;
    const common = longestAsciiFoldedTermPrefixInHaystack(haystack, term);
    if (common < 5) return 0;
    return common * 6;
}

fn longestAsciiFoldedTermPrefixInHaystack(haystack: []const u8, term: []const u8) usize {
    var best: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        var term_start: usize = 0;
        while (term_start < term.len) : (term_start += 1) {
            var n: usize = 0;
            while (i + n < haystack.len and term_start + n < term.len and std.ascii.toLower(haystack[i + n]) == std.ascii.toLower(term[term_start + n])) : (n += 1) {}
            if (term_start > 0 and n < 6) continue;
            best = @max(best, n);
        }
    }
    return best;
}

test "symbol ranker finds zig container symbols" {
    var result = try rank(std.testing.allocator, std.testing.io, "AppendOnlyRenderer", 5);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.indexed_files > 0);
    try std.testing.expect(result.symbol_count > 0);
    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expectEqualStrings("src/render.zig", result.candidates.items[0].path);
}

test "symbol parser extracts js ts declarations" {
    const symbol = parseJsTsSymbol("x.ts", "export async function runToolLoop() {", 7, "{\n}\n", true) orelse return error.NoSymbol;
    try std.testing.expectEqualStrings("runToolLoop", symbol.name);
    try std.testing.expectEqual(@as(usize, 7), symbol.line);
    try std.testing.expect(symbol.top_level);
}

test "symbol ranker uses generic fuzzy definition matching" {
    var result = try rank(std.testing.allocator, std.testing.io, "renderizacao cli projeto", 5);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expectEqualStrings("src/render.zig", result.candidates.items[0].path);
}
