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

test "escapeJsonString and escapeJsonAlloc" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try utils.escapeJsonString(&buf, alloc, "Hello \"World\"\nLine 2\tTab\\Backslash\rCarriage");
    try testing.expectEqualStrings("Hello \\\"World\\\"\\nLine 2\\tTab\\\\Backslash\\rCarriage", buf.items);

    // Test escapeJsonAlloc fast path (clean string)
    const clean_res = try utils.escapeJsonAlloc(alloc, "SimpleCleanString123");
    defer alloc.free(clean_res);
    try testing.expectEqualStrings("SimpleCleanString123", clean_res);

    // Test escapeJsonAlloc with escapes
    const esc_res = try utils.escapeJsonAlloc(alloc, "{\"key\": \"val\\n\"}");
    defer alloc.free(esc_res);
    try testing.expectEqualStrings("{\\\"key\\\": \\\"val\\\\n\\\"}", esc_res);
}

test "escapeHtml with clean and special characters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try utils.escapeHtml(&buf, alloc, "<b>\"Tom & Jerry's\" Movie</b>");
    try testing.expectEqualStrings("&lt;b&gt;&quot;Tom &amp; Jerry&#39;s&quot; Movie&lt;/b&gt;", buf.items);

    buf.clearRetainingCapacity();
    try utils.escapeHtml(&buf, alloc, "Clean Movie Title 2024");
    try testing.expectEqualStrings("Clean Movie Title 2024", buf.items);
}

test "writePercentEncoded and writePercentEncodedQueryParam" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try utils.writePercentEncoded(&buf, alloc, "/movies/Star Wars #1?.mkv");
    try testing.expectEqualStrings("/movies/Star%20Wars%20%231%3F.mkv", buf.items);

    buf.clearRetainingCapacity();
    try utils.writePercentEncodedQueryParam(&buf, alloc, "foo=bar&baz=1/2");
    try testing.expectEqualStrings("foo%3Dbar%26baz%3D1%2F2", buf.items);
}

test "escapeForJs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try utils.escapeForJs(&buf, alloc, "alert('Hello \"<script>\" & \\')\n");
    try testing.expectEqualStrings("alert(\\'Hello \\\"\\u003cscript\\u003e\\\" & \\\\\\')\\n", buf.items);
}

test "isVideoFile case insensitivity" {
    const testing = std.testing;
    try testing.expect(utils.isVideoFile("movie.mkv"));
    try testing.expect(utils.isVideoFile("movie.MKV"));
    try testing.expect(utils.isVideoFile("video.mp4"));
    try testing.expect(utils.isVideoFile("video.MP4"));
    try testing.expect(utils.isVideoFile("clip.avi"));
    try testing.expect(utils.isVideoFile("clip.AVI"));
    try testing.expect(utils.isVideoFile("stream.ts"));
    try testing.expect(utils.isVideoFile("web.webm"));
    try testing.expect(utils.isVideoFile("film.mov"));
    try testing.expect(utils.isVideoFile("film.MOV"));

    try testing.expect(!utils.isVideoFile("subtitle.srt"));
    try testing.expect(!utils.isVideoFile("poster.jpg"));
    try testing.expect(!utils.isVideoFile("movie.mkv.bak"));
    try testing.expect(!utils.isVideoFile("mkv"));
    try testing.expect(!utils.isVideoFile(""));
}

test "urlDecode fast path and hex edge cases" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Fast path: clean string
    const res1 = try utils.urlDecode(alloc, "CleanStringWithoutAnyEncoding");
    defer alloc.free(res1);
    try testing.expectEqualStrings("CleanStringWithoutAnyEncoding", res1);

    // Lowercase hex decoding
    const res2 = try utils.urlDecode(alloc, "%2fpath%20to%20file");
    defer alloc.free(res2);
    try testing.expectEqualStrings("/path to file", res2);

    // Plus decoding
    const res3 = try utils.urlDecode(alloc, "one+two+three");
    defer alloc.free(res3);
    try testing.expectEqualStrings("one two three", res3);
}

test "parseQueryString with fragment" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const res = utils.parseQueryString(alloc, "/search?q=hello%20world&page=2#section", "q");
    try testing.expect(res != null);
    defer alloc.free(res.?);
    try testing.expectEqualStrings("hello world", res.?);

    const res2 = utils.parseQueryString(alloc, "/search?q=hello%20world&page=2#section", "page");
    try testing.expect(res2 != null);
    defer alloc.free(res2.?);
    try testing.expectEqualStrings("2", res2.?);
}


