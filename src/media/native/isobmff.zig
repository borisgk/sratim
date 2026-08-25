const std = @import("std");

pub const BoxHeader = struct {
    type: [4]u8,
    size: u64,
    header_size: usize,
    data_offset: u64,

    pub fn dataSize(self: BoxHeader) u64 {
        if (self.size == std.math.maxInt(u64)) return std.math.maxInt(u64);
        return if (self.size >= self.header_size) self.size - self.header_size else 0;
    }
};

pub const SttsEntry = struct {
    count: u32,
    delta: u32,
};

pub const StscEntry = struct {
    first_chunk: u32,
    samples_per_chunk: u32,
    sample_desc_index: u32,
};

pub const SubtitleSample = struct {
    start_sec: f64,
    end_sec: f64,
    offset: u64,
    size: u32,
};

pub const Mp4SubtitleTrack = struct {
    track_id: u32,
    stream_idx: usize,
    handler_type: [4]u8,
    timescale: u32,
    format: [4]u8,
    samples: []SubtitleSample,

    pub fn deinit(self: *Mp4SubtitleTrack, allocator: std.mem.Allocator) void {
        if (self.samples.len > 0) {
            allocator.free(self.samples);
        }
    }
};

/// Reads an ISOBMFF Box header from the reader.
pub fn readBoxHeader(r: *std.Io.Reader, current_pos: u64) !?BoxHeader {
    var hdr_buf: [8]u8 = undefined;
    r.readSliceAll(&hdr_buf) catch |err| {
        if (err == error.EndOfStream) return null;
        return err;
    };

    const size32 = std.mem.readInt(u32, hdr_buf[0..4], .big);
    const box_type = hdr_buf[4..8].*;

    var size: u64 = size32;
    var header_size: usize = 8;

    if (size32 == 1) {
        var ext_size_buf: [8]u8 = undefined;
        try r.readSliceAll(&ext_size_buf);
        size = std.mem.readInt(u64, &ext_size_buf, .big);
        header_size = 16;
    } else if (size32 == 0) {
        // Extends to end of file
        size = std.math.maxInt(u64);
        header_size = 8;
    }

    return BoxHeader{
        .type = box_type,
        .size = size,
        .header_size = header_size,
        .data_offset = current_pos + header_size,
    };
}

pub fn isFourCC(box_type: [4]u8, expected: *const [4]u8) bool {
    return std.mem.eql(u8, &box_type, expected);
}

pub fn isMp4Container(header_bytes: []const u8) bool {
    if (header_bytes.len < 8) return false;
    const box_type = header_bytes[4..8];
    return isFourCC(box_type.*, "ftyp") or
        isFourCC(box_type.*, "moov") or
        isFourCC(box_type.*, "mdat") or
        isFourCC(box_type.*, "free") or
        isFourCC(box_type.*, "wide") or
        isFourCC(box_type.*, "skip");
}

pub fn isSubtitleHandler(hdlr_type: [4]u8) bool {
    return isFourCC(hdlr_type, "sbtl") or
        isFourCC(hdlr_type, "text") or
        isFourCC(hdlr_type, "subt") or
        isFourCC(hdlr_type, "clcp");
}

/// Skips `count` bytes using the reader interface.
pub fn skipBytes(r: *std.Io.Reader, count: u64) !void {
    var rem = count;
    var discard_buf: [4096]u8 = undefined;
    while (rem > 0) {
        const to_read: usize = @intCast(@min(rem, discard_buf.len));
        try r.readSliceAll(discard_buf[0..to_read]);
        rem -= to_read;
    }
}

