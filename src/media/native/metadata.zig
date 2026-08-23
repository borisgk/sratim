const std = @import("std");
const ebml = @import("ebml.zig");

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

/// Pure Zig keyframe PTS finder for Matroska files.
/// Inspects Cues (or Cluster headers) to find the nearest previous keyframe timestamp in seconds.
pub fn getKeyframePts(io: std.Io, file_path: []const u8, start_time: f64) !f64 {
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

    const segment_data_pos = file_reader.logicalPos();
    var timestamp_scale: f64 = 1_000_000.0;
    var cues_pos: ?u64 = null;

    var best_cluster_time: ?f64 = null;

    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_SEEK_HEAD) {
            var seek_head_rem = elem.size;
            while (seek_head_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                seek_head_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > seek_head_rem) break;

                if (sub.id == ebml.ID_SEEK) {
                    var seek_rem = sub.size;
                    var seek_id: ?u32 = null;
                    var seek_pos: ?u64 = null;

                    while (seek_rem > 0) {
                        const child = (try ebml.readElementHeader(r)) orelse break;
                        seek_rem -= child.header_size;
                        if (child.size != ebml.UNKNOWN_SIZE and child.size > seek_rem) break;

                        if (child.id == ebml.ID_SEEK_ID) {
                            seek_id = @intCast(try ebml.readUint(r, child.size));
                        } else if (child.id == ebml.ID_SEEK_POSITION) {
                            seek_pos = try ebml.readUint(r, child.size);
                        } else {
                            try ebml.skipBytes(r, child.size);
                        }
                        if (child.size != ebml.UNKNOWN_SIZE) seek_rem -= child.size;
                    }

                    if (seek_id == ebml.ID_CUES and seek_pos != null) {
                        cues_pos = segment_data_pos + seek_pos.?;
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) seek_head_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_INFO) {
            var info_rem = elem.size;
            while (info_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                info_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > info_rem) break;

                if (sub.id == ebml.ID_TIMESTAMP_SCALE) {
                    const val = try ebml.readUint(r, sub.size);
                    timestamp_scale = @floatFromInt(val);
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) info_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_CUES) {
            return parseCues(r, elem, timestamp_scale, start_time);
        } else if (elem.id == ebml.ID_CLUSTER) {
            // If we encounter a cluster and haven't jumped to Cues yet
            if (cues_pos) |pos| {
                file_reader.seekTo(pos) catch {};
                const cue_elem = (try ebml.readElementHeader(r)) orelse return start_time;
                if (cue_elem.id == ebml.ID_CUES) {
                    return parseCues(r, cue_elem, timestamp_scale, start_time);
                }
            }

            // Fallback: scan cluster timestamps
            var cluster_elem: ?ebml.ElementHeader = elem;
            while (cluster_elem) |ce| {
                var cl_rem = ce.size;
                while (cl_rem > 0) {
                    const sub = (try ebml.readElementHeader(r)) orelse break;
                    cl_rem -= sub.header_size;
                    if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cl_rem) break;

                    if (sub.id == ebml.ID_CLUSTER_TIMESTAMP) {
                        const cl_ts = try ebml.readUint(r, sub.size);
                        const ts_sec = (@as(f64, @floatFromInt(cl_ts)) * timestamp_scale) / 1_000_000_000.0;
                        if (ts_sec <= start_time) {
                            best_cluster_time = ts_sec;
                        } else {
                            return best_cluster_time orelse start_time;
                        }
                        cl_rem -= sub.size;
                        break;
                    } else {
                        try ebml.skipBytes(r, sub.size);
                        cl_rem -= sub.size;
                    }
                }

                if (ce.size != ebml.UNKNOWN_SIZE) {
                    try ebml.skipBytes(r, cl_rem);
                }

                // Read next cluster
                cluster_elem = null;
                while (true) {
                    const next = (try ebml.readElementHeader(r)) orelse break;
                    if (next.id == ebml.ID_CLUSTER) {
                        cluster_elem = next;
                        break;
                    } else if (next.size != ebml.UNKNOWN_SIZE) {
                        try ebml.skipBytes(r, next.size);
                    }
                }
            }
            return best_cluster_time orelse start_time;
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    if (cues_pos) |pos| {
        file_reader.seekTo(pos) catch {};
        const cue_elem = (try ebml.readElementHeader(r)) orelse return start_time;
        if (cue_elem.id == ebml.ID_CUES) {
            return parseCues(r, cue_elem, timestamp_scale, start_time);
        }
    }

    return start_time;
}

