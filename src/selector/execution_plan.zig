const std = @import("std");
const declaration_testing = @import("../testing.zig");
const ast = @import("ast.zig");
const common = @import("../common.zig");
const tags = @import("../html/tags.zig");
const predicate_plan = @import("predicate_plan.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

const IndexInt = common.IndexInt;

pub const Mask = enum(usize) {
    start_none,
    start_child,
    start_descendant,
    child_targets,
    descendant_targets,
    adjacent_targets,
    sibling_targets,
    final,
    continuation,
    scope_self,
    scope_lineage,
};

pub const MaskCount = @typeInfo(Mask).@"enum".fields.len;

pub const StatefulGroup = struct {
    compound_start: IndexInt,
    compound_len: IndexInt,
    state_start: usize,
};

pub const SimpleGroup = struct {
    compound: IndexInt,
};

pub const StateMeta = struct {
    compound: IndexInt,
    predicate: IndexInt,
    group_index: IndexInt,
    relative: IndexInt,
};

pub const TagSig = struct {
    key: u64,
    len: IndexInt,
};

pub const TagEntry = struct {
    sig: TagSig,
    state_use_start: usize,
    state_use_len: usize,
    simple_start: usize,
    simple_len: usize,
};

pub const TagDispatch = struct {
    wildcard_state_words: []u64 = &.{},
    wildcard_simple: []usize = &.{},
    entries: []TagEntry = &.{},
    state_uses: []predicate_plan.WordUse = &.{},
    simple_indices: []usize = &.{},

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.wildcard_state_words.len != 0) allocator.free(self.wildcard_state_words);
        if (self.wildcard_simple.len != 0) allocator.free(self.wildcard_simple);
        if (self.entries.len != 0) allocator.free(self.entries);
        if (self.state_uses.len != 0) allocator.free(self.state_uses);
        if (self.simple_indices.len != 0) allocator.free(self.simple_indices);
        self.* = .{};
    }

    pub fn find(self: *const @This(), sig: TagSig) ?*const TagEntry {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const item = &self.entries[mid];
            if (tagSigLess(item.sig, sig)) {
                lo = mid + 1;
            } else if (tagSigLess(sig, item.sig)) {
                hi = mid;
            } else {
                return item;
            }
        }
        return null;
    }

    pub fn stateUses(self: *const @This(), entry: *const TagEntry) []const predicate_plan.WordUse {
        return self.state_uses[entry.state_use_start .. entry.state_use_start + entry.state_use_len];
    }

    pub fn simpleIndices(self: *const @This(), entry: *const TagEntry) []const usize {
        return self.simple_indices[entry.simple_start .. entry.simple_start + entry.simple_len];
    }
};

