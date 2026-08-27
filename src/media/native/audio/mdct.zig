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

        var y: [N]f32 = undefined;
        // 1. TDAC Folding: 2N samples -> N samples
        for (0..N2) |n| {
            y[n] = -in[3 * N2 + n] - in[3 * N2 - 1 - n];
            y[N2 + n] = in[n] - in[2 * N2 - 1 - n];
        }

        // 2. Pre-twiddle: N real samples -> N/2 complex samples
        var buf: [N2]Complex = undefined;
        for (0..N2) |n| {
            const rot_angle: f32 = -2.0 * std.math.pi * (@as(f32, @floatFromInt(n)) + 0.125) / @as(f32, @floatFromInt(N));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const c_in = Complex{ .re = y[2 * n], .im = -y[N - 1 - 2 * n] };
            buf[n] = c_in.mul(twiddle);
        }

        // 3. N/2-point FFT
        fft(buf[0..N2]);

        // 4. Post-twiddle to spectral frequency bins
        for (0..N2) |k| {
            const rot_angle: f32 = -2.0 * std.math.pi * (@as(f32, @floatFromInt(k)) + 0.125) / @as(f32, @floatFromInt(N));
            const twiddle = Complex{ .re = @cos(rot_angle), .im = @sin(rot_angle) };
            const post = buf[k].mul(twiddle);

            out[2 * k] = -post.re;
            out[N - 1 - 2 * k] = post.im;
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
