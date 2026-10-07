const std = @import("std");
const languages = @import("languages.zig");

test "getLanguageName mapping" {
    try std.testing.expectEqualStrings("English", languages.getLanguageName("eng").?);
    try std.testing.expectEqualStrings("English", languages.getLanguageName("en").?);
    try std.testing.expectEqualStrings("English", languages.getLanguageName("en-US").?);
    try std.testing.expectEqualStrings("Hebrew", languages.getLanguageName("heb").?);
    try std.testing.expectEqualStrings("Hebrew", languages.getLanguageName("he").?);
    try std.testing.expectEqualStrings("Spanish", languages.getLanguageName("spa").?);
    try std.testing.expectEqualStrings("Russian", languages.getLanguageName("rus").?);
    try std.testing.expectEqualStrings("Chinese (Simplified)", languages.getLanguageName("zh-CN").?);
    try std.testing.expect(languages.getLanguageName("und") == null);
}
