const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

pub const ParseMode = enum {
    strictest,
    fastest,
};

pub fn parseMode(s: []const u8) ?ParseMode {
    if (std.mem.eql(u8, s, "strictest")) return .strictest;
    if (std.mem.eql(u8, s, "fastest")) return .fastest;
    return null;
}

pub fn parseDoc(noalias doc: *Document, input: []u8, mode: ParseMode) !void {
    switch (mode) {
        .strictest => try doc.parse(input, .{ .drop_whitespace_text_nodes = false }),
        .fastest => try doc.parse(input, .{ .drop_whitespace_text_nodes = true }),
    }
}
