const std = @import("std");
const httpx = @import("httpx");

pub const TmdbMovie = struct {
    id: i64,
    title: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,
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

pub fn downloadImages(allocator: std.mem.Allocator, io: std.Io, poster_path: ?[]const u8, backdrop_path: ?[]const u8, proxy_url: ?[]const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, "images") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters/original") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters/w500") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters/w185") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/backdrops") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/backdrops/original") catch |err| std.debug.print("Dir create err: {}\n", .{err});

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

    var client = httpx.Client.initWithConfig(allocator, config);
    defer client.deinit();

    if (poster_path) |poster| {
        // Download w185 poster
        const poster_w185_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/w185{s}", .{poster});
        defer allocator.free(poster_w185_url);
        if (client.get(poster_w185_url, .{})) |response| {
            var res = response;
            defer res.deinit();
            if (res.status.isSuccess() and res.body != null) {
                const dest = try std.fmt.allocPrint(allocator, "images/posters/w185{s}", .{poster});
                defer allocator.free(dest);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = res.body.? }) catch |err| std.debug.print("Failed to save poster_w185: {}\n", .{err});
            } else {
                std.debug.print("TMDB poster_w185 returned HTTP {d}\n", .{res.status.code});
            }
        } else |err| {
            std.debug.print("Failed to download poster_w185: {}\n", .{err});
        }

        // Download w500 poster
        const poster_w500_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/w500{s}", .{poster});
        defer allocator.free(poster_w500_url);
        if (client.get(poster_w500_url, .{})) |response| {
            var res = response;
            defer res.deinit();
            if (res.status.isSuccess() and res.body != null) {
                const dest = try std.fmt.allocPrint(allocator, "images/posters/w500{s}", .{poster});
                defer allocator.free(dest);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = res.body.? }) catch |err| std.debug.print("Failed to save poster_w500: {}\n", .{err});
            } else {
                std.debug.print("TMDB poster_w500 returned HTTP {d}\n", .{res.status.code});
            }
        } else |err| {
            std.debug.print("Failed to download poster_w500: {}\n", .{err});
        }

        // Download original poster
        const poster_original_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/original{s}", .{poster});
        defer allocator.free(poster_original_url);
        if (client.get(poster_original_url, .{})) |response| {
            var res = response;
            defer res.deinit();
            if (res.status.isSuccess() and res.body != null) {
                const dest = try std.fmt.allocPrint(allocator, "images/posters/original{s}", .{poster});
                defer allocator.free(dest);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = res.body.? }) catch |err| std.debug.print("Failed to save poster_original: {}\n", .{err});
            } else {
                std.debug.print("TMDB poster_original returned HTTP {d}\n", .{res.status.code});
            }
        } else |err| {
            std.debug.print("Failed to download poster_original: {}\n", .{err});
        }
    }

    if (backdrop_path) |backdrop| {
        // Download original backdrop
        const backdrop_original_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/original{s}", .{backdrop});
        defer allocator.free(backdrop_original_url);
        if (client.get(backdrop_original_url, .{})) |response| {
            var res = response;
            defer res.deinit();
            if (res.status.isSuccess() and res.body != null) {
                const dest = try std.fmt.allocPrint(allocator, "images/backdrops/original{s}", .{backdrop});
                defer allocator.free(dest);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = res.body.? }) catch |err| std.debug.print("Failed to save backdrop_original: {}\n", .{err});
            } else {
                std.debug.print("TMDB backdrop_original returned HTTP {d}\n", .{res.status.code});
            }
        } else |err| {
            std.debug.print("Failed to download backdrop_original: {}\n", .{err});
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
    _ = io;

    // Configure proxy if provided
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

    var client = httpx.Client.initWithConfig(allocator, config);
    defer client.deinit();

    // Build Search URL
    var query_encoded = std.ArrayList(u8).empty;
    defer query_encoded.deinit(allocator);
    try writePercentEncoded(&query_encoded, allocator, query);

    const search_url = if (year) |y|
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}&primary_release_year={s}", .{query_encoded.items, y})
    else
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}", .{query_encoded.items});
    defer allocator.free(search_url);

    // Perform Fetch
    std.debug.print("TMDB Request URL: {s}\n", .{search_url});
    if (proxy_url) |p| {
        if (p.len > 0) {
            std.debug.print("TMDB Request Proxy: {s}\n", .{p});
        }
    }

    var response = try client.get(search_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB Response Status: {d}\n", .{response.status.code});
    const response_body = response.body orelse return error.EmptyResponseBody;
    std.debug.print("TMDB Response Body: {s}\n", .{response_body});

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    // Parse Response
    const response_parsed = try std.json.parseFromSlice(TmdbSearchResponse, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return response_parsed;
}

test "searchMovie test" {
    const allocator = std.testing.allocator;
    
    var file = std.fs.cwd().openFile("config.json", .{}) catch |err| {
        std.debug.print("Skipping test, config.json not found: {}\n", .{err});
        return;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024*1024);
    defer allocator.free(content);
    
    const Config = struct {
        tmdb_access_token: ?[]const u8 = null,
        tmdb_proxy: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    
    const token = parsed.value.tmdb_access_token orelse return;
    if (token.len == 0) return;
    
    var t = std.Io.Threaded.init(allocator, .{});
    const io = t.io();
    
    const results = try searchMovie(allocator, io, "Inception", "2010", token, parsed.value.tmdb_proxy);
    defer results.deinit();
    
    try std.testing.expect(results.value.results.len > 0);
    std.debug.print("Search result first movie: {s}\n", .{results.value.results[0].title});
}

