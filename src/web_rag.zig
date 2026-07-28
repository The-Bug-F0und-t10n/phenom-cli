const std = @import("std");

const evidence = @import("evidence.zig");
const http = @import("http.zig");
const temporal = @import("temporal.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const default_fetch_limit: usize = 64 * 1024;
pub const default_search_template = "https://html.duckduckgo.com/html/?q={query}";

pub const Result = struct {
    target: []u8,
    evidence_text: []u8,
    audit_text: []u8,
    context_id: []u8,
    status_code: ?u16,
    http_success: bool,
    has_direct_excerpt: bool,
    raw_bytes_read: usize,
    model_bytes: usize,
    quality_score: i32,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.evidence_text);
        allocator.free(self.audit_text);
        allocator.free(self.context_id);
    }
};

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, target: []const u8, query: ?[]const u8, budget_bytes: usize) !Result {
    if (!isHttpTarget(target)) return error.InvalidWebTarget;
    if (budget_bytes == 0) return error.InvalidEvidenceBudget;

    const body_limit = @min(@max(budget_bytes * 4, @as(usize, 4096)), default_fetch_limit);
    const inspected = if (std.mem.startsWith(u8, std.mem.trim(u8, target, " \t\r\n"), "https://"))
        inspectHttpsGetLimit(allocator, io, target, body_limit)
    else
        http.inspectHttpGetLimit(allocator, target, body_limit);
    defer inspected.deinit(allocator);

    const title = try extractTitle(allocator, inspected.body_snippet);
    defer allocator.free(title);
    const plain_text_raw = try distillText(allocator, inspected.body_snippet, inspected.body_snippet.len);
    defer allocator.free(plain_text_raw);
    const plain_text = try stripStyleLikeText(allocator, plain_text_raw, plain_text_raw.len);
    defer allocator.free(plain_text);
    const searchable_text = try structuredTextForDistillation(allocator, inspected.target, inspected.body_snippet, plain_text);
    defer allocator.free(searchable_text);
    const distilled = try distillTextForQuery(allocator, searchable_text, query, budget_bytes);
    defer allocator.free(distilled);
    const selected_excerpt = try selectWebExcerpt(allocator, inspected.target, searchable_text, distilled, query, budget_bytes);
    defer selected_excerpt.deinit(allocator);
    const source_urls = try sourceUrlsForEvidence(allocator, inspected.target, searchable_text, selected_excerpt.text);
    defer allocator.free(source_urls);
    const web_block = try renderWebEvidenceBlock(allocator, inspected, title, source_urls, selected_excerpt.text, selected_excerpt.distill, query, budget_bytes);
    defer allocator.free(web_block);
    const status_text = try renderStatusText(allocator, inspected.status);
    defer allocator.free(status_text);

    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    try packet.add(.{
        .source = try allocator.dupe(u8, inspected.target),
        .kind = try allocator.dupe(u8, "web_http_get"),
        .range = try renderRange(allocator, inspected.status),
        .hash = std.hash.Wyhash.hash(0, web_block),
        .excerpt = try allocator.dupe(u8, web_block),
    });
    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);

    const http_ok = successfulHttpStatus(inspected.status, inspected.error_name);
    const audit_text = try std.fmt.allocPrint(
        allocator,
        "[TOOL_EVENT]\ntool=web_search\nsuccess={}\nargs=target={s} status={s} query_bytes={} raw_bytes={} model_bytes={} budget_bytes={} error={s}\n",
        .{
            http_ok,
            inspected.target,
            status_text,
            if (query) |value| value.len else 0,
            inspected.body_snippet.len,
            evidence_text.len,
            budget_bytes,
            inspected.error_name orelse "",
        },
    );
    errdefer allocator.free(audit_text);
    const context_id = try std.fmt.allocPrint(allocator, "web_{x}", .{std.hash.Wyhash.hash(0, evidence_text)});
    errdefer allocator.free(context_id);

    return .{
        .target = try allocator.dupe(u8, inspected.target),
        .evidence_text = evidence_text,
        .audit_text = audit_text,
        .context_id = context_id,
        .status_code = inspected.status,
        .http_success = http_ok,
        .has_direct_excerpt = distilled.len > 0,
        .raw_bytes_read = inspected.body_snippet.len,
        .model_bytes = evidence_text.len,
        .quality_score = if (http_ok and distilled.len > 0) 82 else if (http_ok and selected_excerpt.text.len > 0) 45 else 30,
    };
}

fn inspectHttpsGetLimit(allocator: std.mem.Allocator, io: std.Io, target: []const u8, body_limit: usize) http.RuntimeHttpResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const response = client.fetch(.{
        .location = .{ .url = target },
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch |err| {
        return .{
            .target = allocator.dupe(u8, target) catch unreachable,
            .status = null,
            .server = null,
            .body_snippet = allocator.dupe(u8, "") catch unreachable,
            .error_name = @errorName(err),
        };
    };

    const written = body.written();
    return .{
        .target = allocator.dupe(u8, target) catch unreachable,
        .status = @intCast(@intFromEnum(response.status)),
        .server = null,
        .body_snippet = allocator.dupe(u8, written[0..@min(written.len, body_limit)]) catch unreachable,
        .error_name = null,
    };
}

fn successfulHttpStatus(status: ?u16, error_name: ?[]const u8) bool {
    if (error_name != null) return false;
    const value = status orelse return false;
    return value >= 200 and value < 300;
}

pub fn resolveSearchTarget(allocator: std.mem.Allocator, target: ?[]const u8, query: ?[]const u8) ![]u8 {
    return resolveSearchTargetWithTemplate(allocator, target, query, null);
}

pub fn resolveSearchTargetWithTemplate(allocator: std.mem.Allocator, target: ?[]const u8, query: ?[]const u8, configured_template: ?[]const u8) ![]u8 {
    if (target) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            if (!isHttpTarget(trimmed)) return error.InvalidWebTarget;
            return allocator.dupe(u8, trimmed);
        }
    }
    const intent = std.mem.trim(u8, query orelse "", " \t\r\n");
    if (intent.len == 0) return error.MissingWebSearchQuery;
    const template = webSearchTemplate(configured_template) orelse return error.MissingWebSearchTarget;
    return resolveSearchTargetFromTemplate(allocator, template, intent);
}

