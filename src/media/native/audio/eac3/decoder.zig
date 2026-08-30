const std = @import("std");
const tables = @import("tables.zig");
const ac3_dec = @import("../ac3/decoder.zig");
const bit_reader = @import("../ac3/bit_reader.zig");
const bit_allocation = @import("../ac3/bit_allocation.zig");
const imdct = @import("../imdct.zig");

pub const BitReader = bit_reader.BitReader;
const bitAllocateDirect = bit_allocation.bitAllocateDirect;

pub const Eac3Decoder = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 6,
    acmod: u3 = 7,
    lfeon: u1 = 1,
    num_blocks: usize = 6,

    // Overlap-add delay buffers for up to 6 channels (L, C, R, Ls, Rs, LFE)
    delay: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6,
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
    cplco: [5][18]f32 = [_][18]f32{[_]f32{0.0} ** 18} ** 5,

    // Exponents & bounds
    endmant: [5]usize = [_]usize{0} ** 5,
    cpl_exp: [256]u8 = [_]u8{0} ** 256,
    fbw_exp: [5][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 5,
    lfe_exp: [256]u8 = [_]u8{0} ** 256,

    // Bit allocation state
    bai: u32 = 0,
    snr_offset: [7]i32 = [_]i32{0} ** 7,
    fast_gain: [7]u3 = [_]u3{4} ** 7,
    cplfleak: i32 = 0,
    cplsleak: i32 = 0,

    cpl_bap: [256]i8 = [_]i8{0} ** 256,
    fbw_bap: [5][256]i8 = [_][256]i8{[_]i8{0} ** 256} ** 5,
    lfe_bap: [256]i8 = [_]i8{0} ** 256,
    rematflg: u32 = 0,
    phsflginu: bool = false,
    phase_flags: [18]bool = [_]bool{false} ** 18,
    cpl_band_sizes: [18]u8 = [_]u8{0} ** 18,

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
        } else {
            if ((try reader.readBit()) == 1) { // mixmdate
                if (self.acmod > 2) {
                    _ = try reader.readBits(u2, 2); // dmixmod
                }
                if ((self.acmod & 1) != 0 and self.acmod > 1) { // center channel exists
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
                    if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // pgmclsube
                    if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // pgmclsub2e
                    if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // extpgmclsube
                    const mixdatae = try reader.readBit();
                    if (mixdatae == 1) {
                        var mixdeflen = try reader.readBits(usize, 5);
                        if (mixdeflen == 31) {
                            mixdeflen += try reader.readBits(usize, 6);
                            if (mixdeflen == 31 + 63) {
                                mixdeflen += try reader.readBits(usize, 8);
                            }
                        }
                        for (0..mixdeflen) |_| _ = try reader.readBits(u8, 8);
                    }
                    if ((try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // paninfo
                    if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // paninfo2
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
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u7, 7); // audprodie
            if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u7, 7); // audprodi2e
            _ = try reader.readBit(); // sourcefscod
        }

        if (strmtyp == 0 and self.num_blocks != 6) {
            _ = try reader.readBit(); // convsync (only present when num_blocks != 6)
        }

        if (strmtyp == 2) {
            if ((try reader.readBit()) == 1) { // blkstrtinfoe
                const blkstrtinfo_len = if (self.num_blocks == 6) @as(usize, 44) else @as(usize, self.num_blocks * 8);
                for (0..blkstrtinfo_len) |_| _ = try reader.readBit();
            }
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
        var cpl_strategy_exists: [6]bool = [_]bool{false} ** 6;
        var cpl_in_use: [6]bool = [_]bool{false} ** 6;
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
        var exp_strategy: [6][7]u2 = [_][7]u2{[_]u2{tables.EXP_REUSE} ** 7} ** 6;
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
                if (use_aht) _ = try reader.readBit();
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
        for (0..nfchans) |_| {
            if (parse_spx_atten_data and (try reader.readBit()) == 1) {
                _ = try reader.readBits(u5, 5);
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

        var first_cpl_coords: [5]bool = [_]bool{true} ** 5;

        // --- Process Audio Blocks ---
        for (0..self.num_blocks) |blk| {
            var blksw: [5]u1 = [_]u1{0} ** 5;
            if (block_switch_syntax) {
                for (0..nfchans) |i| blksw[i] = try reader.readBit();
            }

            var dithflag: [5]bool = [_]bool{true} ** 5;
            if (dither_flag_syntax) {
                for (0..nfchans) |i| dithflag[i] = (try reader.readBit()) == 1;
            }

            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrnge
            if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrng2e

            // Spectral extension in use per block
            if (blk == 0 or (try reader.readBit()) == 1) {
                const spx_in_use = (try reader.readBit()) == 1;
                if (spx_in_use) {
                    // SPX strategy
                    for (0..nfchans) |_| _ = try reader.readBit();
                    _ = try reader.readBits(u5, 5); // spxbegf
                    _ = try reader.readBits(u5, 5); // spxendf
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
                    const cpl_end_subband = (try reader.readBits(usize, 4)) + 3;
                    if (cpl_start_subband >= cpl_end_subband) return error.InvalidBitstream;

                    self.cplbegf = cpl_start_subband;
                    self.cplendf = cpl_end_subband;
                    self.cplstrtbnd = tables.CPL_BND_TAB[cpl_start_subband];
                    self.cplstrtmant = cpl_start_subband * 12 + 37;
                    self.cplendmant = cpl_end_subband * 12 + 37;

                    const ncplsubnd = cpl_end_subband - cpl_start_subband;
                    var cpl_bnd_struct: [18]u1 = undefined;
                    for (cpl_start_subband..cpl_end_subband - 1) |sb| {
                        cpl_bnd_struct[sb - cpl_start_subband] = tables.DEFAULT_CPL_BAND_STRUCT[sb];
                    }
                    if ((try reader.readBit()) == 1) { // decode band structure
                        for (0..ncplsubnd - 1) |i| {
                            cpl_bnd_struct[i] = try reader.readBit();
                        }
                    }

                    var cplbndstrc: u32 = 0;
                    for (0..ncplsubnd - 1) |i| {
                        if (cpl_bnd_struct[i] == 1) cplbndstrc |= @as(u32, 1) << @intCast(i);
                    }
                    self.cplbndstrc = cplbndstrc;

                    var n_bands = ncplsubnd;
                    self.cpl_band_sizes[0] = 12;
                    var cur_bnd: usize = 0;
                    for (1..ncplsubnd) |subbnd| {
                        if (cpl_bnd_struct[subbnd - 1] == 1) {
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
                    } else {
                        const chbwcod = try reader.readBits(usize, 6);
                        if (chbwcod > 60) return error.InvalidBitstream;
                        self.endmant[ch] = chbwcod * 3 + 73;
                    }
                } else if (self.endmant[ch] == 0) {
                    self.endmant[ch] = if (((self.chincpl >> @intCast(ch)) & 1) != 0) self.cplstrtmant else 253;
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

            if (snr_offset_strategy != 0) {
                if (blk == 0 or (try reader.readBit()) == 1) {
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
                if (blk == 0 or (try reader.readBit()) == 1) {
                    const fl = try reader.readBits(i32, 3);
                    const sl = try reader.readBits(i32, 3);
                    self.cplfleak = (9 - fl) << 8;
                    self.cplsleak = (9 - sl) << 8;
                }
            }

            // Delta bit allocation
            var deltba: [5][50]i8 = [_][50]i8{[_]i8{0} ** 50} ** 5;
            var cpldeltba: [50]i8 = [_]i8{0} ** 50;
            var cpl_deltbae: usize = tables.DELTA_BIT_NONE;
            if (dba_syntax) {
                if (cpl_in_use[blk]) {
                    cpl_deltbae = try reader.readBits(usize, 2);
                    if (cpl_deltbae == tables.DELTA_BIT_NEW) try ac3_dec.parseDeltba(&reader, &cpldeltba);
                }
                for (0..nfchans) |i| {
                    const deltbae_ch = try reader.readBits(usize, 2);
                    if (deltbae_ch == tables.DELTA_BIT_NEW) try ac3_dec.parseDeltba(&reader, &deltba[i]);
                }
            }

            // Compute BAPs via bitAllocateDirect
            if (cpl_in_use[blk]) {
                bitAllocateDirect(
                    fscod,
                    halfrate,
                    self.bai,
                    self.snr_offset[0],
                    self.fast_gain[0],
                    @intCast(cpl_deltbae),
                    &cpldeltba,
                    self.cplstrtbnd,
                    self.cplstrtmant,
                    self.cplendmant,
                    self.cplfleak,
                    self.cplsleak,
                    &self.cpl_exp,
                    &self.cpl_bap,
                );
            }

            for (0..nfchans) |ch| {
                if (self.endmant[ch] > 0) {
                    bitAllocateDirect(
                        fscod,
                        halfrate,
                        self.bai,
                        self.snr_offset[ch + 1],
                        self.fast_gain[ch + 1],
                        tables.DELTA_BIT_NONE,
                        &tables.ZERO_DELTBA,
                        0,
                        0,
                        self.endmant[ch],
                        0,
                        0,
                        &self.fbw_exp[ch],
                        &self.fbw_bap[ch],
                    );
                }
            }

            if (self.lfeon == 1) {
                bitAllocateDirect(
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
                    &self.lfe_bap,
                );
            }

            if (skip_syntax and (try reader.readBit()) == 1) {
                var skipl = try reader.readBits(usize, 9);
                while (skipl > 0) : (skipl -= 1) _ = try reader.readBits(u8, 8);
            }

            // Transform coefficients
            var block_samples: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6;
            var quantizer = ac3_dec.Quantizer{};
            quantizer.reset();

            var done_cpl = false;
            for (0..nfchans) |i| {
                try ac3_dec.coeffGet(&reader, &block_samples[i], &self.fbw_exp[i], &self.fbw_bap[i], &quantizer, 1.0, dithflag[i], self.endmant[i], &self.lfsr_state);
                if (cpl_in_use[blk] and ((self.chincpl >> @intCast(i)) & 1) != 0) {
                    if (!done_cpl) {
                        done_cpl = true;
                        const coeff_scale: [5]f32 = [_]f32{1.0} ** 5;
                        try ac3_dec.coeffGetCoupling(&reader, nfchans, &coeff_scale, &block_samples, &quantizer, &dithflag, self.chincpl, self.cplbndstrc, self.cplstrtmant, self.cplendmant, &self.cplco, &self.cpl_exp, &self.cpl_bap, &self.lfsr_state);
                    }
                }
            }

            if (self.lfeon == 1) {
                try ac3_dec.coeffGet(&reader, &block_samples[5], &self.lfe_exp, &self.lfe_bap, &quantizer, 1.0, false, 7, &self.lfsr_state);
            }

            // Rematrixing
            if (self.acmod == 2) {
                var j: usize = 13;
                const end_remat = if (cpl_in_use[blk] and self.chincpl != 0) self.cplstrtmant else self.endmant[0];
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

            // Inverse MDCT transform for each channel
            for (0..nfchans) |i| {
                imdct.imdct512(&block_samples[i], &self.delay[i]);
            }
            if (self.lfeon == 1) {
                imdct.imdct512(&block_samples[5], &self.delay[5]);
            }

            // Downmix to Stereo Interleaved PCM for this block
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
                        out_stereo_pcm[blk_offset + s * 2 + 0] = l + c * tables.ac3_tables.LEVEL_3DB + ls * tables.ac3_tables.LEVEL_3DB;
                        out_stereo_pcm[blk_offset + s * 2 + 1] = r + c * tables.ac3_tables.LEVEL_3DB + rs * tables.ac3_tables.LEVEL_3DB;
                    }
                },
                else => {
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = if (nfchans > 1) block_samples[1][s] else block_samples[0][s];
                    }
                },
            }
        }

        return self.num_blocks * 256;
    }
};
