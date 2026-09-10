const std = @import("std");
const tables = @import("tables.zig");
const bit_reader = @import("../ac3/bit_reader.zig");
pub const BitReader = bit_reader.BitReader;

pub const IcsInfo = struct {
    window_sequence: u2 = 0,
    window_shape: u1 = 0,
    max_sfb: usize = 0,
    num_windows: usize = 1,
    num_window_groups: usize = 1,
    group_len: [8]usize = [_]usize{1} ** 8,
};

pub const TnsData = struct {
    present: bool = false,
    n_filt: [8]usize = [_]usize{0} ** 8,
    length: [8][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 8,
    direction: [8][4]u1 = [_][4]u1{[_]u1{0} ** 4} ** 8,
    order: [8][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 8,
    coef: [8][4][12]f32 = [_][4][12]f32{[_][12]f32{[_]f32{0.0} ** 12} ** 4} ** 8,
};

pub fn computeLpcCoefs(autoc: []const f32, order: usize, lpc: []f32) void {
    for (0..order) |i| {
        const r = -autoc[i];
        lpc[i] = r;
        const half = (i + 1) >> 1;
        for (0..half) |j| {
            const f = lpc[j];
            const b = lpc[i - 1 - j];
            lpc[j] = f + r * b;
            lpc[i - 1 - j] = b + r * f;
        }
    }
}

pub fn parseTnsData(reader: *BitReader, ics: *const IcsInfo, tns: *TnsData) !void {
    tns.present = (try reader.readBit()) == 1;
    if (!tns.present) return;

    const is8 = (ics.window_sequence == 2);
    const tns_max_order: usize = if (is8) 7 else 12;

    for (0..ics.num_windows) |w| {
        const n_filt = try reader.readBits(usize, if (is8) 1 else 2);
        tns.n_filt[w] = n_filt;
        if (n_filt > 0) {
            const coef_res = try reader.readBit();
            for (0..n_filt) |filt| {
                tns.length[w][filt] = try reader.readBits(usize, if (is8) 4 else 6);
                const order = try reader.readBits(usize, if (is8) 3 else 5);
                if (order > tns_max_order) {
                    tns.order[w][filt] = 0;
                    return error.TnsOrderTooHigh;
                }
                tns.order[w][filt] = order;
                if (order > 0) {
                    tns.direction[w][filt] = try reader.readBits(u1, 1);
                    const coef_compress = try reader.readBit();
                    const coef_len: u5 = @as(u5, coef_res) + 3 - @as(u5, coef_compress);
                    const tmp2_idx = 2 * @as(usize, coef_compress) + @as(usize, coef_res);

                    for (0..order) |i| {
                        const coef_idx = try reader.readBits(usize, coef_len);
                        tns.coef[w][filt][i] = switch (tmp2_idx) {
                            0 => tables.TNS_TMP2_MAP_0_3[coef_idx],
                            1 => tables.TNS_TMP2_MAP_0_4[coef_idx],
                            2 => tables.TNS_TMP2_MAP_1_3[coef_idx],
                            3 => tables.TNS_TMP2_MAP_1_4[coef_idx],
                            else => 0.0,
                        };
                    }
                }
            }
        }
    }
}

pub fn applyTns(spectrum: *[1024]f32, ics: *const IcsInfo, tns: *const TnsData, sample_rate_idx: u4) void {
    if (!tns.present) return;

    const is8 = (ics.window_sequence == 2);
    const tns_max_bands: usize = if (is8) tables.TNS_MAX_BANDS_128[sample_rate_idx] else tables.TNS_MAX_BANDS_1024[sample_rate_idx];
    const mmm = @min(tns_max_bands, ics.max_sfb);
    if (mmm == 0) return;

    const num_swb: usize = if (is8) tables.NUM_SWB_128[sample_rate_idx] else tables.NUM_SWB_1024[sample_rate_idx];
    const swb_offset = if (is8) tables.SWB_OFFSETS_128[sample_rate_idx] else tables.SWB_OFFSETS_1024[sample_rate_idx];

    for (0..ics.num_windows) |w| {
        var bottom: usize = num_swb;
        for (0..tns.n_filt[w]) |filt| {
            const top = bottom;
            bottom = if (top > tns.length[w][filt]) top - tns.length[w][filt] else 0;
            const order = tns.order[w][filt];
            if (order == 0) continue;

            var lpc: [12]f32 = undefined;
            computeLpcCoefs(tns.coef[w][filt][0..order], order, lpc[0..order]);

            const b_idx = @min(bottom, mmm);
            const t_idx = @min(top, mmm);
            const start_sfb = swb_offset[b_idx];
            const end_sfb = swb_offset[t_idx];
            if (end_sfb <= start_sfb) continue;
            const size = end_sfb - start_sfb;

            const dir = tns.direction[w][filt];
            const w_offset = w * 128;

            if (dir == 0) {
                // Increasing frequency
                const base = w_offset + start_sfb;
                for (0..size) |m| {
                    const idx = base + m;
                    const max_i = @min(m, order);
                    for (1..max_i + 1) |i| {
                        spectrum[idx] -= spectrum[idx - i] * lpc[i - 1];
                    }
                }
            } else {
                // Decreasing frequency
                const base = w_offset + end_sfb - 1;
                for (0..size) |m| {
                    const idx = base - m;
                    const max_i = @min(m, order);
                    for (1..max_i + 1) |i| {
                        spectrum[idx] -= spectrum[idx + i] * lpc[i - 1];
                    }
                }
            }
        }
    }
}
