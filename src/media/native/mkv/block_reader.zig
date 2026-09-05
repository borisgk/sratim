const std = @import("std");
const ebml = @import("../ebml.zig");
const types = @import("types.zig");

const MkvBlock = types.MkvBlock;
const MkvLacingType = types.MkvLacingType;

pub const BlockReader = struct {
    file_reader: *std.Io.Reader,
    current_cluster_timecode_ms: u64 = 0,
    timecode_scale_ns: u64 = 1_000_000, // Default 1ms
    queue: [64]MkvBlock = undefined,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    audio_track_num: u64 = 0,
    audio_samples_per_frame: u32 = 1024,
    audio_sample_rate: u32 = 48000,

    pub fn init(file_reader: *std.Io.Reader, timecode_scale_ns: u64) BlockReader {
        return .{
            .file_reader = file_reader,
            .timecode_scale_ns = timecode_scale_ns,
            .queue_head = 0,
            .queue_tail = 0,
        };
    }

    pub fn setAudioTrackParams(self: *BlockReader, track_num: u64, samples_per_frame: u32, sample_rate: u32) void {
        self.audio_track_num = track_num;
        self.audio_samples_per_frame = samples_per_frame;
        self.audio_sample_rate = if (sample_rate > 0) sample_rate else 48000;
    }

    /// Reads the next media block from the container.
    pub fn readNextBlock(self: *BlockReader, current_pos: *u64) !?MkvBlock {
        if (self.queue_head < self.queue_tail) {
            const blk = self.queue[self.queue_head];
            self.queue_head += 1;
            return blk;
        }
        self.queue_head = 0;
        self.queue_tail = 0;

        const r = self.file_reader;

        while (true) {
            const elem = (try ebml.readElementHeader(r)) orelse return null;
            current_pos.* += elem.header_size;

            if (elem.id == ebml.ID_CLUSTER or elem.id == ebml.ID_SEGMENT) {
                // Entered Segment or Cluster container; parse sub-elements
                continue;
            } else if (elem.id == ebml.ID_CLUSTER_TIMESTAMP) {
                const tc = try ebml.readUint(r, elem.size);
                current_pos.* += elem.size;
                self.current_cluster_timecode_ms = (tc * self.timecode_scale_ns) / 1_000_000;
            } else if (elem.id == ebml.ID_SIMPLE_BLOCK) {
                return try self.parseBlockPayload(r, elem.size, current_pos, true);
            } else if (elem.id == ebml.ID_BLOCK_GROUP) {
                // BlockGroup contains Block (ID 0xA1) and optional BlockDuration (ID 0x9B)
                var bg_rem = elem.size;
                while (bg_rem > 0) {
                    const sub = (try ebml.readElementHeader(r)) orelse break;
                    current_pos.* += sub.header_size;
                    bg_rem -= sub.header_size;
                    const sub_size = @min(sub.size, bg_rem);

                    if (sub.id == 0xA1) { // Block
                        const blk = try self.parseBlockPayload(r, sub_size, current_pos, false);
                        if (sub.size != ebml.UNKNOWN_SIZE) bg_rem -= sub_size;
                        return blk;
                    } else {
                        try ebml.skipBytes(r, sub_size);
                        current_pos.* += sub_size;
                    }
                    if (sub.size != ebml.UNKNOWN_SIZE) bg_rem -= sub_size;
                }
            } else {
                if (elem.size == ebml.UNKNOWN_SIZE) break;
                try ebml.skipBytes(r, elem.size);
                current_pos.* += elem.size;
            }
        }

        return null;
    }

    fn parseBlockPayload(
        self: *BlockReader,
        r: *std.Io.Reader,
        block_size: u64,
        current_pos: *u64,
        is_simple_block: bool,
    ) !?MkvBlock {
        var bytes_consumed: u64 = 0;

        // 1. Read Track Number (EBML VINT)
        var first_byte_buf: [1]u8 = undefined;
        try r.readSliceAll(&first_byte_buf);
        bytes_consumed += 1;

        const first_byte = first_byte_buf[0];
        if (first_byte == 0) return null;

        var num_bytes: usize = 1;
        var mask: u8 = 0x80;
        while ((first_byte & mask) == 0 and num_bytes <= 8) : (mask >>= 1) {
            num_bytes += 1;
        }

        var track_num: u64 = first_byte & (mask - 1);
        if (num_bytes > 1) {
            var rest: [7]u8 = undefined;
            const to_read = num_bytes - 1;
            try r.readSliceAll(rest[0..to_read]);
            bytes_consumed += to_read;
            for (0..to_read) |i| {
                track_num = (track_num << 8) | rest[i];
            }
        }

        // 2. Read Timecode (signed 16-bit relative to cluster timecode)
        var tc_buf: [2]u8 = undefined;
        try r.readSliceAll(&tc_buf);
        bytes_consumed += 2;
        const rel_tc_raw = std.mem.readInt(u16, &tc_buf, .big);
        const rel_tc: i16 = @bitCast(rel_tc_raw);

        // 3. Read Flags (1 byte)
        var flags_buf: [1]u8 = undefined;
        try r.readSliceAll(&flags_buf);
        bytes_consumed += 1;
        const flags = flags_buf[0];

        const is_keyframe = if (is_simple_block) (flags & 0x80) != 0 else false;
        const is_discardable = (flags & 0x01) != 0;
        const lacing_bits: u2 = @intCast((flags >> 1) & 0x03);
        const lacing: MkvLacingType = @enumFromInt(lacing_bits);

        const pts_calc = @as(i64, @intCast(self.current_cluster_timecode_ms)) + @as(i64, rel_tc);
        const pts_ms: u64 = if (pts_calc >= 0) @intCast(pts_calc) else 0;
        const pts_sec = @as(f64, @floatFromInt(pts_ms)) / 1000.0;

        const payload_offset = current_pos.* + bytes_consumed;
        const payload_size: u32 = if (block_size >= bytes_consumed)
            @intCast(block_size - bytes_consumed)
        else
            0;

        if (lacing == .None) {
            try ebml.skipBytes(r, payload_size);
            current_pos.* += block_size;
            return MkvBlock{
                .track_num = track_num,
                .pts_ms = pts_ms,
                .pts_sec = pts_sec,
                .is_keyframe = is_keyframe,
                .is_discardable = is_discardable,
                .payload_offset = payload_offset,
                .payload_size = payload_size,
            };
        }

        // Handle Laced Frames
        if (payload_size < 1) {
            current_pos.* += block_size;
            return null;
        }

        const lacing_header_start = bytes_consumed;

        var num_frames_buf: [1]u8 = undefined;
        try r.readSliceAll(&num_frames_buf);
        bytes_consumed += 1;
        const num_frames = @as(usize, num_frames_buf[0]) + 1;
        if (num_frames > 64) return error.TooManyLacedFrames;

        var frame_sizes: [64]u32 = [_]u32{0} ** 64;

        if (lacing == .Fixed) {
            const total_frames_bytes = payload_size - 1;
            const single_frame_size = @as(u32, @intCast(total_frames_bytes / num_frames));
            for (0..num_frames) |i| {
                frame_sizes[i] = single_frame_size;
            }
        } else if (lacing == .Xiph) {
            var sum_prev: u32 = 0;
            for (0..num_frames - 1) |i| {
                var s: u32 = 0;
                while (true) {
                    var b: [1]u8 = undefined;
                    try r.readSliceAll(&b);
                    bytes_consumed += 1;
                    s += b[0];
                    if (b[0] < 255) break;
                }
                frame_sizes[i] = s;
                sum_prev += s;
            }
            const lacing_header_len = bytes_consumed - lacing_header_start;
            const total_frames_data_len = payload_size - @as(u32, @intCast(lacing_header_len));
            frame_sizes[num_frames - 1] = if (total_frames_data_len >= sum_prev) total_frames_data_len - sum_prev else 0;
        } else if (lacing == .Ebml) {
            // First frame size: unsigned EBML VINT
            var fv_byte_buf: [1]u8 = undefined;
            try r.readSliceAll(&fv_byte_buf);
            bytes_consumed += 1;
            const fv_byte = fv_byte_buf[0];
            var fv_len: usize = 1;
            var fv_mask: u8 = 0x80;
            while ((fv_byte & fv_mask) == 0 and fv_len <= 8) : (fv_mask >>= 1) {
                fv_len += 1;
            }
            var f0_size: u64 = fv_byte & (fv_mask - 1);
            if (fv_len > 1) {
                var fv_rest: [7]u8 = undefined;
                const to_read = fv_len - 1;
                try r.readSliceAll(fv_rest[0..to_read]);
                bytes_consumed += to_read;
                for (0..to_read) |k| {
                    f0_size = (f0_size << 8) | fv_rest[k];
                }
            }
            frame_sizes[0] = @intCast(f0_size);
            var sum_prev: u32 = frame_sizes[0];

            // Remaining frames 1..num_frames-2: signed difference EBML VINT
            for (1..num_frames - 1) |i| {
                var diff_byte_buf: [1]u8 = undefined;
                try r.readSliceAll(&diff_byte_buf);
                bytes_consumed += 1;
                const d_byte = diff_byte_buf[0];
                var d_len: usize = 1;
                var d_mask: u8 = 0x80;
                while ((d_byte & d_mask) == 0 and d_len <= 8) : (d_mask >>= 1) {
                    d_len += 1;
                }
                var diff_vint: u64 = d_byte & (d_mask - 1);
                if (d_len > 1) {
                    var d_rest: [7]u8 = undefined;
                    const to_read = d_len - 1;
                    try r.readSliceAll(d_rest[0..to_read]);
                    bytes_consumed += to_read;
                    for (0..to_read) |k| {
                        diff_vint = (diff_vint << 8) | d_rest[k];
                    }
                }
                const bias: u64 = (@as(u64, 1) << @intCast(7 * d_len - 1)) - 1;
                const delta: i64 = @as(i64, @intCast(diff_vint)) - @as(i64, @intCast(bias));
                const next_size: i64 = @as(i64, @intCast(frame_sizes[i - 1])) + delta;
                frame_sizes[i] = @intCast(@max(0, next_size));
                sum_prev += frame_sizes[i];
            }
            const lacing_header_len = bytes_consumed - lacing_header_start;
            const total_frames_data_len = payload_size - @as(u32, @intCast(lacing_header_len));
            frame_sizes[num_frames - 1] = if (total_frames_data_len >= sum_prev) total_frames_data_len - sum_prev else 0;
        }

        const spf: u64 = if (track_num == self.audio_track_num) self.audio_samples_per_frame else 1024;
        const sr: u64 = if (track_num == self.audio_track_num) self.audio_sample_rate else 48000;
        const spf_f: f64 = @floatFromInt(spf);
        const sr_f: f64 = @floatFromInt(sr);
        var current_frame_offset = current_pos.* + bytes_consumed;
        for (0..num_frames) |i| {
            const f_size = frame_sizes[i];
            const f_pts_ms = pts_ms + (@as(u64, i) * spf * 1000) / sr;
            const f_pts_sec = pts_sec + (@as(f64, @floatFromInt(i)) * (spf_f / sr_f));
            self.queue[self.queue_tail] = MkvBlock{
                .track_num = track_num,
                .pts_ms = f_pts_ms,
                .pts_sec = f_pts_sec,
                .is_keyframe = is_keyframe,
                .is_discardable = is_discardable,
                .payload_offset = current_frame_offset,
                .payload_size = f_size,
            };
            self.queue_tail += 1;
            current_frame_offset += f_size;
        }

        const remaining_to_skip = block_size - bytes_consumed;
        try ebml.skipBytes(r, remaining_to_skip);
        current_pos.* += block_size;

        const first_unlaced = self.queue[self.queue_head];
        self.queue_head += 1;
        return first_unlaced;
    }
};
