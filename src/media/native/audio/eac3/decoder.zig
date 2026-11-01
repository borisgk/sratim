const std = @import("std");
const tables = @import("tables.zig");
const ac3_dec = @import("../ac3/decoder.zig");
const bit_reader = @import("../bit_reader.zig");
const bit_allocation = @import("../ac3/bit_allocation.zig");
const imdct = @import("../imdct.zig");
const dsp = @import("../dsp.zig");

pub const BitReader = bit_reader.BitReader;
const bitAllocateDirectWithTab = bit_allocation.bitAllocateDirectWithTab;

pub const Eac3Decoder = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 6,
    acmod: u3 = 7,
    lfeon: u1 = 1,
    num_blocks: usize = 6,

    // Overlap-add delay buffers for up to 6 channels (L, C, R, Ls, Rs, LFE)
    delay: [6][256]f32 = @splat(@splat(0.0)),
    lfsr_state: u32 = 1,

    // Coupling state per frame
    chincpl: u8 = 0,
    cplbegf: usize = 0,
    cplendf: usize = 0,
    cplstrtbnd: usize = 0,
    cplstrtmant: usize = 0,
    cplendmant: usize = 0,
    cplbndstrc: u32 = 0,
    ncplbnd: usize = 0,
    cplco: [5][18]f32 = @splat(@splat(0.0)),

    // Exponents & bounds
    endmant: [5]usize = @splat(0),
    cpl_exp: [256]u8 = @splat(0),
    fbw_exp: [5][256]u8 = @splat(@splat(0)),
    lfe_exp: [256]u8 = @splat(0),

    // Bit allocation state
    bai: u32 = 0,
    snr_offset: [7]i32 = @splat(0),
    fast_gain: [7]u3 = @splat(4),
    cplfleak: i32 = 0,
    cplsleak: i32 = 0,

    cpl_bap: [256]i8 = @splat(0),
    fbw_bap: [5][256]i8 = @splat(@splat(0)),
    lfe_bap: [256]i8 = @splat(0),
    rematflg: u32 = 0,
    phsflginu: bool = false,
    phase_flags: [18]bool = @splat(false),
    cpl_band_sizes: [18]u8 = @splat(0),
    cpl_band_struct: [18]u1 = tables.DEFAULT_CPL_BAND_STRUCT,

    // Spectral Extension (SPX) state
    spx_in_use: bool = false,
    channel_uses_spx: [5]bool = @splat(false),
    spx_atten_code: [5]i8 = @splat(-1),
    spx_dst_start_freq: usize = 0,
    spx_src_start_freq: usize = 0,
    spx_dst_end_freq: usize = 0,
    num_spx_bands: usize = 0,
    spx_band_struct: [17]u1 = tables.DEFAULT_SPX_BAND_STRUCT,
    spx_band_sizes: [17]u8 = @splat(0),
    spx_noise_blend: [5][17]f32 = @splat(@splat(0.0)),
    spx_signal_blend: [5][17]f32 = @splat(@splat(0.0)),

    // Delta bit allocation state across blocks
    cpl_deltbae: u2 = tables.DELTA_BIT_NONE,
    cpldeltba: [50]i8 = @splat(0),
    deltbae: [5]u2 = @splat(tables.DELTA_BIT_NONE),
    deltba: [5][50]i8 = @splat(@splat(0)),

    // Adaptive Hybrid Transform (AHT) pre-mantissa buffer: [channel 0..7][blk 0..6][bin 0..256]
    pre_mantissa: [7][6][256]i32 = @splat(@splat(@splat(0))),

    pub fn init() Eac3Decoder {
        return .{};
    }

    /// Decodes a single E-AC-3 audio frame into stereo interleaved float PCM.
    /// out_stereo_pcm must have capacity for at least num_blocks * 256 * 2 f32 samples.
    /// Returns the number of decoded stereo samples (e.g. 1536 for a 6-block frame).
    pub fn decodeFrame(self: *Eac3Decoder, bytes: []const u8, out_stereo_pcm: []f32) !usize {
        if (bytes.len < 7) return error.InputBufferTooSmall;

        var reader = BitReader.init(bytes);
        const syncword = try reader.readBits(u16, 16);
        if (syncword != 0x0B77) return error.InvalidSyncword;

        const strmtyp = try reader.readBits(u2, 2);
        const substreamid = try reader.readBits(u3, 3);
        _ = substreamid;

        const frmsiz = try reader.readBits(u11, 11);

        const fscod = try reader.readBits(u2, 2);
        var halfrate: usize = 0;
        if (fscod == 3) {
            const fscod2 = try reader.readBits(u2, 2);
            if (fscod2 == 3) return error.InvalidSampleRate;
            self.sample_rate = tables.SAMPLE_RATES_HALF[fscod2];
            self.num_blocks = 6;
            halfrate = 1;
        } else {
            self.sample_rate = tables.SAMPLE_RATES[fscod];
            const numblkscod = try reader.readBits(u2, 2);
            self.num_blocks = tables.NUM_BLOCKS[numblkscod];
        }

        self.acmod = try reader.readBits(u3, 3);
        self.lfeon = try reader.readBit();
        const nfchans = tables.NFCHANS_TBL[self.acmod];
        self.channels = @intCast(nfchans + self.lfeon);

        const bsid = try reader.readBits(u5, 5);
        if (bsid < 11 or bsid > 16) return error.InvalidBitstreamId;

        const samples_needed = self.num_blocks * 256 * 2;
        if (out_stereo_pcm.len < samples_needed) return error.OutputBufferTooSmall;

        _ = try reader.readBits(u5, 5); // dialnorm
        if ((try reader.readBit()) == 1) { // compre
            _ = try reader.readBits(u8, 8); // compr
        }

        if (self.acmod == 0) { // dual mono
            _ = try reader.readBits(u5, 5); // dialnorm2
            if ((try reader.readBit()) == 1) {
                _ = try reader.readBits(u8, 8); // compr2
            }
        }

        if (strmtyp == 1) { // dependent stream
            if ((try reader.readBit()) == 1) { // chanmape
                _ = try reader.readBits(u16, 16); // chanmap
            }
        }

        if ((try reader.readBit()) == 1) { // mixmdate
            if (self.acmod > 2) {
                _ = try reader.readBits(u2, 2); // dmixmod
            }
            if ((self.acmod & 1) != 0 and self.acmod > 2) { // three front channels exist
                _ = try reader.readBits(u3, 3); // ltrtcmixlev
                _ = try reader.readBits(u3, 3); // lorocmixlev
            }
            if ((self.acmod & 4) != 0) { // surround channels exist
                _ = try reader.readBits(u3, 3); // ltrtsurmixlev
                _ = try reader.readBits(u3, 3); // lorosurmixlev
            }
            if (self.lfeon == 1) {
                if ((try reader.readBit()) == 1) {
                    _ = try reader.readBits(u5, 5); // lfemixlevcod
                }
            }
            if (strmtyp == 0) {
                if ((try reader.readBit()) == 1) _ = try reader.readBits(u6, 6); // pgmscl
                if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u6, 6); // pgmscl2
                if ((try reader.readBit()) == 1) _ = try reader.readBits(u6, 6); // extpgmscl
                const mixdef = try reader.readBits(u2, 2);
                switch (mixdef) {
                    0 => {},
                    1 => _ = try reader.readBits(u5, 5),
                    2 => _ = try reader.readBits(u12, 12),
                    3 => {
                        const mixdeflen = (@as(usize, try reader.readBits(u5, 5)) + 2) * 8;
                        for (0..mixdeflen) |_| _ = try reader.readBit();
                    },
                }
                if (self.acmod < 2) {
                    if ((try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // paninfo
                    if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // paninfo2
                }
                if ((try reader.readBit()) == 1) { // frmmixcfginfoe
                    if (self.num_blocks == 1) {
                        _ = try reader.readBits(u5, 5);
                    } else {
                        for (0..self.num_blocks) |_| {
                            if ((try reader.readBit()) == 1) _ = try reader.readBits(u5, 5);
                        }
                    }
                }
            }
        }

        const infomdate = (try reader.readBit()) == 1;
        if (infomdate) {
            _ = try reader.readBits(u3, 3); // bsmod
            _ = try reader.readBit(); // copyrightb
            _ = try reader.readBit(); // origbs
            if (self.acmod == 2) {
                _ = try reader.readBits(u2, 2); // dsurmod
                _ = try reader.readBits(u2, 2); // dheadphonmod
            }
            if (self.acmod >= 6) {
                _ = try reader.readBits(u2, 2); // dsurexmod
            }
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // audprodie (mixlevel:5 + roomtyp:2 + adconvtyp:1)
            if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // audprodi2e (mixlevel2:5 + roomtyp2:2 + adconvtyp2:1)
            if (fscod != 3) {
                _ = try reader.readBit(); // sourcefscod
            }
        }

        if (strmtyp == 0 and self.num_blocks != 6) {
            _ = try reader.readBit(); // convsync (only present when num_blocks != 6)
        }

        if (strmtyp == 2 and (self.num_blocks == 6 or (try reader.readBit()) == 1)) {
            _ = try reader.readBits(u6, 6); // blkid / frmsizecod
        }

        const addbsie = (try reader.readBit()) == 1;
        if (addbsie) {
            var addbsil = try reader.readBits(usize, 6);
            while (true) {
                _ = try reader.readBits(u8, 8);
                if (addbsil == 0) break;
                addbsil -= 1;
            }
        }

        // --- Audio Frame Syntax Flags & Strategy (Section E2.3.2) ---
        var ac3_exponent_strategy: u1 = 1;
        var parse_aht_info: u1 = 0;
        if (self.num_blocks == 6) {
            ac3_exponent_strategy = try reader.readBit();
            parse_aht_info = try reader.readBit();
        }

        const snr_offset_strategy = try reader.readBits(u2, 2);
        const parse_transient_proc_info = try reader.readBit();
        const block_switch_syntax = (try reader.readBit()) == 1;
        const dither_flag_syntax = (try reader.readBit()) == 1;
        const bit_allocation_syntax = (try reader.readBit()) == 1;
        const fast_gain_syntax = (try reader.readBit()) == 1;
        const dba_syntax = (try reader.readBit()) == 1;
        const skip_syntax = (try reader.readBit()) == 1;
        const parse_spx_atten_data = (try reader.readBit()) == 1;

        // Coupling strategy occurrence per block
        var cpl_strategy_exists: [6]bool = @splat(false);
        var cpl_in_use: [6]bool = @splat(false);
        var num_cpl_blocks: usize = 0;
        if (self.acmod > 1) {
            for (0..self.num_blocks) |blk| {
                cpl_strategy_exists[blk] = if (blk == 0) true else ((try reader.readBit()) == 1);
                if (cpl_strategy_exists[blk]) {
                    cpl_in_use[blk] = (try reader.readBit()) == 1;
                } else {
                    cpl_in_use[blk] = cpl_in_use[blk - 1];
                }
                if (cpl_in_use[blk]) num_cpl_blocks += 1;
            }
        }

        // Exponent strategies for each block
        var exp_strategy: [6][7]u2 = @splat(@splat(tables.EXP_REUSE));
        if (ac3_exponent_strategy == 1) {
            for (0..self.num_blocks) |blk| {
                const start_ch: usize = if (cpl_in_use[blk]) 0 else 1;
                for (start_ch..nfchans + 1) |ch| {
                    exp_strategy[blk][ch] = try reader.readBits(u2, 2);
                }
            }
        }
        if (ac3_exponent_strategy != 1) {
            // LUT-based exponent strategy
            const start_ch: usize = if (self.acmod > 1 and num_cpl_blocks > 0) 0 else 1;
            for (start_ch..nfchans + 1) |ch| {
                const frmchexpstr = try reader.readBits(usize, 5);
                for (0..self.num_blocks) |blk| {
                    exp_strategy[blk][ch] = tables.EAC3_FRM_EXPSTR[frmchexpstr][blk];
                }
            }
        }

        if (self.lfeon == 1) {
            for (0..self.num_blocks) |blk| {
                exp_strategy[blk][self.channels] = try reader.readBits(u1, 1);
            }
        }

        // Original exponent strategies if converted from AC-3
        if (strmtyp == 0 and (self.num_blocks == 6 or (try reader.readBit()) == 1)) {
            for (0..nfchans) |_| _ = try reader.readBits(u5, 5);
        }

        // AHT info
        var channel_uses_aht: [7]bool = @splat(false);
        if (parse_aht_info == 1) {
            const start_ch: usize = if (num_cpl_blocks != 6) 1 else 0;
            for (start_ch..self.channels + 1) |ch| {
                var use_aht = true;
                for (1..6) |blk| {
                    if (exp_strategy[blk][ch] != tables.EXP_REUSE or (ch == 0 and cpl_strategy_exists[blk])) {
                        use_aht = false;
                        break;
                    }
                }
                if (use_aht) channel_uses_aht[ch] = (try reader.readBit()) == 1;
            }
        }

        // Per-frame SNR offset
        if (snr_offset_strategy == 0) {
            const csnr = (@as(i32, @intCast(try reader.readBits(u32, 6))) - 15) << 4;
            const snr = (csnr + @as(i32, @intCast(try reader.readBits(u32, 4)))) << 2;
            for (0..7) |ch| self.snr_offset[ch] = snr;
        }

        // Transient pre-noise processing info
        if (parse_transient_proc_info == 1) {
            for (0..nfchans) |_| {
                if ((try reader.readBit()) == 1) {
                    _ = try reader.readBits(u10, 10);
                    _ = try reader.readBits(u8, 8);
                }
            }
        }

        // Spectral extension attenuation data
        for (0..nfchans) |ch| {
            if (parse_spx_atten_data and (try reader.readBit()) == 1) {
                self.spx_atten_code[ch] = @intCast(try reader.readBits(u5, 5));
            } else {
                self.spx_atten_code[ch] = -1;
            }
        }

        // Block start info
        if (self.num_blocks > 1 and (try reader.readBit()) == 1) {
            const frame_size_minus_2 = @as(u32, frmsiz) * 2;
            if (frame_size_minus_2 > 0) {
                const log2_val = 31 - @clz(frame_size_minus_2);
                const block_start_bits = (self.num_blocks - 1) * (4 + log2_val);
                for (0..block_start_bits) |_| _ = try reader.readBit();
            }
        }

        // Default bit allocation parameters if bit_allocation_syntax == false
        if (!bit_allocation_syntax) {
            self.bai = (2 << 9) | (1 << 7) | (1 << 5) | (2 << 3) | 7;
        }

        var first_spx_coords: [5]bool = @splat(true);
        var first_cpl_coords: [5]bool = @splat(true);
        var first_cpl_leak: bool = true;

        // --- Process Audio Blocks ---
        for (0..self.num_blocks) |blk| {
            var blksw: [5]u1 = @splat(0);
            if (block_switch_syntax) {
                for (0..nfchans) |i| blksw[i] = try reader.readBit();
            }

            var dithflag: [5]bool = @splat(true);
            if (dither_flag_syntax) {
                for (0..nfchans) |i| dithflag[i] = (try reader.readBit()) == 1;
            }

            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrnge
            if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrng2e

            // Spectral extension strategy per block
            if (blk == 0 or (try reader.readBit()) == 1) {
                self.spx_in_use = (try reader.readBit()) == 1;
                if (self.spx_in_use) {
                    if (self.acmod == 1) {
                        self.channel_uses_spx[0] = true;
                    } else {
                        for (0..nfchans) |ch| {
                            self.channel_uses_spx[ch] = (try reader.readBit()) == 1;
                        }
                    }
                    const dst_start_freq_code = try reader.readBits(usize, 2);
                    var start_subband = (try reader.readBits(usize, 3)) + 2;
                    if (start_subband > 7) start_subband += start_subband - 7;
                    var end_subband = (try reader.readBits(usize, 3)) + 5;
                    if (end_subband > 7) end_subband += end_subband - 7;
                    const dst_start_freq = dst_start_freq_code * 12 + 25;
                    const src_start_freq = start_subband * 12 + 25;
                    const dst_end_freq = end_subband * 12 + 25;
                    if (start_subband >= end_subband) return error.InvalidBitstream;
                    if (dst_start_freq >= src_start_freq) return error.InvalidBitstream;
                    self.spx_dst_start_freq = dst_start_freq;
                    self.spx_src_start_freq = src_start_freq;
                    self.spx_dst_end_freq = dst_end_freq;

                    const n_subbands = end_subband - start_subband;
                    if (blk == 0) {
                        self.spx_band_struct = tables.DEFAULT_SPX_BAND_STRUCT;
                    }
                    if ((try reader.readBit()) == 1) {
                        for (0..n_subbands - 1) |subbnd| {
                            self.spx_band_struct[start_subband + 1 + subbnd] = try reader.readBit();
                        }
                    }
                    var n_bands = n_subbands;
                    self.spx_band_sizes[0] = 12;
                    var bnd: usize = 0;
                    for (1..n_subbands) |subbnd| {
                        if (self.spx_band_struct[start_subband + subbnd] != 0) {
                            n_bands -= 1;
                            self.spx_band_sizes[bnd] += 12;
                        } else {
                            bnd += 1;
                            self.spx_band_sizes[bnd] = 12;
                        }
                    }
                    self.num_spx_bands = n_bands;
                }
            }
            if (!self.spx_in_use) {
                for (0..nfchans) |ch| {
                    self.channel_uses_spx[ch] = false;
                    first_spx_coords[ch] = true;
                }
            }

            // Spectral extension coordinates
            if (self.spx_in_use) {
                for (0..nfchans) |ch| {
                    if (self.channel_uses_spx[ch]) {
                        if (first_spx_coords[ch] or (try reader.readBit()) == 1) {
                            first_spx_coords[ch] = false;
                            const spx_blend = @as(f32, @floatFromInt(try reader.readBits(u5, 5))) * (1.0 / 32.0);
                            const master_spx_coord = @as(usize, try reader.readBits(u2, 2)) * 3;
                            var bin = self.spx_src_start_freq;
                            for (0..self.num_spx_bands) |bnd| {
                                const bandsize: usize = self.spx_band_sizes[bnd];
                                var nratio = (@as(f32, @floatFromInt(bin + (bandsize >> 1))) / @as(f32, @floatFromInt(self.spx_dst_end_freq))) - spx_blend;
                                nratio = std.math.clamp(nratio, 0.0, 1.0);
                                const nblend = @sqrt(3.0 * nratio);
                                const sblend = @sqrt(1.0 - nratio);
                                bin += bandsize;

                                const spx_coord_exp = try reader.readBits(usize, 4);
                                var spx_coord_mant = try reader.readBits(usize, 2);
                                if (spx_coord_exp == 15) {
                                    spx_coord_mant <<= 1;
                                } else {
                                    spx_coord_mant += 4;
                                }
                                const shift_amt: u5 = @intCast(25 - spx_coord_exp - master_spx_coord);
                                spx_coord_mant <<= shift_amt;
                                const spx_coord = @as(f32, @floatFromInt(spx_coord_mant)) * (1.0 / @as(f32, @floatFromInt(@as(u32, 1) << 23)));
                                self.spx_noise_blend[ch][bnd] = nblend * spx_coord;
                                self.spx_signal_blend[ch][bnd] = sblend * spx_coord;
                            }
                        }
                    } else {
                        first_spx_coords[ch] = true;
                    }
                }
            }

            // Coupling strategy per block
            if (cpl_strategy_exists[blk]) {
                if (cpl_in_use[blk]) {
                    // Check for enhanced coupling
                    const ecpl = (try reader.readBit()) == 1;
                    if (ecpl) return error.EnhancedCouplingNotSupported;

                    // Which channels are coupled
                    if (self.acmod == 2) {
                        self.chincpl = 0b11; // both channels coupled in stereo
                    } else {
                        self.chincpl = 0;
                        for (0..nfchans) |i| {
                            if ((try reader.readBit()) == 1) self.chincpl |= @as(u8, 1) << @intCast(i);
                        }
                    }

                    // Phase flags in use
                    if (self.acmod == 2) {
                        self.phsflginu = (try reader.readBit()) == 1;
                    }

                    const cpl_start_subband = try reader.readBits(usize, 4);
                    const cpl_end_subband = if (self.spx_in_use)
                        (self.spx_src_start_freq - 37) / 12
                    else
                        (try reader.readBits(usize, 4)) + 3;
                    if (cpl_start_subband >= cpl_end_subband) return error.InvalidBitstream;

                    self.cplbegf = cpl_start_subband;
                    self.cplendf = cpl_end_subband;
                    self.cplstrtbnd = tables.CPL_BND_TAB[cpl_start_subband];
                    self.cplstrtmant = cpl_start_subband * 12 + 37;
                    self.cplendmant = cpl_end_subband * 12 + 37;

                    const ncplsubnd = cpl_end_subband - cpl_start_subband;
                    if (blk == 0) {
                        self.cpl_band_struct = tables.DEFAULT_CPL_BAND_STRUCT;
                    }
                    if ((try reader.readBit()) == 1) { // decode band structure
                        for (0..ncplsubnd - 1) |i| {
                            self.cpl_band_struct[cpl_start_subband + 1 + i] = try reader.readBit();
                        }
                    }

                    var cplbndstrc: u32 = 0;
                    for (0..ncplsubnd - 1) |i| {
                        if (self.cpl_band_struct[cpl_start_subband + 1 + i] == 1) cplbndstrc |= @as(u32, 1) << @intCast(i);
                    }
                    self.cplbndstrc = cplbndstrc;

                    var n_bands = ncplsubnd;
                    self.cpl_band_sizes[0] = 12;
                    var cur_bnd: usize = 0;
                    for (1..ncplsubnd) |subbnd| {
                        if (self.cpl_band_struct[cpl_start_subband + subbnd] == 1) {
                            n_bands -= 1;
                            self.cpl_band_sizes[cur_bnd] += 12;
                        } else {
                            cur_bnd += 1;
                            self.cpl_band_sizes[cur_bnd] = 12;
                        }
                    }
                    self.ncplbnd = n_bands;
                } else {
                    self.chincpl = 0;
                    for (0..nfchans) |i| first_cpl_coords[i] = true;
                    first_cpl_leak = true;
                    self.phsflginu = false;
                }
            }

            // Coupling coordinates
            var cpl_coords_exist = false;
            if (cpl_in_use[blk]) {
                for (0..nfchans) |i| {
                    if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                        if (first_cpl_coords[i] or (try reader.readBit()) == 1) {
                            first_cpl_coords[i] = false;
                            cpl_coords_exist = true;
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
                    } else {
                        first_cpl_coords[i] = true;
                    }
                }
                // Phase flags
                if (self.acmod == 2 and cpl_coords_exist) {
                    for (0..self.ncplbnd) |b| {
                        self.phase_flags[b] = if (self.phsflginu) (try reader.readBit()) == 1 else false;
                    }
                }
            }

            // Stereo rematrixing
            if (self.acmod == 2) {
                if (blk == 0 or (try reader.readBit()) == 1) {
                    var nrematbnd: usize = 4;
                    if (cpl_in_use[blk] and self.cplstrtmant <= 61) {
                        nrematbnd -= 1 + @as(usize, if (self.cplstrtmant == 37) 1 else 0);
                    } else if (self.spx_in_use and self.spx_src_start_freq <= 61) {
                        nrematbnd -= 1;
                    }
                    self.rematflg = 0;
                    for (0..nrematbnd) |r_idx| {
                        if ((try reader.readBit()) == 1) self.rematflg |= @as(u32, 1) << @intCast(r_idx);
                    }
                }
            }

            // Channel bandwidth for non-reuse exponent strategies
            for (0..nfchans) |ch| {
                if (exp_strategy[blk][ch + 1] != tables.EXP_REUSE) {
                    if (((self.chincpl >> @intCast(ch)) & 1) != 0) {
                        self.endmant[ch] = self.cplstrtmant;
                    } else if (self.channel_uses_spx[ch]) {
                        self.endmant[ch] = self.spx_src_start_freq;
                    } else {
                        const chbwcod = try reader.readBits(usize, 6);
                        if (chbwcod > 60) return error.InvalidBitstream;
                        self.endmant[ch] = chbwcod * 3 + 73;
                    }
                } else if (self.endmant[ch] == 0) {
                    self.endmant[ch] = if (((self.chincpl >> @intCast(ch)) & 1) != 0) self.cplstrtmant else if (self.channel_uses_spx[ch]) self.spx_src_start_freq else 253;
                }
            }

            // Unpack exponents
            if (cpl_in_use[blk] and exp_strategy[blk][0] != tables.EXP_REUSE) {
                const shift: u3 = @intCast(exp_strategy[blk][0] - 1);
                const ncplgrps = (self.cplendmant - self.cplstrtmant) / (@as(usize, 3) << shift);
                const cplabsexp = @as(u8, @intCast((try reader.readBits(u8, 4)) << 1));
                _ = try ac3_dec.parseExponents(&reader, exp_strategy[blk][0], ncplgrps, cplabsexp, self.cpl_exp[self.cplstrtmant..]);
            }

            for (0..nfchans) |ch| {
                if (exp_strategy[blk][ch + 1] != tables.EXP_REUSE) {
                    const shift: u3 = @intCast(exp_strategy[blk][ch + 1] - 1);
                    const group_size = @as(usize, 3) << shift;
                    const nchgrps = (self.endmant[ch] + group_size - 4) / group_size;
                    self.fbw_exp[ch][0] = try reader.readBits(u8, 4);
                    _ = try ac3_dec.parseExponents(&reader, exp_strategy[blk][ch + 1], nchgrps, self.fbw_exp[ch][0], self.fbw_exp[ch][1..]);
                    _ = try reader.readBits(usize, 2); // gainrng
                }
            }

            if (self.lfeon == 1 and exp_strategy[blk][self.channels] != tables.EXP_REUSE) {
                self.lfe_exp[0] = try reader.readBits(u8, 4);
                _ = try ac3_dec.parseExponents(&reader, tables.EXP_D15, 2, self.lfe_exp[0], self.lfe_exp[1..]);
            }

            // Bit allocation information
            if (bit_allocation_syntax) {
                if ((try reader.readBit()) == 1) {
                    const sdcy = try reader.readBits(u32, 2);
                    const fdcy = try reader.readBits(u32, 2);
                    const sgain = try reader.readBits(u32, 2);
                    const dbpb = try reader.readBits(u32, 2);
                    const floor_code = try reader.readBits(u32, 3);
                    self.bai = (sdcy << 9) | (fdcy << 7) | (sgain << 5) | (dbpb << 3) | floor_code;
                }
            }

            if (blk == 0 and snr_offset_strategy != 0) {
                if ((try reader.readBit()) == 1) {
                    const csnr = (@as(i32, @intCast(try reader.readBits(u32, 6))) - 15) << 4;
                    var snr: i32 = 0;
                    const start_ch: usize = if (cpl_in_use[blk]) 0 else 1;
                    for (start_ch..self.channels + 1) |ch| {
                        if (ch == start_ch or snr_offset_strategy == 2) {
                            snr = (csnr + @as(i32, @intCast(try reader.readBits(u32, 4)))) << 2;
                        }
                        self.snr_offset[ch] = snr;
                    }
                }
            }

            if (fast_gain_syntax and (try reader.readBit()) == 1) {
                const start_ch: usize = if (cpl_in_use[blk]) 0 else 1;
                for (start_ch..self.channels + 1) |ch| {
                    self.fast_gain[ch] = try reader.readBits(u3, 3);
                }
            } else if (blk == 0) {
                for (0..7) |ch| self.fast_gain[ch] = 4;
            }

            // Converter SNR offset
            if (strmtyp == 0 and (try reader.readBit()) == 1) {
                _ = try reader.readBits(u10, 10);
            }

            // Coupling leak
            if (cpl_in_use[blk]) {
                if (first_cpl_leak or (try reader.readBit()) == 1) {
                    const fl = try reader.readBits(i32, 3);
                    const sl = try reader.readBits(i32, 3);
                    self.cplfleak = (9 - fl) << 8;
                    self.cplsleak = (9 - sl) << 8;
                }
                first_cpl_leak = false;
            }

            // Delta bit allocation
            if (dba_syntax and (try reader.readBit()) == 1) {
                if (cpl_in_use[blk]) {
                    self.cpl_deltbae = try reader.readBits(u2, 2);
                    if (self.cpl_deltbae == tables.DELTA_BIT_RESERVED) return error.InvalidBitstream;
                }
                for (0..nfchans) |i| {
                    self.deltbae[i] = try reader.readBits(u2, 2);
                    if (self.deltbae[i] == tables.DELTA_BIT_RESERVED) return error.InvalidBitstream;
                }
                if (cpl_in_use[blk] and self.cpl_deltbae == tables.DELTA_BIT_NEW) {
                    try ac3_dec.parseDeltba(&reader, &self.cpldeltba);
                }
                for (0..nfchans) |i| {
                    if (self.deltbae[i] == tables.DELTA_BIT_NEW) {
                        try ac3_dec.parseDeltba(&reader, &self.deltba[i]);
                    }
                }
            } else if (blk == 0) {
                self.cpl_deltbae = tables.DELTA_BIT_NONE;
                for (0..nfchans) |i| self.deltbae[i] = tables.DELTA_BIT_NONE;
            }

            // Compute BAPs via bitAllocateDirectWithTab
            if (cpl_in_use[blk]) {
                const bap_tab = if (channel_uses_aht[0]) &tables.aht_tables.HEBAP_TAB else &tables.BAP_TAB;
                bitAllocateDirectWithTab(
                    fscod,
                    halfrate,
                    self.bai,
                    self.snr_offset[0],
                    self.fast_gain[0],
                    @intCast(self.cpl_deltbae),
                    &self.cpldeltba,
                    self.cplstrtbnd,
                    self.cplstrtmant,
                    self.cplendmant,
                    self.cplfleak,
                    self.cplsleak,
                    &self.cpl_exp,
                    bap_tab,
                    &self.cpl_bap,
                );
            }

            for (0..nfchans) |ch| {
                if (self.endmant[ch] > 0) {
                    const bap_tab = if (channel_uses_aht[ch + 1]) &tables.aht_tables.HEBAP_TAB else &tables.BAP_TAB;
                    bitAllocateDirectWithTab(
                        fscod,
                        halfrate,
                        self.bai,
                        self.snr_offset[ch + 1],
                        self.fast_gain[ch + 1],
                        @intCast(self.deltbae[ch]),
                        &self.deltba[ch],
                        0,
                        0,
                        self.endmant[ch],
                        0,
                        0,
                        &self.fbw_exp[ch],
                        bap_tab,
                        &self.fbw_bap[ch],
                    );
                }
            }

            if (self.lfeon == 1) {
                const bap_tab = if (channel_uses_aht[self.channels]) &tables.aht_tables.HEBAP_TAB else &tables.BAP_TAB;
                bitAllocateDirectWithTab(
                    fscod,
                    halfrate,
                    self.bai,
                    self.snr_offset[self.channels],
                    self.fast_gain[self.channels],
                    tables.DELTA_BIT_NONE,
                    &tables.ZERO_DELTBA,
                    0,
                    0,
                    7,
                    0,
                    0,
                    &self.lfe_exp,
                    bap_tab,
                    &self.lfe_bap,
                );
            }

            if (skip_syntax and (try reader.readBit()) == 1) {
                var skipl = try reader.readBits(usize, 9);
                while (skipl > 0) : (skipl -= 1) _ = try reader.readBits(u8, 8);
            }

            // Transform coefficients
            var block_samples: [6][256]f32 = @splat(@splat(0.0));
            var quantizer = ac3_dec.Quantizer{};
            quantizer.reset();

            var done_cpl = false;
            const V4i = @Vector(4, i32);
            const V4f = @Vector(4, f32);
            const V4b = @Vector(4, i8);
            const v_zero_bap: V4b = @splat(0);
            const v_zero_f: V4f = @splat(0.0);

            for (0..nfchans) |i| {
                if (!channel_uses_aht[i + 1]) {
                    try ac3_dec.coeffGet(&reader, &block_samples[i], &self.fbw_exp[i], &self.fbw_bap[i], &quantizer, 1.0, dithflag[i], self.endmant[i], &self.lfsr_state);
                } else {
                    if (blk == 0) {
                        try self.decodeTransformCoeffsAhtCh(&reader, i + 1, 0, self.endmant[i], &self.fbw_bap[i]);
                    }
                    const end_m = self.endmant[i];
                    const pm_blk = &self.pre_mantissa[i + 1][blk];
                    const exp_ch = &self.fbw_exp[i];
                    var bin: usize = 0;
                    while (bin + 4 <= end_m) : (bin += 4) {
                        const pm_vec: V4i = pm_blk[bin..][0..4].*;
                        const pm_f: V4f = @floatFromInt(pm_vec);
                        const sf_vec = V4f{
                            tables.AHT_SCALE_FACTOR[exp_ch[bin + 0]],
                            tables.AHT_SCALE_FACTOR[exp_ch[bin + 1]],
                            tables.AHT_SCALE_FACTOR[exp_ch[bin + 2]],
                            tables.AHT_SCALE_FACTOR[exp_ch[bin + 3]],
                        };
                        block_samples[i][bin..][0..4].* = pm_f * sf_vec;
                    }
                    while (bin < end_m) : (bin += 1) {
                        block_samples[i][bin] = @as(f32, @floatFromInt(pm_blk[bin])) * tables.AHT_SCALE_FACTOR[exp_ch[bin]];
                    }
                }
                if (cpl_in_use[blk] and ((self.chincpl >> @intCast(i)) & 1) != 0) {
                    if (!done_cpl) {
                        done_cpl = true;
                        const coeff_scale: [5]f32 = @splat(1.0);
                        var signed_cplco = self.cplco;
                        if (self.acmod == 2) {
                            for (0..self.ncplbnd) |b| {
                                if (self.phase_flags[b]) signed_cplco[1][b] = -signed_cplco[1][b];
                            }
                        }
                        if (!channel_uses_aht[0]) {
                            try ac3_dec.coeffGetCoupling(&reader, nfchans, &coeff_scale, &block_samples, &quantizer, &dithflag, self.chincpl, self.cplbndstrc, self.cplstrtmant, self.cplendmant, &signed_cplco, &self.cpl_exp, &self.cpl_bap, &self.lfsr_state);
                        } else {
                            if (blk == 0) {
                                try self.decodeTransformCoeffsAhtCh(&reader, 0, self.cplstrtmant, self.cplendmant, &self.cpl_bap);
                            }
                            const pm_cpl = &self.pre_mantissa[0][blk];
                            var bin = self.cplstrtmant;
                            for (0..self.ncplbnd) |bnd| {
                                const band_end = bin + self.cpl_band_sizes[bnd];
                                while (bin + 4 <= band_end) : (bin += 4) {
                                    const pm_vec: V4i = pm_cpl[bin..][0..4].*;
                                    const pm_f: V4f = @floatFromInt(pm_vec);
                                    const sf_vec = V4f{
                                        tables.AHT_SCALE_FACTOR[self.cpl_exp[bin + 0]],
                                        tables.AHT_SCALE_FACTOR[self.cpl_exp[bin + 1]],
                                        tables.AHT_SCALE_FACTOR[self.cpl_exp[bin + 2]],
                                        tables.AHT_SCALE_FACTOR[self.cpl_exp[bin + 3]],
                                    };
                                    const cpl_vec = pm_f * sf_vec;
                                    const bap_vec: V4b = self.cpl_bap[bin..][0..4].*;
                                    const is_zero_bap = bap_vec == v_zero_bap;
                                    for (0..nfchans) |ch_idx| {
                                        if (((self.chincpl >> @intCast(ch_idx)) & 1) != 0) {
                                            const cplco_vec: V4f = @splat(signed_cplco[ch_idx][bnd]);
                                            const scaled = cpl_vec * cplco_vec;
                                            block_samples[ch_idx][bin..][0..4].* = if (dithflag[ch_idx])
                                                scaled
                                            else
                                                @select(f32, is_zero_bap, v_zero_f, scaled);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (self.lfeon == 1) {
                if (!channel_uses_aht[self.channels]) {
                    try ac3_dec.coeffGet(&reader, &block_samples[5], &self.lfe_exp, &self.lfe_bap, &quantizer, 1.0, false, 7, &self.lfsr_state);
                } else if (blk == 0) {
                    try self.decodeTransformCoeffsAhtCh(&reader, self.channels, 0, 7, &self.lfe_bap);
                }
            }

            // Rematrixing (ATSC A/52 Section 7.5.4)
            if (self.acmod == 2) {
                const end_remat = @min(self.endmant[0], self.endmant[1]);
                ac3_dec.rematrixStereo(self.rematflg, end_remat, &block_samples);
            }

            // Apply Spectral Extension (SPX) to high-frequency bins
            if (self.spx_in_use) {
                self.applySpectralExtension(nfchans, &block_samples);
            }

            // Inverse MDCT transform for each full-bandwidth channel (LFE is not used in stereo downmix)
            for (0..nfchans) |i| {
                imdct.imdct512(&block_samples[i], &self.delay[i]);
            }

            // Downmix to Stereo Interleaved PCM for this block
            const blk_offset = blk * 256 * 2;
            ac3_dec.downmixBlockToStereo(self.acmod, nfchans, &block_samples, out_stereo_pcm[blk_offset..][0..512]);
        }

        return self.num_blocks * 256;
    }

    fn applySpectralExtension(self: *Eac3Decoder, nfchans: usize, block_samples: *[6][256]f32) void {
        var wrapflag: [17]bool = @splat(false);
        wrapflag[0] = true;
        var copy_sizes: [17]usize = @splat(0);
        var num_copy_sections: usize = 0;
        var rms_energy: [17]f32 = @splat(0.0);

        var bin = self.spx_dst_start_freq;
        for (0..self.num_spx_bands) |bnd| {
            const bandsize: usize = self.spx_band_sizes[bnd];
            if (bin + bandsize > self.spx_src_start_freq) {
                copy_sizes[num_copy_sections] = bin - self.spx_dst_start_freq;
                num_copy_sections += 1;
                bin = self.spx_dst_start_freq;
                wrapflag[bnd] = true;
            }
            var i: usize = 0;
            while (i < bandsize) {
                if (bin == self.spx_src_start_freq) {
                    copy_sizes[num_copy_sections] = bin - self.spx_dst_start_freq;
                    num_copy_sections += 1;
                    bin = self.spx_dst_start_freq;
                }
                const copysize = @min(bandsize - i, self.spx_src_start_freq - bin);
                bin += copysize;
                i += copysize;
            }
        }
        copy_sizes[num_copy_sections] = bin - self.spx_dst_start_freq;
        num_copy_sections += 1;

        const V4f = @Vector(4, f32);

        for (0..nfchans) |ch| {
            if (!self.channel_uses_spx[ch]) continue;

            // Copy coeffs from normal bands to extension bands
            bin = self.spx_src_start_freq;
            for (0..num_copy_sections) |i| {
                const csize = copy_sizes[i];
                if (csize > 0 and bin + csize <= 256 and self.spx_dst_start_freq + csize <= 256) {
                    @memcpy(block_samples[ch][bin .. bin + csize], block_samples[ch][self.spx_dst_start_freq .. self.spx_dst_start_freq + csize]);
                }
                bin += csize;
            }

            // Calculate RMS energy for each SPX band (bandsize is a multiple of 12, divisible by 4)
            bin = self.spx_src_start_freq;
            for (0..self.num_spx_bands) |bnd| {
                const bandsize: usize = self.spx_band_sizes[bnd];
                var accum_vec: V4f = @splat(0.0);
                var j: usize = 0;
                while (j + 4 <= bandsize) : (j += 4) {
                    const v: V4f = block_samples[ch][bin + j ..][0..4].*;
                    accum_vec = dsp.mulAdd(V4f, v, v, accum_vec);
                }
                var accum = @reduce(.Add, accum_vec);
                while (j < bandsize) : (j += 1) {
                    const c = block_samples[ch][bin + j];
                    accum += c * c;
                }
                bin += bandsize;
                rms_energy[bnd] = @sqrt(accum / @as(f32, @floatFromInt(bandsize)));
            }

            // Apply a 5-tap notch filter at transitions and wrap points
            if (self.spx_atten_code[ch] >= 0) {
                const atten_tab = tables.SPX_ATTEN_TAB[@intCast(self.spx_atten_code[ch])];
                const tap_vec = V4f{ atten_tab[0], atten_tab[1], atten_tab[2], atten_tab[1] };
                bin = self.spx_src_start_freq - 2;
                for (0..self.num_spx_bands) |bnd| {
                    if (wrapflag[bnd] and bin + 5 <= 256) {
                        const cur_vec: V4f = block_samples[ch][bin..][0..4].*;
                        block_samples[ch][bin..][0..4].* = cur_vec * tap_vec;
                        block_samples[ch][bin + 4] *= atten_tab[0];
                    }
                    bin += self.spx_band_sizes[bnd];
                }
            }

            // Apply noise-blended coefficient scaling (bandsize is a multiple of 12, divisible by 4)
            bin = self.spx_src_start_freq;
            for (0..self.num_spx_bands) |bnd| {
                const nscale = self.spx_noise_blend[ch][bnd] * rms_energy[bnd] * (1.0 / 32768.0);
                const sscale = self.spx_signal_blend[ch][bnd];
                const v_nscale: V4f = @splat(nscale);
                const v_sscale: V4f = @splat(sscale);
                const bandsize: usize = self.spx_band_sizes[bnd];
                var j: usize = 0;
                while (j + 4 <= bandsize) : (j += 4) {
                    const d_vec = V4f{
                        ac3_dec.ditherGen(&self.lfsr_state),
                        ac3_dec.ditherGen(&self.lfsr_state),
                        ac3_dec.ditherGen(&self.lfsr_state),
                        ac3_dec.ditherGen(&self.lfsr_state),
                    };
                    const s_vec: V4f = block_samples[ch][bin + j ..][0..4].*;
                    block_samples[ch][bin + j ..][0..4].* = dsp.mulAdd(V4f, s_vec, v_sscale, d_vec * v_nscale);
                }
                while (j < bandsize) : (j += 1) {
                    const noise = nscale * ac3_dec.ditherGen(&self.lfsr_state);
                    block_samples[ch][bin + j] = block_samples[ch][bin + j] * sscale + noise;
                }
                bin += bandsize;
            }
        }
    }

    inline fn idct6(pre_mant: *[6]i32) void {
        const COEFF_0: i64 = 10273905;
        const COEFF_1: i64 = 11863283;
        const COEFF_2: i64 = 3070444;

        const odd1: i32 = pre_mant[1] - pre_mant[3] - pre_mant[5];
        var even2: i32 = @intCast((@as(i64, pre_mant[2]) * COEFF_0) >> 23);
        var tmp: i32 = @intCast((@as(i64, pre_mant[4]) * COEFF_1) >> 23);
        var odd0: i32 = @intCast((@as(i64, pre_mant[1] + pre_mant[5]) * COEFF_2) >> 23);

        var even0: i32 = pre_mant[0] + (tmp >> 1);
        const even1: i32 = pre_mant[0] - tmp;

        tmp = even0;
        even0 = tmp + even2;
        even2 = tmp - even2;

        tmp = odd0;
        odd0 = tmp + pre_mant[1] + pre_mant[3];
        const odd2: i32 = tmp + pre_mant[5] - pre_mant[3];

        pre_mant[0] = even0 + odd0;
        pre_mant[1] = even1 + odd1;
        pre_mant[2] = even2 + odd2;
        pre_mant[3] = even2 - odd2;
        pre_mant[4] = even1 - odd1;
        pre_mant[5] = even0 - odd0;
    }

    fn decodeTransformCoeffsAhtCh(
        self: *Eac3Decoder,
        reader: *BitReader,
        ch: usize,
        start_freq: usize,
        end_freq: usize,
        bap: *const [256]i8,
    ) !void {
        const gaq_mode = try reader.readBits(u2, 2);
        const end_bap: i8 = if (gaq_mode < 2) 12 else 17;

        var gaq_gain: [256]u8 = @splat(0);
        var gs: usize = 0;

        if (gaq_mode == 1 or gaq_mode == 2) {
            const shift: u3 = @intCast(gaq_mode - 1);
            for (start_freq..end_freq) |bin| {
                if (bap[bin] > 7 and bap[bin] < end_bap) {
                    gaq_gain[gs] = @as(u8, try reader.readBit()) << shift;
                    gs += 1;
                }
            }
        } else if (gaq_mode == 3) {
            var gc: usize = 2;
            for (start_freq..end_freq) |bin| {
                if (bap[bin] > 7 and bap[bin] < 17) {
                    if (gc == 2) {
                        const group_code = try reader.readBits(usize, 5);
                        if (gs + 2 < gaq_gain.len) {
                            gaq_gain[gs..][0..3].* = tables.aht_tables.GAQ_UNGROUP_TAB[group_code];
                        }
                        gs += 3;
                        gc = 0;
                    } else {
                        gc += 1;
                    }
                }
            }
        }

        gs = 0;
        for (start_freq..end_freq) |bin| {
            const hebap: usize = @intCast(@max(@as(i8, 0), bap[bin]));
            const bits: usize = tables.aht_tables.BITS_VS_HEBAP[hebap];
            var pre_mant: [6]i32 = undefined;

            if (hebap == 0) {
                inline for (0..6) |blk| {
                    pre_mant[blk] = @as(i32, @intFromFloat(ac3_dec.ditherGen(&self.lfsr_state))) << 7;
                }
            } else if (hebap < 8) {
                const v = try reader.readBits(usize, bits);
                const vq_vec: @Vector(6, i16) = tables.aht_tables.MANTISSA_VQ[hebap][v];
                pre_mant = @as(@Vector(6, i32), vq_vec) << @splat(8);
            } else {
                const log_gain: usize = if (gaq_mode != 0 and bap[bin] < end_bap) blk_lg: {
                    const lg = gaq_gain[gs];
                    gs += 1;
                    break :blk_lg lg;
                } else 0;
                const gbits: usize = bits - log_gain;

                for (0..6) |blk| {
                    var mant: i32 = try reader.readSignedBits(gbits);
                    if (log_gain != 0 and mant == -(@as(i32, 1) << @intCast(gbits - 1))) {
                        const mbits: usize = bits - (2 - log_gain);
                        mant = try reader.readSignedBits(mbits);
                        mant = @bitCast(@as(u32, @bitCast(mant)) << @intCast(23 - (mbits - 1)));
                        const b: i32 = if (mant >= 0)
                            @as(i32, 1) << @intCast(23 - log_gain)
                        else
                            @as(i32, tables.aht_tables.GAQ_REMAP_2_4_B[hebap - 8][log_gain - 1]) << 8;
                        mant += @intCast((@as(i64, tables.aht_tables.GAQ_REMAP_2_4_A[hebap - 8][log_gain - 1]) * @as(i64, mant)) >> 15);
                        mant += b;
                    } else {
                        mant = @bitCast(@as(u32, @bitCast(mant)) << @intCast(24 - bits));
                        if (log_gain == 0) {
                            mant += @intCast((@as(i64, tables.aht_tables.GAQ_REMAP_1[hebap - 8]) * @as(i64, mant)) >> 15);
                        }
                    }
                    pre_mant[blk] = mant;
                }
            }
            idct6(&pre_mant);
            inline for (0..6) |blk| {
                self.pre_mantissa[ch][blk][bin] = pre_mant[blk];
            }
        }
    }
};
