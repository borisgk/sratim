const std = @import("std");
const tables = @import("tables.zig");

pub const MAX_BITRESERVOIR_BYTES = 511;
pub const SHORT_BLOCK_TYPE = 2;
pub const STOP_BLOCK_TYPE = 3;
pub const MODE_MONO = 3;
pub const MODE_JOINT_STEREO = 1;
pub const HDR_SIZE = 4;
pub const MAX_FREE_FORMAT_FRAME_SIZE = 2304;

pub fn hdr_is_mono(h: []const u8) bool {
    return (h[3] & 0xC0) == 0xC0;
}
pub fn hdr_is_ms_stereo(h: []const u8) bool {
    return (h[3] & 0xE0) == 0x60;
}
pub fn hdr_is_free_format(h: []const u8) bool {
    return (h[2] & 0xF0) == 0;
}
pub fn hdr_is_crc(h: []const u8) bool {
    return (h[1] & 1) == 0;
}
pub fn hdr_test_padding(h: []const u8) bool {
    return (h[2] & 0x02) != 0;
}
pub fn hdr_test_mpeg1(h: []const u8) bool {
    return (h[1] & 0x08) != 0;
}
pub fn hdr_test_not_mpeg25(h: []const u8) bool {
    return (h[1] & 0x10) != 0;
}
pub fn hdr_test_i_stereo(h: []const u8) bool {
    return (h[3] & 0x10) != 0;
}
pub fn hdr_test_ms_stereo(h: []const u8) bool {
    return (h[3] & 0x20) != 0;
}
pub fn hdr_get_stereo_mode(h: []const u8) u8 {
    return (h[3] >> 6) & 3;
}
pub fn hdr_get_stereo_mode_ext(h: []const u8) u8 {
    return (h[3] >> 4) & 3;
}
pub fn hdr_get_layer(h: []const u8) u8 {
    return (h[1] >> 1) & 3;
}
pub fn hdr_get_bitrate(h: []const u8) u8 {
    return (h[2] >> 4) & 15;
}
pub fn hdr_get_sample_rate(h: []const u8) u8 {
    return (h[2] >> 2) & 3;
}
pub fn hdr_get_my_sample_rate(h: []const u8) usize {
    const sr = hdr_get_sample_rate(h);
    const m1: usize = (h[1] >> 3) & 1;
    const m25: usize = (h[1] >> 4) & 1;
    return sr + (m1 + m25) * 3;
}
pub fn hdr_is_frame_576(h: []const u8) bool {
    return (h[1] & 14) == 2;
}
pub fn hdr_is_layer_1(h: []const u8) bool {
    return (h[1] & 6) == 6;
}

pub fn hdr_valid(h: []const u8) bool {
    if (h.len < 4) return false;
    return h[0] == 0xFF and
        ((h[1] & 0xF0) == 0xF0 or (h[1] & 0xFE) == 0xE2) and
        (hdr_get_layer(h) != 0) and
        (hdr_get_bitrate(h) != 15) and
        (hdr_get_sample_rate(h) != 3);
}

pub fn hdr_compare(h1: []const u8, h2: []const u8) bool {
    return hdr_valid(h2) and
        ((h1[1] ^ h2[1]) & 0xFE) == 0 and
        ((h1[2] ^ h2[2]) & 0x0C) == 0 and
        (hdr_is_free_format(h1) == hdr_is_free_format(h2));
}

pub fn hdr_bitrate_kbps(h: []const u8) u32 {
    const is_m1: usize = if (hdr_test_mpeg1(h)) 1 else 0;
    const l = hdr_get_layer(h);
    if (l == 0) return 0;
    const br_idx = hdr_get_bitrate(h);
    if (br_idx >= 15) return 0;
    return @as(u32, 2) * @as(u32, tables.halfrate[is_m1][l - 1][br_idx]);
}

pub fn hdr_sample_rate_hz(h: []const u8) u32 {
    const sr_idx = hdr_get_sample_rate(h);
    if (sr_idx >= 3) return 44100;
    var hz = tables.g_hz[sr_idx];
    if (!hdr_test_mpeg1(h)) hz >>= 1;
    if (!hdr_test_not_mpeg25(h)) hz >>= 1;
    return hz;
}

pub fn hdr_frame_samples(h: []const u8) usize {
    if (hdr_is_layer_1(h)) return 384;
    return if (hdr_is_frame_576(h)) 576 else 1152;
}

pub fn hdr_frame_bytes(h: []const u8, free_format_size: usize) usize {
    const hz = hdr_sample_rate_hz(h);
    if (hz == 0) return free_format_size;
    var fb = (hdr_frame_samples(h) * hdr_bitrate_kbps(h) * 125) / hz;
    if (hdr_is_layer_1(h)) fb &= ~@as(usize, 3);
    return if (fb > 0) fb else free_format_size;
}

