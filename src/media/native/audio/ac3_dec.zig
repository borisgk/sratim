const std = @import("std");

pub const bit_reader = @import("ac3/bit_reader.zig");
pub const BitReader = bit_reader.BitReader;

pub const tables = @import("ac3/tables.zig");
pub const SAMPLE_RATES = tables.SAMPLE_RATES;
pub const FRAME_SIZE_TABLE = tables.FRAME_SIZE_TABLE;
pub const NFCHANS_TBL = tables.NFCHANS_TBL;

pub const bit_allocation = @import("ac3/bit_allocation.zig");
pub const bitAllocate = bit_allocation.bitAllocate;

pub const decoder = @import("ac3/decoder.zig");
pub const Ac3Decoder = decoder.Ac3Decoder;
