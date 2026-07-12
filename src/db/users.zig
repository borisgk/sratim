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

/// Creates a new user with a hashed password and inserts into the database.
pub fn createUser(database: *db_mod.Database, io: std.Io, username: []const u8, password: []const u8, is_admin: bool) !void {
    // Generate random salt
    var salt: [SALT_LEN]u8 = undefined;
    io.random(&salt);

    // Derive key using PBKDF2
    var derived_key: [KEY_LEN]u8 = undefined;
    try pbkdf2(&derived_key, password, &salt, PBKDF2_ROUNDS, HmacSha256);

    // Convert to hex strings
    var hash_hex: [KEY_LEN * 2]u8 = undefined;
    bytesToHex(&hash_hex, derived_key);

    var salt_hex: [SALT_LEN * 2]u8 = undefined;
    saltToHex(&salt_hex, salt);

    // Insert into database
    var stmt = try database.prepare("INSERT INTO users (username, password_hash, salt, is_admin) VALUES (?1, ?2, ?3, ?4);");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindText(2, &hash_hex);
    try stmt.bindText(3, &salt_hex);
    try stmt.bindInt(4, if (is_admin) 1 else 0);

    _ = try stmt.step();
}

/// Verifies a password against the stored hash for a given username.
/// Returns true if the password matches, false otherwise (including if user not found).
pub fn verifyPassword(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !bool {
    var stmt = try database.prepare("SELECT password_hash, salt FROM users WHERE username = ?1;");
    defer stmt.finalize();

    try stmt.bindText(1, username);

    const result = try stmt.step();
    if (result != .row) return false;

    const stored_hash_hex = stmt.columnText(0) orelse return false;
    const stored_salt_hex = stmt.columnText(1) orelse return false;

    // Dupe the strings since they're owned by the statement
    const hash_copy = try allocator.dupe(u8, stored_hash_hex);
    defer allocator.free(hash_copy);
    const salt_copy = try allocator.dupe(u8, stored_salt_hex);
    defer allocator.free(salt_copy);

    // Decode hex salt
    const salt = hexToBytes(SALT_LEN, salt_copy) orelse return false;

    // Re-derive key from candidate password
    var derived_key: [KEY_LEN]u8 = undefined;
    try pbkdf2(&derived_key, password, &salt, PBKDF2_ROUNDS, HmacSha256);

    // Convert derived key to hex for comparison
    var derived_hex: [KEY_LEN * 2]u8 = undefined;
    bytesToHex(&derived_hex, derived_key);

    // Constant-time comparison
    return std.crypto.timing_safe.eql([KEY_LEN * 2]u8, derived_hex, hash_copy[0..KEY_LEN * 2].*);
}

/// Returns whether the given username is an admin.
pub fn isAdmin(database: *db_mod.Database, username: []const u8) !bool {
    var stmt = try database.prepare("SELECT is_admin FROM users WHERE username = ?1;");
    defer stmt.finalize();

    try stmt.bindText(1, username);

    const result = try stmt.step();
    if (result != .row) return false;

    return stmt.columnInt(0) != 0;
}

/// Ensures at least one admin user exists. Creates a default admin/admin if the table is empty.
pub fn ensureAdminExists(database: *db_mod.Database, io: std.Io) !void {
    var stmt = try database.prepare("SELECT COUNT(*) FROM users;");
    defer stmt.finalize();

    const result = try stmt.step();
    if (result != .row) return;

    const count = stmt.columnInt(0);
    if (count == 0) {
        try createUser(database, io, "admin", "admin", true);
        std.debug.print("\n⚠️  Default admin account created (username: admin, password: admin)\n⚠️  Please change the default password!\n\n", .{});
    }
}
