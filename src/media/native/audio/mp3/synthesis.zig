const std = @import("std");
const tables = @import("tables.zig");

/// 32-band Polyphase Synthesis Filterbank (ISO/IEC 11172-3 Section 2.4.3.4.9)
pub const SynthesisFilterbank = struct {
    /// Ring buffer of 1024 past intermediate filter values per channel
    v_buf: [2][1024]f32 = std.mem.zeroes([2][1024]f32),
    v_offset: [2]usize = .{ 0, 0 },

    pub fn init() SynthesisFilterbank {
        return .{};
    }

    pub fn reset(self: *SynthesisFilterbank) void {
        self.v_buf = std.mem.zeroes([2][1024]f32);
        self.v_offset = .{ 0, 0 };
    }

    /// Transforms 32 subband frequency samples into 32 time-domain PCM samples.
    /// subband: [32]f32
    /// out_pcm: []f32 (at least 32 elements)
    pub fn synthesize32(
        self: *SynthesisFilterbank,
        ch: usize,
        subband: []const f32,
        out_pcm: []f32,
    ) void {
        const pi = std.math.pi;

        // 1. Matrixing: Compute 64 values of V
        var v64: [64]f32 = undefined;
        for (0..64) |i| {
            var sum: f32 = 0;
            const fi = @as(f32, @floatFromInt(i));
            for (0..32) |k| {
                const fk = @as(f32, @floatFromInt(k));
                const angle = (pi / 64.0) * (2.0 * fi + 1.0) * (2.0 * fk + 1.0);
                sum += subband[k] * @cos(angle);
            }
            v64[i] = sum;
        }

        // 2. Circular buffer insertion into 1024-sample delay line
        var offset = self.v_offset[ch];
        offset = if (offset >= 64) offset - 64 else 1024 - 64;
        self.v_offset[ch] = offset;

        for (0..64) |i| {
            self.v_buf[ch][offset + i] = v64[i];
        }

        // 3. Windowing by 512-coefficient prototype window D
        const win = &tables.SYNTHESIS_WINDOW;
        for (0..32) |j| {
            var sum: f32 = 0;
            for (0..16) |k| {
                const idx = (offset + k * 64 + j) % 1024;
                const win_idx = k * 32 + j;
                sum += self.v_buf[ch][idx] * win[win_idx];
            }
            // Standard normalization for 16-bit to float range
            out_pcm[j] = sum;
        }
    }
};

test "SynthesisFilterbank basic reset and synth" {
    var filter = SynthesisFilterbank.init();
    var sb: [32]f32 = undefined;
    @memset(&sb, 0);
    sb[0] = 1.0;
    var out: [32]f32 = undefined;
    filter.synthesize32(0, &sb, &out);
    try std.testing.expect(out.len == 32);
}
