const std = @import("std");

pub const Complex = struct {
    real: f32,
    imag: f32,
};

fn besselI0(x: f64) f64 {
    var bessel: f64 = 1.0;
    var term: f64 = 1.0;
    var i: usize = 1;
    while (i < 50) : (i += 1) {
        const fi = @as(f64, @floatFromInt(i));
        term = term * x / (4.0 * fi * fi);
        bessel += term;
        if (term < 1e-15) break;
    }
    return bessel;
}

pub fn makeWindow() [256]f32 {
    @setEvalBranchQuota(100000);
    var window: [256]f32 = undefined;
    var sum: f64 = 0.0;
    const alpha_pi = 5.0 * std.math.pi / 256.0;
    const factor = alpha_pi * alpha_pi;

    for (0..256) |i| {
        const fi = @as(f64, @floatFromInt(i));
        const arg = fi * (256.0 - fi) * factor;
        sum += besselI0(arg);
        window[i] = @floatCast(sum);
    }
    sum += 1.0;
    for (0..256) |i| {
        window[i] = @floatCast(@sqrt(@as(f64, window[i]) / sum));
    }
    return window;
}

pub const KBD_WINDOW = makeWindow();

pub const FFT_ORDER: [128]u8 = .{
      0, 128,  64, 192,  32, 160, 224,  96,  16, 144,  80, 208, 240, 112,  48, 176,
      8, 136,  72, 200,  40, 168, 232, 104, 248, 120,  56, 184,  24, 152, 216,  88,
      4, 132,  68, 196,  36, 164, 228, 100,  20, 148,  84, 212, 244, 116,  52, 180,
    252, 124,  60, 188,  28, 156, 220,  92,  12, 140,  76, 204, 236, 108,  44, 172,
      2, 130,  66, 194,  34, 162, 226,  98,  18, 146,  82, 210, 242, 114,  50, 178,
     10, 138,  74, 202,  42, 170, 234, 106, 250, 122,  58, 186,  26, 154, 218,  90,
    254, 126,  62, 190,  30, 158, 222,  94,  14, 142,  78, 206, 238, 110,  46, 174,
      6, 134,  70, 198,  38, 166, 230, 102, 246, 118,  54, 182,  22, 150, 214,  86,
};

pub const ROOTS16 = computeRoots(3, 8);
pub const ROOTS32 = computeRoots(7, 16);
pub const ROOTS64 = computeRoots(15, 32);
pub const ROOTS128 = computeRoots(31, 64);

fn computeRoots(comptime n: usize, comptime denom: f64) [n]f32 {
    @setEvalBranchQuota(10000);
    var r: [n]f32 = undefined;
    for (0..n) |i| {
        const fi = @as(f64, @floatFromInt(i + 1));
        r[i] = @floatCast(std.math.cos((std.math.pi / denom) * fi));
    }
    return r;
}

pub const PRE1 = computePre1();
pub const POST1 = computePost1();

fn computePre1() [128]Complex {
    @setEvalBranchQuota(50000);
    var p: [128]Complex = undefined;
    for (0..64) |i| {
        const k = @as(f64, @floatFromInt(FF_ORDER_DIV2_PLUS64(i)));
        p[i] = .{
            .real = @floatCast(std.math.cos((std.math.pi / 256.0) * (k - 0.25))),
            .imag = @floatCast(std.math.sin((std.math.pi / 256.0) * (k - 0.25))),
        };
    }
    for (64..128) |i| {
        const k = @as(f64, @floatFromInt(FF_ORDER_DIV2_PLUS64(i)));
        p[i] = .{
            .real = -@as(f32, @floatCast(std.math.cos((std.math.pi / 256.0) * (k - 0.25)))),
            .imag = -@as(f32, @floatCast(std.math.sin((std.math.pi / 256.0) * (k - 0.25)))),
        };
    }
    return p;
}

fn FF_ORDER_DIV2_PLUS64(i: usize) usize {
    return @as(usize, FFT_ORDER[i]) / 2 + 64;
}

fn computePost1() [64]Complex {
    @setEvalBranchQuota(50000);
    var p: [64]Complex = undefined;
    for (0..64) |i| {
        const fi = @as(f64, @floatFromInt(i));
        p[i] = .{
            .real = @floatCast(std.math.cos((std.math.pi / 256.0) * (fi + 0.5))),
            .imag = @floatCast(std.math.sin((std.math.pi / 256.0) * (fi + 0.5))),
        };
    }
    return p;
}

