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
pub const handleGetMovie = media.handleGetMovie;
pub const handleGetShow = media.handleGetShow;

/// Central router for /api/v1/* endpoints.
pub fn route(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    session_info_opt: ?session_mod.SessionInfo,
    body_buf: *[8192]u8,
) !bool {
    const target = request.head.target;

    if (!std.mem.startsWith(u8, target, "/api/v1/")) {
        return false;
    }

    // Public route: login
    if (std.mem.eql(u8, target, "/api/v1/login")) {
        try auth.handleLogin(request, allocator, database, logs_database, body_buf, io);
        return true;
    }

    // Protected routes: require session
    if (session_info_opt == null) {
        try request.respond("{\"success\":false,\"error\":\"Unauthorized\"}", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return true;
    }

    if (std.mem.eql(u8, target, "/api/v1/libraries")) {
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
