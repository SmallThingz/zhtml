const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    const fixture =
        "<html><body>" ++
        "<ul><li class='item'>A</li><li class='item'>B</li></ul>" ++
        "</body></html>";

    var strictest_doc = Document.init(std.testing.allocator);
    defer strictest_doc.deinit();
    var strictest_buf = fixture.*;
    try strictest_doc.parse(&strictest_buf, .{
        .drop_whitespace_text_nodes = false,
    });

    var fastest_doc = Document.init(std.testing.allocator);
    defer fastest_doc.deinit();
    var fastest_buf = fixture.*;
    try fastest_doc.parse(&fastest_buf, .{
        .drop_whitespace_text_nodes = true,
    });

    const strictest_count = blk: {
        var it = strictest_doc.queryAll("li.item");
        var n: usize = 0;
        while (it.next() != null) n += 1;
        break :blk n;
    };
    const fastest_count = blk: {
        var it = fastest_doc.queryAll("li.item");
        var n: usize = 0;
        while (it.next() != null) n += 1;
        break :blk n;
    };

    try std.testing.expectEqual(strictest_count, fastest_count);
    try std.testing.expectEqual(@as(usize, 2), strictest_count);
}

test "strictest and fastest parse option bundles return equivalent query results" {
    try run();
}
