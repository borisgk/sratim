const std = @import("std");

/// Maps ISO 639-1, ISO 639-2 (B/T), and regional BCP 47 language codes to human-readable English names.
pub fn getLanguageName(code: []const u8) ?[]const u8 {
    var clean_code = code;
    // Check for common regional language codes first
    if (std.ascii.eqlIgnoreCase(clean_code, "zh-hans") or std.ascii.eqlIgnoreCase(clean_code, "zh-cn")) return "Chinese (Simplified)";
    if (std.ascii.eqlIgnoreCase(clean_code, "zh-hant") or std.ascii.eqlIgnoreCase(clean_code, "zh-tw") or std.ascii.eqlIgnoreCase(clean_code, "zh-hk")) return "Chinese (Traditional)";
    if (std.ascii.eqlIgnoreCase(clean_code, "pt-br")) return "Portuguese (Brazil)";
    if (std.ascii.eqlIgnoreCase(clean_code, "es-419")) return "Spanish (Latin America)";

    // Strip subtags like "-US", "_US", "-GB", etc. for base lookup
    if (std.mem.indexOfAny(u8, clean_code, "-_")) |dash_idx| {
        clean_code = clean_code[0..dash_idx];
    }

    const MapEntry = struct { code: []const u8, name: []const u8 };
    const lang_map = [_]MapEntry{
        .{ .code = "eng", .name = "English" },
        .{ .code = "en", .name = "English" },
        .{ .code = "heb", .name = "Hebrew" },
        .{ .code = "he", .name = "Hebrew" },
        .{ .code = "iw", .name = "Hebrew" },
        .{ .code = "spa", .name = "Spanish" },
        .{ .code = "es", .name = "Spanish" },
        .{ .code = "fra", .name = "French" },
        .{ .code = "fre", .name = "French" },
        .{ .code = "fr", .name = "French" },
        .{ .code = "deu", .name = "German" },
        .{ .code = "ger", .name = "German" },
        .{ .code = "de", .name = "German" },
        .{ .code = "ita", .name = "Italian" },
        .{ .code = "it", .name = "Italian" },
        .{ .code = "rus", .name = "Russian" },
        .{ .code = "ru", .name = "Russian" },
        .{ .code = "por", .name = "Portuguese" },
        .{ .code = "pt", .name = "Portuguese" },
        .{ .code = "ara", .name = "Arabic" },
        .{ .code = "ar", .name = "Arabic" },
        .{ .code = "zho", .name = "Chinese" },
        .{ .code = "chi", .name = "Chinese" },
        .{ .code = "zh", .name = "Chinese" },
        .{ .code = "jpn", .name = "Japanese" },
        .{ .code = "ja", .name = "Japanese" },
        .{ .code = "kor", .name = "Korean" },
        .{ .code = "ko", .name = "Korean" },
        .{ .code = "hin", .name = "Hindi" },
        .{ .code = "hi", .name = "Hindi" },
        .{ .code = "tur", .name = "Turkish" },
        .{ .code = "tr", .name = "Turkish" },
        .{ .code = "pol", .name = "Polish" },
        .{ .code = "pl", .name = "Polish" },
        .{ .code = "ukr", .name = "Ukrainian" },
        .{ .code = "uk", .name = "Ukrainian" },
        .{ .code = "nld", .name = "Dutch" },
        .{ .code = "dut", .name = "Dutch" },
        .{ .code = "nl", .name = "Dutch" },
        .{ .code = "swe", .name = "Swedish" },
        .{ .code = "sv", .name = "Swedish" },
        .{ .code = "nor", .name = "Norwegian" },
        .{ .code = "nob", .name = "Norwegian" },
        .{ .code = "nno", .name = "Norwegian" },
        .{ .code = "no", .name = "Norwegian" },
        .{ .code = "dan", .name = "Danish" },
        .{ .code = "da", .name = "Danish" },
        .{ .code = "fin", .name = "Finnish" },
        .{ .code = "fi", .name = "Finnish" },
        .{ .code = "ell", .name = "Greek" },
        .{ .code = "gre", .name = "Greek" },
        .{ .code = "el", .name = "Greek" },
        .{ .code = "ces", .name = "Czech" },
        .{ .code = "cze", .name = "Czech" },
        .{ .code = "cs", .name = "Czech" },
        .{ .code = "hun", .name = "Hungarian" },
        .{ .code = "hu", .name = "Hungarian" },
        .{ .code = "ron", .name = "Romanian" },
        .{ .code = "rum", .name = "Romanian" },
        .{ .code = "ro", .name = "Romanian" },
        .{ .code = "bul", .name = "Bulgarian" },
        .{ .code = "bg", .name = "Bulgarian" },
        .{ .code = "hrv", .name = "Croatian" },
        .{ .code = "hr", .name = "Croatian" },
        .{ .code = "srp", .name = "Serbian" },
        .{ .code = "sr", .name = "Serbian" },
        .{ .code = "slv", .name = "Slovenian" },
        .{ .code = "sl", .name = "Slovenian" },
        .{ .code = "slk", .name = "Slovak" },
        .{ .code = "slo", .name = "Slovak" },
        .{ .code = "sk", .name = "Slovak" },
        .{ .code = "lit", .name = "Lithuanian" },
        .{ .code = "lt", .name = "Lithuanian" },
        .{ .code = "lav", .name = "Latvian" },
        .{ .code = "lv", .name = "Latvian" },
        .{ .code = "est", .name = "Estonian" },
        .{ .code = "et", .name = "Estonian" },
        .{ .code = "cat", .name = "Catalan" },
        .{ .code = "ca", .name = "Catalan" },
        .{ .code = "vie", .name = "Vietnamese" },
        .{ .code = "vi", .name = "Vietnamese" },
        .{ .code = "tha", .name = "Thai" },
        .{ .code = "th", .name = "Thai" },
        .{ .code = "ind", .name = "Indonesian" },
        .{ .code = "id", .name = "Indonesian" },
        .{ .code = "msa", .name = "Malay" },
        .{ .code = "may", .name = "Malay" },
        .{ .code = "ms", .name = "Malay" },
        .{ .code = "fil", .name = "Tagalog" },
        .{ .code = "tgl", .name = "Tagalog" },
        .{ .code = "tl", .name = "Tagalog" },
        .{ .code = "fas", .name = "Persian" },
        .{ .code = "per", .name = "Persian" },
        .{ .code = "fa", .name = "Persian" },
        .{ .code = "urd", .name = "Urdu" },
        .{ .code = "ur", .name = "Urdu" },
        .{ .code = "ben", .name = "Bengali" },
        .{ .code = "bn", .name = "Bengali" },
        .{ .code = "tam", .name = "Tamil" },
        .{ .code = "ta", .name = "Tamil" },
        .{ .code = "tel", .name = "Telugu" },
        .{ .code = "te", .name = "Telugu" },
        .{ .code = "kan", .name = "Kannada" },
        .{ .code = "kn", .name = "Kannada" },
        .{ .code = "mal", .name = "Malayalam" },
        .{ .code = "ml", .name = "Malayalam" },
        .{ .code = "mar", .name = "Marathi" },
        .{ .code = "mr", .name = "Marathi" },
        .{ .code = "pan", .name = "Punjabi" },
        .{ .code = "pa", .name = "Punjabi" },
        .{ .code = "guj", .name = "Gujarati" },
        .{ .code = "gu", .name = "Gujarati" },
        .{ .code = "kat", .name = "Georgian" },
        .{ .code = "geo", .name = "Georgian" },
        .{ .code = "ka", .name = "Georgian" },
        .{ .code = "hye", .name = "Armenian" },
        .{ .code = "arm", .name = "Armenian" },
        .{ .code = "hy", .name = "Armenian" },
        .{ .code = "aze", .name = "Azerbaijani" },
        .{ .code = "az", .name = "Azerbaijani" },
        .{ .code = "kaz", .name = "Kazakh" },
        .{ .code = "kk", .name = "Kazakh" },
        .{ .code = "uzb", .name = "Uzbek" },
        .{ .code = "uz", .name = "Uzbek" },
        .{ .code = "mon", .name = "Mongolian" },
        .{ .code = "mn", .name = "Mongolian" },
        .{ .code = "lat", .name = "Latin" },
        .{ .code = "la", .name = "Latin" },
        .{ .code = "isl", .name = "Icelandic" },
        .{ .code = "ice", .name = "Icelandic" },
        .{ .code = "is", .name = "Icelandic" },
        .{ .code = "gle", .name = "Irish" },
        .{ .code = "ga", .name = "Irish" },
        .{ .code = "cym", .name = "Welsh" },
        .{ .code = "wel", .name = "Welsh" },
        .{ .code = "cy", .name = "Welsh" },
        .{ .code = "eus", .name = "Basque" },
        .{ .code = "baq", .name = "Basque" },
        .{ .code = "eu", .name = "Basque" },
        .{ .code = "alb", .name = "Albanian" },
        .{ .code = "sqi", .name = "Albanian" },
        .{ .code = "sq", .name = "Albanian" },
        .{ .code = "mkd", .name = "Macedonian" },
        .{ .code = "mac", .name = "Macedonian" },
        .{ .code = "mk", .name = "Macedonian" },
        .{ .code = "bos", .name = "Bosnian" },
        .{ .code = "bs", .name = "Bosnian" },
        .{ .code = "bel", .name = "Belarusian" },
        .{ .code = "be", .name = "Belarusian" },
        .{ .code = "yid", .name = "Yiddish" },
        .{ .code = "yi", .name = "Yiddish" },
        .{ .code = "epo", .name = "Esperanto" },
        .{ .code = "eo", .name = "Esperanto" },
    };

    for (lang_map) |entry| {
        if (std.ascii.eqlIgnoreCase(clean_code, entry.code)) {
            return entry.name;
        }
    }
    return null;
}

test "getLanguageName mapping" {
    try std.testing.expectEqualStrings("English", getLanguageName("eng").?);
    try std.testing.expectEqualStrings("English", getLanguageName("en").?);
    try std.testing.expectEqualStrings("English", getLanguageName("en-US").?);
    try std.testing.expectEqualStrings("Hebrew", getLanguageName("heb").?);
    try std.testing.expectEqualStrings("Hebrew", getLanguageName("he").?);
    try std.testing.expectEqualStrings("Spanish", getLanguageName("spa").?);
    try std.testing.expectEqualStrings("Russian", getLanguageName("rus").?);
    try std.testing.expectEqualStrings("Chinese (Simplified)", getLanguageName("zh-CN").?);
    try std.testing.expect(getLanguageName("und") == null);
}