pub fn hdr_padding(h: []const u8) usize {
    if (!hdr_test_padding(h)) return 0;
    return if (hdr_is_layer_1(h)) 4 else 1;
}

pub const BitStream = struct {
    buf: []const u8,
    pos: usize,
    limit: usize,

    pub fn init(buf: []const u8) BitStream {
        return .{
            .buf = buf,
            .pos = 0,
            .limit = buf.len * 8,
        };
    }

    pub fn getBits(self: *BitStream, n: usize) u32 {
        if (n == 0) return 0;
        const s: usize = self.pos & 7;
        var shl: i32 = @intCast(n + s);
        var p_idx: usize = self.pos >> 3;
        self.pos += n;
        if (self.pos > self.limit) return 0;
        if (p_idx >= self.buf.len) return 0;

        var next: u32 = @as(u32, self.buf[p_idx]) & (@as(u32, 255) >> @intCast(s));
        p_idx += 1;
        var cache: u32 = 0;
        while (shl - 8 > 0) {
            shl -= 8;
            cache |= next << @intCast(shl);
            next = if (p_idx < self.buf.len) self.buf[p_idx] else 0;
            p_idx += 1;
        }
        shl -= 8;
        return cache | (next >> @intCast(-shl));
    }
};

pub const L3GrInfo = struct {
    sfbtab: []const u8 = &.{},
    part_23_length: u16 = 0,
    big_values: u16 = 0,
    scalefac_compress: u16 = 0,
    global_gain: u8 = 0,
    block_type: u8 = 0,
    mixed_block_flag: u8 = 0,
    n_long_sfb: u8 = 0,
    n_short_sfb: u8 = 0,
    table_select: [3]u8 = .{ 0, 0, 0 },
    region_count: [3]u8 = .{ 0, 0, 0 },
    subblock_gain: [3]u8 = .{ 0, 0, 0 },
    preflag: u8 = 0,
    scalefac_scale: u8 = 0,
    count1_table: u8 = 0,
    scfsi: u8 = 0,
};

pub fn readSideInfo(bs: *BitStream, gr_info: []L3GrInfo, hdr: []const u8) ?usize {
    var sr_idx = hdr_get_my_sample_rate(hdr);
    if (sr_idx != 0) sr_idx -= 1;
    var gr_count: usize = if (hdr_is_mono(hdr)) 1 else 2;
    var scfsi: u32 = 0;
    var main_data_begin: usize = 0;

    if (hdr_test_mpeg1(hdr)) {
        gr_count *= 2;
        main_data_begin = bs.getBits(9);
        scfsi = bs.getBits(7 + gr_count);
    } else {
        main_data_begin = bs.getBits(8 + gr_count) >> @intCast(gr_count);
    }

    var part_23_sum: usize = 0;
    var gr_idx: usize = 0;
    while (gr_idx < gr_count) : (gr_idx += 1) {
        const gr = &gr_info[gr_idx];
        if (hdr_is_mono(hdr)) {
            scfsi <<= 4;
        }
        gr.part_23_length = @intCast(bs.getBits(12));
        part_23_sum += gr.part_23_length;
        gr.big_values = @intCast(bs.getBits(9));
        if (gr.big_values > 288) return null;
        gr.global_gain = @intCast(bs.getBits(8));
        gr.scalefac_compress = @intCast(bs.getBits(if (hdr_test_mpeg1(hdr)) 4 else 9));
        gr.sfbtab = &tables.g_scf_long[sr_idx];
        gr.n_long_sfb = 22;
        gr.n_short_sfb = 0;

        var tables_val: u32 = 0;
        if (bs.getBits(1) != 0) {
            gr.block_type = @intCast(bs.getBits(2));
            if (gr.block_type == 0) return null;
            gr.mixed_block_flag = @intCast(bs.getBits(1));
            gr.region_count[0] = 7;
            gr.region_count[1] = 255;
            if (gr.block_type == SHORT_BLOCK_TYPE) {
                scfsi &= 0x0F0F;
                if (gr.mixed_block_flag == 0) {
                    gr.region_count[0] = 8;
                    gr.sfbtab = &tables.g_scf_short[sr_idx];
                    gr.n_long_sfb = 0;
                    gr.n_short_sfb = 39;
                } else {
                    gr.sfbtab = &tables.g_scf_mixed[sr_idx];
                    gr.n_long_sfb = if (hdr_test_mpeg1(hdr)) 8 else 6;
                    gr.n_short_sfb = 30;
                }
            }
            tables_val = bs.getBits(10) << 5;
            gr.subblock_gain[0] = @intCast(bs.getBits(3));
            gr.subblock_gain[1] = @intCast(bs.getBits(3));
            gr.subblock_gain[2] = @intCast(bs.getBits(3));
        } else {
            gr.block_type = 0;
            gr.mixed_block_flag = 0;
            tables_val = bs.getBits(15);
            gr.region_count[0] = @intCast(bs.getBits(4));
            gr.region_count[1] = @intCast(bs.getBits(3));
            gr.region_count[2] = 255;
        }

        gr.table_select[0] = @intCast(tables_val >> 10);
        gr.table_select[1] = @intCast((tables_val >> 5) & 31);
        gr.table_select[2] = @intCast(tables_val & 31);
        gr.preflag = if (hdr_test_mpeg1(hdr)) @intCast(bs.getBits(1)) else @intFromBool(gr.scalefac_compress >= 500);
        gr.scalefac_scale = @intCast(bs.getBits(1));
        gr.count1_table = @intCast(bs.getBits(1));
        gr.scfsi = @intCast((scfsi >> 12) & 15);
        scfsi <<= 4;
    }

    if (part_23_sum + bs.pos > bs.limit + main_data_begin * 8) return null;
    return main_data_begin;
}

