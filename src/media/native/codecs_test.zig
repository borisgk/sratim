const std = @import("std");
const codecs = @import("codecs.zig");

test "getVideoCodecString for AVC, HEVC, AV1, VP9" {
    const allocator = std.testing.allocator;

    const avc = try codecs.getVideoCodecString(allocator, "V_MPEG4/ISO/AVC", 1920, 1080);
    try std.testing.expectEqualStrings("video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"", avc.getStr().?);

    const hevc_4k = try codecs.getVideoCodecString(allocator, "V_MPEGH/ISO/HEVC", 3840, 2160);
    defer if (hevc_4k.dynamic_str) |s| allocator.free(s);
    try std.testing.expectEqualStrings("video/mp4; codecs=\"hev1.2.4.L150.B0, mp4a.40.2\"", hevc_4k.getStr().?);

    const av1 = try codecs.getVideoCodecString(allocator, "V_AV1", 1920, 1080);
    try std.testing.expectEqualStrings("video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"", av1.getStr().?);

    try std.testing.expectEqualStrings("AC-3 (Dolby Digital)", codecs.getAudioCodecDisplayName("A_AC3"));
    try std.testing.expectEqualStrings("E-AC-3 (Dolby Digital Plus)", codecs.getAudioCodecDisplayName("A_EAC3"));
    try std.testing.expectEqualStrings("MP3", codecs.getAudioCodecDisplayName("A_MPEG/L3"));
    try std.testing.expectEqualStrings("AAC-LC", codecs.getAudioCodecDisplayName("mp4a"));
}
