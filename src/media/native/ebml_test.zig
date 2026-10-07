const std = @import("std");
const ebml = @import("ebml.zig");

test "EBML VINT decoding" {
    // 1-byte VINT
    const b1 = [_]u8{0x85}; // 5
    const res1 = try ebml.decodeVint(&b1);
    try std.testing.expectEqual(@as(u64, 5), res1.value);
    try std.testing.expectEqual(@as(usize, 1), res1.len);

    // 2-byte VINT
    const b2 = [_]u8{ 0x40, 0x02 }; // 2
    const res2 = try ebml.decodeVint(&b2);
    try std.testing.expectEqual(@as(u64, 2), res2.value);
    try std.testing.expectEqual(@as(usize, 2), res2.len);
}

test "EBML element header parsing" {
    const raw = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01 };
    var r: std.Io.Reader = .fixed(&raw);

    const hdr = (try ebml.readElementHeader(&r)).?;
    try std.testing.expectEqual(ebml.ID_EBML, hdr.id);
    try std.testing.expectEqual(@as(u64, 4), hdr.size);
    try std.testing.expectEqual(@as(usize, 5), hdr.header_size);
}
