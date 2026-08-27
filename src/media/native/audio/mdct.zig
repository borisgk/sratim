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

    /// Computes forward MDCT: in (2N time samples) -> out (N frequency bins).
    pub fn mdct(comptime N: usize, in: []const f32, out: []f32) void {
        const N2 = N / 2;
        const N4 = N / 4;

        var buf: [N2]Complex = undefined;

        // 1. Time-domain pre-twiddle & folding
        for (0..N4) |n| {
            const rot_angle: f32 = -std.math.pi * (@as(f32, @floatFromInt(n)) + 0.125) / @as(f32, @floatFromInt(N2));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };

            const x0 = -in[3 * N4 + 2 * n] - in[3 * N4 - 1 - 2 * n];
            const x1 = in[N4 - 1 - 2 * n] - in[N4 + 2 * n];

            buf[n] = (Complex{ .re = x0, .im = x1 }).mul(twiddle);
        }

        for (0..N4) |n| {
            const idx = N4 + n;
            const rot_angle: f32 = -std.math.pi * (@as(f32, @floatFromInt(idx)) + 0.125) / @as(f32, @floatFromInt(N2));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };

            const x0 = in[N4 + 2 * n] - in[N4 - 1 - 2 * n];
            const x1 = in[7 * N4 - 1 - 2 * n] - in[7 * N4 + 2 * n];

            buf[idx] = (Complex{ .re = x0, .im = x1 }).mul(twiddle);
        }

        // 2. N/2-point FFT
        fft(buf[0..N2]);

        // 3. Post-twiddle to frequency bins
        for (0..N2) |k| {
            const rot_angle: f32 = -std.math.pi * (@as(f32, @floatFromInt(k)) + 0.125) / @as(f32, @floatFromInt(N2));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const post = buf[k].mul(twiddle);

            out[2 * k] = -post.re;
            out[N - 1 - 2 * k] = post.im;
        }
    }

    /// Computes inverse MDCT (IMDCT): in (N frequency bins) -> out (2N time samples).
    pub fn imdct(comptime N: usize, in: []const f32, out: []f32) void {
        const N2 = N / 2;
        const N4 = N / 4;

        var buf: [N2]Complex = undefined;

        // 1. Pre-twiddle frequency bins
        for (0..N2) |k| {
            const rot_angle: f32 = std.math.pi * (@as(f32, @floatFromInt(k)) + 0.125) / @as(f32, @floatFromInt(N2));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const in_c = Complex{ .re = in[2 * k], .im = -in[N - 1 - 2 * k] };
            buf[k] = in_c.mul(twiddle);
        }

        // 2. N/2-point IFFT
        ifft(buf[0..N2]);

        // 3. Post-twiddle and time unfolding
        for (0..N4) |n| {
            const rot_angle: f32 = std.math.pi * (@as(f32, @floatFromInt(n)) + 0.125) / @as(f32, @floatFromInt(N2));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const post = buf[n].mul(twiddle);

            out[N4 + 2 * n] = -post.re;
            out[N4 - 1 - 2 * n] = -post.re;
            out[3 * N4 + 2 * n] = post.im;
            out[3 * N4 - 1 - 2 * n] = -post.im;
        }

        for (0..N4) |n| {
            const idx = N4 + n;
            const rot_angle: f32 = std.math.pi * (@as(f32, @floatFromInt(idx)) + 0.125) / @as(f32, @floatFromInt(N2));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const post = buf[idx].mul(twiddle);

            out[7 * N4 + 2 * n] = -post.re;
            out[7 * N4 - 1 - 2 * n] = post.re;
            out[5 * N4 + 2 * n] = -post.im;
            out[5 * N4 - 1 - 2 * n] = -post.im;
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
