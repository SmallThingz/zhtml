const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    var links = doc.query("div#app > a.nav");
    const a = links.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", (try a.getAttributeValue(std.testing.allocator, "href")).?.value);
}

test "basic parse + query" {
    try run();
}
