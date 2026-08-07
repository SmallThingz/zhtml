const std = @import("std");
const data = @import("data.zig");

pub fn main() void {
    for (data.entries) |entry| {
        const name = data.names[entry.name_start..][0..entry.name_len];
        std.debug.print("{d}\n", .{std.hash.Wyhash.hash(0, name)});
    }
}
