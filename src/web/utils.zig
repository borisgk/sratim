const std = @import("std");
const c = @import("../core/c.zig").c;

/// Parse an integer query parameter by name from a URL target string.
pub fn parseQueryInt(comptime T: type, target: []const u8, name: []const u8) ?T {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            return std.fmt.parseInt(T, param[name.len + 1 ..], 10) catch null;
        }
    }
    return null;
}

/// Parse a float query parameter by name from a URL target string.
pub fn parseQueryFloat(target: []const u8, name: []const u8) ?f64 {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            return std.fmt.parseFloat(f64, param[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

pub fn getLanIp(allocator: std.mem.Allocator) !?[]const u8 {
    var ifap: ?*c.ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return null;
    if (ifap == null) return null;
    defer c.freeifaddrs(ifap);

    var curr = ifap;
    while (curr) |ifa| : (curr = ifa.ifa_next) {
        if (ifa.ifa_addr == null) continue;
        const family = ifa.ifa_addr.*.sa_family;
        if (family == c.AF_INET) {
            const flags = ifa.ifa_flags;
            if ((flags & @as(c_uint, @intCast(c.IFF_LOOPBACK))) != 0) continue;
            if ((flags & @as(c_uint, @intCast(c.IFF_UP))) == 0) continue;

            const sin = @as(*const c.sockaddr_in, @ptrCast(@alignCast(ifa.ifa_addr)));
            var buf: [c.INET_ADDRSTRLEN]u8 = undefined;
            if (c.inet_ntop(c.AF_INET, &sin.sin_addr, &buf, @intCast(buf.len))) |str| {
                const len = std.mem.sliceTo(str, 0).len;
                if (len > 0) {
                    return try allocator.dupe(u8, str[0..len]);
                }
            }
        }
    }
    return null;
}

const video_extensions = [_][]const u8{ ".mkv", ".mp4", ".avi", ".ts", ".webm", ".mov" };

pub fn isVideoFile(basename: []const u8) bool {
    for (video_extensions) |ext| {
        if (std.mem.endsWith(u8, basename, ext)) return true;
    }
    return false;
}

/// Percent-encodes a path for use in an HTML href attribute.
pub fn writePercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            ' ' => try list.appendSlice(allocator, "%20"),
            '#' => try list.appendSlice(allocator, "%23"),
            '?' => try list.appendSlice(allocator, "%3F"),
            '&' => try list.appendSlice(allocator, "%26"),
            '%' => try list.appendSlice(allocator, "%25"),
            '"' => try list.appendSlice(allocator, "%22"),
            '<' => try list.appendSlice(allocator, "%3C"),
            '>' => try list.appendSlice(allocator, "%3E"),
            '\''=> try list.appendSlice(allocator, "%27"),
            else => try list.append(allocator, ch),
        }
    }
}

/// Escapes HTML special characters for safe injection into text content.
pub fn escapeHtml(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '&' => try list.appendSlice(allocator, "&amp;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\''=> try list.appendSlice(allocator, "&#39;"),
            else => try list.append(allocator, ch),
        }
    }
}

/// Percent-encodes a string for safe embedding as a URL query parameter value.
pub fn writePercentEncodedQueryParam(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            ' ' => try list.appendSlice(allocator, "%20"),
            '/' => try list.appendSlice(allocator, "%2F"),
            '?' => try list.appendSlice(allocator, "%3F"),
            '=' => try list.appendSlice(allocator, "%3D"),
            '&' => try list.appendSlice(allocator, "%26"),
            '#' => try list.appendSlice(allocator, "%23"),
            '%' => try list.appendSlice(allocator, "%25"),
            '"' => try list.appendSlice(allocator, "%22"),
            '<' => try list.appendSlice(allocator, "%3C"),
            '>' => try list.appendSlice(allocator, "%3E"),
            '\''=> try list.appendSlice(allocator, "%27"),
            else => try list.append(allocator, ch),
        }
    }
}

/// Parse and percent-decode a string query parameter by name from a URL target string.
/// Caller owns the returned allocated slice if non-null.
pub fn parseQueryString(allocator: std.mem.Allocator, target: []const u8, name: []const u8) ?[]const u8 {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            const raw = param[name.len + 1 ..];
            const decoded = allocator.dupe(u8, raw) catch return null;
            return std.Uri.percentDecodeInPlace(decoded);
        }
    }
    return null;
}

/// Validates that a redirect target is a safe relative path on the same origin.
pub fn isValidRedirect(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] != '/') return false;
    if (target.len > 1 and target[1] == '/') return false;
    if (std.mem.indexOfScalar(u8, target, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, target, '\r') != null) return false;
    if (std.mem.indexOfScalar(u8, target, '\n') != null) return false;
    return true;
}

test "parseQueryString and isValidRedirect" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const query_target = "/login?redirect=%2Fdetails%3Fid%3D26";
    const res = parseQueryString(alloc, query_target, "redirect");
    try testing.expect(res != null);
    defer alloc.free(res.?);
    try testing.expectEqualStrings("/details?id=26", res.?);
    try testing.expect(isValidRedirect(res.?));

    try testing.expect(!isValidRedirect("https://evil.com"));
    try testing.expect(!isValidRedirect("//evil.com"));
    try testing.expect(!isValidRedirect("/\\evil.com"));
    try testing.expect(!isValidRedirect(""));
    try testing.expect(isValidRedirect("/"));
    try testing.expect(isValidRedirect("/details?id=26"));
}
