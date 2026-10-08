const std = @import("std");

/// Generic append-only event stream with resource lifecycle management.
pub fn Stream(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ItemType = T;

        allocator: std.mem.Allocator,
        list: std.ArrayList(T),
        max_capacity: ?usize = null,

        pub fn init(allocator: std.mem.Allocator, max_capacity: ?usize) Self {
            return .{
                .allocator = allocator,
                .list = std.ArrayList(T).empty,
                .max_capacity = max_capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            if (comptime @hasDecl(T, "deinit")) {
                for (self.list.items) |*item| {
                    item.deinit(self.allocator);
                }
            }
            self.list.deinit(self.allocator);
        }

        /// Appends an item to the stream.
        pub fn append(self: *Self, item: T) !void {
            const val = if (comptime @hasDecl(T, "clone"))
                try item.clone(self.allocator)
            else
                item;
            errdefer if (comptime @hasDecl(T, "deinit")) {
                var mut = val;
                mut.deinit(self.allocator);
            };

            // Evict oldest item if capacity is exceeded
            if (self.max_capacity) |cap| {
                if (self.list.items.len >= cap and self.list.items.len > 0) {
                    if (comptime @hasDecl(T, "deinit")) {
                        self.list.items[0].deinit(self.allocator);
                    }
                    _ = self.list.orderedRemove(0);
                }
            }

            try self.list.append(self.allocator, val);
        }

        /// Returns direct slice of current items.
        pub fn items(self: *const Self) []const T {
            return self.list.items;
        }

        /// Returns count of items.
        pub fn count(self: *const Self) usize {
            return self.list.items.len;
        }

        /// Clears all items.
        pub fn clear(self: *Self) void {
            if (comptime @hasDecl(T, "deinit")) {
                for (self.list.items) |*item| {
                    item.deinit(self.allocator);
                }
            }
            self.list.clearRetainingCapacity();
        }
    };
}
