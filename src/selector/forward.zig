const std = @import("std");
const builtin = @import("builtin");
const declaration_testing = @import("../testing.zig");
const ast = @import("ast.zig");
const matcher = @import("matcher.zig");
const execution_plan = @import("execution_plan.zig");
const common = @import("../common.zig");
const tags = @import("../html/tags.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

const IndexInt = common.IndexInt;
const InvalidIndex = common.InvalidIndex;

inline fn bitWordCount(count: usize) usize {
    return count / 64 + @intFromBool(count % 64 != 0);
}

fn checkedStateStorageWords(slots: usize, word_count: usize) !usize {
    const words_per_slot = std.math.mul(usize, word_count, 4) catch return error.OutOfMemory;
    return std.math.mul(usize, slots, words_per_slot) catch error.OutOfMemory;
}

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
    continuation_mask: u64 = 0,
    needs_child_position: bool = false,
    stateful: bool = false,
    scope_self_seed_mask: u64 = 0,
    scope_lineage_seed_mask: u64 = 0,
    has_tag_constraints: bool = false,
    short_tag_only_mask: u64 = 0,
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
            plan.has_tag_constraints = plan.has_tag_constraints or comp.hasTag();
            if (!compact) continue;

            const compound_bit = bit(absolute);
            if (comp.hasTag() and comp.tag.len <= 8 and !comp.hasId() and comp.class_len == 0 and comp.attr_len == 0 and comp.pseudo_len == 0 and comp.not_len == 0)
                plan.short_tag_only_mask |= compound_bit;
            if (relative + 1 < len) plan.continuation_mask |= compound_bit;
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
    self_matches: u64 = 0,
    lineage_matches: u64 = 0,
    prev_child_matches: u64 = 0,
    any_child_matches: u64 = 0,
    subtree_end: IndexInt = 0,
    element_child_count: IndexInt = 0,
};

