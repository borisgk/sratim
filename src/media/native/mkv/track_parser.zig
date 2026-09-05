const std = @import("std");
const ebml = @import("../ebml.zig");
const types = @import("types.zig");
const languages = @import("../languages.zig");

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

/// Builds standard ISOBMFF stsd box containing avc1 and avcC records.
pub fn buildAvc1Stsd(
    allocator: std.mem.Allocator,
    avcC_payload: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    return buildVisualStsd(allocator, "avc1", "avcC", avcC_payload, width, height);
}

/// Builds standard ISOBMFF stsd box containing hev1 and hvcC records.
pub fn buildHevcStsd(
    allocator: std.mem.Allocator,
    hvcC_payload: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    return buildVisualStsd(allocator, "hev1", "hvcC", hvcC_payload, width, height);
}

fn buildVisualStsd(
    allocator: std.mem.Allocator,
    sample_entry_fourcc: *const [4]u8,
    config_fourcc: *const [4]u8,
    config_payload: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    // 1. Build config box (avcC / hvcC)
    const config_box_size: u32 = @intCast(8 + config_payload.len);
    var config_box = try allocator.alloc(u8, config_box_size);
    defer allocator.free(config_box);
    std.mem.writeInt(u32, config_box[0..4], config_box_size, .big);
    @memcpy(config_box[4..8], config_fourcc);
    @memcpy(config_box[8..], config_payload);

    // 2. Build sample entry box (avc1 / hev1) (86 bytes header + config box)
    const entry_size: u32 = @intCast(86 + config_box.len);
    var entry_box = try allocator.alloc(u8, entry_size);
    defer allocator.free(entry_box);
    @memset(entry_box, 0);

    std.mem.writeInt(u32, entry_box[0..4], entry_size, .big);
    @memcpy(entry_box[4..8], sample_entry_fourcc);
    std.mem.writeInt(u16, entry_box[14..16], 1, .big); // data_reference_index = 1
    std.mem.writeInt(u16, entry_box[32..34], @intCast(width), .big);
    std.mem.writeInt(u16, entry_box[34..36], @intCast(height), .big);
    std.mem.writeInt(u32, entry_box[36..40], 0x00480000, .big); // 72 dpi horiz
    std.mem.writeInt(u32, entry_box[40..44], 0x00480000, .big); // 72 dpi vert
    std.mem.writeInt(u16, entry_box[48..50], 1, .big); // frame_count = 1
    std.mem.writeInt(u16, entry_box[82..84], 0x0018, .big); // depth = 24
    std.mem.writeInt(i16, entry_box[84..86], -1, .big); // pre_defined = -1
    @memcpy(entry_box[86..], config_box);

    // 3. Build stsd box (16 bytes header + entry box)
    const stsd_size: u32 = @intCast(16 + entry_box.len);
    var stsd_box = try allocator.alloc(u8, stsd_size);
    std.mem.writeInt(u32, stsd_box[0..4], stsd_size, .big);
    @memcpy(stsd_box[4..8], "stsd");
    std.mem.writeInt(u32, stsd_box[8..12], 0, .big); // version = 0, flags = 0
    std.mem.writeInt(u32, stsd_box[12..16], 1, .big); // entry_count = 1
    @memcpy(stsd_box[16..], entry_box);

    return stsd_box;
}

