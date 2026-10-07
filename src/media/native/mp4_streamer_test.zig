const std = @import("std");
const isobmff = @import("isobmff.zig");
const fmp4_muxer = @import("fmp4_muxer.zig");

test "parseMp4Media and fMP4 init segment on test_subs.mp4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const f = std.Io.Dir.cwd().openFile(io, "tests/test_subs.mp4", .{ .mode = .read_only }) catch return;
    f.close(io);

    var media = try isobmff.parseMp4Media(allocator, io, "tests/test_subs.mp4");
    defer media.deinit(allocator);

    try std.testing.expect(media.video_track != null);
    const vt = media.video_track.?;
    try std.testing.expect(vt.samples.len > 0);
    try std.testing.expect(vt.width > 0);
    try std.testing.expect(vt.height > 0);
    try std.testing.expect(vt.stsd_raw.len > 0);

    try std.testing.expect(media.audio_tracks.len > 0);
    const at = media.audio_tracks[0];
    try std.testing.expect(at.samples.len > 0);
    try std.testing.expect(at.stsd_raw.len > 0);

    // Test building init segment
    const init_seg = try fmp4_muxer.buildInitSegment(allocator, vt, at);
    defer allocator.free(init_seg);

    try std.testing.expect(std.mem.startsWith(u8, init_seg[4..8], "ftyp"));
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "moov") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "mvex") != null);
}