pub const Stats = struct {
    nodes_processed: usize = 0,
    local_unique_predicate_evals: usize = 0,
    predicate_state_word_fanouts: usize = 0,
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
        owns_predicate_plan: bool = true,
        seed_workspace: matcher.MatchWorkspace,
        stats: Stats = .{},
        initialized: bool = false,
        tag_cache: [16]TagCacheEntry = [_]TagCacheEntry{.{}} ** 16,

        const Self = @This();
        const TagCacheEntry = struct {
            key: u64 = 0,
            len: IndexInt = 0,
            allowed: u64 = 0,
            valid: bool = false,
        };

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

        pub fn initPrepared(doc: *const Doc, selector: ast.Selector, plan: Plan, scope_root: IndexInt, predicate_plan: *const matcher.PredicatePlan) Self {
            var out = init(doc, selector, plan, scope_root);
            out.predicate_plan = predicate_plan.*;
            out.owns_predicate_plan = false;
            return out;
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit(self.allocator);
            self.node_ctx.deinit();
            if (self.owns_predicate_plan) self.predicate_plan.deinit(self.allocator);
            self.seed_workspace.deinit();
            self.stack = .empty;
            self.initialized = false;
        }

        pub fn process(self: *Self, idx: IndexInt) !bool {
            if (!self.doc.nodes[idx].isElement(idx)) return false;
            return self.processElement(idx);
        }

        pub fn processElement(self: *Self, idx: IndexInt) !bool {
            if (!self.plan.stateful) return self.processSimpleElement(idx);
            if (!self.initialized) try self.ensureInitialized();
            self.syncStack(idx);
            const raw = &self.doc.nodes[idx];
            if (comptime builtin.is_test) self.stats.nodes_processed += 1;

            var parent = self.currentParent();
            var child_position: usize = 0;
            if (self.plan.needs_child_position) {
                parent.element_child_count += 1;
                child_position = @intCast(parent.element_child_count);
            }
            var eligible_bits = self.eligibleMask(parent, raw.parent);
            if (self.plan.has_tag_constraints) eligible_bits &= self.tagAllowedMask(raw.name_or_text.slice(self.doc.source));
            const matched = try self.evaluateEligible(idx, eligible_bits, child_position);
            const final_hits = matched & self.plan.final_mask;
            const persistent = matched & self.plan.continuation_mask;

            parent.prev_child_matches = persistent;
            parent.any_child_matches |= persistent;
            const lineage = parent.lineage_matches | persistent;
            if (raw.subtree_end > idx) {
                try self.stack.append(self.allocator, .{
                    .subtree_end = raw.subtree_end,
                    .self_matches = persistent,
                    .lineage_matches = lineage,
                });
            }
            const is_match = final_hits != 0;
            if (comptime builtin.is_test) {
                if (is_match) self.stats.nodes_emitted += 1;
            }
            return is_match;
        }

        fn processSimpleElement(self: *Self, idx: IndexInt) !bool {
            const raw = &self.doc.nodes[idx];
            if (comptime builtin.is_test) self.stats.nodes_processed += 1;
            self.node_ctx.begin(0);
            const allowed = if (self.plan.has_tag_constraints) self.tagAllowedMask(raw.name_or_text.slice(self.doc.source)) else std.math.maxInt(u64);
            for (self.selector.groups) |group| {
                if (group.compound_len != 1) continue;
                const absolute: usize = @intCast(group.compound_start);
                if ((allowed & bit(absolute)) == 0) continue;
                const comp = self.selector.compounds[group.compound_start];
                const anchored = switch (comp.combinator) {
                    .none, .descendant => true,
                    .child => raw.parent == self.scope_root,
                    .adjacent, .sibling => false,
                };
                if (anchored) {
                    if (comptime builtin.is_test) self.stats.local_unique_predicate_evals += 1;
                    if ((self.plan.short_tag_only_mask & bit(absolute)) != 0 or try matcher.matchesCompoundForward(Doc, self.doc, self.selector, comp, idx, &self.node_ctx)) {
                        if (comptime builtin.is_test) self.stats.nodes_emitted += 1;
                        return true;
                    }
                } else {
                    if (comptime builtin.is_test) self.stats.local_unique_predicate_evals += 1;
                }
            }
            return false;
        }

        fn ensureInitialized(self: *Self) !void {
            self.initialized = true;
            errdefer self.deinit();
            self.root = .{};
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

        fn tagAllowedMask(self: *Self, node_name: []const u8) u64 {
            const key = tags.first8KeyWithMode(node_name, Doc.Options.non_destructive);
            const len: IndexInt = @intCast(node_name.len);
            const mixed = key ^ (@as(u64, len) *% 0x9e3779b97f4a7c15);
            const slot: usize = @intCast(mixed & 15);
            const cached = &self.tag_cache[slot];
            if (cached.valid and cached.key == key and cached.len == len) return cached.allowed;

            var allowed: u64 = 0;
            for (self.selector.compounds, 0..) |comp, absolute| {
                if (!comp.hasTag()) {
                    allowed |= bit(absolute);
                    continue;
                }
                const tag = comp.tag.slice(self.selector.source);
                const tag_key = if (comp.tag_key != 0) comp.tag_key else tags.first8KeyWithMode(tag, false);
                if (tag.len == node_name.len and tag_key == key) allowed |= bit(absolute);
            }
            cached.* = .{ .key = key, .len = len, .allowed = allowed, .valid = true };
            return allowed;
        }

        fn syncStack(self: *Self, idx: IndexInt) void {
            while (self.stack.items.len != 0 and idx > self.stack.items[self.stack.items.len - 1].subtree_end) _ = self.stack.pop();
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
            self.node_ctx.begin(child_position);
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
                if (comptime builtin.is_test) self.stats.local_unique_predicate_evals += 1;
                const representative: usize = @intCast(self.predicate_plan.representatives[predicate_id]);
                if (try matcher.matchesCompoundForward(Doc, self.doc, self.selector, self.selector.compounds[representative], node_index, &self.node_ctx)) {
                    for (self.predicate_plan.usesFor(predicate_id)) |use| {
                        if (use.word_index != 0) continue;
                        matched |= eligible_bits & use.mask;
                    }
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
        scope_root: IndexInt,
        exec_plan: execution_plan.Plan = .{},
        owns_exec_plan: bool = true,
        word_count: usize = 0,
        eligible_words: []u64 = &.{},
        tag_allowed: []u64 = &.{},
        states: std.ArrayListUnmanaged(u64) = .empty,
        stack: std.ArrayListUnmanaged(WideFrame) = .empty,
        node_ctx: matcher.NodeContext = .{},
        predicate_word_count: usize = 0,
        small_seen_predicates: [SmallPredicateWordLimit]u64 = [_]u64{0} ** SmallPredicateWordLimit,
        seen_predicates: []u64 = &.{},
        matched_predicates: []u64 = &.{},
        state_fanned_predicates: []u64 = &.{},
        touched_predicates: std.ArrayListUnmanaged(usize) = .empty,
        seed_workspace: matcher.MatchWorkspace,
        stats: Stats = .{},
        initialized: bool = false,
        root_child_count: IndexInt = 0,

        const Self = @This();
        const SmallPredicateWordLimit: usize = 4;
        const State = enum(usize) { self_matches, lineage, prev_child, any_child };
        const WideFrame = struct {
            slot: usize,
            subtree_end: IndexInt,
            element_child_count: IndexInt = 0,
        };

        pub fn init(doc: *const Doc, selector: ast.Selector, scope_root: IndexInt) Self {
            return .{
                .doc = doc,
                .allocator = doc.allocator,
                .selector = selector,
                .scope_root = scope_root,
                .seed_workspace = matcher.MatchWorkspace.init(doc.allocator),
            };
        }

        pub fn initPrepared(doc: *const Doc, selector: ast.Selector, scope_root: IndexInt, prepared: *const execution_plan.Plan) Self {
            var out = init(doc, selector, scope_root);
            out.exec_plan = prepared.*;
            out.owns_exec_plan = false;
            return out;
        }

        pub fn deinit(self: *Self) void {
            if (self.owns_exec_plan) self.exec_plan.deinit(self.allocator);
            self.exec_plan = .{};
            if (self.eligible_words.len != 0) self.allocator.free(self.eligible_words);
            self.eligible_words = &.{};
            if (self.tag_allowed.len != 0) self.allocator.free(self.tag_allowed);
            self.tag_allowed = &.{};
            self.states.deinit(self.allocator);
            self.states = .empty;
            self.stack.deinit(self.allocator);
            self.stack = .empty;
            self.node_ctx.deinit();
            if (self.seen_predicates.len != 0) self.allocator.free(self.seen_predicates);
            self.seen_predicates = &.{};
            if (self.matched_predicates.len != 0) self.allocator.free(self.matched_predicates);
            self.matched_predicates = &.{};
            if (self.state_fanned_predicates.len != 0) self.allocator.free(self.state_fanned_predicates);
            self.state_fanned_predicates = &.{};
            self.touched_predicates.deinit(self.allocator);
            self.touched_predicates = .empty;
            self.seed_workspace.deinit();
            self.word_count = 0;
            self.predicate_word_count = 0;
            self.owns_exec_plan = true;
            self.initialized = false;
            self.root_child_count = 0;
        }

        pub fn process(self: *Self, idx: IndexInt) !bool {
            if (!self.doc.nodes[idx].isElement(idx)) return false;
            return self.processElement(idx);
        }

        pub fn processElement(self: *Self, idx: IndexInt) !bool {
            if (!self.initialized) try self.ensureInitialized();
            self.syncStack(idx);
            const raw = &self.doc.nodes[idx];
            if (comptime builtin.is_test) self.stats.nodes_processed += 1;

            const parent_slot = if (self.stack.items.len == 0) 0 else self.stack.items[self.stack.items.len - 1].slot;
            var child_position: usize = 0;
            if (self.exec_plan.needs_child_position) {
                if (self.stack.items.len == 0) {
                    self.root_child_count += 1;
                    child_position = @intCast(self.root_child_count);
                } else {
                    self.stack.items[self.stack.items.len - 1].element_child_count += 1;
                    child_position = @intCast(self.stack.items[self.stack.items.len - 1].element_child_count);
                }
            }

            self.beginNode(child_position);
            var is_match = try self.evaluateSimpleGroups(idx, raw.parent);
            const temp_slot = self.stack.items.len + 1;
            if (self.word_count != 0) {
                try self.ensureStateSlots(temp_slot + 1);
                const matched = self.state(temp_slot, .self_matches);
                @memset(matched, 0);
                self.buildEligible(parent_slot, raw.parent);
                if (self.exec_plan.filter_state_tags) self.filterEligibleByTag(raw.name_or_text.slice(self.doc.source));
                try self.evaluateStates(idx, matched);
                is_match = is_match or intersects(matched, self.exec_plan.mask(.final));

                // Terminal states are observed above but never propagated.
                andInto(matched, self.exec_plan.mask(.continuation));
                @memcpy(self.state(parent_slot, .prev_child), matched);
                orInto(self.state(parent_slot, .any_child), matched);

                if (raw.subtree_end > idx) {
                    const lineage = self.state(temp_slot, .lineage);
                    @memcpy(lineage, self.state(parent_slot, .lineage));
                    orInto(lineage, matched);
                    @memset(self.state(temp_slot, .prev_child), 0);
                    @memset(self.state(temp_slot, .any_child), 0);
                }
            }

            if (raw.subtree_end > idx and (self.word_count != 0 or self.exec_plan.needs_child_position)) {
                if (self.stack.items.len == self.stack.capacity) {
                    @branchHint(.unlikely);
                    try self.growStack();
                }
                self.stack.appendAssumeCapacity(.{
                    .subtree_end = raw.subtree_end,
                    .slot = temp_slot,
                });
            }
            if (comptime builtin.is_test) {
                if (is_match) self.stats.nodes_emitted += 1;
            }
            return is_match;
        }

        noinline fn growStack(self: *Self) !void {
            @branchHint(.cold);
            try self.stack.ensureUnusedCapacity(self.allocator, 1);
        }

        fn ensureInitialized(self: *Self) !void {
            self.initialized = true;
            errdefer self.deinit();
            if (self.owns_exec_plan) self.exec_plan = try execution_plan.Plan.init(self.allocator, self.selector);
            self.word_count = self.exec_plan.word_count;
            if (self.word_count != 0) {
                self.eligible_words = try self.allocator.alloc(u64, self.word_count);
                @memset(self.eligible_words, 0);
                if (self.exec_plan.filter_state_tags) {
                    self.tag_allowed = try self.allocator.alloc(u64, self.word_count);
                    @memset(self.tag_allowed, 0);
                }
                try self.ensureStateSlots(2);
                @memset(self.states.items, 0);
            }
            self.predicate_word_count = bitWordCount(self.exec_plan.predicates.count);
            if (self.predicate_word_count != 0 and !self.usesDensePredicates() and !self.usesInlinePredicateReset()) {
                self.seen_predicates = try self.allocator.alloc(u64, self.predicate_word_count);
                @memset(self.seen_predicates, 0);
                if (self.exec_plan.simple_groups.len != 0) {
                    self.matched_predicates = try self.allocator.alloc(u64, self.predicate_word_count);
                    @memset(self.matched_predicates, 0);
                    self.state_fanned_predicates = try self.allocator.alloc(u64, self.predicate_word_count);
                    @memset(self.state_fanned_predicates, 0);
                }
                try self.touched_predicates.ensureTotalCapacity(
                    self.allocator,
                    @min(self.exec_plan.predicates.count, 64),
                );
            }
            if (self.word_count != 0 and self.scope_root != InvalidIndex and self.scope_root != 0 and self.scope_root < self.doc.nodes.len) {
                try self.seedRoot();
            }
        }

        fn seedRoot(self: *Self) !void {
            const self_state = self.state(0, .self_matches);
            try self.seedMaskAt(self.exec_plan.mask(.scope_self), self.scope_root, self_state);
            const lineage = self.state(0, .lineage);
            @memcpy(lineage, self_state);
            const pending = self.eligible_words;
            @memcpy(pending, self.exec_plan.mask(.scope_lineage));
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
            for (wanted, 0..) |wanted_word, word_index| {
                var pending = wanted_word;
                while (pending != 0) {
                    const local_bit: usize = @intCast(@ctz(pending));
                    pending &= pending - 1;
                    const state_index = word_index * 64 + local_bit;
                    if (state_index >= self.exec_plan.state_count) continue;
                    const meta = self.exec_plan.states[state_index];
                    const group = self.selector.groups[meta.group_index];
                    if (try matcher.matchesPrefixAt(
                        Doc,
                        self.doc,
                        self.selector,
                        group,
                        @as(usize, @intCast(meta.relative)) + 1,
                        node_index,
                        &self.seed_workspace,
                    )) setBit(out, state_index);
                }
            }
        }

        fn buildEligible(self: *Self, parent_slot: usize, raw_parent: IndexInt) void {
            switch (self.word_count) {
                1 => return self.buildEligibleFixed(1, parent_slot, raw_parent),
                2 => return self.buildEligibleFixed(2, parent_slot, raw_parent),
                3 => return self.buildEligibleFixed(3, parent_slot, raw_parent),
                4 => return self.buildEligibleFixed(4, parent_slot, raw_parent),
                else => {},
            }
            for (self.eligible_words, self.exec_plan.mask(.start_none), self.exec_plan.mask(.start_descendant)) |*dst, none, descendant| dst.* = none | descendant;
            if (raw_parent == self.scope_root) orInto(self.eligible_words, self.exec_plan.mask(.start_child));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .self_matches), self.exec_plan.mask(.child_targets));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .lineage), self.exec_plan.mask(.descendant_targets));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .prev_child), self.exec_plan.mask(.adjacent_targets));
            shiftOneAndOr(self.eligible_words, self.state(parent_slot, .any_child), self.exec_plan.mask(.sibling_targets));
        }

        fn buildEligibleFixed(self: *Self, comptime word_count: usize, parent_slot: usize, raw_parent: IndexInt) void {
            const self_matches = self.state(parent_slot, .self_matches);
            const lineage = self.state(parent_slot, .lineage);
            const prev_child = self.state(parent_slot, .prev_child);
            const any_child = self.state(parent_slot, .any_child);
            const start_none = self.exec_plan.mask(.start_none);
            const start_descendant = self.exec_plan.mask(.start_descendant);
            const start_child = self.exec_plan.mask(.start_child);
            const child_targets = self.exec_plan.mask(.child_targets);
            const descendant_targets = self.exec_plan.mask(.descendant_targets);
            const adjacent_targets = self.exec_plan.mask(.adjacent_targets);
            const sibling_targets = self.exec_plan.mask(.sibling_targets);
            const scope_child = raw_parent == self.scope_root;

            var self_carry: u64 = 0;
            var lineage_carry: u64 = 0;
            var prev_carry: u64 = 0;
            var any_carry: u64 = 0;
            inline for (0..word_count) |i| {
                const self_word = self_matches[i];
                const lineage_word = lineage[i];
                const prev_word = prev_child[i];
                const any_word = any_child[i];
                var eligible = start_none[i] | start_descendant[i];
                if (scope_child) eligible |= start_child[i];
                eligible |= ((self_word << 1) | self_carry) & child_targets[i];
                eligible |= ((lineage_word << 1) | lineage_carry) & descendant_targets[i];
                eligible |= ((prev_word << 1) | prev_carry) & adjacent_targets[i];
                eligible |= ((any_word << 1) | any_carry) & sibling_targets[i];
                self.eligible_words[i] = eligible;
                self_carry = self_word >> 63;
                lineage_carry = lineage_word >> 63;
                prev_carry = prev_word >> 63;
                any_carry = any_word >> 63;
            }
        }

        fn beginNode(self: *Self, child_position: usize) void {
            if (self.usesDensePredicates()) {
                self.node_ctx.begin(child_position);
                return;
            }
            if (self.usesInlinePredicateReset()) {
                self.clearInlineSeen();
                self.node_ctx.begin(child_position);
                return;
            }

            for (self.touched_predicates.items) |predicate_id| {
                const bit_mask = @as(u64, 1) << @intCast(predicate_id % 64);
                const word = predicate_id / 64;
                self.seen_predicates[word] &= ~bit_mask;
                if (self.exec_plan.simple_groups.len != 0) {
                    self.matched_predicates[word] &= ~bit_mask;
                    self.state_fanned_predicates[word] &= ~bit_mask;
                }
            }
            self.touched_predicates.clearRetainingCapacity();
            self.node_ctx.begin(child_position);
        }

        fn predicateMatches(self: *Self, predicate_id: usize, node_index: IndexInt) !bool {
            const bit_mask = @as(u64, 1) << @intCast(predicate_id % 64);
            const word = predicate_id / 64;
            std.debug.assert(self.exec_plan.simple_groups.len != 0);
            if ((self.seen_predicates[word] & bit_mask) != 0) return (self.matched_predicates[word] & bit_mask) != 0;
            try self.touched_predicates.append(self.allocator, predicate_id);
            self.seen_predicates[word] |= bit_mask;
            if (comptime builtin.is_test) self.stats.local_unique_predicate_evals += 1;
            const representative: usize = @intCast(self.exec_plan.predicates.representatives[predicate_id]);
            const result = try matcher.matchesCompoundForward(
                Doc,
                self.doc,
                self.selector,
                self.selector.compounds[representative],
                node_index,
                &self.node_ctx,
            );
            if (result) self.matched_predicates[word] |= bit_mask;
            return result;
        }

        fn evaluateSimpleGroups(self: *Self, node_index: IndexInt, raw_parent: IndexInt) !bool {
            if (!self.exec_plan.has_tag_constraints) {
                for (0..self.exec_plan.simple_groups.len) |simple_index| {
                    if (try self.evaluateSimpleIndex(simple_index, node_index, raw_parent)) return true;
                }
                return false;
            }

            const node_name = self.doc.nodes[node_index].name_or_text.slice(self.doc.source);
            const sig: execution_plan.TagSig = .{
                .key = tags.first8KeyWithMode(node_name, Doc.Options.non_destructive),
                .len = @intCast(node_name.len),
            };
            const tagged = if (self.exec_plan.tag_dispatch.find(sig)) |entry|
                self.exec_plan.tag_dispatch.simpleIndices(entry)
            else
                &.{};
            const wildcard = self.exec_plan.tag_dispatch.wildcard_simple;

            var wi: usize = 0;
            var ti: usize = 0;
            while (wi < wildcard.len or ti < tagged.len) {
                const simple_index = if (ti >= tagged.len or (wi < wildcard.len and wildcard[wi] < tagged[ti])) blk: {
                    defer wi += 1;
                    break :blk wildcard[wi];
                } else blk: {
                    defer ti += 1;
                    break :blk tagged[ti];
                };
                if (try self.evaluateSimpleIndex(simple_index, node_index, raw_parent)) return true;
            }
            return false;
        }

        fn evaluateSimpleIndex(self: *Self, simple_index: usize, node_index: IndexInt, raw_parent: IndexInt) !bool {
            const simple = self.exec_plan.simple_groups[simple_index];
            const comp = self.selector.compounds[simple.compound];
            const anchored = switch (comp.combinator) {
                .none, .descendant => true,
                .child => raw_parent == self.scope_root,
                .adjacent, .sibling => false,
            };
            if (!anchored) return false;
            const predicate_id: usize = @intCast(self.exec_plan.predicates.state_ids[simple.compound]);
            return self.predicateMatches(predicate_id, node_index);
        }

        fn filterEligibleByTag(self: *Self, node_name: []const u8) void {
            @memcpy(self.tag_allowed, self.exec_plan.tag_dispatch.wildcard_state_words);
            const sig: execution_plan.TagSig = .{
                .key = tags.first8KeyWithMode(node_name, Doc.Options.non_destructive),
                .len = @intCast(node_name.len),
            };
            if (self.exec_plan.tag_dispatch.find(sig)) |entry| {
                for (self.exec_plan.tag_dispatch.stateUses(entry)) |use| {
                    self.tag_allowed[@intCast(use.word_index)] |= use.mask;
                }
            }
            for (self.eligible_words, self.tag_allowed) |*eligible, allowed| eligible.* &= allowed;
        }

        fn evaluateStates(self: *Self, node_index: IndexInt, matched: []u64) !void {
            if (self.exec_plan.simple_groups.len == 0) return self.evaluateStatesOnly(node_index, matched);

            for (self.eligible_words, 0..) |eligible_word, word_index| {
                var pending = eligible_word;
                while (pending != 0) {
                    const bit_index: usize = @intCast(@ctz(pending));
                    pending &= pending - 1;
                    const state_index = word_index * 64 + bit_index;
                    if (state_index >= self.exec_plan.state_count) continue;
                    const meta = self.exec_plan.states[state_index];
                    const predicate_id: usize = @intCast(meta.predicate);
                    const predicate_bit = @as(u64, 1) << @intCast(predicate_id % 64);
                    const predicate_word = predicate_id / 64;
                    if ((self.state_fanned_predicates[predicate_word] & predicate_bit) != 0) continue;
                    const local_match = try self.predicateMatches(predicate_id, node_index);
                    self.state_fanned_predicates[predicate_word] |= predicate_bit;
                    if (local_match) {
                        for (self.exec_plan.predicateStateUsesFor(predicate_id)) |use| {
                            if (comptime builtin.is_test) self.stats.predicate_state_word_fanouts += 1;
                            const word: usize = @intCast(use.word_index);
                            matched[word] |= self.eligible_words[word] & use.mask;
                        }
                    }
                }
            }
        }

        fn evaluateStatesOnly(self: *Self, node_index: IndexInt, matched: []u64) !void {
            if (self.usesDensePredicates()) {
                return switch (self.word_count) {
                    1 => self.evaluateDensePredicatesFixed(1, node_index, matched),
                    2 => self.evaluateDensePredicatesFixed(2, node_index, matched),
                    3 => self.evaluateDensePredicatesFixed(3, node_index, matched),
                    4 => self.evaluateDensePredicatesFixed(4, node_index, matched),
                    else => unreachable,
                };
            }

            const seen = self.seenWords();
            for (self.eligible_words, 0..) |eligible_word, word_index| {
                var pending = eligible_word;
                while (pending != 0) {
                    const bit_index: usize = @intCast(@ctz(pending));
                    pending &= pending - 1;
                    const state_index = word_index * 64 + bit_index;
                    if (state_index >= self.exec_plan.state_count) continue;
                    const meta = self.exec_plan.states[state_index];
                    const predicate_id: usize = @intCast(meta.predicate);
                    const predicate_bit = @as(u64, 1) << @intCast(predicate_id % 64);
                    const predicate_word = predicate_id / 64;
                    if ((seen[predicate_word] & predicate_bit) != 0) continue;

                    try self.markPredicateTouched(predicate_id);
                    seen[predicate_word] |= predicate_bit;
                    if (comptime builtin.is_test) self.stats.local_unique_predicate_evals += 1;
                    const representative: usize = @intCast(self.exec_plan.predicates.representatives[predicate_id]);
                    if (try matcher.matchesCompoundForward(
                        Doc,
                        self.doc,
                        self.selector,
                        self.selector.compounds[representative],
                        node_index,
                        &self.node_ctx,
                    )) {
                        for (self.exec_plan.predicateStateUsesFor(predicate_id)) |use| {
                            if (comptime builtin.is_test) self.stats.predicate_state_word_fanouts += 1;
                            const word: usize = @intCast(use.word_index);
                            matched[word] |= self.eligible_words[word] & use.mask;
                        }
                    }
                }
            }
        }

        fn evaluateDensePredicatesFixed(self: *Self, comptime word_count: usize, node_index: IndexInt, matched: []u64) !void {
            for (0..self.exec_plan.predicates.count) |predicate_id| {
                const predicate_mask = self.exec_plan.densePredicateStateMask(predicate_id);
                var applicable: u64 = 0;
                inline for (0..word_count) |i| applicable |= self.eligible_words[i] & predicate_mask[i];
                if (applicable == 0) continue;

                if (comptime builtin.is_test) self.stats.local_unique_predicate_evals += 1;
                const representative: usize = @intCast(self.exec_plan.predicates.representatives[predicate_id]);
                if (!try matcher.matchesCompoundForward(
                    Doc,
                    self.doc,
                    self.selector,
                    self.selector.compounds[representative],
                    node_index,
                    &self.node_ctx,
                )) continue;

                inline for (0..word_count) |i| {
                    if (comptime builtin.is_test) self.stats.predicate_state_word_fanouts += 1;
                    matched[i] |= self.eligible_words[i] & predicate_mask[i];
                }
            }
        }

        inline fn usesDensePredicates(self: *const Self) bool {
            return self.exec_plan.dense_predicate_state_masks.len != 0;
        }

        inline fn seenWords(self: *Self) []u64 {
            if (self.usesInlinePredicateReset()) return self.small_seen_predicates[0..self.predicate_word_count];
            return self.seen_predicates;
        }

        inline fn markPredicateTouched(self: *Self, predicate_id: usize) !void {
            if (!self.usesInlinePredicateReset()) try self.touched_predicates.append(self.allocator, predicate_id);
        }

        inline fn usesInlinePredicateReset(self: *const Self) bool {
            return self.exec_plan.simple_groups.len == 0 and self.predicate_word_count <= SmallPredicateWordLimit;
        }

        inline fn clearInlineSeen(self: *Self) void {
            switch (self.predicate_word_count) {
                0 => {},
                1 => self.small_seen_predicates[0] = 0,
                2 => {
                    self.small_seen_predicates[0] = 0;
                    self.small_seen_predicates[1] = 0;
                },
                3 => {
                    self.small_seen_predicates[0] = 0;
                    self.small_seen_predicates[1] = 0;
                    self.small_seen_predicates[2] = 0;
                },
                4 => {
                    self.small_seen_predicates[0] = 0;
                    self.small_seen_predicates[1] = 0;
                    self.small_seen_predicates[2] = 0;
                    self.small_seen_predicates[3] = 0;
                },
                else => unreachable,
            }
        }

        fn syncStack(self: *Self, idx: IndexInt) void {
            while (self.stack.items.len != 0 and idx > self.stack.items[self.stack.items.len - 1].subtree_end) _ = self.stack.pop();
        }

        inline fn ensureStateSlots(self: *Self, slots: usize) !void {
            const needed = try checkedStateStorageWords(slots, self.word_count);
            if (self.states.items.len >= needed) return;
            const old_len = self.states.items.len;
            if (needed > self.states.capacity) {
                @branchHint(.unlikely);
                try self.growStates(needed);
            }
            self.states.items.len = needed;
            @memset(self.states.items[old_len..], 0);
        }

        noinline fn growStates(self: *Self, needed: usize) !void {
            @branchHint(.cold);
            try self.states.ensureTotalCapacity(self.allocator, needed);
        }

        fn state(self: *Self, slot: usize, which: State) []u64 {
            const start = (slot * 4 + @intFromEnum(which)) * self.word_count;
            return self.states.items[start .. start + self.word_count];
        }

        fn setBit(words: []u64, index: usize) void {
            words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
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
            for (dst, src) |*d, value| d.* |= value;
        }

        fn andNotInto(dst: []u64, src: []const u64) void {
            for (dst, src) |*d, value| d.* &= ~value;
        }

        fn andInto(dst: []u64, src: []const u64) void {
            for (dst, src) |*d, value| d.* &= value;
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

test "dynamic state storage sizing rejects overflow" {
    try std.testing.expectError(error.OutOfMemory, checkedStateStorageWords(std.math.maxInt(usize), 2));
    try std.testing.expectEqual(@as(usize, 32), try checkedStateStorageWords(2, 4));
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
