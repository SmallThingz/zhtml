const std = @import("std");
const bench = @import("bench.zig");
pub fn main() void {
    std.debug.print("{s}\n", .{bench.lookupFullTrie("CounterClockwiseContourIntegral;").?});
}
