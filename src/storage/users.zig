const std = @import("std");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const SratimStorage = engine.SratimStorage;

// =========================================================================
// User Operations
// =========================================================================

pub fn getUser(self: *SratimStorage, username: []const u8) ?schema.User {
    self.readLock();
    defer self.readUnlock();
    return self.users.get(username);
}

pub fn createUser(self: *SratimStorage, username: []const u8, password_hash: []const u8, salt: []const u8, is_admin: bool) !schema.User {
    self.writeLock();
    defer self.writeUnlock();

    if (self.users.contains(username)) return error.UserAlreadyExists;

    const id = self.next_user_id;
    self.next_user_id += 1;

    const u = schema.User{
        .id = id,
        .username = try self.allocator.dupe(u8, username),
        .password_hash = try self.allocator.dupe(u8, password_hash),
        .salt = try self.allocator.dupe(u8, salt),
        .is_admin = is_admin,
    };
    try self.users.put(u.username, u);
    return u;
}

pub fn updateUserPassword(self: *SratimStorage, username: []const u8, password_hash: []const u8, salt: []const u8) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.users.getPtr(username)) |ptr| {
        self.allocator.free(ptr.password_hash);
        self.allocator.free(ptr.salt);
        ptr.password_hash = try self.allocator.dupe(u8, password_hash);
        ptr.salt = try self.allocator.dupe(u8, salt);
    } else {
        return error.UserNotFound;
    }
}

pub fn deleteUser(self: *SratimStorage, username: []const u8) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.users.fetchRemove(username)) |kv| {
        var val = kv.value;
        val.deinit(self.allocator);
    } else {
        return error.UserNotFound;
    }
}

pub fn deleteUserById(self: *SratimStorage, id: i64) !void {
    self.writeLock();
    defer self.writeUnlock();

    var target_username: ?[]const u8 = null;
    var it = self.users.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.id == id) {
            target_username = e.key_ptr.*;
            break;
        }
    }
    if (target_username) |u| {
        if (self.users.fetchRemove(u)) |kv| {
            var val = kv.value;
            val.deinit(self.allocator);
        }
    } else {
        return error.UserNotFound;
    }
}

pub fn toggleAdminRole(self: *SratimStorage, id: i64) !void {
    self.writeLock();
    defer self.writeUnlock();

    var it = self.users.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.id == id) {
            e.value_ptr.is_admin = !e.value_ptr.is_admin;
            return;
        }
    }
    return error.UserNotFound;
}

pub fn updateUserPasswordById(self: *SratimStorage, id: i64, password_hash: []const u8, salt: []const u8) !void {
    self.writeLock();
    defer self.writeUnlock();

    var it = self.users.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.id == id) {
            self.allocator.free(e.value_ptr.password_hash);
            self.allocator.free(e.value_ptr.salt);
            e.value_ptr.password_hash = try self.allocator.dupe(u8, password_hash);
            e.value_ptr.salt = try self.allocator.dupe(u8, salt);
            return;
        }
    }
    return error.UserNotFound;
}

pub fn listUsers(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.User {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.User).empty;
    errdefer list.deinit(allocator);

    var it = self.users.iterator();
    while (it.next()) |e| {
        try list.append(allocator, try e.value_ptr.clone(allocator));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn countUsers(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    return self.users.count();
}

// =========================================================================
// Session Operations
// =========================================================================

pub fn createSession(self: *SratimStorage, token: []const u8, username: []const u8, is_admin: bool, expires_at: i64) !schema.Session {
    self.writeLock();
    defer self.writeUnlock();

    const s = schema.Session{
        .token = try self.allocator.dupe(u8, token),
        .username = try self.allocator.dupe(u8, username),
        .is_admin = is_admin,
        .created_at = self.now(),
        .expires_at = expires_at,
    };
    try self.sessions.put(s.token, s);
    return s;
}

pub fn getSession(self: *SratimStorage, token: []const u8) ?schema.Session {
    self.readLock();
    defer self.readUnlock();
    return self.sessions.get(token);
}

pub fn deleteSession(self: *SratimStorage, token: []const u8) void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.sessions.fetchRemove(token)) |kv| {
        var val = kv.value;
        val.deinit(self.allocator);
    }
}

pub fn cleanupExpiredSessions(self: *SratimStorage, cutoff_timestamp: i64) void {
    self.writeLock();
    defer self.writeUnlock();

    var to_remove = std.ArrayList([]const u8).empty;
    defer to_remove.deinit(self.allocator);

    var it = self.sessions.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.expires_at <= cutoff_timestamp) {
            to_remove.append(self.allocator, entry.key_ptr.*) catch break;
        }
    }

    for (to_remove.items) |tok| {
        if (self.sessions.fetchRemove(tok)) |kv| {
            var val = kv.value;
            val.deinit(self.allocator);
        }
    }
}
