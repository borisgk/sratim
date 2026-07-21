const std = @import("std");
const client_mod = @import("client.zig");

pub fn downloadImages(allocator: std.mem.Allocator, io: std.Io, poster_path: ?[]const u8, backdrop_path: ?[]const u8, proxy_url: ?[]const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, "images") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters/original") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters/w500") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/posters/w185") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/backdrops") catch |err| std.debug.print("Dir create err: {}\n", .{err});
    std.Io.Dir.cwd().createDirPath(io, "images/backdrops/original") catch |err| std.debug.print("Dir create err: {}\n", .{err});

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    if (poster_path) |poster| {
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