pub const Plan = struct {
    predicates: predicate_plan.Plan = .{},
    stateful_groups: []StatefulGroup = &.{},
    simple_groups: []SimpleGroup = &.{},
    states: []StateMeta = &.{},
    masks: []u64 = &.{},
    predicate_state_ranges: []predicate_plan.UseRange = &.{},
    predicate_state_uses: []predicate_plan.WordUse = &.{},
    dense_predicate_state_masks: []u64 = &.{},
    tag_dispatch: TagDispatch = .{},
    state_count: usize = 0,
    word_count: usize = 0,
    needs_child_position: bool = false,
    has_tag_constraints: bool = false,
    filter_state_tags: bool = false,

    pub fn init(allocator: std.mem.Allocator, selector: ast.Selector) !@This() {
        var out: @This() = .{};
        errdefer out.deinit(allocator);
        out.predicates = try predicate_plan.Plan.init(allocator, selector);

        var stateful_count: usize = 0;
        var simple_count: usize = 0;
        for (selector.groups) |group| {
            if (group.compound_len == 0) continue;
            if (group.compound_len == 1) {
                simple_count += 1;
            } else {
                stateful_count += 1;
                out.state_count = std.math.add(usize, out.state_count, @intCast(group.compound_len)) catch return error.OutOfMemory;
            }
            inspectFeatures(selector, group, &out);
        }
        out.word_count = out.state_count / 64 + @intFromBool(out.state_count % 64 != 0);
        out.stateful_groups = try allocator.alloc(StatefulGroup, stateful_count);
        out.simple_groups = try allocator.alloc(SimpleGroup, simple_count);
        out.states = try allocator.alloc(StateMeta, out.state_count);
        if (out.word_count != 0) {
            const mask_words = std.math.mul(usize, out.word_count, MaskCount) catch return error.OutOfMemory;
            out.masks = try allocator.alloc(u64, mask_words);
            @memset(out.masks, 0);
        }
        out.compileGroups(selector);
        try out.compilePredicateStateUses(allocator);
        try out.compileTagDispatch(allocator, selector);
        out.filter_state_tags = out.shouldFilterStateTags();
        return out;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.predicates.deinit(allocator);
        if (self.stateful_groups.len != 0) allocator.free(self.stateful_groups);
        if (self.simple_groups.len != 0) allocator.free(self.simple_groups);
        if (self.states.len != 0) allocator.free(self.states);
        if (self.masks.len != 0) allocator.free(self.masks);
        if (self.predicate_state_ranges.len != 0) allocator.free(self.predicate_state_ranges);
        if (self.predicate_state_uses.len != 0) allocator.free(self.predicate_state_uses);
        if (self.dense_predicate_state_masks.len != 0) allocator.free(self.dense_predicate_state_masks);
        self.tag_dispatch.deinit(allocator);
        self.* = .{};
    }

    pub fn mask(self: *const @This(), which: Mask) []const u64 {
        const start = @intFromEnum(which) * self.word_count;
        return self.masks[start .. start + self.word_count];
    }

    pub fn maskMut(self: *@This(), which: Mask) []u64 {
        const start = @intFromEnum(which) * self.word_count;
        return self.masks[start .. start + self.word_count];
    }

    pub fn predicateStateUsesFor(self: *const @This(), predicate_id: usize) []const predicate_plan.WordUse {
        const range = self.predicate_state_ranges[predicate_id];
        return self.predicate_state_uses[range.start .. range.start + range.len];
    }

    pub fn densePredicateStateMask(self: *const @This(), predicate_id: usize) []const u64 {
        std.debug.assert(self.dense_predicate_state_masks.len != 0);
        const start = predicate_id * self.word_count;
        return self.dense_predicate_state_masks[start .. start + self.word_count];
    }

    fn shouldFilterStateTags(self: *const @This()) bool {
        if (self.state_count == 0 or !self.has_tag_constraints) return false;

        // A single tag bucket covering every state is not a useful prefilter:
        // matching nodes pay a tag-signature lookup plus a full-width mask pass
        // only to preserve every eligible bit, while mismatching nodes would
        // have needed just one interned local tag predicate evaluation. Keep
        // tag filtering for mixed/wildcard or multi-tag state machines where it
        // can actually reduce the eligible state set.
        if (self.tag_dispatch.entries.len != 1) return true;
        for (self.tag_dispatch.wildcard_state_words) |word| {
            if (word != 0) return true;
        }
        return false;
    }

    pub fn stateIndexForCompound(self: *const @This(), absolute: usize) ?usize {
        // Stateful groups are emitted in AST order, so compound ranges are
        // monotone and can be located without a selector-list linear scan.
        var lo: usize = 0;
        var hi: usize = self.stateful_groups.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const group = self.stateful_groups[mid];
            const start: usize = @intCast(group.compound_start);
            const len: usize = @intCast(group.compound_len);
            if (absolute < start) {
                hi = mid;
            } else if (absolute >= start + len) {
                lo = mid + 1;
            } else {
                return group.state_start + (absolute - start);
            }
        }
        return null;
    }

    fn compileGroups(self: *@This(), selector: ast.Selector) void {
        var stateful_index: usize = 0;
        var simple_index: usize = 0;
        var next_state: usize = 0;

        for (selector.groups, 0..) |group, group_index| {
            if (group.compound_len == 0) continue;
            if (group.compound_len == 1) {
                self.simple_groups[simple_index] = .{
                    .compound = group.compound_start,
                };
                simple_index += 1;
                continue;
            }

            const state_start = next_state;
            var rel: IndexInt = 0;
            while (rel < group.compound_len) : (rel += 1) {
                const absolute = group.compound_start + rel;
                const state = next_state;
                next_state += 1;
                self.states[state] = .{
                    .compound = absolute,
                    .predicate = self.predicates.state_ids[absolute],
                    .group_index = @intCast(group_index),
                    .relative = rel,
                };
                if (rel + 1 < group.compound_len) setBit(self.maskMut(.continuation), state);
                if (rel == group.compound_len - 1) setBit(self.maskMut(.final), state);

                const comp = selector.compounds[absolute];
                if (rel == 0) {
                    switch (comp.combinator) {
                        .none => setBit(self.maskMut(.start_none), state),
                        .child => setBit(self.maskMut(.start_child), state),
                        .descendant => setBit(self.maskMut(.start_descendant), state),
                        .adjacent, .sibling => {},
                    }
                } else switch (comp.combinator) {
                    .child => setBit(self.maskMut(.child_targets), state),
                    .descendant => setBit(self.maskMut(.descendant_targets), state),
                    .adjacent => setBit(self.maskMut(.adjacent_targets), state),
                    .sibling => setBit(self.maskMut(.sibling_targets), state),
                    .none => {},
                }
            }

            self.stateful_groups[stateful_index] = .{
                .compound_start = group.compound_start,
                .compound_len = group.compound_len,
                .state_start = state_start,
            };
            stateful_index += 1;
        }
        std.debug.assert(next_state == self.state_count);
        shiftRightUnion(self.maskMut(.scope_self), self.mask(.child_targets), self.mask(.descendant_targets));
        shiftRightUnion(self.maskMut(.scope_lineage), &.{}, self.mask(.descendant_targets));
    }

    fn compilePredicateStateUses(self: *@This(), allocator: std.mem.Allocator) !void {
        const predicate_count = self.predicates.count;
        self.predicate_state_ranges = try allocator.alloc(predicate_plan.UseRange, predicate_count);
        @memset(self.predicate_state_ranges, .{ .start = 0, .len = 0 });
        if (predicate_count == 0 or self.state_count == 0) return;

        const counts = try allocator.alloc(usize, predicate_count);
        defer allocator.free(counts);
        @memset(counts, 0);
        const last_word = try allocator.alloc(usize, predicate_count);
        defer allocator.free(last_word);
        @memset(last_word, std.math.maxInt(usize));

        for (self.states, 0..) |meta, state| {
            const predicate_id: usize = @intCast(self.predicates.state_ids[meta.compound]);
            const word = state / 64;
            if (last_word[predicate_id] != word) {
                last_word[predicate_id] = word;
                counts[predicate_id] += 1;
            }
        }

        var total: usize = 0;
        for (counts, 0..) |count, predicate_id| {
            self.predicate_state_ranges[predicate_id] = .{ .start = total, .len = count };
            total = std.math.add(usize, total, count) catch return error.OutOfMemory;
        }
        std.debug.assert(total <= self.state_count);
        self.predicate_state_uses = try allocator.alloc(predicate_plan.WordUse, total);

        const cursors = try allocator.alloc(usize, predicate_count);
        defer allocator.free(cursors);
        for (self.predicate_state_ranges, 0..) |range, predicate_id| cursors[predicate_id] = range.start;
        @memset(last_word, std.math.maxInt(usize));

        for (self.states, 0..) |meta, state| {
            const predicate_id: usize = @intCast(self.predicates.state_ids[meta.compound]);
            const word = state / 64;
            const bit_mask = @as(u64, 1) << @intCast(state % 64);
            if (last_word[predicate_id] != word) {
                const cursor = cursors[predicate_id];
                self.predicate_state_uses[cursor] = .{ .word_index = @intCast(word), .mask = bit_mask };
                cursors[predicate_id] += 1;
                last_word[predicate_id] = word;
            } else {
                self.predicate_state_uses[cursors[predicate_id] - 1].mask |= bit_mask;
            }
        }
        std.debug.assert(self.predicate_state_uses.len <= self.state_count);

        // Dense predicate masks are a hot-path specialization, not the general
        // representation. Build them only for state-only machines of at most
        // four words when the dense table is no larger than the state count.
        // This captures repeated chains such as `div div ...` without bringing
        // back the O(predicate_count * state_width) blow-up for large lists of
        // distinct predicates.
        if (self.simple_groups.len == 0 and self.word_count <= 4) {
            const dense_words = std.math.mul(usize, predicate_count, self.word_count) catch return error.OutOfMemory;
            if (dense_words != 0 and dense_words <= self.state_count) {
                self.dense_predicate_state_masks = try allocator.alloc(u64, dense_words);
                @memset(self.dense_predicate_state_masks, 0);
                for (self.states, 0..) |meta, state| {
                    const predicate_id: usize = @intCast(meta.predicate);
                    self.dense_predicate_state_masks[predicate_id * self.word_count + state / 64] |=
                        @as(u64, 1) << @intCast(state % 64);
                }
            }
        }
    }

    fn compileTagDispatch(self: *@This(), allocator: std.mem.Allocator, selector: ast.Selector) !void {
        if (!self.has_tag_constraints) return;
        if (self.word_count != 0) {
            self.tag_dispatch.wildcard_state_words = try allocator.alloc(u64, self.word_count);
            @memset(self.tag_dispatch.wildcard_state_words, 0);
        }

        var entry_map: std.AutoHashMapUnmanaged(TagSig, usize) = .empty;
        defer entry_map.deinit(allocator);
        var temp_entries = std.ArrayList(TagEntry).empty;
        defer temp_entries.deinit(allocator);
        var state_counts = std.ArrayList(usize).empty;
        defer state_counts.deinit(allocator);
        var simple_counts = std.ArrayList(usize).empty;
        defer simple_counts.deinit(allocator);
        var last_words = std.ArrayList(usize).empty;
        defer last_words.deinit(allocator);
        var wildcard_simple_count: usize = 0;

        for (self.states, 0..) |meta, state| {
            const comp = selector.compounds[meta.compound];
            if (!comp.hasTag()) {
                setBit(self.tag_dispatch.wildcard_state_words, state);
                continue;
            }
            const sig = selectorTagSig(selector, comp);
            const entry_id = try getOrCreateTagEntry(allocator, &entry_map, &temp_entries, &state_counts, &simple_counts, &last_words, sig);
            const word = state / 64;
            if (last_words.items[entry_id] != word) {
                last_words.items[entry_id] = word;
                state_counts.items[entry_id] += 1;
            }
        }

        for (self.simple_groups) |simple| {
            const comp = selector.compounds[simple.compound];
            if (!comp.hasTag()) {
                wildcard_simple_count += 1;
                continue;
            }
            const sig = selectorTagSig(selector, comp);
            const entry_id = try getOrCreateTagEntry(allocator, &entry_map, &temp_entries, &state_counts, &simple_counts, &last_words, sig);
            simple_counts.items[entry_id] += 1;
        }

        self.tag_dispatch.wildcard_simple = try allocator.alloc(usize, wildcard_simple_count);
        self.tag_dispatch.entries = try allocator.alloc(TagEntry, temp_entries.items.len);

        var total_state_uses: usize = 0;
        var total_simple: usize = 0;
        for (temp_entries.items, 0..) |entry, i| {
            self.tag_dispatch.entries[i] = .{
                .sig = entry.sig,
                .state_use_start = total_state_uses,
                .state_use_len = state_counts.items[i],
                .simple_start = total_simple,
                .simple_len = simple_counts.items[i],
            };
            total_state_uses = std.math.add(usize, total_state_uses, state_counts.items[i]) catch return error.OutOfMemory;
            total_simple = std.math.add(usize, total_simple, simple_counts.items[i]) catch return error.OutOfMemory;
        }
        self.tag_dispatch.state_uses = try allocator.alloc(predicate_plan.WordUse, total_state_uses);
        self.tag_dispatch.simple_indices = try allocator.alloc(usize, total_simple);

        const state_cursors = try allocator.alloc(usize, temp_entries.items.len);
        defer allocator.free(state_cursors);
        const simple_cursors = try allocator.alloc(usize, temp_entries.items.len);
        defer allocator.free(simple_cursors);
        const build_last_words = try allocator.alloc(usize, temp_entries.items.len);
        defer allocator.free(build_last_words);
        for (self.tag_dispatch.entries, 0..) |entry, i| {
            state_cursors[i] = entry.state_use_start;
            simple_cursors[i] = entry.simple_start;
        }
        @memset(build_last_words, std.math.maxInt(usize));

        var wildcard_cursor: usize = 0;
        for (self.simple_groups, 0..) |simple, simple_index| {
            const comp = selector.compounds[simple.compound];
            if (!comp.hasTag()) {
                self.tag_dispatch.wildcard_simple[wildcard_cursor] = simple_index;
                wildcard_cursor += 1;
                continue;
            }
            const entry_id = entry_map.get(selectorTagSig(selector, comp)).?;
            self.tag_dispatch.simple_indices[simple_cursors[entry_id]] = simple_index;
            simple_cursors[entry_id] += 1;
        }

        for (self.states, 0..) |meta, state| {
            const comp = selector.compounds[meta.compound];
            if (!comp.hasTag()) continue;
            const entry_id = entry_map.get(selectorTagSig(selector, comp)).?;
            const word = state / 64;
            const state_mask = @as(u64, 1) << @intCast(state % 64);
            if (build_last_words[entry_id] != word) {
                const cursor = state_cursors[entry_id];
                self.tag_dispatch.state_uses[cursor] = .{ .word_index = @intCast(word), .mask = state_mask };
                state_cursors[entry_id] += 1;
                build_last_words[entry_id] = word;
            } else {
                self.tag_dispatch.state_uses[state_cursors[entry_id] - 1].mask |= state_mask;
            }
        }

        // Entry ranges remain valid after sorting because they point into
        // independent use/index arrays. Runtime lookup is binary search, not a
        // hash-table operation in the node hot loop.
        std.mem.sort(TagEntry, self.tag_dispatch.entries, {}, struct {
            fn lessThan(_: void, a: TagEntry, b: TagEntry) bool {
                return tagSigLess(a.sig, b.sig);
            }
        }.lessThan);
    }
};

