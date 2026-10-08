const std = @import("std");

/// Generic append-only event stream with resource lifecycle management.
pub fn Stream(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ItemType = T;

        allocator: std.mem.Allocator,
        list: std.ArrayList(T),
        items: []const T = &.{},
        max_capacity: ?usize = null,

        pub fn init(allocator: std.mem.Allocator, max_capacity: ?usize) Self {
            return .{
                .allocator = allocator,
                .list = std.ArrayList(T).empty,
                .items = &.{},
                .max_capacity = max_capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            if (comptime @hasDecl(T, "deinit")) {
                for (self.list.items) |*item| {
                    self.freeItem(item);
                }
            }
            self.list.deinit(self.allocator);
            self.items = &.{};
        }

        fn freeItem(self: *Self, item_ptr: *T) void {
            if (comptime @hasDecl(T, "deinit")) {
                const DeinitFn = @TypeOf(@field(T, "deinit"));
                const params_len = @typeInfo(DeinitFn).@"fn".param_types.len;
                if (params_len == 2) {
                    item_ptr.deinit(self.allocator);
                } else {
                    item_ptr.deinit();
                }
            }
        }

        fn cloneItem(self: *const Self, item: T) !T {
            if (comptime @hasDecl(T, "clone")) {
                const CloneFn = @TypeOf(@field(T, "clone"));
                const params_len = @typeInfo(CloneFn).@"fn".param_types.len;
                if (params_len == 2) {
                    return try item.clone(self.allocator);
                } else {
                    return try item.clone();
                }
            }
            return item;
        }

        /// Appends an item to the stream, cloning if supported.
        pub fn append(self: *Self, item: T) !void {
            var val = try self.cloneItem(item);
            errdefer self.freeItem(&val);

            // Evict oldest item if capacity is exceeded
            if (self.max_capacity) |cap| {
                if (self.list.items.len >= cap and self.list.items.len > 0) {
                    var oldest = self.list.orderedRemove(0);
                    self.freeItem(&oldest);
                }
            }

            try self.list.append(self.allocator, val);
            self.items = self.list.items;
        }

        /// Appends an already-allocated item without re-cloning, taking ownership.
        pub fn appendOwned(self: *Self, val: T) !void {
            var mut_val = val;
            errdefer self.freeItem(&mut_val);

            // Evict oldest item if capacity is exceeded
            if (self.max_capacity) |cap| {
                if (self.list.items.len >= cap and self.list.items.len > 0) {
                    var oldest = self.list.orderedRemove(0);
                    self.freeItem(&oldest);
                }
            }

            try self.list.append(self.allocator, mut_val);
            self.items = self.list.items;
        }

        /// Removes an item at index preserving order.
        pub fn orderedRemove(self: *Self, index: usize) T {
            const item = self.list.orderedRemove(index);
            self.items = self.list.items;
            return item;
        }

        /// Returns direct slice of current items.
        pub fn slice(self: *const Self) []const T {
            return self.items;
        }

        pub fn mutableSlice(self: *Self) []T {
            return self.list.items;
        }

        /// Returns count of items.
        pub fn count(self: *const Self) usize {
            return self.items.len;
        }

        /// Clears all items.
        pub fn clear(self: *Self) void {
            if (comptime @hasDecl(T, "deinit")) {
                for (self.list.items) |*item| {
                    self.freeItem(item);
                }
            }
            self.list.clearRetainingCapacity();
            self.items = self.list.items;
        }
    };
}
