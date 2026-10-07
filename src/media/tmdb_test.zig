const std = @import("std");
const tmdb = @import("tmdb.zig");

test "parseYearAndCleanName tests" {
    const allocator = std.testing.allocator;

    {
        const res = try tmdb.parseYearAndCleanName(allocator, "Inception (2010)");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expectEqualStrings("2010", res.year.?);
    }

    {
        const res = try tmdb.parseYearAndCleanName(allocator, "Inception.2010.1080p");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expectEqualStrings("2010", res.year.?);
    }

    {
        const res = try tmdb.parseYearAndCleanName(allocator, "Inception");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expect(res.year == null);
    }
}
