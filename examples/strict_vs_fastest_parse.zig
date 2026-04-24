const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const strictest_options: html.ParseOptions = .{ .drop_whitespace_text_nodes = false };
    const fastest_options: html.ParseOptions = .{};

    const fixture =
        "<html><body>" ++
        "<ul><li class='item'>A</li><li class='item'>B</li></ul>" ++
        "</body></html>";

    var strictest_buf = fixture.*;
    var strictest_doc = try strictest_options.parse(std.testing.allocator, &strictest_buf);
    defer strictest_doc.deinit();

    var fastest_buf = fixture.*;
    var fastest_doc = try fastest_options.parse(std.testing.allocator, &fastest_buf);
    defer fastest_doc.deinit();

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
