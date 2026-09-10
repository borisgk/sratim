const std = @import("std");
const tables = @import("tables.zig");
const bit_reader = @import("../ac3/bit_reader.zig");
pub const BitReader = bit_reader.BitReader;

pub const AudioSpecificConfig = struct {
    audio_object_type: u8,
    sample_rate_idx: u4,
    sample_rate: u32,
    channel_configuration: u4,
    sbr_present: bool = false,
    ext_sample_rate_idx: ?u4 = null,
    ext_sample_rate: ?u32 = null,
};

pub fn parseAudioSpecificConfig(bytes: []const u8) !AudioSpecificConfig {
    if (bytes.len < 2) return error.BufferTooSmall;
    var reader = BitReader.init(bytes);

    var aot: u8 = try reader.readBits(u5, 5);
    if (aot == 31) {
        aot = 32 + @as(u8, @intCast(try reader.readBits(u6, 6)));
    }

    const sr_idx = try reader.readBits(u4, 4);
    const sample_rate: u32 = if (sr_idx == 15)
        try reader.readBits(u32, 24)
    else if (sr_idx < tables.FREQ_INDICES.len)
        tables.FREQ_INDICES[sr_idx]
    else
        return error.InvalidSampleRateIndex;

    const channel_config = try reader.readBits(u4, 4);

    var sbr_present = false;
    var ext_sr_idx: ?u4 = null;
    var ext_sample_rate: ?u32 = null;

    if (aot == 5 or aot == 29) { // Explicit SBR or PS
        sbr_present = true;
        const e_idx = try reader.readBits(u4, 4);
        ext_sr_idx = e_idx;
        ext_sample_rate = if (e_idx == 15)
            try reader.readBits(u32, 24)
        else if (e_idx < tables.FREQ_INDICES.len)
            tables.FREQ_INDICES[e_idx]
        else
            null;
        aot = try reader.readBits(u5, 5);
        if (aot == 31) {
            aot = 32 + @as(u8, @intCast(try reader.readBits(u6, 6)));
        }
    } else {
        // Skip GASpecificConfig fields for AAC-LC:
        // frameLengthFlag (1), dependsOnCoreCoder (1), if (dependsOnCoreCoder) coreCoderDelay (14), extensionFlag (1)
        if (aot == 2) {
            _ = reader.readBit() catch 0;
            const dependsOnCore = (reader.readBit() catch 0) == 1;
            if (dependsOnCore) _ = reader.readBits(u16, 14) catch 0;
            _ = reader.readBit() catch 0;
        }
        // Check for backward-compatible SBR sync extension (0x2B7)
        if (reader.bitsLeft() >= 16) {
            const sync_ext = reader.readBits(u11, 11) catch 0;
            if (sync_ext == 0x2B7) {
                const ext_aot = reader.readBits(u5, 5) catch 0;
                if (ext_aot == 5) {
                    sbr_present = (reader.readBit() catch 0) == 1;
                    if (sbr_present and reader.bitsLeft() >= 4) {
                        const e_idx = reader.readBits(u4, 4) catch 0;
                        ext_sr_idx = e_idx;
                        ext_sample_rate = if (e_idx < tables.FREQ_INDICES.len) tables.FREQ_INDICES[e_idx] else null;
                    }
                }
            }
        }
    }

    return AudioSpecificConfig{
        .audio_object_type = aot,
        .sample_rate_idx = sr_idx,
        .sample_rate = sample_rate,
        .channel_configuration = channel_config,
        .sbr_present = sbr_present,
        .ext_sample_rate_idx = ext_sr_idx,
        .ext_sample_rate = ext_sample_rate,
    };
}
