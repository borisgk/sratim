const std = @import("std");
const tables = @import("tables.zig");
const header = @import("header.zig");
const side_info = @import("side_info.zig");

pub fn midsideStereo(left: []f32, right: []f32, n: usize) void {
    for (0..n) |i| {
        const a = left[i];
        const b = right[i];
        left[i] = a + b;
        right[i] = a - b;
    }
}

pub fn intensityStereoBand(left: []f32, right: []f32, n: usize, kl: f32, kr: f32) void {
    for (0..n) |i| {
        right[i] = left[i] * kr;
        left[i] = left[i] * kl;
    }
}

pub fn stereoTopBand(right: []const f32, sfb: []const u8, nbands: usize, max_band: *[3]i32) void {
    max_band[0] = -1;
    max_band[1] = -1;
    max_band[2] = -1;
    var r_idx: usize = 0;
    for (0..nbands) |i| {
        const band_len = sfb[i];
        var k: usize = 0;
        while (k < band_len) : (k += 2) {
            if (right[r_idx + k] != 0 or right[r_idx + k + 1] != 0) {
                max_band[i % 3] = @intCast(i);
                break;
            }
        }
        r_idx += band_len;
    }
}

pub fn stereoProcess(
    left: []f32,
    right: []f32,
    ist_pos: []const u8,
    sfb: []const u8,
    hdr: []const u8,
    max_band: *const [3]i32,
    mpeg2_sh: u5,
) void {
    const max_pos: u32 = if (header.hdr_test_mpeg1(hdr)) 7 else 64;
    var l_idx: usize = 0;
    var i: usize = 0;
    while (i < sfb.len and sfb[i] != 0) : (i += 1) {
        const ipos: u32 = ist_pos[i];
        const band_len = sfb[i];
        if (@as(i32, @intCast(i)) > max_band[i % 3] and ipos < max_pos) {
            const s: f32 = if (header.hdr_test_ms_stereo(hdr)) 1.41421356 else 1.0;
            var kl: f32 = undefined;
            var kr: f32 = undefined;
            if (header.hdr_test_mpeg1(hdr)) {
                kl = tables.g_pan[2 * ipos];
                kr = tables.g_pan[2 * ipos + 1];
            } else {
                kl = 1.0;
                kr = side_info.ldexpQ2(1.0, @intCast(((ipos + 1) >> 1) << mpeg2_sh));
                if ((ipos & 1) != 0) {
                    kl = kr;
                    kr = 1.0;
                }
            }
            intensityStereoBand(left[l_idx..], right[l_idx..], band_len, kl * s, kr * s);
        } else if (header.hdr_test_ms_stereo(hdr)) {
            midsideStereo(left[l_idx..], right[l_idx..], band_len);
        }
        l_idx += band_len;
    }
}

pub fn intensityStereo(
    left: []f32,
    right: []f32,
    ist_pos: []u8,
    gr: *const side_info.L3GrInfo,
    hdr: []const u8,
    gr1_compress: u16,
) void {
    var max_band: [3]i32 = undefined;
    const n_sfb = @as(usize, gr.n_long_sfb) + @as(usize, gr.n_short_sfb);
    const max_blocks: usize = if (gr.n_short_sfb != 0) 3 else 1;

    stereoTopBand(right, gr.sfbtab, n_sfb, &max_band);
    if (gr.n_long_sfb != 0) {
        const m = @max(@max(max_band[0], max_band[1]), max_band[2]);
        max_band[0] = m;
        max_band[1] = m;
        max_band[2] = m;
    }

    for (0..max_blocks) |i| {
        const default_pos: u8 = if (header.hdr_test_mpeg1(hdr)) 3 else 0;
        const itop = n_sfb - max_blocks + i;
        const prev = itop - max_blocks;
        ist_pos[itop] = if (max_band[i] >= @as(i32, @intCast(prev))) default_pos else ist_pos[prev];
    }
    stereoProcess(left, right, ist_pos, gr.sfbtab, hdr, &max_band, @intCast(gr1_compress & 1));
}

