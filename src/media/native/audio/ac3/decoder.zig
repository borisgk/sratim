const std = @import("std");
const tables = @import("tables.zig");
const bit_reader = @import("bit_reader.zig");
const bit_allocation = @import("bit_allocation.zig");
const imdct = @import("../imdct.zig");

pub const BitReader = bit_reader.BitReader;
const bitAllocate = bit_allocation.bitAllocate;

pub fn parseExponents(reader: *BitReader, expstr: u2, ngrps: usize, exponent_in: u8, dest: []u8) !u8 {
    var exponent = exponent_in;
    var dest_idx: usize = 0;
    var grp: usize = 0;
    while (grp < ngrps) : (grp += 1) {
        const exps = try reader.readBits(usize, 7);
        if (exps >= 128) return error.InvalidExponentGroup;

        var e = @as(i32, @intCast(exponent)) + tables.EXP_1[exps];
        if (e < 0 or e > 24) return error.ExponentOutOfRange;
        exponent = @intCast(e);
        switch (expstr) {
            tables.EXP_D45 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            tables.EXP_D25 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            tables.EXP_D15 => {
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            else => unreachable,
        }

        e = @as(i32, @intCast(exponent)) + tables.EXP_2[exps];
        if (e < 0 or e > 24) return error.ExponentOutOfRange;
        exponent = @intCast(e);
        switch (expstr) {
            tables.EXP_D45 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            tables.EXP_D25 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            tables.EXP_D15 => {
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            else => unreachable,
        }

        e = @as(i32, @intCast(exponent)) + tables.EXP_3[exps];
        if (e < 0 or e > 24) return error.ExponentOutOfRange;
        exponent = @intCast(e);
        switch (expstr) {
            tables.EXP_D45 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            tables.EXP_D25 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            tables.EXP_D15 => {
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            else => unreachable,
        }
    }
    return exponent;
}

pub fn parseDeltba(reader: *BitReader, deltba: []i8) !void {
    @memset(deltba[0..@min(50, deltba.len)], 0);
    const deltnseg = try reader.readBits(usize, 3);
    var j: usize = 0;
    var seg: usize = 0;
    while (seg <= deltnseg) : (seg += 1) {
        j += try reader.readBits(usize, 5);
        const deltlen = try reader.readBits(usize, 4);
        const raw_delta = try reader.readBits(i32, 3);
        const delta: i8 = @intCast(raw_delta - (if (raw_delta >= 4) @as(i32, 3) else @as(i32, 4)));
        for (0..deltlen) |_| {
            if (j < deltba.len) deltba[j] = delta;
            j += 1;
        }
    }
}

pub const Quantizer = struct {
    q1: [2]f32 = .{ 0.0, 0.0 },
    q2: [2]f32 = .{ 0.0, 0.0 },
    q4: f32 = 0.0,
    q1_ptr: i32 = -1,
    q2_ptr: i32 = -1,
    q4_ptr: i32 = -1,

    pub fn reset(self: *Quantizer) void {
        self.q1_ptr = -1;
        self.q2_ptr = -1;
        self.q4_ptr = -1;
    }
};

pub inline fn ditherGen(lfsr_state: *u32) f32 {
    const s = lfsr_state.*;
    const nstate: u16 = tables.DITHER_LUT[s >> 8] ^ @as(u16, @truncate(s << 8));
    lfsr_state.* = nstate;
    const signed_val: i16 = @bitCast(nstate);
    return @as(f32, @floatFromInt(signed_val));
}

pub fn coeffGet(
    reader: *BitReader,
    coeff: []f32,
    exp: []const u8,
    bap: []const i8,
    quantizer: *Quantizer,
    level: f32,
    dither: bool,
    end: usize,
    lfsr_state: *u32,
) !void {
    var factor: [25]f32 = undefined;
    for (0..25) |i| factor[i] = tables.SCALE_FACTOR[i] * level;

    for (0..end) |i| {
        const bapi = bap[i];
        switch (bapi) {
            0 => {
                if (dither) {
                    coeff[i] = ditherGen(lfsr_state) * tables.LEVEL_3DB * factor[exp[i]];
                } else {
                    coeff[i] = 0.0;
                }
            },
            -1 => {
                if (quantizer.q1_ptr >= 0) {
                    coeff[i] = quantizer.q1[@intCast(quantizer.q1_ptr)] * factor[exp[i]];
                    quantizer.q1_ptr -= 1;
                } else {
                    const code = try reader.readBits(usize, 5);
                    quantizer.q1_ptr = 1;
                    quantizer.q1[0] = tables.Q_1_2[code];
                    quantizer.q1[1] = tables.Q_1_1[code];
                    coeff[i] = tables.Q_1_0[code] * factor[exp[i]];
                }
            },
            -2 => {
                if (quantizer.q2_ptr >= 0) {
                    coeff[i] = quantizer.q2[@intCast(quantizer.q2_ptr)] * factor[exp[i]];
                    quantizer.q2_ptr -= 1;
                } else {
                    const code = try reader.readBits(usize, 7);
                    quantizer.q2_ptr = 1;
                    quantizer.q2[0] = tables.Q_2_2[code];
                    quantizer.q2[1] = tables.Q_2_1[code];
                    coeff[i] = tables.Q_2_0[code] * factor[exp[i]];
                }
            },
            3 => {
                const code = try reader.readBits(usize, 3);
                coeff[i] = tables.Q_3[code] * factor[exp[i]];
            },
            -3 => {
                if (quantizer.q4_ptr == 0) {
                    quantizer.q4_ptr = -1;
                    coeff[i] = quantizer.q4 * factor[exp[i]];
                } else {
                    const code = try reader.readBits(usize, 7);
                    quantizer.q4_ptr = 0;
                    quantizer.q4 = tables.Q_4_1[code];
                    coeff[i] = tables.Q_4_0[code] * factor[exp[i]];
                }
            },
            4 => {
                const code = try reader.readBits(usize, 4);
                coeff[i] = tables.Q_5[code] * factor[exp[i]];
            },
            else => {
                if (bapi > 0) {
                    const ubap: usize = @intCast(bapi);
                    const s_val = try reader.readSignedBits(ubap);
                    const shift: u5 = @intCast(16 - ubap);
                    const mant: f32 = @floatFromInt(s_val << shift);
                    coeff[i] = mant * factor[exp[i]];
                } else {
                    coeff[i] = 0.0;
                }
            },
        }
    }
}

pub fn coeffGetCoupling(
    reader: *BitReader,
    nfchans: usize,
    coeff_scale: []const f32,
    samples: *[6][256]f32,
    quantizer: *Quantizer,
    dithflag: []const bool,
    chincpl: u8,
    cplbndstrc_in: u32,
    cplstrtmant: usize,
    cplendmant: usize,
    cplco_table: *const [5][18]f32,
    cpl_exp: []const u8,
    cpl_bap: []const i8,
    lfsr_state: *u32,
) !void {
    var cplbndstrc = cplbndstrc_in;
    var bnd: usize = 0;
    var i = cplstrtmant;
    var cplco: [5]f32 = undefined;

    while (i < cplendmant) {
        var i_end = i + 12;
        while ((cplbndstrc & 1) != 0) {
            cplbndstrc >>= 1;
            i_end += 12;
        }
        cplbndstrc >>= 1;
        for (0..nfchans) |ch| {
            cplco[ch] = cplco_table[ch][bnd] * coeff_scale[ch];
        }
        bnd += 1;

        while (i < i_end) {
            var cplcoeff: f32 = 0.0;
            const bapi = cpl_bap[i];
            switch (bapi) {
                0 => {
                    const cpl_base = tables.LEVEL_3DB * tables.SCALE_FACTOR[cpl_exp[i]];
                    for (0..nfchans) |ch| {
                        if (((chincpl >> @intCast(ch)) & 1) != 0) {
                            if (dithflag[ch]) {
                                samples[ch][i] = cpl_base * cplco[ch] * ditherGen(lfsr_state);
                            } else {
                                samples[ch][i] = 0.0;
                            }
                        }
                    }
                    i += 1;
                    continue;
                },
                -1 => {
                    if (quantizer.q1_ptr >= 0) {
                        cplcoeff = quantizer.q1[@intCast(quantizer.q1_ptr)];
                        quantizer.q1_ptr -= 1;
                    } else {
                        const code = try reader.readBits(usize, 5);
                        quantizer.q1_ptr = 1;
                        quantizer.q1[0] = tables.Q_1_2[code];
                        quantizer.q1[1] = tables.Q_1_1[code];
                        cplcoeff = tables.Q_1_0[code];
                    }
                },
                -2 => {
                    if (quantizer.q2_ptr >= 0) {
                        cplcoeff = quantizer.q2[@intCast(quantizer.q2_ptr)];
                        quantizer.q2_ptr -= 1;
                    } else {
                        const code = try reader.readBits(usize, 7);
                        quantizer.q2_ptr = 1;
                        quantizer.q2[0] = tables.Q_2_2[code];
                        quantizer.q2[1] = tables.Q_2_1[code];
                        cplcoeff = tables.Q_2_0[code];
                    }
                },
                3 => {
                    const code = try reader.readBits(usize, 3);
                    cplcoeff = tables.Q_3[code];
                },
                -3 => {
                    if (quantizer.q4_ptr == 0) {
                        quantizer.q4_ptr = -1;
                        cplcoeff = quantizer.q4;
                    } else {
                        const code = try reader.readBits(usize, 7);
                        quantizer.q4_ptr = 0;
                        quantizer.q4 = tables.Q_4_1[code];
                        cplcoeff = tables.Q_4_0[code];
                    }
                },
                4 => {
                    const code = try reader.readBits(usize, 4);
                    cplcoeff = tables.Q_5[code];
                },
                else => {
                    if (bapi > 0) {
                        const ubap: usize = @intCast(bapi);
                        const s_val = try reader.readSignedBits(ubap);
                        const shift: u5 = @intCast(16 - ubap);
                        cplcoeff = @floatFromInt(s_val << shift);
                    } else {
                        cplcoeff = 0.0;
                    }
                },
            }

            const cpl_val = cplcoeff * tables.SCALE_FACTOR[cpl_exp[i]];
            for (0..nfchans) |ch| {
                if (((chincpl >> @intCast(ch)) & 1) != 0) {
                    samples[ch][i] = cpl_val * cplco[ch];
                }
            }
            i += 1;
        }
    }
}

pub const Ac3Decoder = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 6,
    acmod: u3 = 7,
    lfeon: u1 = 1,

    delay: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6,
    lfsr_state: u32 = 1,

    chincpl: u8 = 0,
    cplbegf: usize = 0,
    cplendf: usize = 0,
    cplstrtbnd: usize = 0,
    cplstrtmant: usize = 0,
    cplendmant: usize = 0,
    cplbndstrc: u32 = 0,
    ncplbnd: usize = 0,
    cplco: [5][18]f32 = [_][18]f32{[_]f32{0.0} ** 18} ** 5,

    endmant: [5]usize = [_]usize{0} ** 5,
    cpl_exp: [256]u8 = [_]u8{0} ** 256,
    fbw_exp: [5][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 5,
    lfe_exp: [256]u8 = [_]u8{0} ** 256,

    bai: u32 = 0,
    csnroffst: u32 = 0,
    cpl_bai: u32 = 0,
    fbw_bai: [5]u32 = [_]u32{0} ** 5,
    lfe_bai: u32 = 0,
    cplfleak: i32 = 0,
    cplsleak: i32 = 0,

    cpl_bap: [256]i8 = [_]i8{0} ** 256,
    fbw_bap: [5][256]i8 = [_][256]i8{[_]i8{0} ** 256} ** 5,
    lfe_bap: [256]i8 = [_]i8{0} ** 256,
    rematflg: u32 = 0,

    pub fn init() Ac3Decoder {
        return .{};
    }

    /// Decodes a single AC-3 audio frame (1536 samples per channel) into stereo interleaved float PCM.
    /// out_stereo_pcm must have capacity for at least 1536 * 2 = 3072 f32 samples.
    /// Returns 1536 (the number of decoded stereo samples).
    pub fn decodeFrame(self: *Ac3Decoder, bytes: []const u8, out_stereo_pcm: []f32) !usize {
        if (bytes.len < 7) return error.InputBufferTooSmall;
        if (out_stereo_pcm.len < 1536 * 2) return error.OutputBufferTooSmall;

        var reader = BitReader.init(bytes);
        const syncword = try reader.readBits(u16, 16);
        if (syncword != 0x0B77) return error.InvalidSyncword;

        _ = try reader.readBits(u16, 16); // crc1
        const fscod = try reader.readBits(u2, 2);
        if (fscod == 3) return error.InvalidSampleRate;
        self.sample_rate = tables.SAMPLE_RATES[fscod];

        const frmsizecod = try reader.readBits(u6, 6);
        if (frmsizecod >= 38) return error.InvalidFrameSizeCode;

        const bsid = try reader.readBits(u5, 5);
        if (bsid > 10) return error.InvalidBitstreamId;

        const bsmod = try reader.readBits(u3, 3);
        _ = bsmod;
        self.acmod = try reader.readBits(u3, 3);

        if ((self.acmod & 1) != 0 and self.acmod != 1) {
            _ = try reader.readBits(u2, 2); // cmixlev
        }
        if ((self.acmod & 4) != 0) {
            _ = try reader.readBits(u2, 2); // surmixlev
        }
        if (self.acmod == 2) {
            _ = try reader.readBits(u2, 2); // dsurmod
        }

        self.lfeon = try reader.readBit();
        const nfchans = tables.NFCHANS_TBL[self.acmod];
        self.channels = @intCast(nfchans + self.lfeon);

        // BSI extra information
        _ = try reader.readBits(u5, 5); // dialnorm
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // compre
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // langcode
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u7, 7); // audprodie
        if (self.acmod == 0) {
            _ = try reader.readBits(u5, 5); // dialnorm2
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // compr2e
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // langcod2e
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u7, 7); // audprodi2e
        }
        _ = try reader.readBits(u2, 2); // copyrightb + origbs
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // timecod1
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // timecod2
        if ((try reader.readBit()) == 1) { // addbsie
            var addbsil = try reader.readBits(u6, 6);
            while (true) {
                _ = try reader.readBits(u8, 8);
                if (addbsil == 0) break;
                addbsil -= 1;
            }
        }

        // Process 6 audio blocks (each produces 256 time-domain samples per channel)
        for (0..6) |blk| {
            var blksw: [5]u1 = undefined;
            for (0..nfchans) |i| blksw[i] = try reader.readBit();
            var dithflag: [5]bool = undefined;
            for (0..nfchans) |i| dithflag[i] = (try reader.readBit()) == 1;

            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrnge
            if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrng2e

            const cplstre = (try reader.readBit()) == 1;
            if (cplstre) {
                const cplinu = (try reader.readBit()) == 1;
                if (cplinu) {
                    self.chincpl = 0;
                    for (0..nfchans) |i| {
                        if ((try reader.readBit()) == 1) self.chincpl |= @as(u8, 1) << @intCast(i);
                    }
                    if (self.acmod == 2) _ = try reader.readBit(); // phsflginu
                    self.cplbegf = try reader.readBits(usize, 4);
                    self.cplendf = try reader.readBits(usize, 4);
                    if (self.cplendf + 3 < self.cplbegf) return error.InvalidBitstream;
                    const ncplsubnd = self.cplendf + 3 - self.cplbegf;
                    if (ncplsubnd == 0 or ncplsubnd > 18) return error.InvalidBitstream;
                    if (self.cplbegf >= tables.CPL_BND_TAB.len) return error.InvalidBitstream;

                    self.ncplbnd = ncplsubnd;
                    self.cplstrtbnd = tables.CPL_BND_TAB[self.cplbegf];
                    self.cplstrtmant = self.cplbegf * 12 + 37;
                    self.cplendmant = self.cplendf * 12 + 73;

                    self.cplbndstrc = 0;
                    for (0..ncplsubnd - 1) |i| {
                        if ((try reader.readBit()) == 1) {
                            self.cplbndstrc |= @as(u32, 1) << @intCast(i);
                            if (self.ncplbnd > 1) self.ncplbnd -= 1;
                        }
                    }
                } else {
                    self.chincpl = 0;
                }
            }

            if (self.chincpl != 0) {
                for (0..nfchans) |i| {
                    if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                        if ((try reader.readBit()) == 1) {
                            const mstrcplco = 3 * (try reader.readBits(usize, 2));
                            for (0..self.ncplbnd) |b| {
                                const cplcoexp = try reader.readBits(usize, 4);
                                var cplcomant = try reader.readBits(usize, 4);
                                if (cplcoexp == 15) {
                                    cplcomant <<= 14;
                                } else {
                                    cplcomant = (cplcomant | 0x10) << 13;
                                }
                                const sf_idx = cplcoexp + mstrcplco;
                                self.cplco[i][b] = @as(f32, @floatFromInt(cplcomant)) * (if (sf_idx < tables.SCALE_FACTOR.len) tables.SCALE_FACTOR[sf_idx] else 0.0);
                            }
                        }
                    }
                }
            }

            if (self.acmod == 2 and (try reader.readBit()) == 1) { // rematstr
                const end: usize = if (self.chincpl != 0) self.cplstrtmant else 253;
                self.rematflg = 0;
                const remat_bands = [4]usize{ 25, 37, 61, 253 };
                var r_idx: usize = 0;
                while (r_idx < 4) : (r_idx += 1) {
                    const r_bit = try reader.readBit();
                    self.rematflg |= @as(u32, r_bit) << @intCast(r_idx);
                    if (remat_bands[r_idx] >= end) break;
                }
            }

            var cplexpstr: u2 = tables.EXP_REUSE;
            if (self.chincpl != 0) cplexpstr = try reader.readBits(u2, 2);
            var chexpstr: [5]u2 = undefined;
            for (0..nfchans) |i| chexpstr[i] = try reader.readBits(u2, 2);
            var lfeexpstr: u1 = 0;
            if (self.lfeon == 1) lfeexpstr = try reader.readBits(u1, 1);

            for (0..nfchans) |i| {
                if (chexpstr[i] != tables.EXP_REUSE) {
                    if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                        self.endmant[i] = self.cplstrtmant;
                    } else {
                        const chbwcod = try reader.readBits(usize, 6);
                        self.endmant[i] = chbwcod * 3 + 73;
                    }
                }
            }

            var do_bit_alloc: u32 = if (blk == 0) 0xFF else 0;

            if (cplexpstr != tables.EXP_REUSE) {
                do_bit_alloc |= 64;
                if (cplexpstr < 1 or cplexpstr > 3) return error.InvalidBitstream;
                if (self.cplendmant <= self.cplstrtmant) return error.InvalidBitstream;
                const shift: u3 = @intCast(cplexpstr - 1);
                const ncplgrps = (self.cplendmant - self.cplstrtmant) / (@as(usize, 3) << shift);
                const cplabsexp = @as(u8, @intCast((try reader.readBits(u8, 4)) << 1));
                if (self.cplstrtmant >= self.cpl_exp.len) return error.InvalidBitstream;
                _ = try parseExponents(&reader, cplexpstr, ncplgrps, cplabsexp, self.cpl_exp[self.cplstrtmant..]);
            }

            for (0..nfchans) |i| {
                if (chexpstr[i] != tables.EXP_REUSE) {
                    do_bit_alloc |= @as(u32, 1) << @intCast(i);
                    if (chexpstr[i] < 1 or chexpstr[i] > 3) return error.InvalidBitstream;
                    const shift: u3 = @intCast(chexpstr[i] - 1);
                    const grp_size = @as(usize, 3) << shift;
                    if (self.endmant[i] + grp_size < 4) return error.InvalidBitstream;
                    const nchgrps = (self.endmant[i] + grp_size - 4) / grp_size;
                    self.fbw_exp[i][0] = try reader.readBits(u8, 4);
                    _ = try parseExponents(&reader, chexpstr[i], nchgrps, self.fbw_exp[i][0], self.fbw_exp[i][1..]);
                    _ = try reader.readBits(u2, 2); // gainrng
                }
            }

            if (lfeexpstr != tables.EXP_REUSE) {
                do_bit_alloc |= 32;
                self.lfe_exp[0] = try reader.readBits(u8, 4);
                _ = try parseExponents(&reader, lfeexpstr, 2, self.lfe_exp[0], self.lfe_exp[1..]);
            }

            if ((try reader.readBit()) == 1) { self.bai = try reader.readBits(u11, 11); do_bit_alloc = 0xFF; }
            if ((try reader.readBit()) == 1) {
                self.csnroffst = try reader.readBits(u6, 6);
                if (self.chincpl != 0) self.cpl_bai = try reader.readBits(u7, 7);
                for (0..nfchans) |i| self.fbw_bai[i] = try reader.readBits(u7, 7);
                if (self.lfeon == 1) self.lfe_bai = try reader.readBits(u7, 7);
                do_bit_alloc = 0xFF;
            }

            if (self.chincpl != 0 and (try reader.readBit()) == 1) {
                self.cplfleak = 9 - (try reader.readBits(i32, 3));
                self.cplsleak = 9 - (try reader.readBits(i32, 3));
                do_bit_alloc |= 64;
            }

            if ((try reader.readBit()) == 1) { // deltbaie
                do_bit_alloc = 0xFF;
                if (self.chincpl != 0) _ = try reader.readBits(u2, 2);
                for (0..nfchans) |i| {
                    const deltbae = try reader.readBits(u2, 2);
                    if (deltbae == tables.DELTA_BIT_NEW) {
                        var dummy_deltba: [50]i8 = undefined;
                        try parseDeltba(&reader, &dummy_deltba);
                    }
                    _ = i;
                }
            }

            if (do_bit_alloc != 0) {
                if (self.chincpl != 0 and (do_bit_alloc & 64) != 0) {
                    bitAllocate(fscod, 0, self.bai, self.csnroffst, self.cpl_bai, tables.DELTA_BIT_NONE, &tables.ZERO_DELTBA, self.cplstrtbnd, self.cplstrtmant, self.cplendmant, self.cplfleak << 8, self.cplsleak << 8, &self.cpl_exp, &self.cpl_bap);
                }
                for (0..nfchans) |i| {
                    if ((do_bit_alloc & (@as(u32, 1) << @intCast(i))) != 0) {
                        bitAllocate(fscod, 0, self.bai, self.csnroffst, self.fbw_bai[i], tables.DELTA_BIT_NONE, &tables.ZERO_DELTBA, 0, 0, self.endmant[i], 0, 0, &self.fbw_exp[i], &self.fbw_bap[i]);
                    }
                }
                if (self.lfeon == 1 and (do_bit_alloc & 32) != 0) {
                    bitAllocate(fscod, 0, self.bai, self.csnroffst, self.lfe_bai, tables.DELTA_BIT_NONE, &tables.ZERO_DELTBA, 0, 0, 7, 0, 0, &self.lfe_exp, &self.lfe_bap);
                }
            }

            if ((try reader.readBit()) == 1) { // skiple
                var skipl = try reader.readBits(usize, 9);
                while (skipl > 0) : (skipl -= 1) _ = try reader.readBits(u8, 8);
            }

            var quantizer = Quantizer{};
            var block_samples: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6;

            var done_cpl = false;
            for (0..nfchans) |i| {
                try coeffGet(&reader, &block_samples[i], &self.fbw_exp[i], &self.fbw_bap[i], &quantizer, 1.0, dithflag[i], self.endmant[i], &self.lfsr_state);
                if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                    if (!done_cpl) {
                        done_cpl = true;
                        const coeff_scale: [5]f32 = [_]f32{1.0} ** 5;
                        try coeffGetCoupling(&reader, nfchans, &coeff_scale, &block_samples, &quantizer, &dithflag, self.chincpl, self.cplbndstrc, self.cplstrtmant, self.cplendmant, &self.cplco, &self.cpl_exp, &self.cpl_bap, &self.lfsr_state);
                    }
                }
            }

            if (self.lfeon == 1) {
                try coeffGet(&reader, &block_samples[5], &self.lfe_exp, &self.lfe_bap, &quantizer, 1.0, false, 7, &self.lfsr_state);
            }

            // Rematrixing for 2/0 stereo
            if (self.acmod == 2) {
                var j: usize = 0;
                const end_remat = if (self.chincpl != 0) self.cplstrtmant else self.endmant[0];
                const remat_bands = [4]usize{ 25, 37, 61, 253 };
                var b: usize = 0;
                while (j < end_remat and b < 4) : (b += 1) {
                    const endband = @min(remat_bands[b], end_remat);
                    if (((self.rematflg >> @intCast(b)) & 1) != 0) {
                        while (j < endband) : (j += 1) {
                            const left = block_samples[0][j];
                            const right = block_samples[1][j];
                            block_samples[0][j] = left + right;
                            block_samples[1][j] = left - right;
                        }
                    } else {
                        j = endband;
                    }
                }
            }

            // IMDCT transform for each channel
            for (0..nfchans) |i| {
                imdct.imdct512(&block_samples[i], &self.delay[i]);
            }
            if (self.lfeon == 1) {
                imdct.imdct512(&block_samples[5], &self.delay[5]);
            }

            // Downmix block samples to stereo output
            const blk_offset = blk * 256 * 2;
            switch (self.acmod) {
                2 => { // 2.0 Stereo
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = block_samples[1][s];
                    }
                },
                1 => { // 1.0 Mono
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = block_samples[0][s];
                    }
                },
                7 => { // 3/2 Surround (5.1 with LFE)
                    for (0..256) |s| {
                        const l = block_samples[0][s];
                        const c = block_samples[1][s];
                        const r = block_samples[2][s];
                        const ls = block_samples[3][s];
                        const rs = block_samples[4][s];
                        out_stereo_pcm[blk_offset + s * 2 + 0] = l + c * tables.LEVEL_3DB + ls * tables.LEVEL_3DB;
                        out_stereo_pcm[blk_offset + s * 2 + 1] = r + c * tables.LEVEL_3DB + rs * tables.LEVEL_3DB;
                    }
                },
                else => {
                    // General downmix for other channel configurations
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = if (nfchans > 1) block_samples[1][s] else block_samples[0][s];
                    }
                },
            }
        }

        return 1536;
    }
};
