const std = @import("std");

pub const TmdbMovie = struct {
    id: i64,
    title: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
};

pub const TmdbSearchResponse = struct {
    results: []TmdbMovie,
};

fn writePercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
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

pub fn searchMovie(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    year: ?[]const u8,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(TmdbSearchResponse) {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    // Configure proxy if provided
    var proxy: ?std.http.Client.Proxy = null;
    if (proxy_url) |p_url| {
        if (p_url.len > 0) {
            const uri = try std.Uri.parse(p_url);
            const host_bytes = switch (uri.host.?) {
                .raw => |r| r,
                .percent_encoded => |p| p,
            };
            const host_name = try std.Io.net.HostName.init(host_bytes);
            const protocol = std.http.Client.Protocol.fromScheme(uri.scheme) orelse return error.UnsupportedUriScheme;
            proxy = .{
                .protocol = protocol,
                .host = host_name,
                .port = uri.port orelse (if (protocol == .tls) 443 else 80),
                .authorization = null,
                .supports_connect = true,
            };
            client.http_proxy = &proxy.?;
            client.https_proxy = &proxy.?;
        }
    }

    // Build Search URL
    var query_encoded = std.ArrayList(u8).empty;
    defer query_encoded.deinit(allocator);
    try writePercentEncoded(&query_encoded, allocator, query);

    const search_url = if (year) |y|
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}&primary_release_year={s}", .{query_encoded.items, y})
    else
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}", .{query_encoded.items});
    defer allocator.free(search_url);

    // Build Auth Header
    const auth_header_val = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header_val);

    const extra_headers = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header_val },
        .{ .name = "Accept", .value = "application/json" },
    };

    // Perform Fetch
    std.debug.print("TMDB Request URL: {s}\n", .{search_url});
    if (proxy_url) |p| {
        if (p.len > 0) {
            std.debug.print("TMDB Request Proxy: {s}\n", .{p});
        }
    }

    var response_allocating = std.Io.Writer.Allocating.init(allocator);
    defer response_allocating.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .url = search_url },
        .method = .GET,
        .extra_headers = extra_headers,
        .response_writer = &response_allocating.writer,
    });

    std.debug.print("TMDB Response Status: {}\n", .{fetch_res.status});
    const response_body = response_allocating.written();
    std.debug.print("TMDB Response Body: {s}\n", .{response_body});

    if (fetch_res.status != .ok) {
        return error.TmdbRequestFailed;
    }

    // Parse Response
    const parsed = try std.json.parseFromSlice(TmdbSearchResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    
    return parsed;
}