fn selectorTagSig(selector: ast.Selector, comp: ast.Compound) TagSig {
    const name = comp.tag.slice(selector.source);
    return .{
        .key = if (comp.tag_key != 0) comp.tag_key else tags.first8KeyWithMode(name, false),
        .len = @intCast(name.len),
    };
}

fn tagSigLess(a: TagSig, b: TagSig) bool {
    return a.key < b.key or (a.key == b.key and a.len < b.len);
}

fn getOrCreateTagEntry(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(TagSig, usize),
    entries: *std.ArrayList(TagEntry),
    state_counts: *std.ArrayList(usize),
    simple_counts: *std.ArrayList(usize),
    last_words: *std.ArrayList(usize),
    sig: TagSig,
) !usize {
    if (map.get(sig)) |entry_id| return entry_id;
    const entry_id = entries.items.len;
    try entries.append(allocator, .{ .sig = sig, .state_use_start = 0, .state_use_len = 0, .simple_start = 0, .simple_len = 0 });
    errdefer entries.items.len -= 1;
    try state_counts.append(allocator, 0);
    errdefer state_counts.items.len -= 1;
    try simple_counts.append(allocator, 0);
    errdefer simple_counts.items.len -= 1;
    try last_words.append(allocator, std.math.maxInt(usize));
    errdefer last_words.items.len -= 1;
    try map.put(allocator, sig, entry_id);
    return entry_id;
}