pub fn ldexpQ2(initial_y: f32, initial_exp_q2: i32) f32 {
    var y = initial_y;
    var exp_q2 = initial_exp_q2;
    while (exp_q2 > 0) {
        const e = @min(30 * 4, exp_q2);
        const shift: u5 = @intCast(e >> 2);
        const factor: f32 = tables.g_expfrac[@as(usize, @intCast(e & 3))] * @as(f32, @floatFromInt(@as(u32, 1) << 30 >> shift));
        y *= factor;
        exp_q2 -= e;
    }
    return y;
}

pub fn readScalefactors(
    scf: []u8,
    ist_pos: []u8,
    scf_size: []const u8,
    scf_count: []const u8,
    bitbuf: *BitStream,
    initial_scfsi: i32,
) void {
    var scfsi = initial_scfsi;
    var scf_ptr: usize = 0;
    var ist_ptr: usize = 0;

    var i: usize = 0;
    while (i < 4 and i < scf_count.len and scf_count[i] != 0) : ({
        i += 1;
        scfsi *= 2;
    }) {
        const cnt = scf_count[i];
        if ((scfsi & 8) != 0) {
            @memcpy(scf[scf_ptr .. scf_ptr + cnt], ist_pos[ist_ptr .. ist_ptr + cnt]);
        } else {
            const bits = scf_size[i];
            if (bits == 0) {
                @memset(scf[scf_ptr .. scf_ptr + cnt], 0);
                @memset(ist_pos[ist_ptr .. ist_ptr + cnt], 0);
            } else {
                const max_scf: i32 = if (scfsi < 0) (@as(i32, 1) << @intCast(bits)) - 1 else -1;
                for (0..cnt) |k| {
                    const s: i32 = @intCast(bitbuf.getBits(bits));
                    ist_pos[ist_ptr + k] = if (s == max_scf) 0xFF else @intCast(s);
                    scf[scf_ptr + k] = @intCast(s);
                }
            }
        }
        ist_ptr += cnt;
        scf_ptr += cnt;
    }
    scf[scf_ptr] = 0;
    scf[scf_ptr + 1] = 0;
    scf[scf_ptr + 2] = 0;
}