fn webSearchTemplate(configured_template: ?[]const u8) ?[]const u8 {
    if (c.getenv("PHENOM_WEB_SEARCH_URL")) |template_z| {
        const template = std.mem.trim(u8, std.mem.span(template_z), " \t\r\n");
        if (template.len > 0) return template;
    }
    if (configured_template) |value| {
        const template = std.mem.trim(u8, value, " \t\r\n");
        if (template.len > 0) return template;
    }
    return default_search_template;
}

pub fn resolveSearchTargetFromTemplate(allocator: std.mem.Allocator, template: []const u8, query: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, template, "{query}")) |idx| {
        const encoded = try percentEncodeQuery(allocator, query);
        defer allocator.free(encoded);
        const resolved = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ template[0..idx], encoded, template[idx + "{query}".len ..] });
        errdefer allocator.free(resolved);
        if (!isHttpTarget(resolved)) return error.InvalidWebTarget;
        return resolved;
    }
    return error.InvalidWebSearchTemplate;
}

pub fn isHttpTarget(target: []const u8) bool {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://");
}

fn percentEncodeQuery(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else if (ch == ' ') {
            try out.appendSlice(allocator, "%20");
        } else {
            var buf: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch});
            try out.appendSlice(allocator, &buf);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn renderRange(allocator: std.mem.Allocator, status: ?u16) ![]u8 {
    if (status) |value| return std.fmt.allocPrint(allocator, "status={}", .{value});
    return allocator.dupe(u8, "status=unavailable");
}

fn renderStatusText(allocator: std.mem.Allocator, status: ?u16) ![]u8 {
    if (status) |value| return std.fmt.allocPrint(allocator, "{}", .{value});
    return allocator.dupe(u8, "unavailable");
}

fn renderWebEvidenceBlock(
    allocator: std.mem.Allocator,
    inspected: http.RuntimeHttpResult,
    title: []const u8,
    source_urls: []const u8,
    excerpt: []const u8,
    distill: []const u8,
    query: ?[]const u8,
    budget_bytes: usize,
) ![]u8 {
    const status_text = try renderStatusText(allocator, inspected.status);
    defer allocator.free(status_text);
    var retrieved_buf: [16]u8 = undefined;
    const retrieved_at = temporal.currentUtcDateText(&retrieved_buf);
    return std.fmt.allocPrint(
        allocator,
        "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill={s} target={s}\nretrieved_at={s}\ntimezone=UTC\nstatus={s}\nserver={s}\nerror={s}\nquery={s}\ntitle={s}\n{s}excerpt_budget_bytes={}\nexcerpt={s}\n",
        .{
            distill,
            inspected.target,
            retrieved_at,
            status_text,
            inspected.server orelse "",
            inspected.error_name orelse "",
            query orelse "",
            title,
            source_urls,
            budget_bytes,
            excerpt,
        },
    );
}

pub fn distillText(allocator: std.mem.Allocator, input: []const u8, budget_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_tag = false;
    var pending_space = false;
    var i: usize = 0;
    while (i < input.len and out.items.len < budget_bytes) {
        const ch = input[i];
        if (ch == '<') {
            if (skipHtmlNonContent(input, i)) |next| {
                pending_space = out.items.len > 0;
                i = next;
                continue;
            }
            in_tag = true;
            pending_space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (in_tag) {
            if (ch == '>') in_tag = false;
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(ch)) {
            pending_space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (pending_space and out.items.len < budget_bytes) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        if (ch == '&') {
            if (try appendEntity(allocator, &out, input[i..], budget_bytes)) |consumed| {
                i += consumed;
                continue;
            }
        }
        try out.append(allocator, ch);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn skipHtmlNonContent(input: []const u8, start: usize) ?usize {
    const names = [_][]const u8{ "script", "style", "noscript", "svg" };
    for (names) |name| {
        if (!htmlStartTagNameAt(input, start, name)) continue;
        var closing_buf: [32]u8 = undefined;
        const closing = std.fmt.bufPrint(&closing_buf, "</{s}", .{name}) catch return null;
        const close_start = indexOfIgnoreCase(input[start..], closing) orelse return null;
        const after_close = start + close_start;
        const close_end = std.mem.indexOfScalarPos(u8, input, after_close, '>') orelse return input.len;
        return close_end + 1;
    }
    return null;
}

fn htmlStartTagNameAt(input: []const u8, start: usize, name: []const u8) bool {
    if (start >= input.len or input[start] != '<') return false;
    var i = start + 1;
    if (i < input.len and input[i] == '/') return false;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    if (i + name.len > input.len) return false;
    if (!std.ascii.eqlIgnoreCase(input[i .. i + name.len], name)) return false;
    const end = i + name.len;
    return end >= input.len or std.ascii.isWhitespace(input[end]) or input[end] == '>' or input[end] == '/';
}

fn stripStyleLikeText(allocator: std.mem.Allocator, text: []const u8, budget_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < text.len and out.items.len < budget_bytes) {
        const chunk = nextChunk(text, &cursor);
        const trimmed = std.mem.trim(u8, chunk, " \t\r\n");
        if (trimmed.len == 0 or isStyleLikeText(trimmed)) continue;
        try appendBudgetedSlice(allocator, &out, trimmed, budget_bytes);
    }
    return out.toOwnedSlice(allocator);
}

pub fn isStyleLikeText(text: []const u8) bool {
    var braces: usize = 0;
    var colons: usize = 0;
    var semicolons: usize = 0;
    var important: usize = 0;
    for (text) |ch| {
        switch (ch) {
            '{', '}' => braces += 1,
            ':' => colons += 1,
            ';' => semicolons += 1,
            '!' => important += 1,
            else => {},
        }
    }
    if (braces >= 2 and colons > 0 and semicolons > 0) return true;
    if (colons >= 2 and semicolons >= 2 and important > 0) return true;
    if (containsIgnoreCase(text, "@font-face")) return true;
    if (containsIgnoreCase(text, "font-family:") and containsIgnoreCase(text, "sans-serif")) return true;
    if (containsIgnoreCase(text, "src:") and containsIgnoreCase(text, "url(")) return true;
    if (cssSelectorTokenCount(text) >= 2) return true;
    return false;
}

fn cssSelectorTokenCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '.' and text[i] != '#') continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '-' or text[j] == '_')) : (j += 1) {}
        if (j == start) continue;
        const token = text[start..j];
        if (std.mem.indexOfScalar(u8, token, '-') == null and token.len < 8) continue;
        count += 1;
    }
    return count;
}

