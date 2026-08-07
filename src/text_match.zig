const std = @import("std");

pub fn containsFoldedIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var folded_needle_buf: [512]u8 = undefined;
    const folded_needle = foldUtf8(&folded_needle_buf, needle);
    if (folded_needle.len == 0) return false;

    var offset: usize = 0;
    while (offset < haystack.len) : (offset += 1) {
        if (isUtf8Continuation(haystack[offset])) continue;
        if (foldedStartsWith(haystack[offset..], folded_needle)) return true;
    }
    return false;
}

fn foldedStartsWith(text: []const u8, folded_needle: []const u8) bool {
    var needle_idx: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len and needle_idx < folded_needle.len) {
        const decoded = decodeUtf8(text[cursor..]) orelse return false;
        var folded_buf: [4]u8 = undefined;
        const folded = foldCodepoint(decoded.codepoint, &folded_buf);
        for (folded) |byte| {
            if (needle_idx >= folded_needle.len or folded_needle[needle_idx] != byte) return false;
            needle_idx += 1;
        }
        cursor += decoded.len;
    }
    return needle_idx == folded_needle.len;
}

fn foldUtf8(buf: []u8, text: []const u8) []const u8 {
    var out_len: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len and out_len < buf.len) {
        const decoded = decodeUtf8(text[cursor..]) orelse {
            cursor += 1;
            continue;
        };
        var folded_buf: [4]u8 = undefined;
        const folded = foldCodepoint(decoded.codepoint, &folded_buf);
        for (folded) |byte| {
            if (out_len == buf.len) break;
            buf[out_len] = byte;
            out_len += 1;
        }
        cursor += decoded.len;
    }
    return buf[0..out_len];
}

const Decoded = struct {
    codepoint: u21,
    len: usize,
};

