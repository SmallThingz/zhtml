const std = @import("std");
const builtin = @import("builtin");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const ast = @import("ast.zig");
const predicate_plan = @import("predicate_plan.zig");
const execution_plan = @import("execution_plan.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr = @import("../html/attr.zig");
const common = @import("../common.zig");

// SAFETY: Selector AST indices are trusted to be internally consistent
// (group/compound/predicate ranges). Document node indices are validated
// before use; debug asserts guard scope bounds in key entry points.

const IndexInt = common.IndexInt;
const InvalidIndex: IndexInt = common.InvalidIndex;
const MaxCollectedAttrs: usize = 24;
const matchesScopeAnchor = common.matchesScopeAnchor;
const parentElement = common.parentElement;
const prevElementSibling = common.prevElementSibling;
const nextElementSibling = common.nextElementSibling;

inline fn bitWordCount(count: usize) usize {
    return count / 64 + @intFromBool(count % 64 != 0);
}

fn checkedProduct(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.OutOfMemory;
}

fn tagMatches(comptime Doc: type, selector_source: []const u8, comp: ast.Compound, node_name: []const u8) bool {
    const tag = comp.tag.slice(selector_source);
    const tag_key: u64 = if (comp.tag_key != 0) comp.tag_key else tags.first8KeyWithMode(tag, false);
    const node_key = tags.first8KeyWithMode(node_name, Doc.Options.non_destructive);
    return tags.equalByLenAndKeyIgnoreCase(node_name, node_key, tag, tag_key);
}

pub fn evalAttrOp(raw: []const u8, value: []const u8, op: ast.AttrOp, case: ast.AttrCase) bool {
    // Selectors 4: empty substring operands for ^=, $= and *= match nothing.
    // std.mem/std.ascii helpers intentionally consider the empty string a
    // prefix/suffix/substring, so reject it before either case mode.
    if (value.len == 0 and (op == .prefix or op == .suffix or op == .contains)) return false;
    if (case == .insensitive_ascii) return evalAttrOpIgnoreCase(raw, value, op);
    return switch (op) {
        .exists => true,
        .eq => std.mem.eql(u8, raw, value),
        .prefix => std.mem.startsWith(u8, raw, value),
        .suffix => std.mem.endsWith(u8, raw, value),
        .contains => std.mem.indexOf(u8, raw, value) != null,
        .includes => tables.tokenIncludesAsciiWhitespace(raw, value),
        .dash_match => std.mem.eql(u8, raw, value) or (raw.len > value.len and std.mem.startsWith(u8, raw, value) and raw[value.len] == '-'),
    };
}

fn evalAttrOpIgnoreCase(raw: []const u8, value: []const u8, op: ast.AttrOp) bool {
    return switch (op) {
        .exists => true,
        .eq => std.ascii.eqlIgnoreCase(raw, value),
        .prefix => std.ascii.startsWithIgnoreCase(raw, value),
        .suffix => std.ascii.endsWithIgnoreCase(raw, value),
        .contains => std.ascii.indexOfIgnoreCase(raw, value) != null,
        .includes => tokenIncludesIgnoreCaseAscii(raw, value),
        .dash_match => std.ascii.eqlIgnoreCase(raw, value) or (raw.len > value.len and std.ascii.startsWithIgnoreCase(raw, value) and raw[value.len] == '-'),
    };
}

fn tokenIncludesIgnoreCaseAscii(raw: []const u8, value: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and tables.WhitespaceTable[raw[i]]) : (i += 1) {}
        if (i >= raw.len) return false;

        const start = i;
        while (i < raw.len and !tables.WhitespaceTable[raw[i]]) : (i += 1) {}
        if (std.ascii.eqlIgnoreCase(raw[start..i], value)) return true;
    }
    return false;
}

/// Returns whether `node_index` matches any selector group within scope.
pub fn matchesSelectorAt(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, node_index: IndexInt, scope_root: IndexInt) !bool {
    if (node_index >= doc.nodes.len) return false;
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.len) return false;
    var workspace = MatchWorkspace.init(doc.allocator);
    defer workspace.deinit();
    return try matchesSelectorAtWithWorkspace(Doc, doc, selector, node_index, scope_root, &workspace);
}

/// Prepared-program equivalent of `matchesSelectorAt`. The immutable execution
/// plan is borrowed; only mutable RTL scratch is allocated for this call.
pub fn matchesSelectorAtPrepared(
    comptime Doc: type,
    noalias doc: *const Doc,
    selector: ast.Selector,
    plan: *const execution_plan.Plan,
    node_index: IndexInt,
    scope_root: IndexInt,
) !bool {
    if (node_index >= doc.nodes.len) return false;
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.len) return false;
    var workspace = MatchWorkspace.initPrepared(doc.allocator, selector, plan);
    defer workspace.deinit();
    return try matchesSelectorAtWithWorkspace(Doc, doc, selector, node_index, scope_root, &workspace);
}

pub fn matchesSelectorAtWithWorkspace(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, node_index: IndexInt, scope_root: IndexInt, workspace: *MatchWorkspace) !bool {
    if (node_index >= doc.nodes.len) return false;
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.len) return false;
    if (!doc.nodes[node_index].isElement(node_index)) return false;
    workspace.prepareTopology(@intFromPtr(doc), doc.generation);

    var reverse_needed = false;
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        if (!groupRightmostCouldMatch(Doc, doc, selector, group, node_index)) continue;

        const rightmost = group.compound_len - 1;
        if (!groupHasExistential(selector, group, rightmost)) {
            if (try matchDeterministicGroup(Doc, doc, selector, group, rightmost, node_index, scope_root, &workspace.node_ctx)) return true;
        } else {
            reverse_needed = true;
        }
    }
    if (!reverse_needed) return false;

    // Build reverse state only when at least one existential group survives the
    // candidate-local rightmost tag filter. Deterministic groups above never
    // pay reverse-plan setup costs.
    try workspace.ensureReversePlan(selector);
    @memset(workspace.reverse_seed, 0);
    var stateful_cursor: usize = 0;
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        if (group.compound_len == 1) continue;
        const group_plan = workspace.execution_plan.stateful_groups[stateful_cursor];
        stateful_cursor += 1;
        const rightmost = group.compound_len - 1;
        if (!groupHasExistential(selector, group, rightmost)) continue;
        if (!groupRightmostCouldMatch(Doc, doc, selector, group, node_index)) continue;
        setWordBit(workspace.reverse_seed, group_plan.state_start + @as(usize, @intCast(group.compound_len)) - 1);
    }
    return matchReverseAutomaton(Doc, doc, selector, node_index, scope_root, workspace.reverse_seed, workspace);
}

