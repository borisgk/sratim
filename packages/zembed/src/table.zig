const std = @import("std");
const types = @import("types.zig");

pub const TableOptions = types.TableOptions;
pub const DbError = types.DbError;

/// Generic in-memory table indexed by primary key with compile-time type introspection.
pub fn Table(comptime T: type, comptime options: TableOptions) type {
    const PkField = options.primary_key;

    if (!@hasField(T, PkField)) {
        @compileError("Type '" ++ @typeName(T) ++ "' does not have primary key field '" ++ PkField ++ "'");
    }

    const PkType = @TypeOf(@field(@as(T, undefined), PkField));
    const is_string_key = (PkType == []const u8);
    const is_int_key = (@typeInfo(PkType) == .int);

    return struct {
        const Self = @This();
        pub const ItemType = T;
        pub const KeyType = PkType;

        allocator: std.mem.Allocator,
        map: if (is_string_key) std.StringHashMap(T) else std.AutoHashMap(PkType, T),
        next_id: if (is_int_key) PkType else void = if (is_int_key) 1 else {},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .map = if (is_string_key) std.StringHashMap(T).init(allocator) else std.AutoHashMap(PkType, T).init(allocator),
                .next_id = if (is_int_key) 1 else {},
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.freeItem(entry.value_ptr);
            }
            self.map.deinit();
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

        fn cloneItem(self: *const Self, item: T, allocator: std.mem.Allocator) !T {
            _ = self;
            if (comptime @hasDecl(T, "clone")) {
                const CloneFn = @TypeOf(@field(T, "clone"));
                const params_len = @typeInfo(CloneFn).@"fn".param_types.len;
                if (params_len == 2) {
                    return try item.clone(allocator);
                } else {
                    return try item.clone();
                }
            }
            return item;
        }

        /// Inserts or replaces an item. If auto-increment is enabled and key is 0, generates next key.
        pub fn insert(self: *Self, item: T) !PkType {
            var val = try self.cloneItem(item, self.allocator);
            errdefer self.freeItem(&val);

            if (comptime is_int_key and options.auto_increment) {
                const current_key = @field(val, PkField);
                if (current_key == 0) {
                    const assigned = self.next_id;
                    self.next_id += 1;
                    @field(val, PkField) = assigned;
                } else if (current_key >= self.next_id) {
                    self.next_id = current_key + 1;
                }
            }

            const key = @field(val, PkField);
            const key_for_map = if (comptime is_string_key) key else key;

            if (self.map.fetchRemove(key_for_map)) |old_kv| {
                var old_val = old_kv.value;
                self.freeItem(&old_val);
            }

            try self.map.put(key_for_map, val);
            return key;
        }

        pub const MapType = if (is_string_key) std.StringHashMap(T) else std.AutoHashMap(PkType, T);
        pub const Iterator = MapType.Iterator;
        pub const ValueIterator = MapType.ValueIterator;
        pub const KeyIterator = MapType.KeyIterator;
        pub const Entry = MapType.Entry;
        pub const KV = MapType.KV;

        pub fn iterator(self: *const Self) Iterator {
            return self.map.iterator();
        }

        pub fn valueIterator(self: *const Self) ValueIterator {
            return self.map.valueIterator();
        }

        pub fn keyIterator(self: *const Self) KeyIterator {
            return self.map.keyIterator();
        }

        /// Puts an item into the table, taking ownership.
        /// If an item already exists with that key, frees the old item.
        pub fn put(self: *Self, key: PkType, val: T) !void {
            const key_to_insert = if (comptime is_string_key) @field(val, PkField) else key;
            if (self.map.fetchRemove(key)) |old_kv| {
                var old_val = old_kv.value;
                self.freeItem(&old_val);
            }
            try self.map.put(key_to_insert, val);
            if (comptime is_int_key and options.auto_increment) {
                if (key >= self.next_id) {
                    self.next_id = key + 1;
                }
                if (key_to_insert >= self.next_id) {
                    self.next_id = key_to_insert + 1;
                }
            }
        }

        /// Removes an item by key and returns the key-value pair without freeing.
        pub fn fetchRemove(self: *Self, key: PkType) ?KV {
            return self.map.fetchRemove(key);
        }

        /// Gets a direct copy of the item in the table without cloning.
        pub fn get(self: *const Self, key: PkType) ?T {
            return self.map.get(key);
        }

        /// Gets an item cloned with the caller's allocator.
        pub fn getCloned(self: *const Self, allocator: std.mem.Allocator, key: PkType) !?T {
            if (self.map.get(key)) |item| {
                return try self.cloneItem(item, allocator);
            }
            return null;
        }

        /// Gets a direct pointer to the item in memory.
        pub fn getPtr(self: *Self, key: PkType) ?*T {
            return self.map.getPtr(key);
        }

        /// Checks if key exists.
        pub fn contains(self: *const Self, key: PkType) bool {
            return self.map.contains(key);
        }

        /// Deletes an item by primary key. Returns true if removed.
        pub fn delete(self: *Self, key: PkType) bool {
            if (self.map.fetchRemove(key)) |kv| {
                var val = kv.value;
                self.freeItem(&val);
                return true;
            }
            return false;
        }

        /// Returns total count of items.
        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        /// Returns all items cloned into caller's allocator.
        pub fn getAll(self: *const Self, allocator: std.mem.Allocator) ![]T {
            var list = std.ArrayList(T).empty;
            errdefer {
                for (list.items) |*item| {
                    if (comptime @hasDecl(T, "deinit")) item.deinit(allocator);
                }
                list.deinit(allocator);
            }

            var it = self.map.iterator();
            while (it.next()) |entry| {
                const cloned = try self.cloneItem(entry.value_ptr.*, allocator);
                try list.append(allocator, cloned);
            }

            return try list.toOwnedSlice(allocator);
        }

        /// Clears all items.
        pub fn clear(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.freeItem(entry.value_ptr);
            }
            self.map.clearRetainingCapacity();
        }
    };
}
