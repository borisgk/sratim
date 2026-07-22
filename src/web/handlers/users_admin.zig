const std = @import("std");
const db_mod = @import("../../db/db.zig");
const users_mod = @import("../../db/users.zig");
const template_engine = @import("../../core/template.zig");
const minify = @import("../../core/minify.zig");
const global_css: []const u8 = minify.minifyCss(@embedFile("../style.css"));

fn getFormValue(body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, body, "&");
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, key) and pair.len > key.len and pair[key.len] == '=') {
            return pair[key.len + 1 ..];
        }
    }
    return null;
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '+') {
            try list.append(allocator, ' ');
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch ' ';
            try list.append(allocator, byte);
            i += 3;
        } else {
            try list.append(allocator, input[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Escapes HTML characters for safe table injection.
fn escapeHtml(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '&' => try list.appendSlice(allocator, "&amp;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\''=> try list.appendSlice(allocator, "&#39;"),
            else => try list.append(allocator, ch),
        }
    }
}

/// Serves the User Management page at GET /admin/users
pub fn serveUserManagementPage(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    current_username: []const u8,
    notice_message: []const u8,
) !void {
    const users = try users_mod.getAllUsers(database, allocator);
    defer {
        for (users) |u| {
            allocator.free(u.username);
        }
        allocator.free(users);
    }

    var rows_buf = std.ArrayList(u8).empty;
    defer rows_buf.deinit(allocator);

    for (users) |u| {
        const is_current_user = std.mem.eql(u8, u.username, current_username);

        try rows_buf.appendSlice(allocator, "<tr>\n  <td>\n    <div class=\"user-cell\">\n      <div class=\"user-avatar\">");
        if (u.username.len > 0) {
            const initial = [1]u8{std.ascii.toUpper(u.username[0])};
            try rows_buf.appendSlice(allocator, &initial);
        } else {
            try rows_buf.appendSlice(allocator, "U");
        }
        try rows_buf.appendSlice(allocator, "</div>\n      <span class=\"user-name\">");
        try escapeHtml(&rows_buf, allocator, u.username);
        if (is_current_user) {
            try rows_buf.appendSlice(allocator, " <span class=\"you-badge\">(You)</span>");
        }
        try rows_buf.appendSlice(allocator, "</span>\n    </div>\n  </td>\n");

        // Role column
        if (u.is_admin) {
            try rows_buf.appendSlice(allocator, "  <td><span class=\"role-badge admin\">Admin</span></td>\n");
        } else {
            try rows_buf.appendSlice(allocator, "  <td><span class=\"role-badge user\">Standard User</span></td>\n");
        }

        // Actions column
        try rows_buf.appendSlice(allocator, "  <td style=\"text-align: right;\">\n    <div class=\"user-actions\">\n");

        // Toggle Admin form
        if (!is_current_user) {
            const toggle_html = try std.fmt.allocPrint(allocator,
                \\      <form method="POST" action="/admin/users/toggle-role" style="display:inline;">
                \\        <input type="hidden" name="user_id" value="{d}">
                \\        <button type="submit" class="action-btn toggle-btn" title="Toggle Admin Role">
                \\          {s}
                \\        </button>
                \\      </form>
                \\
            , .{
                u.id,
                if (u.is_admin) "Remove Admin" else "Make Admin",
            });
            defer allocator.free(toggle_html);
            try rows_buf.appendSlice(allocator, toggle_html);
        }

        // Reset Password button
        const reset_html = try std.fmt.allocPrint(allocator,
            \\      <button type="button" class="action-btn reset-btn" onclick="openResetModal({d}, '{s}')" title="Reset Password">
            \\        Reset Pwd
            \\      </button>
            \\
        , .{ u.id, u.username });
        defer allocator.free(reset_html);
        try rows_buf.appendSlice(allocator, reset_html);

        // Delete form
        if (!is_current_user) {
            const delete_html = try std.fmt.allocPrint(allocator,
                \\      <form method="POST" action="/admin/users/delete" style="display:inline;" onsubmit="return confirm('Are you sure you want to delete user {s}?');">
                \\        <input type="hidden" name="user_id" value="{d}">
                \\        <button type="submit" class="action-btn delete-btn" title="Delete User">
                \\          Delete
                \\        </button>
                \\      </form>
                \\
            , .{ u.username, u.id });
            defer allocator.free(delete_html);
            try rows_buf.appendSlice(allocator, delete_html);
        }

        try rows_buf.appendSlice(allocator, "    </div>\n  </td>\n</tr>\n");
    }

    const show_notice = if (notice_message.len > 0) "block" else "none";

    const html_content = try template_engine.render(allocator, @embedFile("../templates/users_management.html"), .{
        .INLINE_CSS = global_css,
        .USER_ROWS = rows_buf.items,
        .NOTICE_DISPLAY = show_notice,
        .NOTICE_MESSAGE = notice_message,
    });

    request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    }) catch return;
}

