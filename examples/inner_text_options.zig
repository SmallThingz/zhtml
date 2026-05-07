const std = @import("std");
const html = @import("html");

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var input = "<div id='x'> Hello\n  <span>world</span> &amp;\tteam </div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;

    const gpa = std.testing.allocator;
    const normalized = try node.innerTextWithOptions(gpa, .{});
    defer normalized.free(&doc, gpa);
    try std.testing.expectEqualStrings("Hello world& team", normalized.value);

    const raw = try node.innerTextWithOptions(gpa, .{ .normalize_whitespace = false });
    defer raw.free(&doc, gpa);
    try std.testing.expect(std.mem.indexOfScalar(u8, raw.value, '\n') != null);

    const owned = try node.innerTextOwnedWithOptions(gpa, .{});
    defer gpa.free(owned);
    try std.testing.expectEqualStrings("Hello world& team", owned);
    try std.testing.expect(!doc.isOwned(owned));
}

test "innerText whitespace options" {
    try run();
}
