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
