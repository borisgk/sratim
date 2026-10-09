const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const library_mod = @import("../../../db/library.zig");
const utils = @import("../../utils.zig");

pub const ResolvedMedia = struct {
    resolved_path: []const u8,
    file_path: []const u8,

    pub fn deinit(self: *ResolvedMedia, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved_path);
        allocator.free(self.file_path);
    }
};

/// Resolves a media file's absolute path from its database ID with path traversal checks.
pub fn resolveMediaPath(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    info_opt: ?metadata_mod.MovieInfo,
) !?ResolvedMedia {
    if (info_opt == null) return null;
    const media_info = info_opt.?;
    defer allocator.free(media_info.file_path);

    var base_path: []u8 = undefined;
    if (library_mod.getLibraryById(database, allocator, media_info.library_id) catch null) |lib| {
        base_path = try allocator.dupe(u8, lib.path);
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    } else {
        return error.LibraryNotFound;
    }
    defer allocator.free(base_path);

    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, media_info.file_path });
    defer allocator.free(full_path);

    const resolved_path = try std.fs.path.resolve(allocator, &[_][]const u8{full_path});
    errdefer allocator.free(resolved_path);

    const abs_base = try std.fs.path.resolve(allocator, &[_][]const u8{base_path});
    defer allocator.free(abs_base);

    const is_within = if (std.mem.startsWith(u8, resolved_path, abs_base)) blk: {
        if (resolved_path.len == abs_base.len) break :blk true;
        if (abs_base.len > 0 and abs_base[abs_base.len - 1] == std.fs.path.sep) break :blk true;
        if (resolved_path[abs_base.len] == std.fs.path.sep) break :blk true;
        break :blk false;
    } else false;

    if (!is_within) {
        return error.PathTraversal;
    }

    const file_path_dup = try allocator.dupe(u8, media_info.file_path);
    errdefer allocator.free(file_path_dup);

    return ResolvedMedia{
        .resolved_path = resolved_path,
        .file_path = file_path_dup,
    };
}

/// Extracts movie/episode ID from request query params, queries the database,
/// and resolves the absolute path with traversal checking.
/// If validation fails, an appropriate HTTP response is sent and null is returned.
pub fn resolveRequestMedia(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
) !?ResolvedMedia {
    const target = request.head.target;
    const movie_id = utils.parseQueryInt(i64, target, "id");
    const episode_id = utils.parseQueryInt(i64, target, "episode_id");

    if (movie_id == null and episode_id == null) {
        try request.respond("Missing id or episode_id parameter", .{ .status = .bad_request });
        return null;
    }

    const media_info_opt = if (movie_id != null)
        metadata_mod.getMovieInfoById(database, allocator, movie_id.?) catch null
    else
        metadata_mod.getEpisodeInfoById(database, allocator, episode_id.?) catch null;

    const resolved = resolveMediaPath(database, allocator, media_info_opt) catch |err| {
        if (err == error.PathTraversal) {
            try request.respond("Forbidden", .{ .status = .forbidden });
        } else {
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        }
        return null;
    };

    if (resolved) |res| {
        return res;
    } else {
        try request.respond("Media not found", .{ .status = .not_found });
        return null;
    }
}

