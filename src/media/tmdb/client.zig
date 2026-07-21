const std = @import("std");
const httpx = @import("httpx");

pub fn createClient(allocator: std.mem.Allocator, proxy_url: ?[]const u8) !httpx.Client {
    var config = httpx.ClientConfig.defaults();
    if (proxy_url) |p_url| {
        if (p_url.len > 0) {
            const uri = try std.Uri.parse(p_url);
            const host_bytes = switch (uri.host.?) {
                .raw => |r| r,
                .percent_encoded => |p| p,
            };

            var kind: httpx.ProxyKind = .http;
            if (std.mem.eql(u8, uri.scheme, "socks5") or
                std.mem.eql(u8, uri.scheme, "socks5h") or
                std.mem.eql(u8, uri.scheme, "socks"))
            {
                kind = .socks5h;
            }

            const port = uri.port orelse switch (kind) {
                .socks5h => 1080,
                .http => if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80),
            };

            config = config.withProxy(.{
                .kind = kind,
                .host = host_bytes,
                .port = port,
                .username = null,
                .password = null,
            });
        }
    }

    return httpx.Client.initWithConfig(allocator, config);
}

pub fn writePercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    const hex_chars = "0123456789ABCDEF";
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try list.append(allocator, ch);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, hex_chars[ch >> 4]);
            try list.append(allocator, hex_chars[ch & 15]);
        }
    }
}
