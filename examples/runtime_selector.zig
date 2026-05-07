const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div><a class='primary' href='/x'></a><a class='secondary' href='/y'></a></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer runtime_arena.deinit();

    const primary = try html.Selector.compileRuntime(runtime_arena.allocator(), "a.primary");
    var primary_links = doc.queryRuntime(primary);
    const one = primary_links.next();
    try std.testing.expect(one != null);

    const links = try html.Selector.compileRuntime(runtime_arena.allocator(), "a[href]");
    var it = doc.queryRuntime(links);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime selector APIs" {
    try run();
}