fn decodeUtf8(text: []const u8) ?Decoded {
    if (text.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len > text.len) return null;
    const codepoint = std.unicode.utf8Decode(text[0..len]) catch return null;
    return .{ .codepoint = codepoint, .len = len };
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn foldCodepoint(codepoint: u21, buf: *[4]u8) []const u8 {
    if (codepoint >= 'A' and codepoint <= 'Z') {
        buf[0] = @as(u8, @intCast(codepoint)) + 32;
        return buf[0..1];
    }
    if (codepoint < 128) {
        buf[0] = @as(u8, @intCast(codepoint));
        return buf[0..1];
    }
    if (codepoint >= 0x0300 and codepoint <= 0x036f) return buf[0..0];
    if (foldLatin(codepoint)) |folded| return foldedToBytes(folded, buf);
    return encodeUtf8Lower(codepoint, buf);
}

fn foldedToBytes(folded: []const u8, buf: *[4]u8) []const u8 {
    @memcpy(buf[0..folded.len], folded);
    return buf[0..folded.len];
}

fn foldLatin(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        'À', 'Á', 'Â', 'Ã', 'Ä', 'Å', 'Ā', 'Ă', 'Ą', 'Ǎ', 'Ǟ', 'Ǡ', 'Ạ', 'Ả', 'Ấ', 'Ầ', 'Ẩ', 'Ẫ', 'Ậ', 'Ắ', 'Ằ', 'Ẳ', 'Ẵ', 'Ặ',
        'à', 'á', 'â', 'ã', 'ä', 'å', 'ā', 'ă', 'ą', 'ǎ', 'ǟ', 'ǡ', 'ạ', 'ả', 'ấ', 'ầ', 'ẩ', 'ẫ', 'ậ', 'ắ', 'ằ', 'ẳ', 'ẵ', 'ặ',
        => "a",
        'Æ', 'æ' => "ae",
        'Ç', 'Ć', 'Ĉ', 'Ċ', 'Č', 'ç', 'ć', 'ĉ', 'ċ', 'č' => "c",
        'Ð', 'Ď', 'Đ', 'ð', 'ď', 'đ' => "d",
        'È', 'É', 'Ê', 'Ë', 'Ē', 'Ĕ', 'Ė', 'Ę', 'Ě', 'Ẹ', 'Ẻ', 'Ẽ', 'Ế', 'Ề', 'Ể', 'Ễ', 'Ệ',
        'è', 'é', 'ê', 'ë', 'ē', 'ĕ', 'ė', 'ę', 'ě', 'ẹ', 'ẻ', 'ẽ', 'ế', 'ề', 'ể', 'ễ', 'ệ',
        => "e",
        'Ĝ', 'Ğ', 'Ġ', 'Ģ', 'ĝ', 'ğ', 'ġ', 'ģ' => "g",
        'Ĥ', 'Ħ', 'ĥ', 'ħ' => "h",
        'Ì', 'Í', 'Î', 'Ï', 'Ĩ', 'Ī', 'Ĭ', 'Į', 'İ', 'Ǐ', 'Ỉ', 'Ị',
        'ì', 'í', 'î', 'ï', 'ĩ', 'ī', 'ĭ', 'į', 'ı', 'ǐ', 'ỉ', 'ị',
        => "i",
        'Ĵ', 'ĵ' => "j",
        'Ķ', 'ķ' => "k",
        'Ĺ', 'Ļ', 'Ľ', 'Ŀ', 'Ł', 'ĺ', 'ļ', 'ľ', 'ŀ', 'ł' => "l",
        'Ñ', 'Ń', 'Ņ', 'Ň', 'ñ', 'ń', 'ņ', 'ň' => "n",
        'Ò', 'Ó', 'Ô', 'Õ', 'Ö', 'Ø', 'Ō', 'Ŏ', 'Ő', 'Ơ', 'Ǒ', 'Ǫ', 'Ọ', 'Ỏ', 'Ố', 'Ồ', 'Ổ', 'Ỗ', 'Ộ', 'Ớ', 'Ờ', 'Ở', 'Ỡ', 'Ợ',
        'ò', 'ó', 'ô', 'õ', 'ö', 'ø', 'ō', 'ŏ', 'ő', 'ơ', 'ǒ', 'ǫ', 'ọ', 'ỏ', 'ố', 'ồ', 'ổ', 'ỗ', 'ộ', 'ớ', 'ờ', 'ở', 'ỡ', 'ợ',
        => "o",
        'Œ', 'œ' => "oe",
        'Ŕ', 'Ŗ', 'Ř', 'ŕ', 'ŗ', 'ř' => "r",
        'Ś', 'Ŝ', 'Ş', 'Š', 'ś', 'ŝ', 'ş', 'š' => "s",
        'ẞ', 'ß' => "ss",
        'Ţ', 'Ť', 'Ŧ', 'ţ', 'ť', 'ŧ' => "t",
        'Ù', 'Ú', 'Û', 'Ü', 'Ũ', 'Ū', 'Ŭ', 'Ů', 'Ű', 'Ų', 'Ư', 'Ǔ', 'Ụ', 'Ủ', 'Ứ', 'Ừ', 'Ử', 'Ữ', 'Ự',
        'ù', 'ú', 'û', 'ü', 'ũ', 'ū', 'ŭ', 'ů', 'ű', 'ų', 'ư', 'ǔ', 'ụ', 'ủ', 'ứ', 'ừ', 'ử', 'ữ', 'ự',
        => "u",
        'Ŵ', 'ŵ' => "w",
        'Ý', 'Ÿ', 'Ŷ', 'Ỳ', 'Ỵ', 'Ỷ', 'Ỹ', 'ý', 'ÿ', 'ŷ', 'ỳ', 'ỵ', 'ỷ', 'ỹ' => "y",
        'Ź', 'Ż', 'Ž', 'ź', 'ż', 'ž' => "z",
        'Þ', 'þ' => "th",
        else => null,
    };
}

fn encodeUtf8Lower(codepoint: u21, buf: *[4]u8) []const u8 {
    const len = std.unicode.utf8Encode(codepoint, buf) catch return buf[0..0];
    return buf[0..len];
}

test "folded contains handles accents and case" {
    try std.testing.expect(containsFoldedIgnoreCase("São Paulo hoje", "sao"));
    try std.testing.expect(containsFoldedIgnoreCase("MÜNCHEN Wetter", "münchen"));
    try std.testing.expect(containsFoldedIgnoreCase("Die STRASSE ist lang", "straße"));
    try std.testing.expect(!containsFoldedIgnoreCase("Alpha Web RAG", "Brasilia"));
}