fn groupRightmostCouldMatch(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, node_index: IndexInt) bool {
    if (group.compound_len == 0) return false;
    const rightmost: usize = @intCast(group.compound_start + group.compound_len - 1);
    const comp = selector.compounds[rightmost];
    if (!comp.hasTag()) return true;
    return tagMatches(Doc, selector.source, comp, doc.nodes[node_index].name_or_text.slice(doc.source));
}

/// Matches one left-to-right group prefix at a specific node using the RTL engine.
/// Used once when seeding a scoped forward query from ancestors outside its scan.
pub fn matchesPrefixAt(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, group: ast.Group, prefix_len: usize, node_index: IndexInt, workspace: *MatchWorkspace) !bool {
    if (prefix_len == 0 or prefix_len > group.compound_len or node_index >= doc.nodes.len) return false;
    workspace.prepareTopology(@intFromPtr(doc), doc.generation);
    const partial: ast.Group = .{
        .compound_start = group.compound_start,
        .compound_len = @intCast(prefix_len),
    };
    const rightmost: IndexInt = @intCast(prefix_len - 1);
    if (!groupHasExistential(selector, partial, rightmost)) {
        return matchDeterministicGroup(Doc, doc, selector, partial, rightmost, node_index, InvalidIndex, &workspace.node_ctx);
    }
    try workspace.ensureReversePlan(selector);
    @memset(workspace.reverse_seed, 0);
    const absolute = @as(usize, @intCast(group.compound_start)) + prefix_len - 1;
    setWordBit(workspace.reverse_seed, workspace.execution_plan.stateIndexForCompound(absolute).?);
    return matchReverseAutomaton(Doc, doc, selector, node_index, InvalidIndex, workspace.reverse_seed, workspace);
}

const ReverseInlineMapCapacity = 256;
const ReverseInlineMapMaxLoad = ReverseInlineMapCapacity * 7 / 10;

const ReverseNodeMap = struct {
    keys: [ReverseInlineMapCapacity]IndexInt = [_]IndexInt{InvalidIndex} ** ReverseInlineMapCapacity,
    values: [ReverseInlineMapCapacity]IndexInt = undefined,
    count: usize = 0,
    spill: std.AutoHashMapUnmanaged(IndexInt, IndexInt) = .empty,
    spilled: bool = false,

    fn reset(self: *@This()) void {
        @memset(&self.keys, InvalidIndex);
        self.count = 0;
        if (self.spilled) {
            self.spill.clearRetainingCapacity();
            self.spilled = false;
        }
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.spill.deinit(allocator);
        self.* = .{};
    }

    fn hash(node: IndexInt) usize {
        var x: u64 = @intCast(node);
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        x *%= 0xc4ceb9fe1a85ec53;
        x ^= x >> 33;
        return @truncate(x);
    }

    fn get(self: *const @This(), node: IndexInt) ?usize {
        if (self.spilled) return if (self.spill.get(node)) |value| @intCast(value) else null;
        var slot = hash(node) & (ReverseInlineMapCapacity - 1);
        var probes: usize = 0;
        while (probes < ReverseInlineMapCapacity) : (probes += 1) {
            const key = self.keys[slot];
            if (key == InvalidIndex) return null;
            if (key == node) return @intCast(self.values[slot]);
            slot = (slot + 1) & (ReverseInlineMapCapacity - 1);
        }
        return null;
    }

    fn put(self: *@This(), allocator: std.mem.Allocator, node: IndexInt, value: usize) !void {
        std.debug.assert(value < std.math.maxInt(IndexInt));
        const stored_value: IndexInt = @intCast(value);
        if (self.spilled) {
            try self.spill.put(allocator, node, stored_value);
            return;
        }
        if (self.count >= ReverseInlineMapMaxLoad) {
            try self.spillInline(allocator);
            try self.spill.put(allocator, node, stored_value);
            return;
        }
        var slot = hash(node) & (ReverseInlineMapCapacity - 1);
        while (self.keys[slot] != InvalidIndex) {
            std.debug.assert(self.keys[slot] != node);
            slot = (slot + 1) & (ReverseInlineMapCapacity - 1);
        }
        self.keys[slot] = node;
        self.values[slot] = stored_value;
        self.count += 1;
    }

    fn spillInline(self: *@This(), allocator: std.mem.Allocator) !void {
        self.spill.clearRetainingCapacity();
        try self.spill.ensureTotalCapacity(allocator, @intCast(self.count + 16));
        for (self.keys, self.values) |key, value| {
            if (key == InvalidIndex) continue;
            self.spill.putAssumeCapacity(key, value);
        }
        self.spilled = true;
    }
};

const ReverseQueue = struct {
    const BucketCount = 65;
    buckets: [BucketCount]std.ArrayListUnmanaged(IndexInt) = [_]std.ArrayListUnmanaged(IndexInt){.empty} ** BucketCount,
    last_key: u64 = 0,
    len: usize = 0,

    fn keyFor(node: IndexInt) u64 {
        return @as(u64, std.math.maxInt(IndexInt)) - @as(u64, @intCast(node));
    }

    fn bucketIndex(key: u64, last_key: u64) usize {
        if (key == last_key) return 0;
        const diff = key ^ last_key;
        return @intCast(64 - @clz(diff));
    }

    fn reset(self: *@This()) void {
        for (&self.buckets) |*bucket| bucket.clearRetainingCapacity();
        self.last_key = 0;
        self.len = 0;
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (&self.buckets) |*bucket| bucket.deinit(allocator);
        self.* = .{};
    }

    fn push(self: *@This(), allocator: std.mem.Allocator, node: IndexInt) !void {
        const key = keyFor(node);
        std.debug.assert(key >= self.last_key);
        try self.buckets[bucketIndex(key, self.last_key)].append(allocator, node);
        self.len += 1;
    }

    fn pop(self: *@This(), allocator: std.mem.Allocator) !?IndexInt {
        if (self.len == 0) return null;
        if (self.buckets[0].items.len == 0) {
            var bucket_index: usize = 1;
            while (bucket_index < BucketCount and self.buckets[bucket_index].items.len == 0) : (bucket_index += 1) {}
            std.debug.assert(bucket_index < BucketCount);
            const old_items = self.buckets[bucket_index].items;
            var new_last = keyFor(old_items[0]);
            for (old_items[1..]) |node| new_last = @min(new_last, keyFor(node));
            self.last_key = new_last;
            self.buckets[bucket_index].items.len = 0;
            for (old_items) |node| {
                const new_bucket = bucketIndex(keyFor(node), self.last_key);
                std.debug.assert(new_bucket < bucket_index);
                try self.buckets[new_bucket].append(allocator, node);
            }
        }
        const node = self.buckets[0].pop().?;
        self.len -= 1;
        return node;
    }
};

