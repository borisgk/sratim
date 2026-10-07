const std = @import("std");
const types = @import("types.zig");
const isobmff = @import("../isobmff.zig");

const MkvBlock = types.MkvBlock;
const MediaSample = isobmff.MediaSample;

/// Resolves decode timestamps (DTS), presentation timestamps (PTS), and B-frame CTTS offsets for a GOP of video blocks.
pub fn buildGopMediaSamples(
    allocator: std.mem.Allocator,
    video_blocks: []const MkvBlock,
    timescale: u32,
    default_frame_duration_ts: u32,
) ![]MediaSample {
    if (video_blocks.len == 0) return &[_]MediaSample{};

    const samples = try allocator.alloc(MediaSample, video_blocks.len);
    errdefer allocator.free(samples);

    // 1. Extract PTS for each block in timescale
    const pts_list = try allocator.alloc(u64, video_blocks.len);
    defer allocator.free(pts_list);

    for (video_blocks, 0..) |b, i| {
        const pts_ts: u64 = (b.pts_ms * timescale) / 1000;
        pts_list[i] = pts_ts;
    }

    // 2. Sort PTS list to derive monotonic DTS sequence
    const sorted_pts = try allocator.alloc(u64, video_blocks.len);
    defer allocator.free(sorted_pts);
    @memcpy(sorted_pts, pts_list);
    std.mem.sort(u64, sorted_pts, {}, std.sort.asc(u64));

    // 3. Construct MediaSample entries
    const ts_f = @as(f64, @floatFromInt(timescale));

    for (video_blocks, 0..) |b, i| {
        const dts = sorted_pts[i];
        const pts = pts_list[i];
        const ctts: i32 = if (pts >= dts)
            @intCast(pts - dts)
        else
            -@as(i32, @intCast(dts - pts));

        const next_dts = if (i + 1 < video_blocks.len) sorted_pts[i + 1] else dts + default_frame_duration_ts;
        const dts_delta: u32 = if (next_dts >= dts) @intCast(next_dts - dts) else default_frame_duration_ts;

        samples[i] = MediaSample{
            .dts_delta = if (dts_delta > 0) dts_delta else default_frame_duration_ts,
            .dts = dts,
            .pts = pts,
            .pts_sec = @as(f64, @floatFromInt(pts)) / ts_f,
            .offset = b.payload_offset,
            .size = b.payload_size,
            .is_sync = b.is_keyframe,
            .ctts_offset = ctts,
        };
    }

    return samples;
}