/// Parses the full sample timing and file offset list for an MP4 subtitle track.
pub fn buildSampleList(
    allocator: std.mem.Allocator,
    timescale: u32,
    stts_entries: []const SttsEntry,
    stsc_entries: []const StscEntry,
    stsz_uniform_size: u32,
    stsz_entries: []const u32,
    chunk_offsets: []const u64,
) ![]SubtitleSample {
    if (timescale == 0 or chunk_offsets.len == 0 or stsc_entries.len == 0 or stts_entries.len == 0) {
        return &.{};
    }

    var total_samples: usize = 0;
    if (stsz_uniform_size != 0) {
        for (stts_entries) |entry| total_samples += entry.count;
    } else {
        total_samples = stsz_entries.len;
    }

    if (total_samples == 0) return &.{};

    var samples = try allocator.alloc(SubtitleSample, total_samples);
    errdefer allocator.free(samples);

    // 1. Calculate sample start and end times from STTS table
    var current_sample_idx: usize = 0;
    var current_pts: u64 = 0;
    const timescale_f = @as(f64, @floatFromInt(timescale));

    for (stts_entries) |entry| {
        var c: u32 = 0;
        while (c < entry.count and current_sample_idx < total_samples) : (c += 1) {
            const start_sec = @as(f64, @floatFromInt(current_pts)) / timescale_f;
            current_pts += entry.delta;
            const end_sec = @as(f64, @floatFromInt(current_pts)) / timescale_f;

            samples[current_sample_idx].start_sec = start_sec;
            samples[current_sample_idx].end_sec = end_sec;
            samples[current_sample_idx].size = if (stsz_uniform_size != 0) stsz_uniform_size else stsz_entries[current_sample_idx];
            current_sample_idx += 1;
        }
    }

    // 2. Map sample offsets using STSC and STCO/CO64 tables
    var chunk_idx: usize = 0; // 0-based chunk index
    var sample_idx: usize = 0;
    var stsc_idx: usize = 0;

    while (chunk_idx < chunk_offsets.len and sample_idx < total_samples) {
        while (stsc_idx + 1 < stsc_entries.len and
            (chunk_idx + 1) >= stsc_entries[stsc_idx + 1].first_chunk)
        {
            stsc_idx += 1;
        }

        const samples_in_this_chunk = stsc_entries[stsc_idx].samples_per_chunk;
        var offset_in_chunk = chunk_offsets[chunk_idx];

        var s: u32 = 0;
        while (s < samples_in_this_chunk and sample_idx < total_samples) : (s += 1) {
            samples[sample_idx].offset = offset_in_chunk;
            offset_in_chunk += samples[sample_idx].size;
            sample_idx += 1;
        }

        chunk_idx += 1;
    }

    return samples;
}

/// Parses an entire MP4 file to locate and extract sample metadata for a specific subtitle stream index.
pub fn parseMp4SubtitleTrack(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    target_stream_idx: usize,
) !?Mp4SubtitleTrack {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    var current_stream_idx: usize = 0;

    // Scan top-level boxes to find 'moov'
    while (true) {
        const box = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;

        if (isFourCC(box.type, "moov")) {
            // Traverse inside 'moov'
            var moov_rem = box.dataSize();
            while (moov_rem >= 8) {
                const moov_child = (try readBoxHeader(r, file_reader.logicalPos())) orelse break;
                moov_rem -= moov_child.header_size;
                const child_data_size = @min(moov_child.dataSize(), moov_rem);

                if (isFourCC(moov_child.type, "trak")) {
                    const track_stream_idx = current_stream_idx;
                    current_stream_idx += 1;

                    if (track_stream_idx == target_stream_idx) {
                        const trk_opt = try parseTrackBox(allocator, r, moov_child, track_stream_idx);
                        if (trk_opt) |trk| {
                            return trk;
                        }
                    } else {
                        try skipBytes(r, child_data_size);
                    }
                } else {
                    try skipBytes(r, child_data_size);
                }
                moov_rem -= child_data_size;
            }
            break;
        } else {
            if (box.dataSize() == std.math.maxInt(u64)) break;
            try skipBytes(r, box.dataSize());
        }
    }

    return null;
}

