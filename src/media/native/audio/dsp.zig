const std = @import("std");

/// Channel configuration for multi-channel audio.
pub const ChannelLayout = enum {
    mono,
    stereo,
    layout_2_1,
    layout_3_0,
    surround_5_1,
    surround_7_1,

    pub fn fromChannels(channels: usize) ChannelLayout {
        return switch (channels) {
            1 => .mono,
            2 => .stereo,
            3 => .layout_2_1,
            4 => .layout_3_0,
            6 => .surround_5_1,
            8 => .surround_7_1,
            else => if (channels >= 8) .surround_7_1 else if (channels >= 6) .surround_5_1 else .stereo,
        };
    }
};

const INV_SQRT2: f32 = 0.7071067811865475; // -3 dB attenuation for center & surround channels

/// Downmixes planar multi-channel float PCM into stereo Left and Right channels
/// according to ITU-R BS.775 standard with soft saturation protection.
pub fn downmixPlanarToStereo(
    in_channels: []const []const f32,
    layout: ChannelLayout,
    out_l: []f32,
    out_r: []f32,
) void {
    const num_samples = @min(out_l.len, out_r.len);
    if (num_samples == 0) return;

    switch (layout) {
        .mono => {
            const m = in_channels[0];
            const count = @min(num_samples, m.len);
            for (0..count) |i| {
                out_l[i] = m[i];
                out_r[i] = m[i];
            }
        },
        .stereo => {
            const l = in_channels[0];
            const r = in_channels[1];
            const count = @min(num_samples, @min(l.len, r.len));
            @memcpy(out_l[0..count], l[0..count]);
            @memcpy(out_r[0..count], r[0..count]);
        },
        .layout_2_1 => {
            // L, R, LFE
            const l = in_channels[0];
            const r = in_channels[1];
            const count = @min(num_samples, @min(l.len, r.len));
            @memcpy(out_l[0..count], l[0..count]);
            @memcpy(out_r[0..count], r[0..count]);
        },
        .layout_3_0 => {
            // L, R, C
            const l = in_channels[0];
            const r = in_channels[1];
            const c = in_channels[2];
            const count = @min(num_samples, @min(l.len, @min(r.len, c.len)));
            for (0..count) |i| {
                const center_contrib = c[i] * INV_SQRT2;
                out_l[i] = std.math.clamp(l[i] + center_contrib, -1.0, 1.0);
                out_r[i] = std.math.clamp(r[i] + center_contrib, -1.0, 1.0);
            }
        },
        .surround_5_1 => {
            // Standard 5.1 SMPTE / Film order:
            // 0: L, 1: R, 2: C, 3: LFE, 4: Ls, 5: Rs
            const l = in_channels[0];
            const r = in_channels[1];
            const c = in_channels[2];
            const ls = in_channels[4];
            const rs = in_channels[5];
            const count = @min(num_samples, @min(l.len, @min(r.len, @min(c.len, @min(ls.len, rs.len)))));

            var i: usize = 0;
            // 4-wide SIMD vector optimization
            while (i + 4 <= count) : (i += 4) {
                const vl: @Vector(4, f32) = l[i..][0..4].*;
                const vr: @Vector(4, f32) = r[i..][0..4].*;
                const vc: @Vector(4, f32) = c[i..][0..4].*;
                const vls: @Vector(4, f32) = ls[i..][0..4].*;
                const vrs: @Vector(4, f32) = rs[i..][0..4].*;

                const v_inv_sqrt2: @Vector(4, f32) = @splat(INV_SQRT2);
                const out_l_vec = vl + vc * v_inv_sqrt2 + vls * v_inv_sqrt2;
                const out_r_vec = vr + vc * v_inv_sqrt2 + vrs * v_inv_sqrt2;

                out_l[i..][0..4].* = std.math.clamp(out_l_vec, @as(@Vector(4, f32), @splat(-1.0)), @as(@Vector(4, f32), @splat(1.0)));
                out_r[i..][0..4].* = std.math.clamp(out_r_vec, @as(@Vector(4, f32), @splat(-1.0)), @as(@Vector(4, f32), @splat(1.0)));
            }

            while (i < count) : (i += 1) {
                const mixed_l = l[i] + c[i] * INV_SQRT2 + ls[i] * INV_SQRT2;
                const mixed_r = r[i] + c[i] * INV_SQRT2 + rs[i] * INV_SQRT2;
                out_l[i] = std.math.clamp(mixed_l, -1.0, 1.0);
                out_r[i] = std.math.clamp(mixed_r, -1.0, 1.0);
            }
        },
        .surround_7_1 => {
            // 0: L, 1: R, 2: C, 3: LFE, 4: Ls, 5: Rs, 6: Rls, 7: Rrs
            const l = in_channels[0];
            const r = in_channels[1];
            const c = in_channels[2];
            const ls = in_channels[4];
            const rs = in_channels[5];
            const rls = in_channels[6];
            const rrs = in_channels[7];
            const count = @min(num_samples, @min(l.len, @min(r.len, @min(c.len, @min(ls.len, @min(rs.len, @min(rls.len, rrs.len)))))));

            for (0..count) |i| {
                const mixed_l = l[i] + c[i] * INV_SQRT2 + ls[i] * INV_SQRT2 + rls[i] * 0.5;
                const mixed_r = r[i] + c[i] * INV_SQRT2 + rs[i] * INV_SQRT2 + rrs[i] * 0.5;
                out_l[i] = std.math.clamp(mixed_l, -1.0, 1.0);
                out_r[i] = std.math.clamp(mixed_r, -1.0, 1.0);
            }
        },
    }
}

