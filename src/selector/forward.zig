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

pub const Plan = struct {
    start_none: u64 = 0,
    start_child: u64 = 0,
    start_descendant: u64 = 0,
    child_targets: u64 = 0,
    descendant_targets: u64 = 0,
    adjacent_targets: u64 = 0,
    sibling_targets: u64 = 0,
    final_mask: u64 = 0,
    needs_child_position: bool = false,
    stateful: bool = false,
    scope_self_seed_mask: u64 = 0,
    scope_lineage_seed_mask: u64 = 0,
};

inline fn bit(index: usize) u64 {
    std.debug.assert(index < MaxForwardCompounds);
    return @as(u64, 1) << @intCast(index);
}

pub fn buildPlan(selector: ast.Selector) Plan {
    var plan: Plan = .{};
    const compact = selector.compounds.len <= MaxForwardCompounds;

    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        if (group.compound_len > 1) plan.stateful = true;

        const start: usize = @intCast(group.compound_start);
        const len: usize = @intCast(group.compound_len);
        if (compact) plan.final_mask |= bit(start + len - 1);

        for (0..len) |relative| {
            const absolute = start + relative;
            const comp = selector.compounds[absolute];
            inspectCompoundFeatures(selector, comp, &plan);
            if (!compact) continue;

            const compound_bit = bit(absolute);
            if (relative == 0) {
                // Leading combinators are anchored checks in processSimple, not
                // transitions: `> div` and a leading descendant need no stack.
                switch (comp.combinator) {
                    .none => plan.start_none |= compound_bit,
                    .child => plan.start_child |= compound_bit,
                    .descendant => plan.start_descendant |= compound_bit,
                    .adjacent, .sibling => {},
                }
            } else switch (comp.combinator) {
                .child => plan.child_targets |= compound_bit,
                .descendant => plan.descendant_targets |= compound_bit,
                .adjacent => plan.adjacent_targets |= compound_bit,
                .sibling => plan.sibling_targets |= compound_bit,
                .none => {},
            }
        }
    }

    if (compact) {
        plan.scope_self_seed_mask = (plan.child_targets | plan.descendant_targets) >> 1;
        plan.scope_lineage_seed_mask = plan.descendant_targets >> 1;
    }
    return plan;
}