inline fn ifft2(buf: *[2]Complex) void {
    const r = buf[0].real;
    const i = buf[0].imag;
    buf[0].real += buf[1].real;
    buf[0].imag += buf[1].imag;
    buf[1].real = r - buf[1].real;
    buf[1].imag = i - buf[1].imag;
}

inline fn ifft4(buf: *[4]Complex) void {
    const tmp1 = buf[0].real + buf[1].real;
    const tmp2 = buf[3].real + buf[2].real;
    const tmp3 = buf[0].imag + buf[1].imag;
    const tmp4 = buf[2].imag + buf[3].imag;
    const tmp5 = buf[0].real - buf[1].real;
    const tmp6 = buf[0].imag - buf[1].imag;
    const tmp7 = buf[2].imag - buf[3].imag;
    const tmp8 = buf[3].real - buf[2].real;

    buf[0].real = tmp1 + tmp2;
    buf[0].imag = tmp3 + tmp4;
    buf[2].real = tmp1 - tmp2;
    buf[2].imag = tmp3 - tmp4;
    buf[1].real = tmp5 + tmp7;
    buf[1].imag = tmp6 + tmp8;
    buf[3].real = tmp5 - tmp7;
    buf[3].imag = tmp6 - tmp8;
}

inline fn butterfly(a0: *Complex, a1: *Complex, a2: *Complex, a3: *Complex, wr: f32, wi: f32) void {
    const tmp5 = a2.real * wr + a2.imag * wi;
    const tmp6 = a2.imag * wr - a2.real * wi;
    const tmp7 = a3.real * wr - a3.imag * wi;
    const tmp8 = a3.imag * wr + a3.real * wi;
    const tmp1 = tmp5 + tmp7;
    const tmp2 = tmp6 + tmp8;
    const tmp3 = tmp6 - tmp8;
    const tmp4 = tmp7 - tmp5;
    a2.real = a0.real - tmp1;
    a2.imag = a0.imag - tmp2;
    a3.real = a1.real - tmp3;
    a3.imag = a1.imag - tmp4;
    a0.real += tmp1;
    a0.imag += tmp2;
    a1.real += tmp3;
    a1.imag += tmp4;
}

inline fn butterflyZero(a0: *Complex, a1: *Complex, a2: *Complex, a3: *Complex) void {
    const tmp1 = a2.real + a3.real;
    const tmp2 = a2.imag + a3.imag;
    const tmp3 = a2.imag - a3.imag;
    const tmp4 = a3.real - a2.real;
    a2.real = a0.real - tmp1;
    a2.imag = a0.imag - tmp2;
    a3.real = a1.real - tmp3;
    a3.imag = a1.imag - tmp4;
    a0.real += tmp1;
    a0.imag += tmp2;
    a1.real += tmp3;
    a1.imag += tmp4;
}

inline fn butterflyHalf(a0: *Complex, a1: *Complex, a2: *Complex, a3: *Complex, w: f32) void {
    const tmp5 = (a2.real + a2.imag) * w;
    const tmp6 = (a2.imag - a2.real) * w;
    const tmp7 = (a3.real - a3.imag) * w;
    const tmp8 = (a3.imag + a3.real) * w;
    const tmp1 = tmp5 + tmp7;
    const tmp2 = tmp6 + tmp8;
    const tmp3 = tmp6 - tmp8;
    const tmp4 = tmp7 - tmp5;
    a2.real = a0.real - tmp1;
    a2.imag = a0.imag - tmp2;
    a3.real = a1.real - tmp3;
    a3.imag = a1.imag - tmp4;
    a0.real += tmp1;
    a0.imag += tmp2;
    a1.real += tmp3;
    a1.imag += tmp4;
}

fn ifft8(buf: *[8]Complex) void {
    ifft4(buf[0..4]);
    ifft2(buf[4..6]);
    ifft2(buf[6..8]);
    butterflyZero(&buf[0], &buf[2], &buf[4], &buf[6]);
    butterflyHalf(&buf[1], &buf[3], &buf[5], &buf[7], ROOTS16[1]);
}

