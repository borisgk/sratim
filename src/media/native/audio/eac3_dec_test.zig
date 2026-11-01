const std = @import("std");
const eac3_dec = @import("eac3_dec.zig");
const Eac3Decoder = eac3_dec.Eac3Decoder;

test "Eac3Decoder basic initialization" {
    const testing = std.testing;
    const dec = Eac3Decoder.init();
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try testing.expectEqual(@as(u32, 6), dec.channels);
}

test "Eac3Decoder SPX and AHT frame decoding" {
    const testing = std.testing;
    const frame_b64 =
        "C3cB/z+GP+jeYIFwBEUAAQCSIAPTCCGCCFAPy2osAGAOGFGFENDAhCghAAxwwoIYz51JC1Dw5IhCHQWHAhlbpLWppX5ZMqUxlx0oat2lfuoUKlarbRlWwpfV5yakq3t1tqZU5fa31gil3vNo7tVDVPxnBy/dPnOuG9p0n6ZLS4w530OmWdplN9+9rbFMN8+fU0xGuh5kU30Qs/TOxlkZSpq2tKG+nQn75Mq29/KJJJpIAwV5tKBh6TvCWIpdvpjVC5uWNpErerGVtSWNYWzhLCD3JRMVshFV2JMctDbGI0RJy3G45CpDZrNsQS3tsIUpLAIgY7/+XAYzfXMSsDxFhnT2k3V5PySAIQQQoFfl0w+137V2y4ICW7SIbnZhVxnvh3wzAtODhJC/Sf9iny2vdojwegEv+gqEuvJHP9X+IdCQENWzEdUYeN0fbtZjcuId9yMfL1Az8RMvL6QHZogRpSsvSeQAtexfTt4oH/+IoXqOLjYQXyCGNuUhpeAIAWtXu3f/zIn2ojpY+7GdbgeG/7ng3BEwT/0c/R99t+3GfJZqH3YQ+ecdwGtWvHlf3AIDlEIeLMhsBBgvfrFRbrsdDCcYDUNHQQvlnV6Ea8xEUKqMf3nySCCGHBn+Vvjib/ifUkdbz9kB1eGx6xD+epfZy8NKnKn8rnW7rhFdjITeAAwtg0Gz2IlK20fNRxYqUCVIGMLgB631D4sw2Hlj/9pKTSqwT+xh7i8LitErjYAACiSSR8DPGcaQzkqQNWSmuC2myFJBLKX7IGTIhY9jVYkEZxEzLincuZCRz6l1NCHNR1seS0PJmm2k1DWkm2hbdYwpiACVTPJNQqJxR4KJJJIRWDgADQCCBgSUgATLq0vh6YAyqj6HZTl6qZrhKLKKxkkpJC33kBU2HDrQ6nDuNOXlNwlSuC1edqzG+K2FOpN4LXwUTIJl6OSOSFSOAXJtbSsACBRPPIhUkyDARGsSGi9VSfrqZF70SSSA11cIP13Q1aRSRGOSlq1udFsut9E9Rrwc2id9HpHJm6eTT5Z4QCKQVHDpu39X0et5EemzmhYHBKNJtlpoV5IlWhBOAiSCBBAAOxsOoiatCpwob5L0SSSJ++7onGJVSo1s2hWPi2Njs3Gxs2LOKv3UxJ9E0nWGZbMZZIm4v/QTwhYO/CJvep+zN9nePLXzVrsyRECg5SmN00qAkESYaPJChDDQQ4YwUMIAOABiN1zJaFXSP33RJJIAkMu/UmEWsGqICokGp9XSSJoQc1QEbBmXgeGSW6Cm1Gmr9kYN6gYA/IuhhDfUXbNsSW6lsdmmVsBGRJpMdhat5Gak2Il2xEp2gAAAAAAAAAAAAAAAAAAAAAAAAAABhHQqag==";

    var frame_bytes: [1024]u8 = undefined;
    try std.base64.standard.Decoder.decode(&frame_bytes, frame_b64);

    var dec = Eac3Decoder.init();
    var pcm: [1536 * 2]f32 = undefined;
    const n_samples = try dec.decodeFrame(&frame_bytes, &pcm);

    try testing.expectEqual(@as(usize, 1536), n_samples);
    try testing.expect(dec.spx_in_use);
    try testing.expectEqual(@as(u32, 6), dec.channels);

    var sum_sq: f64 = 0.0;
    for (pcm[0 .. n_samples * 2]) |s| {
        sum_sq += @as(f64, s) * @as(f64, s);
    }
    const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(n_samples * 2)));
    try testing.expect(rms > 0.005);
}