fn parseCues(r: *std.Io.Reader, cues_elem: ebml.ElementHeader, timestamp_scale: f64, start_time: f64) !f64 {
    var cues_rem = cues_elem.size;
    var best_ts_sec: f64 = 0.0;

    while (cues_rem > 0) {
        const sub = (try ebml.readElementHeader(r)) orelse break;
        cues_rem -= sub.header_size;
        if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cues_rem) break;

        if (sub.id == ebml.ID_CUE_POINT) {
            var cp_rem = sub.size;
            var cue_time_raw: ?u64 = null;

            while (cp_rem > 0) {
                const cp_child = (try ebml.readElementHeader(r)) orelse break;
                cp_rem -= cp_child.header_size;
                if (cp_child.size != ebml.UNKNOWN_SIZE and cp_child.size > cp_rem) break;

                if (cp_child.id == ebml.ID_CUE_TIME) {
                    cue_time_raw = try ebml.readUint(r, cp_child.size);
                } else {
                    try ebml.skipBytes(r, cp_child.size);
                }
                if (cp_child.size != ebml.UNKNOWN_SIZE) cp_rem -= cp_child.size;
            }

            if (cue_time_raw) |raw| {
                const ts_sec = (@as(f64, @floatFromInt(raw)) * timestamp_scale) / 1_000_000_000.0;
                if (ts_sec <= start_time) {
                    best_ts_sec = ts_sec;
                } else {
                    return best_ts_sec;
                }
            }
        } else {
            try ebml.skipBytes(r, sub.size);
        }
        if (sub.size != ebml.UNKNOWN_SIZE) cues_rem -= sub.size;
    }

    return best_ts_sec;
}

