const std = @import("std");
const db_mod = @import("db.zig");

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
    const cat = database.catalog orelse return error.CatalogNotConfigured;

    var token_bytes: [TOKEN_BYTES]u8 = undefined;
    io.random(&token_bytes);

    var token_hex: [TOKEN_HEX_LEN]u8 = undefined;
    bytesToHex(&token_hex, token_bytes);

    const now = std.Io.Timestamp.now(cat.io, .real).toSeconds();
    const expires = now + SESSION_DURATION_SECS;

    cat.cleanupExpiredSessions(now);
    _ = try cat.createSession(&token_hex, username, is_admin, expires);
    return try allocator.dupe(u8, &token_hex);
}

/// Looks up a session by token. Returns session info if valid, null if expired or not found.
pub fn getSession(database: *db_mod.Database, allocator: std.mem.Allocator, token: []const u8) !?SessionInfo {
    const cat = database.catalog orelse return error.CatalogNotConfigured;

    if (cat.getSession(token)) |sess| {
        const now = std.Io.Timestamp.now(cat.io, .real).toSeconds();
        if (sess.expires_at > now) {
            return SessionInfo{
                .username = try allocator.dupe(u8, sess.username),
                .is_admin = sess.is_admin,
            };
        }
    }
    return null;
}

/// Destroys a session by token (logout).
pub fn destroySession(database: *db_mod.Database, token: []const u8) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.deleteSession(token);
}

/// Extracts the session token from the Cookie header of an HTTP request.
pub fn extractSessionToken(target: []const u8, headers: anytype) ?[]const u8 {
    _ = target;
    var it = headers;
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            var cookie_it = std.mem.splitSequence(u8, header.value, "; ");
            while (cookie_it.next()) |cookie| {
                if (std.mem.startsWith(u8, cookie, "session=")) {
                    return cookie["session=".len..];
                }
            }
        }
    }
    return null;
}
