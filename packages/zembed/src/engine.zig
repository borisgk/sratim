const std = @import("std");
const types = @import("types.zig");
const wal_mod = @import("wal.zig");
const snapshot_mod = @import("snapshot.zig");

pub const EngineOptions = types.EngineOptions;
pub const Opcode = types.Opcode;
pub const WalWriter = wal_mod.WalWriter;

/// Universal database engine coordinator.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: EngineOptions,
    rwlock: std.Io.RwLock = .init,
    wal: ?WalWriter = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: EngineOptions) Engine {
        const wal_writer = if (options.wal_path) |wp|
            WalWriter.init(io, wp, options.durability == .immediate_sync)
        else
            null;

        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .wal = wal_writer,
        };
    }

    pub fn writeLock(self: *Engine) void {
        self.rwlock.lockUncancelable(self.io);
    }

    pub fn writeUnlock(self: *Engine) void {
        self.rwlock.unlock(self.io);
    }

    pub fn readLock(self: *Engine) void {
        self.rwlock.lockSharedUncancelable(self.io);
    }

    pub fn readUnlock(self: *Engine) void {
        self.rwlock.unlockShared(self.io);
    }

    pub fn now(self: *const Engine) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    /// Appends a record to the WAL if configured.
    pub fn writeWal(self: *Engine, collection_id: u16, opcode: Opcode, payload: []const u8) !void {
        if (self.wal) |*w| {
            try w.append(collection_id, opcode, payload);
        }
    }

    /// Determines if WAL size or record count exceeds compaction thresholds.
    pub fn shouldCompact(self: *const Engine) bool {
        if (self.wal) |*w| {
            if (w.uncompacted_records >= self.options.max_wal_records) return true;
            if (w.byteSize() >= self.options.max_wal_bytes) return true;
        }
        return false;
    }

    /// Atomically persists snapshot bytes and resets the WAL file.
    pub fn saveSnapshot(self: *Engine, bytes: []const u8) !void {
        try snapshot_mod.saveAtomic(self.allocator, self.io, self.options.snapshot_path, bytes);
        if (self.wal) |*w| {
            w.reset() catch {};
        }
    }

    /// Reads existing snapshot file if present.
    pub fn loadSnapshot(self: *Engine, max_bytes: usize) !?[]u8 {
        return snapshot_mod.load(self.allocator, self.io, self.options.snapshot_path, max_bytes);
    }
};
