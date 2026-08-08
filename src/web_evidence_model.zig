const std = @import("std");

pub const SourceRef = struct {
    url: []const u8,
    domain: []const u8 = "",
    quality_score: ?u8 = null,
    quality_reason: []const u8 = "",
};

pub const EvidenceEntry = struct {
    source: []const u8 = "http_get",
    raw_context_persisted: bool = false,
    distill: []const u8,
    target: []const u8,
    retrieved_at: []const u8 = "",
    timezone: []const u8 = "UTC",
    status: []const u8,
    server: []const u8 = "",
    @"error": []const u8 = "",
    query: []const u8 = "",
    title: []const u8 = "",
    sources: []const SourceRef = &.{},
    excerpt_budget_bytes: usize,
    excerpt: []const u8,
};

pub const Claim = struct {
    text: []const u8,

    pub fn validate(self: Claim) !void {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) return error.EmptyClaim;
    }
};

pub const ClaimSupport = struct {
    claim_index: usize,
    evidence_index: usize,
    source_index: usize,
    excerpt: []const u8,

    pub fn validate(self: ClaimSupport) !void {
        _ = self.claim_index;
        _ = self.evidence_index;
        _ = self.source_index;
        if (std.mem.trim(u8, self.excerpt, " \t\r\n").len == 0) return error.EmptyClaimSupport;
    }
};

pub const ParsedEvidenceEntry = struct {
    block: []const u8,
    source: []const u8 = "",
    distill: []const u8 = "",
    target: []const u8 = "",
    retrieved_at: []const u8 = "",
    timezone: []const u8 = "",
    status: []const u8 = "",
    server: []const u8 = "",
    @"error": []const u8 = "",
    query: []const u8 = "",
    title: []const u8 = "",
    source_domain: []const u8 = "",
    source_quality_score: ?u8 = null,
    source_quality_reason: []const u8 = "",
    excerpt_budget_bytes: ?usize = null,
    excerpt: ?[]const u8 = null,

    pub fn sourceIterator(self: ParsedEvidenceEntry) SourceIterator {
        return .{
            .text = self.block,
            .fallback_domain = self.source_domain,
            .fallback_quality_score = self.source_quality_score,
            .fallback_quality_reason = self.source_quality_reason,
        };
    }
};

pub const EntryIterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn next(self: *EntryIterator) ?ParsedEvidenceEntry {
        const marker = "[WEB_EVIDENCE]";
        const start = std.mem.indexOfPos(u8, self.text, self.cursor, marker) orelse return null;
        const body_start = start + marker.len;
        const end = std.mem.indexOfPos(u8, self.text, body_start, marker) orelse self.text.len;
        self.cursor = end;
        return parseBlock(self.text[start..end]);
    }
};

pub const SourceIterator = struct {
    text: []const u8,
    cursor: usize = 0,
    fallback_domain: []const u8 = "",
    fallback_quality_score: ?u8 = null,
    fallback_quality_reason: []const u8 = "",

    pub fn next(self: *SourceIterator) ?SourceRef {
        while (self.cursor < self.text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, self.text, self.cursor, '\n') orelse self.text.len;
            const line = std.mem.trim(u8, self.text[self.cursor..line_end], " \t\r\n");
            self.cursor = if (line_end < self.text.len) line_end + 1 else self.text.len;
            const url = lineValue(line, "source_url") orelse continue;
            const trimmed = std.mem.trim(u8, url, " \t\r\n");
            if (trimmed.len == 0) continue;
            return .{
                .url = trimmed,
                .domain = if (self.fallback_domain.len > 0) self.fallback_domain else urlDomain(trimmed),
                .quality_score = self.fallback_quality_score,
                .quality_reason = self.fallback_quality_reason,
            };
        }
        return null;
    }
};

pub fn iterator(text: []const u8) EntryIterator {
    return .{ .text = text };
}

pub fn hasEvidence(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "[WEB_EVIDENCE]") != null;
}

pub fn parseFirst(text: []const u8) ?ParsedEvidenceEntry {
    var it = iterator(text);
    return it.next();
}

