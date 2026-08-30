const std = @import("std");

/// Complex number structure for FFT and MDCT computations.
pub const Complex = struct {
    re: f32,
    im: f32,

    pub inline fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub inline fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub inline fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }
};

/// Radix-2 in-place Decimation-In-Time Fast Fourier Transform.
pub fn fft(data: []Complex) void {
    const n = data.len;
    if (n <= 1) return;

    // 1. Bit-reversal permutation
    var j: usize = 0;
    for (0..n) |i| {
        if (i < j) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
        var m = n >> 1;
        while (m >= 1 and j >= m) {
            j -= m;
            m >>= 1;
        }
        j += m;
    }

    // 2. Butterfly stages
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half_len = len >> 1;
        const angle: f32 = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const w_step = Complex{ .re = @cos(angle), .im = @sin(angle) };

        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = Complex{ .re = 1.0, .im = 0.0 };
            for (0..half_len) |k| {
                const u = data[i + k];
                const v = data[i + k + half_len].mul(w);
                data[i + k] = u.add(v);
                data[i + k + half_len] = u.sub(v);
                w = w.mul(w_step);
            }
        }
    }
}

/// Computes the Inverse FFT using the forward FFT with complex conjugate twiddles.
pub fn ifft(data: []Complex) void {
    const n = data.len;
    if (n == 0) return;

    for (data) |*c| c.im = -c.im;
    fft(data);
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(n));
    for (data) |*c| {
        c.re *= scale;
        c.im = -c.im * scale;
    }
}

