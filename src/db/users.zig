const std = @import("std");
const db_mod = @import("db.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const pbkdf2 = std.crypto.pwhash.pbkdf2;

const PBKDF2_ROUNDS = 100_000;
const SALT_LEN = 16;
const KEY_LEN = 32;

/// Converts a byte slice to a hex string.
fn bytesToHex(out: *[KEY_LEN * 2]u8, bytes: [KEY_LEN]u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

/// Converts a salt byte slice to a hex string.
fn saltToHex(out: *[SALT_LEN * 2]u8, bytes: [SALT_LEN]u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

/// Converts a hex character to its nibble value.
fn hexCharToNibble(ch: u8) ?u4 {
    return switch (ch) {
        '0'...'9' => @intCast(ch - '0'),
        'a'...'f' => @intCast(ch - 'a' + 10),
        'A'...'F' => @intCast(ch - 'A' + 10),
        else => null,
    };
}

/// Converts a hex string to bytes.
fn hexToBytes(comptime len: usize, hex: []const u8) ?[len]u8 {
    if (hex.len != len * 2) return null;
    var result: [len]u8 = undefined;
    for (0..len) |i| {
        const high = hexCharToNibble(hex[i * 2]) orelse return null;
        const low = hexCharToNibble(hex[i * 2 + 1]) orelse return null;
        result[i] = (@as(u8, high) << 4) | @as(u8, low);
    }
    return result;
}

pub const User = struct {
    id: i64,
    username: []const u8,
    is_admin: bool,
};

/// Creates a new user with a hashed password and inserts into the database.
pub fn createUser(database: *db_mod.Database, io: std.Io, username: []const u8, password: []const u8, is_admin: bool) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;

    var salt: [SALT_LEN]u8 = undefined;
    io.random(&salt);

    var derived_key: [KEY_LEN]u8 = undefined;
    try pbkdf2(&derived_key, password, &salt, PBKDF2_ROUNDS, HmacSha256);

    var hash_hex: [KEY_LEN * 2]u8 = undefined;
    bytesToHex(&hash_hex, derived_key);

    var salt_hex: [SALT_LEN * 2]u8 = undefined;
    saltToHex(&salt_hex, salt);

    _ = try cat.createUser(username, &hash_hex, &salt_hex, is_admin);
    cat.snapshot() catch {};
}

/// Verifies a password against the stored hash for a given username.
pub fn verifyPassword(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !bool {
    _ = allocator;
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const user = cat.getUser(username) orelse return false;

    const salt = hexToBytes(SALT_LEN, user.salt) orelse return false;

    var derived_key: [KEY_LEN]u8 = undefined;
    try pbkdf2(&derived_key, password, &salt, PBKDF2_ROUNDS, HmacSha256);

    var derived_hex: [KEY_LEN * 2]u8 = undefined;
    bytesToHex(&derived_hex, derived_key);

    if (user.password_hash.len != KEY_LEN * 2) return false;
    return std.crypto.timing_safe.eql([KEY_LEN * 2]u8, derived_hex, user.password_hash[0..KEY_LEN * 2].*);
}

/// Returns whether the given username is an admin.
pub fn isAdmin(database: *db_mod.Database, username: []const u8) !bool {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    if (cat.getUser(username)) |u| {
        return u.is_admin;
    }
    return false;
}

/// Ensures at least one admin user exists. Creates a default admin/admin if the table is empty.
pub fn ensureAdminExists(database: *db_mod.Database, io: std.Io) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    if (cat.countUsers() == 0) {
        try createUser(database, io, "admin", "admin", true);
        std.debug.print("\n⚠️  Default admin account created (username: admin, password: admin)\n⚠️  Please change the default password!\n\n", .{});
    }
}

/// Returns total number of registered users.
pub fn getUserCount(database: *db_mod.Database) !i64 {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    return @intCast(cat.countUsers());
}

/// Retrieves all registered users. Caller owns the returned array and username strings.
pub fn getAllUsers(database: *db_mod.Database, allocator: std.mem.Allocator) ![]User {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const user_list = try cat.listUsers(allocator);
    defer {
        for (user_list) |*u| {
            var mut = u.*;
            mut.deinit(allocator);
        }
        allocator.free(user_list);
    }

    var list = std.ArrayList(User).empty;
    errdefer {
        for (list.items) |item| allocator.free(item.username);
        list.deinit(allocator);
    }

    for (user_list) |u| {
        try list.append(allocator, .{
            .id = u.id,
            .username = try allocator.dupe(u8, u.username),
            .is_admin = u.is_admin,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Deletes a user by ID.
pub fn deleteUserById(database: *db_mod.Database, id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    try cat.deleteUserById(id);
    cat.snapshot() catch {};
}

/// Toggles admin role for a user by ID.
pub fn toggleAdminRole(database: *db_mod.Database, id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    try cat.toggleAdminRole(id);
    cat.snapshot() catch {};
}

/// Resets a user's password by ID.
pub fn resetUserPassword(database: *db_mod.Database, io: std.Io, id: i64, new_password: []const u8) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;

    var salt: [SALT_LEN]u8 = undefined;
    io.random(&salt);

    var derived_key: [KEY_LEN]u8 = undefined;
    try pbkdf2(&derived_key, new_password, &salt, PBKDF2_ROUNDS, HmacSha256);

    var hash_hex: [KEY_LEN * 2]u8 = undefined;
    bytesToHex(&hash_hex, derived_key);

    var salt_hex: [SALT_LEN * 2]u8 = undefined;
    saltToHex(&salt_hex, salt);

    try cat.updateUserPasswordById(id, &hash_hex, &salt_hex);
    cat.snapshot() catch {};
}