pub fn parseBlock(block: []const u8) ?ParsedEvidenceEntry {
    if (std.mem.indexOf(u8, block, "[WEB_EVIDENCE]") == null) return null;
    var parsed: ParsedEvidenceEntry = .{ .block = block };
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[WEB_EVIDENCE]")) continue;
        if (std.mem.startsWith(u8, trimmed, "source=")) {
            parsed.source = lineValue(trimmed, "source") orelse parsed.source;
            parsed.distill = tokenValue(trimmed, "distill") orelse parsed.distill;
            parsed.target = tokenValue(trimmed, "target") orelse parsed.target;
            continue;
        }
        if (lineValue(trimmed, "target")) |value| parsed.target = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "retrieved_at")) |value| parsed.retrieved_at = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "timezone")) |value| parsed.timezone = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "status")) |value| parsed.status = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "server")) |value| parsed.server = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "error")) |value| parsed.@"error" = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "query")) |value| parsed.query = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "title")) |value| parsed.title = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "source_domain")) |value| parsed.source_domain = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "source_quality_score")) |value| parsed.source_quality_score = std.fmt.parseInt(u8, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
        if (lineValue(trimmed, "source_quality_reason")) |value| parsed.source_quality_reason = std.mem.trim(u8, value, " \t\r\n");
        if (lineValue(trimmed, "excerpt_budget_bytes")) |value| parsed.excerpt_budget_bytes = std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
        if (lineValue(trimmed, "excerpt")) |value| parsed.excerpt = std.mem.trim(u8, value, " \t\r\n");
    }
    return parsed;
}

pub fn sourceUrlAt(text: []const u8, ordinal: usize) ?[]const u8 {
    if (ordinal == 0) return null;
    var seen: usize = 0;
    var entries = iterator(text);
    while (entries.next()) |entry| {
        var sources = entry.sourceIterator();
        while (sources.next()) |source| {
            seen += 1;
            if (seen == ordinal) return source.url;
        }
    }
    return null;
}

pub fn sourceRefsFromLines(
    allocator: std.mem.Allocator,
    lines_text: []const u8,
    fallback_url: []const u8,
    fallback_domain: []const u8,
    quality_score: u8,
    quality_reason: []const u8,
) ![]SourceRef {
    var refs = std.ArrayList(SourceRef).empty;
    errdefer refs.deinit(allocator);
    var lines = std.mem.splitScalar(u8, lines_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const url = lineValue(trimmed, "source_url") orelse continue;
        const clean = std.mem.trim(u8, url, " \t\r\n");
        if (clean.len == 0) continue;
        try refs.append(allocator, .{
            .url = clean,
            .domain = if (refs.items.len == 0 and fallback_domain.len > 0) fallback_domain else urlDomain(clean),
            .quality_score = quality_score,
            .quality_reason = quality_reason,
        });
    }
    if (refs.items.len == 0 and fallback_domain.len > 0) {
        try refs.append(allocator, .{
            .url = fallback_url,
            .domain = fallback_domain,
            .quality_score = quality_score,
            .quality_reason = quality_reason,
        });
    }
    return refs.toOwnedSlice(allocator);
}

pub fn renderEvidenceBlock(allocator: std.mem.Allocator, entry: EvidenceEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[WEB_EVIDENCE]\n");
    const source_line = try std.fmt.allocPrint(
        allocator,
        "source={s} raw_context_persisted={} distill={s} target={s}\n",
        .{ entry.source, entry.raw_context_persisted, entry.distill, entry.target },
    );
    defer allocator.free(source_line);
    try out.appendSlice(allocator, source_line);
    try appendLine(&out, allocator, "retrieved_at", entry.retrieved_at);
    try appendLine(&out, allocator, "timezone", entry.timezone);
    try appendLine(&out, allocator, "status", entry.status);
    try appendLine(&out, allocator, "server", entry.server);
    try appendLine(&out, allocator, "error", entry.@"error");
    try appendLine(&out, allocator, "query", entry.query);
    try appendLine(&out, allocator, "title", entry.title);
    const primary_source = if (entry.sources.len > 0) entry.sources[0] else SourceRef{ .url = "" };
    try appendLine(&out, allocator, "source_domain", primary_source.domain);
    if (primary_source.quality_score) |score| {
        const text = try std.fmt.allocPrint(allocator, "{}", .{score});
        defer allocator.free(text);
        try appendLine(&out, allocator, "source_quality_score", text);
    } else {
        try appendLine(&out, allocator, "source_quality_score", "");
    }
    try appendLine(&out, allocator, "source_quality_reason", primary_source.quality_reason);
    for (entry.sources) |source| {
        if (source.url.len == 0) continue;
        try appendLine(&out, allocator, "source_url", source.url);
    }
    const budget_text = try std.fmt.allocPrint(allocator, "{}", .{entry.excerpt_budget_bytes});
    defer allocator.free(budget_text);
    try appendLine(&out, allocator, "excerpt_budget_bytes", budget_text);
    try appendLine(&out, allocator, "excerpt", entry.excerpt);
    return out.toOwnedSlice(allocator);
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, value);
    try out.append(allocator, '\n');
}

