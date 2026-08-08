const std = @import("std");

const text_match = @import("text_match.zig");
const web_evidence_model = @import("web_evidence_model.zig");

pub const Decision = enum {
    accept,
    repair_empty_evidence,
    repair_unsupported_claim,
    append_missing_source,
};

pub const Verdict = struct {
    decision: Decision,
    support: ?web_evidence_model.ClaimSupport = null,
};

pub fn verifyWebFinalAnswer(output: []const u8, context: []const u8) Verdict {
    if (std.mem.indexOf(u8, context, "[WEB_DOSSIER v1]") == null) return .{ .decision = .accept };
    if (std.mem.trim(u8, output, " \t\r\n").len == 0) return .{ .decision = .accept };
    if (webDossierHasOnlyEmptyExcerpts(context)) return .{ .decision = .repair_empty_evidence };
    if (findDossierSupport(output, context) == null) return .{ .decision = .repair_unsupported_claim };
    if (webAnswerMissingCollectedSource(output, context)) return .{ .decision = .append_missing_source };
    return .{ .decision = .accept, .support = findDossierSupport(output, context) };
}

pub fn webAnswerMissingCollectedSource(output: []const u8, context: []const u8) bool {
    var lines = std.mem.splitScalar(u8, context, '\n');
    var has_source = false;
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed_line, "source_url=")) continue;
        var source_buf: [2048]u8 = undefined;
        const source = normalizeCollectedSourceUrl(&source_buf, trimmed_line["source_url=".len..]) orelse continue;
        if (sourceUrlIsDuckDuckGoSearchPage(source)) continue;
        has_source = true;
        if (outputContainsCollectedSourceUrl(output, source)) return false;
    }
    return has_source;
}

pub fn webAnswerMissingDossierSupport(output: []const u8, context: []const u8) bool {
    const verdict = verifyWebFinalAnswer(output, context);
    return verdict.decision == .repair_empty_evidence or verdict.decision == .repair_unsupported_claim;
}

pub fn findDossierSupport(output: []const u8, context: []const u8) ?web_evidence_model.ClaimSupport {
    if (std.mem.indexOf(u8, context, "[WEB_DOSSIER v1]") == null) return null;
    if (std.mem.trim(u8, output, " \t\r\n").len == 0) return null;

    var matches: usize = 0;
    var evidence_index: usize = 0;
    var output_without_urls_buf: [8192]u8 = undefined;
    const supported_output = webAnswerTextWithoutUrls(&output_without_urls_buf, output);
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (webDossierEntryIndex(trimmed)) |idx| evidence_index = idx;
        if (!std.mem.startsWith(u8, trimmed, "excerpt=")) continue;
        const excerpt = std.mem.trim(u8, trimmed["excerpt=".len..], " \t\r\n");
        if (excerpt.len == 0) continue;
        if (webDossierExcerptLooksMetadataOnly(excerpt)) continue;
        var terms = std.mem.tokenizeAny(u8, excerpt, " \t\r\n\"'`()[]{}<>:;,./\\|+-=*");
        while (terms.next()) |raw| {
            const term = std.mem.trim(u8, raw, " \t\r\n\"'`()[]{}<>:;,./\\|+-=*");
            if (!webDossierTermIsUseful(term)) continue;
            if (!text_match.containsFoldedIgnoreCase(supported_output, term)) continue;
            if (webDossierTermIsStrong(term)) {
                return .{ .claim_index = 0, .evidence_index = evidence_index, .source_index = 0, .excerpt = excerpt };
            }
            matches += 1;
            if (matches >= 2) {
                return .{ .claim_index = 0, .evidence_index = evidence_index, .source_index = 0, .excerpt = excerpt };
            }
        }
    }
    return null;
}

pub fn webDossierExcerptLooksMetadataOnly(excerpt: []const u8) bool {
    return std.mem.indexOf(u8, excerpt, "page_title=") != null or
        std.mem.indexOf(u8, excerpt, "meta=page_title:") != null or
        std.mem.indexOf(u8, excerpt, "structured_data=page_title:") != null or
        std.mem.indexOf(u8, excerpt, "table_row=page_title:") != null;
}

pub fn appendCollectedWebSources(allocator: std.mem.Allocator, output: []const u8, context: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, std.mem.trimEnd(u8, output, " \t\r\n"));

    var sources = std.ArrayList(u8).empty;
    defer sources.deinit(allocator);
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed_line, "source_url=")) continue;
        var source_buf: [2048]u8 = undefined;
        const source = normalizeCollectedSourceUrl(&source_buf, trimmed_line["source_url=".len..]) orelse continue;
        if (sourceUrlIsDuckDuckGoSearchPage(source) or std.mem.indexOf(u8, sources.items, source) != null) continue;
        try sources.appendSlice(allocator, "- ");
        try sources.appendSlice(allocator, source);
        try sources.append(allocator, '\n');
    }
    if (sources.items.len > 0) {
        try out.appendSlice(allocator, "\n\nSources:\n");
        try out.appendSlice(allocator, sources.items);
    }
    return out.toOwnedSlice(allocator);
}