pub fn distillTextForQuery(allocator: std.mem.Allocator, text: []const u8, query: ?[]const u8, budget_bytes: usize) ![]u8 {
    if (budget_bytes == 0) return allocator.dupe(u8, "");
    const intent = std.mem.trim(u8, query orelse "", " \t\r\n");
    if (intent.len == 0) return budgetedCopy(allocator, text, budget_bytes);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < text.len and out.items.len < budget_bytes) {
        const chunk = nextChunk(text, &cursor);
        const trimmed = std.mem.trim(u8, chunk, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!queryCoverageSufficient(trimmed, intent)) continue;
        try appendBudgetedSlice(allocator, &out, trimmed, budget_bytes);
    }
    if (out.items.len == 0) return allocator.dupe(u8, "");
    return out.toOwnedSlice(allocator);
}

fn distillTextForAnyQueryTerm(allocator: std.mem.Allocator, text: []const u8, query: ?[]const u8, budget_bytes: usize) ![]u8 {
    if (budget_bytes == 0) return allocator.dupe(u8, "");
    const intent = std.mem.trim(u8, query orelse "", " \t\r\n");
    if (intent.len == 0) return budgetedCopy(allocator, text, budget_bytes);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    var trailing_chunks: usize = 0;
    while (cursor < text.len and out.items.len < budget_bytes) {
        const chunk = nextChunk(text, &cursor);
        const trimmed = std.mem.trim(u8, chunk, " \t\r\n");
        if (trimmed.len == 0) continue;
        const matched = queryCoverageScore(trimmed, intent) > 0;
        if (!matched and trailing_chunks == 0) continue;
        try appendBudgetedSlice(allocator, &out, trimmed, budget_bytes);
        trailing_chunks = if (matched) 2 else trailing_chunks - 1;
    }
    if (out.items.len == 0) return allocator.dupe(u8, "");
    return out.toOwnedSlice(allocator);
}

fn structuredTextForDistillation(allocator: std.mem.Allocator, target: []const u8, raw: []const u8, plain_fallback: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, plain_fallback);
    if (trimmed[0] == '{' or trimmed[0] == '[') {
        const json_text = try jsonStringValuesToText(allocator, trimmed, trimmed.len);
        defer allocator.free(json_text);
        if (std.mem.trim(u8, json_text, " \t\r\n").len == 0) return allocator.dupe(u8, plain_fallback);
        return distillText(allocator, json_text, @max(json_text.len, plain_fallback.len));
    }
    if (isDuckDuckGoSearchTarget(target)) {
        const results = try duckDuckGoResultsText(allocator, trimmed);
        if (std.mem.trim(u8, results, " \t\r\n").len > 0) return results;
        allocator.free(results);
        return allocator.dupe(u8, "");
    }
    const releases = try htmlReleaseEntriesText(allocator, trimmed);
    if (std.mem.trim(u8, releases, " \t\r\n").len > 0) return releases;
    allocator.free(releases);
    return allocator.dupe(u8, plain_fallback);
}

fn isDirectStructuredSummary(text: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, text, " \t\r\n"), "release=");
}

