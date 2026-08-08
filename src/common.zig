const std = @import("std");
const declaration_testing = @import("testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const config = @import("config");

pub const IndexInt = switch (config.intlen) {
    .u16 => u16,
    .u32 => u32,
    .u64 => u64,
    .usize => usize,
};

/// Maximum input length representable by the configured index width.
pub const MaxLen: usize = if (@sizeOf(IndexInt) >= @sizeOf(usize))
    std.math.maxInt(usize)
else
    @as(usize, std.math.maxInt(IndexInt));

pub inline fn lenFits(len: usize) bool {
    return len <= MaxLen;
}

/// Sentinel for invalid node indexes in DOM/query paths.
pub const InvalidIndex: IndexInt = std.math.maxInt(IndexInt);

/// Inclusive-exclusive byte span into an input/source buffer.
pub const Span = struct {
    start: IndexInt = 0,
    len: IndexInt = 0,

    pub inline fn end(self: @This()) IndexInt {
        return self.start + self.len;
    }

    pub fn setEnd(self: *@This(), end_offset: IndexInt) void {
        std.debug.assert(end_offset >= self.start);
        self.len = end_offset - self.start;
    }

    pub inline fn slice(self: @This(), source: []const u8) []const u8 {
        return source[self.start..self.end()];
    }

    pub inline fn sliceMut(self: @This(), source: []u8) []u8 {
        return source[self.start..self.end()];
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Span{{start={}, len={}}}", .{ self.start, self.len });
    }
};

/// Byte-slice result that either borrows document source or owns an allocation
/// made by the caller-supplied allocator. Producers set `owned` when they
/// allocate; callers must not infer it from pointer location.
pub const SliceResult = struct {
    value: []const u8,
    owned: bool = false,

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.value);
    }
};

/// Parent element index for `node_index`, excluding root-document index 0.
pub fn parentElement(doc: anytype, node_index: IndexInt) ?IndexInt {
    const p = doc.nodeAt(node_index).raw().parent;
    if (p == InvalidIndex or p == 0) return null;
    return p;
}

/// Previous element sibling index for `node_index`.
pub fn prevElementSibling(doc: anytype, node_index: IndexInt) ?IndexInt {
    const RawNodeType = @TypeOf(doc.nodes[node_index]);
    if (comptime @FieldType(RawNodeType, "prev_sibling") != void) {
        const prev = doc.nodes[node_index].prev_sibling;
        return if (prev == InvalidIndex) null else prev;
    }

    const parent = doc.nodes[node_index].parent;
    if (parent == InvalidIndex) return null;

    const parent_end: usize = @intCast(doc.nodes[parent].subtree_end);
    var idx: usize = @as(usize, @intCast(parent)) + 1;
    var prev: IndexInt = InvalidIndex;
    while (idx < node_index and idx <= parent_end and idx < doc.nodes.len) {
        const idx_int: IndexInt = @intCast(idx);
        const node = &doc.nodes[idx];
        if (node.parent == parent and node.isElement(idx_int)) {
            prev = idx_int;
            idx = @as(usize, @intCast(node.subtree_end)) + 1;
        } else {
            idx += 1;
        }
    }
    return if (prev == InvalidIndex) null else prev;
}

/// Next element sibling index for `node_index`.
pub fn nextElementSibling(doc: anytype, node_index: IndexInt) ?IndexInt {
    const parent = doc.nodes[node_index].parent;
    if (parent == InvalidIndex) return null;

    const parent_end: usize = @intCast(doc.nodes[parent].subtree_end);
    var idx: usize = @as(usize, @intCast(doc.nodes[node_index].subtree_end)) + 1;
    while (idx <= parent_end and idx < doc.nodes.len) : (idx += 1) {
        const idx_int: IndexInt = @intCast(idx);
        const node = &doc.nodes[idx];
        if (node.parent == parent and node.isElement(idx_int)) return idx_int;
    }
    return null;
}

/// One-based element-sibling position for `node_index`.
pub fn elementSiblingPosition(doc: anytype, node_index: IndexInt) ?usize {
    const parent = doc.nodes[node_index].parent;
    if (parent == InvalidIndex) return null;

    var position: usize = 1;
    var idx: usize = @as(usize, @intCast(parent)) + 1;
    const target: usize = @intCast(node_index);
    while (idx < target and idx < doc.nodes.len) {
        const idx_int: IndexInt = @intCast(idx);
        const node = &doc.nodes[idx];
        if (node.parent == parent and node.isElement(idx_int)) {
            position += 1;
            idx = @as(usize, @intCast(node.subtree_end)) + 1;
        } else {
            idx += 1;
        }
    }
    return position;
}

/// Scope-anchor predicate shared by selector matcher and debug matcher.
pub fn matchesScopeAnchor(doc: anytype, combinator: anytype, node_index: IndexInt, scope_root: IndexInt) bool {
    if (combinator == .none) return true;

    const anchor: IndexInt = if (scope_root == InvalidIndex) 0 else scope_root;
    switch (combinator) {
        .child => {
            const p = doc.nodeAt(node_index).raw().parent;
            return p != InvalidIndex and p == anchor;
        },
        .descendant => {
            var p = doc.nodeAt(node_index).raw().parent;
            while (p != InvalidIndex) {
                if (p == anchor) return true;
                if (p == 0) break;
                p = doc.nodeAt(p).raw().parent;
            }
            return false;
        },
        .adjacent => {
            return prevElementSibling(doc, node_index) == anchor;
        },
        .sibling => {
            var prev = prevElementSibling(doc, node_index);
            while (prev) |idx| {
                if (idx == anchor) return true;
                prev = prevElementSibling(doc, idx);
            }
            return false;
        },
        .none => return true,
    }
}