fn inspectFeatures(selector: ast.Selector, group: ast.Group, plan: *Plan) void {
    var rel: IndexInt = 0;
    while (rel < group.compound_len) : (rel += 1) {
        const comp = selector.compounds[group.compound_start + rel];
        plan.has_tag_constraints = plan.has_tag_constraints or comp.hasTag();
        var i: IndexInt = 0;
        while (i < comp.pseudo_len) : (i += 1) {
            switch (selector.pseudos[comp.pseudo_start + i].kind) {
                .first_child, .nth_child => plan.needs_child_position = true,
                .last_child => {},
            }
        }
    }
}

fn setBit(words: []u64, index: usize) void {
    words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
}

fn shiftRightUnion(dst: []u64, a: []const u64, b: []const u64) void {
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

test "dense predicate masks are limited to small reused state-only plans" {
    const alloc = std.testing.allocator;

    var repeated = try ast.Selector.compileRuntime(alloc, "div div div div div div div div div div");
    defer repeated.deinit(alloc);
    var repeated_plan = try Plan.init(alloc, repeated);
    defer repeated_plan.deinit(alloc);
    try std.testing.expect(repeated_plan.dense_predicate_state_masks.len != 0);
    try std.testing.expect(!repeated_plan.filter_state_tags);

    var mixed_tags = try ast.Selector.compileRuntime(alloc, "div span div span div span div span");
    defer mixed_tags.deinit(alloc);
    var mixed_tag_plan = try Plan.init(alloc, mixed_tags);
    defer mixed_tag_plan.deinit(alloc);
    try std.testing.expect(mixed_tag_plan.filter_state_tags);

    var unique_source = std.ArrayList(u8).empty;
    defer unique_source.deinit(alloc);
    for (0..80) |i| {
        if (i != 0) try unique_source.appendSlice(alloc, " > ");
        var buf: [24]u8 = undefined;
        try unique_source.appendSlice(alloc, try std.fmt.bufPrint(&buf, ".c{}", .{i}));
    }
    var unique = try ast.Selector.compileRuntime(alloc, unique_source.items);
    defer unique.deinit(alloc);
    var unique_plan = try Plan.init(alloc, unique);
    defer unique_plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), unique_plan.dense_predicate_state_masks.len);
}

