const std = @import("std");
const tables = @import("tables.zig");

pub const ImdctState = struct {
    /// Overlap buffer: [channel][subband 0..31][18 samples]
    overlap: [2][32][18]f32 = std.mem.zeroes([2][32][18]f32),

    pub fn init() ImdctState {
        return .{};
    }

    pub fn reset(self: *ImdctState) void {
        self.overlap = std.mem.zeroes([2][32][18]f32);
    }

    /// Performs IMDCT, windowing, overlap-add, and frequency inversion for 1 granule (576 samples).
    /// in_spectrum: [576]f32 frequency domain coefficients.
    /// out_subband_samples: [18][32]f32 time-frequency matrix for the polyphase synthesis filterbank.
    pub fn process(
        self: *ImdctState,
        ch: usize,
        block_type: u2,
        mixed_block_flag: bool,
        in_spectrum: []const f32,
        out_subband_samples: *[18][32]f32,
    ) void {
        const pi = std.math.pi;

        for (0..32) |sb| {
            const is_short = (block_type == 2) and (!mixed_block_flag or sb >= 2);
            var raw_out: [36]f32 = undefined;

            if (!is_short) {
                // 36-point IMDCT for long blocks
                const spec = in_spectrum[sb * 18 .. (sb + 1) * 18];
                for (0..36) |i| {
                    var sum: f32 = 0;
                    const fi = @as(f32, @floatFromInt(i));
                    for (0..18) |k| {
                        const fk = @as(f32, @floatFromInt(k));
                        const angle = (pi / 72.0) * (2.0 * fi + 19.0) * (2.0 * fk + 1.0);
                        sum += spec[k] * @cos(angle);
                    }
                    const win = tables.getWindowLong(block_type, i);
                    raw_out[i] = sum * win;
                }
            } else {
                // 3 x 12-point IMDCT for short blocks
                @memset(&raw_out, 0);
                for (0..3) |w| {
                    const spec = in_spectrum[sb * 18 + w * 6 .. sb * 18 + (w + 1) * 6];
                    for (0..12) |i| {
                        var sum: f32 = 0;
                        const fi = @as(f32, @floatFromInt(i));
                        for (0..6) |k| {
                            const fk = @as(f32, @floatFromInt(k));
                            const angle = (pi / 24.0) * (2.0 * fi + 7.0) * (2.0 * fk + 1.0);
                            sum += spec[k] * @cos(angle);
                        }
                        const win = tables.getWindowShort(i);
                        const out_idx = 6 + w * 6 + i;
                        if (out_idx < 36) {
                            raw_out[out_idx] += sum * win;
                        }
                    }
                }
            }

            // Overlap-add with previous granule's upper half
            for (0..18) |i| {
                var s = raw_out[i] + self.overlap[ch][sb][i];
                self.overlap[ch][sb][i] = raw_out[i + 18];

                // Frequency inversion: odd subbands have odd samples negated
                if ((sb & 1) != 0 and (i & 1) != 0) {
                    s = -s;
                }
                out_subband_samples[i][sb] = s;
            }
        }
    }
};

test "ImdctState basic reset and process" {
    var state = ImdctState.init();
    var spec: [576]f32 = undefined;
    @memset(&spec, 0);
    spec[0] = 1.0;
    var out: [18][32]f32 = undefined;
    state.process(0, 0, false, &spec, &out);
    try std.testing.expect(out[0][0] != 0);
}