pub fn getLanguageName(code: []const u8) ?[]const u8 {
    var clean_code = code;
    // Check for common regional language codes first
    if (std.ascii.eqlIgnoreCase(clean_code, "zh-hans") or std.ascii.eqlIgnoreCase(clean_code, "zh-cn")) return "Chinese (Simplified)";
    if (std.ascii.eqlIgnoreCase(clean_code, "zh-hant") or std.ascii.eqlIgnoreCase(clean_code, "zh-tw") or std.ascii.eqlIgnoreCase(clean_code, "zh-hk")) return "Chinese (Traditional)";
    if (std.ascii.eqlIgnoreCase(clean_code, "pt-br")) return "Portuguese (Brazil)";
    if (std.ascii.eqlIgnoreCase(clean_code, "es-419")) return "Spanish (Latin America)";

    // Strip subtags like "-US", "_US", "-GB", etc. for base lookup
    if (std.mem.indexOfAny(u8, clean_code, "-_")) |dash_idx| {
        clean_code = clean_code[0..dash_idx];
    }

    const MapEntry = struct { code: []const u8, name: []const u8 };
    const lang_map = [_]MapEntry{
        .{ .code = "eng", .name = "English" },
        .{ .code = "en", .name = "English" },
        .{ .code = "heb", .name = "Hebrew" },
        .{ .code = "he", .name = "Hebrew" },
        .{ .code = "iw", .name = "Hebrew" },
        .{ .code = "spa", .name = "Spanish" },
        .{ .code = "es", .name = "Spanish" },
        .{ .code = "fra", .name = "French" },
        .{ .code = "fre", .name = "French" },
        .{ .code = "fr", .name = "French" },
        .{ .code = "deu", .name = "German" },
        .{ .code = "ger", .name = "German" },
        .{ .code = "de", .name = "German" },
        .{ .code = "ita", .name = "Italian" },
        .{ .code = "it", .name = "Italian" },
        .{ .code = "rus", .name = "Russian" },
        .{ .code = "ru", .name = "Russian" },
        .{ .code = "por", .name = "Portuguese" },
        .{ .code = "pt", .name = "Portuguese" },
        .{ .code = "ara", .name = "Arabic" },
        .{ .code = "ar", .name = "Arabic" },
        .{ .code = "zho", .name = "Chinese" },
        .{ .code = "chi", .name = "Chinese" },
        .{ .code = "zh", .name = "Chinese" },
        .{ .code = "jpn", .name = "Japanese" },
        .{ .code = "ja", .name = "Japanese" },
        .{ .code = "kor", .name = "Korean" },
        .{ .code = "ko", .name = "Korean" },
        .{ .code = "hin", .name = "Hindi" },
        .{ .code = "hi", .name = "Hindi" },
        .{ .code = "tur", .name = "Turkish" },
        .{ .code = "tr", .name = "Turkish" },
        .{ .code = "pol", .name = "Polish" },
        .{ .code = "pl", .name = "Polish" },
        .{ .code = "ukr", .name = "Ukrainian" },
        .{ .code = "uk", .name = "Ukrainian" },
        .{ .code = "nld", .name = "Dutch" },
        .{ .code = "dut", .name = "Dutch" },
        .{ .code = "nl", .name = "Dutch" },
        .{ .code = "swe", .name = "Swedish" },
        .{ .code = "sv", .name = "Swedish" },
        .{ .code = "nor", .name = "Norwegian" },
        .{ .code = "nob", .name = "Norwegian" },
        .{ .code = "nno", .name = "Norwegian" },
        .{ .code = "no", .name = "Norwegian" },
        .{ .code = "dan", .name = "Danish" },
        .{ .code = "da", .name = "Danish" },
        .{ .code = "fin", .name = "Finnish" },
        .{ .code = "fi", .name = "Finnish" },
        .{ .code = "ell", .name = "Greek" },
        .{ .code = "gre", .name = "Greek" },
        .{ .code = "el", .name = "Greek" },
        .{ .code = "ces", .name = "Czech" },
        .{ .code = "cze", .name = "Czech" },
        .{ .code = "cs", .name = "Czech" },
        .{ .code = "hun", .name = "Hungarian" },
        .{ .code = "hu", .name = "Hungarian" },
        .{ .code = "ron", .name = "Romanian" },
        .{ .code = "rum", .name = "Romanian" },
        .{ .code = "ro", .name = "Romanian" },
        .{ .code = "bul", .name = "Bulgarian" },
        .{ .code = "bg", .name = "Bulgarian" },
        .{ .code = "hrv", .name = "Croatian" },
        .{ .code = "hr", .name = "Croatian" },
        .{ .code = "srp", .name = "Serbian" },
        .{ .code = "sr", .name = "Serbian" },
        .{ .code = "slv", .name = "Slovenian" },
        .{ .code = "sl", .name = "Slovenian" },
        .{ .code = "slk", .name = "Slovak" },
        .{ .code = "slo", .name = "Slovak" },
        .{ .code = "sk", .name = "Slovak" },
        .{ .code = "lit", .name = "Lithuanian" },
        .{ .code = "lt", .name = "Lithuanian" },
        .{ .code = "lav", .name = "Latvian" },
        .{ .code = "lv", .name = "Latvian" },
        .{ .code = "est", .name = "Estonian" },
        .{ .code = "et", .name = "Estonian" },
        .{ .code = "cat", .name = "Catalan" },
        .{ .code = "ca", .name = "Catalan" },
        .{ .code = "vie", .name = "Vietnamese" },
        .{ .code = "vi", .name = "Vietnamese" },
        .{ .code = "tha", .name = "Thai" },
        .{ .code = "th", .name = "Thai" },
        .{ .code = "ind", .name = "Indonesian" },
        .{ .code = "id", .name = "Indonesian" },
        .{ .code = "msa", .name = "Malay" },
        .{ .code = "may", .name = "Malay" },
        .{ .code = "ms", .name = "Malay" },
        .{ .code = "fil", .name = "Tagalog" },
        .{ .code = "tgl", .name = "Tagalog" },
        .{ .code = "tl", .name = "Tagalog" },
        .{ .code = "fas", .name = "Persian" },
        .{ .code = "per", .name = "Persian" },
        .{ .code = "fa", .name = "Persian" },
        .{ .code = "urd", .name = "Urdu" },
        .{ .code = "ur", .name = "Urdu" },
        .{ .code = "ben", .name = "Bengali" },
        .{ .code = "bn", .name = "Bengali" },
        .{ .code = "tam", .name = "Tamil" },
        .{ .code = "ta", .name = "Tamil" },
        .{ .code = "tel", .name = "Telugu" },
        .{ .code = "te", .name = "Telugu" },
        .{ .code = "kan", .name = "Kannada" },
        .{ .code = "kn", .name = "Kannada" },
        .{ .code = "mal", .name = "Malayalam" },
        .{ .code = "ml", .name = "Malayalam" },
        .{ .code = "mar", .name = "Marathi" },
        .{ .code = "mr", .name = "Marathi" },
        .{ .code = "pan", .name = "Punjabi" },
        .{ .code = "pa", .name = "Punjabi" },
        .{ .code = "guj", .name = "Gujarati" },
        .{ .code = "gu", .name = "Gujarati" },
        .{ .code = "kat", .name = "Georgian" },
        .{ .code = "geo", .name = "Georgian" },
        .{ .code = "ka", .name = "Georgian" },
        .{ .code = "hye", .name = "Armenian" },
        .{ .code = "arm", .name = "Armenian" },
        .{ .code = "hy", .name = "Armenian" },
        .{ .code = "aze", .name = "Azerbaijani" },
        .{ .code = "az", .name = "Azerbaijani" },
        .{ .code = "kaz", .name = "Kazakh" },
        .{ .code = "kk", .name = "Kazakh" },
        .{ .code = "uzb", .name = "Uzbek" },
        .{ .code = "uz", .name = "Uzbek" },
        .{ .code = "mon", .name = "Mongolian" },
        .{ .code = "mn", .name = "Mongolian" },
        .{ .code = "lat", .name = "Latin" },
        .{ .code = "la", .name = "Latin" },
        .{ .code = "isl", .name = "Icelandic" },
        .{ .code = "ice", .name = "Icelandic" },
        .{ .code = "is", .name = "Icelandic" },
        .{ .code = "gle", .name = "Irish" },
        .{ .code = "ga", .name = "Irish" },
        .{ .code = "cym", .name = "Welsh" },
        .{ .code = "wel", .name = "Welsh" },
        .{ .code = "cy", .name = "Welsh" },
        .{ .code = "eus", .name = "Basque" },
        .{ .code = "baq", .name = "Basque" },
        .{ .code = "eu", .name = "Basque" },
        .{ .code = "alb", .name = "Albanian" },
        .{ .code = "sqi", .name = "Albanian" },
        .{ .code = "sq", .name = "Albanian" },
        .{ .code = "mkd", .name = "Macedonian" },
        .{ .code = "mac", .name = "Macedonian" },
        .{ .code = "mk", .name = "Macedonian" },
        .{ .code = "bos", .name = "Bosnian" },
        .{ .code = "bs", .name = "Bosnian" },
        .{ .code = "bel", .name = "Belarusian" },
        .{ .code = "be", .name = "Belarusian" },
        .{ .code = "yid", .name = "Yiddish" },
        .{ .code = "yi", .name = "Yiddish" },
        .{ .code = "epo", .name = "Esperanto" },
        .{ .code = "eo", .name = "Esperanto" },
    };

    for (lang_map) |entry| {
        if (std.ascii.eqlIgnoreCase(clean_code, entry.code)) {
            return entry.name;
        }
    }
    return null;
}

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
                                if (std.mem.eql(u8, cid, "V_MPEG4/ISO/AVC")) {
                                    codec_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"";
                                } else if (std.mem.eql(u8, cid, "V_MPEGH/ISO/HEVC")) {
                                    const luma = video_width * video_height;
                                    const min_level: u32 = if (luma > 8_912_896) 156
                                        else if (luma > 2_228_224) 150
                                        else if (luma > 983_040) 120
                                        else 93;
                                    if (dynamic_codec_str) |old| allocator.free(old);
                                    dynamic_codec_str = try std.fmt.allocPrint(allocator,
                                        "video/mp4; codecs=\"hev1.2.4.L{d}.B0, mp4a.40.2\"",
                                        .{min_level});
                                    codec_str = dynamic_codec_str.?;
                                } else if (std.mem.eql(u8, cid, "V_AV1")) {
                                    codec_str = "video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"";
                                } else if (std.mem.eql(u8, cid, "V_VP9")) {
                                    codec_str = "video/mp4; codecs=\"vp09.00.10.08, mp4a.40.2\"";
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

                            if (label.len == 0) {
                                if (!std.ascii.eqlIgnoreCase(lang, "und")) {
                                    label = getLanguageName(lang) orelse lang;
                                } else {
                                    label = "Audio Track";
                                }
                            }

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

                                if (label.len == 0) {
                                    if (!std.ascii.eqlIgnoreCase(lang, "und")) {
                                        label = getLanguageName(lang) orelse lang;
                                    } else {
                                        label = "Subtitle Track";
                                    }
                                }

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

test "parseCues binary parsing" {
    // Construct mock Cues buffer:
    // Cues (ID 0x1C53BB6B):
    //   CuePoint (ID 0xBB, size 4):
    //     CueTime (ID 0xB3, size 2, value 5000) -> 5.0s
    //   CuePoint (ID 0xBB, size 4):
    //     CueTime (ID 0xB3, size 2, value 15000) -> 15.0s
    const raw_cues = [_]u8{
        0xBB, 0x84, 0xB3, 0x82, 0x13, 0x88, // CuePoint 1: CueTime = 0x1388 (5000 ms = 5.0s)
        0xBB, 0x84, 0xB3, 0x82, 0x3A, 0x98, // CuePoint 2: CueTime = 0x3A98 (15000 ms = 15.0s)
    };
    var r: std.Io.Reader = .fixed(&raw_cues);
    const cues_elem = ebml.ElementHeader{
        .id = ebml.ID_CUES,
        .size = raw_cues.len,
        .header_size = 0,
    };

    // When seeking to 10.0s, the nearest previous keyframe is 5.0s
    const pts = try parseCues(&r, cues_elem, 1_000_000.0, 10.0);
    try std.testing.expectEqual(@as(f64, 5.0), pts);
}

test "getLanguageName mapping" {
    try std.testing.expectEqualStrings("English", getLanguageName("eng").?);
    try std.testing.expectEqualStrings("English", getLanguageName("en").?);
    try std.testing.expectEqualStrings("English", getLanguageName("en-US").?);
    try std.testing.expectEqualStrings("Hebrew", getLanguageName("heb").?);
    try std.testing.expectEqualStrings("Hebrew", getLanguageName("he").?);
    try std.testing.expectEqualStrings("Spanish", getLanguageName("spa").?);
    try std.testing.expectEqualStrings("Russian", getLanguageName("rus").?);
    try std.testing.expectEqualStrings("Chinese (Simplified)", getLanguageName("zh-CN").?);
    try std.testing.expect(getLanguageName("und") == null);
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
        try std.testing.expectEqualStrings("Subtitle Track", info.subtitle_tracks[1].label);
        try std.testing.expectEqualStrings("und", info.subtitle_tracks[1].language);
    } else |_| {}

    // Verify test_sync.mkv
    if (getMediaInfo(allocator, io, "tests/test_sync.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), info.subtitle_tracks.len);
        try std.testing.expectEqualStrings("English SRT", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("Hebrew ASS", info.subtitle_tracks[1].label);
        try std.testing.expectEqual(@as(usize, 1), info.audio_tracks.len);
        try std.testing.expectEqualStrings("Audio Track", info.audio_tracks[0].label);
    } else |_| {}
}


