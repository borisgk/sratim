const std = @import("std");
const ebml = @import("../ebml.zig");
const types = @import("types.zig");
const languages = @import("../languages.zig");
const isobmff_stsd = @import("../isobmff/stsd.zig");

pub const MkvTrackInfo = types.MkvTrackInfo;
pub const MkvTrackType = types.MkvTrackType;

/// Parses all tracks from an MKV file, converting CodecPrivate into standard ISOBMFF stsd boxes.
pub fn parseMkvTracks(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8) ![]MkvTrackInfo {
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

    var tracks = std.ArrayList(MkvTrackInfo).empty;
    errdefer {
        for (tracks.items) |*t| t.deinit(allocator);
        tracks.deinit(allocator);
    }

    var stream_idx: usize = 0;

    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_TRACKS) {
            var tracks_rem = elem.size;
            while (tracks_rem > 0) {
                const trk_elem = (try ebml.readElementHeader(r)) orelse break;
                tracks_rem -= trk_elem.header_size;
                const trk_size = @min(trk_elem.size, tracks_rem);

                if (trk_elem.id == ebml.ID_TRACK_ENTRY) {
                    var trk_info = try parseTrackEntry(allocator, r, trk_size, stream_idx);
                    if (trk_info) |*ti| {
                        try tracks.append(allocator, ti.*);
                    }
                    stream_idx += 1;
                } else {
                    try ebml.skipBytes(r, trk_size);
                }
                if (trk_elem.size != ebml.UNKNOWN_SIZE) tracks_rem -= trk_size;
            }
            break; // Tracks element finished
        } else if (elem.id == ebml.ID_CLUSTER) {
            // Reached first cluster; stop scanning
            break;
        } else {
            if (elem.size == ebml.UNKNOWN_SIZE) break;
            try ebml.skipBytes(r, elem.size);
        }
    }

    return try tracks.toOwnedSlice(allocator);
}

