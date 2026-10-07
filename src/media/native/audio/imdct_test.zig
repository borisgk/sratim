const std = @import("std");
const imdct = @import("imdct.zig");
const imdct512 = imdct.imdct512;

test "imdct512 runs on zero input" {
    var data: [256]f32 = @splat(0.0);
    var delay: [256]f32 = @splat(0.0);
    imdct512(&data, &delay);
    for (data) |d| {
        try std.testing.expectEqual(@as(f32, 0.0), d);
    }
}

test "imdct512 executes on non-zero spectral bin" {
    var data1: [256]f32 = @splat(0.0);
    data1[10] = 1.0;
    var delay: [256]f32 = @splat(0.0);
    imdct512(&data1, &delay);

    var has_nonzero = false;
    for (data1) |v| {
        if (@abs(v) > 1e-4) has_nonzero = true;
    }
    try std.testing.expect(has_nonzero);

    var data2: [256]f32 = @splat(0.0);
    imdct512(&data2, &delay);
    var has_nonzero2 = false;
    for (data2) |v| {
        if (@abs(v) > 1e-4) has_nonzero2 = true;
    }
    try std.testing.expect(has_nonzero2);
}