/// Builds standard ISOBMFF stsd box containing mp4a and esds records from AAC AudioSpecificConfig.
pub fn buildAacStsd(
    allocator: std.mem.Allocator,
    audio_specific_config: []const u8,
    channels: u16,
    sample_rate: u32,
) ![]u8 {
    // 1. Build ESDS box
    const asc_len: u8 = @intCast(audio_specific_config.len);
    const tag4_payload_len: u8 = 13 + 2 + asc_len; // 15 + asc_len
    const tag3_payload_len: u8 = 3 + (2 + tag4_payload_len) + 3; // 23 + asc_len
    const esds_payload_len: u32 = 4 + 2 + tag3_payload_len; // 29 + asc_len
    const esds_size: u32 = 8 + esds_payload_len;

    var esds_buf = std.ArrayList(u8).empty;
    defer esds_buf.deinit(allocator);

    var esds_hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, esds_hdr[0..4], esds_size, .big);
    @memcpy(esds_hdr[4..8], "esds");
    try esds_buf.appendSlice(allocator, &esds_hdr);

    const version_flags: [4]u8 = [_]u8{ 0, 0, 0, 0 };
    try esds_buf.appendSlice(allocator, &version_flags);

    // Tag 0x03 (ES_DescrTag)
    try esds_buf.appendSlice(allocator, &[_]u8{ 0x03, tag3_payload_len, 0x00, 0x01, 0x00 });

    // Tag 0x04 (DecoderConfigDescrTag)
    try esds_buf.appendSlice(allocator, &[_]u8{
        0x04, tag4_payload_len,
        0x40, // objectTypeIndication = Audio ISO/IEC 14496-3
        0x15, // streamType = AudioStream
        0x00, 0x18, 0x00, // bufferSizeDB = 6144
        0x00, 0x00, 0x00, 0x00, // maxBitrate
        0x00, 0x00, 0x00, 0x00, // avgBitrate
    });

    // Tag 0x05 (DecSpecificInfoTag)
    try esds_buf.appendSlice(allocator, &[_]u8{ 0x05, asc_len });
    try esds_buf.appendSlice(allocator, audio_specific_config);

    // Tag 0x06 (SLConfigDescrTag)
    try esds_buf.appendSlice(allocator, &[_]u8{ 0x06, 0x01, 0x02 });

    // 2. Build mp4a AudioSampleEntry (36 bytes header + esds box)
    const mp4a_size: u32 = @intCast(36 + esds_buf.items.len);
    var mp4a_buf = std.ArrayList(u8).empty;
    defer mp4a_buf.deinit(allocator);

    var mp4a_hdr: [36]u8 = [_]u8{0} ** 36;
    std.mem.writeInt(u32, mp4a_hdr[0..4], mp4a_size, .big);
    @memcpy(mp4a_hdr[4..8], "mp4a");
    std.mem.writeInt(u16, mp4a_hdr[14..16], 1, .big); // data_reference_index = 1
    std.mem.writeInt(u16, mp4a_hdr[24..26], channels, .big);
    std.mem.writeInt(u16, mp4a_hdr[26..28], 16, .big); // 16-bit
    std.mem.writeInt(u32, mp4a_hdr[32..36], sample_rate << 16, .big); // 16.16 sample rate

    try mp4a_buf.appendSlice(allocator, &mp4a_hdr);
    try mp4a_buf.appendSlice(allocator, esds_buf.items);

    // 3. Build stsd box
    const stsd_size: u32 = @intCast(16 + mp4a_buf.items.len);
    var stsd_box = try allocator.alloc(u8, stsd_size);
    std.mem.writeInt(u32, stsd_box[0..4], stsd_size, .big);
    @memcpy(stsd_box[4..8], "stsd");
    std.mem.writeInt(u32, stsd_box[8..12], 0, .big);
    std.mem.writeInt(u32, stsd_box[12..16], 1, .big);
    @memcpy(stsd_box[16..], mp4a_buf.items);

    return stsd_box;
}

test "buildAvc1Stsd and buildAacStsd structure" {
    const allocator = std.testing.allocator;

    const mock_avcC = [_]u8{ 0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x04, 0x27, 0x64, 0x00, 0x1F, 0x01, 0x00, 0x04, 0x28, 0xEE, 0x38, 0x80 };
    const avc_stsd = try buildAvc1Stsd(allocator, &mock_avcC, 1920, 1080);
    defer allocator.free(avc_stsd);

    try std.testing.expect(avc_stsd.len > 86);
    try std.testing.expectEqualStrings("stsd", avc_stsd[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, avc_stsd, "avc1") != null);
    try std.testing.expect(std.mem.indexOf(u8, avc_stsd, "avcC") != null);

    const mock_asc = [_]u8{ 0x12, 0x10 }; // AAC-LC, 44.1kHz, stereo
    const aac_stsd = try buildAacStsd(allocator, &mock_asc, 2, 44100);
    defer allocator.free(aac_stsd);

    try std.testing.expect(aac_stsd.len > 36);
    try std.testing.expectEqualStrings("stsd", aac_stsd[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, aac_stsd, "mp4a") != null);
    try std.testing.expect(std.mem.indexOf(u8, aac_stsd, "esds") != null);
}
