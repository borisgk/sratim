const std = @import("std");
const tables = @import("tables.zig");

pub const HDR_SIZE = 4;
pub const MAX_FREE_FORMAT_FRAME_SIZE = 2304;
pub const MODE_MONO = 3;
pub const MODE_JOINT_STEREO = 1;
pub const SHORT_BLOCK_TYPE = 2;
pub const STOP_BLOCK_TYPE = 3;

pub fn hdr_is_mono(h: []const u8) bool {
    return (h[3] & 0xC0) == 0xC0;
}
pub fn hdr_is_ms_stereo(h: []const u8) bool {
    return (h[3] & 0xE0) == 0x60;
}
pub fn hdr_is_free_format(h: []const u8) bool {
    return (h[2] & 0xF0) == 0;
}
pub fn hdr_is_crc(h: []const u8) bool {
    return (h[1] & 1) == 0;
}
pub fn hdr_test_padding(h: []const u8) bool {
    return (h[2] & 0x02) != 0;
}
pub fn hdr_test_mpeg1(h: []const u8) bool {
    return (h[1] & 0x08) != 0;
}
pub fn hdr_test_not_mpeg25(h: []const u8) bool {
    return (h[1] & 0x10) != 0;
}
pub fn hdr_test_i_stereo(h: []const u8) bool {
    return (h[3] & 0x10) != 0;
}
pub fn hdr_test_ms_stereo(h: []const u8) bool {
    return (h[3] & 0x20) != 0;
}
pub fn hdr_get_stereo_mode(h: []const u8) u8 {
    return (h[3] >> 6) & 3;
}
pub fn hdr_get_stereo_mode_ext(h: []const u8) u8 {
    return (h[3] >> 4) & 3;
}
pub fn hdr_get_layer(h: []const u8) u8 {
    return (h[1] >> 1) & 3;
}
pub fn hdr_get_bitrate(h: []const u8) u8 {
    return (h[2] >> 4) & 15;
}
pub fn hdr_get_sample_rate(h: []const u8) u8 {
    return (h[2] >> 2) & 3;
}
pub fn hdr_get_my_sample_rate(h: []const u8) usize {
    const sr = hdr_get_sample_rate(h);
    const m1: usize = (h[1] >> 3) & 1;
    const m25: usize = (h[1] >> 4) & 1;
    return sr + (m1 + m25) * 3;
}
pub fn hdr_is_frame_576(h: []const u8) bool {
    return (h[1] & 14) == 2;
}
pub fn hdr_is_layer_1(h: []const u8) bool {
    return (h[1] & 6) == 6;
}

pub fn hdr_valid(h: []const u8) bool {
    if (h.len < 4) return false;
    return h[0] == 0xFF and
        ((h[1] & 0xF0) == 0xF0 or (h[1] & 0xFE) == 0xE2) and
        (hdr_get_layer(h) != 0) and
        (hdr_get_bitrate(h) != 15) and
        (hdr_get_sample_rate(h) != 3);
}

pub fn hdr_compare(h1: []const u8, h2: []const u8) bool {
    return hdr_valid(h2) and
        ((h1[1] ^ h2[1]) & 0xFE) == 0 and
        ((h1[2] ^ h2[2]) & 0x0C) == 0 and
        (hdr_is_free_format(h1) == hdr_is_free_format(h2));
}

pub fn hdr_bitrate_kbps(h: []const u8) u32 {
    const is_m1: usize = if (hdr_test_mpeg1(h)) 1 else 0;
    const l = hdr_get_layer(h);
    if (l == 0) return 0;
    const br_idx = hdr_get_bitrate(h);
    if (br_idx >= 15) return 0;
    return @as(u32, 2) * @as(u32, tables.halfrate[is_m1][l - 1][br_idx]);
}

pub fn hdr_sample_rate_hz(h: []const u8) u32 {
    const sr_idx = hdr_get_sample_rate(h);
    if (sr_idx >= 3) return 44100;
    var hz = tables.g_hz[sr_idx];
    if (!hdr_test_mpeg1(h)) hz >>= 1;
    if (!hdr_test_not_mpeg25(h)) hz >>= 1;
    return hz;
}

pub fn hdr_frame_samples(h: []const u8) usize {
    if (hdr_is_layer_1(h)) return 384;
    return if (hdr_is_frame_576(h)) 576 else 1152;
}

pub fn hdr_frame_bytes(h: []const u8, free_format_size: usize) usize {
    const hz = hdr_sample_rate_hz(h);
    if (hz == 0) return free_format_size;
    var fb = (hdr_frame_samples(h) * hdr_bitrate_kbps(h) * 125) / hz;
    if (hdr_is_layer_1(h)) fb &= ~@as(usize, 3);
    return if (fb > 0) fb else free_format_size;
}

pub fn hdr_padding(h: []const u8) usize {
    if (!hdr_test_padding(h)) return 0;
    return if (hdr_is_layer_1(h)) 4 else 1;
}

pub fn matchFrame(hdr: []const u8, mp3_bytes: usize, frame_bytes: usize) bool {
    var i: usize = 0;
    var nmatch: usize = 0;
    while (nmatch < 10) : (nmatch += 1) {
        i += hdr_frame_bytes(hdr[i..], frame_bytes) + hdr_padding(hdr[i..]);
        if (i + HDR_SIZE > mp3_bytes) return nmatch > 0;
        if (!hdr_compare(hdr, hdr[i..])) return false;
    }
    return true;
}

pub fn findFrame(
    mp3: []const u8,
    free_format_bytes: *usize,
    ptr_frame_bytes: *usize,
) usize {
    if (mp3.len < HDR_SIZE) {
        ptr_frame_bytes.* = 0;
        return mp3.len;
    }
    const max_search = mp3.len - HDR_SIZE;
    for (0..max_search) |i| {
        const h = mp3[i..];
        if (hdr_valid(h)) {
            const fb = hdr_frame_bytes(h, free_format_bytes.*);
            const frame_and_padding = fb + hdr_padding(h);

            if ((fb != 0 and i + frame_and_padding <= mp3.len and matchFrame(h, mp3.len - i, fb)) or
                (i == 0 and frame_and_padding == mp3.len))
            {
                ptr_frame_bytes.* = frame_and_padding;
                return i;
            }
            free_format_bytes.* = 0;
        }
    }
    ptr_frame_bytes.* = 0;
    return mp3.len;
}
