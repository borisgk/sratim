const std = @import("std");
const types = @import("types.zig");
const reader = @import("reader.zig");
const samples = @import("samples.zig");

const BoxHeader = types.BoxHeader;
const SttsEntry = types.SttsEntry;
const CttsEntry = types.CttsEntry;
const StscEntry = types.StscEntry;
const Mp4SubtitleTrack = types.Mp4SubtitleTrack;
const Mp4MediaTrack = types.Mp4MediaTrack;

const readBoxHeader = reader.readBoxHeader;
const skipBytes = reader.skipBytes;
const isFourCC = reader.isFourCC;
const isSubtitleHandler = reader.isSubtitleHandler;
const buildSampleList = samples.buildSampleList;
const buildMediaSampleList = samples.buildMediaSampleList;

/// Parses a subtitle trak box and extracts sample indexing.
pub fn parseSubtitleTrackBox(
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
                                        var stsd_hdr: [16]u8 = undefined;
                                        try r.readSliceAll(&stsd_hdr);
                                        const entry_count = std.mem.readInt(u32, stsd_hdr[12..16], .big);
                                        var rem = stbl_data_size - 16;
                                        if (entry_count > 0 and rem >= 8) {
                                            var entry_hdr: [8]u8 = undefined;
                                            try r.readSliceAll(&entry_hdr);
                                            format = entry_hdr[4..8].*;
                                            rem -= 8;
                                        }
                                        try skipBytes(r, rem);
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
                                            var row: [8]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const count = std.mem.readInt(u32, row[0..4], .big);
                                            const delta = std.mem.readInt(u32, row[4..8], .big);
                                            try stts_list.append(allocator, SttsEntry{ .count = count, .delta = delta });
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
                                            var row: [12]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const first_chunk = std.mem.readInt(u32, row[0..4], .big);
                                            const samples_per_chunk = std.mem.readInt(u32, row[4..8], .big);
                                            const sample_desc_index = std.mem.readInt(u32, row[8..12], .big);
                                            try stsc_list.append(allocator, StscEntry{
                                                .first_chunk = first_chunk,
                                                .samples_per_chunk = samples_per_chunk,
                                                .sample_desc_index = sample_desc_index,
                                            });
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

    const samples_res = try buildSampleList(
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
        .samples = samples_res,
    };
}

