const std = @import("std");

pub const ParseMode = enum {
    strictest,
    fastest,
    full,
};

pub fn parseMode(s: []const u8) ?ParseMode {
    if (std.mem.eql(u8, s, "strictest")) return .strictest;
    if (std.mem.eql(u8, s, "fastest")) return .fastest;
    if (std.mem.eql(u8, s, "full")) return .full;
    return null;
}
