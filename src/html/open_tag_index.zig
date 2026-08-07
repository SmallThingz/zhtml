//! Lazy cache for malformed closing-tag recovery.
//!
//! A backwards scan of the open-element stack is cheapest for normal HTML and
//! for a mismatched close that successfully finds and pops a deep opener. It
//! becomes quadratic, however, when an attacker supplies many closing tags
//! that are absent from a deep stack. The parser therefore builds this index
//! only after the first proven full-stack miss.
//!
//! The index is a historical snapshot, not a live mirror. Normal pushes never
//! touch it, and normal pops only shorten `index_len`. Historical entries retain
//! their own source spans so stale stack positions can be repaired safely after
//! those live positions have been reused. A later slow close scans the newer
//! unindexed suffix first, rewinds stale snapshot entries only if map lookup is
//! needed, and extends the snapshot only after another complete miss. This
//! keeps the well-formed top-match path essentially identical to a plain stack
//! while bounding repeated absent-close recovery.

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