const ReverseCellMeta = struct {
    node: IndexInt,
    scheduled: bool = false,
    processed: bool = false,
};

pub const MatchWorkspace = struct {
    allocator: std.mem.Allocator,
    topology_prev: std.AutoHashMapUnmanaged(IndexInt, IndexInt) = .empty,
    execution_plan: execution_plan.Plan = .{},
    owns_execution_plan: bool = true,
    node_ctx: NodeContext = .{},
    reverse_seed: []u64 = &.{},
    reverse_current: []u64 = &.{},
    reverse_local: []u64 = &.{},
    reverse_seen_predicates: []u64 = &.{},
    reverse_touched_predicates: std.ArrayListUnmanaged(usize) = .empty,
    reverse_node_map: ReverseNodeMap = .{},
    reverse_queue: ReverseQueue = .{},
    reverse_cell_meta: std.ArrayListUnmanaged(ReverseCellMeta) = .empty,
    reverse_cells: std.ArrayListUnmanaged(u64) = .empty,
    reverse_word_count: usize = 0,
    reverse_scratch_ready: bool = false,
    stats: if (builtin.is_test) MatchStats else void = if (builtin.is_test) .{} else {},
    topology_doc: usize = 0,
    topology_generation: u64 = 0,
    reverse_selector_id: u64 = 0,
    reverse_source: usize = 0,
    reverse_compounds: usize = 0,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn initPrepared(allocator: std.mem.Allocator, selector: ast.Selector, plan: *const execution_plan.Plan) @This() {
        var self = init(allocator);
        self.execution_plan = plan.*;
        self.owns_execution_plan = false;
        self.setReverseSelectorIdentity(selector);
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.topology_prev.deinit(self.allocator);
        self.topology_prev = .empty;
        if (self.owns_execution_plan) self.execution_plan.deinit(self.allocator);
        self.execution_plan = .{};
        self.node_ctx.deinit();
        if (self.reverse_seed.len != 0) self.allocator.free(self.reverse_seed);
        self.reverse_seed = &.{};
        if (self.reverse_current.len != 0) self.allocator.free(self.reverse_current);
        self.reverse_current = &.{};
        if (self.reverse_local.len != 0) self.allocator.free(self.reverse_local);
        self.reverse_local = &.{};
        if (self.reverse_seen_predicates.len != 0) self.allocator.free(self.reverse_seen_predicates);
        self.reverse_seen_predicates = &.{};
        self.reverse_touched_predicates.deinit(self.allocator);
        self.reverse_touched_predicates = .empty;
        self.reverse_node_map.deinit(self.allocator);
        self.reverse_queue.deinit(self.allocator);
        self.reverse_cell_meta.deinit(self.allocator);
        self.reverse_cell_meta = .empty;
        self.reverse_cells.deinit(self.allocator);
        self.reverse_cells = .empty;
    }

    fn prepareTopology(self: *@This(), doc_id: usize, generation: u64) void {
        if (self.topology_doc == doc_id and self.topology_generation == generation) return;
        self.topology_doc = doc_id;
        self.topology_generation = generation;
        self.topology_prev.clearRetainingCapacity();
    }

    fn ensureReversePlan(self: *@This(), selector: ast.Selector) !void {
        const source_id = @intFromPtr(selector.source.ptr);
        const compounds_id = @intFromPtr(selector.compounds.ptr);
        const same_selector = if (selector.cache_id != 0)
            self.reverse_selector_id == selector.cache_id
        else
            self.reverse_selector_id == 0 and self.reverse_source == source_id and self.reverse_compounds == compounds_id;
        if (same_selector) {
            if (!self.reverse_scratch_ready) try self.configureReverseScratch();
            return;
        }

        self.reverse_selector_id = 0;
        self.reverse_source = 0;
        self.reverse_compounds = 0;
        try self.compileReversePlan(selector);
        self.setReverseSelectorIdentity(selector);
    }

    fn setReverseSelectorIdentity(self: *@This(), selector: ast.Selector) void {
        self.reverse_selector_id = selector.cache_id;
        self.reverse_source = @intFromPtr(selector.source.ptr);
        self.reverse_compounds = @intFromPtr(selector.compounds.ptr);
    }

    fn reverseMask(self: *const @This(), which: execution_plan.Mask) []const u64 {
        return self.execution_plan.mask(which);
    }

    fn compileReversePlan(self: *@This(), selector: ast.Selector) !void {
        self.reverse_touched_predicates.clearRetainingCapacity();
        if (self.owns_execution_plan) {
            self.execution_plan.deinit(self.allocator);
        } else {
            // Drop the borrowed view without touching its backing allocations.
            self.execution_plan = .{};
            self.owns_execution_plan = true;
        }
        self.execution_plan = try execution_plan.Plan.init(self.allocator, selector);
        try self.configureReverseScratch();
    }

    fn configureReverseScratch(self: *@This()) !void {
        self.reverse_scratch_ready = false;
        self.reverse_word_count = self.execution_plan.word_count;
        const words = self.reverse_word_count;

        if (self.reverse_seed.len != 0) self.allocator.free(self.reverse_seed);
        self.reverse_seed = &.{};
        if (words != 0) self.reverse_seed = try self.allocator.alloc(u64, words);

        if (self.reverse_current.len != 0) self.allocator.free(self.reverse_current);
        self.reverse_current = &.{};
        if (words != 0) self.reverse_current = try self.allocator.alloc(u64, try checkedProduct(words, 3));

        if (self.reverse_local.len != 0) self.allocator.free(self.reverse_local);
        self.reverse_local = &.{};
        if (words != 0) self.reverse_local = try self.allocator.alloc(u64, words);

        if (self.reverse_seen_predicates.len != 0) self.allocator.free(self.reverse_seen_predicates);
        self.reverse_seen_predicates = &.{};
        const predicate_words = bitWordCount(self.execution_plan.predicates.count);
        if (predicate_words != 0) {
            self.reverse_seen_predicates = try self.allocator.alloc(u64, predicate_words);
            @memset(self.reverse_seen_predicates, 0);
            try self.reverse_touched_predicates.ensureTotalCapacity(
                self.allocator,
                @min(self.execution_plan.predicates.count, 64),
            );
        }
        self.reverse_scratch_ready = true;
    }
};

