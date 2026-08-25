const std = @import("std");

pub const MkvTrackType = enum {
    Video,
    Audio,
    Subtitle,
    Other,

    pub fn fromInt(val: u64) MkvTrackType {
        return switch (val) {
            1 => .Video,
            2 => .Audio,
            17 => .Subtitle,
            else => .Other,
        };
    }
};

pub const MkvLacingType = enum(u2) {
    None = 0,
    Xiph = 1,
    Fixed = 2,
    Ebml = 3,
};

pub const MkvTrackInfo = struct {
    track_num: u64,
    stream_idx: usize,
    track_type: MkvTrackType,
    codec_id: []const u8,
    codec_private: ?[]u8 = null,
    timescale: u32 = 1000,
    width: u32 = 0,
    height: u32 = 0,
    sample_rate: u32 = 48000,
    channels: u16 = 2,
    language: [4]u8 = "und\x00".*,
    stsd_raw: ?[]u8 = null,

    pub fn deinit(self: *MkvTrackInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.codec_id);
        if (self.codec_private) |cp| allocator.free(cp);
        if (self.stsd_raw) |stsd| allocator.free(stsd);
    }
};

pub const MkvBlock = struct {
    track_num: u64,
    pts_ms: u64,
    pts_sec: f64,
    is_keyframe: bool,
    is_discardable: bool,
    payload_offset: u64,
    payload_size: u32,
};
