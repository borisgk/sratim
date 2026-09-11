// Pure Zig DTS Core (DCA) Synthesis Filterbank - ETSI TS 102 114
const std = @import("std");
const tables = @import("tables.zig");

pub const MAX_LFE_HISTORY: usize = 8;
pub const SUBBAND_HISTORY_SIZE: usize = 512;

pub const Idct32 = struct {
    const cs: [15]f64 = blk: {
        @setEvalBranchQuota(10000);
        var res: [15]f64 = undefined;
        var base: usize = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const p: usize = @as(usize, 1) << @intCast(i);
            var j: usize = 0;
            while (j < p) : (j += 1) {
                const angle = std.math.pi * @as(f64, @floatFromInt(4 * j + 1)) * @as(f64, @floatFromInt(8 >> @intCast(i))) / 32.0;
                res[base + j] = @cos(angle);
            }
            base += p;
        }
        break :blk res;
    };

    const ac: [16]f64 = blk: {
        var res: [16]f64 = undefined;
        for (0..16) |i| {
            const a = std.math.pi * (1.0 / (32.0 * 4.0) + @as(f64, @floatFromInt(i)) / (32.0 * 2.0));
            res[i] = 0.25 * @cos(a);
        }
        break :blk res;
    };

    const as: [16]f64 = blk: {
        var res: [16]f64 = undefined;
        for (0..16) |i| {
            const a = std.math.pi * (1.0 / (32.0 * 4.0) + @as(f64, @floatFromInt(i)) / (32.0 * 2.0));
            res[i] = 0.25 * @sin(a);
        }
        break :blk res;
    };

    const permute: [16]usize = blk: {
        var res: [16]usize = [_]usize{0} ** 16;
        var i: usize = 1;
        while (i < 15) : (i += 1) {
            var k: usize = 0;
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                k = (k << 1) | ((i >> @intCast(j)) & 1);
            }
            res[i] = k;
        }
        break :blk res;
    };

    fn proc(x: *[16]f64, flag: bool) void {
        var y: [16]f64 = x.*;

        // Stage 1: i = 2 (f0=4, f1=2, f2=1, f3=6)
        const K1 = [7]usize{ 6, 5, 4, 3, 2, 1, 0 };
        inline for (K1) |k| {
            const p = 3 + k * 2;
            const q = 1 + k * 2;
            y[q] -= y[p];
            y[p] += y[p];
        }

        // Stage 2: i = 1 (f0=8, f1=4, f2=2, f3=2)
        const K2 = [3]usize{ 2, 1, 0 };
        inline for (K2) |k| {
            // j = 2
            const p2 = 6 + k * 4;
            const q2 = 2 + k * 4;
            y[q2] -= y[p2];
            y[p2] += y[p2];
            // j = 1
            const p1 = 7 + k * 4;
            const q1 = 3 + k * 4;
            y[q1] -= y[p1];
            y[p1] += y[p1];
        }

        // Stage 3: i = 0 (f0=16, f1=8, f2=4, f3=0)
        inline for ([4]usize{ 4, 3, 2, 1 }) |j| {
            const p = 16 - j;
            const q = 8 - j;
            y[q] -= y[p];
            y[p] += y[p];
        }

        // Bit-reversal permutation (unrolled)
        inline for (1..15) |idx| {
            const k = permute[idx];
            if (idx < k) {
                const tmp = y[idx];
                y[idx] = y[k];
                y[k] = tmp;
            }
        }

        // Butterfly stage (unrolled)
        // lvl = 0: p = 1, q = 2, base = 0
        inline for (0..8) |step| {
            const k = step * 2;
            const tmp = y[k + 1] * cs[0];
            y[k + 1] = y[k] - tmp;
            y[k] += tmp;
        }

        // lvl = 1: p = 2, q = 4, base = 1
        inline for (0..2) |j| {
            const c = cs[1 + j];
            inline for (0..4) |step| {
                const k = j + step * 4;
                const tmp = y[k + 2] * c;
                y[k + 2] = y[k] - tmp;
                y[k] += tmp;
            }
        }

        // lvl = 2: p = 4, q = 8, base = 3
        inline for (0..4) |j| {
            const c = cs[3 + j];
            inline for (0..2) |step| {
                const k = j + step * 8;
                const tmp = y[k + 4] * c;
                y[k + 4] = y[k] - tmp;
                y[k] += tmp;
            }
        }

        // lvl = 3: p = 8, q = 16, base = 7
        inline for (0..8) |j| {
            const c = cs[7 + j];
            const tmp = y[j + 8] * c;
            y[j + 8] = y[j] - tmp;
            y[j] += tmp;
        }

        // Output mapping
        inline for (0..8) |idx| {
            x[2 * idx] = y[idx];
            if (flag) {
                x[2 * idx + 1] = -y[15 - idx];
            } else {
                x[2 * idx + 1] = y[15 - idx];
            }
        }
    }

    pub fn idct(input: []const f64, output: *[32]f64) void {
        var a: [16]f64 = undefined;
        var b: [16]f64 = undefined;

        a[0] = input[0];
        b[0] = input[31];
        for (1..16) |idx| {
            a[idx] = input[2 * idx - 1] + input[2 * idx];
            b[16 - idx] = input[2 * idx - 1] - input[2 * idx];
        }

        proc(&a, false);
        proc(&b, true);

        for (0..16) |idx| {
            output[idx] = a[idx] * ac[idx] + b[idx] * as[idx];
            output[32 - idx - 1] = a[idx] * as[idx] - b[idx] * ac[idx];
        }
    }
};