/// Parses a generic media track (video or audio) extracting complete sample tables and headers.
pub fn parseGenericTrackBox(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    trak_box: BoxHeader,
    stream_idx: usize,
) !?Mp4MediaTrack {
    var trak_rem = trak_box.dataSize();
    var track_id: u32 = @intCast(stream_idx + 1);

    var timescale: u32 = 1000;
    var duration: u64 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var volume: u16 = 0;
    var language: [4]u8 = "und\x00".*;
    var handler_type: [4]u8 = [_]u8{ 0, 0, 0, 0 };
    var stsd_raw = std.ArrayList(u8).empty;
    defer stsd_raw.deinit(allocator);

    var stts_list = std.ArrayList(SttsEntry).empty;
    defer stts_list.deinit(allocator);

    var ctts_list = std.ArrayList(CttsEntry).empty;
    defer ctts_list.deinit(allocator);

    var stss_list = std.ArrayList(u32).empty;
    defer stss_list.deinit(allocator);
    var has_stss = false;

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
            var tkhd_buf: [128]u8 = undefined;
            const to_read: usize = @intCast(@min(child_data_size, tkhd_buf.len));
            try r.readSliceAll(tkhd_buf[0..to_read]);

            const version = if (to_read > 0) tkhd_buf[0] else 0;
            if (version == 0 and to_read >= 84) {
                track_id = std.mem.readInt(u32, tkhd_buf[12..16], .big);
                duration = std.mem.readInt(u32, tkhd_buf[20..24], .big);
                volume = std.mem.readInt(u16, tkhd_buf[36..38], .big);
                width = std.mem.readInt(u32, tkhd_buf[76..80], .big) >> 16;
                height = std.mem.readInt(u32, tkhd_buf[80..84], .big) >> 16;
            } else if (version == 1 and to_read >= 96) {
                track_id = std.mem.readInt(u32, tkhd_buf[20..24], .big);
                duration = std.mem.readInt(u64, tkhd_buf[28..36], .big);
                volume = std.mem.readInt(u16, tkhd_buf[48..50], .big);
                width = std.mem.readInt(u32, tkhd_buf[88..92], .big) >> 16;
                height = std.mem.readInt(u32, tkhd_buf[92..96], .big) >> 16;
            }
            try skipBytes(r, child_data_size - to_read);
        } else if (isFourCC(child.type, "mdia")) {
            var mdia_rem = child_data_size;
            while (mdia_rem >= 8) {
                const mdia_child = (try readBoxHeader(r, 0)) orelse break;
                mdia_rem -= mdia_child.header_size;
                const m_data_size = @min(mdia_child.dataSize(), mdia_rem);

                if (isFourCC(mdia_child.type, "mdhd")) {
                    if (m_data_size >= 24) {
                        var mdhd_buf: [36]u8 = undefined;
                        const to_read = @min(m_data_size, mdhd_buf.len);
                        try r.readSliceAll(mdhd_buf[0..to_read]);
                        const version = mdhd_buf[0];
                        if (version == 0 and to_read >= 16) {
                            timescale = std.mem.readInt(u32, mdhd_buf[12..16], .big);
                            duration = std.mem.readInt(u32, mdhd_buf[16..20], .big);
                            if (to_read >= 22) {
                                const lang_packed = std.mem.readInt(u16, mdhd_buf[20..22], .big);
                                if (lang_packed > 0) {
                                    language[0] = @as(u8, @intCast(((lang_packed >> 10) & 0x1F) + 0x60));
                                    language[1] = @as(u8, @intCast(((lang_packed >> 5) & 0x1F) + 0x60));
                                    language[2] = @as(u8, @intCast((lang_packed & 0x1F) + 0x60));
                                    language[3] = 0;
                                }
                            }
                        } else if (version == 1 and to_read >= 28) {
                            timescale = std.mem.readInt(u32, mdhd_buf[20..24], .big);
                            duration = std.mem.readInt(u64, mdhd_buf[24..32], .big);
                            if (to_read >= 34) {
                                const lang_packed = std.mem.readInt(u16, mdhd_buf[32..34], .big);
                                if (lang_packed > 0) {
                                    language[0] = @as(u8, @intCast(((lang_packed >> 10) & 0x1F) + 0x60));
                                    language[1] = @as(u8, @intCast(((lang_packed >> 5) & 0x1F) + 0x60));
                                    language[2] = @as(u8, @intCast((lang_packed & 0x1F) + 0x60));
                                    language[3] = 0;
                                }
                            }
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
                                    // Save full raw stsd box including its 8-byte box header
                                    stsd_raw.clearRetainingCapacity();
                                    var hdr: [8]u8 = undefined;
                                    std.mem.writeInt(u32, hdr[0..4], @intCast(stbl_child.header_size + stbl_data_size), .big);
                                    @memcpy(hdr[4..8], "stsd");
                                    try stsd_raw.appendSlice(allocator, &hdr);

                                    var rem_bytes = stbl_data_size;
                                    var copy_buf: [4096]u8 = undefined;
                                    while (rem_bytes > 0) {
                                        const to_read: usize = @intCast(@min(rem_bytes, copy_buf.len));
                                        try r.readSliceAll(copy_buf[0..to_read]);
                                        try stsd_raw.appendSlice(allocator, copy_buf[0..to_read]);
                                        rem_bytes -= to_read;
                                    }
                                } else if (isFourCC(stbl_child.type, "stts")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 8) break;
                                            var row: [8]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const count = std.mem.readInt(u32, row[0..4], .big);
                                            const delta = std.mem.readInt(u32, row[4..8], .big);
                                            try stts_list.append(allocator, SttsEntry{ .count = count, .delta = delta });
                                            rem_bytes -= 8;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "ctts")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 8) break;
                                            var row: [8]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const count = std.mem.readInt(u32, row[0..4], .big);
                                            const offset_raw = std.mem.readInt(u32, row[4..8], .big);
                                            const offset_signed: i32 = @bitCast(offset_raw);
                                            try ctts_list.append(allocator, CttsEntry{ .count = count, .offset = offset_signed });
                                            rem_bytes -= 8;
                                        }
                                        try skipBytes(r, rem_bytes);
                                    } else {
                                        try skipBytes(r, stbl_data_size);
                                    }
                                } else if (isFourCC(stbl_child.type, "stss")) {
                                    if (stbl_data_size >= 8) {
                                        var hdr: [8]u8 = undefined;
                                        try r.readSliceAll(&hdr);
                                        const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                                        var rem_bytes = stbl_data_size - 8;
                                        has_stss = true;

                                        for (0..entry_count) |_| {
                                            if (rem_bytes < 4) break;
                                            var row: [4]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const sync_1based = std.mem.readInt(u32, &row, .big);
                                            try stss_list.append(allocator, sync_1based);
                                            rem_bytes -= 4;
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
                                            var row: [12]u8 = undefined;
                                            try r.readSliceAll(&row);
                                            const first_chunk = std.mem.readInt(u32, row[0..4], .big);
                                            const samples_per_chunk = std.mem.readInt(u32, row[4..8], .big);
                                            const sample_desc_index = std.mem.readInt(u32, row[8..12], .big);
                                            try stsc_list.append(allocator, StscEntry{
                                                .first_chunk = first_chunk,
                                                .samples_per_chunk = samples_per_chunk,
                                                .sample_desc_index = sample_desc_index,
                                            });
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

    const samples_res = try buildMediaSampleList(
        allocator,
        timescale,
        stts_list.items,
        ctts_list.items,
        stss_list.items,
        has_stss,
        stsc_list.items,
        stsz_uniform,
        stsz_list.items,
        stco_list.items,
    );

    return Mp4MediaTrack{
        .track_id = track_id,
        .stream_idx = stream_idx,
        .handler_type = handler_type,
        .timescale = timescale,
        .duration = duration,
        .width = width,
        .height = height,
        .volume = volume,
        .language = language,
        .stsd_raw = try stsd_raw.toOwnedSlice(allocator),
        .samples = samples_res,
        .sync_sample_indices = try stss_list.toOwnedSlice(allocator),
    };
}
