const std = @import("std");
const synthesis = @import("synthesis.zig");

test "Idct32 impulse response" {
    var in: [32]f64 = @splat(0.0);
    in[0] = 1.0;
    var out: [32]f64 = undefined;
    synthesis.Idct32.idct(&in, &out);

    // Sum of squares should be non-zero and finite
    var energy: f64 = 0.0;
    for (out) |v| {
        try std.testing.expect(!std.math.isNan(v));
        energy += v * v;
    }
    try std.testing.expect(energy > 0.001);
}
