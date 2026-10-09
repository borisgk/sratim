const std = @import("std");
const types = @import("types.zig");
const reader = @import("reader.zig");
const tracks = @import("tracks.zig");

const BoxHeader = types.BoxHeader;
const SttsEntry = types.SttsEntry;
const CttsEntry = types.CttsEntry;
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

/// Fast MP4 keyframe seeker that parses only the video track's sync sample (stss) and
/// time-to-sample (stts/ctts) tables, avoiding parsing and allocation of sample payloads,
/// audio tracks, subtitle tracks, and sample offsets.
pub fn findMp4KeyframePts(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    start_time: f64,
) !f64 {
    if (start_time <= 0.0) return 0.0;

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    while (true) {
        const box = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;

        if (isFourCC(box.type, "moov")) {
            var moov_rem = box.dataSize();
            while (moov_rem >= 8) {
                const moov_child = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;
                moov_rem -= moov_child.header_size;
                const child_data_size = @min(moov_child.dataSize(), moov_rem);

                if (isFourCC(moov_child.type, "trak")) {
                    const res = try parseVideoTrackKeyframes(allocator, r, moov_child, start_time);
                    if (res) |pts| {
                        return pts;
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

    return 0.0;
}

fn parseVideoTrackKeyframes(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    trak_box: BoxHeader,
    start_time: f64,
) !?f64 {
    var trak_rem = trak_box.dataSize();
    var timescale: u32 = 1000;
    var is_video = false;

    var stts_list = std.ArrayList(SttsEntry).empty;
    defer stts_list.deinit(allocator);

    var ctts_list = std.ArrayList(CttsEntry).empty;
    defer ctts_list.deinit(allocator);

    var stss_list = std.ArrayList(u32).empty;
    defer stss_list.deinit(allocator);
    var has_stss = false;

    while (trak_rem >= 8) {
        const child = (try readBoxHeader(r, 0)) orelse break;
        trak_rem -= child.header_size;
        const child_data_size = @min(child.dataSize(), trak_rem);

        if (isFourCC(child.type, "mdia")) {
            var mdia_rem = child_data_size;
            while (mdia_rem >= 8) {
                const mdia_child = (try readBoxHeader(r, 0)) orelse break;
                mdia_rem -= mdia_child.header_size;
                const m_data_size = @min(mdia_child.dataSize(), mdia_rem);

                if (isFourCC(mdia_child.type, "mdhd")) {
                    if (m_data_size >= 24) {
                        var mdhd_buf: [32]u8 = undefined;
                        const to_read: usize = @intCast(@min(m_data_size, mdhd_buf.len));
                        try r.readSliceAll(mdhd_buf[0..to_read]);
                        const version = mdhd_buf[0];
                        if (version == 0 and to_read >= 16) {
                            timescale = std.mem.readInt(u32, mdhd_buf[12..16], .big);
                        } else if (version == 1 and to_read >= 24) {
                            timescale = std.mem.readInt(u32, mdhd_buf[20..24], .big);
                        }
                        try skipBytes(r, m_data_size - to_read);
                    } else {
                        try skipBytes(r, m_data_size);
                    }
                } else if (isFourCC(mdia_child.type, "hdlr")) {
                    if (m_data_size >= 12) {
                        var hdlr_buf: [12]u8 = undefined;
                        try r.readSliceAll(&hdlr_buf);
                        if (isFourCC(hdlr_buf[8..12].*, "vide")) {
                            is_video = true;
                        }
                        try skipBytes(r, m_data_size - 12);
                    } else {
                        try skipBytes(r, m_data_size);
                    }
                } else if (isFourCC(mdia_child.type, "minf")) {
                    var minf_rem = m_data_size;
                    while (minf_rem >= 8) {
                        const minf_child = (try readBoxHeader(r, 0)) orelse break;
                        minf_rem -= minf_child.header_size;
                        const minf_data_size = @min(minf_child.dataSize(), minf_rem);

                        if (isFourCC(minf_child.type, "stbl")) {
                            var stbl_rem = minf_data_size;
                            while (stbl_rem >= 8) {
                                const stbl_child = (try readBoxHeader(r, 0)) orelse break;
                                stbl_rem -= stbl_child.header_size;
                                const stbl_data_size = @min(stbl_child.dataSize(), stbl_rem);

                                if (isFourCC(stbl_child.type, "stts")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 8) break;
                                            var row: [8]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const count = std.mem.readInt(u32, row[0..4], .big);
                                            const delta = std.mem.readInt(u32, row[4..8], .big);
                                            try stts_list.append(allocator, SttsEntry{ .count = count, .delta = delta });
                                            rem_bytes -= 8;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "ctts")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 8) break;
                                            var row: [8]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const count = std.mem.readInt(u32, row[0..4], .big);
                                            const offset_raw = std.mem.readInt(u32, row[4..8], .big);
                                            const offset_signed: i32 = @bitCast(offset_raw);
                                            try ctts_list.append(allocator, CttsEntry{ .count = count, .offset = offset_signed });
                                            rem_bytes -= 8;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "stss")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;
                                        has_stss = true;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 4) break;
                                            var row: [4]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const sync_1based = std.mem.readInt(u32, &row, .big);
                                            try stss_list.append(allocator, sync_1based);
                                            rem_bytes -= 4;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else {
                                    try skipBytes(r, stbl_data_size);
                                }
                                stbl_rem -= stbl_data_size;
                            }
                        } else {
                            try skipBytes(r, minf_data_size);
                        }
                        minf_rem -= minf_data_size;
                    }
                } else {
                    try skipBytes(r, m_data_size);
                }
                mdia_rem -= m_data_size;
            }
        } else {
            try skipBytes(r, child_data_size);
        }
        trak_rem -= child_data_size;
    }

    if (!is_video or timescale == 0 or stts_list.items.len == 0) {
        return null;
    }

    return calculateKeyframePts(timescale, stts_list.items, ctts_list.items, stss_list.items, has_stss, start_time);
}

fn calculateKeyframePts(
    timescale: u32,
    stts: []const SttsEntry,
    ctts: []const CttsEntry,
    stss: []const u32,
    has_stss: bool,
    start_time: f64,
) f64 {
    const ts_f = @as(f64, @floatFromInt(timescale));

    if (has_stss) {
        if (stss.len == 0) return 0.0;

        var stts_idx: usize = 0;
        var stts_sample: u32 = 1;
        var current_dts: u64 = 0;
        var stts_rem_in_entry: u32 = stts[0].count;

        var ctts_idx: usize = 0;
        var ctts_sample: u32 = 1;
        var ctts_rem_in_entry: u32 = if (ctts.len > 0) ctts[0].count else 0;

        var best_pts: f64 = 0.0;

        for (stss) |sync_1based| {
            if (sync_1based < stts_sample) continue;

            var advance_stts = sync_1based - stts_sample;
            while (advance_stts > 0 and stts_idx < stts.len) {
                if (advance_stts < stts_rem_in_entry) {
                    current_dts += @as(u64, advance_stts) * stts[stts_idx].delta;
                    stts_rem_in_entry -= advance_stts;
                    stts_sample = sync_1based;
                    advance_stts = 0;
                    break;
                } else {
                    current_dts += @as(u64, stts_rem_in_entry) * stts[stts_idx].delta;
                    stts_sample += stts_rem_in_entry;
                    advance_stts -= stts_rem_in_entry;
                    stts_idx += 1;
                    if (stts_idx < stts.len) {
                        stts_rem_in_entry = stts[stts_idx].count;
                    } else {
                        stts_rem_in_entry = 0;
                    }
                }
            }

            var pts_val: u64 = current_dts;
            if (ctts.len > 0 and ctts_idx < ctts.len) {
                var advance_ctts = if (sync_1based >= ctts_sample) sync_1based - ctts_sample else 0;
                while (advance_ctts > 0 and ctts_idx < ctts.len) {
                    if (advance_ctts < ctts_rem_in_entry) {
                        ctts_rem_in_entry -= advance_ctts;
                        ctts_sample = sync_1based;
                        advance_ctts = 0;
                        break;
                    } else {
                        ctts_sample += ctts_rem_in_entry;
                        advance_ctts -= ctts_rem_in_entry;
                        ctts_idx += 1;
                        if (ctts_idx < ctts.len) {
                            ctts_rem_in_entry = ctts[ctts_idx].count;
                        } else {
                            ctts_rem_in_entry = 0;
                        }
                    }
                }
                if (ctts_idx < ctts.len) {
                    const ctts_offset = ctts[ctts_idx].offset;
                    const pts_calc = @as(i64, @intCast(current_dts)) + @as(i64, ctts_offset);
                    pts_val = if (pts_calc >= 0) @intCast(pts_calc) else 0;
                }
            }

            const pts_sec = @as(f64, @floatFromInt(pts_val)) / ts_f;
            if (pts_sec <= start_time) {
                best_pts = pts_sec;
            } else {
                break;
            }
        }

        return best_pts;
    } else {
        var current_dts: u64 = 0;
        var best_pts: f64 = 0.0;
        var ctts_idx: usize = 0;
        var ctts_rem: u32 = if (ctts.len > 0) ctts[0].count else 0;

        for (stts) |entry| {
            for (0..entry.count) |_| {
                var pts_val: u64 = current_dts;
                if (ctts.len > 0 and ctts_idx < ctts.len) {
                    const pts_calc = @as(i64, @intCast(current_dts)) + @as(i64, ctts[ctts_idx].offset);
                    pts_val = if (pts_calc >= 0) @intCast(pts_calc) else 0;
                    ctts_rem -= 1;
                    if (ctts_rem == 0) {
                        ctts_idx += 1;
                        if (ctts_idx < ctts.len) ctts_rem = ctts[ctts_idx].count;
                    }
                }
                const pts_sec = @as(f64, @floatFromInt(pts_val)) / ts_f;
                if (pts_sec <= start_time) {
                    best_pts = pts_sec;
                } else {
                    return best_pts;
                }
                current_dts += entry.delta;
            }
        }
        return best_pts;
    }
}
