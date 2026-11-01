const std = @import("std");
const tables = @import("tables.zig");

pub fn bitAllocateDirect(
    fscod: usize,
    halfrate: usize,
    bai: u32,
    snroffset_direct: i32,
    fast_gain_val: u3,
    deltbae: u32,
    deltba: []const i8,
    bndstart: usize,
    start: usize,
    end: usize,
    fastleak_init: i32,
    slowleak_init: i32,
    exp: []const u8,
    bap: []i8,
) void {
    bitAllocateDirectWithTab(
        fscod,
        halfrate,
        bai,
        snroffset_direct,
        fast_gain_val,
        deltbae,
        deltba,
        bndstart,
        start,
        end,
        fastleak_init,
        slowleak_init,
        exp,
        &tables.BAP_TAB,
        bap,
    );
}

inline fn computeSingleBap(
    mask_in: i32,
    snroffset: i32,
    floor_val: i32,
    d_val: i32,
    exp_val: u8,
    bap_tab: *const [305]i8,
) i8 {
    var mask = mask_in - (snroffset + 128 * d_val);
    mask = if (mask > 0) 0 else ((-mask) >> 5);
    mask -= floor_val;
    const bap_idx: usize = @intCast(@max(0, @min(@as(i32, 304), mask + 4 * @as(i32, exp_val) + 156)));
    return bap_tab[bap_idx];
}

