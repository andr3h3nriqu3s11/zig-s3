/// Time formatting utilities for AWS Signature V4.
const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const time = std.time;

/// Format timestamp as required by AWS (YYYYMMDD'T'HHMMSS'Z')
pub fn formatAmzDateTime(allocator: Allocator, timestamp: i64) ![]const u8 {
    const epoch_seconds = @as(u64, @intCast(timestamp));
    const epoch_days = epoch_seconds / (24 * 60 * 60);
    const day_seconds = epoch_seconds % (24 * 60 * 60);

    const year = @as(u16, @intCast(1970 + epoch_days / 365));
    var remaining_days = @as(u16, @intCast(epoch_days % 365));

    // Adjust for leap years
    var leap_days: u16 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        if (isLeapYear(y)) {
            leap_days += 1;
        }
    }
    remaining_days -= leap_days;

    // Calculate month and day
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u8 = 1;
    var day = remaining_days + 1;

    for (days_in_month) |days| {
        if (day <= days) break;
        day -= days;
        month += 1;
    }

    // Calculate hours, minutes, seconds
    const hours = @as(u8, @intCast(day_seconds / 3600));
    const minutes = @as(u8, @intCast((day_seconds % 3600) / 60));
    const seconds = @as(u8, @intCast(day_seconds % 60));

    return fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{ year, month, day, hours, minutes, seconds },
    );
}

/// Format date as required by AWS (YYYYMMDD)
pub fn formatAmzDate(allocator: Allocator, timestamp: i64) ![]const u8 {
    const datetime = try formatAmzDateTime(allocator, timestamp);
    defer allocator.free(datetime);
    return allocator.dupe(u8, datetime[0..8]); // First 8 characters (YYYYMMDD)
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
