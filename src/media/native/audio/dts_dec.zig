const std = @import("std");

pub const bit_reader = @import("dts/bit_reader.zig");
pub const BitReader = bit_reader.BitReader;

pub const tables = @import("dts/tables.zig");
pub const vectors = @import("dts/vectors.zig");
pub const header = @import("dts/header.zig");
pub const FrameHeader = header.FrameHeader;
pub const findSync = header.findSync;
pub const parseHeader = header.parseHeader;

pub const synthesis = @import("dts/synthesis.zig");
pub const subband = @import("dts/subband.zig");
pub const decoder = @import("dts/decoder.zig");
pub const DtsDecoder = decoder.DtsDecoder;

test "DtsDecoder decodes test_dts_5s.dts with high correlation to reference PCM" {
    const testing = std.testing;
    const file = std.Io.Dir.cwd().openFile(testing.io, "tests/test_dts_5s.dts", .{}) catch return;
    defer file.close(testing.io);

    const file_size = (try file.stat(testing.io)).size;
    const buf = try testing.allocator.alloc(u8, file_size);
    defer testing.allocator.free(buf);

    var reader_file = file.reader(testing.io, buf);
    const bytes_read = try reader_file.interface.readSliceShort(buf);
    try testing.expectEqual(file_size, bytes_read);

    var dec = DtsDecoder.init();
    var offset: usize = 0;
    var frame_count: usize = 0;

    var decoded_pcm = try std.ArrayList(f32).initCapacity(testing.allocator, 48000 * 5 * 2);
    defer decoded_pcm.deinit(testing.allocator);

    var frame_out: [2048 * 2]f32 = undefined;

    var tv_start: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv_start, null);

    while (offset + 96 <= bytes_read) {
        const sync = findSync(buf[offset..bytes_read]) orelse break;
        offset += sync.offset;

        var r = BitReader.init(buf[offset..bytes_read]);
        const hdr = parseHeader(&r) catch break;

        const n_samples = try dec.decodeFrame(buf[offset .. offset + hdr.frame_size], &frame_out);
        try decoded_pcm.appendSlice(testing.allocator, frame_out[0 .. n_samples * 2]);

        offset += hdr.frame_size;
        frame_count += 1;
        if (frame_count >= 200) break;
    }

    var tv_end: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv_end, null);
    const elapsed_us = (@as(i64, tv_end.sec) - @as(i64, tv_start.sec)) * 1000000 + (@as(i64, tv_end.usec) - @as(i64, tv_start.usec));
    const us_per_frame = @as(f64, @floatFromInt(elapsed_us)) / @as(f64, @floatFromInt(frame_count));
    std.debug.print("\n>>> DECODED {} DTS frames in {d:.2} ms ({d:.1} us/frame, {d:.1}x realtime) <<<\n", .{
        frame_count,
        @as(f64, @floatFromInt(elapsed_us)) / 1000.0,
        us_per_frame,
        10666.67 / us_per_frame,
    });

    try testing.expect(frame_count >= 10);

    // Read reference PCM
    const ref_file = std.Io.Dir.cwd().openFile(testing.io, "tests/test_dts_5s_ref.pcm", .{}) catch return;
    defer ref_file.close(testing.io);

    const ref_size = (try ref_file.stat(testing.io)).size;
    const ref_floats_count = ref_size / @sizeOf(f32);
    const ref_buf = try testing.allocator.alloc(u8, ref_size);
    defer testing.allocator.free(ref_buf);

    var ref_reader = ref_file.reader(testing.io, ref_buf);
    _ = try ref_reader.interface.readSliceShort(ref_buf);

    const ref_floats: []const f32 = @as([*]const f32, @ptrCast(@alignCast(ref_buf.ptr)))[0..ref_floats_count];

    const compare_len = @min(decoded_pcm.items.len, ref_floats.len);
    try testing.expect(compare_len > 1000);

    var dot: f64 = 0.0;
    var norm_dec: f64 = 0.0;
    var norm_ref: f64 = 0.0;

    for (0..compare_len) |i| {
        const d: f64 = decoded_pcm.items[i];
        const r: f64 = ref_floats[i];
        dot += d * r;
        norm_dec += d * d;
        norm_ref += r * r;
    }

    const denom = @sqrt(norm_dec * norm_ref);
    const corr = if (denom > 0.0) dot / denom else 0.0;
    std.debug.print("\nDTS Correlation: {d:.6} across {} samples ({} frames)\n", .{ corr, compare_len, frame_count });
    try testing.expect(corr > 0.95);
}
