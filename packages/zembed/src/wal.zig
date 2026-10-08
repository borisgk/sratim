const std = @import("std");
const types = @import("types.zig");

pub const RecordHeader = types.RecordHeader;
pub const Opcode = types.Opcode;
pub const DbError = types.DbError;

pub const WalRecord = struct {
    collection_id: u16,
    opcode: Opcode,
    payload: []const u8,
};

pub const WalWriter = struct {
    io: std.Io,
    wal_path: []const u8,
    sync_on_write: bool = true,
    uncompacted_records: usize = 0,

    pub fn init(io: std.Io, wal_path: []const u8, sync_on_write: bool) WalWriter {
        return .{
            .io = io,
            .wal_path = wal_path,
            .sync_on_write = sync_on_write,
            .uncompacted_records = 0,
        };
    }

    /// Appends a framed record to the WAL file.
    pub fn append(self: *WalWriter, collection_id: u16, opcode: Opcode, payload: []const u8) !void {
        const payload_len: u32 = @intCast(payload.len);
        const crc = std.hash.Crc32.hash(payload);

        var header = RecordHeader{
            .magic = RecordHeader.MAGIC,
            .collection_id = collection_id,
            .opcode = @intFromEnum(opcode),
            .flags = 0,
            .payload_len = payload_len,
            .crc32 = crc,
        };

        const file = std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{
            .truncate = false,
        }) catch |err| {
            std.debug.print("WalWriter: failed to open {s}: {}\n", .{ self.wal_path, err });
            return error.WalWriteFailed;
        };
        defer file.close(self.io);

        const offset = file.length(self.io) catch 0;
        const header_bytes = std.mem.asBytes(&header);

        var stack_buf: [512]u8 = undefined;
        const total_len = RecordHeader.SIZE + payload.len;

        if (total_len <= stack_buf.len) {
            @memcpy(stack_buf[0..RecordHeader.SIZE], header_bytes);
            @memcpy(stack_buf[RecordHeader.SIZE..total_len], payload);
            try file.writePositionalAll(self.io, stack_buf[0..total_len], offset);
        } else {
            try file.writePositionalAll(self.io, header_bytes, offset);
            try file.writePositionalAll(self.io, payload, offset + RecordHeader.SIZE);
        }

        if (self.sync_on_write) {
            file.sync(self.io) catch {};
        }

        self.uncompacted_records += 1;
    }

    /// Resets/truncates the WAL file upon snapshot checkpoint.
    pub fn reset(self: *WalWriter) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{});
        file.close(self.io);
        self.uncompacted_records = 0;
    }

    /// Gets current byte length of the WAL file.
    pub fn byteSize(self: *const WalWriter) usize {
        const file = std.Io.Dir.cwd().openFile(self.io, self.wal_path, .{}) catch return 0;
        defer file.close(self.io);
        return file.length(self.io) catch 0;
    }
};

pub const WalReader = struct {
    /// Replays all valid WAL records from file.
    /// Returns the number of successfully applied records.
    pub fn replay(
        allocator: std.mem.Allocator,
        io: std.Io,
        wal_path: []const u8,
        context: anytype,
        comptime applyFn: fn (@TypeOf(context), WalRecord) anyerror!void,
    ) !usize {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, wal_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer allocator.free(bytes);

        var pos: usize = 0;
        var count: usize = 0;

        while (pos + RecordHeader.SIZE <= bytes.len) {
            const header_slice = bytes[pos .. pos + RecordHeader.SIZE];
            var header: RecordHeader = undefined;
            @memcpy(std.mem.asBytes(&header), header_slice);

            if (!std.mem.eql(u8, &header.magic, &RecordHeader.MAGIC)) {
                // Not a valid frame start or truncated
                break;
            }

            const payload_len = header.payload_len;
            const record_end = pos + RecordHeader.SIZE + payload_len;

            if (record_end > bytes.len) {
                // Incomplete record at end of file (e.g. crash during write)
                break;
            }

            const payload = bytes[pos + RecordHeader.SIZE .. record_end];
            const computed_crc = std.hash.Crc32.hash(payload);

            if (computed_crc != header.crc32) {
                // Corrupted record, halt replay at last valid point
                break;
            }

            const opcode: Opcode = @enumFromInt(header.opcode);
            const record = WalRecord{
                .collection_id = header.collection_id,
                .opcode = opcode,
                .payload = payload,
            };

            try applyFn(context, record);

            pos = record_end;
            count += 1;
        }

        return count;
    }
};
