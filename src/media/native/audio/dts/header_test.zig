const std = @import("std");
const header = @import("header.zig");
const bit_reader = @import("bit_reader.zig");

test "parse header from test_dts_5s.dts" {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, "tests/test_dts_5s.dts", .{}) catch return;
    defer file.close(std.testing.io);

    var buf: [4096]u8 = undefined;
    var reader_file = file.reader(std.testing.io, &buf);
    const bytes_read = try reader_file.interface.readSliceShort(&buf);
    try std.testing.expect(bytes_read > 200);

    const sync_info = header.findSync(buf[0..bytes_read]) orelse return error.SyncNotFound;
    try std.testing.expectEqual(@as(usize, 0), sync_info.offset);
    try std.testing.expect(!sync_info.is_14bit);

    var reader = bit_reader.BitReader.init(buf[sync_info.offset..bytes_read]);
    const hdr = try header.parseHeader(&reader);
    try std.testing.expect(hdr.sample_rate == 48000 or hdr.sample_rate == 44100);
    try std.testing.expect(hdr.nchannels >= 2);
    try std.testing.expect(hdr.frame_size >= 96);
}