const SelectedWebExcerpt = struct {
    text: []u8,
    distill: []const u8,

    fn deinit(self: SelectedWebExcerpt, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn selectWebExcerpt(allocator: std.mem.Allocator, target: []const u8, searchable_text: []const u8, distilled: []const u8, query: ?[]const u8, budget_bytes: usize) !SelectedWebExcerpt {
    if (distilled.len > 0) return .{ .text = try allocator.dupe(u8, distilled), .distill = "query_chunks" };
    if (isDirectStructuredSummary(searchable_text)) return .{ .text = try budgetedCopy(allocator, searchable_text, budget_bytes), .distill = "query_chunks" };
    if (!isDuckDuckGoSearchTarget(target) and std.mem.trim(u8, searchable_text, " \t\r\n").len > 0) {
        const relaxed = try distillTextForAnyQueryTerm(allocator, searchable_text, query, budget_bytes);
        defer allocator.free(relaxed);
        if (relaxed.len > 0) return .{ .text = try allocator.dupe(u8, relaxed), .distill = "source_excerpt" };
        return .{ .text = try budgetedCopy(allocator, searchable_text, @min(budget_bytes, 2048)), .distill = "source_excerpt" };
    }
    return .{ .text = try allocator.dupe(u8, ""), .distill = "query_chunks" };
}

fn isDuckDuckGoSearchTarget(target: []const u8) bool {
    return containsIgnoreCase(target, "://html.duckduckgo.com/html/");
}

fn duckDuckGoResultsText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    var result_index: usize = 0;
    while (result_index < 8) {
        const rel = indexOfIgnoreCase(raw[cursor..], "result__a") orelse break;
        const class_pos = cursor + rel;
        const tag_start = tagStartBefore(raw, class_pos) orelse break;
        const tag_end = std.mem.indexOfScalar(u8, raw[class_pos..], '>') orelse break;
        const content_start = class_pos + tag_end + 1;
        const title_end_rel = indexOfIgnoreCase(raw[content_start..], "</a>") orelse break;
        const title_html = raw[content_start .. content_start + title_end_rel];
        const title = try distillText(allocator, title_html, 240);
        defer allocator.free(title);
        const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed_title.len == 0) {
            cursor = content_start + title_end_rel + "</a>".len;
            continue;
        }

        const result_start = content_start + title_end_rel + "</a>".len;
        const next_result = if (indexOfIgnoreCase(raw[result_start..], "result__a")) |next| result_start + next else @min(raw.len, result_start + 4096);
        const href = try extractHtmlAttribute(allocator, raw[tag_start..content_start], "href");
        defer allocator.free(href);
        const snippet = try extractTagBodyAfterClass(allocator, raw[result_start..next_result], "result__snippet");
        defer allocator.free(snippet);

        result_index += 1;
        try appendResultField(allocator, &out, result_index, "title", trimmed_title);
        if (std.mem.trim(u8, href, " \t\r\n").len > 0) try appendResultField(allocator, &out, result_index, "url", href);
        const trimmed_snippet = std.mem.trim(u8, snippet, " \t\r\n");
        if (trimmed_snippet.len > 0) try appendResultField(allocator, &out, result_index, "snippet", trimmed_snippet);
        cursor = result_start;
    }
    return out.toOwnedSlice(allocator);
}

fn tagStartBefore(raw: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (raw[i] == '<') return i;
        if (raw[i] == '>') return null;
    }
    return null;
}

fn extractHtmlAttribute(allocator: std.mem.Allocator, tag: []const u8, name: []const u8) ![]u8 {
    var cursor: usize = 0;
    while (cursor < tag.len) {
        const rel = indexOfIgnoreCase(tag[cursor..], name) orelse return allocator.dupe(u8, "");
        const key_pos = cursor + rel;
        var i = key_pos + name.len;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') {
            cursor = i;
            continue;
        }
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len) return allocator.dupe(u8, "");
        const quote = tag[i];
        if (quote != '"' and quote != '\'') return allocator.dupe(u8, "");
        i += 1;
        const start = i;
        while (i < tag.len and tag[i] != quote) : (i += 1) {}
        return distillText(allocator, tag[start..i], 512);
    }
    return allocator.dupe(u8, "");
}

fn extractTagBodyAfterClass(allocator: std.mem.Allocator, html: []const u8, class_marker: []const u8) ![]u8 {
    const rel = indexOfIgnoreCase(html, class_marker) orelse return allocator.dupe(u8, "");
    const class_pos = rel;
    const tag_end_rel = std.mem.indexOfScalar(u8, html[class_pos..], '>') orelse return allocator.dupe(u8, "");
    const content_start = class_pos + tag_end_rel + 1;
    const close = nearestHtmlClose(html[content_start..]) orelse return allocator.dupe(u8, "");
    return distillText(allocator, html[content_start .. content_start + close], 512);
}

fn nearestHtmlClose(html: []const u8) ?usize {
    var best: ?usize = null;
    const closers = [_][]const u8{ "</a>", "</div>", "</td>", "</span>" };
    for (closers) |closer| {
        if (indexOfIgnoreCase(html, closer)) |idx| {
            if (best == null or idx < best.?) best = idx;
        }
    }
    return best;
}

fn appendResultField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), idx: usize, name: []const u8, value: []const u8) !void {
    const line = try std.fmt.allocPrint(allocator, "result={d} {s}={s}\n", .{ idx, name, value });
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn sourceUrlsForEvidence(allocator: std.mem.Allocator, target: []const u8, searchable_text: []const u8, distilled: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendSourceUrlsFromText(allocator, &out, searchable_text);
    try appendSourceUrlsFromText(allocator, &out, distilled);
    if (out.items.len == 0 and !isDuckDuckGoSearchTarget(target) and (std.mem.trim(u8, distilled, " \t\r\n").len > 0 or std.mem.trim(u8, searchable_text, " \t\r\n").len > 0)) {
        try appendSourceUrlLine(allocator, &out, target);
    }
    return out.toOwnedSlice(allocator);
}

fn appendSourceUrlsFromText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (out.items.len >= 2048) return;
        const marker = " url=";
        const idx = std.mem.indexOf(u8, line, marker) orelse continue;
        const raw_tail = std.mem.trim(u8, line[idx + marker.len ..], " \t\r\n");
        const raw_end = std.mem.indexOfAny(u8, raw_tail, " \t\r\n") orelse raw_tail.len;
        const raw = raw_tail[0..raw_end];
        if (raw.len == 0) continue;
        const url = try normalizeSearchResultUrl(allocator, raw);
        defer allocator.free(url);
        if (!isHttpTarget(url) or !sourceUrlLooksComplete(url) or containsSourceUrl(out.items, url)) continue;
        try appendSourceUrlLine(allocator, out, url);
    }
}

