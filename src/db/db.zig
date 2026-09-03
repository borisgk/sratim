const std = @import("std");
pub const schema = @import("../storage/schema.zig");
pub const engine = @import("../storage/engine.zig");
pub const logs_engine = @import("../storage/logs_engine.zig");
pub const sqlite_migrator = @import("../storage/sqlite_migrator.zig");

/// Database facade over pure-Zig SratimStorage (catalog) and LogsStorage (telemetry).
pub const Database = struct {
    catalog: ?*engine.SratimStorage = null,
    logs: ?*logs_engine.LogsStorage = null,

    pub fn forCatalog(s: *engine.SratimStorage) Database {
        return .{ .catalog = s, .logs = null };
    }

    pub fn forLogs(l: *logs_engine.LogsStorage) Database {
        return .{ .catalog = null, .logs = l };
    }

    pub fn close(self: *Database) void {
        _ = self;
    }
};

/// Initializes the database schema (no-op in pure-Zig SratimDB).
pub fn initSchema(database: *Database) !void {
    _ = database;
}
