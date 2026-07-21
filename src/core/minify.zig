const std = @import("std");

pub fn minifyCss(comptime input: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100000);
        var out: [input.len]u8 = undefined;
        var out_len: usize = 0;
        var in_comment = false;
        var i: usize = 0;
        var last_char_was_space = false;
        
        while (i < input.len) {
            if (!in_comment and i + 1 < input.len and input[i] == '/' and input[i+1] == '*') {
                in_comment = true;
                i += 2;
                continue;
            }
            if (in_comment and i + 1 < input.len and input[i] == '*' and input[i+1] == '/') {
                in_comment = false;
                i += 2;
                continue;
            }
            if (in_comment) {
                i += 1;
                continue;
            }
            
            const c = input[i];
            if (c == '\n' or c == '\r' or c == '\t' or c == ' ') {
                if (!last_char_was_space and out_len > 0) {
                    out[out_len] = ' ';
                    out_len += 1;
                    last_char_was_space = true;
                }
            } else {
                if (c == '{' or c == '}' or c == ':' or c == ';' or c == ',' or c == '>') {
                    if (out_len > 0 and out[out_len - 1] == ' ') {
                        out_len -= 1;
                    }
                }
                out[out_len] = c;
                out_len += 1;
                last_char_was_space = (c == '{' or c == '}' or c == ':' or c == ';' or c == ',' or c == '>');
            }
            i += 1;
        }
        
        const final_len = out_len;
        var final_array: [final_len]u8 = undefined;
        for (out[0..final_len], 0..) |c, idx| {
            final_array[idx] = c;
        }
        const final_const = final_array;
        return &final_const;
    }
}
