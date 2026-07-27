const std = @import("std");
const db_mod = @import("../../db/db.zig");
const session_mod = @import("../../db/session.zig");
const admin_handler = @import("../handlers/admin.zig");
const users_admin_handler = @import("../handlers/users_admin.zig");
const unmatched_admin_handler = @import("../handlers/unmatched_admin.zig");

pub fn route(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    session_info_opt: ?session_mod.SessionInfo,
    resp_buf: *[8192]u8,
) !bool {
    const target = request.head.target;
    const method = request.head.method;

    if (!std.mem.startsWith(u8, target, "/admin")) {
        return false; // Not handled
    }

    if (session_info_opt == null) {
        try request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "location", .value = "/login" },
            },
        });
        return true;
    }

    const session_info = session_info_opt.?;

    if (!session_info.is_admin) {
        try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
        return true;
    }

    if (std.mem.eql(u8, target, "/admin")) {
        admin_handler.serveAdminPage(request, allocator, database) catch |err| {
            std.debug.print("Admin handler error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.eql(u8, target, "/admin/users")) {
        users_admin_handler.serveUserManagementPage(request, allocator, database, session_info.username, "") catch |err| {
            std.debug.print("User management handler error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.eql(u8, target, "/admin/unmatched")) {
        unmatched_admin_handler.serveUnmatchedPage(request, allocator, database) catch |err| {
            std.debug.print("Unmatched page handler error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.eql(u8, target, "/admin/users/create") and method == .POST) {
        try users_admin_handler.handleCreateUserPost(request, allocator, database, io, resp_buf);
        return true;
    }

    if (std.mem.eql(u8, target, "/admin/users/delete") and method == .POST) {
        try users_admin_handler.handleDeleteUserPost(request, allocator, database, session_info.username, resp_buf);
        return true;
    }

    if (std.mem.eql(u8, target, "/admin/users/toggle-role") and method == .POST) {
        try users_admin_handler.handleToggleRolePost(request, allocator, database, session_info.username, resp_buf);
        return true;
    }

    if (std.mem.eql(u8, target, "/admin/users/reset-password") and method == .POST) {
        try users_admin_handler.handleResetPasswordPost(request, allocator, database, io, resp_buf);
        return true;
    }

    return false; // Matched /admin but not a specific route? Fallthrough or 404? Let's just return false.
}
