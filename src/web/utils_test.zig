const std = @import("std");
const utils = @import("utils.zig");

test "parseQueryString and isValidRedirect" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const query_target = "/login?redirect=%2Fdetails%3Fid%3D26";
    const res = utils.parseQueryString(alloc, query_target, "redirect");
    try testing.expect(res != null);
    defer alloc.free(res.?);
    try testing.expectEqualStrings("/details?id=26", res.?);
    try testing.expect(utils.isValidRedirect(res.?));

    try testing.expect(!utils.isValidRedirect("https://evil.com"));
    try testing.expect(!utils.isValidRedirect("//evil.com"));
    try testing.expect(!utils.isValidRedirect("/\\evil.com"));
    try testing.expect(!utils.isValidRedirect(""));
    try testing.expect(utils.isValidRedirect("/"));
    try testing.expect(utils.isValidRedirect("/details?id=26"));
}

test "parseQueryInt robust parsing" {
    const testing = std.testing;
    try testing.expectEqual(@as(?i64, 2183), utils.parseQueryInt(i64, "/details?id=2183%20Watch%20Fiddler%20on%20the%20Roof%20on%20Sratim", "id"));
    try testing.expectEqual(@as(?i64, 2183), utils.parseQueryInt(i64, "/details?id=2183", "id"));
    try testing.expectEqual(@as(?i64, 2183), utils.parseQueryInt(i64, "/details?id=2183&start=0", "id"));
    try testing.expectEqual(@as(?i64, 2183), utils.parseQueryInt(i64, "/details?id=2183#header", "id"));
    try testing.expectEqual(@as(?i64, 2183), utils.parseQueryInt(i64, "/details?id=+2183", "id"));
    try testing.expectEqual(@as(?i64, -2183), utils.parseQueryInt(i64, "/details?id=-2183", "id"));
    try testing.expectEqual(@as(?i64, null), utils.parseQueryInt(i64, "/details?id=abc", "id"));
    try testing.expectEqual(@as(?f64, 42.5), utils.parseQueryFloat("/watch?pos=42.5s", "pos"));
}

test "getLanIp does not crash" {
    const testing = std.testing;
    const ip = try utils.getLanIp(testing.allocator);
    if (ip) |val| {
        defer testing.allocator.free(val);
        try testing.expect(val.len > 0);
        // Verify format is standard dotted IPv4
        var it = std.mem.splitScalar(u8, val, '.');
        var octets: usize = 0;
        while (it.next()) |oct| {
            _ = try std.fmt.parseInt(u8, oct, 10);
            octets += 1;
        }
        try testing.expectEqual(@as(usize, 4), octets);
    }
}
