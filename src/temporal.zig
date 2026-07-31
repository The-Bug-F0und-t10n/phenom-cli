const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

pub const UtcDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

pub const LocalClockText = struct {
    date: []const u8,
    time: []const u8,
    weekday: []const u8,
    iso_weekday: u8,
    zone: []const u8,
    utc_offset: []const u8,
};

pub fn currentLocalClockText(
    date_buf: *[16]u8,
    time_buf: *[16]u8,
    zone_buf: *[32]u8,
    offset_buf: *[8]u8,
) LocalClockText {
    var timestamp = c.time(null);
    const local_ptr = c.localtime(&timestamp);
    if (local_ptr == null) {
        return .{
            .date = currentUtcDateText(date_buf),
            .time = "unknown",
            .weekday = "unknown",
            .iso_weekday = 0,
            .zone = "UTC",
            .utc_offset = "+0000",
        };
    }
    const local = local_ptr.*;
    return .{
        .date = formatLocalDate(date_buf, local) catch "unknown",
        .time = formatLocalTime(time_buf, local) catch "unknown",
        .weekday = weekdayName(local.tm_wday),
        .iso_weekday = isoWeekday(local.tm_wday),
        .zone = strftimeText(zone_buf, "%Z", local_ptr),
        .utc_offset = strftimeText(offset_buf, "%z", local_ptr),
    };
}

fn weekdayName(tm_weekday: c_int) []const u8 {
    return switch (tm_weekday) {
        0 => "Sunday",
        1 => "Monday",
        2 => "Tuesday",
        3 => "Wednesday",
        4 => "Thursday",
        5 => "Friday",
        6 => "Saturday",
        else => "unknown",
    };
}

fn isoWeekday(tm_weekday: c_int) u8 {
    return if (tm_weekday == 0) 7 else if (tm_weekday >= 1 and tm_weekday <= 6) @intCast(tm_weekday) else 0;
}

fn formatLocalDate(buf: *[16]u8, local: c.struct_tm) ![]const u8 {
    const year: u16 = @intCast(local.tm_year + 1900);
    const month: u8 = @intCast(local.tm_mon + 1);
    const day: u8 = @intCast(local.tm_mday);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
}

fn formatLocalTime(buf: *[16]u8, local: c.struct_tm) ![]const u8 {
    const hour: u8 = @intCast(local.tm_hour);
    const minute: u8 = @intCast(local.tm_min);
    const second: u8 = @intCast(local.tm_sec);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second });
}

fn strftimeText(buf: []u8, format: [*:0]const u8, local: *const c.struct_tm) []const u8 {
    const len = c.strftime(buf.ptr, buf.len, format, local);
    return if (len == 0) "unknown" else buf[0..len];
}

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

test "current local clock exposes complete system fields" {
    var date_buf: [16]u8 = undefined;
    var time_buf: [16]u8 = undefined;
    var zone_buf: [32]u8 = undefined;
    var offset_buf: [8]u8 = undefined;
    const clock = currentLocalClockText(&date_buf, &time_buf, &zone_buf, &offset_buf);
    try std.testing.expect(clock.date.len > 0);
    try std.testing.expect(clock.time.len > 0);
    try std.testing.expect(clock.weekday.len > 0);
    try std.testing.expect(clock.zone.len > 0);
    try std.testing.expect(clock.utc_offset.len > 0);
}

test "local clock fields use unsigned ISO formatting" {
    var local = std.mem.zeroes(c.struct_tm);
    local.tm_year = 126;
    local.tm_mon = 6;
    local.tm_mday = 31;
    local.tm_hour = 5;
    local.tm_min = 6;
    local.tm_sec = 7;
    local.tm_wday = 5;
    var date_buf: [16]u8 = undefined;
    var time_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-07-31", try formatLocalDate(&date_buf, local));
    try std.testing.expectEqualStrings("05:06:07", try formatLocalTime(&time_buf, local));
    try std.testing.expectEqualStrings("Friday", weekdayName(local.tm_wday));
    try std.testing.expectEqual(@as(u8, 5), isoWeekday(local.tm_wday));
}
