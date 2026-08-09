//! Lazy live index for malformed closing-tag recovery.
//!
//! Normal well-formed parsing uses only the open-element stack. After the first
//! closing tag that misses a full backwards stack scan, callers activate this
//! map. From then on each open entry links to the previous entry with the same
//! first-eight-byte signature, making repeated malformed closes bounded without
//! storing malformed-close links in every normal open-stack entry.
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

pub const Map = std.AutoHashMapUnmanaged(u64, StackPos);

/// Shared live index over an open-element stack of `T`. Items expose only a
/// `keyValue()` method; duplicate-signature links live here and are allocated only
/// after malformed-close recovery activates the index. Stack positions are
/// full-stack indexes; the caller's root sits at index 0 and is never indexed.
pub fn LiveIndex(comptime T: type) type {
    return struct {
        map: Map = .empty,
        links: std.ArrayListUnmanaged(StackPos) = .empty,
        active: bool = false,

        const Self = @This();

        /// Releases the map allocation. Safe to call when already deactivated.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
            self.links.deinit(allocator);
        }

        /// Bulk-builds the map for every stack entry above index 0.
        /// Must only be called while inactive with an empty map.
        pub fn activate(self: *Self, allocator: std.mem.Allocator, items: []const T) !void {
            std.debug.assert(!self.active and self.map.count() == 0 and self.links.items.len == 0);
            try self.map.ensureTotalCapacity(allocator, @intCast(items.len));
            try self.links.resize(allocator, items.len);
            @memset(self.links.items, no_stack_pos);
            var pos: usize = 1;
            while (pos < items.len) : (pos += 1) {
                const key = items[pos].keyValue();
                self.links.items[pos] = self.map.get(key) orelse no_stack_pos;
                self.map.putAssumeCapacity(key, @intCast(pos));
            }
            self.active = true;
        }

        /// Reserves index storage for one active-stack push. No-op while inactive.
        pub inline fn preparePush(self: *Self, allocator: std.mem.Allocator, item: *const T) !void {
            if (!self.active) return;
            try self.links.ensureUnusedCapacity(allocator, 1);
            if (!self.map.contains(item.keyValue())) try self.map.ensureUnusedCapacity(allocator, 1);
        }

        /// Commits an already-reserved push. `stack_len` is the length after
        /// the push and therefore also the new link-array length.
        pub inline fn commitPush(self: *Self, item: *const T, stack_len: usize) void {
            if (!self.active) return;
            std.debug.assert(self.links.items.len + 1 == stack_len);
            const key = item.keyValue();
            const previous_pos = self.map.get(key) orelse no_stack_pos;
            self.links.appendAssumeCapacity(previous_pos);
            if (previous_pos == no_stack_pos)
                self.map.putAssumeCapacity(key, @intCast(stack_len - 1))
            else
                self.map.getPtr(key).?.* = @intCast(stack_len - 1);
        }

        /// Reverts a pop of the top item. `stack_len` is the length before pop.
        pub inline fn pop(self: *Self, item: *const T, stack_len: usize) void {
            if (!self.active) return;
            const pos = stack_len - 1;
            std.debug.assert(self.links.items.len == stack_len);
            const previous_pos = self.links.pop().?;
            const key = item.keyValue();
            std.debug.assert(self.map.get(key).? == pos);
            if (previous_pos == no_stack_pos)
                std.debug.assert(self.map.remove(key))
            else
                self.map.getPtr(key).?.* = previous_pos;
        }

        /// Returns the most recent stack position for `close`, or null when the
        /// index is inactive or the signature is absent. Callers walk the
        /// `previous()` chain themselves when first-eight-byte signatures collide.
        pub inline fn find(self: *const Self, close_key: u64) ?StackPos {
            if (!self.active) return null;
            return self.map.get(close_key);
        }

        pub inline fn previous(self: *const Self, pos: StackPos) StackPos {
            std.debug.assert(self.active and pos < self.links.items.len);
            return self.links.items[@intCast(pos)];
        }

        /// Deactivates once the stack empties down to the root (`stack_len`
        /// after a pop == 1). Invariant: every entry in the map sits at a stack
        /// position >= 1, so an empty-root stack means the map is empty; drop it
        /// and restore the no-map fast path.
        pub inline fn maybeDeactivate(self: *Self, allocator: std.mem.Allocator, stack_len: usize) void {
            if (!self.active or stack_len != 1) return;
            std.debug.assert(self.map.count() == 0 and self.links.items.len == 1);
            self.map.deinit(allocator);
            self.links.deinit(allocator);
            self.map = .empty;
            self.links = .empty;
            self.active = false;
        }
    };
}