pub fn decodeScalefactors(
    hdr: []const u8,
    ist_pos: []u8,
    bs: *BitStream,
    gr: *const L3GrInfo,
    scf: []f32,
    ch: usize,
) void {
    const partition_idx = @as(usize, @intFromBool(gr.n_short_sfb != 0)) + @as(usize, @intFromBool(gr.n_long_sfb == 0));
    var scf_partition: []const u8 = &tables.g_scf_partitions[partition_idx];
    var scf_size: [4]u8 = undefined;
    var iscf: [40]u8 = undefined;
    const scf_shift: u5 = @intCast(gr.scalefac_scale + 1);
    var scfsi: i32 = gr.scfsi;

    if (hdr_test_mpeg1(hdr)) {
        const part = tables.g_scfc_decode[gr.scalefac_compress];
        scf_size[1] = part >> 2;
        scf_size[0] = part >> 2;
        scf_size[3] = part & 3;
        scf_size[2] = part & 3;
    } else {
        const ist: usize = if (hdr_test_i_stereo(hdr) and ch != 0) 1 else 0;
        var sfc: i32 = @intCast(gr.scalefac_compress >> @intCast(ist));
        var k: usize = ist * 3 * 4;
        while (sfc >= 0) : (k += 4) {
            var modprod: i32 = 1;
            var i: i32 = 3;
            while (i >= 0) : (i -= 1) {
                const ui: usize = @intCast(i);
                scf_size[ui] = @intCast(@mod(@divTrunc(sfc, modprod), tables.g_mod[k + ui]));
                modprod *= tables.g_mod[k + ui];
            }
            sfc -= modprod;
        }
        scf_partition = scf_partition[k..];
        scfsi = -16;
    }

    readScalefactors(&iscf, ist_pos, &scf_size, scf_partition, bs, scfsi);

    if (gr.n_short_sfb != 0) {
        const sh: u3 = @intCast(3 - scf_shift);
        var i: usize = 0;
        while (i < gr.n_short_sfb) : (i += 3) {
            iscf[gr.n_long_sfb + i + 0] += @as(u8, gr.subblock_gain[0]) << sh;
            iscf[gr.n_long_sfb + i + 1] += @as(u8, gr.subblock_gain[1]) << sh;
            iscf[gr.n_long_sfb + i + 2] += @as(u8, gr.subblock_gain[2]) << sh;
        }
    } else if (gr.preflag != 0) {
        for (0..10) |i| {
            iscf[11 + i] += tables.g_preamp[i];
        }
    }

    const gain_exp: i32 = @as(i32, gr.global_gain) - 4 - 210 - (if (hdr_is_ms_stereo(hdr)) @as(i32, 2) else @as(i32, 0));
    const gain = ldexpQ2(2048.0, 44 - gain_exp);
    const total_sfb = @as(usize, gr.n_long_sfb) + @as(usize, gr.n_short_sfb);
    for (0..total_sfb) |i| {
        scf[i] = ldexpQ2(gain, @as(i32, iscf[i]) << scf_shift);
    }
}

pub fn pow43(x_in: i32) f32 {
    var x = x_in;
    if (x < 129) {
        return tables.g_pow43[@as(usize, @intCast(16 + x))];
    }
    var mult: f32 = 256.0;
    if (x < 1024) {
        mult = 16.0;
        x <<= 3;
    }
    const sign: i32 = (2 * x) & 64;
    const num: f32 = @floatFromInt((x & 63) - sign);
    const den: f32 = @floatFromInt((x & ~@as(i32, 63)) + sign);
    const frac: f32 = num / den;
    const base_idx = @as(usize, @intCast(16 + ((x + sign) >> 6)));
    return tables.g_pow43[base_idx] * (1.0 + frac * ((4.0 / 3.0) + frac * (2.0 / 9.0))) * mult;
}

pub const HuffmanBitReader = struct {
    buf: []const u8,
    ptr_idx: usize,
    cache: u32,
    sh: i32,

    pub fn init(buf: []const u8, start_pos: usize) HuffmanBitReader {
        const p = start_pos / 8;
        const b0: u32 = if (p < buf.len) buf[p] else 0;
        const b1: u32 = if (p + 1 < buf.len) buf[p + 1] else 0;
        const b2: u32 = if (p + 2 < buf.len) buf[p + 2] else 0;
        const b3: u32 = if (p + 3 < buf.len) buf[p + 3] else 0;
        const shift: u5 = @intCast(start_pos & 7);
        const cache = (((b0 * 256 + b1) * 256 + b2) * 256 + b3) << shift;
        return .{
            .buf = buf,
            .ptr_idx = p + 4,
            .cache = cache,
            .sh = @as(i32, @intCast(shift)) - 8,
        };
    }

    pub inline fn peekBits(self: *const HuffmanBitReader, n: u5) u32 {
        if (n == 0) return 0;
        const shift: u5 = @intCast(31 - (n - 1));
        return self.cache >> shift;
    }

    pub inline fn flushBits(self: *HuffmanBitReader, n: u5) void {
        self.cache <<= n;
        self.sh += n;
    }

    pub inline fn checkBits(self: *HuffmanBitReader) void {
        while (self.sh >= 0) {
            const next_byte: u32 = if (self.ptr_idx < self.buf.len) self.buf[self.ptr_idx] else 0;
            self.ptr_idx += 1;
            self.cache |= next_byte << @intCast(self.sh);
            self.sh -= 8;
        }
    }

    pub inline fn bsPos(self: *const HuffmanBitReader) usize {
        const signed_pos = @as(i64, @intCast(self.ptr_idx * 8)) - 24 + self.sh;
        return if (signed_pos > 0) @intCast(signed_pos) else 0;
    }
};

