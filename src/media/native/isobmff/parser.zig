const std = @import("std");
const types = @import("types.zig");
const reader = @import("reader.zig");
const tracks = @import("tracks.zig");

const Mp4SubtitleTrack = types.Mp4SubtitleTrack;
const Mp4SubtitleTrackInfo = types.Mp4SubtitleTrackInfo;
const Mp4MediaTrack = types.Mp4MediaTrack;
const Mp4Media = types.Mp4Media;

const readBoxHeader = reader.readBoxHeader;
const skipBytes = reader.skipBytes;
const isFourCC = reader.isFourCC;
const isSubtitleHandler = reader.isSubtitleHandler;
const parseSubtitleTrackBox = tracks.parseSubtitleTrackBox;
const parseGenericTrackBox = tracks.parseGenericTrackBox;

/// Parses an entire MP4 file to locate and extract sample metadata for a specific subtitle stream index.
pub fn parseMp4SubtitleTrack(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    target_stream_idx: usize,
) !?Mp4SubtitleTrack {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    var current_stream_idx: usize = 0;

    while (true) {
        const box = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;

        if (isFourCC(box.type, "moov")) {
            var moov_rem = box.dataSize();
            while (moov_rem >= 8) {
                const moov_child = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;
                moov_rem -= moov_child.header_size;
                const child_data_size = @min(moov_child.dataSize(), moov_rem);

                if (isFourCC(moov_child.type, "trak")) {
                    const track_stream_idx = current_stream_idx;
                    current_stream_idx += 1;

                    if (track_stream_idx == target_stream_idx) {
                        const trk_opt = try parseSubtitleTrackBox(allocator, r, moov_child, track_stream_idx);
                        if (trk_opt) |trk| {
                            return trk;
                        }
                    } else {
                        try skipBytes(r, child_data_size);
                    }
                } else {
                    try skipBytes(r, child_data_size);
                }
                moov_rem -= child_data_size;
            }
            break;
        } else {
            if (box.dataSize() == std.math.maxInt(u64)) break;
            try skipBytes(r, box.dataSize());
        }
    }

    return null;
}

/// Parses an entire MP4 file to load video, audio, and subtitle media tracks with indexing and sample tables.
pub fn parseMp4Media(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
) !Mp4Media {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    var current_stream_idx: usize = 0;
    var media_timescale: u32 = 1000;
    var video_track: ?Mp4MediaTrack = null;
    var audio_tracks = std.ArrayList(Mp4MediaTrack).empty;
    var subtitle_tracks = std.ArrayList(Mp4SubtitleTrackInfo).empty;
    errdefer {
        if (video_track) |*vt| vt.deinit(allocator);
        for (audio_tracks.items) |*at| at.deinit(allocator);
        audio_tracks.deinit(allocator);
        subtitle_tracks.deinit(allocator);
    }

    while (true) {
        const box = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;

        if (isFourCC(box.type, "moov")) {
            var moov_rem = box.dataSize();
            while (moov_rem >= 8) {
                const moov_child = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;
                moov_rem -= moov_child.header_size;
                const child_data_size = @min(moov_child.dataSize(), moov_rem);

                if (isFourCC(moov_child.type, "mvhd")) {
                    if (child_data_size >= 16) {
                        var mvhd_buf: [32]u8 = undefined;
                        const to_read = @min(child_data_size, mvhd_buf.len);
                        try r.readSliceAll(mvhd_buf[0..to_read]);
                        const version = mvhd_buf[0];
                        if (version == 0 and to_read >= 16) {
                            media_timescale = std.mem.readInt(u32, mvhd_buf[12..16], .big);
                        } else if (version == 1 and to_read >= 24) {
                            media_timescale = std.mem.readInt(u32, mvhd_buf[20..24], .big);
                        }
                        try skipBytes(r, child_data_size - to_read);
                    } else {
                        try skipBytes(r, child_data_size);
                    }
                } else if (isFourCC(moov_child.type, "trak")) {
                    const track_stream_idx = current_stream_idx;
                    current_stream_idx += 1;

                    const track_opt = try parseGenericTrackBox(allocator, r, moov_child, track_stream_idx);
                    if (track_opt) |trk| {
                        if (isFourCC(trk.handler_type, "vide") and video_track == null) {
                            video_track = trk;
                        } else if (isFourCC(trk.handler_type, "soun")) {
                            try audio_tracks.append(allocator, trk);
                        } else if (isSubtitleHandler(trk.handler_type)) {
                            try subtitle_tracks.append(allocator, .{
                                .stream_idx = trk.stream_idx,
                                .track_id = trk.track_id,
                                .language = trk.language,
                            });
                            var mutable_trk = trk;
                            mutable_trk.deinit(allocator);
                        } else {
                            var mutable_trk = trk;
                            mutable_trk.deinit(allocator);
                        }
                    }
                } else {
                    try skipBytes(r, child_data_size);
                }
                moov_rem -= child_data_size;
            }
            break;
        } else {
            if (box.dataSize() == std.math.maxInt(u64)) break;
            try skipBytes(r, box.dataSize());
        }
    }

    return Mp4Media{
        .timescale = media_timescale,
        .video_track = video_track,
        .audio_tracks = try audio_tracks.toOwnedSlice(allocator),
        .subtitle_tracks = try subtitle_tracks.toOwnedSlice(allocator),
    };
}
