const std = @import("std");
const db_mod = @import("../../db/db.zig");
const session_mod = @import("../../db/session.zig");
const config_mod = @import("../../config.zig");

pub const auth = @import("../handlers/api_v1/auth.zig");
pub const library = @import("../handlers/api_v1/library.zig");
pub const media = @import("../handlers/api_v1/media.zig");

// Re-export handlers for backward compatibility
pub const handleLogin = auth.handleLogin;
pub const handleGetLibraries = library.handleGetLibraries;
pub const handleGetLibraryItems = library.handleGetLibraryItems;
pub const handleRenameLibrary = library.handleRenameLibrary;
pub const handleDeleteLibrary = library.handleDeleteLibrary;
pub const handleGetMovie = media.handleGetMovie;
pub const handleGetShow = media.handleGetShow;

/// Central router for /api/v1/* endpoints.
pub fn route(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    database: *db_mod.Database,
    session_info: session_mod.SessionInfo,
    body_buf: *[8192]u8,
) !bool {
    const target = request.head.target;

    if (!std.mem.startsWith(u8, target, "/api/v1/")) {
        return false;
    }

    // Public route: login
    if (std.mem.eql(u8, target, "/api/v1/login")) {
        try auth.handleLogin(request, allocator, database, body_buf, io);
        return true;
    }

    if (std.mem.eql(u8, target, "/api/v1/library/rename") or std.mem.eql(u8, target, "/api/v1/libraries/rename")) {
        try library.handleRenameLibrary(request, allocator, database, session_info.is_admin, body_buf);
        return true;
    } else if (std.mem.eql(u8, target, "/api/v1/library/delete") or std.mem.eql(u8, target, "/api/v1/libraries/delete")) {
        try library.handleDeleteLibrary(request, allocator, database, session_info.is_admin, body_buf);
        return true;
    } else if (std.mem.eql(u8, target, "/api/v1/libraries")) {
        try library.handleGetLibraries(request, allocator, database);
        return true;
    } else if (std.mem.startsWith(u8, target, "/api/v1/library?")) {
        try library.handleGetLibraryItems(request, allocator, database);
        return true;
    } else if (std.mem.startsWith(u8, target, "/api/v1/movie?")) {
        try media.handleGetMovie(request, allocator, database, config, io);
        return true;
    } else if (std.mem.startsWith(u8, target, "/api/v1/show?")) {
        try media.handleGetShow(request, allocator, database, config, io);
        return true;
    }

    return false;
}
