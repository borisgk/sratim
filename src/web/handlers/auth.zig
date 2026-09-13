const std = @import("std");
const db_mod = @import("../../db/db.zig");
const users_mod = @import("../../db/users.zig");
const logging_mod = @import("../../db/logging.zig");
const session_mod = @import("../../db/session.zig");
const template_engine = @import("../../core/template.zig");
const utils = @import("../utils.zig");
const global_css: []const u8 = @embedFile("../style.css");

pub fn serveLoginPage(request: *std.http.Server.Request, allocator: std.mem.Allocator, error_message: []const u8) !void {
    try serveLoginPageWithRedirect(request, allocator, error_message, null);
}

pub fn serveLoginPageWithRedirect(request: *std.http.Server.Request, allocator: std.mem.Allocator, error_message: []const u8, redirect_override: ?[]const u8) !void {
    const show_error = if (error_message.len > 0) "block" else "none";
    const msg = if (error_message.len > 0) error_message else "";

    var redirect_val: []const u8 = "";
    var redirect_alloc: ?[]const u8 = null;
    defer if (redirect_alloc) |r| allocator.free(r);

    if (redirect_override) |ro| {
        if (utils.isValidRedirect(ro)) {
            redirect_val = ro;
        }
    } else {
        if (utils.parseQueryString(allocator, request.head.target, "redirect")) |r| {
            redirect_alloc = r;
            if (utils.isValidRedirect(r)) {
                redirect_val = r;
            }
        }
    }

    const html_content = try template_engine.render(allocator, @embedFile("../templates/login.html"), .{
        .INLINE_CSS = global_css,
        .ERROR_DISPLAY = show_error,
        .ERROR_MESSAGE = msg,
        .REDIRECT = redirect_val,
    });

    request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html" },
        },
    }) catch return;
}

/// Handles POST /login — validates credentials and creates a session.
pub fn handleLoginPost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, logs_database: *db_mod.Database, body_buf: *[8192]u8, io: std.Io) !void {
    var client_ip: []const u8 = "127.0.0.1";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for") or std.ascii.eqlIgnoreCase(header.name, "x-real-ip")) {
            client_ip = header.value;
            break;
        }
    }

    // Read request body
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    // Parse form data (application/x-www-form-urlencoded)
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var redirect: ?[]const u8 = null;
    defer if (redirect) |r| allocator.free(r);

    var pairs = std.mem.splitScalar(u8, body_data.items, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "username=")) {
            const raw = pair[9..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            username = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "password=")) {
            const raw = pair[9..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            password = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "redirect=")) {
            const raw = pair[9..];
            if (raw.len > 0) {
                const decoded = allocator.dupe(u8, raw) catch continue;
                redirect = std.Uri.percentDecodeInPlace(decoded);
            }
        }
    }

    if (redirect == null or redirect.?.len == 0) {
        redirect = utils.parseQueryString(allocator, request.head.target, "redirect");
    }

    if (username == null or password == null) {
        try serveLoginPageWithRedirect(request, allocator, "Please enter both username and password.", redirect);
        return;
    }

    // Verify credentials
    const valid = users_mod.verifyPassword(database, allocator, username.?, password.?) catch false;
    if (!valid) {
        if (username) |u| {
            logging_mod.logLoginAttempt(logs_database, u, "failed", client_ip) catch |err| {
                std.debug.print("Failed to log failed auth attempt: {}\n", .{err});
            };
        }
        try serveLoginPageWithRedirect(request, allocator, "Invalid username or password.", redirect);
        return;
    }

    // Check if user is admin
    const is_admin = users_mod.isAdmin(database, username.?) catch false;

    // Log successful login
    logging_mod.logLoginAttempt(logs_database, username.?, "success", client_ip) catch |err| {
        std.debug.print("Failed to log successful auth attempt: {}\n", .{err});
    };

    // Create session
    const token = try session_mod.createSession(database, allocator, io, username.?, is_admin);
    const cookie_value = try std.fmt.allocPrint(allocator, "session={s}; Path=/; HttpOnly; SameSite=Strict", .{token});

    var target_location: []const u8 = "/";
    if (redirect) |r| {
        if (utils.isValidRedirect(r)) {
            target_location = r;
        }
    }

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = target_location },
            .{ .name = "set-cookie", .value = cookie_value },
        },
    }) catch return;
}

/// Handles GET /logout — destroys session and redirects.
pub fn handleLogout(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database) !void {
    const token = extractCookieToken(request);
    if (token) |t| {
        session_mod.destroySession(database, t) catch {};
    }
    _ = allocator;

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/login" },
            .{ .name = "set-cookie", .value = "session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" },
        },
    }) catch return;
}

/// Extracts the session token from Cookie headers.
pub fn extractCookieToken(request: *std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            var cookie_it = std.mem.splitSequence(u8, header.value, "; ");
            while (cookie_it.next()) |cookie| {
                if (std.mem.startsWith(u8, cookie, "session=")) {
                    return cookie[8..];
                }
            }
        }
    }
    return null;
}
