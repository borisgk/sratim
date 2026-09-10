const std = @import("std");
const tables = @import("tables.zig");
const header = @import("header.zig");

pub const MAX_BITRESERVOIR_BYTES = 511;

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
    var sr_idx = header.hdr_get_my_sample_rate(hdr);
    if (sr_idx != 0) sr_idx -= 1;
    var gr_count: usize = if (header.hdr_is_mono(hdr)) 1 else 2;
    var scfsi: u32 = 0;
    var main_data_begin: usize = 0;

    if (header.hdr_test_mpeg1(hdr)) {
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
        if (header.hdr_is_mono(hdr)) {
            scfsi <<= 4;
        }
        gr.part_23_length = @intCast(bs.getBits(12));
        part_23_sum += gr.part_23_length;
        gr.big_values = @intCast(bs.getBits(9));
        if (gr.big_values > 288) return null;
        gr.global_gain = @intCast(bs.getBits(8));
        gr.scalefac_compress = @intCast(bs.getBits(if (header.hdr_test_mpeg1(hdr)) 4 else 9));
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
            if (gr.block_type == header.SHORT_BLOCK_TYPE) {
                scfsi &= 0x0F0F;
                if (gr.mixed_block_flag == 0) {
                    gr.region_count[0] = 8;
                    gr.sfbtab = &tables.g_scf_short[sr_idx];
                    gr.n_long_sfb = 0;
                    gr.n_short_sfb = 39;
                } else {
                    gr.sfbtab = &tables.g_scf_mixed[sr_idx];
                    gr.n_long_sfb = if (header.hdr_test_mpeg1(hdr)) 8 else 6;
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
        gr.preflag = if (header.hdr_test_mpeg1(hdr)) @intCast(bs.getBits(1)) else @intFromBool(gr.scalefac_compress >= 500);
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

    if (header.hdr_test_mpeg1(hdr)) {
        const part = tables.g_scfc_decode[gr.scalefac_compress];
        scf_size[1] = part >> 2;
        scf_size[0] = part >> 2;
        scf_size[3] = part & 3;
        scf_size[2] = part & 3;
    } else {
        const ist: usize = if (header.hdr_test_i_stereo(hdr) and ch != 0) 1 else 0;
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

    const gain_exp: i32 = @as(i32, gr.global_gain) - 4 - 210 - (if (header.hdr_is_ms_stereo(hdr)) @as(i32, 2) else @as(i32, 0));
    const gain = ldexpQ2(2048.0, 44 - gain_exp);
    const total_sfb = @as(usize, gr.n_long_sfb) + @as(usize, gr.n_short_sfb);
    for (0..total_sfb) |i| {
        scf[i] = ldexpQ2(gain, @as(i32, iscf[i]) << scf_shift);
    }
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