pub fn decodeHuffman(
    dst_slice: []f32,
    bs: *BitStream,
    gr_info: *const L3GrInfo,
    scf_slice: []const f32,
    layer3gr_limit: usize,
) void {
    var hbr = HuffmanBitReader.init(bs.buf, bs.pos);
    var one: f32 = 0.0;
    var ireg: usize = 0;
    var big_val_cnt: i32 = @intCast(gr_info.big_values);
    var sfb_idx: usize = 0;
    var scf_idx: usize = 0;
    var dst_idx: usize = 0;

    while (big_val_cnt > 0) {
        const tab_num = gr_info.table_select[ireg];
        var sfb_cnt: i32 = @intCast(gr_info.region_count[ireg]);
        ireg += 1;
        const codebook_offset = @as(usize, @intCast(tables.tabindex[tab_num]));
        const linbits: u5 = @intCast(tables.g_linbits[tab_num]);

        if (linbits > 0) {
            while (true) {
                const np: i32 = if (sfb_idx < gr_info.sfbtab.len) @as(i32, @intCast(gr_info.sfbtab[sfb_idx] / 2)) else 0;
                sfb_idx += 1;
                var pairs_to_decode: usize = @intCast(@min(big_val_cnt, np));
                one = if (scf_idx < scf_slice.len) scf_slice[scf_idx] else 0.0;
                scf_idx += 1;

                while (pairs_to_decode > 0) : (pairs_to_decode -= 1) {
                    var w: u5 = 5;
                    var leaf: i32 = tables.tabs[codebook_offset + hbr.peekBits(w)];
                    while (leaf < 0) {
                        hbr.flushBits(w);
                        w = @intCast(leaf & 7);
                        const idx = @as(usize, @intCast(@as(i32, @intCast(hbr.peekBits(w))) - (leaf >> 3)));
                        leaf = tables.tabs[codebook_offset + idx];
                    }
                    hbr.flushBits(@intCast(@as(u32, @intCast(leaf)) >> 8));

                    var j: usize = 0;
                    while (j < 2) : (j += 1) {
                        var lsb = leaf & 0x0F;
                        if (lsb == 15) {
                            lsb += @as(i32, @intCast(hbr.peekBits(linbits)));
                            hbr.flushBits(linbits);
                            hbr.checkBits();
                            const sign: f32 = if (@as(i32, @bitCast(hbr.cache)) < 0) -1.0 else 1.0;
                            if (dst_idx < dst_slice.len) {
                                dst_slice[dst_idx] = one * pow43(lsb) * sign;
                                dst_idx += 1;
                            }
                        } else {
                            const sign_offset: i32 = if ((hbr.cache >> 31) != 0) 16 else 0;
                            const pow_idx = @as(usize, @intCast(16 + lsb - sign_offset));
                            if (dst_idx < dst_slice.len) {
                                dst_slice[dst_idx] = tables.g_pow43[pow_idx] * one;
                                dst_idx += 1;
                            }
                        }
                        hbr.flushBits(if (lsb != 0) 1 else 0);
                        leaf >>= 4;
                    }
                    hbr.checkBits();
                }

                big_val_cnt -= np;
                sfb_cnt -= 1;
                if (big_val_cnt <= 0 or sfb_cnt < 0) break;
            }
        } else {
            while (true) {
                const np: i32 = if (sfb_idx < gr_info.sfbtab.len) @as(i32, @intCast(gr_info.sfbtab[sfb_idx] / 2)) else 0;
                sfb_idx += 1;
                var pairs_to_decode: usize = @intCast(@min(big_val_cnt, np));
                one = if (scf_idx < scf_slice.len) scf_slice[scf_idx] else 0.0;
                scf_idx += 1;

                while (pairs_to_decode > 0) : (pairs_to_decode -= 1) {
                    var w: u5 = 5;
                    var leaf: i32 = tables.tabs[codebook_offset + hbr.peekBits(w)];
                    while (leaf < 0) {
                        hbr.flushBits(w);
                        w = @intCast(leaf & 7);
                        const idx = @as(usize, @intCast(@as(i32, @intCast(hbr.peekBits(w))) - (leaf >> 3)));
                        leaf = tables.tabs[codebook_offset + idx];
                    }
                    hbr.flushBits(@intCast(@as(u32, @intCast(leaf)) >> 8));

                    var j: usize = 0;
                    while (j < 2) : (j += 1) {
                        const lsb = leaf & 0x0F;
                        const sign_offset: i32 = if ((hbr.cache >> 31) != 0) 16 else 0;
                        const pow_idx = @as(usize, @intCast(16 + lsb - sign_offset));
                        if (dst_idx < dst_slice.len) {
                            dst_slice[dst_idx] = tables.g_pow43[pow_idx] * one;
                            dst_idx += 1;
                        }
                        hbr.flushBits(if (lsb != 0) 1 else 0);
                        leaf >>= 4;
                    }
                    hbr.checkBits();
                }

                big_val_cnt -= np;
                sfb_cnt -= 1;
                if (big_val_cnt <= 0 or sfb_cnt < 0) break;
            }
        }
    }

    var np_cnt: i32 = 1 - big_val_cnt;
    while (dst_idx + 3 < 576) : (dst_idx += 4) {
        var leaf: u32 = if (gr_info.count1_table != 0)
            tables.tab33[hbr.peekBits(4)]
        else
            tables.tab32[hbr.peekBits(4)];

        if ((leaf & 8) == 0) {
            const extra_bits: u5 = @intCast(leaf & 3);
            const extra_val: u32 = if (extra_bits > 0) ((hbr.cache << 4) >> @as(u5, @intCast(31 - (extra_bits - 1)))) else 0;
            const idx = (leaf >> 3) + extra_val;
            leaf = if (gr_info.count1_table != 0) tables.tab33[idx] else tables.tab32[idx];
        }
        hbr.flushBits(@intCast(leaf & 7));
        if (hbr.bsPos() > layer3gr_limit) break;

        np_cnt -= 1;
        if (np_cnt == 0) {
            const next_np = if (sfb_idx < gr_info.sfbtab.len) @as(i32, @intCast(gr_info.sfbtab[sfb_idx] / 2)) else 0;
            sfb_idx += 1;
            if (next_np == 0) break;
            np_cnt = next_np;
            one = if (scf_idx < scf_slice.len) scf_slice[scf_idx] else 0.0;
            scf_idx += 1;
        }

        if ((leaf & 128) != 0) {
            dst_slice[dst_idx + 0] = if (@as(i32, @bitCast(hbr.cache)) < 0) -one else one;
            hbr.flushBits(1);
        }
        if ((leaf & 64) != 0) {
            dst_slice[dst_idx + 1] = if (@as(i32, @bitCast(hbr.cache)) < 0) -one else one;
            hbr.flushBits(1);
        }

        np_cnt -= 1;
        if (np_cnt == 0) {
            const next_np = if (sfb_idx < gr_info.sfbtab.len) @as(i32, @intCast(gr_info.sfbtab[sfb_idx] / 2)) else 0;
            sfb_idx += 1;
            if (next_np == 0) break;
            np_cnt = next_np;
            one = if (scf_idx < scf_slice.len) scf_slice[scf_idx] else 0.0;
            scf_idx += 1;
        }

        if ((leaf & 32) != 0) {
            dst_slice[dst_idx + 2] = if (@as(i32, @bitCast(hbr.cache)) < 0) -one else one;
            hbr.flushBits(1);
        }
        if ((leaf & 16) != 0) {
            dst_slice[dst_idx + 3] = if (@as(i32, @bitCast(hbr.cache)) < 0) -one else one;
            hbr.flushBits(1);
        }
        hbr.checkBits();
    }

    bs.pos = layer3gr_limit;
}

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
    const max_pos: u32 = if (hdr_test_mpeg1(hdr)) 7 else 64;
    var l_idx: usize = 0;
    var i: usize = 0;
    while (i < sfb.len and sfb[i] != 0) : (i += 1) {
        const ipos: u32 = ist_pos[i];
        const band_len = sfb[i];
        if (@as(i32, @intCast(i)) > max_band[i % 3] and ipos < max_pos) {
            const s: f32 = if (hdr_test_ms_stereo(hdr)) 1.41421356 else 1.0;
            var kl: f32 = undefined;
            var kr: f32 = undefined;
            if (hdr_test_mpeg1(hdr)) {
                kl = tables.g_pan[2 * ipos];
                kr = tables.g_pan[2 * ipos + 1];
            } else {
                kl = 1.0;
                kr = ldexpQ2(1.0, @intCast(((ipos + 1) >> 1) << mpeg2_sh));
                if ((ipos & 1) != 0) {
                    kl = kr;
                    kr = 1.0;
                }
            }
            intensityStereoBand(left[l_idx..], right[l_idx..], band_len, kl * s, kr * s);
        } else if (hdr_test_ms_stereo(hdr)) {
            midsideStereo(left[l_idx..], right[l_idx..], band_len);
        }
        l_idx += band_len;
    }
}

