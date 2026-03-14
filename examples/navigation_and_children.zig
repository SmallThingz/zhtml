const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<main id='m'><h1 id='title'></h1><p id='intro'></p><p id='body'></p></main>".*;
    try doc.parse(&input, .{});

    const main = doc.queryOne("main#m") orelse return error.TestUnexpectedResult;
    const first = main.firstChild() orelse return error.TestUnexpectedResult;
    const last = main.lastChild() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("title", first.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("body", last.getAttributeValue("id").?);

    var children = main.children();
    var child_indexes: std.ArrayListUnmanaged(u32) = .{};
    defer child_indexes.deinit(std.testing.allocator);
    try children.collect(std.testing.allocator, &child_indexes);
    try std.testing.expectEqual(@as(usize, 3), child_indexes.items.len);
    const first_idx = child_indexes.items[0];
    const first_via_index = main.doc.nodeAt(first_idx) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("title", first_via_index.getAttributeValue("id").?);
}

test "navigation and children iterator" {
    try run();
}