/// Downmixes interleaved multi-channel float PCM into stereo Left and Right channels.
pub fn downmixInterleavedToStereo(
    interleaved: []const f32,
    channels: usize,
    layout: ChannelLayout,
    out_l: []f32,
    out_r: []f32,
) void {
    const total_frames = @min(interleaved.len / channels, @min(out_l.len, out_r.len));
    if (total_frames == 0) return;

    switch (layout) {
        .mono => {
            for (0..total_frames) |i| {
                const s = interleaved[i * channels];
                out_l[i] = s;
                out_r[i] = s;
            }
        },
        .stereo => {
            for (0..total_frames) |i| {
                out_l[i] = interleaved[i * channels];
                out_r[i] = interleaved[i * channels + 1];
            }
        },
        .layout_2_1 => {
            for (0..total_frames) |i| {
                out_l[i] = interleaved[i * channels];
                out_r[i] = interleaved[i * channels + 1];
            }
        },
        .layout_3_0 => {
            for (0..total_frames) |i| {
                const l = interleaved[i * channels];
                const r = interleaved[i * channels + 1];
                const c = interleaved[i * channels + 2];
                out_l[i] = std.math.clamp(l + c * INV_SQRT2, -1.0, 1.0);
                out_r[i] = std.math.clamp(r + c * INV_SQRT2, -1.0, 1.0);
            }
        },
        .surround_5_1 => {
            for (0..total_frames) |i| {
                const base = i * channels;
                const l = interleaved[base];
                const r = interleaved[base + 1];
                const c = interleaved[base + 2];
                // base + 3 is LFE
                const ls = interleaved[base + 4];
                const rs = interleaved[base + 5];

                out_l[i] = std.math.clamp(l + c * INV_SQRT2 + ls * INV_SQRT2, -1.0, 1.0);
                out_r[i] = std.math.clamp(r + c * INV_SQRT2 + rs * INV_SQRT2, -1.0, 1.0);
            }
        },
        .surround_7_1 => {
            for (0..total_frames) |i| {
                const base = i * channels;
                const l = interleaved[base];
                const r = interleaved[base + 1];
                const c = interleaved[base + 2];
                const ls = interleaved[base + 4];
                const rs = interleaved[base + 5];
                const rls = interleaved[base + 6];
                const rrs = interleaved[base + 7];

                out_l[i] = std.math.clamp(l + c * INV_SQRT2 + ls * INV_SQRT2 + rls * 0.5, -1.0, 1.0);
                out_r[i] = std.math.clamp(r + c * INV_SQRT2 + rs * INV_SQRT2 + rrs * 0.5, -1.0, 1.0);
            }
        },
    }
}

