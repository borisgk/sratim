const std = @import("std");

pub const LanguageInfo = struct {
    code: []const u8,
    name: []const u8,
};

const LatinWordMatch = struct {
    word: []const u8,
    code: []const u8,
    name: []const u8,
    weight: u32 = 10,
};

const LATIN_KEYWORDS = [_]LatinWordMatch{
    // English
    .{ .word = "previously on", .code = "eng", .name = "English", .weight = 50 },
    .{ .word = "previously in", .code = "eng", .name = "English", .weight = 50 },
    .{ .word = "previously", .code = "eng", .name = "English", .weight = 30 },
    .{ .word = "the", .code = "eng", .name = "English", .weight = 2 },
    .{ .word = "and", .code = "eng", .name = "English", .weight = 2 },
    .{ .word = "that", .code = "eng", .name = "English", .weight = 2 },
    .{ .word = "with", .code = "eng", .name = "English", .weight = 2 },
    .{ .word = "what", .code = "eng", .name = "English", .weight = 2 },

    // French
    .{ .word = "précédemment", .code = "fra", .name = "French", .weight = 50 },
    .{ .word = "precedemment", .code = "fra", .name = "French", .weight = 50 },
    .{ .word = "dans", .code = "fra", .name = "French", .weight = 5 },
    .{ .word = "pourquoi", .code = "fra", .name = "French", .weight = 10 },
    .{ .word = "avec", .code = "fra", .name = "French", .weight = 4 },
    .{ .word = "vous", .code = "fra", .name = "French", .weight = 3 },
    .{ .word = "nous", .code = "fra", .name = "French", .weight = 3 },

    // German
    .{ .word = "bisher bei", .code = "deu", .name = "German", .weight = 50 },
    .{ .word = "bisher in", .code = "deu", .name = "German", .weight = 50 },
    .{ .word = "bisher", .code = "deu", .name = "German", .weight = 30 },
    .{ .word = "zuvor bei", .code = "deu", .name = "German", .weight = 50 },
    .{ .word = "nicht", .code = "deu", .name = "German", .weight = 5 },
    .{ .word = "warum", .code = "deu", .name = "German", .weight = 8 },
    .{ .word = "auch", .code = "deu", .name = "German", .weight = 5 },

    // Spanish
    .{ .word = "anteriormente en", .code = "spa", .name = "Spanish", .weight = 60 },
    .{ .word = "anteriormente", .code = "spa", .name = "Spanish", .weight = 50 },
    .{ .word = "por qué", .code = "spa", .name = "Spanish", .weight = 10 },
    .{ .word = "también", .code = "spa", .name = "Spanish", .weight = 10 },
    .{ .word = "tambien", .code = "spa", .name = "Spanish", .weight = 8 },
    .{ .word = "estoy", .code = "spa", .name = "Spanish", .weight = 6 },

    // Italian
    .{ .word = "negli episodi precedenti", .code = "ita", .name = "Italian", .weight = 50 },
    .{ .word = "nelle puntate precedenti", .code = "ita", .name = "Italian", .weight = 50 },
    .{ .word = "precedenti", .code = "ita", .name = "Italian", .weight = 30 },
    .{ .word = "perché", .code = "ita", .name = "Italian", .weight = 10 },
    .{ .word = "perche", .code = "ita", .name = "Italian", .weight = 8 },
    .{ .word = "questo", .code = "ita", .name = "Italian", .weight = 5 },

    // Portuguese
    .{ .word = "no episódio anterior", .code = "por", .name = "Portuguese", .weight = 50 },
    .{ .word = "anterior", .code = "por", .name = "Portuguese", .weight = 20 },
    .{ .word = "você", .code = "por", .name = "Portuguese", .weight = 15 },
    .{ .word = "voce", .code = "por", .name = "Portuguese", .weight = 10 },
    .{ .word = "não", .code = "por", .name = "Portuguese", .weight = 10 },
    .{ .word = "nao", .code = "por", .name = "Portuguese", .weight = 5 },

    // Dutch
    .{ .word = "wat voorafging", .code = "nld", .name = "Dutch", .weight = 50 },
    .{ .word = "voorafging", .code = "nld", .name = "Dutch", .weight = 40 },
    .{ .word = "eerder in", .code = "nld", .name = "Dutch", .weight = 30 },
    .{ .word = "waarom", .code = "nld", .name = "Dutch", .weight = 8 },
    .{ .word = "altijd", .code = "nld", .name = "Dutch", .weight = 8 },

    // Czech
    .{ .word = "viděli jste", .code = "ces", .name = "Czech", .weight = 50 },
    .{ .word = "videli jste", .code = "ces", .name = "Czech", .weight = 40 },
    .{ .word = "předchozím", .code = "ces", .name = "Czech", .weight = 40 },
    .{ .word = "jsem", .code = "ces", .name = "Czech", .weight = 8 },
    .{ .word = "jako", .code = "ces", .name = "Czech", .weight = 5 },

    // Polish
    .{ .word = "poprzednio w", .code = "pol", .name = "Polish", .weight = 50 },
    .{ .word = "poprzednio", .code = "pol", .name = "Polish", .weight = 40 },
    .{ .word = "dlaczego", .code = "pol", .name = "Polish", .weight = 10 },
    .{ .word = "jestem", .code = "pol", .name = "Polish", .weight = 8 },
    .{ .word = "będzie", .code = "pol", .name = "Polish", .weight = 8 },

    // Hungarian
    .{ .word = "korábban történt", .code = "hun", .name = "Hungarian", .weight = 50 },
    .{ .word = "korabban tortent", .code = "hun", .name = "Hungarian", .weight = 40 },
    .{ .word = "korábban", .code = "hun", .name = "Hungarian", .weight = 30 },
    .{ .word = "miért", .code = "hun", .name = "Hungarian", .weight = 10 },
    .{ .word = "vagyok", .code = "hun", .name = "Hungarian", .weight = 8 },

    // Turkish
    .{ .word = "daha önce", .code = "tur", .name = "Turkish", .weight = 50 },
    .{ .word = "daha once", .code = "tur", .name = "Turkish", .weight = 40 },
    .{ .word = "önceki bölümde", .code = "tur", .name = "Turkish", .weight = 50 },
    .{ .word = "neden", .code = "tur", .name = "Turkish", .weight = 8 },
    .{ .word = "burada", .code = "tur", .name = "Turkish", .weight = 6 },

    // Finnish
    .{ .word = "aiemmin tapahtunutta", .code = "fin", .name = "Finnish", .weight = 50 },
    .{ .word = "aiemmin", .code = "fin", .name = "Finnish", .weight = 30 },
    .{ .word = "tapahtunutta", .code = "fin", .name = "Finnish", .weight = 30 },
    .{ .word = "edellisessä", .code = "fin", .name = "Finnish", .weight = 30 },
    .{ .word = "miksi", .code = "fin", .name = "Finnish", .weight = 8 },

    // Swedish
    .{ .word = "detta har hänt", .code = "swe", .name = "Swedish", .weight = 50 },
    .{ .word = "detta har hant", .code = "swe", .name = "Swedish", .weight = 40 },
    .{ .word = "hänt", .code = "swe", .name = "Swedish", .weight = 20 },
    .{ .word = "varför", .code = "swe", .name = "Swedish", .weight = 8 },
    .{ .word = "också", .code = "swe", .name = "Swedish", .weight = 8 },

    // Danish / Norwegian
    .{ .word = "tidligere i", .code = "dan", .name = "Danish", .weight = 40 },
    .{ .word = "tidligere på", .code = "nor", .name = "Norwegian", .weight = 40 },
    .{ .word = "hvorfor", .code = "dan", .name = "Danish", .weight = 6 },

    // Indonesian / Malay
    .{ .word = "sebelumnya di", .code = "ind", .name = "Indonesian", .weight = 50 },
    .{ .word = "sebelumnya", .code = "ind", .name = "Indonesian", .weight = 40 },
    .{ .word = "sebelum ini", .code = "msa", .name = "Malay", .weight = 50 },
    .{ .word = "kenapa", .code = "ind", .name = "Indonesian", .weight = 8 },

    // Basque
    .{ .word = "aurreko ataletan", .code = "eus", .name = "Basque", .weight = 50 },
    .{ .word = "aurreko", .code = "eus", .name = "Basque", .weight = 30 },
    .{ .word = "ataletan", .code = "eus", .name = "Basque", .weight = 30 },

    // Catalan
    .{ .word = "anteriorment a", .code = "cat", .name = "Catalan", .weight = 50 },
    .{ .word = "anteriorment", .code = "cat", .name = "Catalan", .weight = 40 },
};

