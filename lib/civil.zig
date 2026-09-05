//! Civil time: Unix seconds to and from a calendar date and time of
//! day, UTC, and the ISO 8601 text of it (`2026-09-05T02:47:33Z`).
//! Proleptic Gregorian, the days-from-civil arithmetic of Howard
//! Hinnant; no zones, no leap seconds (Unix time has none). Pure and
//! host-tested; `date` in the language and the log use it.

const std = @import("std");

pub const Civil = struct {
    year: i64,
    month: u8, // 1..12
    day: u8, // 1..31
    hour: u8,
    minute: u8,
    second: u8,
    /// Days since 1970-01-01 (may be negative).
    days: i64,
    /// Monday = 1 … Sunday = 7 (ISO).
    weekday: u8,
};

/// The date and time of a Unix second.
pub fn fromUnix(secs: i64) Civil {
    const days = @divFloor(secs, 86400);
    const rem: u64 = @intCast(secs - days * 86400);
    // days → y/m/d (Hinnant's civil_from_days).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const wd: u8 = @intCast(@mod(days + 3, 7) + 1); // 1970-01-01 was a Thursday
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = m,
        .day = d,
        .hour = @intCast(rem / 3600),
        .minute = @intCast((rem % 3600) / 60),
        .second = @intCast(rem % 60),
        .days = days,
        .weekday = wd,
    };
}

/// The Unix second of a date and time (days_from_civil); no validation
/// beyond the arithmetic.
pub fn toUnix(year: i64, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const m: u64 = month;
    const doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days = era * 146097 + @as(i64, @intCast(doe)) - 719468;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

/// `2026-09-05T02:47:33Z`; `out` needs 20 bytes (more for years past 9999).
pub fn isoText(out: []u8, secs: i64) []const u8 {
    const c = fromUnix(secs);
    // A signed year would print with a sign when zero-padded.
    const sign: []const u8 = if (c.year < 0) "-" else "";
    const year: u64 = @intCast(if (c.year < 0) -c.year else c.year);
    return std.fmt.bufPrint(out, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ sign, year, c.month, c.day, c.hour, c.minute, c.second }) catch out[0..0];
}

/// Read ISO text back (`YYYY-MM-DDTHH:MM:SSZ`, the seconds optional).
pub fn parseIso(text: []const u8) ?i64 {
    if (text.len < 16 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':') return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
    var second: u8 = 0;
    if (text.len >= 19 and text[16] == ':') second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
    return toUnix(year, month, day, hour, minute, second);
}

test "civil: known dates both ways" {
    const c = fromUnix(1_788_576_453); // 2026-09-05T02:47:33Z
    try std.testing.expectEqual(@as(i64, 2026), c.year);
    try std.testing.expectEqual(@as(u8, 9), c.month);
    try std.testing.expectEqual(@as(u8, 5), c.day);
    try std.testing.expectEqual(@as(u8, 2), c.hour);
    try std.testing.expectEqual(@as(u8, 47), c.minute);
    try std.testing.expectEqual(@as(u8, 33), c.second);
    try std.testing.expectEqual(@as(u8, 6), c.weekday); // a Saturday
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-05T02:47:33Z", isoText(&buf, 1_788_576_453));
    try std.testing.expectEqual(@as(i64, 1_788_576_453), parseIso("2026-09-05T02:47:33Z").?);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", isoText(&buf, 0));
    try std.testing.expectEqual(@as(u8, 4), fromUnix(0).weekday); // a Thursday
    try std.testing.expectEqualStrings("1969-12-31T23:59:59Z", isoText(&buf, -1));
    try std.testing.expectEqualStrings("2000-02-29T12:00:00Z", isoText(&buf, toUnix(2000, 2, 29, 12, 0, 0)));
    try std.testing.expectEqualStrings("2100-03-01T00:00:00Z", isoText(&buf, toUnix(2100, 2, 28, 0, 0, 0) + 86400)); // 2100 is not a leap year
    var t: i64 = -2_000_000_000;
    while (t < 4_000_000_000) : (t += 86_400_000 + 12_345) {
        const cc = fromUnix(t);
        try std.testing.expectEqual(t, toUnix(cc.year, cc.month, cc.day, cc.hour, cc.minute, cc.second));
    }
    try std.testing.expect(parseIso("2026-13-01T00:00Z") == null);
    try std.testing.expect(parseIso("nope") == null);
}
