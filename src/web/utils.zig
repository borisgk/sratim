const std = @import("std");
const builtin = @import("builtin");

/// Parse an integer query parameter by name from a URL target string.
/// Robust against trailing whitespace, encoded characters, or fragment identifiers.
pub fn parseQueryInt(comptime T: type, target: []const u8, name: []const u8) ?T {
    const q_idx = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const after_q = target[q_idx + 1 ..];
    const query = if (std.mem.indexOfScalar(u8, after_q, '#')) |hash_idx|
        after_q[0..hash_idx]
    else
        after_q;
    var it = std.mem.splitScalar(u8, query, '&');
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
    const q_idx = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const after_q = target[q_idx + 1 ..];
    const query = if (std.mem.indexOfScalar(u8, after_q, '#')) |hash_idx|
        after_q[0..hash_idx]
    else
        after_q;
    var it = std.mem.splitScalar(u8, query, '&');
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
    if (builtin.os.tag == .linux) {
        const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/proc/net/fib_trie", .{ .ACCMODE = .RDONLY }, 0) catch return null;
        defer std.posix.close(fd);

        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return null;
        const content = buf[0..n];

        var it = std.mem.splitScalar(u8, content, '\n');
        var candidate_ip: ?[]const u8 = null;

        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "|-- ")) {
                const ip_part = trimmed[4..];
                if (std.mem.indexOfScalar(u8, ip_part, '.') != null and !std.mem.startsWith(u8, ip_part, "127.")) {
                    candidate_ip = ip_part;
                }
            } else if (candidate_ip != null and std.mem.indexOf(u8, trimmed, "host LOCAL") != null) {
                return try allocator.dupe(u8, candidate_ip.?);
            }
        }
    }
    return null;
}

const video_extensions = [_][]const u8{ ".mkv", ".mp4", ".avi", ".ts", ".webm", ".mov" };

pub fn isVideoFile(basename: []const u8) bool {
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return false;
    const ext = basename[dot_idx..];
    inline for (video_extensions) |valid_ext| {
        if (std.ascii.eqlIgnoreCase(ext, valid_ext)) return true;
    }
    return false;
}

/// Percent-encodes a path for use in an HTML href attribute.
pub fn writePercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    try list.ensureUnusedCapacity(allocator, input.len);
    var start: usize = 0;
    for (input, 0..) |ch, i| {
        const replacement = switch (ch) {
            ' ' => "%20",
            '#' => "%23",
            '?' => "%3F",
            '&' => "%26",
            '%' => "%25",
            '"' => "%22",
            '<' => "%3C",
            '>' => "%3E",
            '\'' => "%27",
            else => continue,
        };
        if (i > start) {
            try list.appendSlice(allocator, input[start..i]);
        }
        try list.appendSlice(allocator, replacement);
        start = i + 1;
    }
    if (start < input.len) {
        try list.appendSlice(allocator, input[start..]);
    }
}

/// Escapes HTML special characters for safe injection into text content.
pub fn escapeHtml(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    try list.ensureUnusedCapacity(allocator, input.len);
    var start: usize = 0;
    for (input, 0..) |ch, i| {
        const replacement = switch (ch) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        if (i > start) {
            try list.appendSlice(allocator, input[start..i]);
        }
        try list.appendSlice(allocator, replacement);
        start = i + 1;
    }
    if (start < input.len) {
        try list.appendSlice(allocator, input[start..]);
    }
}

/// Percent-encodes a string for safe embedding as a URL query parameter value.
pub fn writePercentEncodedQueryParam(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    try list.ensureUnusedCapacity(allocator, input.len);
    var start: usize = 0;
    for (input, 0..) |ch, i| {
        const replacement = switch (ch) {
            ' ' => "%20",
            '/' => "%2F",
            '?' => "%3F",
            '=' => "%3D",
            '&' => "%26",
            '#' => "%23",
            '%' => "%25",
            '"' => "%22",
            '<' => "%3C",
            '>' => "%3E",
            '\'' => "%27",
            else => continue,
        };
        if (i > start) {
            try list.appendSlice(allocator, input[start..i]);
        }
        try list.appendSlice(allocator, replacement);
        start = i + 1;
    }
    if (start < input.len) {
        try list.appendSlice(allocator, input[start..]);
    }
}

