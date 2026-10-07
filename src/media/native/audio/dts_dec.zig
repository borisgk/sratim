const std = @import("std");

pub const bit_reader = @import("dts/bit_reader.zig");
pub const BitReader = bit_reader.BitReader;

pub const tables = @import("dts/tables.zig");
pub const vectors = @import("dts/vectors.zig");
pub const header = @import("dts/header.zig");
pub const FrameHeader = header.FrameHeader;
pub const findSync = header.findSync;
pub const parseHeader = header.parseHeader;

pub const synthesis = @import("dts/synthesis.zig");
pub const subband = @import("dts/subband.zig");
pub const decoder = @import("dts/decoder.zig");
pub const DtsDecoder = decoder.DtsDecoder;