pub fn reorder(grbuf: []f32, scratch: []f32, sfbtab: []const u8) void {
    var sfb_idx: usize = 0;
    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    while (sfb_idx < sfbtab.len) {
        const len: usize = sfbtab[sfb_idx];
        if (len == 0) break;
        sfb_idx += 3;
        for (0..len) |i| {
            scratch[dst_idx + 0] = grbuf[src_idx + i + 0 * len];
            scratch[dst_idx + 1] = grbuf[src_idx + i + 1 * len];
            scratch[dst_idx + 2] = grbuf[src_idx + i + 2 * len];
            dst_idx += 3;
        }
        src_idx += 3 * len;
    }
    @memcpy(grbuf[0..dst_idx], scratch[0..dst_idx]);
}

pub fn antialias(grbuf: []f32, nbands: usize) void {
    var ptr: usize = 0;
    for (0..nbands) |_| {
        for (0..8) |i| {
            const u = grbuf[ptr + 18 + i];
            const d = grbuf[ptr + 17 - i];
            grbuf[ptr + 18 + i] = u * tables.g_aa[0][i] - d * tables.g_aa[1][i];
            grbuf[ptr + 17 - i] = u * tables.g_aa[1][i] + d * tables.g_aa[0][i];
        }
        ptr += 18;
    }
}

pub fn dct3_9(y: *[9]f32) void {
    var s0 = y[0];
    const s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    const s8 = y[8];
    const t0 = s0 + s6 * 0.5;
    s0 -= s6;
    const t4 = (s4 + s2) * 0.93969262;
    const t2 = (s8 + s2) * 0.76604444;
    s6 = (s4 - s8) * 0.17364818;
    s4 += s8 - s2;

    const ns2 = s0 - s4 * 0.5;
    y[4] = s4 + s0;
    const ns8 = t0 - t2 + s6;
    const ns0 = t0 - t4 + t2;
    const ns4 = t0 + t4 - s6;

    const s1 = y[1];
    var s3 = y[3];
    const s5 = y[5];
    const s7 = y[7];

    s3 *= 0.86602540;
    const nt0 = (s5 + s1) * 0.98480775;
    const nt4 = (s5 - s7) * 0.34202014;
    const nt2 = (s1 + s7) * 0.64278761;
    const ns1 = (s1 - s5 - s7) * 0.86602540;

    const ns5 = nt0 - s3 - nt2;
    const ns7 = nt4 - s3 - nt0;
    const ns3 = nt4 + s3 - nt2;

    y[0] = ns4 - ns7;
    y[1] = ns2 + ns1;
    y[2] = ns0 - ns3;
    y[3] = ns8 + ns5;
    y[5] = ns8 - ns5;
    y[6] = ns0 + ns3;
    y[7] = ns2 - ns1;
    y[8] = ns4 + ns7;
}

pub fn imdct36(grbuf: []f32, overlap: []f32, window: []const f32, nbands: usize) void {
    var gr_idx: usize = 0;
    var ov_idx: usize = 0;
    for (0..nbands) |_| {
        var co: [9]f32 = undefined;
        var si: [9]f32 = undefined;
        co[0] = -grbuf[gr_idx];
        si[0] = grbuf[gr_idx + 17];
        for (0..4) |i| {
            si[8 - 2 * i] = grbuf[gr_idx + 4 * i + 1] - grbuf[gr_idx + 4 * i + 2];
            co[1 + 2 * i] = grbuf[gr_idx + 4 * i + 1] + grbuf[gr_idx + 4 * i + 2];
            si[7 - 2 * i] = grbuf[gr_idx + 4 * i + 4] - grbuf[gr_idx + 4 * i + 3];
            co[2 + 2 * i] = -(grbuf[gr_idx + 4 * i + 3] + grbuf[gr_idx + 4 * i + 4]);
        }
        dct3_9(&co);
        dct3_9(&si);

        si[1] = -si[1];
        si[3] = -si[3];
        si[5] = -si[5];
        si[7] = -si[7];

        for (0..9) |i| {
            const ovl = overlap[ov_idx + i];
            const sum = co[i] * tables.g_twid9[9 + i] + si[i] * tables.g_twid9[i];
            overlap[ov_idx + i] = co[i] * tables.g_twid9[i] - si[i] * tables.g_twid9[9 + i];
            grbuf[gr_idx + i] = ovl * window[i] - sum * window[9 + i];
            grbuf[gr_idx + 17 - i] = ovl * window[9 + i] + sum * window[i];
        }
        gr_idx += 18;
        ov_idx += 9;
    }
}