pub const MatchStats = struct {
    topology_parent_builds: usize = 0,
    topology_child_visits: usize = 0,
    reverse_nodes_processed: usize = 0,
    reverse_node_duplicate_processes: usize = 0,
    reverse_cells_created: usize = 0,
    reverse_queue_pushes: usize = 0,
    local_unique_predicate_evals: usize = 0,
};

pub const PredicatePlan = predicate_plan.Plan;

fn setWordBit(words: []u64, index: usize) void {
    words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
}

fn wordsIntersect(a: []const u64, b: []const u64) bool {
    for (a, b) |lhs, rhs| if ((lhs & rhs) != 0) return true;
    return false;
}

fn wordsAny(words: []const u64) bool {
    for (words) |word| if (word != 0) return true;
    return false;
}

fn matchReverseAutomaton(
    comptime Doc: type,
    noalias doc: *const Doc,
    selector: ast.Selector,
    target: IndexInt,
    scope_root: IndexInt,
    seed: []const u64,
    workspace: *MatchWorkspace,
) !bool {
    if (!doc.nodes[target].isElement(target) or workspace.reverse_word_count == 0) return false;
    resetReverseRun(workspace);
    try addReverseBits(workspace, target, seed, .direct);
    var run_nodes: usize = 0;
    // The scheduler pops the highest scheduled index first and every RTL
    // structural transition (parent, previous sibling) goes to a lower preorder
    // index, so processed indexes are strictly descending. One integer checks
    // that invariant; no document-sized processed bitset is needed.
    var previous_index_exclusive = @as(usize, @intCast(target)) + 1;

    while (try workspace.reverse_queue.pop(workspace.allocator)) |idx| {
        run_nodes += 1;
        if (comptime builtin.is_test) workspace.stats.reverse_nodes_processed += 1;
        std.debug.assert(run_nodes <= doc.nodes.len);
        const index: usize = @intCast(idx);
        std.debug.assert(index < previous_index_exclusive);
        previous_index_exclusive = index;
        const words = workspace.reverse_word_count;
        const slot = workspace.reverse_node_map.get(idx).?;
        var meta = &workspace.reverse_cell_meta.items[slot];
        std.debug.assert(meta.scheduled);
        if (meta.processed) {
            if (comptime builtin.is_test) workspace.stats.reverse_node_duplicate_processes += 1;
            std.debug.assert(false);
            continue;
        }
        meta.scheduled = false;
        meta.processed = true;
        const cell_start = slot * words * 3;
        @memcpy(workspace.reverse_current, workspace.reverse_cells.items[cell_start .. cell_start + words * 3]);
        const direct = workspace.reverse_current[0..words];
        const ancestor_carry = workspace.reverse_current[words .. words * 2];
        const sibling_carry = workspace.reverse_current[words * 2 .. words * 3];

        for (direct, ancestor_carry, sibling_carry) |*dst, up, left| dst.* |= up | left;
        try evaluateReversePredicates(Doc, doc, selector, idx, direct, workspace);
        for (direct, workspace.reverse_local) |*dst, local| dst.* &= local;

        if (wordsIntersect(direct, workspace.reverseMask(.start_none)) or
            (wordsIntersect(direct, workspace.reverseMask(.start_child)) and matchesScopeAnchor(doc, ast.Combinator.child, idx, scope_root)) or
            (wordsIntersect(direct, workspace.reverseMask(.start_descendant)) and matchesScopeAnchor(doc, ast.Combinator.descendant, idx, scope_root))) return true;

        if (wordsAny(ancestor_carry) or wordsIntersect(direct, workspace.reverseMask(.child_targets)) or wordsIntersect(direct, workspace.reverseMask(.descendant_targets))) {
            if (parentElement(doc, idx)) |parent_idx| {
                try addReverseBits(workspace, parent_idx, ancestor_carry, .ancestor);
                try addShiftedPredecessors(workspace, parent_idx, direct, workspace.reverseMask(.child_targets), .direct);
                try addShiftedPredecessors(workspace, parent_idx, direct, workspace.reverseMask(.descendant_targets), .ancestor);
            }
        }
        if (wordsAny(sibling_carry) or wordsIntersect(direct, workspace.reverseMask(.adjacent_targets)) or wordsIntersect(direct, workspace.reverseMask(.sibling_targets))) {
            if (try prevElementSiblingAccelerated(Doc, doc, idx, workspace)) |previous_idx| {
                try addReverseBits(workspace, previous_idx, sibling_carry, .sibling);
                try addShiftedPredecessors(workspace, previous_idx, direct, workspace.reverseMask(.adjacent_targets), .direct);
                try addShiftedPredecessors(workspace, previous_idx, direct, workspace.reverseMask(.sibling_targets), .sibling);
            }
        }
    }
    return false;
}

const ReverseArrival = enum { direct, ancestor, sibling };

fn resetReverseRun(workspace: *MatchWorkspace) void {
    workspace.reverse_node_map.reset();
    workspace.reverse_queue.reset();
    workspace.reverse_cells.clearRetainingCapacity();
    workspace.reverse_cell_meta.clearRetainingCapacity();
}

fn reverseCell(workspace: *MatchWorkspace, node: IndexInt) !usize {
    if (workspace.reverse_node_map.get(node)) |slot| return slot;
    const slot = workspace.reverse_cell_meta.items.len;
    const old_cells_len = workspace.reverse_cells.items.len;
    try workspace.reverse_cell_meta.append(workspace.allocator, .{ .node = node });
    errdefer workspace.reverse_cell_meta.items.len -= 1;
    try workspace.reverse_cells.appendNTimes(workspace.allocator, 0, try checkedProduct(workspace.reverse_word_count, 3));
    errdefer workspace.reverse_cells.items.len = old_cells_len;
    try workspace.reverse_node_map.put(workspace.allocator, node, slot);
    if (comptime builtin.is_test) workspace.stats.reverse_cells_created += 1;
    return slot;
}