fn ifftPass(buf: []Complex, weight: []const f32, n: usize) void {
    butterflyZero(&buf[0], &buf[n], &buf[2 * n], &buf[3 * n]);
    var s: usize = 0;
    const limit = n - 1;

    const mask_even = @Vector(4, i32){ 0, 2, 4, 6 };
    const mask_odd = @Vector(4, i32){ 1, 3, 5, 7 };
    const mask_rev = @Vector(4, i32){ 3, 2, 1, 0 };
    const mask_interleave = @Vector(8, i32){ 0, -1, 1, -2, 2, -3, 3, -4 };

    while (s + 4 <= limit) : (s += 4) {
        const idx = s + 1;

        const c0: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&buf[idx])).*;
        const c1: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&buf[n + idx])).*;
        const c2: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&buf[2 * n + idx])).*;
        const c3: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&buf[3 * n + idx])).*;

        const a0_re = @shuffle(f32, c0, undefined, mask_even);
        const a0_im = @shuffle(f32, c0, undefined, mask_odd);
        const a1_re = @shuffle(f32, c1, undefined, mask_even);
        const a1_im = @shuffle(f32, c1, undefined, mask_odd);
        const a2_re = @shuffle(f32, c2, undefined, mask_even);
        const a2_im = @shuffle(f32, c2, undefined, mask_odd);
        const a3_re = @shuffle(f32, c3, undefined, mask_even);
        const a3_im = @shuffle(f32, c3, undefined, mask_odd);

        const v_wr: @Vector(4, f32) = weight[s..][0..4].*;
        const raw_wi: @Vector(4, f32) = weight[n - 2 - s - 3 ..][0..4].*;
        const v_wi = @shuffle(f32, raw_wi, undefined, mask_rev);

        const tmp5 = a2_re * v_wr + a2_im * v_wi;
        const tmp6 = a2_im * v_wr - a2_re * v_wi;
        const tmp7 = a3_re * v_wr - a3_im * v_wi;
        const tmp8 = a3_im * v_wr + a3_re * v_wi;

        const tmp1 = tmp5 + tmp7;
        const tmp2 = tmp6 + tmp8;
        const tmp3 = tmp6 - tmp8;
        const tmp4 = tmp7 - tmp5;

        const new_a2_re = a0_re - tmp1;
        const new_a2_im = a0_im - tmp2;
        const new_a3_re = a1_re - tmp3;
        const new_a3_im = a1_im - tmp4;
        const new_a0_re = a0_re + tmp1;
        const new_a0_im = a0_im + tmp2;
        const new_a1_re = a1_re + tmp3;
        const new_a1_im = a1_im + tmp4;

        @as(*[8]f32, @ptrCast(&buf[idx])).* = @shuffle(f32, new_a0_re, new_a0_im, mask_interleave);
        @as(*[8]f32, @ptrCast(&buf[n + idx])).* = @shuffle(f32, new_a1_re, new_a1_im, mask_interleave);
        @as(*[8]f32, @ptrCast(&buf[2 * n + idx])).* = @shuffle(f32, new_a2_re, new_a2_im, mask_interleave);
        @as(*[8]f32, @ptrCast(&buf[3 * n + idx])).* = @shuffle(f32, new_a3_re, new_a3_im, mask_interleave);
    }

    while (s < limit) : (s += 1) {
        const idx = s + 1;
        const wr = weight[s];
        const wi = weight[n - 2 - s];
        butterfly(&buf[idx], &buf[n + idx], &buf[2 * n + idx], &buf[3 * n + idx], wr, wi);
    }
}

fn ifft16(buf: *[16]Complex) void {
    ifft8(buf[0..8]);
    ifft4(buf[8..12]);
    ifft4(buf[12..16]);
    ifftPass(buf, &ROOTS16, 4);
}

fn ifft32(buf: *[32]Complex) void {
    ifft16(buf[0..16]);
    ifft8(buf[16..24]);
    ifft8(buf[24..32]);
    ifftPass(buf, &ROOTS32, 8);
}

pub fn ifft64(buf: *[64]Complex) void {
    ifft32(buf[0..32]);
    ifft16(buf[32..48]);
    ifft16(buf[48..64]);
    ifftPass(buf, &ROOTS64, 16);
}

pub fn ifft128(buf: *[128]Complex) void {
    ifft32(buf[0..32]);
    ifft16(buf[32..48]);
    ifft16(buf[48..64]);
    ifftPass(buf, &ROOTS64, 16);

    ifft32(buf[64..96]);
    ifft32(buf[96..128]);
    ifftPass(buf, &ROOTS128, 32);
}