fn lineValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (line.len < key.len + 1) return null;
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line[key.len] != '=') return null;
    return line[key.len + 1 ..];
}

fn tokenValue(line: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
    while (it.next()) |token| {
        if (token.len < key.len + 1) continue;
        if (!std.mem.startsWith(u8, token, key)) continue;
        if (token[key.len] != '=') continue;
        return token[key.len + 1 ..];
    }
    return null;
}

fn urlDomain(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    var start = scheme_end + "://".len;
    if (start >= url.len) return "";
    const end = std.mem.indexOfAnyPos(u8, url, start, "/?#") orelse url.len;
    var host = url[start..end];
    if (std.mem.indexOfScalar(u8, host, '@')) |at| {
        start += at + 1;
        host = url[start..end];
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    return std.mem.trim(u8, host, " \t\r\n.");
}

test "web evidence render parse round trip keeps multiple sources" {
    const sources = [_]SourceRef{
        .{ .url = "https://example.test/one", .domain = "example.test", .quality_score = 70, .quality_reason = "https_domain" },
        .{ .url = "https://docs.example.test/two", .domain = "docs.example.test", .quality_score = 70, .quality_reason = "https_domain" },
    };
    const rendered = try renderEvidenceBlock(std.testing.allocator, .{
        .distill = "model_summary",
        .target = "https://search.test/?q=zig",
        .retrieved_at = "2026-08-08",
        .status = "200",
        .query = "zig latest",
        .title = "Zig",
        .sources = &sources,
        .excerpt_budget_bytes = 512,
        .excerpt = "Zig release notes.",
    });
    defer std.testing.allocator.free(rendered);

    const parsed = parseFirst(rendered).?;
    try std.testing.expectEqualStrings("model_summary", parsed.distill);
    try std.testing.expectEqualStrings("https://search.test/?q=zig", parsed.target);
    try std.testing.expectEqualStrings("200", parsed.status);
    try std.testing.expectEqualStrings("zig latest", parsed.query);
    try std.testing.expectEqualStrings("Zig release notes.", parsed.excerpt.?);
    try std.testing.expectEqual(@as(?usize, 512), parsed.excerpt_budget_bytes);
    try std.testing.expectEqual(@as(?u8, 70), parsed.source_quality_score);

    var it = parsed.sourceIterator();
    try std.testing.expectEqualStrings("https://example.test/one", it.next().?.url);
    try std.testing.expectEqualStrings("https://docs.example.test/two", it.next().?.url);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqualStrings("https://docs.example.test/two", sourceUrlAt(rendered, 2).?);
}

test "web evidence parser preserves empty excerpt" {
    const parsed = parseFirst("[WEB_EVIDENCE]\nstatus=200\nsource_url=https://empty.test/\nexcerpt=\n").?;
    try std.testing.expect(parsed.excerpt != null);
    try std.testing.expectEqualStrings("", parsed.excerpt.?);
}

test "source refs from legacy lines carry quality fields" {
    const refs = try sourceRefsFromLines(std.testing.allocator, "source_url=https://dados.gov.br/dataset/atlas\n", "", "dados.gov.br", 92, "government_domain");
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("https://dados.gov.br/dataset/atlas", refs[0].url);
    try std.testing.expectEqualStrings("dados.gov.br", refs[0].domain);
    try std.testing.expectEqual(@as(?u8, 92), refs[0].quality_score);
    try std.testing.expectEqualStrings("government_domain", refs[0].quality_reason);
}

test "claims require visible support" {
    try (Claim{ .text = "Zig has a release page." }).validate();
    try (ClaimSupport{ .claim_index = 0, .evidence_index = 0, .source_index = 0, .excerpt = "release page" }).validate();
    try std.testing.expectError(error.EmptyClaim, (Claim{ .text = " \n" }).validate());
    try std.testing.expectError(error.EmptyClaimSupport, (ClaimSupport{ .claim_index = 0, .evidence_index = 0, .source_index = 0, .excerpt = "" }).validate());
}
