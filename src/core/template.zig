const std = @import("std");

/// Renders a template string by replacing placeholders like `__KEY__` with values
/// from the `replacements` anonymous struct.
pub fn render(allocator: std.mem.Allocator, template_str: []const u8, replacements: anytype) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    const T = @TypeOf(replacements);
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("replacements must be a struct");
    }

    var i: usize = 0;
    while (i < template_str.len) {
        var replaced = false;
        inline for (info.@"struct".fields) |field| {
            const placeholder = comptime "__" ++ field.name ++ "__";
            if (std.mem.startsWith(u8, template_str[i..], placeholder)) {
                const value = @field(replacements, field.name);
                switch (@typeInfo(@TypeOf(value))) {
                    .pointer => |p| {
                        if (p.size == .slice and p.child == u8) {
                            try result.appendSlice(allocator, value);
                        } else {
                            @compileError("Unsupported pointer type in template: " ++ @typeName(@TypeOf(value)));
                        }
                    },
                    .float => {
                        var buf: [64]u8 = undefined;
                        const slice = try std.fmt.bufPrint(&buf, "{d}", .{value});
                        try result.appendSlice(allocator, slice);
                    },
                    .int => {
                        var buf: [64]u8 = undefined;
                        const slice = try std.fmt.bufPrint(&buf, "{d}", .{value});
                        try result.appendSlice(allocator, slice);
                    },
                    else => @compileError("Unsupported replacement type: " ++ @typeName(@TypeOf(value))),
                }
                i += placeholder.len;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try result.append(allocator, template_str[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}
