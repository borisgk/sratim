const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const users_mod = @import("../../../db/users.zig");
const logging_mod = @import("../../../db/logging.zig");
const session_mod = @import("../../../db/session.zig");
const utils = @import("../../utils.zig");

const LoginPayload = struct {
    username: []const u8,
    password: []const u8,
};

pub fn handleLogin(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    body_buf: *[8192]u8,
    io: std.Io,
) !void {
    if (request.head.method != .POST) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    var client_ip: []const u8 = "127.0.0.1";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for") or std.ascii.eqlIgnoreCase(header.name, "x-real-ip")) {
            client_ip = header.value;
            break;
        }
    }

    const body_data = utils.readRequestBody(request, allocator, body_buf, 64 * 1024) catch {
        try request.respond("{\"success\":false,\"error\":\"Payload too large\"}", .{ .status = .payload_too_large });
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(LoginPayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse login JSON: {any}\n", .{err});
        try request.respond("{\"success\":false,\"error\":\"Bad request\"}", .{ .status = .bad_request });
        return;
    };
    defer parsed.deinit();

    const username = parsed.value.username;
    const password = parsed.value.password;

    const valid = users_mod.verifyPassword(database, allocator, username, password) catch false;
    if (!valid) {
        logging_mod.logLoginAttempt(database, username, "failed", client_ip) catch |err| {
            std.debug.print("Failed to log failed auth attempt: {}\n", .{err});
        };
        try request.respond("{\"success\":false,\"error\":\"Invalid credentials\"}", .{ .status = .unauthorized });
        return;
    }

    const is_admin = users_mod.isAdmin(database, username) catch false;

    logging_mod.logLoginAttempt(database, username, "success", client_ip) catch |err| {
        std.debug.print("Failed to log successful auth attempt: {}\n", .{err});
    };

    const token = try session_mod.createSession(database, allocator, io, username, is_admin);

    const is_admin_str = if (is_admin) "true" else "false";
    const resp_json = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"token\":\"{s}\",\"is_admin\":{s}}}", .{ token, is_admin_str });
    defer allocator.free(resp_json);

    try request.respond(resp_json, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
