const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div id='x'> Hello\n  <span>world</span> &amp;\tteam </div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;

    var arena_normalized = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_normalized.deinit();
    const normalized = try node.innerText(arena_normalized.allocator());
    try std.testing.expectEqualStrings("Hello world & team", normalized);

    var arena_raw = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_raw.deinit();
    const raw = try node.innerTextWithOptions(arena_raw.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, '\n') != null);

    var arena_owned = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owned.deinit();
    const owned = try node.innerTextOwned(arena_owned.allocator());
    try std.testing.expectEqualStrings("Hello world & team", owned);
    try std.testing.expect(!doc.isOwned(owned));
}

test "innerText whitespace options" {
    try run();
}
