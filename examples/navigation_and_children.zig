const std = @import("std");
const html = @import("html");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<main id='m'><h1 id='title'></h1><p id='intro'></p><p id='body'></p></main>".*;
    try doc.parse(&input);

    const main = doc.queryOne("main#m") orelse return error.TestUnexpectedResult;
    const first = main.firstChild() orelse return error.TestUnexpectedResult;
    const last = main.lastChild() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("title", first.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("body", last.getAttributeValue("id").?);

    var children = main.children();
    const child_nodes = try children.collect(std.testing.allocator);
    defer std.testing.allocator.free(child_nodes);
    try std.testing.expectEqual(@as(usize, 3), child_nodes.len);
    try std.testing.expectEqualStrings("title", child_nodes[0].getAttributeValue("id").?);
}

test "navigation and children iterator" {
    try run();
}
