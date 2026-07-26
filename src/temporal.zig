const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

pub const UtcDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

pub fn currentUtcDateText(buf: *[16]u8) []const u8 {
    return utcDateText(buf, @intCast(c.time(null))) catch "unknown";
}

pub fn utcDateText(buf: *[16]u8, unix_seconds: i64) ![]const u8 {
    const date = utcDateFromUnixSeconds(unix_seconds);
    const year: u64 = @intCast(date.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, date.month, date.day });
}

pub fn utcDateFromUnixSeconds(unix_seconds: i64) UtcDate {
    const days = @divFloor(unix_seconds, 86_400);
    return civilFromDays(days);
}

fn civilFromDays(days_since_epoch: i64) UtcDate {
    const z = days_since_epoch + 719_468;
    const era = if (z >= 0) @divTrunc(z, 146_097) else @divTrunc(z - 146_096, 146_097);
    const doe_i = z - era * 146_097;
    const doe: u64 = @intCast(doe_i);
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    var year: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    if (month <= 2) year += 1;
    return .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

test "utc date conversion covers unix epoch and leap day" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", try utcDateText(&buf, 0));
    try std.testing.expectEqualStrings("2024-02-29", try utcDateText(&buf, 1_709_164_800));
}