/// 256-point and 1024-point Modified Discrete Cosine Transform (MDCT) engine.
/// Transforms 2N time samples into N frequency bins using N/2-point FFT.
pub const MdctEngine = struct {
    const MAX_N = 1024;
    const MAX_N2 = MAX_N / 2;

    pub const TCOS_512 = blk: {
        @setEvalBranchQuota(5000);
        var table: [512]f32 = undefined;
        for (0..512) |i| {
            const alpha = 2.0 * std.math.pi * (@as(f64, @floatFromInt(i)) + 0.125) / 2048.0;
            table[i] = -@as(f32, @floatCast(@cos(alpha)));
        }
        break :blk table;
    };

    pub const TSIN_512 = blk: {
        @setEvalBranchQuota(5000);
        var table: [512]f32 = undefined;
        for (0..512) |i| {
            const alpha = 2.0 * std.math.pi * (@as(f64, @floatFromInt(i)) + 0.125) / 2048.0;
            table[i] = -@as(f32, @floatCast(@sin(alpha)));
        }
        break :blk table;
    };

    pub const TCOS_64 = blk: {
        @setEvalBranchQuota(2000);
        var table: [64]f32 = undefined;
        for (0..64) |i| {
            const alpha = 2.0 * std.math.pi * (@as(f64, @floatFromInt(i)) + 0.125) / 256.0;
            table[i] = -@as(f32, @floatCast(@cos(alpha)));
        }
        break :blk table;
    };

    pub const TSIN_64 = blk: {
        @setEvalBranchQuota(2000);
        var table: [64]f32 = undefined;
        for (0..64) |i| {
            const alpha = 2.0 * std.math.pi * (@as(f64, @floatFromInt(i)) + 0.125) / 256.0;
            table[i] = -@as(f32, @floatCast(@sin(alpha)));
        }
        break :blk table;
    };

    /// Computes forward ISO/IEC 14496-3 AAC MDCT: in (2N time samples) -> out (N frequency bins)
    /// using an N/2-point complex FFT algorithm (O(N log N)).
    pub fn mdct(comptime N: usize, in: []const f32, out: []f32) void {
        const n = 2 * N;
        const n2 = N;
        const n4 = N / 2;
        const n8 = N / 4;
        const n3 = 3 * n4;

        const tcos = if (N == 1024) &TCOS_512 else if (N == 128) &TCOS_64 else unreachable;
        const tsin = if (N == 1024) &TSIN_512 else if (N == 128) &TSIN_64 else unreachable;

        // 1. Pre-rotation
        var x: [n4]Complex = undefined;
        for (0..n8) |i| {
            const re0 = -in[2 * i + n3] - in[n3 - 1 - 2 * i];
            const im0 = -in[n4 + 2 * i] + in[n4 - 1 - 2 * i];
            x[i].re = re0 * (-tcos[i]) - im0 * tsin[i];
            x[i].im = re0 * tsin[i] + im0 * (-tcos[i]);

            const re1 = in[2 * i] - in[n2 - 1 - 2 * i];
            const im1 = -in[n2 + 2 * i] - in[n - 1 - 2 * i];
            x[n8 + i].re = re1 * (-tcos[n8 + i]) - im1 * tsin[n8 + i];
            x[n8 + i].im = re1 * tsin[n8 + i] + im1 * (-tcos[n8 + i]);
        }

        // 2. N/2-point in-place complex FFT
        fft(x[0..n4]);

        // 3. Post-rotation directly into frequency bins
        for (0..n8) |i| {
            const a_re0 = x[n8 - i - 1].re;
            const a_im0 = x[n8 - i - 1].im;
            const b_re0 = -tsin[n8 - i - 1];
            const b_im0 = -tcos[n8 - i - 1];
            const res_i1 = a_re0 * b_re0 - a_im0 * b_im0;
            const r0 = a_re0 * b_im0 + a_im0 * b_re0;

            const a_re1 = x[n8 + i].re;
            const a_im1 = x[n8 + i].im;
            const b_re1 = -tsin[n8 + i];
            const b_im1 = -tcos[n8 + i];
            const res_i0 = a_re1 * b_re1 - a_im1 * b_im1;
            const r1 = a_re1 * b_im1 + a_im1 * b_re1;

            out[2 * (n8 - i - 1)] = r0 * 2.0;
            out[2 * (n8 - i - 1) + 1] = res_i0 * 2.0;
            out[2 * (n8 + i)] = r1 * 2.0;
            out[2 * (n8 + i) + 1] = res_i1 * 2.0;
        }
    }

    /// Computes inverse MDCT (IMDCT): in (N frequency bins) -> out (2N time samples)
    /// by inverting the forward MDCT steps using the existing N/2-point IFFT and twiddle tables.
    pub fn imdct(comptime N: usize, in: []const f32, out: []f32) void {
        // N is the number of spectral coefficients (1024 or 128)
        // N_time is 2*N (2048 or 256)
        const N_time = 2 * N;
        const N2 = N; // N
        const N4 = N / 2; // N/2 = 512 (or 64)
        const N8 = N / 4; // N/4 = 256 (or 32)

        var z1: [N4]Complex = undefined;

        // Step 1: Pre-IFFT complex multiplication (Duhamel / FAAD2)
        // sincos[k] = exp(j * 2*pi*(k + 1/8) / N_time)
        const pi2_over_ntime = 2.0 * std.math.pi / @as(f32, @floatFromInt(N_time));
        for (0..N4) |k| {
            const angle = pi2_over_ntime * (@as(f32, @floatFromInt(k)) + 0.125);
            const c = @cos(angle);
            const s = @sin(angle);
            const x1 = in[2 * k];
            const x2 = in[N2 - 1 - 2 * k];
            // ComplexMult(&IM(z1[k]), &RE(z1[k]), x1, x2, c, s):
            // IM = x1 * c + x2 * s
            // RE = x2 * c - x1 * s
            z1[k].im = x1 * c + x2 * s;
            z1[k].re = x2 * c - x1 * s;
        }

        // Step 2: Complex IFFT of size N4
        ifft(z1[0..N4]);

        // Step 3: Post-IFFT complex multiplication
        // Note: IFFT introduces 1/N4 scale factor. In AAC IMDCT, overall factor is 2/N = 1/N4.
        // So with ifft() already applying 1/N4, no extra scaling is needed.
        for (0..N4) |k| {
            const angle = pi2_over_ntime * (@as(f32, @floatFromInt(k)) + 0.125);
            const c = @cos(angle);
            const s = @sin(angle);
            const rx = z1[k].re;
            const ix = z1[k].im;
            // ComplexMult(&IM(z1[k]), &RE(z1[k]), ix, rx, c, s):
            // IM = ix * c + rx * s
            // RE = rx * c - ix * s
            z1[k].im = ix * c + rx * s;
            z1[k].re = rx * c - ix * s;
        }

        // Step 4: Reordering into 2N time samples (Duhamel / FAAD2)
        var k: usize = 0;
        while (k < N8) : (k += 2) {
            out[2 * k] = z1[N8 + k].im;
            out[2 + 2 * k] = z1[N8 + 1 + k].im;

            out[1 + 2 * k] = -z1[N8 - 1 - k].re;
            out[3 + 2 * k] = -z1[N8 - 2 - k].re;

            out[N4 + 2 * k] = z1[k].re;
            out[N4 + 2 + 2 * k] = z1[1 + k].re;

            out[N4 + 1 + 2 * k] = -z1[N4 - 1 - k].im;
            out[N4 + 3 + 2 * k] = -z1[N4 - 2 - k].im;

            out[N2 + 2 * k] = z1[N8 + k].re;
            out[N2 + 2 + 2 * k] = z1[N8 + 1 + k].re;

            out[N2 + 1 + 2 * k] = -z1[N8 - 1 - k].im;
            out[N2 + 3 + 2 * k] = -z1[N8 - 2 - k].im;

            out[N2 + N4 + 2 * k] = -z1[k].im;
            out[N2 + N4 + 2 + 2 * k] = -z1[1 + k].im;

            out[N2 + N4 + 1 + 2 * k] = z1[N4 - 1 - k].re;
            out[N2 + N4 + 3 + 2 * k] = z1[N4 - 2 - k].re;
        }
    }
};

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
    var spec: [N]f32 = [_]f32{0.0} ** N;
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
    var spec: [N]f32 = [_]f32{0.0} ** N;
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


