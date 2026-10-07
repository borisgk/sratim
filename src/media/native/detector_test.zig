const std = @import("std");
const detector = @import("detector.zig");
const detectLanguage = detector.detectLanguage;

test "detect non-Latin scripts" {
    const heb = detectLanguage("‫בפרקים הקودמים…");
    try std.testing.expect(heb != null);
    try std.testing.expectEqualStrings("heb", heb.?.code);

    const ara = detectLanguage("‫في الحلقات السابقة…");
    try std.testing.expect(ara != null);
    try std.testing.expectEqualStrings("ara", ara.?.code);

    const ell = detectLanguage("Στα προηγούμενα…");
    try std.testing.expect(ell != null);
    try std.testing.expectEqualStrings("ell", ell.?.code);

    const hin = detectLanguage("रीचर में इससे पहले…");
    try std.testing.expect(hin != null);
    try std.testing.expectEqualStrings("hin", hin.?.code);

    const jpn = detectLanguage("前回までは…");
    try std.testing.expect(jpn != null);
    try std.testing.expectEqualStrings("jpn", jpn.?.code);

    const kor = detectLanguage("지난 이야기");
    try std.testing.expect(kor != null);
    try std.testing.expectEqualStrings("kor", kor.?.code);

    const zho = detectLanguage("《侠探杰克》前情提要…");
    try std.testing.expect(zho != null);
    try std.testing.expectEqualStrings("zho", zho.?.code);
}

test "detect Latin languages" {
    const fra = detectLanguage("Précédemment, dans Reacher…");
    try std.testing.expect(fra != null);
    try std.testing.expectEqualStrings("fra", fra.?.code);

    const deu = detectLanguage("Bisher bei Reacher…");
    try std.testing.expect(deu != null);
    try std.testing.expectEqualStrings("deu", deu.?.code);

    const spa = detectLanguage("Anteriormente en Reacher");
    try std.testing.expect(spa != null);
    try std.testing.expectEqualStrings("spa", spa.?.code);

    const nld = detectLanguage("Wat voorafging…");
    try std.testing.expect(nld != null);
    try std.testing.expectEqualStrings("nld", nld.?.code);

    const tur = detectLanguage("Reacher'da daha önce…");
    try std.testing.expect(tur != null);
    try std.testing.expectEqualStrings("tur", tur.?.code);
}
