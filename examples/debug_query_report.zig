const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div><a id='one' class='nav'></a><a id='two'></a></div>".*;
    try doc.parse(&input, .{});

    var report: html.QueryDebugReport = .{};
    const node = try doc.queryOneRuntimeDebug("a[href^=https]", &report);
    try std.testing.expect(node == null);
    try std.testing.expect(report.visited_elements > 0);
    try std.testing.expect(report.near_miss_len > 0);
    try std.testing.expect(report.near_misses[0].reason.kind != .none);
}

test "query debug report for selector mismatch" {
    try run();
}
