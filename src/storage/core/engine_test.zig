const std = @import("std");
const core = @import("mod.zig");

const testing = std.testing;

const TestUser = struct {
    id: i64 = 0,
    username: []const u8,
    email: []const u8,
    is_active: bool = true,

    pub fn clone(self: TestUser, allocator: std.mem.Allocator) !TestUser {
        return .{
            .id = self.id,
            .username = try allocator.dupe(u8, self.username),
            .email = try allocator.dupe(u8, self.email),
            .is_active = self.is_active,
        };
    }

    pub fn deinit(self: *TestUser, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.email);
    }
};

const TestProduct = struct {
    sku: []const u8,
    price_cents: u32,
    stock: u32,

    pub fn clone(self: TestProduct, allocator: std.mem.Allocator) !TestProduct {
        return .{
            .sku = try allocator.dupe(u8, self.sku),
            .price_cents = self.price_cents,
            .stock = self.stock,
        };
    }

    pub fn deinit(self: *TestProduct, allocator: std.mem.Allocator) void {
        allocator.free(self.sku);
    }
};

const TestLog = struct {
    timestamp: i64,
    event: []const u8,

    pub fn clone(self: TestLog, allocator: std.mem.Allocator) !TestLog {
        return .{
            .timestamp = self.timestamp,
            .event = try allocator.dupe(u8, self.event),
        };
    }

    pub fn deinit(self: *TestLog, allocator: std.mem.Allocator) void {
        allocator.free(self.event);
    }
};

test "Universal Engine: Table with integer auto-increment primary key" {
    const allocator = testing.allocator;

    var users = core.Table(TestUser, .{ .primary_key = "id", .auto_increment = true }).init(allocator);
    defer users.deinit();

    // 1. Insert with auto-increment
    const id1 = try users.insert(.{ .username = "alice", .email = "alice@example.com" });
    try testing.expectEqual(@as(i64, 1), id1);

    const id2 = try users.insert(.{ .username = "bob", .email = "bob@example.com" });
    try testing.expectEqual(@as(i64, 2), id2);

    try testing.expectEqual(@as(usize, 2), users.count());

    // 2. Lookup
    const alice_opt = try users.get(allocator, id1);
    try testing.expect(alice_opt != null);
    var alice = alice_opt.?;
    defer alice.deinit(allocator);
    try testing.expectEqualStrings("alice", alice.username);
    try testing.expectEqualStrings("alice@example.com", alice.email);

    // 3. Update
    _ = try users.insert(.{ .id = id1, .username = "alice_updated", .email = "alice2@example.com" });
    const alice_upd = (try users.get(allocator, id1)).?;
    defer {
        var m = alice_upd;
        m.deinit(allocator);
    }
    try testing.expectEqualStrings("alice_updated", alice_upd.username);

    // 4. GetAll
    const all = try users.getAll(allocator);
    defer {
        for (all) |*u| u.deinit(allocator);
        allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 2), all.len);

    // 5. Delete
    try testing.expect(users.delete(id1));
    try testing.expect(!users.contains(id1));
    try testing.expectEqual(@as(usize, 1), users.count());
}

test "Universal Engine: Table with string primary key" {
    const allocator = testing.allocator;

    var products = core.Table(TestProduct, .{ .primary_key = "sku", .auto_increment = false }).init(allocator);
    defer products.deinit();

    const p1_key = try products.insert(.{ .sku = "SKU-100", .price_cents = 1999, .stock = 50 });
    try testing.expectEqualStrings("SKU-100", p1_key);

    const p2_key = try products.insert(.{ .sku = "SKU-200", .price_cents = 4999, .stock = 10 });
    try testing.expectEqualStrings("SKU-200", p2_key);

    try testing.expect(products.contains("SKU-100"));
    try testing.expect(products.contains("SKU-200"));
    try testing.expect(!products.contains("SKU-999"));

    const item = (try products.get(allocator, "SKU-200")).?;
    defer {
        var m = item;
        m.deinit(allocator);
    }
    try testing.expectEqual(@as(u32, 4999), item.price_cents);

    try testing.expect(products.delete("SKU-100"));
    try testing.expectEqual(@as(usize, 1), products.count());
}

test "Universal Engine: Stream append-only log with capacity limit" {
    const allocator = testing.allocator;

    var stream = core.Stream(TestLog).init(allocator, 2);
    defer stream.deinit();

    try stream.append(.{ .timestamp = 100, .event = "first" });
    try stream.append(.{ .timestamp = 200, .event = "second" });
    try testing.expectEqual(@as(usize, 2), stream.count());

    // 3rd item should evict the oldest "first"
    try stream.append(.{ .timestamp = 300, .event = "third" });
    try testing.expectEqual(@as(usize, 2), stream.count());
    try testing.expectEqualStrings("second", stream.items()[0].event);
    try testing.expectEqualStrings("third", stream.items()[1].event);
}

test "Universal Engine: WAL frame writer, CRC verification, and replay" {
    const allocator = testing.allocator;
    const wal_path = "tmp/test_universal.wal";
    std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    var writer = core.WalWriter.init(testing.io, wal_path, true);

    try writer.append(1, .insert, "payload_one");
    try writer.append(1, .insert, "payload_two");
    try writer.append(2, .delete, "payload_three");

    try testing.expectEqual(@as(usize, 3), writer.uncompacted_records);

    const Collector = struct {
        records: std.ArrayList(core.WalRecord),

        fn apply(self: *@This(), rec: core.WalRecord) !void {
            const owned = try testing.allocator.dupe(u8, rec.payload);
            try self.records.append(testing.allocator, .{
                .collection_id = rec.collection_id,
                .opcode = rec.opcode,
                .payload = owned,
            });
        }

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            for (self.records.items) |r| alloc.free(r.payload);
            self.records.deinit(alloc);
        }
    };

    var collector = Collector{ .records = std.ArrayList(core.WalRecord).empty };
    defer collector.deinit(allocator);

    const replayed = try core.WalReader.replay(allocator, testing.io, wal_path, &collector, Collector.apply);
    try testing.expectEqual(@as(usize, 3), replayed);
    try testing.expectEqualStrings("payload_one", collector.records.items[0].payload);
    try testing.expectEqualStrings("payload_two", collector.records.items[1].payload);
    try testing.expectEqualStrings("payload_three", collector.records.items[2].payload);
}

test "Universal Engine: Engine coordinator atomic snapshot and WAL compaction" {
    const allocator = testing.allocator;
    const snap_path = "tmp/test_engine_snap.json";
    const wal_path = "tmp/test_engine_wal.wal";
    std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    var engine = core.Engine.init(allocator, testing.io, .{
        .snapshot_path = snap_path,
        .wal_path = wal_path,
        .max_wal_records = 3,
    });

    try engine.writeWal(10, .insert, "record_a");
    try engine.writeWal(10, .insert, "record_b");
    try testing.expect(!engine.shouldCompact());

    try engine.writeWal(10, .insert, "record_c");
    try testing.expect(engine.shouldCompact());

    // Save snapshot flushes and resets WAL
    try engine.saveSnapshot("{\"state\":\"checkpointed\"}");
    try testing.expect(!engine.shouldCompact());

    const loaded = (try engine.loadSnapshot(1024)).?;
    defer allocator.free(loaded);
    try testing.expectEqualStrings("{\"state\":\"checkpointed\"}", loaded);
}