fn inspectCompoundFeatures(selector: ast.Selector, comp: ast.Compound, plan: *Plan) void {
    var i: IndexInt = 0;
    while (i < comp.pseudo_len) : (i += 1) {
        switch (selector.pseudos[comp.pseudo_start + i].kind) {
            .first_child, .nth_child => {
                plan.needs_child_position = true;
                plan.stateful = true;
            },
            .last_child => {},
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

pub const Stats = struct {
    nodes_processed: usize = 0,
    local_unique_predicate_evals: usize = 0,
    nodes_emitted: usize = 0,
};

pub fn Executor(comptime Doc: type) type {
    return struct {
        doc: *const Doc,
        allocator: std.mem.Allocator,
        selector: ast.Selector,
        plan: Plan,
        scope_root: IndexInt,
        root: Frame = .{},
        stack: std.ArrayListUnmanaged(Frame) = .empty,
        node_ctx: matcher.NodeContext = .{},
        predicate_plan: matcher.PredicatePlan = .{},
        seed_workspace: matcher.MatchWorkspace,
        stats: Stats = .{},
        initialized: bool = false,

        const Self = @This();

        pub fn init(doc: *const Doc, selector: ast.Selector, plan: Plan, scope_root: IndexInt) Self {
            return .{
                .doc = doc,
                .allocator = doc.allocator,
                .selector = selector,
                .plan = plan,
                .scope_root = scope_root,
                .seed_workspace = matcher.MatchWorkspace.init(doc.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit(self.allocator);
            self.node_ctx.deinit();
            self.predicate_plan.deinit(self.allocator);
            self.seed_workspace.deinit();
            self.stack = .empty;
            self.initialized = false;
        }

        pub fn process(self: *Self, idx: IndexInt) !bool {
            if (!self.plan.stateful) return self.processSimple(idx);
            if (!self.initialized) try self.ensureInitialized();
            self.syncStack(idx);
            const raw = &self.doc.nodes[idx];
            if (!raw.isElement(idx)) return false;
            self.stats.nodes_processed += 1;

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
                try self.stack.append(self.allocator, .{
                    .subtree_end = raw.subtree_end,
                    .node_index = idx,
                    .self_matches = matched,
                    .lineage_matches = lineage,
                });
            }
            const is_match = (matched & self.plan.final_mask) != 0;
            if (is_match) self.stats.nodes_emitted += 1;
            return is_match;
        }

        fn processSimple(self: *Self, idx: IndexInt) !bool {
            const raw = &self.doc.nodes[idx];
            if (!raw.isElement(idx)) return false;
            self.stats.nodes_processed += 1;
            self.node_ctx.begin(self.allocator, 0);
            for (self.selector.groups) |group| {
                if (group.compound_len != 1) continue;
                const comp = self.selector.compounds[group.compound_start];
                const anchored = switch (comp.combinator) {
                    .none, .descendant => true,
                    .child => raw.parent == self.scope_root,
                    .adjacent, .sibling => false,
                };
                if (anchored and try matcher.matchesCompoundForward(Doc, self.doc, self.selector, comp, idx, &self.node_ctx)) {
                    self.stats.local_unique_predicate_evals += 1;
                    self.stats.nodes_emitted += 1;
                    return true;
                }
                self.stats.local_unique_predicate_evals += 1;
            }
            return false;
        }

        fn ensureInitialized(self: *Self) !void {
            self.initialized = true;
            errdefer self.deinit();
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
            if (eligible_bits == 0) return 0;
            if (self.predicate_plan.state_ids.len == 0) self.predicate_plan = try matcher.PredicatePlan.init(self.allocator, self.selector);
            self.node_ctx.begin(self.allocator, child_position);
            var pending = eligible_bits;
            var seen: u64 = 0;
            var matched: u64 = 0;
            while (pending != 0) {
                const index: usize = @intCast(@ctz(pending));
                pending &= pending - 1;
                const predicate_id: usize = self.predicate_plan.state_ids[index];
                const predicate_bit = bit(predicate_id);
                if ((seen & predicate_bit) != 0) continue;
                seen |= predicate_bit;
                self.stats.local_unique_predicate_evals += 1;
                const representative: usize = @intCast(self.predicate_plan.representatives[predicate_id]);
                if (try matcher.matchesCompoundForward(Doc, self.doc, self.selector, self.selector.compounds[representative], node_index, &self.node_ctx)) {
                    matched |= eligible_bits & self.predicate_plan.predicateMaskConst(predicate_id)[0];
                }
            }
            return matched;
        }
    };
}

/// Arbitrary-width forward executor. The compact executor above remains the
/// specialized one-u64 hot path; this executor is selected only when the
/// flattened selector representation needs more than one machine word.
pub fn WideExecutor(comptime Doc: type) type {
    return struct {
        doc: *const Doc,
        allocator: std.mem.Allocator,
        selector: ast.Selector,
        plan: Plan,
        scope_root: IndexInt,
        word_count: usize,
        masks: []u64 = &.{},
        eligible_words: []u64 = &.{},
        states: std.ArrayListUnmanaged(u64) = .empty,
        stack: std.ArrayListUnmanaged(WideFrame) = .empty,
        node_ctx: matcher.NodeContext = .{},
        predicate_plan: matcher.PredicatePlan = .{},
        seen_predicates: []u64 = &.{},
        seed_workspace: matcher.MatchWorkspace,
        stats: Stats = .{},
        initialized: bool = false,
        root_child_count: usize = 0,

        const Self = @This();
        const MaskCount = 10;
        const Mask = enum(usize) {
            start_none,
            start_child,
            start_descendant,
            child_targets,
            descendant_targets,
            adjacent_targets,
            sibling_targets,
            final,
            scope_self,
            scope_lineage,
        };
        const State = enum(usize) { self_matches, lineage, prev_child, any_child };
        const WideFrame = struct {
            subtree_end: IndexInt,
            slot: usize,
            element_child_count: usize = 0,
        };

        pub fn init(doc: *const Doc, selector: ast.Selector, plan: Plan, scope_root: IndexInt) Self {
            return .{
                .doc = doc,
                .allocator = doc.allocator,
                .selector = selector,
                .plan = plan,
                .scope_root = scope_root,
                .word_count = (selector.compounds.len + 63) / 64,
                .seed_workspace = matcher.MatchWorkspace.init(doc.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.masks.len != 0) self.allocator.free(self.masks);
            self.masks = &.{};
            if (self.eligible_words.len != 0) self.allocator.free(self.eligible_words);
            self.eligible_words = &.{};
            self.states.deinit(self.allocator);
            self.states = .empty;
            self.stack.deinit(self.allocator);
            self.stack = .empty;
            self.node_ctx.deinit();
            self.predicate_plan.deinit(self.allocator);
            if (self.seen_predicates.len != 0) self.allocator.free(self.seen_predicates);
            self.seen_predicates = &.{};
            self.seed_workspace.deinit();
            self.initialized = false;
        }

        pub fn process(self: *Self, idx: IndexInt) !bool {
            if (!self.initialized) try self.ensureInitialized();
            self.syncStack(idx);
            const raw = &self.doc.nodes[idx];
            if (!raw.isElement(idx)) return false;
            self.stats.nodes_processed += 1;

            const parent_slot = if (self.stack.items.len == 0) 0 else self.stack.items[self.stack.items.len - 1].slot;
            var child_position: usize = 0;
            if (self.plan.needs_child_position) {
                if (self.stack.items.len == 0) {
                    self.root_child_count += 1;
                    child_position = self.root_child_count;
                } else {
                    self.stack.items[self.stack.items.len - 1].element_child_count += 1;
                    child_position = self.stack.items[self.stack.items.len - 1].element_child_count;
                }
            }

            const temp_slot = self.stack.items.len + 1;
            try self.ensureStateSlots(temp_slot + 1);
            const matched = self.state(temp_slot, .self_matches);
            @memset(matched, 0);
            self.buildEligible(parent_slot, raw.parent);
            try self.evaluateNode(idx, child_position, matched);

            @memcpy(self.state(parent_slot, .prev_child), matched);
            orInto(self.state(parent_slot, .any_child), matched);

            if (raw.subtree_end > idx) {
                const lineage = self.state(temp_slot, .lineage);
                @memcpy(lineage, self.state(parent_slot, .lineage));
                orInto(lineage, matched);
                @memset(self.state(temp_slot, .prev_child), 0);
                @memset(self.state(temp_slot, .any_child), 0);
                try self.stack.append(self.allocator, .{
                    .subtree_end = raw.subtree_end,
                    .slot = temp_slot,
                });
            }
            const is_match = intersects(matched, self.mask(.final));
            if (is_match) self.stats.nodes_emitted += 1;
            return is_match;
        }

        fn ensureInitialized(self: *Self) !void {
            self.initialized = true;
            errdefer self.deinit();
            self.masks = try self.allocator.alloc(u64, self.word_count * MaskCount);
            @memset(self.masks, 0);
            self.eligible_words = try self.allocator.alloc(u64, self.word_count);
            @memset(self.eligible_words, 0);
            try self.ensureStateSlots(2);
            @memset(self.states.items, 0);
            self.compileMasks();
            if (self.scope_root != InvalidIndex and self.scope_root != 0 and self.scope_root < self.doc.nodes.len) {
                try self.seedRoot();
            }
        }

        fn compileMasks(self: *Self) void {
            for (self.selector.groups) |group| {
                if (group.compound_len == 0) continue;
                const start: usize = @intCast(group.compound_start);
                const len: usize = @intCast(group.compound_len);
                setBit(self.mask(.final), start + len - 1);
                for (0..len) |rel| {
                    const absolute = start + rel;
                    const comp = self.selector.compounds[absolute];
                    if (rel == 0) {
                        switch (comp.combinator) {
                            .none => setBit(self.mask(.start_none), absolute),
                            .child => setBit(self.mask(.start_child), absolute),
                            .descendant => setBit(self.mask(.start_descendant), absolute),
                            .adjacent, .sibling => {},
                        }
                    } else switch (comp.combinator) {
                        .child => setBit(self.mask(.child_targets), absolute),
                        .descendant => setBit(self.mask(.descendant_targets), absolute),
                        .adjacent => setBit(self.mask(.adjacent_targets), absolute),
                        .sibling => setBit(self.mask(.sibling_targets), absolute),
                        .none => {},
                    }
                }
            }
            shiftRightOne(self.mask(.scope_self), self.mask(.child_targets), self.mask(.descendant_targets));
            shiftRightOne(self.mask(.scope_lineage), &.{}, self.mask(.descendant_targets));
        }

        fn seedRoot(self: *Self) !void {
            const self_state = self.state(0, .self_matches);
            try self.seedMaskAt(self.mask(.scope_self), self.scope_root, self_state);
            const lineage = self.state(0, .lineage);
            @memcpy(lineage, self_state);
            // eligible_words is scratch: overwritten by buildEligible before any
            // normal matching, so reuse it instead of a temporary allocation.
            const pending = self.eligible_words;
            @memcpy(pending, self.mask(.scope_lineage));
            var cursor = self.scope_root;
            while (any(pending) and cursor != InvalidIndex and cursor != 0) {
                const found = self.state(1, .self_matches);
                @memset(found, 0);
                try self.seedMaskAt(pending, cursor, found);
                orInto(lineage, found);
                andNotInto(pending, found);
                cursor = self.doc.nodes[cursor].parent;
            }
        }

        fn seedMaskAt(self: *Self, wanted: []const u64, node_index: IndexInt, out: []u64) !void {
            var absolute: usize = 0;
            while (absolute < self.selector.compounds.len) : (absolute += 1) {
                if (!hasBit(wanted, absolute)) continue;
                for (self.selector.groups) |group| {
                    const start: usize = @intCast(group.compound_start);
                    const len: usize = @intCast(group.compound_len);
                    if (absolute < start or absolute >= start + len) continue;
                    if (try matcher.matchesPrefixAt(Doc, self.doc, self.selector, group, absolute - start + 1, node_index, &self.seed_workspace)) setBit(out, absolute);
                    break;
                }
            }
        }

        fn buildEligible(self: *Self, parent_slot: usize, raw_parent: IndexInt) void {
            for (self.eligible_words, self.mask(.start_none), self.mask(.start_descendant)) |*dst, none, descendant| dst.* = none | descendant;
            if (raw_parent == self.scope_root) orInto(self.eligible_words, self.mask(.start_child));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .self_matches), self.mask(.child_targets));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .lineage), self.mask(.descendant_targets));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .prev_child), self.mask(.adjacent_targets));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .any_child), self.mask(.sibling_targets));
        }

        fn evaluateNode(self: *Self, node_index: IndexInt, child_position: usize, matched: []u64) !void {
            if (self.predicate_plan.state_ids.len == 0) {
                self.predicate_plan = try matcher.PredicatePlan.init(self.allocator, self.selector);
                self.seen_predicates = try self.allocator.alloc(u64, (self.predicate_plan.count + 63) / 64);
            }
            @memset(self.seen_predicates, 0);
            self.node_ctx.begin(self.allocator, child_position);
            for (self.eligible_words, 0..) |eligible_word, word_index| {
                var pending = eligible_word;
                while (pending != 0) {
                    const bit_index: usize = @intCast(@ctz(pending));
                    pending &= pending - 1;
                    const absolute = word_index * 64 + bit_index;
                    if (absolute >= self.selector.compounds.len) continue;
                    const predicate_id: usize = self.predicate_plan.state_ids[absolute];
                    const seen_bit = @as(u64, 1) << @intCast(predicate_id % 64);
                    if ((self.seen_predicates[predicate_id / 64] & seen_bit) != 0) continue;
                    self.seen_predicates[predicate_id / 64] |= seen_bit;
                    self.stats.local_unique_predicate_evals += 1;
                    const representative: usize = @intCast(self.predicate_plan.representatives[predicate_id]);
                    if (try matcher.matchesCompoundForward(Doc, self.doc, self.selector, self.selector.compounds[representative], node_index, &self.node_ctx)) {
                        for (matched, self.eligible_words, self.predicate_plan.predicateMaskConst(predicate_id)) |*dst, eligible, mask_word| dst.* |= eligible & mask_word;
                    }
                }
            }
        }

        fn syncStack(self: *Self, idx: IndexInt) void {
            while (self.stack.items.len != 0 and idx > self.stack.items[self.stack.items.len - 1].subtree_end) _ = self.stack.pop();
        }

        fn ensureStateSlots(self: *Self, slots: usize) !void {
            const needed = slots * self.word_count * 4;
            if (self.states.items.len >= needed) return;
            const old_len = self.states.items.len;
            try self.states.resize(self.allocator, needed);
            @memset(self.states.items[old_len..], 0);
        }

        fn mask(self: *Self, which: Mask) []u64 {
            const start = @intFromEnum(which) * self.word_count;
            return self.masks[start .. start + self.word_count];
        }

        fn state(self: *Self, slot: usize, which: State) []u64 {
            const start = (slot * 4 + @intFromEnum(which)) * self.word_count;
            return self.states.items[start .. start + self.word_count];
        }

        fn setBit(words: []u64, index: usize) void {
            words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }

        fn hasBit(words: []const u64, index: usize) bool {
            return (words[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
        }

        fn any(words: []const u64) bool {
            for (words) |word| if (word != 0) return true;
            return false;
        }

        fn intersects(a: []const u64, b: []const u64) bool {
            for (a, b) |lhs, rhs| if ((lhs & rhs) != 0) return true;
            return false;
        }

        fn orInto(dst: []u64, src: []const u64) void {
            for (dst, src) |*d, s| d.* |= s;
        }

        fn andNotInto(dst: []u64, src: []const u64) void {
            for (dst, src) |*d, s| d.* &= ~s;
        }

        fn shiftRightOne(dst: []u64, a: []const u64, b: []const u64) void {
            var carry: u64 = 0;
            var i = dst.len;
            while (i != 0) {
                i -= 1;
                const source = (if (a.len == 0) 0 else a[i]) | b[i];
                const next_carry = source << 63;
                dst[i] = (source >> 1) | carry;
                carry = next_carry;
            }
        }

        fn shiftOneAndOr(dst: []u64, src: []const u64, transition_mask: []const u64) void {
            var carry: u64 = 0;
            for (dst, src, transition_mask) |*d, source, mask_word| {
                const next_carry = source >> 63;
                d.* |= ((source << 1) | carry) & mask_word;
                carry = next_carry;
            }
        }
    };
}

test "forward plan flattens groups into exact transition masks" {
    const allocator = std.testing.allocator;
    var selector = try ast.Selector.compileRuntime(allocator, "a > b c + d ~ e, x > y");
    defer selector.deinit(allocator);
    const plan = buildPlan(selector);
    try std.testing.expect(plan.stateful);
    try std.testing.expectEqual(bit(0) | bit(5), plan.start_none);
    try std.testing.expectEqual(bit(1) | bit(6), plan.child_targets);
    try std.testing.expectEqual(bit(2), plan.descendant_targets);
    try std.testing.expectEqual(bit(3), plan.adjacent_targets);
    try std.testing.expectEqual(bit(4), plan.sibling_targets);
    try std.testing.expectEqual(bit(4) | bit(6), plan.final_mask);
}