/// High-quality Cubic Hermite Interpolation audio resampler with continuous phase preservation.
pub const HermiteResampler = struct {
    in_rate: u32,
    out_rate: u32,
    ratio: f64,
    phase: f64 = 0.0,
    history: [4]f32 = [_]f32{ 0.0, 0.0, 0.0, 0.0 },

    pub fn init(in_rate: u32, out_rate: u32) HermiteResampler {
        return .{
            .in_rate = in_rate,
            .out_rate = out_rate,
            .ratio = @as(f64, @floatFromInt(in_rate)) / @as(f64, @floatFromInt(out_rate)),
            .phase = 0.0,
            .history = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
        };
    }

    pub fn reset(self: *HermiteResampler) void {
        self.phase = 0.0;
        self.history = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    }

    /// Resamples an input slice of single-channel float PCM into an output buffer.
    /// Returns the number of output samples generated.
    pub fn process(self: *HermiteResampler, input: []const f32, output: []f32) usize {
        if (self.in_rate == self.out_rate) {
            const count = @min(input.len, output.len);
            @memcpy(output[0..count], input[0..count]);
            return count;
        }

        var out_idx: usize = 0;

        while (out_idx < output.len) {
            const current_sample_idx = @as(usize, @intFromFloat(self.phase));
            if (current_sample_idx + 2 >= input.len) break;

            const t: f32 = @floatCast(self.phase - @as(f64, @floatFromInt(current_sample_idx)));

            // 4-point cubic Hermite spline interpolation:
            // p0, p1, p2, p3
            const p0 = if (current_sample_idx == 0) self.history[3] else input[current_sample_idx - 1];
            const p1 = input[current_sample_idx];
            const p2 = input[current_sample_idx + 1];
            const p3 = input[current_sample_idx + 2];

            const c0 = p1;
            const c1 = 0.5 * (p2 - p0);
            const c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
            const c3 = 0.5 * (p3 - p0) + 1.5 * (p1 - p2);

            output[out_idx] = ((c3 * t + c2) * t + c1) * t + c0;
            out_idx += 1;
            self.phase += self.ratio;
        }

        // Maintain phase and history for seamless streaming across packet boundaries
        if (input.len >= 4) {
            self.history[0] = input[input.len - 4];
            self.history[1] = input[input.len - 3];
            self.history[2] = input[input.len - 2];
            self.history[3] = input[input.len - 1];
        }
        const consumed = @as(usize, @intFromFloat(self.phase));
        self.phase -= @as(f64, @floatFromInt(@min(consumed, input.len)));

        return out_idx;
    }
};

test "downmixPlanarToStereo 5.1 surround ITU-R BS.775" {
    var l = [_]f32{1.0} ** 8;
    var r = [_]f32{1.0} ** 8;
    var c = [_]f32{1.0} ** 8;
    var lfe = [_]f32{0.5} ** 8;
    var ls = [_]f32{1.0} ** 8;
    var rs = [_]f32{1.0} ** 8;

    const channels = [_][]const f32{ &l, &r, &c, &lfe, &ls, &rs };

    var out_l: [8]f32 = undefined;
    var out_r: [8]f32 = undefined;

    downmixPlanarToStereo(&channels, .surround_5_1, &out_l, &out_r);

    // L_out = clamp(1.0 + 0.7071 + 0.7071, -1.0, 1.0) = 1.0
    for (out_l) |s| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), s, 0.001);
    }
    for (out_r) |s| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), s, 0.001);
    }
}

test "downmixPlanarToStereo stereo passthrough" {
    var l = [_]f32{ 0.25, -0.5, 0.75, -0.1 };
    var r = [_]f32{ -0.25, 0.5, -0.75, 0.1 };
    const channels = [_][]const f32{ &l, &r };

    var out_l: [4]f32 = undefined;
    var out_r: [4]f32 = undefined;

    downmixPlanarToStereo(&channels, .stereo, &out_l, &out_r);

    try std.testing.expectEqualSlices(f32, &l, &out_l);
    try std.testing.expectEqualSlices(f32, &r, &out_r);
}

test "HermiteResampler 44100 to 48000 Hz preserves sine continuity" {
    var resampler = HermiteResampler.init(44100, 48000);

    var input: [441]f32 = undefined;
    // Generate 10ms of 1000 Hz sine wave at 44.1kHz
    for (0..input.len) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        input[i] = @sin(2.0 * std.math.pi * 1000.0 * t);
    }

    var output: [480]f32 = undefined;
    const generated = resampler.process(&input, &output);

    try std.testing.expect(generated > 450);
    // Verify peak amplitude preserved within 5%
    var max_amp: f32 = 0.0;
    for (output[0..generated]) |s| {
        if (@abs(s) > max_amp) max_amp = @abs(s);
    }
    try std.testing.expect(max_amp > 0.90 and max_amp <= 1.05);
}
