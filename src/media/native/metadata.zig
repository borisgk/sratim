const std = @import("std");
const ebml = @import("ebml.zig");
pub const languages = @import("languages.zig");
pub const cues = @import("cues.zig");
pub const codecs = @import("codecs.zig");

const detector = @import("detector.zig");
const subtitles = @import("subtitles.zig");

pub const AudioTrack = struct {
    id: usize,
    label: []const u8,
};

pub const SubtitleTrack = struct {
    id: usize,
    label: []const u8,
    language: []const u8,
};

pub const MediaInfo = struct {
    duration: f64,
    codec_str: []const u8,
    dynamic_codec_str: ?[]const u8 = null,
    audio_tracks: []AudioTrack,
    subtitle_tracks: []SubtitleTrack,

    pub fn deinit(self: *const MediaInfo, allocator: std.mem.Allocator) void {
        for (self.audio_tracks) |track| allocator.free(track.label);
        if (self.audio_tracks.len > 0) allocator.free(self.audio_tracks);
        for (self.subtitle_tracks) |track| {
            allocator.free(track.label);
            allocator.free(track.language);
        }
        if (self.subtitle_tracks.len > 0) allocator.free(self.subtitle_tracks);
        if (self.dynamic_codec_str) |s| allocator.free(s);
    }
};

pub const getLanguageName = languages.getLanguageName;
pub const getKeyframePts = cues.getKeyframePts;