test "compact plan excludes one-compound groups from persistent state" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..1000) |i| {
        if (i != 0) try source.appendSlice(alloc, ",");
        var name_buf: [24]u8 = undefined;
        try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, ".a{}", .{i}));
    }
    try source.appendSlice(alloc, ",div div");

    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);
    var plan = try Plan.init(alloc, selector);
    defer plan.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1002), selector.compounds.len);
    try std.testing.expectEqual(@as(usize, 2), plan.state_count);
    try std.testing.expectEqual(@as(usize, 1), plan.word_count);
    try std.testing.expectEqual(@as(usize, 1000), plan.simple_groups.len);
}

test "execution plan cleans up every partial allocation failure" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..80) |i| {
        if (i != 0) try source.appendSlice(alloc, ",");
        var name_buf: [24]u8 = undefined;
        if (i % 2 == 0) {
            try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, "x{}", .{i}));
        } else {
            try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, ".c{}", .{i}));
        }
    }
    try source.appendSlice(alloc, ",div");
    for (1..65) |_| try source.appendSlice(alloc, " > div");

    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);
    const Case = struct {
        fn run(allocator: std.mem.Allocator, sel: ast.Selector) !void {
            var plan = try Plan.init(allocator, sel);
            defer plan.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(alloc, Case.run, .{selector});
}
