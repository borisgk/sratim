const std = @import("std");

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

/// Builds standard ISOBMFF stsd box containing av01 and av1C records.
pub fn buildAv1Stsd(
    allocator: std.mem.Allocator,
    av1C_payload: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    return buildVisualStsd(allocator, "av01", "av1C", av1C_payload, width, height);
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

    var mp4a_hdr: [36]u8 = @splat(0);
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
