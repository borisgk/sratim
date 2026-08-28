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

    /// Computes inverse MDCT (IMDCT): in (N frequency bins) -> out (2N time samples).
    pub fn imdct(comptime N: usize, in: []const f32, out: []f32) void {
        const N2 = N / 2;

        // 1. Pre-twiddle frequency bins
        var buf: [N2]Complex = undefined;
        for (0..N2) |k| {
            const rot_angle: f32 = 2.0 * std.math.pi * (@as(f32, @floatFromInt(k)) + 0.125) / @as(f32, @floatFromInt(N));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const in_c = Complex{ .re = -in[2 * k], .im = in[N - 1 - 2 * k] };
            buf[k] = in_c.mul(twiddle);
        }

        // 2. N/2-point IFFT
        ifft(buf[0..N2]);

        // 3. Post-twiddle
        var y: [N]f32 = undefined;
        for (0..N2) |n| {
            const rot_angle: f32 = 2.0 * std.math.pi * (@as(f32, @floatFromInt(n)) + 0.125) / @as(f32, @floatFromInt(N));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const post = buf[n].mul(twiddle);

            y[2 * n] = post.re;
            y[N - 1 - 2 * n] = -post.im;
        }

        // 4. Time unfolding: N samples -> 2N samples
        for (0..N2) |n| {
            out[n] = y[N2 + n];
            out[2 * N2 - 1 - n] = -y[N2 + n];
            out[2 * N2 + n] = -y[N2 - 1 - n];
            out[4 * N2 - 1 - n] = -y[N2 - 1 - n];
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