fn addReverseBits(workspace: *MatchWorkspace, node: IndexInt, bits: []const u64, arrival: ReverseArrival) !void {
    var any_bits = false;
    for (bits) |word| any_bits = any_bits or word != 0;
    if (!any_bits) return;
    const slot = try reverseCell(workspace, node);
    const offset: usize = switch (arrival) {
        .direct => 0,
        .ancestor => 1,
        .sibling => 2,
    };
    const start = (slot * 3 + offset) * workspace.reverse_word_count;
    for (workspace.reverse_cells.items[start .. start + workspace.reverse_word_count], bits) |*dst, source| dst.* |= source;

    var meta = &workspace.reverse_cell_meta.items[slot];
    if (meta.processed) {
        if (comptime builtin.is_test) workspace.stats.reverse_node_duplicate_processes += 1;
        std.debug.assert(false);
        return;
    }
    if (!meta.scheduled) {
        try workspace.reverse_queue.push(workspace.allocator, node);
        meta.scheduled = true;
        if (comptime builtin.is_test) workspace.stats.reverse_queue_pushes += 1;
    }
}

fn addShiftedPredecessors(workspace: *MatchWorkspace, node: IndexInt, matched: []const u64, relation: []const u64, arrival: ReverseArrival) !void {
    @memset(workspace.reverse_local, 0);
    var carry: u64 = 0;
    var i = matched.len;
    while (i != 0) {
        i -= 1;
        const source = matched[i] & relation[i];
        workspace.reverse_local[i] = (source >> 1) | carry;
        carry = source << 63;
    }
    try addReverseBits(workspace, node, workspace.reverse_local, arrival);
}

fn evaluateReversePredicates(comptime Doc: type, doc: *const Doc, selector: ast.Selector, node: IndexInt, wanted: []u64, workspace: *MatchWorkspace) !void {
    // Use reverse_local as temporary tag-dispatch scratch before repurposing it
    // as the local-match output vector below. Selectors without tag constraints
    // bypass dispatch entirely and allocate no dispatch data.
    if (workspace.execution_plan.has_tag_constraints) {
        @memcpy(workspace.reverse_local, workspace.execution_plan.tag_dispatch.wildcard_state_words);
        const node_name = doc.nodes[node].name_or_text.slice(doc.source);
        const sig: execution_plan.TagSig = .{
            .key = tags.first8KeyWithMode(node_name, Doc.Options.non_destructive),
            .len = @intCast(node_name.len),
        };
        if (workspace.execution_plan.tag_dispatch.find(sig)) |entry| {
            for (workspace.execution_plan.tag_dispatch.stateUses(entry)) |use| {
                workspace.reverse_local[@intCast(use.word_index)] |= use.mask;
            }
        }
        for (wanted, workspace.reverse_local) |*word, allowed| word.* &= allowed;
    }

    @memset(workspace.reverse_local, 0);
    for (workspace.reverse_touched_predicates.items) |predicate_id| {
        const seen_bit = @as(u64, 1) << @intCast(predicate_id % 64);
        workspace.reverse_seen_predicates[predicate_id / 64] &= ~seen_bit;
    }
    workspace.reverse_touched_predicates.clearRetainingCapacity();
    workspace.node_ctx.begin(0);

    for (wanted, 0..) |wanted_word, word_index| {
        var pending = wanted_word;
        while (pending != 0) {
            const local_bit: usize = @intCast(@ctz(pending));
            pending &= pending - 1;
            const state_index = word_index * 64 + local_bit;
            if (state_index >= workspace.execution_plan.state_count) continue;
            const meta = workspace.execution_plan.states[state_index];
            const predicate_id: usize = @intCast(workspace.execution_plan.predicates.state_ids[meta.compound]);
            const seen_bit = @as(u64, 1) << @intCast(predicate_id % 64);
            if ((workspace.reverse_seen_predicates[predicate_id / 64] & seen_bit) != 0) continue;
            try workspace.reverse_touched_predicates.append(workspace.allocator, predicate_id);
            workspace.reverse_seen_predicates[predicate_id / 64] |= seen_bit;
            if (comptime builtin.is_test) workspace.stats.local_unique_predicate_evals += 1;
            const representative: usize = @intCast(workspace.execution_plan.predicates.representatives[predicate_id]);
            if (try matchesCompoundRtlCached(Doc, doc, selector, selector.compounds[representative], node, &workspace.node_ctx)) {
                for (workspace.execution_plan.predicateStateUsesFor(predicate_id)) |use| {
                    const word: usize = @intCast(use.word_index);
                    workspace.reverse_local[word] |= wanted[word] & use.mask;
                }
            }
        }
    }
}

fn prevElementSiblingAccelerated(comptime Doc: type, doc: *const Doc, node_index: IndexInt, workspace: *MatchWorkspace) !?IndexInt {
    const RawNode = @TypeOf(doc.nodes[0]);
    if (comptime @FieldType(RawNode, "prev_sibling") != void) {
        const previous = doc.nodes[node_index].prev_sibling;
        return if (previous == InvalidIndex) null else previous;
    }
    // Invariant: cache miss implies parent topology not yet materialized, so
    // this node can only be reached via the first-child path below (or is the
    // root). The lookup must not miss for a node that got inserted by a build.
    if (workspace.topology_prev.get(node_index)) |previous| return if (previous == InvalidIndex) null else previous;
    const parent = doc.nodes[node_index].parent;
    if (parent == InvalidIndex or parent >= doc.nodes.len) return null;

    // Cache miss means this node's parent topology has not been materialized.
    // Building it inserts every direct element child (first child included, as
    // InvalidIndex) into topology_prev, so no second lookup or marker map is
    // needed to know it was built.
    if (comptime builtin.is_test) workspace.stats.topology_parent_builds += 1;
    var previous: IndexInt = InvalidIndex;
    var cursor: IndexInt = parent + 1;
    const end = doc.nodes[parent].subtree_end;
    while (cursor <= end and cursor < doc.nodes.len) {
        const raw = &doc.nodes[cursor];
        if (raw.parent == parent) {
            if (comptime builtin.is_test) workspace.stats.topology_child_visits += 1;
            if (raw.isElement(cursor)) {
                try workspace.topology_prev.put(workspace.allocator, cursor, previous);
                previous = cursor;
                cursor = raw.subtree_end + 1;
                continue;
            }
        }
        cursor += 1;
    }

    // Invariant: this build inserted node_index itself, so the read-back must
    // not miss. A miss here signals a corrupted sibling-topology.
    const result = workspace.topology_prev.get(node_index).?;
    return if (result == InvalidIndex) null else result;
}

