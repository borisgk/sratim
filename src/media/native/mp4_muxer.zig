const std = @import("std");

pub const VideoCodecType = enum {
    h264,
    hevc,
    av1,
    vp9,
};

pub const VideoTrackConfig = struct {
    width: u32,
    height: u32,
    codec: VideoCodecType,
    codec_private: ?[]const u8 = null,
    timescale: u32 = 90000,
};

pub const AudioTrackConfig = struct {
    sample_rate: u32 = 48000,
    channels: u16 = 2,
    codec_private: ?[]const u8 = null, // AudioSpecificConfig for AAC
    timescale: u32 = 48000,
};

pub const SampleInfo = struct {
    duration: u32,
    size: u32,
    is_keyframe: bool = false,
    composition_time_offset: i32 = 0,
};

/// Helper to build and nest ISO BMFF boxes.
pub const BoxBuilder = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BoxBuilder {
        return .{
            .buf = std.ArrayList(u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BoxBuilder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn startBox(self: *BoxBuilder, fourcc: *const [4]u8) !usize {
        const pos = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 }); // Placeholder for 32-bit size
        try self.buf.appendSlice(self.allocator, fourcc);
        return pos;
    }

    pub fn endBox(self: *BoxBuilder, start_pos: usize) !void {
        const box_size: u32 = @intCast(self.buf.items.len - start_pos);
        std.mem.writeInt(u32, self.buf.items[start_pos..][0..4], box_size, .big);
    }

    pub fn writeU8(self: *BoxBuilder, val: u8) !void {
        try self.buf.append(self.allocator, val);
    }

    pub fn writeU16(self: *BoxBuilder, val: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, val, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeI16(self: *BoxBuilder, val: i16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, val, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU24(self: *BoxBuilder, val: u24) !void {
        var b: [3]u8 = undefined;
        b[0] = @intCast((val >> 16) & 0xFF);
        b[1] = @intCast((val >> 8) & 0xFF);
        b[2] = @intCast(val & 0xFF);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU32(self: *BoxBuilder, val: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, val, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeI32(self: *BoxBuilder, val: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, val, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU64(self: *BoxBuilder, val: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, val, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeBytes(self: *BoxBuilder, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn writeFullBoxHeader(self: *BoxBuilder, fourcc: *const [4]u8, version: u8, flags: u24) !usize {
        const start = try self.startBox(fourcc);
        try self.writeU8(version);
        try self.writeU24(flags);
        return start;
    }
};

/// Writes the ISO Base Media File Format `ftyp` (File Type) box.
pub fn writeFtyp(builder: *BoxBuilder) !void {
    const start = try builder.startBox("ftyp");
    try builder.writeBytes("isom"); // Major brand
    try builder.writeU32(512); // Minor version
    // Compatible brands
    try builder.writeBytes("isomiso6mp41mp42");
    try builder.endBox(start);
}

/// Writes the `moov` (Movie) metadata box for fragmented MP4 streaming.
pub fn writeMoov(
    builder: *BoxBuilder,
    video: VideoTrackConfig,
    audio: ?AudioTrackConfig,
) !void {
    const moov_start = try builder.startBox("moov");

    // 1. mvhd (Movie Header)
    {
        const mvhd_start = try builder.writeFullBoxHeader("mvhd", 0, 0);
        try builder.writeU32(0); // creation_time
        try builder.writeU32(0); // modification_time
        try builder.writeU32(90000); // timescale
        try builder.writeU32(0); // duration (0 for fragmented streaming)
        try builder.writeU32(0x00010000); // rate = 1.0 (16.16 fixed point)
        try builder.writeU16(0x0100); // volume = 1.0 (8.8 fixed point)
        try builder.writeU16(0); // reserved
        try builder.writeU32(0); // reserved
        try builder.writeU32(0); // reserved
        // Identity unity matrix
        const unity_matrix = [_]u32{
            0x00010000, 0,          0,
            0,          0x00010000, 0,
            0,          0,          0x40000000,
        };
        for (unity_matrix) |m| try builder.writeU32(m);
        // Pre-defined (24 bytes of zeros)
        for (0..6) |_| try builder.writeU32(0);
        try builder.writeU32(if (audio != null) 3 else 2); // next_track_ID
        try builder.endBox(mvhd_start);
    }

    // 2. Video trak (Track ID = 1)
    {
        const trak_start = try builder.startBox("trak");

        // tkhd
        const tkhd_start = try builder.writeFullBoxHeader("tkhd", 0, 0x000003); // Track enabled + in movie
        try builder.writeU32(0); // creation_time
        try builder.writeU32(0); // modification_time
        try builder.writeU32(1); // track_ID = 1
        try builder.writeU32(0); // reserved
        try builder.writeU32(0); // duration = 0
        try builder.writeU32(0); // reserved
        try builder.writeU32(0); // reserved
        try builder.writeI16(0); // layer
        try builder.writeI16(0); // alternate_group
        try builder.writeI16(0); // volume (0 for video)
        try builder.writeU16(0); // reserved
        // Matrix
        const unity_matrix = [_]u32{
            0x00010000, 0,          0,
            0,          0x00010000, 0,
            0,          0,          0x40000000,
        };
        for (unity_matrix) |m| try builder.writeU32(m);
        try builder.writeU32(video.width << 16); // width (16.16 fixed point)
        try builder.writeU32(video.height << 16); // height (16.16 fixed point)
        try builder.endBox(tkhd_start);

        // mdia
        const mdia_start = try builder.startBox("mdia");

        // mdhd
        const mdhd_start = try builder.writeFullBoxHeader("mdhd", 0, 0);
        try builder.writeU32(0); // creation_time
        try builder.writeU32(0); // modification_time
        try builder.writeU32(video.timescale); // timescale (e.g. 90000)
        try builder.writeU32(0); // duration
        try builder.writeU16(0x55C4); // language = 'und' (undetermined)
        try builder.writeU16(0); // pre-defined
        try builder.endBox(mdhd_start);

        // hdlr (Handler)
        const hdlr_start = try builder.writeFullBoxHeader("hdlr", 0, 0);
        try builder.writeU32(0); // pre-defined
        try builder.writeBytes("vide"); // handler_type
        for (0..3) |_| try builder.writeU32(0); // reserved
        try builder.writeBytes("VideoHandler\x00");
        try builder.endBox(hdlr_start);

        // minf (Media Information)
        const minf_start = try builder.startBox("minf");

        // vmhd (Video Media Header)
        const vmhd_start = try builder.writeFullBoxHeader("vmhd", 0, 0x000001);
        try builder.writeU16(0); // graphicsmode = copy
        for (0..3) |_| try builder.writeU16(0); // opcolor
        try builder.endBox(vmhd_start);

        // dinf -> dref -> url
        const dinf_start = try builder.startBox("dinf");
        const dref_start = try builder.writeFullBoxHeader("dref", 0, 0);
        try builder.writeU32(1); // entry_count
        const url_start = try builder.writeFullBoxHeader("url ", 0, 0x000001); // self-contained flag
        try builder.endBox(url_start);
        try builder.endBox(dref_start);
        try builder.endBox(dinf_start);

        // stbl (Sample Table)
        const stbl_start = try builder.startBox("stbl");

        // stsd (Sample Description Table)
        const stsd_start = try builder.writeFullBoxHeader("stsd", 0, 0);
        try builder.writeU32(1); // entry_count

        switch (video.codec) {
            .h264 => {
                const avc1_start = try builder.startBox("avc1");
                for (0..6) |_| try builder.writeU8(0); // reserved
                try builder.writeU16(1); // data_reference_index
                try builder.writeU16(0); // pre-defined
                try builder.writeU16(0); // reserved
                for (0..3) |_| try builder.writeU32(0); // pre-defined
                try builder.writeU16(@intCast(video.width));
                try builder.writeU16(@intCast(video.height));
                try builder.writeU32(0x00480000); // 72 dpi horiz
                try builder.writeU32(0x00480000); // 72 dpi vert
                try builder.writeU32(0); // reserved
                try builder.writeU16(1); // frame_count = 1
                for (0..32) |_| try builder.writeU8(0); // compressorname (32 bytes)
                try builder.writeU16(0x0018); // depth = 24
                try builder.writeI16(-1); // pre-defined

                // avcC box
                if (video.codec_private) |cp| {
                    const avcc_start = try builder.startBox("avcC");
                    try builder.writeBytes(cp);
                    try builder.endBox(avcc_start);
                }
                try builder.endBox(avc1_start);
            },
            .hevc => {
                const hev1_start = try builder.startBox("hev1");
                for (0..6) |_| try builder.writeU8(0);
                try builder.writeU16(1);
                try builder.writeU16(0);
                try builder.writeU16(0);
                for (0..3) |_| try builder.writeU32(0);
                try builder.writeU16(@intCast(video.width));
                try builder.writeU16(@intCast(video.height));
                try builder.writeU32(0x00480000);
                try builder.writeU32(0x00480000);
                try builder.writeU32(0);
                try builder.writeU16(1);
                for (0..32) |_| try builder.writeU8(0);
                try builder.writeU16(0x0018);
                try builder.writeI16(-1);

                // hvcC box
                if (video.codec_private) |cp| {
                    const hvcc_start = try builder.startBox("hvcC");
                    try builder.writeBytes(cp);
                    try builder.endBox(hvcc_start);
                }
                try builder.endBox(hev1_start);
            },
            .av1 => {
                const av01_start = try builder.startBox("av01");
                for (0..6) |_| try builder.writeU8(0);
                try builder.writeU16(1);
                for (0..4) |_| try builder.writeU32(0);
                try builder.writeU16(@intCast(video.width));
                try builder.writeU16(@intCast(video.height));
                try builder.writeU32(0x00480000);
                try builder.writeU32(0x00480000);
                try builder.writeU32(0);
                try builder.writeU16(1);
                for (0..32) |_| try builder.writeU8(0);
                try builder.writeU16(0x0018);
                try builder.writeI16(-1);
                if (video.codec_private) |cp| {
                    const av1c_start = try builder.startBox("av1C");
                    try builder.writeBytes(cp);
                    try builder.endBox(av1c_start);
                }
                try builder.endBox(av01_start);
            },
            .vp9 => {
                const vp09_start = try builder.startBox("vp09");
                for (0..6) |_| try builder.writeU8(0);
                try builder.writeU16(1);
                for (0..4) |_| try builder.writeU32(0);
                try builder.writeU16(@intCast(video.width));
                try builder.writeU16(@intCast(video.height));
                try builder.writeU32(0x00480000);
                try builder.writeU32(0x00480000);
                try builder.writeU32(0);
                try builder.writeU16(1);
                for (0..32) |_| try builder.writeU8(0);
                try builder.writeU16(0x0018);
                try builder.writeI16(-1);
                if (video.codec_private) |cp| {
                    const vpcc_start = try builder.startBox("vpcC");
                    try builder.writeBytes(cp);
                    try builder.endBox(vpcc_start);
                }
                try builder.endBox(vp09_start);
            },
        }

        try builder.endBox(stsd_start);

        // Empty stts, stsc, stsz, stco for fragmented MP4
        const stts_start = try builder.writeFullBoxHeader("stts", 0, 0);
        try builder.writeU32(0);
        try builder.endBox(stts_start);

        const stsc_start = try builder.writeFullBoxHeader("stsc", 0, 0);
        try builder.writeU32(0);
        try builder.endBox(stsc_start);

        const stsz_start = try builder.writeFullBoxHeader("stsz", 0, 0);
        try builder.writeU32(0); // sample_size
        try builder.writeU32(0); // sample_count
        try builder.endBox(stsz_start);

        const stco_start = try builder.writeFullBoxHeader("stco", 0, 0);
        try builder.writeU32(0);
        try builder.endBox(stco_start);

        try builder.endBox(stbl_start);
        try builder.endBox(minf_start);
        try builder.endBox(mdia_start);
        try builder.endBox(trak_start);
    }

    // 3. Audio trak (Track ID = 2, optional)
    if (audio) |aud| {
        const trak_start = try builder.startBox("trak");

        // tkhd
        const tkhd_start = try builder.writeFullBoxHeader("tkhd", 0, 0x000003);
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.writeU32(2); // track_ID = 2
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.writeI16(0);
        try builder.writeI16(0);
        try builder.writeI16(0x0100); // volume = 1.0 (8.8)
        try builder.writeU16(0);
        const unity_matrix = [_]u32{
            0x00010000, 0,          0,
            0,          0x00010000, 0,
            0,          0,          0x40000000,
        };
        for (unity_matrix) |m| try builder.writeU32(m);
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.endBox(tkhd_start);

        // mdia
        const mdia_start = try builder.startBox("mdia");
        const mdhd_start = try builder.writeFullBoxHeader("mdhd", 0, 0);
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.writeU32(aud.timescale);
        try builder.writeU32(0);
        try builder.writeU16(0x55C4);
        try builder.writeU16(0);
        try builder.endBox(mdhd_start);

        const hdlr_start = try builder.writeFullBoxHeader("hdlr", 0, 0);
        try builder.writeU32(0);
        try builder.writeBytes("soun");
        for (0..3) |_| try builder.writeU32(0);
        try builder.writeBytes("AudioHandler\x00");
        try builder.endBox(hdlr_start);

        const minf_start = try builder.startBox("minf");
        const smhd_start = try builder.writeFullBoxHeader("smhd", 0, 0);
        try builder.writeI16(0); // balance
        try builder.writeU16(0); // reserved
        try builder.endBox(smhd_start);

        const dinf_start = try builder.startBox("dinf");
        const dref_start = try builder.writeFullBoxHeader("dref", 0, 0);
        try builder.writeU32(1);
        const url_start = try builder.writeFullBoxHeader("url ", 0, 0x000001);
        try builder.endBox(url_start);
        try builder.endBox(dref_start);
        try builder.endBox(dinf_start);

        const stbl_start = try builder.startBox("stbl");
        const stsd_start = try builder.writeFullBoxHeader("stsd", 0, 0);
        try builder.writeU32(1);

        const mp4a_start = try builder.startBox("mp4a");
        for (0..6) |_| try builder.writeU8(0);
        try builder.writeU16(1); // data_reference_index
        for (0..2) |_| try builder.writeU32(0); // reserved
        try builder.writeU16(aud.channels);
        try builder.writeU16(16); // sample_size
        try builder.writeU16(0); // pre-defined
        try builder.writeU16(0); // reserved
        try builder.writeU32(aud.sample_rate << 16); // sample_rate (16.16)

        // esds box for AAC
        if (aud.codec_private) |asc| {
            const esds_start = try builder.writeFullBoxHeader("esds", 0, 0);
            // ES_Descriptor (tag 0x03)
            try builder.writeU8(0x03);
            try builder.writeU8(@intCast(20 + asc.len)); // length
            try builder.writeU16(1); // ES_ID
            try builder.writeU8(0); // flags

            // DecoderConfigDescriptor (tag 0x04)
            try builder.writeU8(0x04);
            try builder.writeU8(@intCast(15 + asc.len)); // length
            try builder.writeU8(0x40); // objectTypeIndication (0x40 = AAC)
            try builder.writeU8(0x15); // streamType (AudioStream = 5 << 2 | 1)
            try builder.writeU24(0); // bufferSizeDB
            try builder.writeU32(192000); // maxBitrate
            try builder.writeU32(192000); // avgBitrate

            // DecSpecificInfo (tag 0x05)
            try builder.writeU8(0x05);
            try builder.writeU8(@intCast(asc.len));
            try builder.writeBytes(asc);

            // SLConfigDescriptor (tag 0x06)
            try builder.writeBytes(&[_]u8{ 0x06, 0x01, 0x02 });

            try builder.endBox(esds_start);
        }

        try builder.endBox(mp4a_start);
        try builder.endBox(stsd_start);

        const stts_start = try builder.writeFullBoxHeader("stts", 0, 0);
        try builder.writeU32(0);
        try builder.endBox(stts_start);

        const stsc_start = try builder.writeFullBoxHeader("stsc", 0, 0);
        try builder.writeU32(0);
        try builder.endBox(stsc_start);

        const stsz_start = try builder.writeFullBoxHeader("stsz", 0, 0);
        try builder.writeU32(0);
        try builder.writeU32(0);
        try builder.endBox(stsz_start);

        const stco_start = try builder.writeFullBoxHeader("stco", 0, 0);
        try builder.writeU32(0);
        try builder.endBox(stco_start);

        try builder.endBox(stbl_start);
        try builder.endBox(minf_start);
        try builder.endBox(mdia_start);
        try builder.endBox(trak_start);
    }

    // 4. mvex (Movie Extends Box)
    {
        const mvex_start = try builder.startBox("mvex");

        // trex for video (track 1)
        const trex_v_start = try builder.writeFullBoxHeader("trex", 0, 0);
        try builder.writeU32(1); // track_ID = 1
        try builder.writeU32(1); // default_sample_description_index = 1
        try builder.writeU32(0); // default_sample_duration = 0
        try builder.writeU32(0); // default_sample_size = 0
        try builder.writeU32(0); // default_sample_flags = 0
        try builder.endBox(trex_v_start);

        if (audio != null) {
            const trex_a_start = try builder.writeFullBoxHeader("trex", 0, 0);
            try builder.writeU32(2); // track_ID = 2
            try builder.writeU32(1);
            try builder.writeU32(0);
            try builder.writeU32(0);
            try builder.writeU32(0);
            try builder.endBox(trex_a_start);
        }

        try builder.endBox(mvex_start);
    }

    try builder.endBox(moov_start);
}

/// Writes a single movie fragment (`moof` + `mdat`).
pub fn writeFragment(
    builder: *BoxBuilder,
    sequence_number: u32,
    track_id: u32,
    base_decode_time: u64,
    samples: []const SampleInfo,
    payload_data: []const u8,
) !void {
    const moof_start = try builder.startBox("moof");

    // mfhd
    {
        const mfhd_start = try builder.writeFullBoxHeader("mfhd", 0, 0);
        try builder.writeU32(sequence_number);
        try builder.endBox(mfhd_start);
    }

    var data_offset_pos: usize = 0;

    // traf
    {
        const traf_start = try builder.startBox("traf");

        // tfhd: default-base-is-moof (0x020000)
        const tfhd_start = try builder.writeFullBoxHeader("tfhd", 0, 0x020000);
        try builder.writeU32(track_id);
        try builder.endBox(tfhd_start);

        // tfdt: version 1 (64-bit base decode time)
        const tfdt_start = try builder.writeFullBoxHeader("tfdt", 1, 0);
        try builder.writeU64(base_decode_time);
        try builder.endBox(tfdt_start);

        // trun:
        // flags:
        //   0x000001 (data-offset-present)
        //   0x000004 (first-sample-flags-present)
        //   0x000100 (sample-duration-present)
        //   0x000200 (sample-size-present)
        //   0x000800 (sample-composition-time-offsets-present)
        const trun_flags: u24 = 0x000001 | 0x000004 | 0x000100 | 0x000200 | 0x000800;
        const trun_start = try builder.writeFullBoxHeader("trun", 0, trun_flags);
        try builder.writeU32(@intCast(samples.len));

        // data_offset placeholder (we will compute and write after calculating moof length)
        data_offset_pos = builder.buf.items.len;
        try builder.writeI32(0);

        // first_sample_flags: 0x02000000 for keyframe, 0x01010000 for non-keyframe
        const first_keyframe = if (samples.len > 0 and samples[0].is_keyframe) @as(u32, 0x02000000) else @as(u32, 0x01010000);
        try builder.writeU32(first_keyframe);

        for (samples) |s| {
            try builder.writeU32(s.duration);
            try builder.writeU32(s.size);
            try builder.writeI32(s.composition_time_offset);
        }
        try builder.endBox(trun_start);
        try builder.endBox(traf_start);
    }

    try builder.endBox(moof_start);

    // Calculate actual data_offset (offset from start of moof to start of mdat payload):
    // moof size + 8 bytes (mdat size + 'mdat' header)
    const moof_len: i32 = @intCast(builder.buf.items.len - moof_start);
    const data_offset: i32 = moof_len + 8;
    std.mem.writeInt(i32, builder.buf.items[data_offset_pos..][0..4], data_offset, .big);

    // Write mdat box
    const mdat_start = try builder.startBox("mdat");
    try builder.writeBytes(payload_data);
    try builder.endBox(mdat_start);
}

test "mp4_muxer ftyp and moov construction" {
    const testing = std.testing;
    var builder = BoxBuilder.init(testing.allocator);
    defer builder.deinit();

    try writeFtyp(&builder);
    try testing.expect(builder.buf.items.len > 0);
    // Verify first 8 bytes: size (28 or 32) and 'ftyp'
    const ftyp_size = std.mem.readInt(u32, builder.buf.items[0..4], .big);
    try testing.expectEqual(@as(u32, @intCast(builder.buf.items.len)), ftyp_size);
    try testing.expectEqualStrings("ftyp", builder.buf.items[4..8]);

    const video_cfg = VideoTrackConfig{
        .width = 1920,
        .height = 1080,
        .codec = .h264,
        .codec_private = &[_]u8{ 0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x04, 0x27, 0x64, 0x00, 0x1f, 0x01, 0x00, 0x04, 0x28, 0xee, 0x38, 0x80 },
    };

    const moov_offset = builder.buf.items.len;
    try writeMoov(&builder, video_cfg, null);
    const moov_size = std.mem.readInt(u32, builder.buf.items[moov_offset..][0..4], .big);
    try testing.expectEqualStrings("moov", builder.buf.items[moov_offset + 4 .. moov_offset + 8]);
    try testing.expectEqual(@as(u32, @intCast(builder.buf.items.len - moov_offset)), moov_size);
}

test "mp4_muxer fragment construction" {
    const testing = std.testing;
    var builder = BoxBuilder.init(testing.allocator);
    defer builder.deinit();

    const samples = [_]SampleInfo{
        .{ .duration = 3000, .size = 12, .is_keyframe = true, .composition_time_offset = 0 },
        .{ .duration = 3000, .size = 10, .is_keyframe = false, .composition_time_offset = 0 },
    };
    const payload = [_]u8{
        0, 0, 0, 8, 0x65, 0x88, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, // sample 1 (12 bytes)
        0, 0, 0, 6, 0x41, 0x9a, 0x00, 0x00, 0x00, 0x00,             // sample 2 (10 bytes)
    };

    try writeFragment(&builder, 1, 1, 0, &samples, &payload);

    // Verify moof header
    const moof_size = std.mem.readInt(u32, builder.buf.items[0..4], .big);
    try testing.expectEqualStrings("moof", builder.buf.items[4..8]);

    // Verify mdat header
    const mdat_pos = moof_size;
    const mdat_size = std.mem.readInt(u32, builder.buf.items[mdat_pos..][0..4], .big);
    try testing.expectEqualStrings("mdat", builder.buf.items[mdat_pos + 4 .. mdat_pos + 8]);
    try testing.expectEqual(@as(u32, payload.len + 8), mdat_size);
}

test "mp4_muxer dual-track Video + Audio moov construction" {
    const testing = std.testing;
    var builder = BoxBuilder.init(testing.allocator);
    defer builder.deinit();

    try writeFtyp(&builder);

    const video_cfg = VideoTrackConfig{
        .width = 1920,
        .height = 1080,
        .codec = .h264,
        .codec_private = &[_]u8{ 0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x04, 0x27, 0x64, 0x00, 0x1f, 0x01, 0x00, 0x04, 0x28, 0xee, 0x38, 0x80 },
    };
    const audio_cfg = AudioTrackConfig{
        .sample_rate = 48000,
        .channels = 2,
        .codec_private = &[_]u8{ 0x11, 0x90 }, // 48kHz stereo AAC
        .timescale = 48000,
    };

    const moov_offset = builder.buf.items.len;
    try writeMoov(&builder, video_cfg, audio_cfg);
    const moov_size = std.mem.readInt(u32, builder.buf.items[moov_offset..][0..4], .big);
    try testing.expectEqualStrings("moov", builder.buf.items[moov_offset + 4 .. moov_offset + 8]);
    try testing.expectEqual(@as(u32, @intCast(builder.buf.items.len - moov_offset)), moov_size);
}