fn parseTrackBox(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    trak_box: BoxHeader,
    stream_idx: usize,
) !?Mp4SubtitleTrack {
    var trak_rem = trak_box.dataSize();
    var track_id: u32 = @intCast(stream_idx + 1);

    var timescale: u32 = 1000;
    var handler_type: [4]u8 = [_]u8{ 0, 0, 0, 0 };
    var format: [4]u8 = "tx3g".*;

    var stts_list = std.ArrayList(SttsEntry).empty;
    defer stts_list.deinit(allocator);

    var stsc_list = std.ArrayList(StscEntry).empty;
    defer stsc_list.deinit(allocator);

    var stsz_uniform: u32 = 0;
    var stsz_list = std.ArrayList(u32).empty;
    defer stsz_list.deinit(allocator);

    var stco_list = std.ArrayList(u64).empty;
    defer stco_list.deinit(allocator);

    while (trak_rem >= 8) {
        const child = (try readBoxHeader(r, 0)) orelse break;
        trak_rem -= child.header_size;
        const child_data_size = @min(child.dataSize(), trak_rem);

        if (isFourCC(child.type, "tkhd")) {
            if (child_data_size >= 24) {
                var tkhd_buf: [32]u8 = undefined;
                const to_read = @min(child_data_size, tkhd_buf.len);
                try r.readSliceAll(tkhd_buf[0..to_read]);
                const version = tkhd_buf[0];
                if (version == 0 and to_read >= 16) {
                    track_id = std.mem.readInt(u32, tkhd_buf[12..16], .big);
                } else if (version == 1 and to_read >= 24) {
                    track_id = std.mem.readInt(u32, tkhd_buf[20..24], .big);
                }
                try skipBytes(r, child_data_size - to_read);
            } else {
                try skipBytes(r, child_data_size);
            }
        } else if (isFourCC(child.type, "mdia")) {
            var mdia_rem = child_data_size;
            while (mdia_rem >= 8) {
                const mdia_child = (try readBoxHeader(r, 0)) orelse break;
                mdia_rem -= mdia_child.header_size;
                const m_data_size = @min(mdia_child.dataSize(), mdia_rem);

                if (isFourCC(mdia_child.type, "mdhd")) {
                    if (m_data_size >= 24) {
                        var mdhd_buf: [32]u8 = undefined;
                        const to_read = @min(m_data_size, mdhd_buf.len);
                        try r.readSliceAll(mdhd_buf[0..to_read]);
                        const version = mdhd_buf[0];
                        if (version == 0 and to_read >= 16) {
                            timescale = std.mem.readInt(u32, mdhd_buf[12..16], .big);
                        } else if (version == 1 and to_read >= 24) {
                            timescale = std.mem.readInt(u32, mdhd_buf[20..24], .big);
                        }
                        try skipBytes(r, m_data_size - to_read);
                    } else {
                        try skipBytes(r, m_data_size);
                    }
                } else if (isFourCC(mdia_child.type, "hdlr")) {
                    if (m_data_size >= 12) {
                        var hdlr_buf: [12]u8 = undefined;
                        try r.readSliceAll(&hdlr_buf);
                        handler_type = hdlr_buf[8..12].*;
                        try skipBytes(r, m_data_size - 12);
                    } else {
                        try skipBytes(r, m_data_size);
                    }
                } else if (isFourCC(mdia_child.type, "minf")) {
                    var minf_rem = m_data_size;
                    while (minf_rem >= 8) {
                        const minf_child = (try readBoxHeader(r, 0)) orelse break;
                        minf_rem -= minf_child.header_size;
                        const minf_data_size = @min(minf_child.dataSize(), minf_rem);

                        if (isFourCC(minf_child.type, "stbl")) {
                            var stbl_rem = minf_data_size;
                            while (stbl_rem >= 8) {
                                const stbl_child = (try readBoxHeader(r, 0)) orelse break;
                                stbl_rem -= stbl_child.header_size;
                                const stbl_data_size = @min(stbl_child.dataSize(), stbl_rem);

                                if (isFourCC(stbl_child.type, "stsd")) {
                                    if (stbl_data_size >= 16) {
                                        var stsd_buf: [16]u8 = undefined;
                                        try r.readSliceAll(&stsd_buf);
                                        // Sample format is 4 bytes at offset 12 (after version, flags, entry_count, entry_size)
                                        format = stsd_buf[12..16].*;
                                        try skipBytes(r, stbl_data_size - 16);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "stts")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 8) break;
                                            var e_buf: [8]u8 = undefined;
                                            try r.readSliceAll(&e_buf);
                                            const count = std.mem.readInt(u32, e_buf[0..4], .big);
                                            const delta = std.mem.readInt(u32, e_buf[4..8], .big);
                                            try stts_list.append(allocator, .{ .count = count, .delta = delta });
                                            rem_bytes -= 8;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "stsc")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 12) break;
                                            var e_buf: [12]u8 = undefined;
                                            try r.readSliceAll(&e_buf);
                                            const f_chunk = std.mem.readInt(u32, e_buf[0..4], .big);
                                            const s_chunk = std.mem.readInt(u32, e_buf[4..8], .big);
                                            const s_idx = std.mem.readInt(u32, e_buf[8..12], .big);
                                            try stsc_list.append(allocator, .{ .first_chunk = f_chunk, .samples_per_chunk = s_chunk, .sample_desc_index = s_idx });
                                            rem_bytes -= 12;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "stsz")) {
                                    if (stbl_data_size >= 12) {
                                        var hdr: [12]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        stsz_uniform = std.mem.readInt(u32, hdr[4..8], .big);
                                        const count = std.mem.readInt(u32, hdr[8..12], .big);
                                        var rem_bytes = stbl_data_size - 12;

                                        if (stsz_uniform == 0) {
                                            for (0..count) |_| {
                                                if (rem_bytes < 4) break;
                                                var sz_buf: [4]u8 = undefined;
                                                try r.readSliceAll(&sz_buf);
                                                const sz = std.mem.readInt(u32, &sz_buf, .big);
                                                try stsz_list.append(allocator, sz);
                                                rem_bytes -= 4;
                                            }
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "stco")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 4) break;
                                            var off_buf: [4]u8 = undefined;
                                            try r.readSliceAll(&off_buf);
                                            const off = std.mem.readInt(u32, &off_buf, .big);
                                            try stco_list.append(allocator, @as(u64, off));
                                            rem_bytes -= 4;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "co64")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 8) break;
                                            var off_buf: [8]u8 = undefined;
                                            try r.readSliceAll(&off_buf);
                                            const off = std.mem.readInt(u64, &off_buf, .big);
                                            try stco_list.append(allocator, off);
                                            rem_bytes -= 8;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else {
                                    try skipBytes(r, stbl_data_size);
                                }
                                stbl_rem -= stbl_data_size;
                            }
                        } else {
                            try skipBytes(r, minf_data_size);
                        }
                        minf_rem -= minf_data_size;
                    }
                } else {
                    try skipBytes(r, m_data_size);
                }
                mdia_rem -= m_data_size;
            }
        } else {
            try skipBytes(r, child_data_size);
        }
        trak_rem -= child_data_size;
    }

    if (!isSubtitleHandler(handler_type)) {
        return null;
    }

    const samples = try buildSampleList(
        allocator,
        timescale,
        stts_list.items,
        stsc_list.items,
        stsz_uniform,
        stsz_list.items,
        stco_list.items,
    );

    return Mp4SubtitleTrack{
        .track_id = track_id,
        .stream_idx = stream_idx,
        .handler_type = handler_type,
        .timescale = timescale,
        .format = format,
        .samples = samples,
    };
}
