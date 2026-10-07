const std = @import("std");
const track_parser = @import("track_parser.zig");

test "buildAvc1Stsd and buildAacStsd structure" {
    const allocator = std.testing.allocator;

    const mock_avcC = [_]u8{ 0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x04, 0x27, 0x64, 0x00, 0x1F, 0x01, 0x00, 0x04, 0x28, 0xEE, 0x38, 0x80 };
    const avc_stsd = try track_parser.buildAvc1Stsd(allocator, &mock_avcC, 1920, 1080);
    defer allocator.free(avc_stsd);

    try std.testing.expect(avc_stsd.len > 86);
    try std.testing.expectEqualStrings("stsd", avc_stsd[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, avc_stsd, "avc1") != null);
    try std.testing.expect(std.mem.indexOf(u8, avc_stsd, "avcC") != null);

    const mock_asc = [_]u8{ 0x12, 0x10 }; // AAC-LC, 44.1kHz, stereo
    const aac_stsd = try track_parser.buildAacStsd(allocator, &mock_asc, 2, 44100);
    defer allocator.free(aac_stsd);

    try std.testing.expect(aac_stsd.len > 36);
    try std.testing.expectEqualStrings("stsd", aac_stsd[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, aac_stsd, "mp4a") != null);
    try std.testing.expect(std.mem.indexOf(u8, aac_stsd, "esds") != null);

    const mock_av1C = [_]u8{ 0x81, 0x00, 0x0C, 0x00 }; // Marker=1, version=1, profile 0, level 0.0, 8-bit
    const av1_stsd = try track_parser.buildAv1Stsd(allocator, &mock_av1C, 320, 240);
    defer allocator.free(av1_stsd);

    try std.testing.expect(av1_stsd.len > 86);
    try std.testing.expectEqualStrings("stsd", av1_stsd[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, av1_stsd, "av01") != null);
    try std.testing.expect(std.mem.indexOf(u8, av1_stsd, "av1C") != null);
}
