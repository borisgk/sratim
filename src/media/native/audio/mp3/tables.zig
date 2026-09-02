const std = @import("std");

/// Supported MPEG audio versions
pub const MpegVersion = enum(u2) {
    mpeg2_5 = 0, // MPEG 2.5
    reserved = 1,
    mpeg2 = 2, // MPEG 2 (ISO/IEC 13818-3)
    mpeg1 = 3, // MPEG 1 (ISO/IEC 11172-3)
};

/// Supported MPEG layers
pub const MpegLayer = enum(u2) {
    reserved = 0,
    layer3 = 1, // Layer III (MP3)
    layer2 = 2, // Layer II
    layer1 = 3, // Layer I
};

/// Channel modes
pub const ChannelMode = enum(u2) {
    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    single_channel = 3, // Mono
};

/// Sampling rates in Hz: [version][srate_idx]
pub const SAMPLE_RATES = [4][3]u32{
    .{ 11025, 12000, 8000 }, // MPEG 2.5
    .{ 0, 0, 0 }, // Reserved
    .{ 22050, 24000, 16000 }, // MPEG 2
    .{ 44100, 48000, 32000 }, // MPEG 1
};

/// Bitrates in kbps for Layer III: [version][bitrate_idx]
pub const BITRATES_LAYER3 = [4][16]u16{
    // MPEG 2.5
    .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
    // Reserved
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // MPEG 2
    .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
    // MPEG 1
    .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 },
};

/// Pre-emphasis table for long blocks (preflag == 1)
pub const PRETAB = [22]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3,
};

/// Scalefactor band widths for MPEG-1 long blocks (22 bands): [sample_rate_index][band]
pub const SFB_MPEG1_LONG = [3][23]u16{
    // 44.1 kHz
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576 },
    // 48 kHz
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576 },
    // 32 kHz
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576 },
};

/// Scalefactor band widths for MPEG-1 short blocks (13 bands, 3 windows each): [sample_rate_index][band]
pub const SFB_MPEG1_SHORT = [3][14]u16{
    // 44.1 kHz
    .{ 0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192 },
    // 48 kHz
    .{ 0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192 },
    // 32 kHz
    .{ 0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192 },
};

/// Scalefactor band widths for MPEG-2 / 2.5 long blocks (22 bands)
pub const SFB_MPEG2_LONG = [3][23]u16{
    // 22.05 kHz
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    // 24 kHz
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 114, 136, 162, 194, 232, 278, 332, 394, 464, 540, 576 },
    // 16 kHz
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
};

/// Scalefactor band widths for MPEG-2 / 2.5 short blocks (13 bands)
pub const SFB_MPEG2_SHORT = [3][14]u16{
    // 22.05 kHz
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 136, 180, 192 },
    // 24 kHz
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    // 16 kHz
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 136, 180, 192 },
};

/// Scalefactor transmission lengths for MPEG-1 (slen1, slen2 from scalefac_compress)
pub const SLEN_MPEG1 = [16][2]u4{
    .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 },
    .{ 3, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 3 },
    .{ 2, 1 }, .{ 2, 2 }, .{ 2, 3 }, .{ 3, 1 },
    .{ 3, 2 }, .{ 3, 3 }, .{ 4, 2 }, .{ 4, 3 },
};

/// Alias reduction butterfly coefficients: 8 butterflies between each pair of subbands
pub const ALIAS_CS = [8]f32{
    0.8574929257125442,
    0.8817419973177053,
    0.9496286491027328,
    0.9833145924917900,
    0.9955178160675858,
    0.9991605581781475,
    0.9998991952444471,
    0.9999931550702636,
};

pub const ALIAS_CA = [8]f32{
    -0.5144957554275265,
    -0.4717319685649723,
    -0.3133774542039018,
    -0.1819131996109811,
    -0.0945741925264206,
    -0.0409655828853040,
    -0.0141985685724711,
    -0.0036999746737599,
};

/// Window function generation for 36-point long blocks
pub fn getWindowLong(block_type: u2, i: usize) f32 {
    const pi = std.math.pi;
    return switch (block_type) {
        0 => @sin(pi / 36.0 * (@as(f32, @floatFromInt(i)) + 0.5)), // Normal window
        1 => if (i < 18) // Start window
            @sin(pi / 36.0 * (@as(f32, @floatFromInt(i)) + 0.5))
        else if (i < 24)
            1.0
        else if (i < 30)
            @sin(pi / 12.0 * (@as(f32, @floatFromInt(i - 18)) + 0.5))
        else
            0.0,
        2 => 0.0, // Short blocks handled separately
        3 => if (i < 6) // Stop window
            0.0
        else if (i < 12)
            @sin(pi / 12.0 * (@as(f32, @floatFromInt(i - 6)) + 0.5))
        else if (i < 18)
            1.0
        else
            @sin(pi / 36.0 * (@as(f32, @floatFromInt(i)) + 0.5)),
    };
}

/// Window function generation for 12-point short blocks
pub fn getWindowShort(i: usize) f32 {
    return @sin(std.math.pi / 12.0 * (@as(f32, @floatFromInt(i)) + 0.5));
}

/// Standard 512-coefficient synthesis filter window (D-window)
pub const SYNTHESIS_WINDOW: [512]f32 = initSynthWindow();

fn initSynthWindow() [512]f32 {
    @setEvalBranchQuota(50000);
    var win: [512]f32 = undefined;
    for (0..512) |i| {
        const x = (@as(f32, @floatFromInt(i)) + 0.5) / 512.0;
        win[i] = -@sin(std.math.pi * x) * (0.5 - 0.5 * @cos(2.0 * std.math.pi * x));
    }
    return win;
}