pub const SubbandDsp = struct {
    history: [SUBBAND_HISTORY_SIZE]f64,

    pub fn init() SubbandDsp {
        return .{
            .history = [_]f64{0.0} ** SUBBAND_HISTORY_SIZE,
        };
    }

    pub fn reset(self: *SubbandDsp) void {
        @memset(&self.history, 0.0);
    }

    /// Interpolates 32 subband samples into 32 PCM samples per block.
    /// subband_samples: [32][4 + 64]i32 (history + frame samples)
    /// out_pcm: [npcmblocks * 32]f32
    pub fn interpolateSub32(
        self: *SubbandDsp,
        subband_samples: *const [32][68]i32,
        npcmblocks: usize,
        perfect: bool,
        out_pcm: []f32,
    ) void {
        if (perfect) {
            self.interpolateSub32T(&tables.band_fir_perfect, subband_samples, npcmblocks, out_pcm);
        } else {
            self.interpolateSub32T(&tables.band_fir_nonperfect, subband_samples, npcmblocks, out_pcm);
        }
    }

    fn interpolateSub32T(
        self: *SubbandDsp,
        comptime filter_coeff: *const [512]f64,
        subband_samples: *const [32][68]i32,
        npcmblocks: usize,
        out_pcm: []f32,
    ) void {
        const norm_scale: f64 = 1.0 / 8388608.0;

        for (0..npcmblocks) |sample_idx| {
            var input: [32]f64 = undefined;
            for (0..32) |b| {
                input[b] = @floatFromInt(subband_samples[b][4 + sample_idx]);
            }

            var output: [32]f64 = undefined;
            Idct32.idct(&input, &output);

            // Store into history
            for (0..16) |i| {
                const k = 31 - i;
                self.history[i] = output[i] - output[k];
                self.history[16 + i] = output[i] + output[k];
            }

            // Generate 32 interpolated samples with 4-wide SIMD
            const pcm_offset = sample_idx * 32;
            const J1 = [8]usize{ 0, 64, 128, 192, 256, 320, 384, 448 };
            const J2 = [8]usize{ 32, 96, 160, 224, 288, 352, 416, 480 };
            const rev_mask = @Vector(4, i32){ 3, 2, 1, 0 };

            inline for ([4]usize{ 0, 4, 8, 12 }) |i| {
                var v_res1: @Vector(4, f64) = @splat(0.0);
                var v_res2: @Vector(4, f64) = @splat(0.0);
                const k_base = 12 - i;

                inline for (J1) |j| {
                    const h1: @Vector(4, f64) = self.history[i + j ..][0..4].*;
                    const c1: @Vector(4, f64) = filter_coeff[i + j ..][0..4].*;
                    v_res1 += h1 * c1;

                    const h2_raw: @Vector(4, f64) = self.history[k_base + j ..][0..4].*;
                    const h2_rev = @shuffle(f64, h2_raw, undefined, rev_mask);
                    const c2: @Vector(4, f64) = filter_coeff[16 + i + j ..][0..4].*;
                    v_res2 += h2_rev * c2;
                }

                inline for (J2) |j| {
                    const h1: @Vector(4, f64) = self.history[16 + i + j ..][0..4].*;
                    const c1: @Vector(4, f64) = filter_coeff[i + j ..][0..4].*;
                    v_res1 += h1 * c1;

                    const h2_raw: @Vector(4, f64) = self.history[16 + k_base + j ..][0..4].*;
                    const h2_rev = @shuffle(f64, h2_raw, undefined, rev_mask);
                    const c2: @Vector(4, f64) = filter_coeff[16 + i + j ..][0..4].*;
                    v_res2 += h2_rev * c2;
                }

                out_pcm[pcm_offset + i + 0] = @floatCast(v_res1[0] * norm_scale);
                out_pcm[pcm_offset + i + 1] = @floatCast(v_res1[1] * norm_scale);
                out_pcm[pcm_offset + i + 2] = @floatCast(v_res1[2] * norm_scale);
                out_pcm[pcm_offset + i + 3] = @floatCast(v_res1[3] * norm_scale);

                out_pcm[pcm_offset + 16 + i + 0] = @floatCast(v_res2[0] * norm_scale);
                out_pcm[pcm_offset + 16 + i + 1] = @floatCast(v_res2[1] * norm_scale);
                out_pcm[pcm_offset + 16 + i + 2] = @floatCast(v_res2[2] * norm_scale);
                out_pcm[pcm_offset + 16 + i + 3] = @floatCast(v_res2[3] * norm_scale);
            }

            // Shift history by 32
            std.mem.copyBackwards(f64, self.history[32..512], self.history[0..480]);
        }
    }
};

