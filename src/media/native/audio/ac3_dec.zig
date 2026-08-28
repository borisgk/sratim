const std = @import("std");

pub const bit_reader = @import("ac3/bit_reader.zig");
pub const BitReader = bit_reader.BitReader;

pub const tables = @import("ac3/tables.zig");
pub const SAMPLE_RATES = tables.SAMPLE_RATES;
pub const FRAME_SIZE_TABLE = tables.FRAME_SIZE_TABLE;
pub const NFCHANS_TBL = tables.NFCHANS_TBL;

pub const bit_allocation = @import("ac3/bit_allocation.zig");
pub const bitAllocate = bit_allocation.bitAllocate;

pub const decoder = @import("ac3/decoder.zig");
pub const Ac3Decoder = decoder.Ac3Decoder;

test "Ac3Decoder decodes 10 frames from polly_5s.ac3 with high correlation to FFmpeg" {
    const testing = std.testing;
    const file = std.Io.Dir.cwd().openFile(testing.io, "tmp/polly_5s.ac3", .{}) catch return;
    defer file.close(testing.io);

    var buf: [15360]u8 = undefined;
    var reader_file = file.reader(testing.io, &buf);
    _ = try reader_file.interface.readSliceShort(&buf);

    var ac3_decoder = Ac3Decoder.init();
    var native_stereo_pcm: [10 * 1536 * 2]f32 = undefined;

    for (0..10) |f| {
        const in_frame = buf[f * 1536 .. (f + 1) * 1536];
        const out_slice = native_stereo_pcm[f * 1536 * 2 .. (f + 1) * 1536 * 2];
        const n_samples = try ac3_decoder.decodeFrame(in_frame, out_slice);
        try testing.expectEqual(@as(usize, 1536), n_samples);
    }

    const ref_file = std.Io.Dir.cwd().openFile(testing.io, "tmp/polly_5s_ref.pcm", .{}) catch return;
    defer ref_file.close(testing.io);
    var ref_buf: [122880]u8 align(@alignOf(f32)) = undefined;
    var ref_reader = ref_file.reader(testing.io, &ref_buf);
    _ = try ref_reader.interface.readSliceShort(&ref_buf);
    const ref_floats: []const f32 = @as([*]const f32, @ptrCast(@alignCast(&ref_buf)))[0 .. 122880 / 4];

    var dot: f64 = 0.0;
    var norm_nat: f64 = 0.0;
    var norm_ref: f64 = 0.0;
    for (native_stereo_pcm, ref_floats) |n, r| {
        dot += @as(f64, n) * @as(f64, r);
        norm_nat += @as(f64, n) * @as(f64, n);
        norm_ref += @as(f64, r) * @as(f64, r);
    }
    const corr = dot / (std.math.sqrt(norm_nat) * std.math.sqrt(norm_ref));
    std.debug.print("\nNative Ac3Decoder correlation with FFmpeg: {d:.6}\n", .{corr});
    try testing.expect(corr > 0.95);
}
