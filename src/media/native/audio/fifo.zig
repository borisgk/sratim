const std = @import("std");

/// A pure Zig planar stereo PCM sample FIFO buffer.
/// Stores left and right channel f32 samples and provides efficient push/pop operations
/// for bridging decoders and encoders with differing frame sizes (e.g. AC-3's 1536 samples
/// to AAC's 1024 samples) with zero C library dependencies.
pub const AudioFifo = struct {
    left: std.ArrayList(f32),
    right: std.ArrayList(f32),
    read_pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AudioFifo {
        return .{
            .left = .empty,
            .right = .empty,
            .read_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AudioFifo) void {
        self.left.deinit(self.allocator);
        self.right.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns the number of stereo samples currently available to read.
    pub fn size(self: *const AudioFifo) usize {
        return self.left.items.len - self.read_pos;
    }

    /// Compacts the internal buffer if read_pos has advanced substantially,
    /// reclaiming unread capacity without reallocating.
    fn compactIfNeeded(self: *AudioFifo) void {
        if (self.read_pos == 0) return;

        if (self.read_pos == self.left.items.len) {
            self.left.clearRetainingCapacity();
            self.right.clearRetainingCapacity();
            self.read_pos = 0;
        } else if (self.read_pos >= 4096) {
            const rem = self.size();
            std.mem.copyForwards(f32, self.left.items[0..rem], self.left.items[self.read_pos..]);
            std.mem.copyForwards(f32, self.right.items[0..rem], self.right.items[self.read_pos..]);
            self.left.items.len = rem;
            self.right.items.len = rem;
            self.read_pos = 0;
        }
    }

    /// Pushes planar stereo slices into the FIFO. Both slices must be the same length.
    pub fn write(self: *AudioFifo, l: []const f32, r: []const f32) !void {
        std.debug.assert(l.len == r.len);
        if (l.len == 0) return;

        self.compactIfNeeded();
        try self.left.appendSlice(self.allocator, l);
        try self.right.appendSlice(self.allocator, r);
    }

    /// Pushes interleaved stereo samples ([L0, R0, L1, R1, ...]) into the planar FIFO.
    pub fn writeInterleaved(self: *AudioFifo, samples: []const f32) !void {
        const n_samples = samples.len / 2;
        if (n_samples == 0) return;

        self.compactIfNeeded();

        const old_len = self.left.items.len;
        try self.left.resize(self.allocator, old_len + n_samples);
        try self.right.resize(self.allocator, old_len + n_samples);

        for (0..n_samples) |i| {
            self.left.items[old_len + i] = samples[i * 2 + 0];
            self.right.items[old_len + i] = samples[i * 2 + 1];
        }
    }

    /// Reads up to out_l.len samples into out_l and out_r. Both destination slices
    /// must be of equal length. Returns the number of samples actually read.
    pub fn read(self: *AudioFifo, out_l: []f32, out_r: []f32) usize {
        std.debug.assert(out_l.len == out_r.len);
        const avail = self.size();
        const count = @min(out_l.len, avail);
        if (count == 0) return 0;

        @memcpy(out_l[0..count], self.left.items[self.read_pos .. self.read_pos + count]);
        @memcpy(out_r[0..count], self.right.items[self.read_pos .. self.read_pos + count]);
        self.read_pos += count;

        return count;
    }

    /// Discards all samples currently in the FIFO without releasing capacity.
    pub fn clear(self: *AudioFifo) void {
        self.left.clearRetainingCapacity();
        self.right.clearRetainingCapacity();
        self.read_pos = 0;
    }
};