pub const LfeDsp = struct {
    history: [MAX_LFE_HISTORY]i32,

    pub fn init() LfeDsp {
        return .{
            .history = [_]i32{0} ** MAX_LFE_HISTORY,
        };
    }

    pub fn reset(self: *LfeDsp) void {
        @memset(&self.history, 0);
    }

    /// Interpolates LFE samples into full PCM rate.
    /// npcmblocks is the number of PCM blocks in the frame (e.g. 16 or 32).
    /// lfe_present: 1 (factor 64) or 2 (factor 128)
    /// lfe_samples: buffer containing MAX_LFE_HISTORY + nlfesamples
    pub fn interpolateLfe(
        self: *LfeDsp,
        lfe_samples: []const i32,
        npcmblocks: usize,
        dec_select: bool,
        out_pcm: []f32,
    ) void {
        if (dec_select) {
            self.interpolateLfeT(true, lfe_samples, npcmblocks, out_pcm);
        } else {
            self.interpolateLfeT(false, lfe_samples, npcmblocks, out_pcm);
        }
    }

    /// Comptime-specialized LFE interpolation. The comptime dec_select parameter
    /// allows the compiler to fully unroll the inner ncoeffs loop (4 or 8 iterations)
    /// and inline the correct filter coefficient pointer.
    fn interpolateLfeT(
        self: *LfeDsp,
        comptime dec_select: bool,
        lfe_samples: []const i32,
        npcmblocks: usize,
        out_pcm: []f32,
    ) void {
        const factor: usize = if (dec_select) 128 else 64;
        const ncoeffs: usize = if (dec_select) 4 else 8;
        const nlfesamples: usize = npcmblocks >> (if (dec_select) 2 else 1);
        const filter_coeff: []const f64 = if (dec_select) &tables.lfe_fir_128 else &tables.lfe_fir_64;
        const norm_scale: f64 = 1.0 / 8388608.0;

        for (0..nlfesamples) |i| {
            const src_idx = MAX_LFE_HISTORY + i;
            const pcm_base = i * factor;

            for (0..factor / 2) |j| {
                var res1: f64 = 0.0;
                var res2: f64 = 0.0;

                // Inner loop is unrolled at comptime (4 or 8 iterations)
                inline for (0..ncoeffs) |k| {
                    const sample_val: f64 = @floatFromInt(lfe_samples[src_idx - k]);
                    res1 += filter_coeff[j * ncoeffs + k] * sample_val;
                    res2 += filter_coeff[255 - j * ncoeffs - k] * sample_val;
                }

                out_pcm[pcm_base + j] = @floatCast(res1 * norm_scale);
                out_pcm[pcm_base + factor / 2 + j] = @floatCast(res2 * norm_scale);
            }
        }

        // Update history
        var n: usize = 0;
        while (n < 8) : (n += 1) {
            const h_idx = MAX_LFE_HISTORY - 1 - n;
            self.history[h_idx] = lfe_samples[nlfesamples + h_idx];
        }
    }
};

test "Idct32 impulse response" {
    var in = [_]f64{0.0} ** 32;
    in[0] = 1.0;
    var out: [32]f64 = undefined;
    Idct32.idct(&in, &out);

    // Sum of squares should be non-zero and finite
    var energy: f64 = 0.0;
    for (out) |v| {
        try std.testing.expect(!std.math.isNan(v));
        energy += v * v;
    }
    try std.testing.expect(energy > 0.001);
}