fn webDossierHasOnlyEmptyExcerpts(context: []const u8) bool {
    var saw_evidence = false;
    var saw_empty = false;
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (webDossierEntryIndex(trimmed) != null) saw_evidence = true;
        if (std.mem.startsWith(u8, trimmed, "- W") and (std.mem.indexOf(u8, trimmed, "empty_excerpt") != null or std.mem.indexOf(u8, trimmed, "missing_excerpt") != null)) {
            saw_evidence = true;
            saw_empty = true;
        }
        if (!std.mem.startsWith(u8, trimmed, "excerpt=")) continue;
        saw_evidence = true;
        const excerpt = std.mem.trim(u8, trimmed["excerpt=".len..], " \t\r\n");
        if (excerpt.len > 0) return false;
        saw_empty = true;
    }
    return saw_evidence and saw_empty;
}

fn webDossierEntryIndex(line: []const u8) ?usize {
    if (line.len < 3 or line[0] != 'W') return null;
    var end: usize = 1;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == 1 or end >= line.len or line[end] != ':') return null;
    return std.fmt.parseInt(usize, line[1..end], 10) catch null;
}

fn webAnswerTextWithoutUrls(buf: []u8, text: []const u8) []const u8 {
    var out_len: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len and out_len < buf.len) {
        if (std.mem.startsWith(u8, text[cursor..], "http://") or std.mem.startsWith(u8, text[cursor..], "https://")) {
            while (cursor < text.len and !std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
            continue;
        }
        buf[out_len] = text[cursor];
        out_len += 1;
        cursor += 1;
    }
    return buf[0..out_len];
}

fn webDossierTermIsUseful(term: []const u8) bool {
    if (std.mem.startsWith(u8, term, "http")) return false;
    if (webDossierTermIsStrong(term)) return true;
    if (term.len < 4) return false;
    var useful = false;
    for (term) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte >= 0x80 or byte == '_') {
            useful = true;
            break;
        }
    }
    return useful;
}

fn webDossierTermIsStrong(term: []const u8) bool {
    if (std.mem.indexOfScalar(u8, term, '_') != null) return true;
    var has_digit = false;
    var has_alpha = false;
    for (term) |byte| {
        has_digit = has_digit or std.ascii.isDigit(byte);
        has_alpha = has_alpha or std.ascii.isAlphabetic(byte);
    }
    return has_digit and has_alpha;
}

fn normalizeCollectedSourceUrl(buf: []u8, raw: []const u8) ?[]const u8 {
    const trimmed = trimSourceUrlBoundary(raw);
    var len: usize = 0;
    for (trimmed) |byte| {
        if (std.ascii.isWhitespace(byte) or byte == '`') continue;
        if (len == buf.len) return null;
        buf[len] = byte;
        len += 1;
    }
    const normalized = trimSourceUrlBoundary(buf[0..len]);
    if (!isHttpTarget(normalized)) return null;
    return normalized;
}

fn trimSourceUrlBoundary(raw: []const u8) []const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n`'\"<>()[]{}");
    while (text.len > 0 and isTrailingSourceUrlPunctuation(text[text.len - 1])) {
        text = text[0 .. text.len - 1];
    }
    return text;
}

fn isTrailingSourceUrlPunctuation(byte: u8) bool {
    return byte == '.' or byte == ',' or byte == ';' or byte == ':' or byte == ')' or byte == ']' or byte == '}';
}

fn sourceUrlIsDuckDuckGoSearchPage(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "://html.duckduckgo.com/html/") != null;
}

fn outputContainsCollectedSourceUrl(output: []const u8, source: []const u8) bool {
    if (std.mem.indexOf(u8, output, source) != null) return true;
    var cursor: usize = 0;
    while (cursor < output.len) : (cursor += 1) {
        var output_idx = cursor;
        var source_idx: usize = 0;
        while (output_idx < output.len and source_idx < source.len) {
            const byte = output[output_idx];
            if (std.ascii.isWhitespace(byte) or byte == '`') {
                output_idx += 1;
                continue;
            }
            if (byte != source[source_idx]) break;
            output_idx += 1;
            source_idx += 1;
        }
        if (source_idx == source.len) return true;
    }
    return false;
}

fn isHttpTarget(target: []const u8) bool {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://");
}

test "web final verifier repairs empty unsupported and missing source cases" {
    const context =
        \\[WEB_DOSSIER v1]
        \\W1:
        \\source_url=https://example.test/r36s
        \\excerpt=Console R36S usa RK3326 e 1GB RAM.
    ;
    try std.testing.expectEqual(Decision.repair_unsupported_claim, verifyWebFinalAnswer("O PS5 tem Wi-Fi 6.", context).decision);
    try std.testing.expectEqual(Decision.append_missing_source, verifyWebFinalAnswer("O R36S usa RK3326.", context).decision);
    try std.testing.expectEqual(Decision.accept, verifyWebFinalAnswer("Fonte: https://example.test/r36s. O R36S usa RK3326.", context).decision);

    const empty =
        \\[WEB_DOSSIER v1]
        \\W1:
        \\source_url=https://example.test/r36s
        \\GAPS:
        \\- W1 empty_excerpt
    ;
    try std.testing.expectEqual(Decision.repair_empty_evidence, verifyWebFinalAnswer("O R36S usa RK3326.", empty).decision);
}

test "web final verifier exposes claim support" {
    const context =
        \\[WEB_DOSSIER v1]
        \\W2:
        \\source_url=https://example.test/r36s
        \\excerpt=Console R36S usa RK3326 e 1GB RAM.
    ;
    const support = findDossierSupport("O R36S usa RK3326.", context).?;
    try support.validate();
    try std.testing.expectEqual(@as(usize, 2), support.evidence_index);
    try std.testing.expectEqualStrings("Console R36S usa RK3326 e 1GB RAM.", support.excerpt);
}