pub fn bitAllocateDirectWithTab(
    fscod: usize,
    halfrate: usize,
    bai: u32,
    snroffset_direct: i32,
    fast_gain_val: u3,
    deltbae: u32,
    deltba: []const i8,
    bndstart: usize,
    start: usize,
    end: usize,
    fastleak_init: i32,
    slowleak_init: i32,
    exp: []const u8,
    bap_tab: *const [305]i8,
    bap: []i8,
) void {
    const fdecay = (63 + 20 * @as(i32, @intCast((bai >> 7) & 3))) >> @intCast(halfrate);
    const fgain = 128 + 128 * @as(i32, @intCast(fast_gain_val));
    const sdecay = (15 + 2 * @as(i32, @intCast(bai >> 9))) >> @intCast(halfrate);
    const sgain = tables.SLOW_GAIN[@intCast((bai >> 5) & 3)];
    const dbknee = tables.DBPB_TAB[@intCast((bai >> 3) & 3)];
    const hth = &tables.HTH_TAB[fscod];
    const deltba_slice: []const i8 = if (deltbae == tables.DELTA_BIT_NONE) &tables.ZERO_DELTBA else deltba;
    var floor_val = tables.FLOOR_TAB[@intCast(bai & 7)];
    const snroffset = -snroffset_direct + floor_val;
    floor_val >>= 5;

    var fastleak = fastleak_init;
    var slowleak = slowleak_init;

    var i = bndstart;
    var j = start;

    if (start == 0) {
        var lowcomp: i32 = 0;
        const j_end = end - 1;

        while (true) {
            if (i < j_end) {
                if (@as(i32, exp[i + 1]) == @as(i32, exp[i]) - 2) {
                    lowcomp = 384;
                } else if (lowcomp != 0 and exp[i + 1] > exp[i]) {
                    lowcomp -= 64;
                }
            }
            const psd = 128 * @as(i32, exp[i]);
            var mask = psd + fgain + lowcomp;
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            bap[i] = computeSingleBap(mask, snroffset, floor_val, d_val, exp[i], bap_tab);
            i += 1;
            if (!((i < 3) or ((i < 7) and (exp[i] > exp[i - 1])))) break;
        }

        const psd_last = 128 * @as(i32, exp[i - 1]);
        fastleak = psd_last + fgain;
        slowleak = psd_last + sgain;

        while (i < 7) : (i += 1) {
            if (i < j_end) {
                if (@as(i32, exp[i + 1]) == @as(i32, exp[i]) - 2) {
                    lowcomp = 384;
                } else if (lowcomp != 0 and exp[i + 1] > exp[i]) {
                    lowcomp -= 64;
                }
            }
            const psd = 128 * @as(i32, exp[i]);
            fastleak = @min(fastleak + fdecay, psd + fgain);
            slowleak = @min(slowleak + sdecay, psd + sgain);

            var mask = @min(fastleak + lowcomp, slowleak);
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            bap[i] = computeSingleBap(mask, snroffset, floor_val, d_val, exp[i], bap_tab);
        }

        while (i < 20) : (i += 1) {
            if (@as(i32, exp[i + 1]) == @as(i32, exp[i]) - 2) {
                lowcomp = 320;
            } else if (lowcomp != 0 and exp[i + 1] > exp[i]) {
                lowcomp -= 64;
            }
            const psd = 128 * @as(i32, exp[i]);
            fastleak = @min(fastleak + fdecay, psd + fgain);
            slowleak = @min(slowleak + sdecay, psd + sgain);

            var mask = @min(fastleak + lowcomp, slowleak);
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            bap[i] = computeSingleBap(mask, snroffset, floor_val, d_val, exp[i], bap_tab);
        }

        while (lowcomp > 128) : (i += 1) {
            lowcomp -= 128;
            const psd = 128 * @as(i32, exp[i]);
            fastleak = @min(fastleak + fdecay, psd + fgain);
            slowleak = @min(slowleak + sdecay, psd + sgain);

            var mask = @min(fastleak + lowcomp, slowleak);
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            bap[i] = computeSingleBap(mask, snroffset, floor_val, d_val, exp[i], bap_tab);
        }
        j = i;
    }

    const v_zero: @Vector(4, i32) = @splat(0);
    const v_max: @Vector(4, i32) = @splat(304);

    while (i < 50) {
        const startband = j;
        const bnd_idx = if (i >= 20) i - 20 else 0;
        const endband = if (bnd_idx < 30 and tables.BND_TAB[bnd_idx] < end) tables.BND_TAB[bnd_idx] else end;
        var psd = 128 * @as(i32, exp[j]);
        j += 1;
        while (j < endband) {
            const next = 128 * @as(i32, exp[j]);
            j += 1;
            const delta = next - psd;
            switch (delta >> 9) {
                -6, -5, -4, -3, -2 => psd = next,
                -1 => {
                    const la_idx: usize = @intCast((-delta) >> 1);
                    if (la_idx < tables.LA_TAB.len) psd = next + tables.LA_TAB[la_idx];
                },
                0 => {
                    const la_idx: usize = @intCast(delta >> 1);
                    if (la_idx < tables.LA_TAB.len) psd += tables.LA_TAB[la_idx];
                },
                else => {},
            }
        }

        fastleak = @min(fastleak + fdecay, psd + fgain);
        slowleak = @min(slowleak + sdecay, psd + sgain);

        var mask = @min(fastleak, slowleak);
        if (psd > dbknee) mask -= (psd - dbknee) >> 2;
        const hth_idx = i >> @intCast(halfrate);
        if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
        const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
        mask -= snroffset + 128 * d_val;
        mask = if (mask > 0) 0 else ((-mask) >> 5);
        mask -= floor_val;

        const mask_offset = mask + 156;
        const v_mask_off: @Vector(4, i32) = @splat(mask_offset);

        i += 1;
        j = startband;
        while (j + 4 <= endband) : (j += 4) {
            const exp_u8: @Vector(4, u8) = exp[j..][0..4].*;
            const exp_i32: @Vector(4, i32) = exp_u8;
            const bap_idx_vec = @max(v_zero, @min(v_max, v_mask_off + (exp_i32 << @splat(2))));
            const idx_arr: [4]i32 = bap_idx_vec;
            bap[j..][0..4].* = .{
                bap_tab[@intCast(idx_arr[0])],
                bap_tab[@intCast(idx_arr[1])],
                bap_tab[@intCast(idx_arr[2])],
                bap_tab[@intCast(idx_arr[3])],
            };
        }
        while (j < endband) : (j += 1) {
            const bap_idx: usize = @intCast(@max(0, @min(@as(i32, 304), mask_offset + 4 * @as(i32, exp[j]))));
            bap[j] = bap_tab[bap_idx];
        }
    }
}

pub fn bitAllocate(
    fscod: usize,
    halfrate: usize,
    bai: u32,
    csnroffst: u32,
    channel_bai: u32,
    deltbae: u32,
    deltba: []const i8,
    bndstart: usize,
    start: usize,
    end: usize,
    fastleak_init: i32,
    slowleak_init: i32,
    exp: []const u8,
    bap: []i8,
) void {
    const snroffst = 64 * @as(i32, @intCast(csnroffst)) + 4 * @as(i32, @intCast(channel_bai >> 3)) - 960;
    const fast_gain_val: u3 = @intCast(channel_bai & 7);
    bitAllocateDirect(
        fscod,
        halfrate,
        bai,
        snroffst,
        fast_gain_val,
        deltbae,
        deltba,
        bndstart,
        start,
        end,
        fastleak_init,
        slowleak_init,
        exp,
        bap,
    );
}
