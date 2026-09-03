const std = @import("std");

pub const CodecResult = struct {
    static_str: ?[]const u8 = null,
    dynamic_str: ?[]const u8 = null,

    pub fn getStr(self: CodecResult) ?[]const u8 {
        return self.dynamic_str orelse self.static_str;
    }
};

/// Computes browser-compatible video MIME codec string based on container CodecID and resolution.
pub fn getVideoCodecString(allocator: std.mem.Allocator, codec_id: []const u8, width: u32, height: u32) !CodecResult {
    if (std.mem.eql(u8, codec_id, "V_MPEG4/ISO/AVC")) {
        return CodecResult{ .static_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"" };
    } else if (std.mem.eql(u8, codec_id, "V_MPEGH/ISO/HEVC")) {
        const luma = width * height;
        const min_level: u32 = if (luma > 8_912_896) 156
            else if (luma > 2_228_224) 150
            else if (luma > 983_040) 120
            else 93;
        const dynamic_str = try std.fmt.allocPrint(allocator,
            "video/mp4; codecs=\"hev1.2.4.L{d}.B0, mp4a.40.2\"",
            .{min_level});
        return CodecResult{ .dynamic_str = dynamic_str };
    } else if (std.mem.eql(u8, codec_id, "V_AV1")) {
        return CodecResult{ .static_str = "video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"" };
    } else if (std.mem.eql(u8, codec_id, "V_VP9")) {
        return CodecResult{ .static_str = "video/mp4; codecs=\"vp09.00.10.08, mp4a.40.2\"" };
    }
    return CodecResult{};
}

/// Computes browser-compatible video MIME codec string based on ISOBMFF 4-character FourCC and resolution.
pub fn getVideoCodecStringFromFourCC(allocator: std.mem.Allocator, fourcc: [4]u8, width: u32, height: u32) !CodecResult {
    if (std.mem.eql(u8, &fourcc, "avc1")) {
        return CodecResult{ .static_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"" };
    } else if (std.mem.eql(u8, &fourcc, "hev1") or std.mem.eql(u8, &fourcc, "hvc1")) {
        const luma = width * height;
        const min_level: u32 = if (luma > 8_912_896) 156
            else if (luma > 2_228_224) 150
            else if (luma > 983_040) 120
            else 93;
        const dynamic_str = try std.fmt.allocPrint(allocator,
            "video/mp4; codecs=\"{s}.2.4.L{d}.B0, mp4a.40.2\"",
            .{ fourcc, min_level });
        return CodecResult{ .dynamic_str = dynamic_str };
    } else if (std.mem.eql(u8, &fourcc, "av01")) {
        return CodecResult{ .static_str = "video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"" };
    } else if (std.mem.eql(u8, &fourcc, "vp09")) {
        return CodecResult{ .static_str = "video/mp4; codecs=\"vp09.00.10.08, mp4a.40.2\"" };
    }
    return CodecResult{ .static_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"" };
}

/// Maps container audio codec IDs or sample FourCCs to clean, human-readable display names.
pub fn getAudioCodecDisplayName(codec_id_or_fourcc: []const u8) []const u8 {
    if (std.mem.eql(u8, codec_id_or_fourcc, "A_AC3") or std.mem.eql(u8, codec_id_or_fourcc, "ac-3") or std.mem.eql(u8, codec_id_or_fourcc, "sac3")) {
        return "AC-3 (Dolby Digital)";
    } else if (std.mem.eql(u8, codec_id_or_fourcc, "A_EAC3") or std.mem.eql(u8, codec_id_or_fourcc, "ec-3")) {
        return "E-AC-3 (Dolby Digital Plus)";
    } else if (std.mem.eql(u8, codec_id_or_fourcc, "A_AAC") or std.mem.eql(u8, codec_id_or_fourcc, "mp4a")) {
        return "AAC-LC";
    } else if (std.mem.startsWith(u8, codec_id_or_fourcc, "A_MPEG/L3") or std.mem.eql(u8, codec_id_or_fourcc, ".mp3") or std.mem.eql(u8, codec_id_or_fourcc, "mp3 ") or std.mem.eql(u8, codec_id_or_fourcc, "mp3")) {
        return "MP3";
    } else if (std.mem.startsWith(u8, codec_id_or_fourcc, "A_MPEG/L2")) {
        return "MP2";
    } else if (std.mem.startsWith(u8, codec_id_or_fourcc, "A_MPEG/L1")) {
        return "MP1";
    } else if (std.mem.startsWith(u8, codec_id_or_fourcc, "A_DTS") or std.mem.eql(u8, codec_id_or_fourcc, "dts ") or std.mem.eql(u8, codec_id_or_fourcc, "dtsc") or std.mem.eql(u8, codec_id_or_fourcc, "dtsh")) {
        return "DTS";
    } else if (std.mem.eql(u8, codec_id_or_fourcc, "A_FLAC") or std.mem.eql(u8, codec_id_or_fourcc, "flac")) {
        return "FLAC";
    } else if (std.mem.eql(u8, codec_id_or_fourcc, "A_OPUS") or std.mem.eql(u8, codec_id_or_fourcc, "Opus") or std.mem.eql(u8, codec_id_or_fourcc, "opus")) {
        return "Opus";
    } else if (std.mem.eql(u8, codec_id_or_fourcc, "A_VORBIS") or std.mem.eql(u8, codec_id_or_fourcc, "vorbis")) {
        return "Vorbis";
    } else if (std.mem.eql(u8, codec_id_or_fourcc, "A_TRUEHD") or std.mem.eql(u8, codec_id_or_fourcc, "mlpa")) {
        return "TrueHD";
    } else if (std.mem.startsWith(u8, codec_id_or_fourcc, "A_PCM")) {
        return "PCM";
    } else if (codec_id_or_fourcc.len > 0) {
        return codec_id_or_fourcc;
    }
    return "Unknown";
}

test "getVideoCodecString for AVC, HEVC, AV1, VP9" {
    const allocator = std.testing.allocator;

    const avc = try getVideoCodecString(allocator, "V_MPEG4/ISO/AVC", 1920, 1080);
    try std.testing.expectEqualStrings("video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"", avc.getStr().?);

    const hevc_4k = try getVideoCodecString(allocator, "V_MPEGH/ISO/HEVC", 3840, 2160);
    defer if (hevc_4k.dynamic_str) |s| allocator.free(s);
    try std.testing.expectEqualStrings("video/mp4; codecs=\"hev1.2.4.L150.B0, mp4a.40.2\"", hevc_4k.getStr().?);

    const av1 = try getVideoCodecString(allocator, "V_AV1", 1920, 1080);
    try std.testing.expectEqualStrings("video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"", av1.getStr().?);

    try std.testing.expectEqualStrings("AC-3 (Dolby Digital)", getAudioCodecDisplayName("A_AC3"));
    try std.testing.expectEqualStrings("E-AC-3 (Dolby Digital Plus)", getAudioCodecDisplayName("A_EAC3"));
    try std.testing.expectEqualStrings("MP3", getAudioCodecDisplayName("A_MPEG/L3"));
    try std.testing.expectEqualStrings("AAC-LC", getAudioCodecDisplayName("mp4a"));
}