fn sourceUrlLooksComplete(url: []const u8) bool {
    if (std.mem.indexOfAny(u8, url, " \t\r\n") != null) return false;
    if (std.mem.endsWith(u8, url, ".")) return false;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    const host_start = scheme_end + "://".len;
    if (host_start >= url.len) return false;
    var host_end = host_start;
    while (host_end < url.len and url[host_end] != '/' and url[host_end] != '?' and url[host_end] != '#') : (host_end += 1) {}
    const host = url[host_start..host_end];
    if (host.len == 0) return false;
    if (std.mem.endsWith(u8, host, ".")) return false;
    return true;
}

fn appendSourceUrlLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), url: []const u8) !void {
    try out.appendSlice(allocator, "source_url=");
    try out.appendSlice(allocator, url);
    try out.append(allocator, '\n');
}

fn containsSourceUrl(text: []const u8, url: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "source_url=")) continue;
        if (std.mem.eql(u8, trimmed["source_url=".len..], url)) return true;
    }
    return false;
}

fn normalizeSearchResultUrl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, raw, "uddg=")) |idx| {
        const value_start = idx + "uddg=".len;
        var value_end = value_start;
        while (value_end < raw.len and raw[value_end] != '&' and !std.ascii.isWhitespace(raw[value_end])) : (value_end += 1) {}
        return percentDecodeBytes(allocator, raw[value_start..value_end]);
    }
    return allocator.dupe(u8, raw);
}

fn percentDecodeBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (parseHexByte(text[i + 1 .. i + 3])) |value| {
                try out.append(allocator, value);
                i += 3;
                continue;
            }
        }
        try out.append(allocator, if (text[i] == '+') ' ' else text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn parseHexByte(bytes: []const u8) ?u8 {
    if (bytes.len != 2) return null;
    const hi = std.fmt.charToDigit(bytes[0], 16) catch return null;
    const lo = std.fmt.charToDigit(bytes[1], 16) catch return null;
    return @intCast(hi * 16 + lo);
}

fn htmlReleaseEntriesText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    var count: usize = 0;
    while (count < 12) {
        const rel = indexOfIgnoreCase(raw[cursor..], "<h2 id=\"release-") orelse break;
        const id_start = cursor + rel + "<h2 id=\"release-".len;
        const id_end_rel = std.mem.indexOfScalar(u8, raw[id_start..], '"') orelse break;
        const release_id = raw[id_start .. id_start + id_end_rel];
        const tag_end_rel = std.mem.indexOfScalar(u8, raw[id_start + id_end_rel ..], '>') orelse break;
        const label_start = id_start + id_end_rel + tag_end_rel + 1;
        const label_end_rel = indexOfIgnoreCase(raw[label_start..], "</h2>") orelse break;
        const label = try distillText(allocator, raw[label_start .. label_start + label_end_rel], 120);
        defer allocator.free(label);
        const section_start = label_start + label_end_rel + "</h2>".len;
        const section_end = if (indexOfIgnoreCase(raw[section_start..], "<h2 id=\"release-")) |next| section_start + next else @min(raw.len, section_start + 4096);
        const date = try firstHtmlListItemText(allocator, raw[section_start..section_end]);
        defer allocator.free(date);

        count += 1;
        const line = try std.fmt.allocPrint(
            allocator,
            "release={s} label={s} date={s}\n",
            .{ release_id, std.mem.trim(u8, label, " \t\r\n"), std.mem.trim(u8, date, " \t\r\n") },
        );
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        cursor = section_start;
    }
    return out.toOwnedSlice(allocator);
}

fn firstHtmlListItemText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const start_rel = indexOfIgnoreCase(html, "<li>") orelse return allocator.dupe(u8, "");
    const content_start = start_rel + "<li>".len;
    const end_rel = indexOfIgnoreCase(html[content_start..], "</li>") orelse return allocator.dupe(u8, "");
    return distillText(allocator, html[content_start .. content_start + end_rel], 80);
}

fn jsonStringValuesToText(allocator: std.mem.Allocator, json: []const u8, budget_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < json.len and out.items.len < budget_bytes) {
        if (json[i] != '"') {
            i += 1;
            continue;
        }
        const value_start = i + 1;
        const string_end = jsonStringEnd(json, value_start) orelse break;
        var after = string_end + 1;
        while (after < json.len and std.ascii.isWhitespace(json[after])) : (after += 1) {}
        if (after >= json.len or json[after] != ':') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
            try appendJsonDecodedBudgeted(allocator, &out, json[value_start..string_end], budget_bytes);
        }
        i = string_end + 1;
    }
    return out.toOwnedSlice(allocator);
}

fn jsonStringEnd(json: []const u8, start: usize) ?usize {
    var i = start;
    var escaped = false;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') return i;
    }
    return null;
}

fn appendJsonDecodedBudgeted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), encoded: []const u8, budget_bytes: usize) !void {
    var i: usize = 0;
    while (i < encoded.len and out.items.len < budget_bytes) {
        const ch = encoded[i];
        if (ch != '\\') {
            try out.append(allocator, ch);
            i += 1;
            continue;
        }
        if (i + 1 >= encoded.len) break;
        const esc = encoded[i + 1];
        switch (esc) {
            '"', '\\', '/' => {
                try out.append(allocator, esc);
                i += 2;
            },
            'b' => {
                try out.append(allocator, ' ');
                i += 2;
            },
            'f' => {
                try out.append(allocator, ' ');
                i += 2;
            },
            'n', 'r', 't' => {
                try out.append(allocator, ' ');
                i += 2;
            },
            'u' => {
                if (i + 6 <= encoded.len) {
                    const codepoint = parseHexCodepoint(encoded[i + 2 .. i + 6]) orelse {
                        i += 2;
                        continue;
                    };
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch 0;
                    try out.appendSlice(allocator, buf[0..@min(len, budget_bytes - out.items.len)]);
                    i += 6;
                } else {
                    i += 2;
                }
            },
            else => {
                try out.append(allocator, esc);
                i += 2;
            },
        }
    }
}

