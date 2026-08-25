const std = @import("std");
const types = @import("types.zig");
const BoxHeader = types.BoxHeader;

/// Reads an ISOBMFF Box header from the reader.
pub fn readBoxHeader(r: *std.Io.Reader, current_pos: u64) !?BoxHeader {
    var hdr_buf: [8]u8 = undefined;
    r.readSliceAll(&hdr_buf) catch |err| {
        if (err == error.EndOfStream) return null;
        return err;
    };

    const size32 = std.mem.readInt(u32, hdr_buf[0..4], .big);
    const box_type = hdr_buf[4..8].*;

    var size: u64 = size32;
    var header_size: usize = 8;

    if (size32 == 1) {
        var ext_size_buf: [8]u8 = undefined;
        try r.readSliceAll(&ext_size_buf);
        size = std.mem.readInt(u64, &ext_size_buf, .big);
        header_size = 16;
    } else if (size32 == 0) {
        // Extends to end of file
        size = std.math.maxInt(u64);
        header_size = 8;
    }

    return BoxHeader{
        .type = box_type,
        .size = size,
        .header_size = header_size,
        .data_offset = current_pos + header_size,
    };
}

/// Skips the specified number of bytes using chunked reads.
pub fn skipBytes(r: *std.Io.Reader, count: u64) !void {
    var remaining = count;
    var discard_buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, discard_buf.len));
        try r.readSliceAll(discard_buf[0..to_read]);
        remaining -= to_read;
    }
}

/// Checks if a 4-byte box type matches a FourCC string.
pub fn isFourCC(box_type: [4]u8, expected: *const [4]u8) bool {
    return std.mem.eql(u8, &box_type, expected);
}

/// Quick probe to determine if a file is an MP4/MOV container by looking for ftyp, moov, free, mdat.
pub fn isMp4Container(buf: []const u8) bool {
    if (buf.len < 8) return false;
    const box_type = buf[4..8];
    return isFourCC(box_type.*, "ftyp") or
        isFourCC(box_type.*, "moov") or
        isFourCC(box_type.*, "free") or
        isFourCC(box_type.*, "mdat") or
        isFourCC(box_type.*, "skip") or
        isFourCC(box_type.*, "wide");
}

/// Helper to check if a track handler is a subtitle/text track.
pub fn isSubtitleHandler(handler: [4]u8) bool {
    return isFourCC(handler, "sbtl") or isFourCC(handler, "text") or isFourCC(handler, "subp") or isFourCC(handler, "clcp");
}
