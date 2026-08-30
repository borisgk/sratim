const std = @import("std");

/// MPEG-4 Audio Sample Rate Indices (Table 1.16).
pub const FREQ_INDICES = [_]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
};

/// 49 Scale Factor Band offsets for 48kHz long windows (1024 bins).
pub const SWB_OFFSET_48000 = [_]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  48,  56,  64,
    72,  80,  88,  96,  108, 120, 132, 144, 160, 176, 196, 216, 240, 264,
    292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704,
    736, 768, 800, 832, 864, 896, 928, 1024,
};
pub const NUM_SFBS_48000 = 49;
pub const NUM_SFBS = NUM_SFBS_48000;

/// 14 Scale Factor Band offsets for 48kHz short windows (128 bins).
pub const SWB_OFFSET_SHORT_48000 = [_]u16{
    0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128,
};
pub const NUM_SHORT_SFBS_48000 = 14;

/// Precomputed 2048-point Sine window: w[n] = sin(pi / 2048 * (n + 0.5)).
pub const SINE_WINDOW_2048 = blk: {
    @setEvalBranchQuota(5000);
    var w: [2048]f32 = undefined;
    for (0..2048) |i| {
        const angle: f64 = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / 2048.0;
        w[i] = @floatCast(@sin(angle));
    }
    break :blk w;
};

/// Precomputed 256-point Sine window: w[n] = sin(pi / 256 * (n + 0.5)).
pub const SINE_WINDOW_256 = blk: {
    @setEvalBranchQuota(5000);
    var w: [256]f32 = undefined;
    for (0..256) |i| {
        const angle: f64 = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / 256.0;
        w[i] = @floatCast(@sin(angle));
    }
    break :blk w;
};

fn besselI0(x: f64) f64 {
    var sum: f64 = 1.0;
    var term: f64 = 1.0;
    const x2 = x * x / 4.0;
    var k: f64 = 1.0;
    while (k < 50.0) : (k += 1.0) {
        term *= x2 / (k * k);
        sum += term;
        if (term < 1e-15) break;
    }
    return sum;
}

pub fn computeKbdWindow(comptime N: usize, comptime alpha: f64) [N]f32 {
    @setEvalBranchQuota(50000);
    var w: [N]f32 = undefined;
    var kbd: [N / 2 + 1]f64 = undefined;
    var sum: f64 = 0.0;
    const half = N / 2;
    for (0..half + 1) |i| {
        const val = 2.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(half)) - 1.0;
        const arg = if (val * val >= 1.0) 0.0 else std.math.pi * alpha * @sqrt(1.0 - val * val);
        sum += besselI0(arg);
        kbd[i] = sum;
    }
    const total = kbd[half];
    for (0..half) |i| {
        const win_val: f32 = @floatCast(@sqrt(kbd[i] / total));
        w[i] = win_val;
        w[N - 1 - i] = win_val;
    }
    return w;
}

pub const KBD_WINDOW_2048 = computeKbdWindow(2048, 4.0);
pub const KBD_WINDOW_256 = computeKbdWindow(256, 6.0);

/// Precomputed x^(4/3) for values 0..16
pub const POW43 = blk: {
    @setEvalBranchQuota(5000);
    var p: [17]f32 = undefined;
    for (0..17) |i| {
        p[i] = @floatCast(std.math.pow(f64, @as(f64, @floatFromInt(i)), 4.0 / 3.0));
    }
    break :blk p;
};

/// Downmix coefficient for center and surround channels: 1 / sqrt(2) = -3dB
pub const LEVEL_3DB: f32 = 0.7071067811865476;

pub const huffman = @import("huffman.zig");
pub const SCALEFACTOR_CODES = huffman.SF_CODES;
pub const SCALEFACTOR_BITS = huffman.SF_BITS;
pub const CB11_CODES = huffman.CB11_CODES;
pub const CB11_BITS = huffman.CB11_BITS;

/// TNS reflection coefficient mapping tables per ISO/IEC 14496-3 Table 4.158 / Table 4.159.
pub const TNS_TMP2_MAP_0_3 = [_]f32{
    0.00000000, -0.43388373, -0.78183150, -0.97492790,
    0.98480773,  0.86602539,  0.64278758,  0.34202015,
};

pub const TNS_TMP2_MAP_0_4 = [_]f32{
     0.00000000, -0.20791170, -0.40673664, -0.58778524,
    -0.74314481, -0.86602539, -0.95105654, -0.99452192,
     0.99573416,  0.96182561,  0.89516330,  0.79801720,
     0.67369562,  0.52643216,  0.36124167,  0.18374951,
};

pub const TNS_TMP2_MAP_1_3 = [_]f32{
    0.00000000, -0.43388373,  0.64278758,  0.34202015,
};

pub const TNS_TMP2_MAP_1_4 = [_]f32{
    0.00000000, -0.20791170, -0.40673664, -0.58778524,
    0.67369562,  0.52643216,  0.36124167,  0.18374951,
};

/// Maximum number of scale factor bands for TNS per sample rate index.
pub const TNS_MAX_BANDS_1024 = [_]u8{
    31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39, 39,
};

pub const TNS_MAX_BANDS_128 = [_]u8{
    9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
};