fn groupHasExistential(selector: ast.Selector, group: ast.Group, rel_index: IndexInt) bool {
    var rel: IndexInt = 1;
    while (rel <= rel_index) : (rel += 1) {
        const combinator = selector.compounds[group.compound_start + rel].combinator;
        if (combinator == .descendant or combinator == .sibling) return true;
    }
    return false;
}

fn matchDeterministicGroup(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, start_rel: IndexInt, start_node: IndexInt, scope_root: IndexInt, ctx: *NodeContext) !bool {
    var rel = start_rel;
    var node = start_node;
    while (true) {
        const comp = selector.compounds[group.compound_start + rel];
        ctx.begin(0);
        if (!try matchesCompoundRtlCached(Doc, doc, selector, comp, node, ctx)) return false;
        if (rel == 0) return comp.combinator == .none or matchesScopeAnchor(doc, comp.combinator, node, scope_root);
        node = switch (comp.combinator) {
            .child => parentElement(doc, node),
            .adjacent => prevElementSibling(doc, node),
            else => unreachable,
        } orelse return false;
        rel -= 1;
    }
}

pub const NodeContext = struct {
    scratch: ?std.heap.ArenaAllocator = null,
    child_position: usize = 0,
    last_child_cache: ?bool = null,

    pub fn begin(self: *@This(), child_position: usize) void {
        if (self.scratch) |*scratch| _ = scratch.reset(.retain_capacity);
        self.child_position = child_position;
        self.last_child_cache = null;
    }

    inline fn scratchAllocator(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator {
        if (self.scratch == null) self.scratch = std.heap.ArenaAllocator.init(allocator);
        return self.scratch.?.allocator();
    }

    pub fn deinit(self: *@This()) void {
        if (self.scratch) |*scratch| scratch.deinit();
        self.scratch = null;
    }
};

const PseudoMode = enum { rtl, forward };

pub fn matchesCompoundForward(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, ctx: *NodeContext) !bool {
    return matchesCompoundCore(Doc, doc, selector, comp, node_index, ctx, .forward, ctx.child_position);
}

fn matchesCompoundRtlCached(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, ctx: *NodeContext) !bool {
    return matchesCompoundCore(Doc, doc, selector, comp, node_index, ctx, .rtl, 0);
}

fn matchesCompoundCore(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, ctx: *NodeContext, pseudo_mode: PseudoMode, child_position: usize) !bool {
    if (!doc.nodes[node_index].isElement(node_index)) return false;
    const node = &doc.nodes[node_index];

    const possible_attr_requests: usize = @as(usize, @intFromBool(comp.hasId())) + @as(usize, @intFromBool(comp.class_len != 0)) + @as(usize, @intCast(comp.attr_len)) + @as(usize, @intCast(comp.not_len));
    var collected_attrs: CollectedAttrs = undefined;
    const inspect_collected = possible_attr_requests >= 2 or comp.not_len != 0;
    const use_collected = inspect_collected and prepareCollectedAttrs(selector, comp, &collected_attrs);
    const collected_ptr: ?*CollectedAttrs = if (use_collected) &collected_attrs else null;
    const attr_allocator: std.mem.Allocator = if (use_collected) ctx.scratchAllocator(doc.allocator) else doc.allocator;
    const last_child_cache = &ctx.last_child_cache;

    if (comp.hasTag()) {
        const node_name = node.name_or_text.slice(doc.source);
        if (!tagMatches(Doc, selector.source, comp, node_name)) return false;
    }

    if (comp.hasId()) {
        const id = comp.id.slice(selector.source);
        const result = try attrValueByNameFrom(
            doc,
            node,
            attr_allocator,
            collected_ptr,
            "id",
        ) orelse return false;
        defer result.free(attr_allocator);
        if (!std.mem.eql(u8, result.value, id)) return false;
    }

    if (comp.class_len != 0) {
        const result = try attrValueByNameFrom(
            doc,
            node,
            attr_allocator,
            collected_ptr,
            "class",
        ) orelse return false;
        defer result.free(attr_allocator);
        if (!hasAllClassesOnePass(selector, comp, result.value)) return false;
    }

    var attr_i: IndexInt = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!try matchesAttrSelector(doc, node, attr_allocator, collected_ptr, selector.source, attr_sel)) return false;
    }

    var pseudo_i: IndexInt = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        const pseudo_matches = switch (pseudo_mode) {
            .rtl => matchesPseudo(doc, node_index, pseudo),
            .forward => switch (pseudo.kind) {
                .first_child => child_position == 1,
                .nth_child => pseudo.nth.matches(child_position),
                .last_child => blk: {
                    if (last_child_cache.* == null) last_child_cache.* = nextElementSibling(doc, node_index) == null;
                    break :blk last_child_cache.*.?;
                },
            },
        };
        if (!pseudo_matches) return false;
    }

    var not_i: IndexInt = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (try matchesNotSimple(doc, node, attr_allocator, collected_ptr, selector.source, item)) return false;
    }

    return true;
}

fn matchesNotSimple(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    item: ast.NotSimple,
) !bool {
    return switch (item.kind) {
        .tag => std.ascii.eqlIgnoreCase(node.name_or_text.slice(doc.source), item.text.slice(selector_source)),
        .id => blk: {
            const result = (try attrValueByNameFrom(doc, node, allocator, collected, "id")) orelse break :blk false;
            defer result.free(allocator);
            break :blk std.mem.eql(u8, result.value, item.text.slice(selector_source));
        },
        .class => try hasClass(doc, node, allocator, collected, item.text.slice(selector_source)),
        .attr => try matchesAttrSelector(doc, node, allocator, collected, selector_source, item.attr),
    };
}

pub fn matchesPseudo(doc: anytype, node_index: IndexInt, pseudo: ast.Pseudo) bool {
    return switch (pseudo.kind) {
        .first_child => prevElementSibling(doc, node_index) == null,
        .last_child => nextElementSibling(doc, node_index) == null,
        .nth_child => blk: {
            const position = common.elementSiblingPosition(doc, node_index) orelse break :blk false;
            break :blk pseudo.nth.matches(position);
        },
    };
}