fn readRequestBody(request: *std.http.Server.Request, allocator: std.mem.Allocator, body_buf: *[8192]u8) ![]u8 {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    errdefer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }
    return body_data.toOwnedSlice(allocator);
}

/// Handles POST /admin/users/create
pub fn handleCreateUserPost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, io: std.Io, body_buf: *[8192]u8) !void {
    const body = try readRequestBody(request, allocator, body_buf);
    defer allocator.free(body);

    const username_enc = getFormValue(body, "username") orelse "";
    const password_enc = getFormValue(body, "password") orelse "";
    const is_admin_val = getFormValue(body, "is_admin") orelse "0";

    const username = try urlDecode(allocator, username_enc);
    defer allocator.free(username);
    const password = try urlDecode(allocator, password_enc);
    defer allocator.free(password);

    if (username.len > 0 and password.len > 0) {
        const is_admin = std.mem.eql(u8, is_admin_val, "1");
        users_mod.createUser(database, io, username, password, is_admin) catch |err| {
            std.debug.print("Create user error: {}\n", .{err});
        };
    }

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/admin/users" },
        },
    }) catch return;
}

/// Handles POST /admin/users/delete
pub fn handleDeleteUserPost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, current_username: []const u8, body_buf: *[8192]u8) !void {
    _ = current_username;
    const body = try readRequestBody(request, allocator, body_buf);
    defer allocator.free(body);

    const user_id_str = getFormValue(body, "user_id") orelse "";
    if (std.fmt.parseInt(i64, user_id_str, 10)) |id| {
        users_mod.deleteUserById(database, id) catch |err| {
            std.debug.print("Delete user error: {}\n", .{err});
        };
    } else |_| {}

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/admin/users" },
        },
    }) catch return;
}

/// Handles POST /admin/users/toggle-role
pub fn handleToggleRolePost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, current_username: []const u8, body_buf: *[8192]u8) !void {
    _ = current_username;
    const body = try readRequestBody(request, allocator, body_buf);
    defer allocator.free(body);

    const user_id_str = getFormValue(body, "user_id") orelse "";
    if (std.fmt.parseInt(i64, user_id_str, 10)) |id| {
        users_mod.toggleAdminRole(database, id) catch |err| {
            std.debug.print("Toggle role error: {}\n", .{err});
        };
    } else |_| {}

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/admin/users" },
        },
    }) catch return;
}

/// Handles POST /admin/users/reset-password
pub fn handleResetPasswordPost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, io: std.Io, body_buf: *[8192]u8) !void {
    const body = try readRequestBody(request, allocator, body_buf);
    defer allocator.free(body);

    const user_id_str = getFormValue(body, "user_id") orelse "";
    const new_pwd_enc = getFormValue(body, "new_password") orelse "";

    const new_password = try urlDecode(allocator, new_pwd_enc);
    defer allocator.free(new_password);

    if (new_password.len > 0) {
        if (std.fmt.parseInt(i64, user_id_str, 10)) |id| {
            users_mod.resetUserPassword(database, io, id, new_password) catch |err| {
                std.debug.print("Reset password error: {}\n", .{err});
            };
        } else |_| {}
    }

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/admin/users" },
        },
    }) catch return;
}