pub fn idct3(x0: f32, x1: f32, x2: f32, dst: *[3]f32) void {
    const m1 = x1 * 0.86602540;
    const a1 = x0 - x2 * 0.5;
    dst[1] = x0 + x2;
    dst[0] = a1 + m1;
    dst[2] = a1 - m1;
}

pub fn imdct12(x: []const f32, dst: []f32, overlap: []f32) void {
    var co: [3]f32 = undefined;
    var si: [3]f32 = undefined;
    idct3(-x[0], x[6] + x[3], x[12] + x[9], &co);
    idct3(x[15], x[12] - x[9], x[6] - x[3], &si);
    si[1] = -si[1];

    for (0..3) |i| {
        const ovl = overlap[i];
        const sum = co[i] * tables.g_twid3[3 + i] + si[i] * tables.g_twid3[i];
        overlap[i] = co[i] * tables.g_twid3[i] - si[i] * tables.g_twid3[3 + i];
        dst[i] = ovl * tables.g_twid3[2 - i] - sum * tables.g_twid3[5 - i];
        dst[5 - i] = ovl * tables.g_twid3[5 - i] + sum * tables.g_twid3[2 - i];
    }
}

pub fn imdctShort(grbuf: []f32, overlap: []f32, nbands: usize) void {
    var gr_idx: usize = 0;
    var ov_idx: usize = 0;
    for (0..nbands) |_| {
        var tmp: [18]f32 = undefined;
        @memcpy(&tmp, grbuf[gr_idx .. gr_idx + 18]);
        @memcpy(grbuf[gr_idx .. gr_idx + 6], overlap[ov_idx .. ov_idx + 6]);
        imdct12(tmp[0..], grbuf[gr_idx + 6 ..], overlap[ov_idx + 6 ..]);
        imdct12(tmp[1..], grbuf[gr_idx + 12 ..], overlap[ov_idx + 6 ..]);
        imdct12(tmp[2..], overlap[ov_idx ..], overlap[ov_idx + 6 ..]);
        gr_idx += 18;
        ov_idx += 9;
    }
}

pub fn changeSign(grbuf: []f32) void {
    var b: usize = 0;
    var ptr: usize = 18;
    while (b < 32) : ({
        b += 2;
        ptr += 36;
    }) {
        var i: usize = 1;
        while (i < 18) : (i += 2) {
            grbuf[ptr + i] = -grbuf[ptr + i];
        }
    }
}

pub fn imdctGranule(
    grbuf: []f32,
    overlap: []f32,
    block_type: u8,
    n_long_bands: usize,
) void {
    if (n_long_bands > 0) {
        imdct36(grbuf, overlap, &tables.g_mdct_window[0], n_long_bands);
    }
    const rem_bands = 32 - n_long_bands;
    const gr_rem = grbuf[18 * n_long_bands ..];
    const ov_rem = overlap[9 * n_long_bands ..];
    if (block_type == header.SHORT_BLOCK_TYPE) {
        imdctShort(gr_rem, ov_rem, rem_bands);
    } else {
        const win_idx = @as(usize, @intFromBool(block_type == header.STOP_BLOCK_TYPE));
        imdct36(gr_rem, ov_rem, &tables.g_mdct_window[win_idx], rem_bands);
    }
}

