const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div><a class='primary' href='/x'></a><a class='secondary' href='/y'></a></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    const one = try doc.queryOneRuntime(std.testing.allocator, "a.primary");
    try std.testing.expect(one != null);

    var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer runtime_arena.deinit();
    var it = try doc.queryAllRuntime(runtime_arena.allocator(), "a[href]");
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime selector APIs" {
    try run();
}
