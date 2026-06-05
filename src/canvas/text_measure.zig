const std = @import("std");

pub fn width(text: []const u8) !u32 {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();
    var count: u32 = 0;
    while (it.nextCodepoint()) |_| {
        count += 1;
    }
    return count;
}