pub fn dctII(grbuf: []f32, n: usize) void {
    for (0..n) |k| {
        var t: [4][8]f32 = undefined;
        const y = grbuf[k..];

        for (0..8) |i| {
            const x0 = y[i * 18];
            const x1 = y[(15 - i) * 18];
            const x2 = y[(16 + i) * 18];
            const x3 = y[(31 - i) * 18];
            const t0 = x0 + x3;
            const t1 = x1 + x2;
            const t2 = (x1 - x2) * tables.g_sec[3 * i + 0];
            const t3 = (x0 - x3) * tables.g_sec[3 * i + 1];
            t[0][i] = t0 + t1;
            t[1][i] = (t0 - t1) * tables.g_sec[3 * i + 2];
            t[2][i] = t3 + t2;
            t[3][i] = (t3 - t2) * tables.g_sec[3 * i + 2];
        }

        for (0..4) |row| {
            var x0 = t[row][0];
            var x1 = t[row][1];
            var x2 = t[row][2];
            var x3 = t[row][3];
            var x4 = t[row][4];
            var x5 = t[row][5];
            var x6 = t[row][6];
            var x7 = t[row][7];
            const xt = x0 - x7;
            x0 += x7;
            x7 = x1 - x6;
            x1 += x6;
            x6 = x2 - x5;
            x2 += x5;
            x5 = x3 - x4;
            x3 += x4;
            x4 = x0 - x3;
            x0 += x3;
            x3 = x1 - x2;
            x1 += x2;
            t[row][0] = x0 + x1;
            t[row][4] = (x0 - x1) * 0.70710677;
            x5 = x5 + x6;
            x6 = (x6 + x7) * 0.70710677;
            x7 = x7 + xt;
            x3 = (x3 + x4) * 0.70710677;
            x5 -= x7 * 0.198912367;
            x7 += x5 * 0.382683432;
            x5 -= x7 * 0.198912367;
            const nx0 = xt - x6;
            const nxt = xt + x6;
            t[row][1] = (nxt + x7) * 0.50979561;
            t[row][2] = (x4 + x3) * 0.54119611;
            t[row][3] = (nx0 - x5) * 0.60134488;
            t[row][5] = (nx0 + x5) * 0.89997619;
            t[row][6] = (x4 - x3) * 1.30656302;
            t[row][7] = (nxt - x7) * 2.56291556;
        }

        var y_idx: usize = k;
        for (0..7) |i| {
            grbuf[y_idx + 0 * 18] = t[0][i];
            grbuf[y_idx + 1 * 18] = t[2][i] + t[3][i] + t[3][i + 1];
            grbuf[y_idx + 2 * 18] = t[1][i] + t[1][i + 1];
            grbuf[y_idx + 3 * 18] = t[2][i + 1] + t[3][i] + t[3][i + 1];
            y_idx += 4 * 18;
        }
        grbuf[y_idx + 0 * 18] = t[0][7];
        grbuf[y_idx + 1 * 18] = t[2][7] + t[3][7];
        grbuf[y_idx + 2 * 18] = t[1][7];
        grbuf[y_idx + 3 * 18] = t[3][7];
    }
}

pub fn scalePcm(sample: f32) f32 {
    return sample * (1.0 / 32768.0);
}

pub fn synthPair(pcm: []f32, pcm_idx: usize, nch: usize, lins: []const f32, z_idx: usize) void {
    var a: f32 = (lins[z_idx + 14 * 64] - lins[z_idx + 0]) * 29.0;
    a += (lins[z_idx + 1 * 64] + lins[z_idx + 13 * 64]) * 213.0;
    a += (lins[z_idx + 12 * 64] - lins[z_idx + 2 * 64]) * 459.0;
    a += (lins[z_idx + 3 * 64] + lins[z_idx + 11 * 64]) * 2037.0;
    a += (lins[z_idx + 10 * 64] - lins[z_idx + 4 * 64]) * 5153.0;
    a += (lins[z_idx + 5 * 64] + lins[z_idx + 9 * 64]) * 6574.0;
    a += (lins[z_idx + 8 * 64] - lins[z_idx + 6 * 64]) * 37489.0;
    a += lins[z_idx + 7 * 64] * 75038.0;
    pcm[pcm_idx] = scalePcm(a);

    const z2 = z_idx + 2;
    var a2: f32 = lins[z2 + 14 * 64] * 104.0;
    a2 += lins[z2 + 12 * 64] * 1567.0;
    a2 += lins[z2 + 10 * 64] * 9727.0;
    a2 += lins[z2 + 8 * 64] * 64019.0;
    a2 += lins[z2 + 6 * 64] * -9975.0;
    a2 += lins[z2 + 4 * 64] * -45.0;
    a2 += lins[z2 + 2 * 64] * 146.0;
    a2 += lins[z2 + 0 * 64] * -5.0;
    pcm[pcm_idx + 16 * nch] = scalePcm(a2);
}