fn parseHexCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len != 4) return null;
    var value: u21 = 0;
    for (bytes) |byte| {
        const digit: u21 = if (byte >= '0' and byte <= '9')
            byte - '0'
        else if (byte >= 'a' and byte <= 'f')
            byte - 'a' + 10
        else if (byte >= 'A' and byte <= 'F')
            byte - 'A' + 10
        else
            return null;
        value = value * 16 + digit;
    }
    return value;
}

fn nextChunk(text: []const u8, cursor: *usize) []const u8 {
    const start = cursor.*;
    var end = start;
    while (end < text.len) : (end += 1) {
        const ch = text[end];
        if (ch == '.' or ch == '!' or ch == '?' or ch == '\n') {
            end += 1;
            break;
        }
        if (end - start >= 360 and ch == ' ') {
            end += 1;
            break;
        }
    }
    cursor.* = end;
    return text[start..end];
}

fn queryCoverageScore(chunk: []const u8, query: []const u8) usize {
    var score: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n\"'`()[]{}<>:;,./\\|+-_*=");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " \t\r\n");
        if (term.len < 3) continue;
        if (containsIgnoreCase(chunk, term)) score += term.len;
    }
    return score;
}

fn queryCoverageTotal(query: []const u8) struct { bytes: usize, terms: usize } {
    var bytes: usize = 0;
    var terms: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n\"'`()[]{}<>:;,./\\|+-_*=");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " \t\r\n");
        if (term.len < 3) continue;
        bytes += term.len;
        terms += 1;
    }
    return .{ .bytes = bytes, .terms = terms };
}

fn queryCoverageSufficient(chunk: []const u8, query: []const u8) bool {
    const total = queryCoverageTotal(query);
    if (total.terms == 0) return true;
    const score = queryCoverageScore(chunk, query);
    if (total.terms == 1) return score > 0;
    return score * 2 >= total.bytes;
}

fn appendBudgetedSlice(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, budget_bytes: usize) !void {
    if (out.items.len >= budget_bytes) return;
    if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
    const remaining = budget_bytes - out.items.len;
    try out.appendSlice(allocator, text[0..@min(text.len, remaining)]);
}

fn budgetedCopy(allocator: std.mem.Allocator, text: []const u8, budget_bytes: usize) ![]u8 {
    return allocator.dupe(u8, text[0..@min(text.len, budget_bytes)]);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn appendEntity(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8, budget_bytes: usize) !?usize {
    const semicolon = std.mem.indexOfScalar(u8, input, ';') orelse return null;
    if (semicolon > 8) return null;
    const entity = input[0 .. semicolon + 1];
    const decoded: ?u8 = if (std.mem.eql(u8, entity, "&amp;"))
        '&'
    else if (std.mem.eql(u8, entity, "&lt;"))
        '<'
    else if (std.mem.eql(u8, entity, "&gt;"))
        '>'
    else if (std.mem.eql(u8, entity, "&quot;"))
        '"'
    else if (std.mem.eql(u8, entity, "&#39;"))
        '\''
    else
        null;
    if (decoded) |value| {
        if (out.items.len < budget_bytes) try out.append(allocator, value);
        return semicolon + 1;
    }
    return null;
}

pub fn extractTitle(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const start = indexOfIgnoreCase(input, "<title>") orelse return allocator.dupe(u8, "");
    const content_start = start + "<title>".len;
    const end_rel = indexOfIgnoreCase(input[content_start..], "</title>") orelse return allocator.dupe(u8, "");
    return distillText(allocator, input[content_start .. content_start + end_rel], 256);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "distill strips html and decodes common entities" {
    const out = try distillText(std.testing.allocator, "<html><title>A &amp; B</title><body>Texto <b>forte</b> &lt;x&gt;</body></html>", 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("A & B Texto forte <x>", out);
}

test "distill skips non content html blocks" {
    const out = try distillText(std.testing.allocator, "<html><style>.x{color:red}</style><script>alert(1)</script><body>Console R36S RK3326 1GB RAM.</body></html>", 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Console R36S") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "color:red") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alert") == null);
}

test "distill skips inline css-like text chunks" {
    const page = "Console R36S body {font-family: 'Poppins', sans-serif ! important;background: #F3F4F8;font-weight: 300 ! important;} R36S RK3326 1GB RAM tela IPS 480x320.";
    const out = try stripStyleLikeText(std.testing.allocator, page, 1024);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "RK3326") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font-family") == null);
    try std.testing.expect(isStyleLikeText("body {font-family: 'Poppins', sans-serif ! important;background: #F3F4F8;}"));
    try std.testing.expect(isStyleLikeText("Dados tecnicos . product-shop-page . shop-list-view . sidebar-widget"));
}

test "title extraction is case insensitive and budgeted" {
    const title = try extractTitle(std.testing.allocator, "<HTML><TITLE> Phenom &amp; Web </TITLE></HTML>");
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Phenom & Web", title);
}

test "query distillation keeps matching chunks and drops unrelated text" {
    const input = "Abertura irrelevante longa. Horario de Brasilia agora aparece nesta frase importante. Outra frase sobre clima sem relacao.";
    const out = try distillTextForQuery(std.testing.allocator, input, "horario de brasilia", 96);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Horario de Brasilia") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Abertura irrelevante") == null);
    try std.testing.expect(out.len <= 96);
}