/// Parse and percent-decode a string query parameter by name from a URL target string.
/// Caller owns the returned allocated slice if non-null.
pub fn parseQueryString(allocator: std.mem.Allocator, target: []const u8, name: []const u8) ?[]const u8 {
    const q_idx = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const after_q = target[q_idx + 1 ..];
    const query = if (std.mem.indexOfScalar(u8, after_q, '#')) |hash_idx|
        after_q[0..hash_idx]
    else
        after_q;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            const raw = param[name.len + 1 ..];
            // Fast path: if no percent-encoding is present, dupe directly
            if (std.mem.indexOfScalar(u8, raw, '%') == null) {
                return allocator.dupe(u8, raw) catch null;
            }
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
    if (target.len == 0 or target[0] != '/') return false;
    if (target.len > 1 and target[1] == '/') return false;
    for (target) |ch| {
        if (ch <= 32 or ch >= 127) return false;
        switch (ch) {
            '\\', '"', '\'', '<', '>' => return false,
            else => {},
        }
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
    if (request.head.content_length) |cl| {
        if (cl > max_size) return error.PayloadTooLarge;
    }

    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    errdefer body_data.deinit(allocator);

    if (request.head.content_length) |cl| {
        try body_data.ensureTotalCapacity(allocator, @intCast(cl));
    }

    var chunk_buf: [8192]u8 = undefined;
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
    try out.ensureUnusedCapacity(allocator, input.len);
    var start: usize = 0;
    for (input, 0..) |ch, i| {
        const replacement = switch (ch) {
            '\\' => "\\\\",
            '"' => "\\\"",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => continue,
        };
        if (i > start) {
            try out.appendSlice(allocator, input[start..i]);
        }
        try out.appendSlice(allocator, replacement);
        start = i + 1;
    }
    if (start < input.len) {
        try out.appendSlice(allocator, input[start..]);
    }
}

/// Escapes a string for safe embedding into JSON string literals, returning an allocated slice.
pub fn escapeJsonAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, input, "\\\"\n\r\t") == null) {
        return try allocator.dupe(u8, input);
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try escapeJsonString(&out, allocator, input);
    return out.toOwnedSlice(allocator);
}

/// Escapes a string for safe embedding into JavaScript string literals inside HTML templates.
pub fn escapeForJs(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    try out.ensureUnusedCapacity(allocator, input.len);
    var start: usize = 0;
    for (input, 0..) |ch, i| {
        const replacement = switch (ch) {
            '\\' => "\\\\",
            '"' => "\\\"",
            '\'' => "\\'",
            '<' => "\\u003c",
            '>' => "\\u003e",
            '\n' => "\\n",
            '\r' => "\\r",
            else => continue,
        };
        if (i > start) {
            try out.appendSlice(allocator, input[start..i]);
        }
        try out.appendSlice(allocator, replacement);
        start = i + 1;
    }
    if (start < input.len) {
        try out.appendSlice(allocator, input[start..]);
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

inline fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// Decodes an application/x-www-form-urlencoded value: converts '+' to space and decodes %XX sequences.
/// Caller owns the returned slice and must free it with allocator.
pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Fast path: if there are no '+' or '%' characters, dupe directly.
    if (std.mem.indexOfAny(u8, input, "+%") == null) {
        return try allocator.dupe(u8, input);
    }

    const out = try allocator.alloc(u8, input.len);
    errdefer allocator.free(out);

    var i: usize = 0;
    var out_idx: usize = 0;
    while (i < input.len) {
        if (input[i] == '+') {
            out[out_idx] = ' ';
            out_idx += 1;
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const h1 = hexDigit(input[i + 1]);
            const h2 = hexDigit(input[i + 2]);
            if (h1 != null and h2 != null) {
                out[out_idx] = (h1.? << 4) | h2.?;
            } else {
                out[out_idx] = ' ';
            }
            out_idx += 1;
            i += 3;
        } else {
            out[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    if (out_idx == input.len) {
        return out;
    }
    return try allocator.realloc(out, out_idx);
}