fn matchesAttrSelector(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    sel: ast.AttrSelector,
) !bool {
    const name = sel.name.slice(selector_source);
    const result = (try attrValueByNameFrom(doc, node, allocator, collected, name)) orelse return false;
    defer result.free(allocator);
    const value = sel.value.slice(selector_source);
    return evalAttrOp(result.value, value, sel.op, sel.case);
}

fn hasClass(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    collected: ?*CollectedAttrs,
    class_name: []const u8,
) !bool {
    const result = (try attrValueByNameFrom(doc, node, allocator, collected, "class")) orelse return false;
    defer result.free(allocator);
    return tables.tokenIncludesAsciiWhitespace(result.value, class_name);
}

fn hasAllClassesOnePass(selector: ast.Selector, comp: ast.Compound, class_attr: []const u8) bool {
    const class_count = comp.class_len;
    if (class_count == 0) return true;
    if (class_count > 63) {
        var i: IndexInt = 0;
        while (i < class_count) : (i += 1) {
            const cls = selector.classes[comp.class_start + i].slice(selector.source);
            if (!tables.tokenIncludesAsciiWhitespace(class_attr, cls)) return false;
        }
        return true;
    }

    const target_mask: u64 = (@as(u64, 1) << @as(u6, @intCast(class_count))) - 1;
    var found_mask: u64 = 0;
    var i: usize = 0;
    while (i < class_attr.len) {
        while (i < class_attr.len and tables.WhitespaceTable[class_attr[i]]) : (i += 1) {}
        if (i >= class_attr.len) break;
        const tok_start = i;
        while (i < class_attr.len and !tables.WhitespaceTable[class_attr[i]]) : (i += 1) {}
        const tok = class_attr[tok_start..i];

        var j: IndexInt = 0;
        while (j < class_count) : (j += 1) {
            const bit_shift: u6 = @intCast(j);
            const bit: u64 = @as(u64, 1) << bit_shift;
            if ((found_mask & bit) != 0) continue;
            const cls = selector.classes[comp.class_start + j].slice(selector.source);
            if (std.mem.eql(u8, tok, cls)) {
                found_mask |= bit;
                if (found_mask == target_mask) return true;
            }
        }
    }
    return found_mask == target_mask;
}

fn attrValueByNameFrom(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    collected: ?*CollectedAttrs,
    name: []const u8,
) !?common.SliceResult {
    if (collected) |c| {
        if (findCollectedEntry(c, name)) |idx| {
            if (c.materialized or c.looked[idx]) return if (c.values[idx]) |value| .{ .value = value } else null;

            if (!c.requested_once) {
                const result = try attr.getAttrValue(doc, node, name, allocator);
                c.values[idx] = if (result) |r| r.value else null;
                c.looked[idx] = true;
                c.requested_once = true;
                return if (result) |r| .{ .value = r.value } else null;
            }

            try attr.collectSelectedValues(
                doc,
                node,
                c.names[0..c.count],
                c.values[0..c.count],
                allocator,
            );
            c.materialized = true;
            var i: usize = 0;
            while (i < c.count) : (i += 1) c.looked[i] = true;
            return if (c.values[idx]) |value| .{ .value = value } else null;
        }
    }
    return try attr.getAttrValue(doc, node, name, allocator);
}

const CollectedAttrs = struct {
    count: usize = 0,
    requested_once: bool = false,
    materialized: bool = false,
    names: [MaxCollectedAttrs][]const u8 = undefined,
    values: [MaxCollectedAttrs]?[]const u8 = [_]?[]const u8{null} ** MaxCollectedAttrs,
    looked: [MaxCollectedAttrs]bool = [_]bool{false} ** MaxCollectedAttrs,
};

fn prepareCollectedAttrs(selector: ast.Selector, comp: ast.Compound, out: *CollectedAttrs) bool {
    out.count = 0;
    out.requested_once = false;
    out.materialized = false;

    if (comp.hasId() and !pushCollectedName(out, "id")) return false;
    if (comp.class_len != 0 and !pushCollectedName(out, "class")) return false;

    var attr_i: IndexInt = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        const name = attr_sel.name.slice(selector.source);
        if (!pushCollectedName(out, name)) return false;
    }

    var not_i: IndexInt = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        switch (item.kind) {
            .id => if (!pushCollectedName(out, "id")) return false,
            .class => if (!pushCollectedName(out, "class")) return false,
            .attr => {
                const name = item.attr.name.slice(selector.source);
                if (!pushCollectedName(out, name)) return false;
            },
            else => {},
        }
    }

    return out.count >= 2;
}

fn pushCollectedName(out: *CollectedAttrs, name: []const u8) bool {
    if (findCollectedEntry(out, name) != null) return true;
    if (out.count >= MaxCollectedAttrs) return false;
    out.names[out.count] = name;
    out.values[out.count] = null;
    out.looked[out.count] = false;
    out.count += 1;
    return true;
}

fn findCollectedEntry(collected: *const CollectedAttrs, needle: []const u8) ?usize {
    var i: usize = 0;
    while (i < collected.count) : (i += 1) {
        const cand = collected.names[i];
        if (cand.len != needle.len) continue;
        if (cand.len != 0 and std.ascii.toLower(cand[0]) != std.ascii.toLower(needle[0])) continue;
        if (std.ascii.eqlIgnoreCase(cand, needle)) return i;
    }
    return null;
}

test "matcher attr operators cover sensitive and ascii-insensitive semantics" {
    try std.testing.expect(evalAttrOp("alpha beta", "", .exists, .sensitive));
    try std.testing.expect(evalAttrOp("abc", "abc", .eq, .sensitive));
    try std.testing.expect(!evalAttrOp("Abc", "abc", .eq, .sensitive));
    try std.testing.expect(evalAttrOp("Abc", "abc", .eq, .insensitive_ascii));
    try std.testing.expect(evalAttrOp("abcdef", "abc", .prefix, .sensitive));
    try std.testing.expect(evalAttrOp("abcdef", "DEF", .suffix, .insensitive_ascii));
    try std.testing.expect(evalAttrOp("abcdef", "CD", .contains, .insensitive_ascii));
    try std.testing.expect(evalAttrOp("alpha\tbeta\ngamma", "BETA", .includes, .insensitive_ascii));
    try std.testing.expect(!evalAttrOp("alphabet", "alpha", .includes, .sensitive));
    try std.testing.expect(evalAttrOp("en-US", "EN", .dash_match, .insensitive_ascii));
    try std.testing.expect(!evalAttrOp("english", "en", .dash_match, .sensitive));
}

