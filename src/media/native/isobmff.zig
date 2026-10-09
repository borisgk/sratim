const std = @import("std");

pub const types = @import("isobmff/types.zig");
pub const reader = @import("isobmff/reader.zig");
pub const samples = @import("isobmff/samples.zig");
pub const tracks = @import("isobmff/tracks.zig");
pub const parser = @import("isobmff/parser.zig");

// Re-export public types
pub const BoxHeader = types.BoxHeader;
pub const SttsEntry = types.SttsEntry;
pub const CttsEntry = types.CttsEntry;
pub const StscEntry = types.StscEntry;
pub const SubtitleSample = types.SubtitleSample;
pub const Mp4SubtitleTrack = types.Mp4SubtitleTrack;
pub const MediaSample = types.MediaSample;
pub const Mp4MediaTrack = types.Mp4MediaTrack;
pub const Mp4SubtitleTrackInfo = types.Mp4SubtitleTrackInfo;
pub const Mp4Media = types.Mp4Media;
pub const IdentityMatrix = types.IdentityMatrix;

// Re-export reader and box utilities
pub const readBoxHeader = reader.readBoxHeader;
pub const skipBytes = reader.skipBytes;
pub const isFourCC = reader.isFourCC;
pub const isMp4Container = reader.isMp4Container;
pub const isSubtitleHandler = reader.isSubtitleHandler;

// Re-export sample mapping functions
pub const buildSampleList = samples.buildSampleList;
pub const buildMediaSampleList = samples.buildMediaSampleList;

// Re-export track and container parsers
pub const parseSubtitleTrackBox = tracks.parseSubtitleTrackBox;
pub const parseGenericTrackBox = tracks.parseGenericTrackBox;
pub const parseMp4SubtitleTrack = parser.parseMp4SubtitleTrack;
pub const parseMp4Media = parser.parseMp4Media;
pub const findMp4KeyframePts = parser.findMp4KeyframePts;

/// Reads media sample payloads from a seekable reader in chunks and writes them directly to writer.
/// If an I/O error occurs, sets `has_error.* = true` and returns immediately.
pub fn streamSamplePayloads(
    payload_reader: anytype,
    writer: anytype,
    sample_list: []const MediaSample,
    transfer_buf: []u8,
    has_error: *bool,
) void {
    for (sample_list) |s| {
        if (s.size == 0) continue;
        payload_reader.seekTo(s.offset) catch {
            has_error.* = true;
            return;
        };

        var rem = s.size;
        while (rem > 0) {
            const to_read: usize = @intCast(@min(rem, transfer_buf.len));
            payload_reader.interface.readSliceAll(transfer_buf[0..to_read]) catch {
                has_error.* = true;
                return;
            };
            writer.writeAll(transfer_buf[0..to_read]) catch {
                has_error.* = true;
                return;
            };
            rem -= @intCast(to_read);
        }
        if (has_error.*) return;
    }
}