test "query distillation does not fall back to similar unrelated text" {
    const input = "Resultado sobre Wesley Silva, musico local. Outro resultado sobre Behemoth, banda polonesa.";
    const out = try distillTextForQuery(std.testing.allocator, input, "Wesley Beehmot biografia perfil", 256);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("", out);
}

test "direct page excerpt falls back to real page text when strict coverage is empty" {
    const page = "Ficha técnica completa do Console Portátil R36S. Tela IPS 3.5 polegadas 480x320. Sistema Linux e armazenamento 64GB.";
    const strict = try distillTextForQuery(std.testing.allocator, page, "especificações técnicas R36S console portátil", 512);
    defer std.testing.allocator.free(strict);
    try std.testing.expectEqualStrings("", strict);

    const excerpt = try selectWebExcerpt(std.testing.allocator, "https://example.test/r36s", page, strict, "especificações técnicas R36S console portátil", 512);
    defer excerpt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("source_excerpt", excerpt.distill);
    try std.testing.expect(std.mem.indexOf(u8, excerpt.text, "R36S") != null);
    try std.testing.expect(std.mem.indexOf(u8, excerpt.text, "480x320") != null);
}

test "json search payload is converted to readable evidence before query ranking" {
    const raw =
        \\{"pages":[{"key":"Linux_(n\u00facleo)","title":"Linux (n\u00facleo)","excerpt":"O <span class=\"searchmatch\">kernel</span> Linux foi criado por <span class=\"searchmatch\">Linus</span> <span class=\"searchmatch\">Torvalds</span> em 1991.","description":"nucleo Unix"}]}
    ;
    const fallback = try distillText(std.testing.allocator, raw, raw.len);
    defer std.testing.allocator.free(fallback);
    const text = try structuredTextForDistillation(std.testing.allocator, "https://example.test/search", raw, fallback);
    defer std.testing.allocator.free(text);
    const out = try distillTextForQuery(std.testing.allocator, text, "criador kernel Linux Linus Torvalds", 512);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "{") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "searchmatch") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Linus") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Torvalds") != null);
}

test "duckduckgo html search results become structured snippets" {
    const raw =
        \\<html><body>
        \\<a rel="nofollow" class="result__a" href="https://ziglang.org/download/">Download - Zig Programming Language</a>
        \\<a class="result__snippet">Download the latest release of Zig from the official project page.</a>
        \\<a rel="nofollow" class="result__a" href="https://example.test/other">Other result</a>
        \\<a class="result__snippet">Adjacent topic without the requested fact.</a>
        \\</body></html>
    ;
    const text = try structuredTextForDistillation(std.testing.allocator, "https://html.duckduckgo.com/html/?q=zig", raw, "");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "result=1 title=Download - Zig Programming Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "result=1 url=https://ziglang.org/download/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "result=1 snippet=Download the latest release") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<a") == null);
}

test "duckduckgo result urls become web evidence source urls" {
    const searchable_text =
        \\result=1 title=Download - Zig Programming Language
        \\result=1 url=https://ziglang.org/download/
        \\result=1 snippet=Download the latest release of Zig from the official project page.
    ;
    const distilled =
        \\result=1 title=Download - Zig Programming Language
        \\result=1 snippet=Download the latest release of Zig from the official project page.
    ;
    const urls = try sourceUrlsForEvidence(std.testing.allocator, "https://html.duckduckgo.com/html/?q=zig", searchable_text, distilled);
    defer std.testing.allocator.free(urls);

    try std.testing.expectEqualStrings("source_url=https://ziglang.org/download/\n", urls);
}

test "structured result url wins over text-distorted url" {
    const searchable_text =
        \\result=1 title=R36S Specs
        \\result=1 url=http://127.0.0.1/source-empty
        \\result=1 snippet=Dados tecnicos do console R36S.
    ;
    const distilled = "R36S result=1 title=R36S Specs url=http://127. 0. 0. 1/source-empty snippet=Dados tecnicos.";
    const urls = try sourceUrlsForEvidence(std.testing.allocator, "https://html.duckduckgo.com/html/?q=r36s", searchable_text, distilled);
    defer std.testing.allocator.free(urls);

    try std.testing.expectEqualStrings("source_url=http://127.0.0.1/source-empty\n", urls);
}

test "source urls are extracted from plain result text with port" {
    const searchable_text = "R36S results result=1 title=R36S Specs url=http://127.0.0.1:43337/source-empty snippet=Dados tecnicos do console R36S result=2 title=R36S Specs url=http://127.0.0.1:43337/source snippet=Ficha tecnica do console R36S";
    const distilled = "R36S results result=1 title=R36S Specs url=http://127. 0. 0. 1/source-empty snippet=Dados tecnicos do console R36S";
    const urls = try sourceUrlsForEvidence(std.testing.allocator, "http://127.0.0.1:43337/search?q=R36S", searchable_text, distilled);
    defer std.testing.allocator.free(urls);

    try std.testing.expectEqualStrings("source_url=http://127.0.0.1:43337/source-empty\n", urls);
}

test "duckduckgo redirect result url is decoded before source evidence" {
    const url = try normalizeSearchResultUrl(std.testing.allocator, "/l/?kh=-1&uddg=https%3A%2F%2Fziglang.org%2Fdownload%2F&rut=abc");
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings("https://ziglang.org/download/", url);
}

