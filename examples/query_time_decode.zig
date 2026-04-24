const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<a id='x' href='https://example.test/?a=1&amp;b=2' data-k='a&amp;b'>link</a>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    const a = doc.queryOne("a#x[data-k='a&b']") orelse return error.TestUnexpectedResult;
    const href = a.getAttributeValue("href") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://example.test/?a=1&b=2", href);
}

test "attribute entity decode is applied by query-time APIs" {
    try run();
}
