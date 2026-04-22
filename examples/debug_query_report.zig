const std = @import("std");
const html = @import("html");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn run() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div><a id='one' class='nav'></a><a id='two'></a></div>".*;
    try doc.parse(&input);

    const result = doc.queryOneRuntimeDebug(std.testing.allocator, "a[href^=https]");
    try std.testing.expect(result.err == null);
    try std.testing.expect(result.node == null);
    try std.testing.expect(result.report.visited_elements > 0);
    try std.testing.expect(result.report.near_miss_len > 0);
    try std.testing.expect(result.report.near_misses[0].reason.kind != .none);
}

test "query debug report for selector mismatch" {
    try run();
}
