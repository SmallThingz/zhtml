const std = @import("std");
const common = @import("../common.zig");

pub const StackPos = common.IndexInt;
pub const no_stack_pos: StackPos = common.InvalidIndex;

pub const TagSig = struct {
    key: u64,
    len: common.IndexInt,
};

pub const Map = std.AutoHashMapUnmanaged(TagSig, StackPos);

pub fn BeforeEntry(comptime Span: type) type {
    return struct {
        name: Span,
        sig: TagSig,
        prev: StackPos = no_stack_pos,
    };
}
