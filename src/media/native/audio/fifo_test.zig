const std = @import("std");
const fifo_mod = @import("fifo.zig");
const AudioFifo = fifo_mod.AudioFifo;

test "AudioFifo write, read, and size accounting" {
    const testing = std.testing;
    var fifo = AudioFifo.init(testing.allocator);
    defer fifo.deinit();

    try testing.expectEqual(@as(usize, 0), fifo.size());

    const l_data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const r_data = [_]f32{ -1.0, -2.0, -3.0, -4.0, -5.0 };

    try fifo.write(&l_data, &r_data);
    try testing.expectEqual(@as(usize, 5), fifo.size());

    var out_l: [3]f32 = undefined;
    var out_r: [3]f32 = undefined;

    const read1 = fifo.read(&out_l, &out_r);
    try testing.expectEqual(@as(usize, 3), read1);
    try testing.expectEqual(@as(usize, 2), fifo.size());
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 2.0, 3.0 }, &out_l);
    try testing.expectEqualSlices(f32, &[_]f32{ -1.0, -2.0, -3.0 }, &out_r);

    var out2_l: [4]f32 = undefined;
    var out2_r: [4]f32 = undefined;
    const read2 = fifo.read(&out2_l, &out2_r);
    try testing.expectEqual(@as(usize, 2), read2);
    try testing.expectEqual(@as(usize, 0), fifo.size());
    try testing.expectEqualSlices(f32, &[_]f32{ 4.0, 5.0 }, out2_l[0..2]);
    try testing.expectEqualSlices(f32, &[_]f32{ -4.0, -5.0 }, out2_r[0..2]);
}

test "AudioFifo writeInterleaved" {
    const testing = std.testing;
    var fifo = AudioFifo.init(testing.allocator);
    defer fifo.deinit();

    const interleaved = [_]f32{ 10.0, 20.0, 30.0, 40.0 };
    try fifo.writeInterleaved(&interleaved);

    try testing.expectEqual(@as(usize, 2), fifo.size());

    var out_l: [2]f32 = undefined;
    var out_r: [2]f32 = undefined;
    const n = fifo.read(&out_l, &out_r);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(f32, &[_]f32{ 10.0, 30.0 }, &out_l);
    try testing.expectEqualSlices(f32, &[_]f32{ 20.0, 40.0 }, &out_r);
}

test "AudioFifo compaction under repeated write/read cycles" {
    const testing = std.testing;
    var fifo = AudioFifo.init(testing.allocator);
    defer fifo.deinit();

    var write_l: [512]f32 = undefined;
    var write_r: [512]f32 = undefined;
    @memset(&write_l, 0.5);
    @memset(&write_r, -0.5);

    var read_l: [512]f32 = undefined;
    var read_r: [512]f32 = undefined;

    // Run 20 cycles of 512 samples each (total 10240 samples written & read)
    for (0..20) |_| {
        try fifo.write(&write_l, &write_r);
        const read_count = fifo.read(&read_l, &read_r);
        try testing.expectEqual(@as(usize, 512), read_count);
        try testing.expectEqual(@as(usize, 0), fifo.size());
    }
}
