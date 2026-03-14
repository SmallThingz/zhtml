const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<a id='x' href='https://example.test/?a=1&amp;b=2' data-k='a&amp;b'>link</a>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("a#x[data-k='a&b']") orelse return error.TestUnexpectedResult;
    const href = a.getAttributeValue("href") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://example.test/?a=1&b=2", href);
}

test "attribute entity decode is applied by query-time APIs" {
    try run();
}