pub fn intensityStereo(
    left: []f32,
    right: []f32,
    ist_pos: []u8,
    gr: *const L3GrInfo,
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
        const default_pos: u8 = if (hdr_test_mpeg1(hdr)) 3 else 0;
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
    if (block_type == SHORT_BLOCK_TYPE) {
        imdctShort(gr_rem, ov_rem, rem_bands);
    } else {
        const win_idx = @as(usize, @intFromBool(block_type == STOP_BLOCK_TYPE));
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

pub fn restoreReservoir(
    reserv: *usize,
    reserv_buf: []u8,
    bs: *BitStream,
    maindata: []u8,
    main_data_begin: usize,
) BitStream {
    const frame_bytes = (bs.limit - bs.pos) / 8;
    const bytes_have = @min(reserv.*, main_data_begin);
    const start = if (reserv.* >= main_data_begin) reserv.* - main_data_begin else 0;
    @memcpy(maindata[0..bytes_have], reserv_buf[start .. start + bytes_have]);
    const frame_data = bs.buf[bs.pos / 8 .. bs.pos / 8 + frame_bytes];
    @memcpy(maindata[bytes_have .. bytes_have + frame_bytes], frame_data);
    return BitStream.init(maindata[0 .. bytes_have + frame_bytes]);
}

pub fn saveReservoir(
    reserv: *usize,
    reserv_buf: []u8,
    main_bs: *const BitStream,
    maindata: []const u8,
) void {
    var pos = (main_bs.pos + 7) / 8;
    var remains: usize = if (main_bs.limit / 8 > pos) main_bs.limit / 8 - pos else 0;
    if (remains > MAX_BITRESERVOIR_BYTES) {
        pos += remains - MAX_BITRESERVOIR_BYTES;
        remains = MAX_BITRESERVOIR_BYTES;
    }
    if (remains > 0) {
        @memcpy(reserv_buf[0..remains], maindata[pos .. pos + remains]);
    }
    reserv.* = remains;
}

pub fn matchFrame(hdr: []const u8, mp3_bytes: usize, frame_bytes: usize) bool {
    var i: usize = 0;
    var nmatch: usize = 0;
    while (nmatch < 10) : (nmatch += 1) {
        i += hdr_frame_bytes(hdr[i..], frame_bytes) + hdr_padding(hdr[i..]);
        if (i + HDR_SIZE > mp3_bytes) return nmatch > 0;
        if (!hdr_compare(hdr, hdr[i..])) return false;
    }
    return true;
}

pub fn findFrame(
    mp3: []const u8,
    free_format_bytes: *usize,
    ptr_frame_bytes: *usize,
) usize {
    if (mp3.len < HDR_SIZE) {
        ptr_frame_bytes.* = 0;
        return mp3.len;
    }
    const max_search = mp3.len - HDR_SIZE;
    for (0..max_search) |i| {
        const h = mp3[i..];
        if (hdr_valid(h)) {
            const fb = hdr_frame_bytes(h, free_format_bytes.*);
            const frame_and_padding = fb + hdr_padding(h);

            if ((fb != 0 and i + frame_and_padding <= mp3.len and matchFrame(h, mp3.len - i, fb)) or
                (i == 0 and frame_and_padding == mp3.len))
            {
                ptr_frame_bytes.* = frame_and_padding;
                return i;
            }
            free_format_bytes.* = 0;
        }
    }
    ptr_frame_bytes.* = 0;
    return mp3.len;
}

pub const Mp3Decoder = struct {
    sample_rate: u32 = 44100,
    channels: u16 = 2,
    bitrate_kbps: u16 = 128,

    mdct_overlap: [2][9 * 32]f32 = std.mem.zeroes([2][9 * 32]f32),
    qmf_state: [15 * 2 * 32]f32 = std.mem.zeroes([15 * 2 * 32]f32),
    reserv: usize = 0,
    free_format_bytes: usize = 0,
    header: [4]u8 = [_]u8{0} ** 4,
    reserv_buf: [511]u8 = [_]u8{0} ** 511,

    pub fn init() Mp3Decoder {
        return .{};
    }

    pub fn reset(self: *Mp3Decoder) void {
        self.* = .{};
    }

    pub fn decodeFrame(
        self: *Mp3Decoder,
        in_payload: []const u8,
        out_interleaved: []f32,
    ) !usize {
        if (in_payload.len == 0) return error.BufferTooSmall;
        if (out_interleaved.len < 1152 * 2) return error.BufferTooSmall;

        var frame_size: usize = 0;
        var offset: usize = 0;

        if (in_payload.len > 4 and self.header[0] == 0xFF and hdr_compare(&self.header, in_payload)) {
            frame_size = hdr_frame_bytes(in_payload, self.free_format_bytes) + hdr_padding(in_payload);
            if (frame_size != in_payload.len and (frame_size + HDR_SIZE > in_payload.len or !hdr_compare(in_payload, in_payload[frame_size..]))) {
                frame_size = 0;
            }
        }

        if (frame_size == 0) {
            self.reset();
            offset = findFrame(in_payload, &self.free_format_bytes, &frame_size);
            if (frame_size == 0 or offset + frame_size > in_payload.len) {
                return error.InvalidData;
            }
        }

        const hdr = in_payload[offset .. offset + HDR_SIZE];
        @memcpy(&self.header, hdr);
        const nch: usize = if (hdr_is_mono(hdr)) 1 else 2;
        self.channels = @intCast(nch);
        self.sample_rate = hdr_sample_rate_hz(hdr);
        self.bitrate_kbps = @intCast(hdr_bitrate_kbps(hdr));

        var bs_frame = BitStream.init(in_payload[offset + HDR_SIZE .. offset + frame_size]);
        if (hdr_is_crc(hdr)) {
            _ = bs_frame.getBits(16);
        }

        var gr_info: [4]L3GrInfo = [_]L3GrInfo{.{}} ** 4;
        const mdb_opt = readSideInfo(&bs_frame, &gr_info, hdr);
        if (mdb_opt == null or bs_frame.pos > bs_frame.limit) {
            self.reset();
            return error.InvalidData;
        }
        const main_data_begin = mdb_opt.?;

        var maindata: [MAX_BITRESERVOIR_BYTES + 2304]u8 = undefined;
        var main_bs = restoreReservoir(&self.reserv, &self.reserv_buf, &bs_frame, &maindata, main_data_begin);
        const have_full_reservoir = self.reserv >= main_data_begin;

        if (have_full_reservoir) {
            const n_gr: usize = if (hdr_test_mpeg1(hdr)) 2 else 1;
            var grbuf: [2 * 576]f32 = undefined;
            var ist_pos: [2][39]u8 = undefined;
            var scf: [40]f32 = undefined;
            var syn_buf: [(18 + 15) * 64]f32 = undefined;

            for (0..n_gr) |igr| {
                @memset(&grbuf, 0.0);

                const gr_ptr = gr_info[igr * nch .. (igr + 1) * nch];
                for (0..nch) |ch| {
                    const layer3gr_limit = main_bs.pos + gr_ptr[ch].part_23_length;
                    decodeScalefactors(hdr, &ist_pos[ch], &main_bs, &gr_ptr[ch], &scf, ch);
                    decodeHuffman(grbuf[ch * 576 .. (ch + 1) * 576], &main_bs, &gr_ptr[ch], &scf, layer3gr_limit);
                }

                if (hdr_test_i_stereo(hdr)) {
                    intensityStereo(grbuf[0..576], grbuf[576..1152], &ist_pos[1], &gr_ptr[0], hdr, gr_ptr[1].scalefac_compress);
                } else if (hdr_is_ms_stereo(hdr)) {
                    midsideStereo(grbuf[0..576], grbuf[576..1152], 576);
                }

                for (0..nch) |ch| {
                    const grbuf_ch = grbuf[ch * 576 .. (ch + 1) * 576];
                    var aa_bands: usize = 31;
                    const sr_shift: u5 = @intCast(@intFromBool(hdr_get_my_sample_rate(hdr) == 2));
                    const n_long_bands: usize = (if (gr_ptr[ch].mixed_block_flag != 0) @as(usize, 2) else @as(usize, 0)) << sr_shift;

                    if (gr_ptr[ch].n_short_sfb != 0) {
                        aa_bands = if (n_long_bands > 0) n_long_bands - 1 else 0;
                        reorder(grbuf_ch[n_long_bands * 18 ..], syn_buf[0..], gr_ptr[ch].sfbtab[gr_ptr[ch].n_long_sfb ..]);
                    }

                    antialias(grbuf_ch, aa_bands);
                    imdctGranule(grbuf_ch, &self.mdct_overlap[ch], gr_ptr[ch].block_type, n_long_bands);
                    changeSign(grbuf_ch);
                }

                const pcm_granule_offset = igr * 576 * nch;
                synthGranule(&self.qmf_state, &grbuf, 18, nch, out_interleaved, pcm_granule_offset, &syn_buf);
            }
        }

        saveReservoir(&self.reserv, &self.reserv_buf, &main_bs, &maindata);

        const total_samples = hdr_frame_samples(hdr);

        // If mono, upmix mono channel in-place to stereo interleaved
        if (nch == 1) {
            var i: usize = total_samples;
            while (i > 0) {
                i -= 1;
                const s = out_interleaved[i];
                out_interleaved[i * 2] = s;
                out_interleaved[i * 2 + 1] = s;
            }
        }

        return total_samples;
    }
};

test "Mp3Decoder initialization and reset" {
    var dec = Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    dec.reset();
}

test "Mp3Decoder decodeFrame valid MPEG-1 Layer III frame" {
    var dec = Mp3Decoder.init();
    var frame_bytes: [417]u8 = std.mem.zeroes([417]u8);
    // Standard 128kbps 44.1kHz Joint Stereo MPEG-1 Layer III header
    frame_bytes[0] = 0xFF;
    frame_bytes[1] = 0xFB;
    frame_bytes[2] = 0x90;
    frame_bytes[3] = 0x64;

    var out_pcm: [1152 * 2]f32 = undefined;
    const n_samples = try dec.decodeFrame(&frame_bytes, &out_pcm);
    try std.testing.expectEqual(@as(usize, 1152), n_samples);
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    try std.testing.expectEqual(@as(u16, 128), dec.bitrate_kbps);
}
