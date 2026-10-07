const std = @import("std");
const dsp = @import("dsp.zig");
const downmixPlanarToStereo = dsp.downmixPlanarToStereo;
const HermiteResampler = dsp.HermiteResampler;

test "downmixPlanarToStereo 5.1 surround ITU-R BS.775" {
    var l: [8]f32 = @splat(1.0);
    var r: [8]f32 = @splat(1.0);
    var c: [8]f32 = @splat(1.0);
    var lfe: [8]f32 = @splat(0.5);
    var ls: [8]f32 = @splat(1.0);
    var rs: [8]f32 = @splat(1.0);

    const channels = [_][]const f32{ &l, &r, &c, &lfe, &ls, &rs };

    var out_l: [8]f32 = undefined;
    var out_r: [8]f32 = undefined;

    downmixPlanarToStereo(&channels, .surround_5_1, &out_l, &out_r);

    // L_out = clamp(1.0 + 0.7071 + 0.7071, -1.0, 1.0) = 1.0
    for (out_l) |s| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), s, 0.001);
    }
    for (out_r) |s| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), s, 0.001);
    }
}

test "downmixPlanarToStereo stereo passthrough" {
    var l = [_]f32{ 0.25, -0.5, 0.75, -0.1 };
    var r = [_]f32{ -0.25, 0.5, -0.75, 0.1 };
    const channels = [_][]const f32{ &l, &r };

    var out_l: [4]f32 = undefined;
    var out_r: [4]f32 = undefined;

    downmixPlanarToStereo(&channels, .stereo, &out_l, &out_r);

    try std.testing.expectEqualSlices(f32, &l, &out_l);
    try std.testing.expectEqualSlices(f32, &r, &out_r);
}

test "HermiteResampler 44100 to 48000 Hz preserves sine continuity" {
    var resampler = HermiteResampler.init(44100, 48000);

    var input: [441]f32 = undefined;
    // Generate 10ms of 1000 Hz sine wave at 44.1kHz
    for (0..input.len) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        input[i] = @sin(2.0 * std.math.pi * 1000.0 * t);
    }

    var output: [480]f32 = undefined;
    const generated = resampler.process(&input, &output);

    try std.testing.expect(generated > 450);
    // Verify peak amplitude preserved within 5%
    var max_amp: f32 = 0.0;
    for (output[0..generated]) |s| {
        if (@abs(s) > max_amp) max_amp = @abs(s);
    }
    try std.testing.expect(max_amp > 0.90 and max_amp <= 1.05);
}

test "HermiteResampler 24000 to 48000 Hz zero cumulative drift across chunks" {
    var resampler = HermiteResampler.init(24000, 48000);

    var input: [1024]f32 = undefined;
    for (0..1024) |i| {
        input[i] = @sin(@as(f32, @floatFromInt(i)) * 0.1);
    }

    var output: [4096]f32 = undefined;
    var total_out: usize = 0;

    // Simulate 50 consecutive chunks of 1024 samples
    for (0..50) |chunk_idx| {
        const n = resampler.process(&input, &output);
        total_out += n;
        if (chunk_idx > 0) {
            // From chunk 1 onwards, every 1024-sample chunk MUST output exactly 2048 samples
            try std.testing.expectEqual(@as(usize, 2048), n);
        }
    }

    // 50 * 1024 in = 51,200 samples. Total out is 102,400 - 4 (initial 4-sample latency) = 102,396.
    try std.testing.expectEqual(@as(usize, 102396), total_out);
}
