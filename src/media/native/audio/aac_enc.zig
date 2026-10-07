const std = @import("std");

pub const tables = @import("aac/tables.zig");
pub const FREQ_INDICES = tables.FREQ_INDICES;
pub const SWB_OFFSET_48000 = tables.SWB_OFFSET_48000;
pub const NUM_SFBS = tables.NUM_SFBS;
pub const SINE_WINDOW_2048 = tables.SINE_WINDOW_2048;

pub const bit_writer = @import("aac/bit_writer.zig");
pub const BitWriter = bit_writer.BitWriter;

pub const encoder = @import("aac/encoder.zig");
pub const AacEncoder = encoder.AacEncoder;
pub const quantizeChannel = encoder.quantizeChannel;
pub const writeIndividualChannelStream = encoder.writeIndividualChannelStream;
