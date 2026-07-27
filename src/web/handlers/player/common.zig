const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const library_mod = @import("../../../db/library.zig");

pub const ResolvedMedia = struct {
    resolved_path: []const u8,
    file_path: []const u8,
};

/// Resolves a media file's absolute path from its database ID with path traversal checks.
pub fn resolveMediaPath(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    info_opt: ?metadata_mod.MovieInfo,
    working_folder: []const u8,
) !?ResolvedMedia {
    if (info_opt == null) return null;
    const media_info = info_opt.?;

    var base_path = try allocator.dupe(u8, working_folder);
    if (library_mod.getLibraryById(database, allocator, media_info.library_id) catch null) |lib| {
        allocator.free(base_path);
        base_path = try allocator.dupe(u8, lib.path);
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, media_info.file_path });
    const resolved_path = try std.fs.path.resolve(allocator, &[_][]const u8{full_path});
    const abs_base = try std.fs.path.resolve(allocator, &[_][]const u8{base_path});
    allocator.free(base_path);

    if (!std.mem.startsWith(u8, resolved_path, abs_base)) {
        return error.PathTraversal;
    }

    return ResolvedMedia{
        .resolved_path = resolved_path,
        .file_path = media_info.file_path,
    };
}