pub fn imdct512(data: *[256]f32, delay: *[256]f32) void {
    var buf: [128]Complex = undefined;
    const mask_pre_interleave = @Vector(8, i32){ 0, -1, 1, -2, 2, -3, 3, -4 };
    const mask_even = @Vector(4, i32){ 0, 2, 4, 6 };
    const mask_odd = @Vector(4, i32){ 1, 3, 5, 7 };

    var pre_i: usize = 0;
    while (pre_i < 128) : (pre_i += 4) {
        const k0 = FFT_ORDER[pre_i];
        const k1 = FFT_ORDER[pre_i + 1];
        const k2 = FFT_ORDER[pre_i + 2];
        const k3 = FFT_ORDER[pre_i + 3];

        const dk: @Vector(4, f32) = .{ data[k0], data[k1], data[k2], data[k3] };
        const d_rev: @Vector(4, f32) = .{ data[255 - k0], data[255 - k1], data[255 - k2], data[255 - k3] };

        const c_pre: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&PRE1[pre_i])).*;
        const tr = @shuffle(f32, c_pre, undefined, mask_even);
        const ti = @shuffle(f32, c_pre, undefined, mask_odd);

        const buf_re = ti * d_rev + tr * dk;
        const buf_im = tr * d_rev - ti * dk;

        @as(*[8]f32, @ptrCast(&buf[pre_i])).* = @shuffle(f32, buf_re, buf_im, mask_pre_interleave);
    }

    ifft128(&buf);

    var post_i: usize = 0;
    const mask_post_even = @Vector(4, i32){ 0, 2, 4, 6 };
    const mask_post_odd = @Vector(4, i32){ 1, 3, 5, 7 };
    const mask_post_rev = @Vector(4, i32){ 3, 2, 1, 0 };
    const mask_post_interleave = @Vector(8, i32){ 0, -1, 1, -2, 2, -3, 3, -4 };
    const mask_rev_8 = @Vector(8, i32){ 7, 6, 5, 4, 3, 2, 1, 0 };
    const sign_front = @Vector(8, f32){ -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0 };
    const sign_back = @Vector(8, f32){ 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0 };

    while (post_i < 64) : (post_i += 4) {
        const c_buf: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&buf[post_i])).*;
        const buf_re = @shuffle(f32, c_buf, undefined, mask_post_even);
        const buf_im = @shuffle(f32, c_buf, undefined, mask_post_odd);

        const c_back: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&buf[127 - post_i - 3])).*;
        const back_re_raw = @shuffle(f32, c_back, undefined, mask_post_even);
        const back_im_raw = @shuffle(f32, c_back, undefined, mask_post_odd);
        const back_re = @shuffle(f32, back_re_raw, undefined, mask_post_rev);
        const back_im = @shuffle(f32, back_im_raw, undefined, mask_post_rev);

        const c_post: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(&POST1[post_i])).*;
        const tr = @shuffle(f32, c_post, undefined, mask_post_even);
        const ti = @shuffle(f32, c_post, undefined, mask_post_odd);

        const ar = tr * buf_re + ti * buf_im;
        const ai = ti * buf_re - tr * buf_im;
        const br = ti * back_re + tr * back_im;
        const bi = tr * back_re - ti * back_im;

        const r_interleaved = @shuffle(f32, ar, br, mask_post_interleave);
        const i_interleaved = @shuffle(f32, ai, bi, mask_post_interleave);

        const k = 2 * post_i;
        const w1_vec: @Vector(8, f32) = KBD_WINDOW[k..][0..8].*;
        const w2_raw: @Vector(8, f32) = KBD_WINDOW[255 - k - 7 ..][0..8].*;
        const w2_vec = @shuffle(f32, w2_raw, undefined, mask_rev_8);

        const delay_front: @Vector(8, f32) = delay[k..][0..8].*;

        const data_front = delay_front * w2_vec + (r_interleaved * sign_front) * w1_vec;
        const data_back = delay_front * w1_vec + (r_interleaved * sign_back) * w2_vec;

        @as(*[8]f32, @ptrCast(&data[k])).* = data_front;
        @as(*[8]f32, @ptrCast(&data[255 - k - 7])).* = @shuffle(f32, data_back, undefined, mask_rev_8);
        @as(*[8]f32, @ptrCast(&delay[k])).* = i_interleaved;
    }
}

test "imdct512 runs on zero input" {
    var data: [256]f32 = @splat(0.0);
    var delay: [256]f32 = @splat(0.0);
    imdct512(&data, &delay);
    for (data) |d| {
        try std.testing.expectEqual(@as(f32, 0.0), d);
    }
}

test "imdct512 executes on non-zero spectral bin" {
    var data1: [256]f32 = @splat(0.0);
    data1[10] = 1.0;
    var delay: [256]f32 = @splat(0.0);
    imdct512(&data1, &delay);

    var has_nonzero = false;
    for (data1) |v| {
        if (@abs(v) > 1e-4) has_nonzero = true;
    }
    try std.testing.expect(has_nonzero);

    var data2: [256]f32 = @splat(0.0);
    imdct512(&data2, &delay);
    var has_nonzero2 = false;
    for (data2) |v| {
        if (@abs(v) > 1e-4) has_nonzero2 = true;
    }
    try std.testing.expect(has_nonzero2);
}
