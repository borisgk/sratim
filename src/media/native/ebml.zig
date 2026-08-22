const std = @import("std");

pub const ID_EBML = 0x1A45DFA3;
pub const ID_SEGMENT = 0x18538067;
pub const ID_SEEK_HEAD = 0x114D9B74;
pub const ID_INFO = 0x1549A966;
pub const ID_TIMESTAMP_SCALE = 0x2AD7B1;
pub const ID_DURATION = 0x4489;
pub const ID_TRACKS = 0x1654AE6B;
pub const ID_TRACK_ENTRY = 0xAE;
pub const ID_TRACK_NUMBER = 0xD7;
pub const ID_TRACK_UID = 0x73C5;
pub const ID_TRACK_TYPE = 0x83;
pub const ID_CODEC_ID = 0x86;
pub const ID_CODEC_PRIVATE = 0x63A2;
pub const ID_NAME = 0x536E;
pub const ID_LANGUAGE = 0x22B59C;
pub const ID_LANGUAGE_IETF = 0x22B59D;
pub const ID_CLUSTER = 0x1F43B675;
pub const ID_CLUSTER_TIMESTAMP = 0xE7;
pub const ID_SIMPLE_BLOCK = 0xA3;
pub const ID_BLOCK_GROUP = 0xA0;
pub const ID_BLOCK = 0xA1;
pub const ID_BLOCK_DURATION = 0x9B;
pub const ID_CUES = 0x1C53BB6B;
pub const ID_CUE_POINT = 0xBB;
pub const ID_CUE_TIME = 0xB3;
pub const ID_CUE_TRACK_POSITIONS = 0xB7;
pub const ID_CUE_TRACK = 0xF7;
pub const ID_CUE_CLUSTER_POSITION = 0xF1;

pub const UNKNOWN_SIZE: u64 = std.math.maxInt(u64);

pub const ElementHeader = struct {
    id: u32,
    size: u64,
    header_size: usize,
};

/// Reads an EBML Element ID from reader. The leading width bit is preserved.
pub fn readElementId(r: *std.Io.Reader) !?struct { id: u32, bytes_read: usize } {
    const first_byte = r.takeByte() catch |err| {
        if (err == error.EndOfStream) return null;
        return err;
    };

    var mask: u8 = 0x80;
    var length: usize = 1;
    while (mask > 0 and (first_byte & mask) == 0) {
        mask >>= 1;
        length += 1;
    }

    if (length > 4 or mask == 0) {
        return error.InvalidEbmlId;
    }

    var id: u32 = @as(u32, first_byte);
    var i: usize = 1;
    while (i < length) : (i += 1) {
        const b = try r.takeByte();
        id = (id << 8) | @as(u32, b);
    }

    return .{ .id = id, .bytes_read = length };
}

/// Reads an EBML Data Size VINT from reader. The leading width bit is stripped.
pub fn readElementDataSize(r: *std.Io.Reader) !struct { size: u64, bytes_read: usize } {
    const first_byte = try r.takeByte();

    var mask: u8 = 0x80;
    var length: usize = 1;
    while (mask > 0 and (first_byte & mask) == 0) {
        mask >>= 1;
        length += 1;
    }

    if (length > 8 or mask == 0) {
        return error.InvalidEbmlSize;
    }

    var size: u64 = @as(u64, first_byte & (~mask));
    var is_unknown = (first_byte & (~mask)) == (mask - 1);

    var i: usize = 1;
    while (i < length) : (i += 1) {
        const b = try r.takeByte();
        size = (size << 8) | @as(u64, b);
        if (b != 0xFF) is_unknown = false;
    }

    if (is_unknown) {
        return .{ .size = UNKNOWN_SIZE, .bytes_read = length };
    }

    return .{ .size = size, .bytes_read = length };
}