test "direct http evidence uses fetched target as source url" {
    const urls = try sourceUrlsForEvidence(std.testing.allocator, "http://127.0.0.1/search?q=zig", "Zig stable release", "Zig stable release");
    defer std.testing.allocator.free(urls);

    try std.testing.expectEqualStrings("source_url=http://127.0.0.1/search?q=zig\n", urls);
}

test "direct http evidence keeps source when lexical excerpt is empty" {
    const urls = try sourceUrlsForEvidence(std.testing.allocator, "http://127.0.0.1/search?q=londrina", "Londrina fica no norte do Parana.", "");
    defer std.testing.allocator.free(urls);

    try std.testing.expectEqualStrings("source_url=http://127.0.0.1/search?q=londrina\n", urls);
}

test "duckduckgo challenge page does not become query echo evidence" {
    const raw =
        \\<html><title>DuckDuckGo</title><body>
        \\<form id="challenge-form" action="//duckduckgo.com/anomaly.js?q=versao mais recente zig">
        \\<div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
        \\</form></body></html>
    ;
    const text = try structuredTextForDistillation(std.testing.allocator, "https://html.duckduckgo.com/html/?q=zig", raw, "DuckDuckGo versao mais recente zig");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("", text);
}

test "release html becomes compact structured evidence" {
    const raw =
        \\<h2 id="release-master">master</h2><ul><li>2026-07-25</li></ul>
        \\<h2 id="release-0.15.1">0.15.1</h2><ul><li>2026-04-10</li></ul>
        \\<table><a href="https://ziglang.org/download/0.15.1/zig-0.15.1.tar.xz">zig-0.15.1.tar.xz</a></table>
    ;
    const text = try structuredTextForDistillation(std.testing.allocator, "https://ziglang.org/download/", raw, "");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "release=master label=master date=2026-07-25") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "release=0.15.1 label=0.15.1 date=2026-04-10") != null);
    try std.testing.expect(isDirectStructuredSummary(text));
}

test "rejects non http targets" {
    try std.testing.expect(!isHttpTarget("README.md"));
    try std.testing.expect(isHttpTarget("http://127.0.0.1:8080/"));
    try std.testing.expect(isHttpTarget("https://example.com/"));
}

test "query-only web search resolves through configured template" {
    const target = try resolveSearchTargetFromTemplate(std.testing.allocator, "http://127.0.0.1:8080/search?q={query}&format=html", "horario de brasilia");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/search?q=horario%20de%20brasilia&format=html", target);
}

test "query-only web search can use config template without env" {
    var saved_env: ?[:0]u8 = null;
    if (c.getenv("PHENOM_WEB_SEARCH_URL")) |value| {
        saved_env = try std.testing.allocator.dupeZ(u8, std.mem.span(value));
    }
    _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
    defer {
        if (saved_env) |value| {
            _ = c.setenv("PHENOM_WEB_SEARCH_URL", value.ptr, 1);
            std.testing.allocator.free(value);
        } else {
            _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
        }
    }

    const target = try resolveSearchTargetWithTemplate(std.testing.allocator, null, "horario de brasilia", "http://127.0.0.1:8080/search?q={query}");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/search?q=horario%20de%20brasilia", target);
}

test "query-only web search has built-in default when env and config are absent" {
    var saved_env: ?[:0]u8 = null;
    if (c.getenv("PHENOM_WEB_SEARCH_URL")) |value| {
        saved_env = try std.testing.allocator.dupeZ(u8, std.mem.span(value));
    }
    _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
    defer {
        if (saved_env) |value| {
            _ = c.setenv("PHENOM_WEB_SEARCH_URL", value.ptr, 1);
            std.testing.allocator.free(value);
        } else {
            _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
        }
    }

    const target = try resolveSearchTargetWithTemplate(std.testing.allocator, null, "Linus Torvalds Linux", null);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("https://html.duckduckgo.com/html/?q=Linus%20Torvalds%20Linux", target);
}

test "query-only web search env overrides config template" {
    var saved_env: ?[:0]u8 = null;
    if (c.getenv("PHENOM_WEB_SEARCH_URL")) |value| {
        saved_env = try std.testing.allocator.dupeZ(u8, std.mem.span(value));
    }
    _ = c.setenv("PHENOM_WEB_SEARCH_URL", "http://127.0.0.1:9000/env?q={query}", 1);
    defer {
        if (saved_env) |value| {
            _ = c.setenv("PHENOM_WEB_SEARCH_URL", value.ptr, 1);
            std.testing.allocator.free(value);
        } else {
            _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
        }
    }

    const target = try resolveSearchTargetWithTemplate(std.testing.allocator, null, "horario de brasilia", "http://127.0.0.1:8080/config?q={query}");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/env?q=horario%20de%20brasilia", target);
}

test "query-only web search requires template placeholder" {
    try std.testing.expectError(error.InvalidWebSearchTemplate, resolveSearchTargetFromTemplate(std.testing.allocator, "http://127.0.0.1:8080/search", "horario de brasilia"));
}

test "http status success excludes server errors" {
    try std.testing.expect(successfulHttpStatus(200, null));
    try std.testing.expect(successfulHttpStatus(204, null));
    try std.testing.expect(!successfulHttpStatus(301, null));
    try std.testing.expect(!successfulHttpStatus(500, null));
    try std.testing.expect(!successfulHttpStatus(null, "ConnectFailed"));
}

test "https web fetch uses std client path instead of legacy runtime rejection" {
    const result = try fetch(std.testing.allocator, std.testing.io, "https://", "external evidence", 256);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[WEB_EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.audit_text, "tool=web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.audit_text, "TlsRuntimeInspectionUnsupported") == null);
}
