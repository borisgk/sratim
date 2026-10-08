const std = @import("std");

/// Opcodes for generic WAL journal frames.
pub const Opcode = enum(u8) {
    insert = 1,
    update = 2,
    delete = 3,
    clear = 4,
    checkpoint = 5,
    custom = 6,
    _,
};

/// 16-byte fixed binary header for every WAL frame.
/// [ Magic: 4B ("ZWAL") | CollectionId: 2B | Opcode: 1B | Flags: 1B | PayloadLen: 4B | CRC32: 4B ]
pub const RecordHeader = extern struct {
    magic: [4]u8 = "ZWAL".*,
    collection_id: u16,
    opcode: u8,
    flags: u8 = 0,
    payload_len: u32,
    crc32: u32,

    pub const MAGIC: [4]u8 = "ZWAL".*;
    pub const SIZE: usize = @sizeOf(RecordHeader);
};

comptime {
    std.debug.assert(@sizeOf(RecordHeader) == 16);
}

/// Durability policies for writes.
pub const DurabilityPolicy = enum {
    immediate_sync,
    deferred_sync,
    snapshot_only,
};

/// Configuration options for the database engine coordinator.
pub const EngineOptions = struct {
    snapshot_path: []const u8,
    wal_path: ?[]const u8 = null,
    max_wal_records: usize = 500,
    max_wal_bytes: usize = 512 * 1024,
    durability: DurabilityPolicy = .immediate_sync,
};

/// Configuration options for generic typed tables.
pub const TableOptions = struct {
    primary_key: []const u8 = "id",
    auto_increment: bool = true,
};

/// Universal database error set.
pub const DbError = error{
    KeyNotFound,
    DuplicateKey,
    InvalidPrimaryKey,
    UnsupportedKeyType,
    CorruptedWalRecord,
    ChecksumMismatch,
    InvalidMagic,
    WalWriteFailed,
    SnapshotCorrupted,
    SnapshotWriteFailed,
    TableNotFound,
    CollectionNotFound,
    EmptyKey,
};
