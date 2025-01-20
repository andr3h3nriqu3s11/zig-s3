/// Time formatting utilities for AWS Signature V4.
const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const time = std.time;

/// Format timestamp as YYYYMMDD for AWS date
pub fn formatDate(allocator: Allocator, timestamp: i64) ![]const u8 {
    const seconds = @as(u64, @intCast(timestamp));
    const epoch_seconds = seconds;
    const epoch_days = @divFloor(epoch_seconds, 86400);
    var days = @as(u32, @intCast(epoch_days));

    // Calculate year, month, day
    var year: u32 = 1970;
    while (days >= 365) {
        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
        const days_in_year = if (is_leap) @as(u32, 366) else @as(u32, 365);
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u32 = 1;
    const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);

    for (month_days, 0..) |days_in_month, i| {
        var adjusted_days = days_in_month;
        if (i == 1 and is_leap) adjusted_days += 1;
        if (days < adjusted_days) break;
        days -= adjusted_days;
        month += 1;
    }

    const day = days + 1;

    // Format as YYYYMMDD
    return fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}",
        .{ year, month, day },
    );
}

/// Format timestamp as YYYYMMDD'T'HHMMSS'Z' for AWS
pub fn formatAmzDateTime(allocator: Allocator, timestamp: i64) ![]const u8 {
    const date = try formatDate(allocator, timestamp);
    defer allocator.free(date);

    const seconds = @as(u64, @intCast(timestamp));
    const day_seconds = @mod(seconds, 86400);
    const hour = @divFloor(day_seconds, 3600);
    const minute = @divFloor(@mod(day_seconds, 3600), 60);
    const second = @mod(day_seconds, 60);

    return fmt.allocPrint(
        allocator,
        "{s}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{ date, hour, minute, second },
    );
}

/// Format timestamp as YYYYMMDD for AWS credential scope
pub fn formatAmzDate(allocator: Allocator, timestamp: i64) ![]const u8 {
    return formatDate(allocator, timestamp);
}

/// Check if a year is a leap year
fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

test "time formatting" {
    const allocator = std.testing.allocator;

    // Test case: 2013-05-24T00:00:00Z (1369353600)
    const timestamp: i64 = 1369353600;

    const datetime = try formatAmzDateTime(allocator, timestamp);
    defer allocator.free(datetime);
    try std.testing.expectEqualStrings("20130524T000000Z", datetime);

    const date = try formatAmzDate(allocator, timestamp);
    defer allocator.free(date);
    try std.testing.expectEqualStrings("20130524", date);
}

test "leap year" {
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(isLeapYear(2004));
    try std.testing.expect(!isLeapYear(2100));
    try std.testing.expect(!isLeapYear(2001));
}
