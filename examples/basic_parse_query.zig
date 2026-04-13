const std = @import("std");
const html = @import("html");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input);

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}

test "basic parse + query" {
    try run();
}
