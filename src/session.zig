const std = @import("std");
const db_mod = @import("db.zig");
const c = @import("c.zig").c;

const TOKEN_BYTES = 32;
const TOKEN_HEX_LEN = TOKEN_BYTES * 2;
const SESSION_DURATION_SECS = 24 * 60 * 60; // 24 hours

/// Session information returned to the caller.
pub const SessionInfo = struct {
    username: []const u8,
    is_admin: bool,
};

/// Converts a byte slice to a hex string.
fn bytesToHex(out: *[TOKEN_HEX_LEN]u8, bytes: [TOKEN_BYTES]u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

/// Creates a new session for the given user and returns the hex-encoded session token.
pub fn createSession(database: *db_mod.Database, allocator: std.mem.Allocator, io: std.Io, username: []const u8, is_admin: bool) ![]const u8 {
    // Generate random token
    var token_bytes: [TOKEN_BYTES]u8 = undefined;
    io.random(&token_bytes);

    var token_hex: [TOKEN_HEX_LEN]u8 = undefined;
    bytesToHex(&token_hex, token_bytes);

    const now = c.time(null);
    const expires = now + SESSION_DURATION_SECS;

    // Clean up expired sessions while we're here
    cleanExpiredSessions(database, now) catch {};

    // Insert session
    var stmt = try database.prepare("INSERT INTO sessions (token, username, is_admin, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5);");
    defer stmt.finalize();

    try stmt.bindText(1, &token_hex);
    try stmt.bindText(2, username);
    try stmt.bindInt(3, if (is_admin) 1 else 0);
    try stmt.bindInt64(4, now);
    try stmt.bindInt64(5, expires);

    _ = try stmt.step();

    return try allocator.dupe(u8, &token_hex);
}

/// Looks up a session by token. Returns session info if valid, null if expired or not found.
pub fn getSession(database: *db_mod.Database, allocator: std.mem.Allocator, token: []const u8) !?SessionInfo {
    const now = c.time(null);

    var stmt = try database.prepare("SELECT username, is_admin FROM sessions WHERE token = ?1 AND expires_at > ?2;");
    defer stmt.finalize();

    try stmt.bindText(1, token);
    try stmt.bindInt64(2, now);

    const result = try stmt.step();
    if (result != .row) return null;

    const username = stmt.columnText(0) orelse return null;

    return .{
        .username = try allocator.dupe(u8, username),
        .is_admin = stmt.columnInt(1) != 0,
    };
}

/// Destroys a session by token (logout).
pub fn destroySession(database: *db_mod.Database, token: []const u8) !void {
    var stmt = try database.prepare("DELETE FROM sessions WHERE token = ?1;");
    defer stmt.finalize();

    try stmt.bindText(1, token);
    _ = try stmt.step();
}

/// Removes all expired sessions from the database.
fn cleanExpiredSessions(database: *db_mod.Database, now: i64) !void {
    var stmt = try database.prepare("DELETE FROM sessions WHERE expires_at <= ?1;");
    defer stmt.finalize();

    try stmt.bindInt64(1, now);
    _ = try stmt.step();
}

/// Extracts the session token from the Cookie header of an HTTP request.
pub fn extractSessionToken(target: []const u8, headers: anytype) ?[]const u8 {
    _ = target;
    var it = headers;
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            // Parse cookie string: "session=<token>; other=value"
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
