const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}

test "basic parse + query" {
    try run();
}
