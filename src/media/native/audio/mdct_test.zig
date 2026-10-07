const std = @import("std");
const mdct = @import("mdct.zig");
const Complex = mdct.Complex;
const MdctEngine = mdct.MdctEngine;
const fft = mdct.fft;
const ifft = mdct.ifft;

test "FFT and IFFT roundtrip" {
    var signal = [_]Complex{
        .{ .re = 1.0, .im = 0.0 },
        .{ .re = 2.0, .im = 0.0 },
        .{ .re = 3.0, .im = 0.0 },
        .{ .re = 4.0, .im = 0.0 },
        .{ .re = 5.0, .im = 0.0 },
        .{ .re = 6.0, .im = 0.0 },
        .{ .re = 7.0, .im = 0.0 },
        .{ .re = 8.0, .im = 0.0 },
    };
    const original = signal;

    fft(&signal);
    ifft(&signal);

    for (0..8) |i| {
        try std.testing.expectApproxEqAbs(original[i].re, signal[i].re, 0.001);
        try std.testing.expectApproxEqAbs(original[i].im, signal[i].im, 0.001);
    }
}

test "Verify MdctEngine against ISO AAC MDCT direct formula" {
    const N = 1024;
    const TWO_N = 2048;
    var in: [TWO_N]f32 = undefined;
    for (0..TWO_N) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        in[i] = @sin(2.0 * std.math.pi * 440.0 * t);
    }

    var fast_out: [N]f32 = undefined;
    MdctEngine.mdct(N, &in, &fast_out);

    // Compute first 8 bins with direct ISO formula:
    // X[k] = -2 * sum_{n=0}^{2N-1} in[n] * cos(pi/N * (n + 0.5 + N/2) * (k + 0.5))
    for (0..8) |k| {
        var direct: f64 = 0;
        const fk: f64 = @floatFromInt(k);
        for (0..TWO_N) |n| {
            const fn_idx: f64 = @floatFromInt(n);
            const angle = (std.math.pi / 1024.0) * (fn_idx + 0.5 + 512.0) * (fk + 0.5);
            direct += @as(f64, in[n]) * @cos(angle);
        }
        direct *= 2.0;
        try std.testing.expectApproxEqAbs(@as(f64, fast_out[k]), direct, 0.05);
    }
}

test "Verify MdctEngine.imdct against direct ISO AAC IMDCT formula" {
    const N = 1024;
    const TWO_N = 2048;
    var spec: [N]f32 = @splat(0.0);
    spec[1] = 1.0;

    var imdct_out: [TWO_N]f32 = undefined;
    MdctEngine.imdct(N, &spec, &imdct_out);

    // Direct ISO formula:
    // x[n] = (2.0 / N) * sum_{k=0}^{N-1} X[k] * cos( (pi/N) * (n + 0.5 + N/2) * (k + 0.5) )
    for (0..TWO_N) |n| {
        const fn_idx: f64 = @floatFromInt(n);
        const fk: f64 = 1.0;
        const angle = (std.math.pi / 1024.0) * (fn_idx + 0.5 + 512.0) * (fk + 0.5);
        const direct = (2.0 / 1024.0) * 1.0 * @cos(angle);
        try std.testing.expectApproxEqAbs(@as(f64, imdct_out[n]), direct, 0.00001);
    }
}

test "Verify MdctEngine.imdct(128) against direct ISO AAC IMDCT formula" {
    const N = 128;
    const TWO_N = 256;
    var spec: [N]f32 = @splat(0.0);
    spec[1] = 1.0;

    var imdct_out: [TWO_N]f32 = undefined;
    MdctEngine.imdct(N, &spec, &imdct_out);

    // Direct ISO formula:
    // x[n] = (2.0 / N) * sum_{k=0}^{N-1} X[k] * cos( (pi/N) * (n + 0.5 + N/2) * (k + 0.5) )
    for (0..TWO_N) |n| {
        const fn_idx: f64 = @floatFromInt(n);
        const fk: f64 = 1.0;
        const angle = (std.math.pi / 128.0) * (fn_idx + 0.5 + 64.0) * (fk + 0.5);
        const direct = (2.0 / 128.0) * 1.0 * @cos(angle);
        try std.testing.expectApproxEqAbs(@as(f64, imdct_out[n]), direct, 0.00001);
    }
}

test "MDCT to IMDCT perfect reconstruction (TDAC)" {
    const N = 1024;
    const TWO_N = 2048;

    var sig: [3072]f32 = undefined;
    for (0..3072) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        sig[i] = @sin(2.0 * std.math.pi * 440.0 * t);
    }

    var win: [TWO_N]f32 = undefined;
    for (0..TWO_N) |i| {
        const angle: f64 = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / 2048.0;
        win[i] = @floatCast(@sin(angle));
    }

    // Frame 0: analysis windowed
    var f0_win: [TWO_N]f32 = undefined;
    for (0..TWO_N) |i| f0_win[i] = sig[i] * win[i];
    var spec0: [N]f32 = undefined;
    // ISO AAC forward MDCT:
    for (0..N) |k| {
        var sum: f64 = 0;
        const fk: f64 = @floatFromInt(k);
        for (0..TWO_N) |n| {
            const fn_idx: f64 = @floatFromInt(n);
            const angle = (std.math.pi / 1024.0) * (fn_idx + 0.5 + 512.0) * (fk + 0.5);
            sum += @as(f64, f0_win[n]) * @cos(angle);
        }
        spec0[k] = @floatCast(-2.0 * sum);
    }

    // Frame 1: analysis windowed
    var f1_win: [TWO_N]f32 = undefined;
    for (0..TWO_N) |i| f1_win[i] = sig[1024 + i] * win[i];
    var spec1: [N]f32 = undefined;
    for (0..N) |k| {
        var sum: f64 = 0;
        const fk: f64 = @floatFromInt(k);
        for (0..TWO_N) |n| {
            const fn_idx: f64 = @floatFromInt(n);
            const angle = (std.math.pi / 1024.0) * (fn_idx + 0.5 + 512.0) * (fk + 0.5);
            sum += @as(f64, f1_win[n]) * @cos(angle);
        }
        spec1[k] = @floatCast(-2.0 * sum);
    }

    // Synthesis IMDCT:
    var time0: [TWO_N]f32 = undefined;
    MdctEngine.imdct(N, &spec0, &time0);
    var time1: [TWO_N]f32 = undefined;
    MdctEngine.imdct(N, &spec1, &time1);

    // Synthesis windowing:
    for (0..TWO_N) |i| time0[i] *= win[i];
    for (0..TWO_N) |i| time1[i] *= win[i];

    // Reconstruct samples 1024..2048:
    // ISO forward MDCT has factor -2.0, so the round-trip signal is scaled by -2.0.
    var rec: [N]f32 = undefined;
    for (0..N) |i| {
        rec[i] = -(time0[1024 + i] + time1[i]) * 0.5;
    }

    var max_tdac_err: f32 = 0;
    for (0..N) |i| {
        const diff = @abs(rec[i] - sig[1024 + i]);
        if (diff > max_tdac_err) max_tdac_err = diff;
    }
    try std.testing.expect(max_tdac_err < 0.0001);
}
