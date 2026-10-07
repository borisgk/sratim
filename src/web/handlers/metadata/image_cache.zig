const std = @import("std");
const config_mod = @import("../../../config.zig");
const tmdb = @import("../../../media/tmdb.zig");
const tmdb_client = @import("../../../media/tmdb/client.zig");
const main = @import("../../../main.zig");

pub fn handleApiImageCache(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
) !void {
    var raw_path: []const u8 = "";
    if (std.mem.indexOf(u8, request.head.target, "?")) |q_idx| {
        const params = request.head.target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "path=")) {
                raw_path = param[5..];
            }
        }
    }

    if (raw_path.len == 0) {
        request.respond("Missing path parameter", .{ .status = .bad_request }) catch return;
        return;
    }

    const decoded = try allocator.dupe(u8, raw_path);
    defer allocator.free(decoded);
    const path = std.Uri.percentDecodeInPlace(decoded);

    // Disallow path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        request.respond("Invalid path", .{ .status = .bad_request }) catch return;
        return;
    }

    var clean = path;
    if (std.mem.startsWith(u8, clean, "/")) clean = clean[1..];
    if (std.mem.startsWith(u8, clean, "images/")) clean = clean[7..];

    // If it's a direct profile filename without directories (e.g. "abc.jpg")
    if (std.mem.indexOfScalar(u8, clean, '/') == null) {
        const p = try std.fmt.allocPrint(allocator, "/{s}", .{clean});
        defer allocator.free(p);
        tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch |err| {
            std.debug.print("handleApiImageCache downloadProfileImage error: {}\n", .{err});
        };
    } else if (std.mem.startsWith(u8, clean, "profiles/w185/")) {
        const p = clean["profiles/w185".len..];
        tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch |err| {
            std.debug.print("handleApiImageCache downloadProfileImage error: {}\n", .{err});
        };
    } else {
        // Format: {category}/{size}/{filename}, e.g. "posters/w500/abc.jpg"
        if (std.mem.indexOfScalar(u8, clean, '/')) |slash_idx| {
            const tmdb_subpath = clean[slash_idx + 1 ..];
            const dest_file = try std.fmt.allocPrint(allocator, "images/{s}", .{clean});
            defer allocator.free(dest_file);

            if (main.app_dir.statFile(io, dest_file, .{})) |_| {
                // Already cached
            } else |_| {
                const tmdb_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/{s}", .{tmdb_subpath});
                defer allocator.free(tmdb_url);

                if (tmdb_client.createClient(allocator, config.tmdb_proxy)) |*client_val| {
                    var client = client_val.*;
                    defer client.deinit();

                    if (client.get(tmdb_url, .{})) |response| {
                        var res = response;
                        defer res.deinit();
                        if (res.status.isSuccess() and res.body != null) {
                            if (std.mem.lastIndexOfScalar(u8, dest_file, '/')) |last_slash| {
                                main.app_dir.createDirPath(io, dest_file[0..last_slash]) catch {};
                            }
                            main.app_dir.writeFile(io, .{ .sub_path = dest_file, .data = res.body.? }) catch {};
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    var headers_buf: [2]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    request.respond("{\"success\":true}", .{ .extra_headers = &headers_buf, .status = .ok }) catch return;
}
