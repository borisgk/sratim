const std = @import("std");

pub const BoxHeader = struct {
    type: [4]u8,
    size: u64,
    header_size: usize,
    data_offset: u64,

    pub fn dataSize(self: BoxHeader) u64 {
        if (self.size == std.math.maxInt(u64)) return std.math.maxInt(u64);
        return if (self.size >= self.header_size) self.size - self.header_size else 0;
    }
};

pub const SttsEntry = struct {
    count: u32,
    delta: u32,
};

pub const CttsEntry = struct {
    count: u32,
    offset: i32,
};

pub const StscEntry = struct {
    first_chunk: u32,
    samples_per_chunk: u32,
    sample_desc_index: u32,
};

pub const SubtitleSample = struct {
    start_sec: f64,
    end_sec: f64,
    offset: u64,
    size: u32,
};

pub const Mp4SubtitleTrack = struct {
    track_id: u32,
    stream_idx: usize,
    handler_type: [4]u8,
    timescale: u32,
    format: [4]u8,
    samples: []SubtitleSample,

    pub fn deinit(self: *Mp4SubtitleTrack, allocator: std.mem.Allocator) void {
        if (self.samples.len > 0) {
            allocator.free(self.samples);
        }
    }
};

pub const MediaSample = struct {
    dts_delta: u32,
    dts: u64,
    pts: u64,
    pts_sec: f64,
    offset: u64,
    size: u32,
    is_sync: bool,
    ctts_offset: i32 = 0,
};

pub const Mp4MediaTrack = struct {
    track_id: u32,
    stream_idx: usize,
    handler_type: [4]u8, // "vide", "soun", "sbtl"
    timescale: u32,
    duration: u64,
    width: u32 = 0,
    height: u32 = 0,
    volume: u16 = 0,
    language: [4]u8 = "und\x00".*,
    stsd_raw: []u8,
    samples: []MediaSample,
    sync_sample_indices: []u32,

    pub fn deinit(self: *Mp4MediaTrack, allocator: std.mem.Allocator) void {
        if (self.stsd_raw.len > 0) allocator.free(self.stsd_raw);
        if (self.samples.len > 0) allocator.free(self.samples);
        if (self.sync_sample_indices.len > 0) allocator.free(self.sync_sample_indices);
    }
};

pub const Mp4SubtitleTrackInfo = struct {
    stream_idx: usize,
    track_id: u32,
    language: [4]u8 = "und\x00".*,
};

pub const Mp4Media = struct {
    timescale: u32,
    video_track: ?Mp4MediaTrack = null,
    audio_tracks: []Mp4MediaTrack,
    subtitle_tracks: []Mp4SubtitleTrackInfo = &.{},

    pub fn deinit(self: *Mp4Media, allocator: std.mem.Allocator) void {
        if (self.video_track) |*vt| vt.deinit(allocator);
        for (self.audio_tracks) |*at| at.deinit(allocator);
        if (self.audio_tracks.len > 0) allocator.free(self.audio_tracks);
        if (self.subtitle_tracks.len > 0) allocator.free(self.subtitle_tracks);
    }
};

pub const IdentityMatrix = [_]u8{
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
};
