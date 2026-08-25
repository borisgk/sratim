const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const library_mod = @import("../../../db/library.zig");

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

    if (!std.mem.startsWith(u8, resolved_path, abs_base)) {
        allocator.free(resolved_path);
        return error.PathTraversal;
    }

    const file_path_dup = try allocator.dupe(u8, media_info.file_path);
    errdefer allocator.free(file_path_dup);

    return ResolvedMedia{
        .resolved_path = resolved_path,
        .file_path = file_path_dup,
    };
}
