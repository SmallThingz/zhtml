const std = @import("std");
const declaration_testing = @import("../testing.zig");
const ast = @import("ast.zig");
const matcher = @import("matcher.zig");
const common = @import("../common.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

const IndexInt = common.IndexInt;
const InvalidIndex = common.InvalidIndex;

pub const MaxForwardCompounds: usize = 64;

pub const Kind = enum { simple, forward, rtl };

pub const Plan = struct {
    kind: Kind = .rtl,
    start_none: u64 = 0,
    start_child: u64 = 0,
    start_descendant: u64 = 0,
    child_targets: u64 = 0,
    descendant_targets: u64 = 0,
    adjacent_targets: u64 = 0,
    sibling_targets: u64 = 0,
    final_mask: u64 = 0,
    needs_child_position: bool = false,
    needs_last_child: bool = false,
    needs_attributes: bool = false,
    scope_self_seed_mask: u64 = 0,
    scope_lineage_seed_mask: u64 = 0,
};

inline fn bit(index: usize) u64 {
    std.debug.assert(index < MaxForwardCompounds);
    return @as(u64, 1) << @intCast(index);
}

pub fn buildPlan(selector: ast.Selector) Plan {
    if (selector.compounds.len > MaxForwardCompounds) return .{ .kind = .rtl };

    var plan: Plan = .{ .kind = .simple };
    var requires_forward_state = false;
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const start: usize = @intCast(group.compound_start);
        const len: usize = @intCast(group.compound_len);
        plan.final_mask |= bit(start + len - 1);

        for (0..len) |relative| {
            const absolute = start + relative;
            const comp = selector.compounds[absolute];
            const compound_bit = bit(absolute);
            if (relative == 0) {
                switch (comp.combinator) {
                    .none => plan.start_none |= compound_bit,
                    .child => {
                        plan.start_child |= compound_bit;
                        requires_forward_state = true;
                    },
                    .descendant => {
                        plan.start_descendant |= compound_bit;
                        requires_forward_state = true;
                    },
                    .adjacent, .sibling => {},
                }
            } else {
                requires_forward_state = true;
                switch (comp.combinator) {
                    .child => plan.child_targets |= compound_bit,
                    .descendant => plan.descendant_targets |= compound_bit,
                    .adjacent => plan.adjacent_targets |= compound_bit,
                    .sibling => plan.sibling_targets |= compound_bit,
                    .none => {},
                }
            }
            inspectCompoundFeatures(selector, comp, &plan, &requires_forward_state);
        }
    }

    plan.scope_self_seed_mask = (plan.child_targets | plan.descendant_targets) >> 1;
    plan.scope_lineage_seed_mask = plan.descendant_targets >> 1;
    if (requires_forward_state) plan.kind = .forward;
    return plan;
}

fn inspectCompoundFeatures(selector: ast.Selector, comp: ast.Compound, plan: *Plan, requires_forward_state: *bool) void {
    if (comp.hasId() or comp.class_len != 0 or comp.attr_len != 0) plan.needs_attributes = true;
    var i: IndexInt = 0;
    while (i < comp.pseudo_len) : (i += 1) {
        switch (selector.pseudos[comp.pseudo_start + i].kind) {
            .first_child, .nth_child => {
                plan.needs_child_position = true;
                requires_forward_state.* = true;
            },
            .last_child => plan.needs_last_child = true,
        }
    }
    i = 0;
    while (i < comp.not_len) : (i += 1) {
        switch (selector.not_items[comp.not_start + i].kind) {
            .id, .class, .attr => plan.needs_attributes = true,
            .tag => {},
        }
    }
}

pub const Frame = struct {
    subtree_end: IndexInt = 0,
    node_index: IndexInt = InvalidIndex,
    self_matches: u64 = 0,
    lineage_matches: u64 = 0,
    prev_child_matches: u64 = 0,
    any_child_matches: u64 = 0,
    element_child_count: usize = 0,
};

