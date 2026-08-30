const std = @import("std");
pub const ac3_tables = @import("../ac3/tables.zig");

// Re-export shared AC-3 tables used by E-AC-3
pub const SAMPLE_RATES = ac3_tables.SAMPLE_RATES;
pub const NFCHANS_TBL = ac3_tables.NFCHANS_TBL;
pub const EXP_REUSE = ac3_tables.EXP_REUSE;
pub const EXP_D15 = ac3_tables.EXP_D15;
pub const EXP_D25 = ac3_tables.EXP_D25;
pub const EXP_D45 = ac3_tables.EXP_D45;
pub const DELTA_BIT_NONE = ac3_tables.DELTA_BIT_NONE;
pub const DELTA_BIT_REUSE = ac3_tables.DELTA_BIT_REUSE;
pub const DELTA_BIT_NEW = ac3_tables.DELTA_BIT_NEW;
pub const DELTA_BIT_RESERVED = ac3_tables.DELTA_BIT_RESERVED;
pub const EXP_1 = ac3_tables.EXP_1;
pub const EXP_2 = ac3_tables.EXP_2;
pub const EXP_3 = ac3_tables.EXP_3;
pub const DITHER_LUT = ac3_tables.DITHER_LUT;
pub const CPL_BND_TAB = ac3_tables.CPL_BND_TAB;
pub const SCALE_FACTOR = ac3_tables.SCALE_FACTOR;
pub const Q_1_0 = ac3_tables.Q_1_0;
pub const Q_1_1 = ac3_tables.Q_1_1;
pub const Q_1_2 = ac3_tables.Q_1_2;
pub const Q_2_0 = ac3_tables.Q_2_0;
pub const Q_2_1 = ac3_tables.Q_2_1;
pub const Q_2_2 = ac3_tables.Q_2_2;
pub const Q_3 = ac3_tables.Q_3;
pub const Q_4_0 = ac3_tables.Q_4_0;
pub const Q_4_1 = ac3_tables.Q_4_1;
pub const Q_5 = ac3_tables.Q_5;
pub const WINDOW = ac3_tables.WINDOW;
pub const BAP_TAB = ac3_tables.BAP_TAB;
pub const SLOW_GAIN = ac3_tables.SLOW_GAIN;
pub const DBPB_TAB = ac3_tables.DBPB_TAB;
pub const HTH_TAB = ac3_tables.HTH_TAB;
pub const FLOOR_TAB = ac3_tables.FLOOR_TAB;
pub const ZERO_DELTBA = ac3_tables.ZERO_DELTBA;

// E-AC-3 specific constants and tables
pub const NUM_BLOCKS: [4]usize = .{ 1, 2, 3, 6 };
pub const SAMPLE_RATES_HALF: [3]u32 = .{ 24000, 22050, 16000 };

/// Table E2.16 Default Coupling Banding Structure
pub const DEFAULT_CPL_BAND_STRUCT: [18]u1 = .{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1,
};

/// Table E2.14: Frame Exponent Strategy Combinations
pub const EAC3_FRM_EXPSTR: [32][6]u2 = .{
    .{ EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_REUSE },
    .{ EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_D45 },
    .{ EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_D25, EXP_REUSE },
    .{ EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_D45, EXP_D45 },
    .{ EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_REUSE },
    .{ EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_D45 },
    .{ EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D45, EXP_D25, EXP_REUSE },
    .{ EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D45, EXP_D45, EXP_D45 },
    .{ EXP_D25, EXP_REUSE, EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE },
    .{ EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D45 },
    .{ EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE },
    .{ EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_D45, EXP_D45 },
    .{ EXP_D25, EXP_REUSE, EXP_D45, EXP_D25, EXP_REUSE, EXP_REUSE },
    .{ EXP_D25, EXP_REUSE, EXP_D45, EXP_D25, EXP_REUSE, EXP_D45 },
    .{ EXP_D25, EXP_REUSE, EXP_D45, EXP_D45, EXP_D25, EXP_REUSE },
    .{ EXP_D25, EXP_REUSE, EXP_D45, EXP_D45, EXP_D45, EXP_D45 },
    .{ EXP_D45, EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_REUSE },
    .{ EXP_D45, EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE, EXP_D45 },
    .{ EXP_D45, EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D25, EXP_REUSE },
    .{ EXP_D45, EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D45, EXP_D45 },
    .{ EXP_D45, EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_REUSE },
    .{ EXP_D45, EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE, EXP_D45 },
    .{ EXP_D45, EXP_D25, EXP_REUSE, EXP_D45, EXP_D25, EXP_REUSE },
    .{ EXP_D45, EXP_D25, EXP_REUSE, EXP_D45, EXP_D45, EXP_D45 },
    .{ EXP_D45, EXP_D45, EXP_D15, EXP_REUSE, EXP_REUSE, EXP_REUSE },
    .{ EXP_D45, EXP_D45, EXP_D25, EXP_REUSE, EXP_REUSE, EXP_D45 },
    .{ EXP_D45, EXP_D45, EXP_D25, EXP_REUSE, EXP_D25, EXP_REUSE },
    .{ EXP_D45, EXP_D45, EXP_D25, EXP_REUSE, EXP_D45, EXP_D45 },
    .{ EXP_D45, EXP_D45, EXP_D45, EXP_D25, EXP_REUSE, EXP_REUSE },
    .{ EXP_D45, EXP_D45, EXP_D45, EXP_D25, EXP_REUSE, EXP_D45 },
    .{ EXP_D45, EXP_D45, EXP_D45, EXP_D45, EXP_D25, EXP_REUSE },
    .{ EXP_D45, EXP_D45, EXP_D45, EXP_D45, EXP_D45, EXP_D45 },
};