fn parseTrackEntry(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    entry_size: u64,
    stream_idx: usize,
) !?MkvTrackInfo {
    var rem = entry_size;
    var track_num: u64 = 1;
    var track_type = MkvTrackType.Other;
    var codec_id_opt: ?[]const u8 = null;
    var codec_private_opt: ?[]u8 = null;
    var width: u32 = 0;
    var height: u32 = 0;
    var sample_rate: u32 = 48000;
    var channels: u16 = 2;
    var language: [4]u8 = "und\x00".*;

    errdefer {
        if (codec_id_opt) |cid| allocator.free(cid);
        if (codec_private_opt) |cp| allocator.free(cp);
    }

    while (rem > 0) {
        const sub = (try ebml.readElementHeader(r)) orelse break;
        rem -= sub.header_size;
        const sub_size = @min(sub.size, rem);

        if (sub.id == ebml.ID_TRACK_NUMBER) {
            track_num = try ebml.readUint(r, sub_size);
        } else if (sub.id == ebml.ID_TRACK_TYPE) {
            const tt_int = try ebml.readUint(r, sub_size);
            track_type = MkvTrackType.fromInt(tt_int);
        } else if (sub.id == ebml.ID_CODEC_ID) {
            const cid = try ebml.readString(allocator, r, sub_size);
            if (codec_id_opt) |old| allocator.free(old);
            codec_id_opt = cid;
        } else if (sub.id == ebml.ID_CODEC_PRIVATE) {
            const cp = try allocator.alloc(u8, @intCast(sub_size));
            try r.readSliceAll(cp);
            if (codec_private_opt) |old| allocator.free(old);
            codec_private_opt = cp;
        } else if (sub.id == ebml.ID_LANGUAGE) {
            const lang_str = try ebml.readString(allocator, r, sub_size);
            defer allocator.free(lang_str);
            if (lang_str.len >= 3) {
                @memcpy(language[0..3], lang_str[0..3]);
                language[3] = 0;
            }
        } else if (sub.id == ebml.ID_VIDEO) {
            var v_rem = sub_size;
            while (v_rem > 0) {
                const v_sub = (try ebml.readElementHeader(r)) orelse break;
                v_rem -= v_sub.header_size;
                const v_sub_size = @min(v_sub.size, v_rem);

                if (v_sub.id == ebml.ID_PIXEL_WIDTH) {
                    width = @intCast(try ebml.readUint(r, v_sub_size));
                } else if (v_sub.id == ebml.ID_PIXEL_HEIGHT) {
                    height = @intCast(try ebml.readUint(r, v_sub_size));
                } else {
                    try ebml.skipBytes(r, v_sub_size);
                }
                if (v_sub.size != ebml.UNKNOWN_SIZE) v_rem -= v_sub_size;
            }
        } else if (sub.id == ebml.ID_AUDIO) {
            var a_rem = sub_size;
            while (a_rem > 0) {
                const a_sub = (try ebml.readElementHeader(r)) orelse break;
                a_rem -= a_sub.header_size;
                const a_sub_size = @min(a_sub.size, a_rem);

                if (a_sub.id == ebml.ID_SAMPLING_FREQUENCY) {
                    const sf = try ebml.readFloat(r, a_sub_size);
                    sample_rate = @intFromFloat(sf);
                } else if (a_sub.id == ebml.ID_CHANNELS) {
                    channels = @intCast(try ebml.readUint(r, a_sub_size));
                } else {
                    try ebml.skipBytes(r, a_sub_size);
                }
                if (a_sub.size != ebml.UNKNOWN_SIZE) a_rem -= a_sub_size;
            }
        } else {
            try ebml.skipBytes(r, sub_size);
        }
        if (sub.size != ebml.UNKNOWN_SIZE) rem -= sub_size;
    }

    const codec_id = codec_id_opt orelse {
        if (codec_private_opt) |cp| allocator.free(cp);
        return null;
    };

    // Generate standard ISOBMFF stsd box from CodecPrivate
    var stsd_raw: ?[]u8 = null;
    errdefer if (stsd_raw) |s| allocator.free(s);

    if (track_type == .Video) {
        if (std.mem.eql(u8, codec_id, "V_MPEG4/ISO/AVC")) {
            if (codec_private_opt) |cp| {
                stsd_raw = try buildAvc1Stsd(allocator, cp, width, height);
            }
        } else if (std.mem.eql(u8, codec_id, "V_MPEGH/ISO/HEVC")) {
            if (codec_private_opt) |cp| {
                stsd_raw = try buildHevcStsd(allocator, cp, width, height);
            }
        } else if (std.mem.eql(u8, codec_id, "V_AV1")) {
            if (codec_private_opt) |cp| {
                stsd_raw = try buildAv1Stsd(allocator, cp, width, height);
            }
        }
    } else if (track_type == .Audio) {
        if (std.mem.eql(u8, codec_id, "A_AAC")) {
            if (codec_private_opt) |cp| {
                stsd_raw = try buildAacStsd(allocator, cp, channels, sample_rate);
            }
        }
    }

    return MkvTrackInfo{
        .track_num = track_num,
        .stream_idx = stream_idx,
        .track_type = track_type,
        .codec_id = codec_id,
        .codec_private = codec_private_opt,
        .width = width,
        .height = height,
        .sample_rate = sample_rate,
        .channels = channels,
        .language = language,
        .stsd_raw = stsd_raw,
    };
}

/// Returns true if the MKV video codec ID can be transmuxed into browser-compatible fMP4.
pub fn isSupportedVideoCodec(codec_id: []const u8) bool {
    const supported_codecs = .{ "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC", "V_AV1" };
    inline for (supported_codecs) |c| {
        if (std.mem.eql(u8, codec_id, c)) return true;
    }
    return false;
}

pub const buildAvc1Stsd = isobmff_stsd.buildAvc1Stsd;
pub const buildHevcStsd = isobmff_stsd.buildHevcStsd;
pub const buildAv1Stsd = isobmff_stsd.buildAv1Stsd;
pub const buildAacStsd = isobmff_stsd.buildAacStsd;
