const std = @import("std");
const cues = @import("cues.zig");
const ebml = @import("ebml.zig");

test "parseCues binary parsing" {
    const raw_cues = [_]u8{
        0xBB, 0x84, 0xB3, 0x82, 0x13, 0x88, // CuePoint 1: CueTime = 0x1388 (5000 ms = 5.0s)
        0xBB, 0x84, 0xB3, 0x82, 0x3A, 0x98, // CuePoint 2: CueTime = 0x3A98 (15000 ms = 15.0s)
    };
    var r: std.Io.Reader = .fixed(&raw_cues);
    const cues_elem = ebml.ElementHeader{
        .id = ebml.ID_CUES,
        .size = raw_cues.len,
        .header_size = 0,
    };

    const pts = try cues.parseCues(&r, cues_elem, 1_000_000.0, 10.0, null);
    try std.testing.expectEqual(@as(f64, 5.0), pts);
}

test "parseCues filters specifically by video track number" {
    // CuePoint 1: CueTime = 1000ms (1.0s), CueTrack = 3 (Subtitle)
    // CuePoint 2: CueTime = 4000ms (4.0s), CueTrack = 1 (Video)
    // CuePoint 3: CueTime = 5000ms (5.0s), CueTrack = 3 (Subtitle)
    const raw_cues = [_]u8{
        // CuePoint 1
        0xBB, 0x89,
        0xB3, 0x82, 0x03, 0xE8, // CueTime = 1000
        0xB7, 0x83, 0xF7, 0x81, 0x03, // CueTrackPositions: CueTrack = 3
        // CuePoint 2
        0xBB, 0x89,
        0xB3, 0x82, 0x0F, 0xA0, // CueTime = 4000
        0xB7, 0x83, 0xF7, 0x81, 0x01, // CueTrackPositions: CueTrack = 1
        // CuePoint 3
        0xBB, 0x89,
        0xB3, 0x82, 0x13, 0x88, // CueTime = 5000
        0xB7, 0x83, 0xF7, 0x81, 0x03, // CueTrackPositions: CueTrack = 3
    };
    var r: std.Io.Reader = .fixed(&raw_cues);
    const cues_elem = ebml.ElementHeader{
        .id = ebml.ID_CUES,
        .size = raw_cues.len,
        .header_size = 0,
    };

    // When seeking to 5.0s, video track 1 should match CuePoint 2 (4.0s) and ignore CuePoint 3 (5.0s, subtitle track)
    const pts = try cues.parseCues(&r, cues_elem, 1_000_000.0, 5.0, 1);
    try std.testing.expectEqual(@as(f64, 4.0), pts);
}
