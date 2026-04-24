const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div><a id='one' class='nav'></a><a id='two'></a></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

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
