//! Lazy live index for malformed closing-tag recovery.
//!
//! Normal well-formed parsing uses only the open-element stack. After the first
//! closing tag that misses a full backwards stack scan, callers activate this
//! map. From then on each open entry links to the previous entry with the same
//! first-eight-byte signature, making repeated malformed closes bounded without
//! maintaining a second historical copy of the stack.
//!
//! `LiveIndex` is the shared state machine for that map: inactive parsing pays
//! zero cost, activation bulk-builds from the live stack once, and every
//! subsequent push/pop maintains the map in O(1). When the stack empties back
//! down to the root the map is provably empty, so the index deactivates and
//! frees its allocation, restoring the O(1) no-map hot path.

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

/// Shared live index over an open-element stack of `T`. Items must expose a
/// `sig()` method returning their close-tag `TagSig`, and a `prev_same` field
/// of type `StackPos`. Stack positions are full-stack indexes; the caller's
/// root (document node or pseudo-root) sits at index 0 and is never indexed.
pub fn LiveIndex(comptime T: type) type {
    return struct {
        map: Map = .empty,
        active: bool = false,

        const Self = @This();

        /// Releases the map allocation. Safe to call when already deactivated.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
        }

        /// Bulk-builds the map for every stack entry above index 0.
        /// Must only be called while inactive with an empty map.
        pub fn activate(self: *Self, allocator: std.mem.Allocator, items: []T) !void {
            std.debug.assert(!self.active and self.map.count() == 0);
            try self.map.ensureTotalCapacity(allocator, @intCast(items.len));
            var pos: usize = 1;
            while (pos < items.len) : (pos += 1) {
                const open = &items[pos];
                const sig = open.sig();
                open.prev_same = self.map.get(sig) orelse no_stack_pos;
                self.map.putAssumeCapacity(sig, @intCast(pos));
            }
            self.active = true;
        }

        /// Prepares a push: fills `item.prev_same` when active, so the item is
        /// safe to append to the stack. No-op while inactive.
        pub fn preparePush(self: *Self, allocator: std.mem.Allocator, item: *T) !void {
            if (!self.active) return;
            const sig = item.sig();
            if (self.map.get(sig)) |previous| {
                // Updating an existing signature cannot grow the hash map. Avoid
                // a capacity check/allocation on repeated nested tags.
                item.prev_same = previous;
                return;
            }
            try self.map.ensureUnusedCapacity(allocator, 1);
            item.prev_same = no_stack_pos;
        }

        /// Commits a push: records the item's new position. `stack_len` is the
        /// length *after* the push. Must be preceded by `preparePush`.
        pub fn commitPush(self: *Self, item: *const T, stack_len: usize) void {
            if (!self.active) return;
            const sig = item.sig();
            const pos: StackPos = @intCast(stack_len - 1);
            if (item.prev_same != no_stack_pos) {
                // preparePush already proved the entry exists. Updating through
                // the pointer avoids re-running hash-map insertion machinery.
                self.map.getPtr(sig).?.* = pos;
            } else {
                self.map.putAssumeCapacity(sig, pos);
            }
        }

        /// Reverts a pop of the top item. `stack_len` is the length *before*
        /// the pop (item's position is `stack_len - 1`).
        pub fn pop(self: *Self, item: *const T, stack_len: usize) void {
            if (!self.active) return;
            const pos = stack_len - 1;
            const sig = item.sig();
            std.debug.assert(self.map.get(sig).? == pos);
            if (item.prev_same == no_stack_pos)
                std.debug.assert(self.map.remove(sig))
            else
                self.map.getPtr(sig).?.* = item.prev_same;
        }

        /// Returns the most recent stack position for `close`, or null when the
        /// index is inactive or the signature is absent. Callers walk the
        /// `prev_same` chain themselves.
        pub fn find(self: *const Self, close_key: u64, close_len: usize) ?StackPos {
            if (!self.active) return null;
            return self.map.get(signature(close_key, @intCast(close_len)));
        }

        /// Deactivates once the stack empties down to the root (`stack_len`
        /// after a pop == 1). Invariant: every entry in the map sits at a stack
        /// position >= 1, so an empty-root stack means the map is empty; drop it
        /// and restore the no-map fast path.
        pub fn maybeDeactivate(self: *Self, allocator: std.mem.Allocator, stack_len: usize) void {
            if (!self.active or stack_len != 1) return;
            std.debug.assert(self.map.count() == 0);
            self.map.deinit(allocator);
            self.map = .empty;
            self.active = false;
        }
    };
}
