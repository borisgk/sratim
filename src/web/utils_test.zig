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

test "getFormValue and urlDecode" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const body = "username=john+doe&password=secret%21%40%23&role=admin";
    const user_raw = utils.getFormValue(body, "username");
    try testing.expect(user_raw != null);
    try testing.expectEqualStrings("john+doe", user_raw.?);

    const user_decoded = try utils.urlDecode(alloc, user_raw.?);
    defer alloc.free(user_decoded);
    try testing.expectEqualStrings("john doe", user_decoded);

    const pass_raw = utils.getFormValue(body, "password");
    try testing.expect(pass_raw != null);
    const pass_decoded = try utils.urlDecode(alloc, pass_raw.?);
    defer alloc.free(pass_decoded);
    try testing.expectEqualStrings("secret!@#", pass_decoded);

    try testing.expect(utils.getFormValue(body, "nonexistent") == null);
}

test "escapeJsonString" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try utils.escapeJsonString(&buf, alloc, "Hello \"World\"\nLine 2\tTab\\Backslash\rCarriage");
    try testing.expectEqualStrings("Hello \\\"World\\\"\\nLine 2\\tTab\\\\Backslash\\rCarriage", buf.items);
}

