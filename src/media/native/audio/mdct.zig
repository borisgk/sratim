const std = @import("std");
const dsp = @import("dsp.zig");

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

/// Precomputed bit-reversal and stage twiddle tables for compile-time known power-of-2 FFT sizes.
fn FftTables(comptime N: usize) type {
    return struct {
        pub const BITREV: [N]u16 = blk: {
            @setEvalBranchQuota(20000);
            var rev: [N]u16 = undefined;
            var j: usize = 0;
            for (0..N) |i| {
                rev[i] = @intCast(j);
                var m = N >> 1;
                while (m >= 1 and j >= m) {
                    j -= m;
                    m >>= 1;
                }
                j += m;
            }
            break :blk rev;
        };

        pub const TWIDDLE_RE: [N]f32 = blk: {
            @setEvalBranchQuota(20000);
            var re: [N]f32 = @splat(0.0);
            var len: usize = 2;
            while (len <= N) : (len <<= 1) {
                const half_len = len >> 1;
                const angle_step: f64 = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
                for (0..half_len) |k| {
                    re[half_len + k] = @floatCast(@cos(angle_step * @as(f64, @floatFromInt(k))));
                }
            }
            break :blk re;
        };

        pub const TWIDDLE_IM: [N]f32 = blk: {
            @setEvalBranchQuota(20000);
            var im: [N]f32 = @splat(0.0);
            var len: usize = 2;
            while (len <= N) : (len <<= 1) {
                const half_len = len >> 1;
                const angle_step: f64 = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
                for (0..half_len) |k| {
                    im[half_len + k] = @floatCast(@sin(angle_step * @as(f64, @floatFromInt(k))));
                }
            }
            break :blk im;
        };
    };
}