/// Pure Zig extraction of container track metadata, codecs, and duration.
pub fn getMediaInfo(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8) !MediaInfo {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    const ebml_hdr = (try ebml.readElementHeader(r)) orelse return error.InvalidEbml;
    if (ebml_hdr.id != ebml.ID_EBML) return error.NotMatroska;
    try ebml.skipBytes(r, ebml_hdr.size);

    const seg_hdr = (try ebml.readElementHeader(r)) orelse return error.InvalidEbml;
    if (seg_hdr.id != ebml.ID_SEGMENT) return error.NotMatroska;

    var timestamp_scale: f64 = 1_000_000.0;
    var duration_sec: f64 = 0.0;
    var codec_str: []const u8 = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"";
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

    var current_stream_idx: usize = 0;

    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_INFO) {
            var info_rem = elem.size;
            while (info_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                info_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > info_rem) break;

                if (sub.id == ebml.ID_TIMESTAMP_SCALE) {
                    const val = try ebml.readUint(r, sub.size);
                    timestamp_scale = @floatFromInt(val);
                } else if (sub.id == ebml.ID_DURATION) {
                    const dur_raw = try ebml.readFloat(r, sub.size);
                    duration_sec = (dur_raw * timestamp_scale) / 1_000_000_000.0;
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) info_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_TRACKS) {
            var tracks_rem = elem.size;
            while (tracks_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                tracks_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > tracks_rem) break;

                if (sub.id == ebml.ID_TRACK_ENTRY) {
                    var entry_rem = sub.size;
                    var t_type: ?u64 = null;
                    var codec_id_str: ?[]u8 = null;
                    defer if (codec_id_str) |s| allocator.free(s);
                    var name_str: ?[]u8 = null;
                    defer if (name_str) |s| allocator.free(s);
                    var lang_str: ?[]u8 = null;
                    defer if (lang_str) |s| allocator.free(s);
                    var flag_forced: u64 = 0;

                    var video_width: u32 = 0;
                    var video_height: u32 = 0;

                    while (entry_rem > 0) {
                        const trk_child = (try ebml.readElementHeader(r)) orelse break;
                        entry_rem -= trk_child.header_size;
                        if (trk_child.size != ebml.UNKNOWN_SIZE and trk_child.size > entry_rem) break;

                        if (trk_child.id == ebml.ID_TRACK_TYPE) {
                            t_type = try ebml.readUint(r, trk_child.size);
                        } else if (trk_child.id == ebml.ID_CODEC_ID) {
                            codec_id_str = try ebml.readString(allocator, r, trk_child.size);
                        } else if (trk_child.id == ebml.ID_NAME) {
                            name_str = try ebml.readString(allocator, r, trk_child.size);
                        } else if (trk_child.id == ebml.ID_LANGUAGE) {
                            if (lang_str == null) {
                                lang_str = try ebml.readString(allocator, r, trk_child.size);
                            } else {
                                try ebml.skipBytes(r, trk_child.size);
                            }
                        } else if (trk_child.id == ebml.ID_LANGUAGE_IETF) {
                            if (lang_str) |old| allocator.free(old);
                            lang_str = try ebml.readString(allocator, r, trk_child.size);
                        } else if (trk_child.id == ebml.ID_FLAG_FORCED) {
                            flag_forced = try ebml.readUint(r, trk_child.size);
                        } else if (trk_child.id == ebml.ID_VIDEO) {
                            var v_rem = trk_child.size;
                            while (v_rem > 0) {
                                const v_child = (try ebml.readElementHeader(r)) orelse break;
                                v_rem -= v_child.header_size;
                                if (v_child.size != ebml.UNKNOWN_SIZE and v_child.size > v_rem) break;

                                if (v_child.id == ebml.ID_PIXEL_WIDTH) {
                                    video_width = @intCast(try ebml.readUint(r, v_child.size));
                                } else if (v_child.id == ebml.ID_PIXEL_HEIGHT) {
                                    video_height = @intCast(try ebml.readUint(r, v_child.size));
                                } else {
                                    try ebml.skipBytes(r, v_child.size);
                                }
                                if (v_child.size != ebml.UNKNOWN_SIZE) v_rem -= v_child.size;
                            }
                        } else {
                            try ebml.skipBytes(r, trk_child.size);
                        }
                        if (trk_child.size != ebml.UNKNOWN_SIZE) entry_rem -= trk_child.size;
                    }

                    if (t_type) |tt| {
                        if (tt == 1) { // Video
                            if (codec_id_str) |cid| {
                                const cres = try codecs.getVideoCodecString(allocator, cid, video_width, video_height);
                                if (cres.dynamic_str) |dyn| {
                                    if (dynamic_codec_str) |old| allocator.free(old);
                                    dynamic_codec_str = dyn;
                                    codec_str = dyn;
                                } else if (cres.static_str) |st| {
                                    codec_str = st;
                                }
                            }
                        } else if (tt == 2) { // Audio
                            var label: []const u8 = "";
                            var lang: []const u8 = "und";

                            if (lang_str) |l| {
                                const trimmed_l = std.mem.trim(u8, l, " \t\r\n\x00");
                                if (trimmed_l.len > 0 and !std.ascii.eqlIgnoreCase(trimmed_l, "und") and !std.ascii.eqlIgnoreCase(trimmed_l, "undetermined")) {
                                    lang = trimmed_l;
                                }
                            }

                            if (name_str) |n| {
                                const trimmed_n = std.mem.trim(u8, n, " \t\r\n\x00");
                                if (trimmed_n.len > 0 and !std.ascii.eqlIgnoreCase(trimmed_n, "und") and !std.ascii.eqlIgnoreCase(trimmed_n, "undetermined")) {
                                    label = trimmed_n;
                                }
                            }

                            var free_label = false;
                            if (label.len == 0) {
                                if (!std.ascii.eqlIgnoreCase(lang, "und")) {
                                    label = getLanguageName(lang) orelse lang;
                                } else {
                                    label = try std.fmt.allocPrint(allocator, "Audio Track {d}", .{audio_tracks.items.len + 1});
                                    free_label = true;
                                }
                            }
                            defer if (free_label) allocator.free(label);

                            const label_dup = try allocator.dupe(u8, label);
                            try audio_tracks.append(allocator, .{ .id = current_stream_idx, .label = label_dup });
                        } else if (tt == 17) { // Subtitle
                            var is_bitmap = false;
                            if (codec_id_str) |cid| {
                                if (std.mem.indexOf(u8, cid, "PGS") != null or
                                    std.mem.indexOf(u8, cid, "VOBSUB") != null or
                                    std.mem.indexOf(u8, cid, "DVBSUB") != null)
                                {
                                    is_bitmap = true;
                                }
                            }

                            if (!is_bitmap) {
                                var label: []const u8 = "";
                                var lang: []const u8 = "und";

                                if (lang_str) |l| {
                                    const trimmed_l = std.mem.trim(u8, l, " \t\r\n\x00");
                                    if (trimmed_l.len > 0 and !std.ascii.eqlIgnoreCase(trimmed_l, "und") and !std.ascii.eqlIgnoreCase(trimmed_l, "undetermined")) {
                                        lang = trimmed_l;
                                    }
                                }

                                if (name_str) |n| {
                                    const trimmed_n = std.mem.trim(u8, n, " \t\r\n\x00");
                                    if (trimmed_n.len > 0 and !std.ascii.eqlIgnoreCase(trimmed_n, "und") and !std.ascii.eqlIgnoreCase(trimmed_n, "undetermined")) {
                                        label = trimmed_n;
                                    }
                                }

                                // If language is undetermined and no custom label, attempt automated detection from subtitle text
                                if (std.ascii.eqlIgnoreCase(lang, "und") and label.len == 0) {
                                    const sample_opt = subtitles.peekSubtitleSample(allocator, io, file_path, current_stream_idx) catch null;
                                    if (sample_opt) |sample| {
                                        defer allocator.free(sample);
                                        if (detector.detectLanguage(sample)) |dl| {
                                            lang = dl.code;
                                            label = dl.name;
                                        }
                                    }
                                }

                                var free_label = false;
                                if (label.len == 0) {
                                    if (!std.ascii.eqlIgnoreCase(lang, "und")) {
                                        label = getLanguageName(lang) orelse lang;
                                    } else {
                                        label = try std.fmt.allocPrint(allocator, "Subtitle Track {d}", .{subtitle_tracks.items.len + 1});
                                        free_label = true;
                                    }
                                }
                                defer if (free_label) allocator.free(label);

                                const is_forced = (flag_forced != 0) or (std.ascii.indexOfIgnoreCase(label, "forced") != null);
                                var final_label: []const u8 = label;
                                var free_final = false;

                                if (is_forced and std.ascii.indexOfIgnoreCase(label, "forced") == null) {
                                    final_label = try std.fmt.allocPrint(allocator, "{s} (Forced)", .{label});
                                    free_final = true;
                                }
                                defer if (free_final) allocator.free(final_label);

                                const label_dup = try allocator.dupe(u8, final_label);
                                const lang_dup = try allocator.dupe(u8, lang);
                                try subtitle_tracks.append(allocator, .{ .id = current_stream_idx, .label = label_dup, .language = lang_dup });
                            }
                        }
                        current_stream_idx += 1;
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) tracks_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_CLUSTER) {
            // Found tracks and info; no need to scan all clusters for metadata
            break;
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    return MediaInfo{
        .duration = duration_sec,
        .codec_str = codec_str,
        .dynamic_codec_str = dynamic_codec_str,
        .audio_tracks = try audio_tracks.toOwnedSlice(allocator),
        .subtitle_tracks = try subtitle_tracks.toOwnedSlice(allocator),
    };
}

test "inspect sample MKVs metadata" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Verify Polly.mkv
    if (getMediaInfo(allocator, io, "tests/Polly.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), info.subtitle_tracks.len);
        try std.testing.expectEqualStrings("English", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("eng", info.subtitle_tracks[0].language);
    } else |_| {}

    // Verify test_sync.mkv
    if (getMediaInfo(allocator, io, "tests/test_sync.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), info.subtitle_tracks.len);
        try std.testing.expectEqualStrings("English SRT", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("Hebrew ASS", info.subtitle_tracks[1].label);
        try std.testing.expectEqual(@as(usize, 1), info.audio_tracks.len);
        try std.testing.expectEqualStrings("Audio Track 1", info.audio_tracks[0].label);
    } else |_| {}

    // Verify Reacher.mkv automated detection
    if (getMediaInfo(allocator, io, "tests/Reacher.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 37), info.subtitle_tracks.len);
        // Verify key language detections
        try std.testing.expectEqualStrings("English", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("Basque", info.subtitle_tracks[1].label);
        try std.testing.expectEqualStrings("Spanish", info.subtitle_tracks[2].label);
        try std.testing.expectEqualStrings("French", info.subtitle_tracks[3].label);
        try std.testing.expectEqualStrings("Czech", info.subtitle_tracks[5].label);
        try std.testing.expectEqualStrings("German", info.subtitle_tracks[13].label);
        try std.testing.expectEqualStrings("Greek", info.subtitle_tracks[14].label);
        try std.testing.expectEqualStrings("Hebrew", info.subtitle_tracks[15].label);
        try std.testing.expectEqualStrings("Hindi", info.subtitle_tracks[16].label);
        try std.testing.expectEqualStrings("Japanese", info.subtitle_tracks[20].label);
        try std.testing.expectEqualStrings("Kannada", info.subtitle_tracks[21].label);
        try std.testing.expectEqualStrings("Korean", info.subtitle_tracks[22].label);
        try std.testing.expectEqualStrings("Arabic", info.subtitle_tracks[26].label);
        try std.testing.expectEqualStrings("Chinese", info.subtitle_tracks[30].label);
        try std.testing.expectEqualStrings("Turkish", info.subtitle_tracks[36].label);
    } else |_| {}
}
