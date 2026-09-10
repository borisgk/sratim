const std = @import("std");

/// MPEG-4 Audio Sample Rate Indices (Table 1.16).
pub const FREQ_INDICES = [_]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
};

pub fn getSampleRateIndex(rate: u32) u4 {
    for (FREQ_INDICES, 0..) |freq, idx| {
        if (freq == rate) return @intCast(idx);
    }
    // If no exact match, find the closest standard frequency
    var best_idx: u4 = 3; // default 48 kHz
    var best_diff: u32 = std.math.maxInt(u32);
    for (FREQ_INDICES, 0..) |freq, idx| {
        const diff = if (freq > rate) freq - rate else rate - freq;
        if (diff < best_diff) {
            best_diff = diff;
            best_idx = @intCast(idx);
        }
    }
    return best_idx;
}

/// 41 Scale Factor Band offsets for 96kHz long windows (1024 bins).
pub const SWB_OFFSET_96000 = [_]u16{
    0,   4,   8,  12,  16,  20,  24,  28,
    32,  36,  40,  44,  48,  52,  56,  64,
    72,  80,  88,  96, 108, 120, 132, 144,
    156, 172, 188, 212, 240, 276, 320, 384,
    448, 512, 576, 640, 704, 768, 832, 896,
    960, 1024,
};

/// 12 Scale Factor Band offsets for 96kHz/64kHz short windows (128 bins).
pub const SWB_OFFSET_SHORT_96000 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128,
};

/// 47 Scale Factor Band offsets for 64kHz long windows (1024 bins).
pub const SWB_OFFSET_64000 = [_]u16{
    0,   4,   8,  12,  16,  20,  24,  28,
    32,  36,  40,  44,  48,  52,  56,  64,
    72,  80,  88, 100, 112, 124, 140, 156,
    172, 192, 216, 240, 268, 304, 344, 384,
    424, 464, 504, 544, 584, 624, 664, 704,
    744, 784, 824, 864, 904, 944, 984, 1024,
};

/// 49 Scale Factor Band offsets for 48kHz/44.1kHz long windows (1024 bins).
pub const SWB_OFFSET_48000 = [_]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  48,  56,  64,
    72,  80,  88,  96,  108, 120, 132, 144, 160, 176, 196, 216, 240, 264,
    292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704,
    736, 768, 800, 832, 864, 896, 928, 1024,
};

/// 14 Scale Factor Band offsets for 48kHz/44.1kHz/32kHz short windows (128 bins).
pub const SWB_OFFSET_SHORT_48000 = [_]u16{
    0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128,
};

/// 51 Scale Factor Band offsets for 32kHz long windows (1024 bins).
pub const SWB_OFFSET_32000 = [_]u16{
    0,   4,   8,  12,  16,  20,  24,  28,
    32,  36,  40,  48,  56,  64,  72,  80,
    88,  96, 108, 120, 132, 144, 160, 176,
    196, 216, 240, 264, 292, 320, 352, 384,
    416, 448, 480, 512, 544, 576, 608, 640,
    672, 704, 736, 768, 800, 832, 864, 896,
    928, 960, 992, 1024,
};

/// 47 Scale Factor Band offsets for 24kHz/22.05kHz long windows (1024 bins).
pub const SWB_OFFSET_24000 = [_]u16{
    0,   4,   8,  12,  16,  20,  24,  28,
    32,  36,  40,  44,  52,  60,  68,  76,
    84,  92, 100, 108, 116, 124, 136, 148,
    160, 172, 188, 204, 220, 240, 260, 284,
    308, 336, 364, 396, 432, 468, 508, 552,
    600, 652, 704, 768, 832, 896, 960, 1024,
};

/// 15 Scale Factor Band offsets for 24kHz/22.05kHz short windows (128 bins).
pub const SWB_OFFSET_SHORT_24000 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128,
};

/// 43 Scale Factor Band offsets for 16kHz/12kHz/11.025kHz long windows (1024 bins).
pub const SWB_OFFSET_16000 = [_]u16{
    0,   8,  16,  24,  32,  40,  48,  56,
    64,  72,  80,  88, 100, 112, 124, 136,
    148, 160, 172, 184, 196, 212, 228, 244,
    260, 280, 300, 320, 344, 368, 396, 424,
    456, 492, 532, 572, 616, 664, 716, 772,
    832, 896, 960, 1024,
};

/// 15 Scale Factor Band offsets for 16kHz/12kHz/11.025kHz short windows (128 bins).
pub const SWB_OFFSET_SHORT_16000 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128,
};

/// 40 Scale Factor Band offsets for 8kHz/7.35kHz long windows (1024 bins).
pub const SWB_OFFSET_8000 = [_]u16{
    0,  12,  24,  36,  48,  60,  72,  84,
    96, 108, 120, 132, 144, 156, 172, 188,
    204, 220, 236, 252, 268, 288, 308, 328,
    348, 372, 396, 420, 448, 476, 508, 544,
    580, 620, 664, 712, 764, 820, 880, 944,
    1024,
};

/// 15 Scale Factor Band offsets for 8kHz/7.35kHz short windows (128 bins).
pub const SWB_OFFSET_SHORT_8000 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128,
};

/// Pointers to long-window (1024) SWB offset tables indexed by MPEG-4 sample rate index (0..12).
pub const SWB_OFFSETS_1024: [13][]const u16 = [_][]const u16{
    &SWB_OFFSET_96000, &SWB_OFFSET_96000, &SWB_OFFSET_64000,
    &SWB_OFFSET_48000, &SWB_OFFSET_48000, &SWB_OFFSET_32000,
    &SWB_OFFSET_24000, &SWB_OFFSET_24000, &SWB_OFFSET_16000,
    &SWB_OFFSET_16000, &SWB_OFFSET_16000, &SWB_OFFSET_8000,
    &SWB_OFFSET_8000,
};

/// Pointers to short-window (128) SWB offset tables indexed by MPEG-4 sample rate index (0..12).
pub const SWB_OFFSETS_128: [13][]const u16 = [_][]const u16{
    &SWB_OFFSET_SHORT_96000, &SWB_OFFSET_SHORT_96000, &SWB_OFFSET_SHORT_96000,
    &SWB_OFFSET_SHORT_48000, &SWB_OFFSET_SHORT_48000, &SWB_OFFSET_SHORT_48000,
    &SWB_OFFSET_SHORT_24000, &SWB_OFFSET_SHORT_24000, &SWB_OFFSET_SHORT_16000,
    &SWB_OFFSET_SHORT_16000, &SWB_OFFSET_SHORT_16000, &SWB_OFFSET_SHORT_8000,
    &SWB_OFFSET_SHORT_8000,
};

/// Number of SWBs for 1024 windows per sample rate index.
pub const NUM_SWB_1024: [13]u8 = [_]u8{ 41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40, 40 };

/// Number of SWBs for 128 windows per sample rate index.
pub const NUM_SWB_128: [13]u8 = [_]u8{ 12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15 };

pub const NUM_SFBS_48000 = 49;
pub const NUM_SHORT_SFBS_48000 = 14;
pub const NUM_SFBS = NUM_SFBS_48000;

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

