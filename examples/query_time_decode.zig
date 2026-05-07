const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<a id='x' href='https://example.test/?a=1&amp;b=2' data-k='a&amp;b'>link</a>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    var links = doc.query("a#x[data-k='a&b']");
    const a = links.next() orelse return error.TestUnexpectedResult;
    const href = (try a.getAttributeValue(std.testing.allocator, "href")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://example.test/?a=1&b=2", href.value);
}

test "attribute entity decode is applied by query-time APIs" {
    try run();
}