test "predicate plan stores sparse uses for one repeated predicate" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..65) |i| {
        if (i != 0) try source.appendSlice(alloc, " ");
        try source.appendSlice(alloc, "div");
    }

    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);
    var plan = try PredicatePlan.init(alloc, selector);
    defer plan.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expect(plan.uses.len <= selector.compounds.len);
    try std.testing.expectEqual(@as(usize, 2), plan.uses.len);
}

test "empty substring attribute operands match nothing" {
    inline for (.{ ast.AttrOp.prefix, ast.AttrOp.suffix, ast.AttrOp.contains }) |op| {
        try std.testing.expect(!evalAttrOp("", "", op, .sensitive));
        try std.testing.expect(!evalAttrOp("abc", "", op, .sensitive));
        try std.testing.expect(!evalAttrOp("AbC", "", op, .insensitive_ascii));
    }
}

test "matcher ascii-insensitive token include respects token boundaries" {
    try std.testing.expect(tokenIncludesIgnoreCaseAscii("  Foo\tbar\nBAZ  ", "foo"));
    try std.testing.expect(tokenIncludesIgnoreCaseAscii("  Foo\tbar\nBAZ  ", "baz"));
    try std.testing.expect(!tokenIncludesIgnoreCaseAscii("foobar baz", "foo"));
    try std.testing.expect(!tokenIncludesIgnoreCaseAscii("   ", "foo"));
}

test "matcher class one-pass requires every class token exactly" {
    const classes = [_]ast.Range{
        ast.Range.from(0, 3),
        ast.Range.from(4, 7),
        ast.Range.from(8, 13),
    };
    const selector: ast.Selector = .{
        .source = "foo bar bazed",
        .groups = &.{},
        .compounds = &.{},
        .classes = &classes,
        .attrs = &.{},
        .pseudos = &.{},
        .not_items = &.{},
    };
    const comp: ast.Compound = .{ .class_start = 0, .class_len = classes.len };

    try std.testing.expect(hasAllClassesOnePass(selector, comp, "bar foo bazed"));
    try std.testing.expect(hasAllClassesOnePass(selector, comp, "foo foo bazed bar"));
    try std.testing.expect(!hasAllClassesOnePass(selector, comp, "foo bar baz"));
    try std.testing.expect(!hasAllClassesOnePass(selector, comp, "foobar bazed bar"));

    const duplicate_classes = [_]ast.Range{
        ast.Range.from(0, 3),
        ast.Range.from(4, 7),
    };
    const duplicate_selector: ast.Selector = .{
        .source = "foo foo",
        .groups = &.{},
        .compounds = &.{},
        .classes = &duplicate_classes,
        .attrs = &.{},
        .pseudos = &.{},
        .not_items = &.{},
    };
    const duplicate_comp: ast.Compound = .{ .class_start = 0, .class_len = duplicate_classes.len };
    try std.testing.expect(hasAllClassesOnePass(duplicate_selector, duplicate_comp, "foo"));
}

test "matcher pseudo classes inspect element sibling position" {
    const html = @import("../html/document.zig");
    const opts: html.ParseOptions = .{ .drop_whitespace_text_nodes = .nodes };
    const alloc = std.testing.allocator;
    const input = try alloc.dupe(u8, "<main><p>A</p>text<span>B</span><em>C</em></main>");
    defer alloc.free(input);
    var doc = try opts.parse(alloc, input);
    defer doc.deinit();

    const p: IndexInt = 2;
    const span: IndexInt = 4;
    const em: IndexInt = 6;

    try std.testing.expect(matchesPseudo(&doc, p, .{ .kind = .first_child }));
    try std.testing.expect(!matchesPseudo(&doc, span, .{ .kind = .first_child }));
    try std.testing.expect(matchesPseudo(&doc, em, .{ .kind = .last_child }));
    try std.testing.expect(!matchesPseudo(&doc, span, .{ .kind = .last_child }));
    try std.testing.expect(matchesPseudo(&doc, span, .{ .kind = .nth_child, .nth = .{ .a = 0, .b = 2 } }));
    try std.testing.expect(matchesPseudo(&doc, em, .{ .kind = .nth_child, .nth = .{ .a = 2, .b = 1 } }));
}

test "matcher direct selector entry points handle attrs classes pseudos and not" {
    const html = @import("../html/document.zig");
    const opts: html.ParseOptions = .{ .drop_whitespace_text_nodes = .nodes };
    const alloc = std.testing.allocator;
    const input = try alloc.dupe(u8, "<main><a class='nav button' href='https-docs'>x</a><a class='nav'>y</a></main>");
    defer alloc.free(input);
    var doc = try opts.parse(alloc, input);
    defer doc.deinit();

    var sel = try ast.Selector.compileRuntime(alloc, "a[href^=https][class*=nav]:first-child:not(.missing)");
    defer sel.deinit(alloc);
    try std.testing.expect(try matchesSelectorAt(@TypeOf(doc), &doc, sel, 2, InvalidIndex));
    try std.testing.expect(!try matchesSelectorAt(@TypeOf(doc), &doc, sel, 4, InvalidIndex));
    try std.testing.expect(!try matchesSelectorAt(@TypeOf(doc), &doc, sel, @intCast(doc.nodes.len), InvalidIndex));
}

test "RTL sibling topology survives scope changes within one workspace" {
    const html = @import("../html/document.zig");
    const alloc = std.testing.allocator;
    var input = "<div><a></a><x></x><b></b></div>".*;
    const opts: html.ParseOptions = .{};
    var doc = try opts.parse(alloc, &input);
    defer doc.deinit();

    var selector = try ast.Selector.compileRuntime(alloc, "a ~ b");
    defer selector.deinit(alloc);
    var workspace = MatchWorkspace.init(alloc);
    defer workspace.deinit();

    const target: IndexInt = 4;
    try std.testing.expect(try matchesSelectorAtWithWorkspace(@TypeOf(doc), &doc, selector, target, InvalidIndex, &workspace));
    try std.testing.expectEqual(@as(usize, 1), workspace.stats.topology_parent_builds);

    // Scope affects selector anchoring, not the document's previous-sibling
    // topology. A scope change must therefore reuse the already-built parent
    // topology rather than scan the same siblings again.
    try std.testing.expect(try matchesSelectorAtWithWorkspace(@TypeOf(doc), &doc, selector, target, 1, &workspace));
    try std.testing.expectEqual(@as(usize, 1), workspace.stats.topology_parent_builds);
}
