const std = @import("std");
const c = @import("../core/c.zig").c;
const native_metadata = @import("native/metadata.zig");

pub const SubtitleTrack = native_metadata.SubtitleTrack;
pub const AudioTrack = native_metadata.AudioTrack;
pub const MediaInfo = native_metadata.MediaInfo;

/// Extracts duration, codec strings, audio and subtitle tracks using FFmpeg/libavformat.
pub fn getMediaInfoFfmpeg(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8) !MediaInfo {
    _ = io;
    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&fmt_ctx), file_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&fmt_ctx));

    if (c.avformat_find_stream_info(fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    const duration = @as(f64, @floatFromInt(fmt_ctx.?.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
    var codec_str: []const u8 = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\""; // Default
    var dynamic_codec_str: ?[]const u8 = null;

    var audio_tracks: std.ArrayList(AudioTrack) = .empty;
    var subtitle_tracks: std.ArrayList(SubtitleTrack) = .empty;
    errdefer {
        for (audio_tracks.items) |track| allocator.free(track.label);
        audio_tracks.deinit(allocator);
        for (subtitle_tracks.items) |track| {
            allocator.free(track.label);
            allocator.free(track.language);
        }
        subtitle_tracks.deinit(allocator);
        if (dynamic_codec_str) |s| allocator.free(s);
    }

    for (0..fmt_ctx.?.nb_streams) |i| {
        const stream = fmt_ctx.?.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            // Skip attached pictures (cover art) — only use the real video stream
            if (stream.*.disposition & c.AV_DISPOSITION_ATTACHED_PIC != 0) continue;

            const codec_id = stream.*.codecpar.*.codec_id;
            if (codec_id == c.AV_CODEC_ID_H264) {
                codec_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"";
            } else if (codec_id == c.AV_CODEC_ID_HEVC) {
                // Build dynamic codec string from actual profile and level
                const profile = stream.*.codecpar.*.profile;
                const reported_level = stream.*.codecpar.*.level;
                const width: u32 = @intCast(stream.*.codecpar.*.width);
                const height: u32 = @intCast(stream.*.codecpar.*.height);

                const profile_idc: u32 = if (profile >= 1 and profile <= 3) @intCast(profile) else 2;
                const compat: u32 = switch (profile_idc) {
                    1 => 6, // Main: compatible with Main
                    2 => 4, // Main 10: compatible with Main 10
                    3 => 1, // Main Still Picture
                    else => 4,
                };

                const luma_samples = width * height;
                const min_level: u32 = if (luma_samples > 8_912_896) 156
                    else if (luma_samples > 2_228_224) 150
                    else if (luma_samples > 983_040) 120
                    else 93;

                const rl: u32 = if (reported_level > 0) @intCast(reported_level) else 0;
                const level_idc: u32 = @max(rl, min_level);

                var constraint_hex: u8 = 0xB0;
                if (stream.*.codecpar.*.extradata_size >= 7 and stream.*.codecpar.*.extradata != null) {
                    const ed = stream.*.codecpar.*.extradata;
                    if (ed[0] == 1) {
                        constraint_hex = ed[6];
                    }
                }

                dynamic_codec_str = try std.fmt.allocPrint(allocator,
                    "video/mp4; codecs=\"hev1.{d}.{d}.L{d}.{X:0>2}, mp4a.40.2\"",
                    .{ profile_idc, compat, level_idc, constraint_hex });
                codec_str = dynamic_codec_str.?;
            } else if (codec_id == c.AV_CODEC_ID_AV1) {
                codec_str = "video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"";
            } else if (codec_id == c.AV_CODEC_ID_VP9) {
                codec_str = "video/mp4; codecs=\"vp09.00.10.08, mp4a.40.2\"";
            }
        } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            var label: []const u8 = "Unknown";

            const title_entry = c.av_dict_get(stream.*.metadata, "title", null, 0);
            const lang_entry = c.av_dict_get(stream.*.metadata, "language", null, 0);

            if (title_entry != null) {
                label = std.mem.span(title_entry.*.value);
            } else if (lang_entry != null) {
                label = std.mem.span(lang_entry.*.value);
            }

            const label_dup = try allocator.dupe(u8, label);
            try audio_tracks.append(allocator, .{ .id = i, .label = label_dup });
        } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            const codec_id = stream.*.codecpar.*.codec_id;
            if (codec_id == c.AV_CODEC_ID_HDMV_PGS_SUBTITLE or
                codec_id == c.AV_CODEC_ID_DVD_SUBTITLE or
                codec_id == c.AV_CODEC_ID_DVB_SUBTITLE or
                codec_id == c.AV_CODEC_ID_XSUB) {
                continue; // Ignore bitmap subtitle formats
            }

            var label: []const u8 = "";
            var lang: []const u8 = "";

            const title_entry = c.av_dict_get(stream.*.metadata, "title", null, 0);
            const lang_entry = c.av_dict_get(stream.*.metadata, "language", null, 0);

            if (title_entry != null) {
                label = std.mem.span(title_entry.*.value);
            }
            if (lang_entry != null) {
                lang = std.mem.span(lang_entry.*.value);
                if (label.len == 0) label = lang;
            }
            if (label.len == 0) {
                label = "Subtitle Track";
            }

            const is_forced = (stream.*.disposition & c.AV_DISPOSITION_FORCED) != 0 or
                (std.ascii.indexOfIgnoreCase(label, "forced") != null);

            var final_label: []const u8 = label;
            var free_final = false;

            if (is_forced and std.ascii.indexOfIgnoreCase(label, "forced") == null) {
                final_label = try std.fmt.allocPrint(allocator, "{s} (Forced)", .{label});
                free_final = true;
            }
            defer if (free_final) allocator.free(final_label);

            const label_dup = try allocator.dupe(u8, final_label);
            const lang_dup = try allocator.dupe(u8, lang);
            try subtitle_tracks.append(allocator, .{ .id = i, .label = label_dup, .language = lang_dup });
        }
    }

    return MediaInfo{
        .duration = duration,
        .codec_str = codec_str,
        .dynamic_codec_str = dynamic_codec_str,
        .audio_tracks = try audio_tracks.toOwnedSlice(allocator),
        .subtitle_tracks = try subtitle_tracks.toOwnedSlice(allocator),
    };
}
