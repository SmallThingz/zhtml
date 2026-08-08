//! Lazy live index for malformed closing-tag recovery.
//!
//! Normal well-formed parsing uses only the open-element stack. After the first
//! closing tag that misses a full backwards stack scan, callers activate this
//! map. From then on each open entry links to the previous entry with the same
//! first-eight-byte signature, making repeated malformed closes bounded without
//! maintaining a second historical copy of the stack.

const std = @import("std");
const common = @import("../common.zig");

pub const StackPos = common.IndexInt;
pub const no_stack_pos: StackPos = common.InvalidIndex;

pub const TagSig = struct {
    key: u64,
    len: common.IndexInt,
};

pub const Map = std.AutoHashMapUnmanaged(TagSig, StackPos);

pub inline fn signature(key: u64, len: common.IndexInt) TagSig {
    return .{ .key = key, .len = len };
}
