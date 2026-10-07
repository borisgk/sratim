const std = @import("std");
const fmp4_muxer = @import("fmp4_muxer.zig");
const isobmff = @import("isobmff.zig");

test "buildInitSegment ftyp and moov structure" {
    const allocator = std.testing.allocator;

    const mock_stsd = [_]u8{ 0, 0, 0, 16, 's', 't', 's', 'd', 0, 0, 0, 0, 0, 0, 0, 1 };
    const stsd_raw = try allocator.dupe(u8, &mock_stsd);

    const video_track = isobmff.Mp4MediaTrack{
        .track_id = 1,
        .stream_idx = 0,
        .handler_type = "vide".*,
        .timescale = 30000,
        .duration = 300000,
        .width = 1920,
        .height = 1080,
        .stsd_raw = stsd_raw,
        .samples = &.{},
        .sync_sample_indices = &.{},
    };
    var mut_video = video_track;
    defer mut_video.deinit(allocator);

    const init_seg = try fmp4_muxer.buildInitSegment(allocator, mut_video, null);
    defer allocator.free(init_seg);

    try std.testing.expect(init_seg.len >= 28);
    try std.testing.expectEqualStrings("ftyp", init_seg[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "moov") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "mvex") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "trak") != null);
}

test "buildFragmentHeader moof and mdat structure" {
    const allocator = std.testing.allocator;

    const mock_stsd = [_]u8{ 0, 0, 0, 16, 's', 't', 's', 'd', 0, 0, 0, 0, 0, 0, 0, 1 };
    const stsd_raw = try allocator.dupe(u8, &mock_stsd);

    const video_track = isobmff.Mp4MediaTrack{
        .track_id = 1,
        .stream_idx = 0,
        .handler_type = "vide".*,
        .timescale = 1000,
        .duration = 10000,
        .width = 640,
        .height = 360,
        .stsd_raw = stsd_raw,
        .samples = &.{},
        .sync_sample_indices = &.{},
    };
    var mut_video = video_track;
    defer mut_video.deinit(allocator);

    const video_samples = [_]isobmff.MediaSample{
        .{ .dts_delta = 33, .dts = 0, .pts = 0, .pts_sec = 0.0, .offset = 100, .size = 500, .is_sync = true },
        .{ .dts_delta = 33, .dts = 33, .pts = 33, .pts_sec = 0.033, .offset = 600, .size = 200, .is_sync = false },
    };

    const frag_hdr = try fmp4_muxer.buildFragmentHeader(
        allocator,
        1,
        mut_video,
        &video_samples,
        0,
        null,
        &.{},
        0,
        700,
        0,
    );
    defer allocator.free(frag_hdr);

    try std.testing.expect(frag_hdr.len > 8);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "moof") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "mfhd") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "traf") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "tfhd") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "tfdt") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "trun") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "mdat") != null);
}

test "trun box version 1 for negative CTTS offsets" {
    const allocator = std.testing.allocator;

    const mock_stsd = [_]u8{ 0, 0, 0, 16, 's', 't', 's', 'd', 0, 0, 0, 0, 0, 0, 0, 1 };
    const stsd_raw = try allocator.dupe(u8, &mock_stsd);

    const video_track = isobmff.Mp4MediaTrack{
        .track_id = 1,
        .stream_idx = 0,
        .handler_type = "vide".*,
        .timescale = 1000,
        .duration = 10000,
        .width = 640,
        .height = 360,
        .stsd_raw = stsd_raw,
        .samples = &.{},
        .sync_sample_indices = &.{},
    };
    var mut_video = video_track;
    defer mut_video.deinit(allocator);

    const video_samples = [_]isobmff.MediaSample{
        .{ .dts_delta = 33, .dts = 0, .pts = 0, .pts_sec = 0.0, .offset = 100, .size = 500, .is_sync = true, .ctts_offset = 0 },
        .{ .dts_delta = 33, .dts = 33, .pts = 100, .pts_sec = 0.1, .offset = 600, .size = 200, .is_sync = false, .ctts_offset = 67 },
        .{ .dts_delta = 33, .dts = 66, .pts = 33, .pts_sec = 0.033, .offset = 800, .size = 200, .is_sync = false, .ctts_offset = -33 },
    };

    const frag_hdr = try fmp4_muxer.buildFragmentHeader(
        allocator,
        1,
        mut_video,
        &video_samples,
        0,
        null,
        &.{},
        0,
        900,
        0,
    );
    defer allocator.free(frag_hdr);

    const trun_pos = std.mem.indexOf(u8, frag_hdr, "trun").?;
    const trun_box = frag_hdr[trun_pos - 4 ..];
    // trun box layout: [0..4] size, [4..8] "trun", [8] version
    const version = trun_box[8];
    try std.testing.expectEqual(@as(u8, 1), version);
}
