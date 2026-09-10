const std = @import("std");
const tables = @import("tables.zig");
const side_info = @import("side_info.zig");

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
    bs: *side_info.BitStream,
    gr_info: *const side_info.L3GrInfo,
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
