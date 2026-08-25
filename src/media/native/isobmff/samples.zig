const std = @import("std");
const types = @import("types.zig");
const SttsEntry = types.SttsEntry;
const CttsEntry = types.CttsEntry;
const StscEntry = types.StscEntry;
const SubtitleSample = types.SubtitleSample;
const MediaSample = types.MediaSample;

/// Builds an array of SubtitleSample structs by combining STTS, STSC, STSZ, and STCO tables.
pub fn buildSampleList(
    allocator: std.mem.Allocator,
    timescale: u32,
    stts_entries: []const SttsEntry,
    stsc_entries: []const StscEntry,
    stsz_uniform: u32,
    stsz_entries: []const u32,
    chunk_offsets: []const u64,
) ![]SubtitleSample {
    var total_samples: usize = 0;
    for (stts_entries) |entry| {
        total_samples += entry.count;
    }

    if (total_samples == 0) return &[_]SubtitleSample{};

    const samples = try allocator.alloc(SubtitleSample, total_samples);
    errdefer allocator.free(samples);

    // 1. Compute start and end timestamps (in seconds) from STTS
    var current_ts: u64 = 0;
    var idx: usize = 0;
    const ts_f = @as(f64, @floatFromInt(timescale));

    for (stts_entries) |entry| {
        for (0..entry.count) |_| {
            if (idx >= total_samples) break;
            const start_sec = @as(f64, @floatFromInt(current_ts)) / ts_f;
            current_ts += entry.delta;
            const end_sec = @as(f64, @floatFromInt(current_ts)) / ts_f;

            samples[idx].start_sec = start_sec;
            samples[idx].end_sec = end_sec;
            samples[idx].offset = 0;
            samples[idx].size = 0;
            idx += 1;
        }
    }

    // 2. Set sample sizes from STSZ
    for (0..total_samples) |i| {
        samples[i].size = if (stsz_uniform > 0)
            stsz_uniform
        else if (i < stsz_entries.len)
            stsz_entries[i]
        else
            0;
    }

    // 3. Map sample offsets using STSC and STCO/CO64 tables
    var chunk_idx: usize = 0;
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

/// Builds an array of MediaSample structs with full decode and presentation timestamps, keyframes, and offsets.
pub fn buildMediaSampleList(
    allocator: std.mem.Allocator,
    timescale: u32,
    stts_entries: []const SttsEntry,
    ctts_entries: []const CttsEntry,
    sync_samples: []const u32,
    has_stss: bool,
    stsc_entries: []const StscEntry,
    stsz_uniform: u32,
    stsz_entries: []const u32,
    chunk_offsets: []const u64,
) ![]MediaSample {
    var total_samples: usize = 0;
    for (stts_entries) |entry| {
        total_samples += entry.count;
    }

    if (total_samples == 0) return &[_]MediaSample{};

    const samples = try allocator.alloc(MediaSample, total_samples);
    errdefer allocator.free(samples);

    // 1. Compute Decode Timestamps (DTS) from STTS
    var current_dts: u64 = 0;
    var idx: usize = 0;
    const ts_f = @as(f64, @floatFromInt(timescale));

    for (stts_entries) |entry| {
        for (0..entry.count) |_| {
            if (idx >= total_samples) break;
            samples[idx] = MediaSample{
                .dts_delta = entry.delta,
                .dts = current_dts,
                .pts = current_dts,
                .pts_sec = @as(f64, @floatFromInt(current_dts)) / ts_f,
                .offset = 0,
                .size = 0,
                .is_sync = !has_stss, // If no stss box exists, all samples are sync samples
                .ctts_offset = 0,
            };
            current_dts += entry.delta;
            idx += 1;
        }
    }

    // 2. Apply CTTS (Composition Time Offsets for B-frames) -> PTS = DTS + CTTS
    if (ctts_entries.len > 0) {
        var ctts_sample_idx: usize = 0;
        for (ctts_entries) |entry| {
            for (0..entry.count) |_| {
                if (ctts_sample_idx >= total_samples) break;
                const pts_calc = @as(i64, @intCast(samples[ctts_sample_idx].dts)) + @as(i64, entry.offset);
                const pts_u64: u64 = if (pts_calc >= 0) @intCast(pts_calc) else 0;
                samples[ctts_sample_idx].pts = pts_u64;
                samples[ctts_sample_idx].pts_sec = @as(f64, @floatFromInt(pts_u64)) / ts_f;
                samples[ctts_sample_idx].ctts_offset = entry.offset;
                ctts_sample_idx += 1;
            }
        }
    }

    // 3. Apply STSS (Sync Samples / Keyframes)
    if (has_stss) {
        for (sync_samples) |sync_1based| {
            if (sync_1based >= 1 and sync_1based <= total_samples) {
                samples[sync_1based - 1].is_sync = true;
            }
        }
    }

    // 4. Set sample sizes from STSZ
    for (0..total_samples) |i| {
        samples[i].size = if (stsz_uniform > 0)
            stsz_uniform
        else if (i < stsz_entries.len)
            stsz_entries[i]
        else
            0;
    }

    // 5. Map sample offsets using STSC and STCO/CO64 tables
    var chunk_idx: usize = 0;
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
