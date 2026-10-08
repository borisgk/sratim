# zembed

A universal, ultra-fast embedded database engine for Zig 0.17+, providing in-memory indexing, binary write-ahead logging (WAL) with CRC32 framing, atomic snapshot persistence, and append-only event streams.

---

## Features

- **Compile-Time Table Reflection (`Table`)**:
  - Automatically introspects structs at compile time (`@typeInfo`).
  - Supports string slices (`[]const u8`), integers (`i64`, `u64`), or UUIDs as primary keys.
  - Automatically handles memory cloning and deinitialization for nested allocations (`clone(allocator)`, `deinit(allocator)`).
  - Built-in auto-increment support for integer keys.
  - Full collection iterator support (`iterator()`, `valueIterator()`, `keyIterator()`).

- **Append-Only Streams (`Stream`)**:
  - High-throughput event logs for telemetry, analytics, and audit logging.
  - Optional ring-buffer capacity bounding with oldest-item auto-eviction.
  - Synchronized `.items` slice view and full lifecycle management.

- **Binary Write-Ahead Logging (`WalWriter` / `WalReader`)**:
  - Framed binary records: `[Magic (4B) | PayloadLen (4B) | CRC32 (4B) | Payload]`.
  - Incremental replay with automatic corruption detection and truncation recovery.
  - Checkpointed compaction when exceeding byte size or record limits.

- **Atomic Snapshot Persistence (`snapshot.saveAtomic`)**:
  - Crash-safe atomic flushes using temporary file write + atomic directory replace.

- **Coordinator Engine (`Engine`)**:
  - Central coordinator holding background compaction policy, snapshot management, and WAL lifecycle.

---

## Installation

Add `zembed` to your `build.zig.zon`:

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .dependencies = .{
        .zembed = .{
            .url = "https://github.com/borisgk/zembed/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

In your `build.zig`:

```zig
const zembed_dep = b.dependency("zembed", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zembed", zembed_dep.module("zembed"));
```

---

## Quick Start

### 1. In-Memory Typed Table

```zig
const std = @import("std");
const zembed = @import("zembed");

const User = struct {
    id: i64 = 0,
    username: []const u8,
    email: []const u8,

    pub fn clone(self: User, allocator: std.mem.Allocator) !User {
        return .{
            .id = self.id,
            .username = try allocator.dupe(u8, self.username),
            .email = try allocator.dupe(u8, self.email),
        };
    }

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.email);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var users = zembed.Table(User, .{
        .primary_key = "id",
        .auto_increment = true,
    }).init(allocator);
    defer users.deinit();

    // Insert user (auto-increments id: 1)
    const id = try users.insert(.{
        .username = "alice",
        .email = "alice@example.com",
    });

    if (users.get(id)) |u| {
        std.debug.print("User: {s} <{s}>\n", .{ u.username, u.email });
    }
}
```

### 2. Append-Only Event Stream

```zig
const LogEntry = struct {
    timestamp: i64,
    message: []const u8,
};

var log_stream = zembed.Stream(LogEntry).init(allocator, 1000); // Max 1000 items
defer log_stream.deinit();

try log_stream.append(.{ .timestamp = 1234567890, .message = "system started" });
for (log_stream.items) |entry| {
    std.debug.print("[{d}] {s}\n", .{ entry.timestamp, entry.message });
}
```

---

## Testing

Run the test suite using Zig 0.17:

```bash
zig build test
```

---

## License

MIT License.