/// Compile-time specialized Radix-2 in-place DIT FFT using comptime tables and @Vector(4, f32) SIMD.
pub fn fftComptime(comptime N: usize, data: *[N]Complex) void {
    if (N <= 1) return;
    const Tabs = FftTables(N);

    // 1. Bit-reversal permutation using comptime table
    for (0..N) |i| {
        const j = Tabs.BITREV[i];
        if (i < j) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
    }

    // 2. Stage len = 2 (half_len = 1): w = (1, 0), pure add/sub
    {
        var i: usize = 0;
        while (i < N) : (i += 2) {
            const u = data[i];
            const v = data[i + 1];
            data[i] = u.add(v);
            data[i + 1] = u.sub(v);
        }
    }

    if (N < 4) return;

    // 3. Stage len = 4 (half_len = 2): w_0 = (1, 0), w_1 = (0, -1), pure add/sub/swap
    {
        var i: usize = 0;
        while (i < N) : (i += 4) {
            const u_even = data[i];
            const v_even = data[i + 2];
            data[i] = u_even.add(v_even);
            data[i + 2] = u_even.sub(v_even);

            const u_odd = data[i + 1];
            const v_odd = data[i + 3];
            const vw_odd = Complex{ .re = v_odd.im, .im = -v_odd.re };
            data[i + 1] = u_odd.add(vw_odd);
            data[i + 3] = u_odd.sub(vw_odd);
        }
    }

    // 4. Stages len >= 8 (half_len >= 4): vectorized 4 Complex butterflies at a time
    const f32_data: *[2 * N]f32 = @ptrCast(data);
    var len: usize = 8;
    while (len <= N) : (len <<= 1) {
        const half_len = len >> 1;
        var i: usize = 0;
        while (i < N) : (i += len) {
            var k: usize = 0;
            while (k < half_len) : (k += 4) {
                const w_re: @Vector(4, f32) = Tabs.TWIDDLE_RE[half_len + k ..][0..4].*;
                const w_im: @Vector(4, f32) = Tabs.TWIDDLE_IM[half_len + k ..][0..4].*;

                const u_idx = 2 * (i + k);
                const v_idx = 2 * (i + k + half_len);

                const u_raw: @Vector(8, f32) = f32_data[u_idx..][0..8].*;
                const v_raw: @Vector(8, f32) = f32_data[v_idx..][0..8].*;

                const u_re = @shuffle(f32, u_raw, undefined, [4]i32{ 0, 2, 4, 6 });
                const u_im = @shuffle(f32, u_raw, undefined, [4]i32{ 1, 3, 5, 7 });
                const v_re = @shuffle(f32, v_raw, undefined, [4]i32{ 0, 2, 4, 6 });
                const v_im = @shuffle(f32, v_raw, undefined, [4]i32{ 1, 3, 5, 7 });

                const vw_re = dsp.mulAdd(@Vector(4, f32), v_re, w_re, -(v_im * w_im));
                const vw_im = dsp.mulAdd(@Vector(4, f32), v_re, w_im, v_im * w_re);

                const out_u_re = u_re + vw_re;
                const out_u_im = u_im + vw_im;
                const out_v_re = u_re - vw_re;
                const out_v_im = u_im - vw_im;

                f32_data[u_idx..][0..8].* = @shuffle(f32, out_u_re, out_u_im, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
                f32_data[v_idx..][0..8].* = @shuffle(f32, out_v_re, out_v_im, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
            }
        }
    }
}

/// Compile-time specialized Inverse FFT using @Vector(8, f32) conjugation/scaling and fftComptime.
pub fn ifftComptime(comptime N: usize, data: *[N]Complex) void {
    if (N == 0) return;
    const f32_data: *[2 * N]f32 = @ptrCast(data);
    const conj_vec = @Vector(8, f32){ 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0 };
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(N));
    const scale_conj_vec = @Vector(8, f32){ scale, -scale, scale, -scale, scale, -scale, scale, -scale };

    if ((2 * N) % 8 == 0) {
        var i: usize = 0;
        while (i < 2 * N) : (i += 8) {
            const v: @Vector(8, f32) = f32_data[i..][0..8].*;
            f32_data[i..][0..8].* = v * conj_vec;
        }
    } else {
        for (data) |*c| c.im = -c.im;
    }

    fftComptime(N, data);

    if ((2 * N) % 8 == 0) {
        var i: usize = 0;
        while (i < 2 * N) : (i += 8) {
            const v: @Vector(8, f32) = f32_data[i..][0..8].*;
            f32_data[i..][0..8].* = v * scale_conj_vec;
        }
    } else {
        for (data) |*c| {
            c.re *= scale;
            c.im = -c.im * scale;
        }
    }
}

/// Radix-2 in-place Decimation-In-Time Fast Fourier Transform.
pub fn fft(data: []Complex) void {
    switch (data.len) {
        512 => {
            fftComptime(512, data[0..512]);
            return;
        },
        64 => {
            fftComptime(64, data[0..64]);
            return;
        },
        8 => {
            fftComptime(8, data[0..8]);
            return;
        },
        else => {},
    }
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
    switch (data.len) {
        512 => {
            ifftComptime(512, data[0..512]);
            return;
        },
        64 => {
            ifftComptime(64, data[0..64]);
            return;
        },
        8 => {
            ifftComptime(8, data[0..8]);
            return;
        },
        else => {},
    }
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

        // 1. Pre-rotation (vectorized 4 bins at a time)
        var x: [n4]Complex = undefined;
        const x_f32: *[2 * n4]f32 = @ptrCast(&x);
        var i: usize = 0;
        while (i < n8) : (i += 4) {
            const a0: @Vector(8, f32) = in[2 * i + n3 ..][0..8].*;
            const b0: @Vector(8, f32) = in[n3 - 8 - 2 * i ..][0..8].*;
            const re0 = -@shuffle(f32, a0, undefined, [4]i32{ 0, 2, 4, 6 }) - @shuffle(f32, b0, undefined, [4]i32{ 7, 5, 3, 1 });

            const c0: @Vector(8, f32) = in[n4 + 2 * i ..][0..8].*;
            const d0: @Vector(8, f32) = in[n4 - 8 - 2 * i ..][0..8].*;
            const im0 = @shuffle(f32, d0, undefined, [4]i32{ 7, 5, 3, 1 }) - @shuffle(f32, c0, undefined, [4]i32{ 0, 2, 4, 6 });

            const tc0: @Vector(4, f32) = tcos[i..][0..4].*;
            const ts0: @Vector(4, f32) = tsin[i..][0..4].*;
            const x0_re = dsp.mulAdd(@Vector(4, f32), re0, -tc0, -(im0 * ts0));
            const x0_im = dsp.mulAdd(@Vector(4, f32), re0, ts0, im0 * (-tc0));
            x_f32[2 * i ..][0..8].* = @shuffle(f32, x0_re, x0_im, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });

            const a1: @Vector(8, f32) = in[2 * i ..][0..8].*;
            const b1: @Vector(8, f32) = in[n2 - 8 - 2 * i ..][0..8].*;
            const re1 = @shuffle(f32, a1, undefined, [4]i32{ 0, 2, 4, 6 }) - @shuffle(f32, b1, undefined, [4]i32{ 7, 5, 3, 1 });

            const c1: @Vector(8, f32) = in[n2 + 2 * i ..][0..8].*;
            const d1: @Vector(8, f32) = in[n - 8 - 2 * i ..][0..8].*;
            const im1 = -@shuffle(f32, c1, undefined, [4]i32{ 0, 2, 4, 6 }) - @shuffle(f32, d1, undefined, [4]i32{ 7, 5, 3, 1 });

            const tc1: @Vector(4, f32) = tcos[n8 + i ..][0..4].*;
            const ts1: @Vector(4, f32) = tsin[n8 + i ..][0..4].*;
            const x1_re = dsp.mulAdd(@Vector(4, f32), re1, -tc1, -(im1 * ts1));
            const x1_im = dsp.mulAdd(@Vector(4, f32), re1, ts1, im1 * (-tc1));
            x_f32[2 * (n8 + i) ..][0..8].* = @shuffle(f32, x1_re, x1_im, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
        }

        // 2. N/2-point in-place complex FFT
        fftComptime(n4, &x);

        // 3. Post-rotation directly into frequency bins
        for (0..n8) |idx| {
            const a_re0 = x[n8 - idx - 1].re;
            const a_im0 = x[n8 - idx - 1].im;
            const b_re0 = -tsin[n8 - idx - 1];
            const b_im0 = -tcos[n8 - idx - 1];
            const res_i1 = a_re0 * b_re0 - a_im0 * b_im0;
            const r0 = a_re0 * b_im0 + a_im0 * b_re0;

            const a_re1 = x[n8 + idx].re;
            const a_im1 = x[n8 + idx].im;
            const b_re1 = -tsin[n8 + idx];
            const b_im1 = -tcos[n8 + idx];
            const res_i0 = a_re1 * b_re1 - a_im1 * b_im1;
            const r1 = a_re1 * b_im1 + a_im1 * b_re1;

            out[2 * (n8 - idx - 1)] = r0 * 2.0;
            out[2 * (n8 - idx - 1) + 1] = res_i0 * 2.0;
            out[2 * (n8 + idx)] = r1 * 2.0;
            out[2 * (n8 + idx) + 1] = res_i1 * 2.0;
        }
    }

    /// Computes inverse MDCT (IMDCT): in (N frequency bins) -> out (2N time samples)
    /// by inverting the forward MDCT steps using the N/2-point IFFT and comptime twiddle tables.
    pub fn imdct(comptime N: usize, in: []const f32, out: []f32) void {
        // N is the number of spectral coefficients (1024 or 128)
        // N_time is 2*N (2048 or 256)
        const N2 = N; // N
        const N4 = N / 2; // N/2 = 512 (or 64)
        const N8 = N / 4; // N/4 = 256 (or 32)

        const tcos = if (N == 1024) &TCOS_512 else if (N == 128) &TCOS_64 else unreachable;
        const tsin = if (N == 1024) &TSIN_512 else if (N == 128) &TSIN_64 else unreachable;

        var z1: [N4]Complex = undefined;
        const z1_f32: *[2 * N4]f32 = @ptrCast(&z1);

        // Step 1: Pre-IFFT complex multiplication (Duhamel / FAAD2) using comptime twiddle tables and @Vector(4, f32)
        // c = -tcos[k], s = -tsin[k]
        var k: usize = 0;
        while (k < N4) : (k += 4) {
            const c = -@as(@Vector(4, f32), tcos[k..][0..4].*);
            const s = -@as(@Vector(4, f32), tsin[k..][0..4].*);

            const in_fwd: @Vector(8, f32) = in[2 * k ..][0..8].*;
            const in_rev: @Vector(8, f32) = in[N2 - 8 - 2 * k ..][0..8].*;

            const x1 = @shuffle(f32, in_fwd, undefined, [4]i32{ 0, 2, 4, 6 });
            const x2 = @shuffle(f32, in_rev, undefined, [4]i32{ 7, 5, 3, 1 });

            const re = dsp.mulAdd(@Vector(4, f32), x2, c, -(x1 * s));
            const im = dsp.mulAdd(@Vector(4, f32), x1, c, x2 * s);
            z1_f32[2 * k ..][0..8].* = @shuffle(f32, re, im, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
        }

        // Step 2: Complex IFFT of size N4
        ifftComptime(N4, &z1);

        // Step 3: Post-IFFT complex multiplication using comptime twiddle tables and @Vector(4, f32)
        // Note: IFFT introduces 1/N4 scale factor. In AAC IMDCT, overall factor is 2/N = 1/N4.
        // So with ifftComptime() already applying 1/N4, no extra scaling is needed.
        k = 0;
        while (k < N4) : (k += 4) {
            const c = -@as(@Vector(4, f32), tcos[k..][0..4].*);
            const s = -@as(@Vector(4, f32), tsin[k..][0..4].*);

            const z_raw: @Vector(8, f32) = z1_f32[2 * k ..][0..8].*;
            const rx = @shuffle(f32, z_raw, undefined, [4]i32{ 0, 2, 4, 6 });
            const ix = @shuffle(f32, z_raw, undefined, [4]i32{ 1, 3, 5, 7 });

            const re = dsp.mulAdd(@Vector(4, f32), rx, c, -(ix * s));
            const im = dsp.mulAdd(@Vector(4, f32), ix, c, rx * s);
            z1_f32[2 * k ..][0..8].* = @shuffle(f32, re, im, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
        }

        // Step 4: Reordering into 2N time samples (Duhamel / FAAD2)
        k = 0;
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