/// Decodes an EBML Data Size VINT directly from an in-memory byte slice.
pub fn decodeVint(bytes: []const u8) !struct { value: u64, len: usize } {
    if (bytes.len == 0) return error.UnexpectedEof;
    const first_byte = bytes[0];
    var mask: u8 = 0x80;
    var length: usize = 1;
    while (mask > 0 and (first_byte & mask) == 0) {
        mask >>= 1;
        length += 1;
    }
    if (length > 8 or mask == 0 or bytes.len < length) {
        return error.InvalidVint;
    }
    var val: u64 = @as(u64, first_byte & (~mask));
    var i: usize = 1;
    while (i < length) : (i += 1) {
        val = (val << 8) | @as(u64, bytes[i]);
    }
    return .{ .value = val, .len = length };
}

/// Reads next element header (ID + Size).
pub fn readElementHeader(r: *std.Io.Reader) !?ElementHeader {
    const id_res = (try readElementId(r)) orelse return null;
    const size_res = try readElementDataSize(r);
    return ElementHeader{
        .id = id_res.id,
        .size = size_res.size,
        .header_size = id_res.bytes_read + size_res.bytes_read,
    };
}

/// Reads an unsigned integer of `size` bytes (big-endian).
pub fn readUint(r: *std.Io.Reader, size: u64) !u64 {
    if (size > 8) return error.UintTooLarge;
    var val: u64 = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        const b = try r.takeByte();
        val = (val << 8) | @as(u64, b);
    }
    return val;
}

/// Reads a signed integer of `size` bytes (big-endian) with sign extension.
pub fn readInt(r: *std.Io.Reader, size: u64) !i64 {
    if (size == 0 or size > 8) return error.IntTooLarge;
    const first_byte = try r.takeByte();
    var val: i64 = @as(i8, @bitCast(first_byte)); // sign-extend first byte
    var i: usize = 1;
    while (i < size) : (i += 1) {
        const b = try r.takeByte();
        val = (val << 8) | @as(i64, b);
    }
    return val;
}

/// Reads a float of 4 or 8 bytes.
pub fn readFloat(r: *std.Io.Reader, size: u64) !f64 {
    if (size == 4) {
        var buf: [4]u8 = undefined;
        try r.readSliceAll(&buf);
        const u = std.mem.readInt(u32, &buf, .big);
        return @floatCast(@as(f32, @bitCast(u)));
    } else if (size == 8) {
        var buf: [8]u8 = undefined;
        try r.readSliceAll(&buf);
        const u = std.mem.readInt(u64, &buf, .big);
        return @as(f64, @bitCast(u));
    }
    return error.InvalidFloatSize;
}

/// Reads a UTF-8 or ASCII string of `size` bytes.
pub fn readString(allocator: std.mem.Allocator, r: *std.Io.Reader, size: u64) ![]u8 {
    if (size > 10 * 1024 * 1024) return error.StringTooLarge;
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    try r.readSliceAll(buf);
    return buf;
}

/// Skips `size` bytes in reader.
pub fn skipBytes(r: *std.Io.Reader, size: u64) !void {
    var remaining = size;
    while (remaining > 0) {
        const chunk_size: usize = @intCast(@min(remaining, std.math.maxInt(usize)));
        const discarded = try r.discard(.limited(chunk_size));
        if (discarded == 0) return error.EndOfStream;
        remaining -= discarded;
    }
}

test "EBML VINT decoding" {
    // 1-byte VINT
    const b1 = [_]u8{0x85}; // 5
    const res1 = try decodeVint(&b1);
    try std.testing.expectEqual(@as(u64, 5), res1.value);
    try std.testing.expectEqual(@as(usize, 1), res1.len);

    // 2-byte VINT
    const b2 = [_]u8{ 0x40, 0x02 }; // 2
    const res2 = try decodeVint(&b2);
    try std.testing.expectEqual(@as(u64, 2), res2.value);
    try std.testing.expectEqual(@as(usize, 2), res2.len);
}

test "EBML element header parsing" {
    const raw = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01 };
    var r: std.Io.Reader = .fixed(&raw);

    const hdr = (try readElementHeader(&r)).?;
    try std.testing.expectEqual(ID_EBML, hdr.id);
    try std.testing.expectEqual(@as(u64, 4), hdr.size);
    try std.testing.expectEqual(@as(usize, 5), hdr.header_size);
}