/// Detects the language of a subtitle text snippet.
pub fn detectLanguage(raw_text: []const u8) ?LanguageInfo {
    if (raw_text.len == 0) return null;

    var heb_count: usize = 0;
    var ara_count: usize = 0;
    var ell_count: usize = 0;
    var rus_count: usize = 0;
    var hin_count: usize = 0;
    var kan_count: usize = 0;
    var mal_count: usize = 0;
    var tam_count: usize = 0;
    var tel_count: usize = 0;
    var tha_count: usize = 0;
    var kor_count: usize = 0;
    var jpn_count: usize = 0;
    var cjk_count: usize = 0;

    var latin_count: usize = 0;

    var iter = (std.unicode.Utf8View.init(raw_text) catch return null).iterator();
    while (iter.nextCodepoint()) |cp| {
        switch (cp) {
            0x0590...0x05FF => heb_count += 1,
            0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF => ara_count += 1,
            0x0370...0x03FF, 0x1F00...0x1FFF => ell_count += 1,
            0x0400...0x052F => rus_count += 1,
            0x0900...0x097F => hin_count += 1,
            0x0C80...0x0CFF => kan_count += 1,
            0x0D00...0x0D7F => mal_count += 1,
            0x0B80...0x0BFF => tam_count += 1,
            0x0C00...0x0C7F => tel_count += 1,
            0x0E00...0x0E7F => tha_count += 1,
            0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F => kor_count += 1,
            0x3040...0x309F, 0x30A0...0x30FF => jpn_count += 1,
            0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF => cjk_count += 1,
            'a'...'z', 'A'...'Z', 0x00C0...0x024F => latin_count += 1,
            else => {},
        }
    }

    // 1. Non-Latin Scripts check
    if (heb_count >= 2) return .{ .code = "heb", .name = "Hebrew" };
    if (ara_count >= 2) return .{ .code = "ara", .name = "Arabic" };
    if (ell_count >= 2) return .{ .code = "ell", .name = "Greek" };
    if (rus_count >= 2) return .{ .code = "rus", .name = "Russian" };
    if (hin_count >= 2) return .{ .code = "hin", .name = "Hindi" };
    if (kan_count >= 2) return .{ .code = "kan", .name = "Kannada" };
    if (mal_count >= 2) return .{ .code = "mal", .name = "Malayalam" };
    if (tam_count >= 2) return .{ .code = "tam", .name = "Tamil" };
    if (tel_count >= 2) return .{ .code = "tel", .name = "Telugu" };
    if (tha_count >= 2) return .{ .code = "tha", .name = "Thai" };
    if (kor_count >= 2) return .{ .code = "kor", .name = "Korean" };
    if (jpn_count >= 1) return .{ .code = "jpn", .name = "Japanese" };
    if (cjk_count >= 2) return .{ .code = "zho", .name = "Chinese" };

    // 2. Latin Keyword / Stop-Word scoring
    var best_score: u32 = 0;
    var best_lang: ?LanguageInfo = null;

    for (LATIN_KEYWORDS) |kw| {
        if (std.ascii.indexOfIgnoreCase(raw_text, kw.word) != null) {
            const score = kw.weight + @as(u32, @intCast(kw.word.len * 5));
            if (score > best_score) {
                best_score = score;
                best_lang = .{ .code = kw.code, .name = kw.name };
            }
        }
    }

    if (best_lang) |l| {
        return l;
    }

    // Default fallback if substantial Latin text is present
    if (latin_count >= 5) {
        return .{ .code = "eng", .name = "English" };
    }

    return null;
}

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
