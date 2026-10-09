const std = @import("std");
const c = @import("../core/c.zig").c;

/// Parse an integer query parameter by name from a URL target string.
/// Robust against trailing whitespace, encoded characters, or fragment identifiers.
pub fn parseQueryInt(comptime T: type, target: []const u8, name: []const u8) ?T {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            const raw = param[name.len + 1 ..];
            var end_idx: usize = 0;
            if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) {
                end_idx = 1;
            }
            while (end_idx < raw.len and std.ascii.isDigit(raw[end_idx])) {
                end_idx += 1;
            }
            if (end_idx == 0 or (end_idx == 1 and (raw[0] == '+' or raw[0] == '-'))) return null;
            return std.fmt.parseInt(T, raw[0..end_idx], 10) catch null;
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
            const raw = param[name.len + 1 ..];
            var end_idx: usize = 0;
            if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) {
                end_idx = 1;
            }
            var has_dot = false;
            while (end_idx < raw.len) {
                const ch = raw[end_idx];
                if (std.ascii.isDigit(ch)) {
                    end_idx += 1;
                } else if (ch == '.' and !has_dot) {
                    has_dot = true;
                    end_idx += 1;
                } else {
                    break;
                }
            }
            if (end_idx == 0 or (end_idx == 1 and (raw[0] == '+' or raw[0] == '-'))) return null;
            return std.fmt.parseFloat(f64, raw[0..end_idx]) catch null;
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
        if (ifa.ifa_addr) |addr| {
            if (addr.family == c.AF_INET) {
                const flags = ifa.ifa_flags;
                if ((flags & @as(c_uint, @intCast(c.IFF_LOOPBACK))) != 0) continue;
                if ((flags & @as(c_uint, @intCast(c.IFF_UP))) == 0) continue;

                const sin = @as(*const c.sockaddr_in, @ptrCast(@alignCast(addr)));
                // sin.addr holds the address in network byte order; view its memory directly.
                // (Zig 0.17 @bitCast to arrays is LSB-first, which would reverse octets on big-endian.)
                const bytes: *const [4]u8 = @ptrCast(&sin.addr);
                return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                    bytes[0], bytes[1], bytes[2], bytes[3],
                });
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
            '\'' => try list.appendSlice(allocator, "%27"),
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
            '\'' => try list.appendSlice(allocator, "&#39;"),
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
            '\'' => try list.appendSlice(allocator, "%27"),
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
            const res = std.Uri.percentDecodeInPlace(decoded);
            if (res.len != decoded.len) {
                const final = allocator.dupe(u8, res) catch {
                    allocator.free(decoded);
                    return null;
                };
                allocator.free(decoded);
                return final;
            }
            return decoded;
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
    if (std.mem.indexOfScalar(u8, target, '"') != null) return false;
    if (std.mem.indexOfScalar(u8, target, '\'') != null) return false;
    if (std.mem.indexOfScalar(u8, target, '<') != null) return false;
    if (std.mem.indexOfScalar(u8, target, '>') != null) return false;
    for (target) |ch| {
        if (ch <= 32 or ch >= 127) return false;
    }
    return true;
}

/// Reads an HTTP request body completely into a newly allocated buffer.
/// Uses body_buf for reading chunks via request.readerExpectNone.
/// Caller owns the returned slice and must free it with allocator.
pub fn readRequestBody(request: *std.http.Server.Request, allocator: std.mem.Allocator, body_buf: []u8) ![]u8 {
    return readRequestBodyWithLimit(request, allocator, body_buf, 10 * 1024 * 1024);
}

/// Reads an HTTP request body up to max_size bytes into a newly allocated buffer.
/// Returns error.PayloadTooLarge if the incoming body exceeds max_size.
pub fn readRequestBodyWithLimit(request: *std.http.Server.Request, allocator: std.mem.Allocator, body_buf: []u8, max_size: usize) ![]u8 {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    errdefer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        if (body_data.items.len + n > max_size) {
            return error.PayloadTooLarge;
        }
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }
    return try body_data.toOwnedSlice(allocator);
}

/// Escapes a string for safe embedding into JSON string literals.
pub fn escapeJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
}

/// Escapes a string for safe embedding into JSON string literals, returning an allocated slice.
pub fn escapeJsonAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try escapeJsonString(&out, allocator, input);
    return out.toOwnedSlice(allocator);
}

/// Escapes a string for safe embedding into JavaScript string literals inside HTML templates.
pub fn escapeForJs(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\'' => try out.appendSlice(allocator, "\\'"),
            '<' => try out.appendSlice(allocator, "\\u003c"),
            '>' => try out.appendSlice(allocator, "\\u003e"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, ch),
        }
    }
}

/// Extracts the raw (encoded) value for a given key from an application/x-www-form-urlencoded body.
pub fn getFormValue(body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, key) and pair.len > key.len and pair[key.len] == '=') {
            return pair[key.len + 1 ..];
        }
    }
    return null;
}

/// Decodes an application/x-www-form-urlencoded value: converts '+' to space and decodes %XX sequences.
/// Caller owns the returned slice and must free it with allocator.
pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '+') {
            try list.append(allocator, ' ');
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch ' ';
            try list.append(allocator, byte);
            i += 3;
        } else {
            try list.append(allocator, input[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