pub fn synth(
    xl: []const f32,
    xr: []const f32,
    dstl: []f32,
    dstr: []f32,
    nch: usize,
    lins: []f32,
) void {
    const zlin_base = 15 * 64;
    lins[zlin_base + 4 * 15 + 0] = xl[18 * 16];
    lins[zlin_base + 4 * 15 + 1] = xr[18 * 16];
    lins[zlin_base + 4 * 15 + 2] = xl[0];
    lins[zlin_base + 4 * 15 + 3] = xr[0];

    lins[zlin_base + 4 * 31 + 0] = xl[1 + 18 * 16];
    lins[zlin_base + 4 * 31 + 1] = xr[1 + 18 * 16];
    lins[zlin_base + 4 * 31 + 2] = xl[1];
    lins[zlin_base + 4 * 31 + 3] = xr[1];

    synthPair(dstr, 0, nch, lins, 4 * 15 + 1);
    synthPair(dstr, 32 * nch, nch, lins, 4 * 15 + 64 + 1);
    synthPair(dstl, 0, nch, lins, 4 * 15);
    synthPair(dstl, 32 * nch, nch, lins, 4 * 15 + 64);

    var w_idx: usize = 0;
    var i_val: i32 = 14;
    while (i_val >= 0) : (i_val -= 1) {
        const i: usize = @intCast(i_val);
        lins[zlin_base + 4 * i + 0] = xl[18 * (31 - i)];
        lins[zlin_base + 4 * i + 1] = xr[18 * (31 - i)];
        lins[zlin_base + 4 * i + 2] = xl[1 + 18 * (31 - i)];
        lins[zlin_base + 4 * i + 3] = xr[1 + 18 * (31 - i)];
        lins[zlin_base + 4 * (i + 16) + 0] = xl[1 + 18 * (1 + i)];
        lins[zlin_base + 4 * (i + 16) + 1] = xr[1 + 18 * (1 + i)];
        lins[zlin_base + 4 * i - 64 + 2] = xl[18 * (1 + i)];
        lins[zlin_base + 4 * i - 64 + 3] = xr[18 * (1 + i)];

        var a_arr: [4]f32 = undefined;
        var b_arr: [4]f32 = undefined;

        for (0..8) |k| {
            const w0 = tables.g_win[w_idx];
            const w1 = tables.g_win[w_idx + 1];
            w_idx += 2;
            const vz_idx = zlin_base + 4 * i - k * 64;
            const vy_idx = zlin_base + 4 * i - (15 - k) * 64;

            if (k == 0) {
                for (0..4) |j| {
                    b_arr[j] = lins[vz_idx + j] * w1 + lins[vy_idx + j] * w0;
                    a_arr[j] = lins[vz_idx + j] * w0 - lins[vy_idx + j] * w1;
                }
            } else if ((k & 1) != 0) {
                for (0..4) |j| {
                    b_arr[j] += lins[vz_idx + j] * w1 + lins[vy_idx + j] * w0;
                    a_arr[j] += lins[vy_idx + j] * w1 - lins[vz_idx + j] * w0;
                }
            } else {
                for (0..4) |j| {
                    b_arr[j] += lins[vz_idx + j] * w1 + lins[vy_idx + j] * w0;
                    a_arr[j] += lins[vz_idx + j] * w0 - lins[vy_idx + j] * w1;
                }
            }
        }

        dstr[(15 - i) * nch] = scalePcm(a_arr[1]);
        dstr[(17 + i) * nch] = scalePcm(b_arr[1]);
        dstl[(15 - i) * nch] = scalePcm(a_arr[0]);
        dstl[(17 + i) * nch] = scalePcm(b_arr[0]);
        dstr[(47 - i) * nch] = scalePcm(a_arr[3]);
        dstr[(49 + i) * nch] = scalePcm(b_arr[3]);
        dstl[(47 - i) * nch] = scalePcm(a_arr[2]);
        dstl[(49 + i) * nch] = scalePcm(b_arr[2]);
    }
}

pub fn synthGranule(
    qmf_state: []f32,
    grbuf: []f32,
    nbands: usize,
    nch: usize,
    pcm: []f32,
    pcm_offset: usize,
    lins: []f32,
) void {
    for (0..nch) |ch| {
        dctII(grbuf[ch * 576 .. (ch + 1) * 576], nbands);
    }

    @memcpy(lins[0 .. 15 * 64], qmf_state[0 .. 15 * 64]);

    var i: usize = 0;
    while (i < nbands) : (i += 2) {
        const xl = grbuf[i..];
        const xr = grbuf[576 * (nch - 1) + i ..];
        const dstl = pcm[pcm_offset + 32 * nch * i ..];
        const dstr = pcm[pcm_offset + 32 * nch * i + (nch - 1) ..];
        synth(xl, xr, dstl, dstr, nch, lins[i * 64 ..]);
    }

    @memcpy(qmf_state[0 .. 15 * 64], lins[nbands * 64 .. nbands * 64 + 15 * 64]);
}