pub fn Executor(comptime Doc: type) type {
    return struct {
        doc: *const Doc,
        selector: ast.Selector,
        plan: Plan,
        scope_root: IndexInt,
        root: Frame = .{},
        stack: std.ArrayListUnmanaged(Frame) = .empty,
        node_ctx: matcher.ForwardNodeContext = .{},
        seed_workspace: matcher.MatchWorkspace,
        initialized: bool = false,

        const Self = @This();

        pub fn init(doc: *const Doc, selector: ast.Selector, plan: Plan, scope_root: IndexInt) Self {
            return .{
                .doc = doc,
                .selector = selector,
                .plan = plan,
                .scope_root = scope_root,
                .seed_workspace = matcher.MatchWorkspace.init(doc.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit(self.doc.allocator);
            self.node_ctx.deinit();
            self.seed_workspace.deinit();
            self.stack = .empty;
            self.initialized = false;
        }

        pub fn process(self: *Self, idx: IndexInt) !bool {
            if (!self.initialized) try self.ensureInitialized();
            if (self.plan.kind == .simple) return self.processSimple(idx);
            self.syncStack(idx);
            const raw = &self.doc.nodes[idx];
            if (!raw.isElement(idx)) return false;

            var parent = self.currentParent();
            var child_position: usize = 0;
            if (self.plan.needs_child_position) {
                parent.element_child_count += 1;
                child_position = parent.element_child_count;
            }
            const eligible_bits = self.eligibleMask(parent, raw.parent);
            const matched = try self.evaluateEligible(idx, eligible_bits, child_position);

            parent.prev_child_matches = matched;
            parent.any_child_matches |= matched;
            const lineage = parent.lineage_matches | matched;
            if (raw.subtree_end > idx) {
                try self.stack.append(self.doc.allocator, .{
                    .subtree_end = raw.subtree_end,
                    .node_index = idx,
                    .self_matches = matched,
                    .lineage_matches = lineage,
                });
            }
            return (matched & self.plan.final_mask) != 0;
        }

        fn processSimple(self: *Self, idx: IndexInt) !bool {
            const raw = &self.doc.nodes[idx];
            if (!raw.isElement(idx)) return false;
            var eligible_bits = self.plan.start_none | self.plan.start_descendant;
            if (raw.parent == self.scope_root) eligible_bits |= self.plan.start_child;
            const matched = try self.evaluateEligible(idx, eligible_bits, 0);
            return (matched & self.plan.final_mask) != 0;
        }

        fn ensureInitialized(self: *Self) !void {
            self.initialized = true;
            self.root = .{ .node_index = self.scope_root };
            if (self.scope_root == InvalidIndex or self.scope_root == 0 or self.scope_root >= self.doc.nodes.len) return;
            self.root.self_matches = try self.seedMaskAt(self.plan.scope_self_seed_mask, self.scope_root);

            var pending = self.plan.scope_lineage_seed_mask;
            var cursor = self.scope_root;
            while (pending != 0 and cursor != InvalidIndex and cursor != 0) {
                const found = try self.seedMaskAt(pending, cursor);
                self.root.lineage_matches |= found;
                pending &= ~found;
                cursor = self.doc.nodes[cursor].parent;
            }
            self.root.lineage_matches |= self.root.self_matches;
        }

        fn seedMaskAt(self: *Self, mask: u64, node_index: IndexInt) !u64 {
            var pending = mask;
            var matched: u64 = 0;
            while (pending != 0) {
                const absolute: usize = @intCast(@ctz(pending));
                pending &= pending - 1;
                for (self.selector.groups) |group| {
                    const start: usize = @intCast(group.compound_start);
                    const len: usize = @intCast(group.compound_len);
                    if (absolute < start or absolute >= start + len) continue;
                    if (try matcher.matchesPrefixAt(Doc, self.doc, self.selector, group, absolute - start + 1, node_index, &self.seed_workspace)) matched |= bit(absolute);
                    break;
                }
            }
            return matched;
        }

        fn syncStack(self: *Self, idx: IndexInt) void {
            while (self.stack.items.len != 0 and idx > self.stack.items[self.stack.items.len - 1].subtree_end) _ = self.stack.pop();
            if (self.stack.items.len != 0) std.debug.assert(self.doc.nodes[idx].parent == self.stack.items[self.stack.items.len - 1].node_index or !self.doc.nodes[idx].isElement(idx));
        }

        fn currentParent(self: *Self) *Frame {
            if (self.stack.items.len != 0) return &self.stack.items[self.stack.items.len - 1];
            return &self.root;
        }

        fn eligibleMask(self: *const Self, parent: *const Frame, raw_parent: IndexInt) u64 {
            var result = self.plan.start_none | self.plan.start_descendant;
            if (raw_parent == self.scope_root) result |= self.plan.start_child;
            result |= (parent.self_matches << 1) & self.plan.child_targets;
            result |= (parent.lineage_matches << 1) & self.plan.descendant_targets;
            result |= (parent.prev_child_matches << 1) & self.plan.adjacent_targets;
            result |= (parent.any_child_matches << 1) & self.plan.sibling_targets;
            return result;
        }

        fn evaluateEligible(self: *Self, node_index: IndexInt, eligible_bits: u64, child_position: usize) !u64 {
            var pending = eligible_bits;
            const node_name = self.doc.nodes[node_index].name_or_text.slice(self.doc.source);
            var candidates: u64 = 0;
            while (pending != 0) {
                const index: usize = @intCast(@ctz(pending));
                pending &= pending - 1;
                const comp = self.selector.compounds[index];
                if (!comp.hasTag() or matcher.tagMatches(Doc, self.selector.source, comp, node_name)) candidates |= bit(index);
            }
            if (candidates == 0) return 0;

            self.node_ctx.begin(self.doc.allocator, child_position);
            pending = candidates;
            var matched: u64 = 0;
            while (pending != 0) {
                const index: usize = @intCast(@ctz(pending));
                pending &= pending - 1;
                if (try matcher.matchesCompoundForward(Doc, self.doc, self.selector, self.selector.compounds[index], node_index, &self.node_ctx)) matched |= bit(index);
            }
            return matched;
        }
    };
}

test "forward plan flattens groups into exact transition masks" {
    const allocator = std.testing.allocator;
    var selector = try ast.Selector.compileRuntime(allocator, "a > b c + d ~ e, x > y");
    defer selector.deinit(allocator);
    const plan = buildPlan(selector);
    try std.testing.expectEqual(Kind.forward, plan.kind);
    try std.testing.expectEqual(bit(0) | bit(5), plan.start_none);
    try std.testing.expectEqual(bit(1) | bit(6), plan.child_targets);
    try std.testing.expectEqual(bit(2), plan.descendant_targets);
    try std.testing.expectEqual(bit(3), plan.adjacent_targets);
    try std.testing.expectEqual(bit(4), plan.sibling_targets);
    try std.testing.expectEqual(bit(4) | bit(6), plan.final_mask);
}
