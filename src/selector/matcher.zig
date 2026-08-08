const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr = @import("../html/attr.zig");
const common = @import("../common.zig");

// SAFETY: Selector AST indices are trusted to be internally consistent
// (group/compound/predicate ranges). Document node indices are validated
// before use; debug asserts guard scope bounds in key entry points.

const IndexInt = common.IndexInt;
const InvalidIndex: IndexInt = common.InvalidIndex;
const MaxProbeEntries: usize = 24;
const MaxCollectedAttrs: usize = 24;
const matchesScopeAnchor = common.matchesScopeAnchor;
const parentElement = common.parentElement;
const prevElementSibling = common.prevElementSibling;
const nextElementSibling = common.nextElementSibling;

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

pub fn matchesSelectorAtWithWorkspace(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, node_index: IndexInt, scope_root: IndexInt, workspace: *MatchWorkspace) !bool {
    if (node_index >= doc.nodes.len) return false;
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.len) return false;
    workspace.prepare(selector, scope_root, @intFromPtr(doc), doc.generation);

    var has_existential = false;
    for (selector.groups) |group| {
        if (group.compound_len != 0 and groupHasExistential(selector, group, group.compound_len - 1)) {
            has_existential = true;
            break;
        }
    }
    if (!has_existential) {
        for (selector.groups) |group| {
            if (group.compound_len == 0) continue;
            if (try matchDeterministicGroup(Doc, doc, selector, group, group.compound_len - 1, node_index, scope_root, &workspace.node_ctx)) return true;
        }
        return false;
    }
    try workspace.ensureReversePlan(selector);
    return matchReverseAutomaton(Doc, doc, selector, node_index, scope_root, workspace.reverseMask(.final), workspace);
}

/// Matches one left-to-right group prefix at a specific node using the RTL engine.
/// Used once when seeding a scoped forward query from ancestors outside its scan.
pub fn matchesPrefixAt(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, group: ast.Group, prefix_len: usize, node_index: IndexInt, workspace: *MatchWorkspace) !bool {
    if (prefix_len == 0 or prefix_len > group.compound_len or node_index >= doc.nodes.len) return false;
    workspace.prepare(selector, InvalidIndex, @intFromPtr(doc), doc.generation);
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
    setWordBit(workspace.reverse_seed, @as(usize, @intCast(group.compound_start)) + prefix_len - 1);
    return matchReverseAutomaton(Doc, doc, selector, node_index, InvalidIndex, workspace.reverse_seed, workspace);
}

pub const MatchWorkspace = struct {
    allocator: std.mem.Allocator,
    topology_prev: std.AutoHashMapUnmanaged(IndexInt, IndexInt) = .empty,
    predicate_plan: PredicatePlan = .{},
    node_ctx: NodeContext = .{},
    reverse_masks: []u64 = &.{},
    reverse_seed: []u64 = &.{},
    reverse_current: []u64 = &.{},
    reverse_local: []u64 = &.{},
    reverse_seen_predicates: []u64 = &.{},
    reverse_scheduled: []u64 = &.{},
    reverse_slot_by_node: []u32 = &.{},
    reverse_cells: std.ArrayListUnmanaged(u64) = .empty,
    reverse_cell_nodes: std.ArrayListUnmanaged(IndexInt) = .empty,
    reverse_word_count: usize = 0,
    reverse_cursor_exclusive: usize = 0,
    stats: MatchStats = .{},
    prepared_source: usize = 0,
    prepared_compounds: usize = 0,
    prepared_scope: IndexInt = InvalidIndex,
    prepared_doc: usize = 0,
    prepared_generation: u64 = 0,
    reverse_source: usize = 0,
    reverse_compounds: usize = 0,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        self.topology_prev.deinit(self.allocator);
        self.topology_prev = .empty;
        self.predicate_plan.deinit(self.allocator);
        self.node_ctx.deinit();
        if (self.reverse_masks.len != 0) self.allocator.free(self.reverse_masks);
        self.reverse_masks = &.{};
        if (self.reverse_seed.len != 0) self.allocator.free(self.reverse_seed);
        self.reverse_seed = &.{};
        if (self.reverse_current.len != 0) self.allocator.free(self.reverse_current);
        self.reverse_current = &.{};
        if (self.reverse_local.len != 0) self.allocator.free(self.reverse_local);
        self.reverse_local = &.{};
        if (self.reverse_seen_predicates.len != 0) self.allocator.free(self.reverse_seen_predicates);
        self.reverse_seen_predicates = &.{};
        if (self.reverse_scheduled.len != 0) self.allocator.free(self.reverse_scheduled);
        self.reverse_scheduled = &.{};
        if (self.reverse_slot_by_node.len != 0) self.allocator.free(self.reverse_slot_by_node);
        self.reverse_slot_by_node = &.{};
        self.reverse_cells.deinit(self.allocator);
        self.reverse_cells = .empty;
        self.reverse_cell_nodes.deinit(self.allocator);
        self.reverse_cell_nodes = .empty;
    }

    fn prepare(self: *@This(), selector: ast.Selector, scope_root: IndexInt, doc_id: usize, generation: u64) void {
        const source_id = @intFromPtr(selector.source.ptr);
        const compounds_id = @intFromPtr(selector.compounds.ptr);
        if (self.prepared_source == source_id and
            self.prepared_compounds == compounds_id and
            self.prepared_scope == scope_root and
            self.prepared_doc == doc_id and
            self.prepared_generation == generation) return;
        self.prepared_source = source_id;
        self.prepared_compounds = compounds_id;
        self.prepared_scope = scope_root;
        self.prepared_doc = doc_id;
        self.prepared_generation = generation;
        self.topology_prev.clearRetainingCapacity();
    }

    fn ensureReversePlan(self: *@This(), selector: ast.Selector) !void {
        const source_id = @intFromPtr(selector.source.ptr);
        const compounds_id = @intFromPtr(selector.compounds.ptr);
        if (self.reverse_source == source_id and self.reverse_compounds == compounds_id) return;
        try self.compileReversePlan(selector);
        self.reverse_source = source_id;
        self.reverse_compounds = compounds_id;
    }

    const ReverseMask = enum(usize) { start_none, start_child, start_descendant, child, descendant, adjacent, sibling, final };

    fn reverseMask(self: *@This(), which: ReverseMask) []u64 {
        const start = @intFromEnum(which) * self.reverse_word_count;
        return self.reverse_masks[start .. start + self.reverse_word_count];
    }

    fn compileReversePlan(self: *@This(), selector: ast.Selector) !void {
        self.predicate_plan.deinit(self.allocator);
        self.predicate_plan = try PredicatePlan.init(self.allocator, selector);
        self.reverse_word_count = (selector.compounds.len + 63) / 64;
        const words = self.reverse_word_count;
        if (self.reverse_masks.len != 0) self.allocator.free(self.reverse_masks);
        self.reverse_masks = &.{};
        self.reverse_masks = try self.allocator.alloc(u64, words * 8);
        @memset(self.reverse_masks, 0);
        if (self.reverse_seed.len != 0) self.allocator.free(self.reverse_seed);
        self.reverse_seed = &.{};
        self.reverse_seed = try self.allocator.alloc(u64, words);
        if (self.reverse_current.len != 0) self.allocator.free(self.reverse_current);
        self.reverse_current = &.{};
        self.reverse_current = try self.allocator.alloc(u64, words * 3);
        if (self.reverse_local.len != 0) self.allocator.free(self.reverse_local);
        self.reverse_local = &.{};
        self.reverse_local = try self.allocator.alloc(u64, words);
        if (self.reverse_seen_predicates.len != 0) self.allocator.free(self.reverse_seen_predicates);
        self.reverse_seen_predicates = &.{};
        self.reverse_seen_predicates = try self.allocator.alloc(u64, (self.predicate_plan.count + 63) / 64);

        for (selector.groups) |group| {
            if (group.compound_len == 0) continue;
            const start: usize = @intCast(group.compound_start);
            const len: usize = @intCast(group.compound_len);
            setWordBit(self.reverseMask(.final), start + len - 1);
            for (0..len) |rel| {
                const absolute = start + rel;
                const comp = selector.compounds[absolute];
                if (rel == 0) {
                    switch (comp.combinator) {
                        .none => setWordBit(self.reverseMask(.start_none), absolute),
                        .child => setWordBit(self.reverseMask(.start_child), absolute),
                        .descendant => setWordBit(self.reverseMask(.start_descendant), absolute),
                        .adjacent, .sibling => {},
                    }
                } else switch (comp.combinator) {
                    .child => setWordBit(self.reverseMask(.child), absolute),
                    .descendant => setWordBit(self.reverseMask(.descendant), absolute),
                    .adjacent => setWordBit(self.reverseMask(.adjacent), absolute),
                    .sibling => setWordBit(self.reverseMask(.sibling), absolute),
                    .none => {},
                }
            }
        }
    }
};

pub const MatchStats = struct {
    topology_parent_builds: usize = 0,
    topology_child_visits: usize = 0,
    reverse_nodes_processed: usize = 0,
    local_unique_predicate_evals: usize = 0,
};

/// Interns semantically identical local compounds and maps each predicate to
/// every selector-state bit that uses it. Combinators are deliberately ignored:
/// they are structural transitions, not local node predicates.
pub const PredicatePlan = struct {
    state_ids: []u32 = &.{},
    representatives: []IndexInt = &.{},
    masks: []u64 = &.{},
    word_count: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, selector: ast.Selector) !@This() {
        var self: @This() = .{ .word_count = (selector.compounds.len + 63) / 64 };
        errdefer self.deinit(allocator);
        self.state_ids = try allocator.alloc(u32, selector.compounds.len);
        self.representatives = try allocator.alloc(IndexInt, selector.compounds.len);

        // First intern predicates. Allocate dense state masks only after the
        // actual unique-predicate count is known; allocating N rows here makes
        // repeated selectors such as `div div ...` consume O(N^2 / word_bits).
        for (selector.compounds, 0..) |_, absolute| {
            var predicate_id: usize = 0;
            while (predicate_id < self.count) : (predicate_id += 1) {
                const representative: usize = @intCast(self.representatives[predicate_id]);
                if (compoundsEquivalent(selector, selector.compounds[representative], selector.compounds[absolute])) break;
            }
            if (predicate_id == self.count) {
                self.representatives[self.count] = @intCast(absolute);
                self.count += 1;
            }
            self.state_ids[absolute] = @intCast(predicate_id);
        }

        if (self.count != 0 and self.word_count != 0) {
            self.masks = try allocator.alloc(u64, self.count * self.word_count);
            @memset(self.masks, 0);
            for (self.state_ids, 0..) |predicate_id, absolute| {
                setWordBit(self.predicateMask(predicate_id), absolute);
            }
        }
        return self;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.state_ids.len != 0) allocator.free(self.state_ids);
        if (self.representatives.len != 0) allocator.free(self.representatives);
        if (self.masks.len != 0) allocator.free(self.masks);
        self.* = .{};
    }

    pub fn predicateMask(self: *@This(), predicate_id: usize) []u64 {
        const start = predicate_id * self.word_count;
        return self.masks[start .. start + self.word_count];
    }

    pub fn predicateMaskConst(self: *const @This(), predicate_id: usize) []const u64 {
        const start = predicate_id * self.word_count;
        return self.masks[start .. start + self.word_count];
    }
};

fn compoundsEquivalent(selector: ast.Selector, a: ast.Compound, b: ast.Compound) bool {
    if (!rangeEqual(selector.source, a.tag, b.tag) or !rangeEqual(selector.source, a.id, b.id)) return false;
    if (a.class_len != b.class_len or a.attr_len != b.attr_len or a.pseudo_len != b.pseudo_len or a.not_len != b.not_len) return false;

    var i: IndexInt = 0;
    while (i < a.class_len) : (i += 1) {
        if (!rangeEqual(selector.source, selector.classes[a.class_start + i], selector.classes[b.class_start + i])) return false;
    }
    i = 0;
    while (i < a.attr_len) : (i += 1) {
        if (!attrSelectorsEqual(selector.source, selector.attrs[a.attr_start + i], selector.attrs[b.attr_start + i])) return false;
    }
    i = 0;
    while (i < a.pseudo_len) : (i += 1) {
        const lhs = selector.pseudos[a.pseudo_start + i];
        const rhs = selector.pseudos[b.pseudo_start + i];
        if (lhs.kind != rhs.kind or lhs.nth.a != rhs.nth.a or lhs.nth.b != rhs.nth.b) return false;
    }
    i = 0;
    while (i < a.not_len) : (i += 1) {
        const lhs = selector.not_items[a.not_start + i];
        const rhs = selector.not_items[b.not_start + i];
        if (lhs.kind != rhs.kind) return false;
        switch (lhs.kind) {
            .tag, .id, .class => if (!rangeEqual(selector.source, lhs.text, rhs.text)) return false,
            .attr => if (!attrSelectorsEqual(selector.source, lhs.attr, rhs.attr)) return false,
        }
    }
    return true;
}

fn attrSelectorsEqual(source: []const u8, a: ast.AttrSelector, b: ast.AttrSelector) bool {
    return a.op == b.op and a.case == b.case and rangeEqual(source, a.name, b.name) and rangeEqual(source, a.value, b.value);
}

fn rangeEqual(source: []const u8, a: ast.Range, b: ast.Range) bool {
    return std.mem.eql(u8, a.slice(source), b.slice(source));
}

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
    try resetReverseRun(workspace, doc.nodes.len, target);
    try addReverseBits(workspace, target, seed, .direct);
    var run_nodes: usize = 0;
    // The scheduler pops the highest scheduled index first and every RTL
    // structural transition (parent, previous sibling) goes to a lower preorder
    // index, so processed indexes are strictly descending. One integer checks
    // that invariant; no document-sized processed bitset is needed.
    var previous_index_exclusive = @as(usize, @intCast(target)) + 1;

    while (popHighestScheduled(workspace)) |idx| {
        run_nodes += 1;
        workspace.stats.reverse_nodes_processed += 1;
        std.debug.assert(run_nodes <= doc.nodes.len);
        const index: usize = @intCast(idx);
        std.debug.assert(index < previous_index_exclusive);
        previous_index_exclusive = index;
        const words = workspace.reverse_word_count;
        const slot: usize = workspace.reverse_slot_by_node[idx];
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

        if (wordsAny(ancestor_carry) or wordsIntersect(direct, workspace.reverseMask(.child)) or wordsIntersect(direct, workspace.reverseMask(.descendant))) {
            if (parentElement(doc, idx)) |parent_idx| {
                try addReverseBits(workspace, parent_idx, ancestor_carry, .ancestor);
                try addShiftedPredecessors(workspace, parent_idx, direct, workspace.reverseMask(.child), .direct);
                try addShiftedPredecessors(workspace, parent_idx, direct, workspace.reverseMask(.descendant), .ancestor);
            }
        }
        if (wordsAny(sibling_carry) or wordsIntersect(direct, workspace.reverseMask(.adjacent)) or wordsIntersect(direct, workspace.reverseMask(.sibling))) {
            if (try prevElementSiblingAccelerated(Doc, doc, idx, workspace)) |previous_idx| {
                try addReverseBits(workspace, previous_idx, sibling_carry, .sibling);
                try addShiftedPredecessors(workspace, previous_idx, direct, workspace.reverseMask(.adjacent), .direct);
                try addShiftedPredecessors(workspace, previous_idx, direct, workspace.reverseMask(.sibling), .sibling);
            }
        }
    }
    return false;
}

const ReverseArrival = enum { direct, ancestor, sibling };

fn resetReverseRun(workspace: *MatchWorkspace, node_count: usize, target: IndexInt) !void {
    const NoSlot = std.math.maxInt(u32);
    if (workspace.reverse_slot_by_node.len != node_count) {
        if (workspace.reverse_slot_by_node.len != 0) workspace.allocator.free(workspace.reverse_slot_by_node);
        workspace.reverse_slot_by_node = &.{};
        workspace.reverse_slot_by_node = try workspace.allocator.alloc(u32, node_count);
        @memset(workspace.reverse_slot_by_node, NoSlot);
    } else {
        for (workspace.reverse_cell_nodes.items) |node| workspace.reverse_slot_by_node[node] = NoSlot;
    }
    workspace.reverse_cells.clearRetainingCapacity();
    workspace.reverse_cell_nodes.clearRetainingCapacity();

    const scheduled_words = (@as(usize, @intCast(target)) + 64) / 64;
    if (workspace.reverse_scheduled.len != scheduled_words) {
        if (workspace.reverse_scheduled.len != 0) workspace.allocator.free(workspace.reverse_scheduled);
        workspace.reverse_scheduled = &.{};
        workspace.reverse_scheduled = try workspace.allocator.alloc(u64, scheduled_words);
    }
    @memset(workspace.reverse_scheduled, 0);
    workspace.reverse_cursor_exclusive = @as(usize, @intCast(target)) + 1;
}

fn reverseCell(workspace: *MatchWorkspace, node: IndexInt) !usize {
    const NoSlot = std.math.maxInt(u32);
    const existing = workspace.reverse_slot_by_node[node];
    if (existing != NoSlot) return existing;
    const slot: u32 = @intCast(workspace.reverse_cell_nodes.items.len);
    try workspace.reverse_cell_nodes.append(workspace.allocator, node);
    try workspace.reverse_cells.appendNTimes(workspace.allocator, 0, workspace.reverse_word_count * 3);
    workspace.reverse_slot_by_node[node] = slot;
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
    const index: usize = @intCast(node);
    workspace.reverse_scheduled[index / 64] |= @as(u64, 1) << @intCast(index % 64);
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

fn popHighestScheduled(workspace: *MatchWorkspace) ?IndexInt {
    while (workspace.reverse_cursor_exclusive != 0) {
        const upper = workspace.reverse_cursor_exclusive - 1;
        const word_index = upper / 64;
        const bit_limit: u6 = @intCast(upper % 64);
        const through = if (bit_limit == 63) std.math.maxInt(u64) else (@as(u64, 1) << (bit_limit + 1)) - 1;
        const word = workspace.reverse_scheduled[word_index] & through;
        if (word != 0) {
            const bit_index: usize = 63 - @clz(word);
            const index = word_index * 64 + bit_index;
            workspace.reverse_scheduled[word_index] &= ~(@as(u64, 1) << @intCast(bit_index));
            workspace.reverse_cursor_exclusive = index;
            return @intCast(index);
        }
        workspace.reverse_cursor_exclusive = word_index * 64;
    }
    return null;
}

fn evaluateReversePredicates(comptime Doc: type, doc: *const Doc, selector: ast.Selector, node: IndexInt, wanted: []const u64, workspace: *MatchWorkspace) !void {
    @memset(workspace.reverse_local, 0);
    @memset(workspace.reverse_seen_predicates, 0);
    workspace.node_ctx.begin(doc.allocator, 0);

    for (wanted, 0..) |wanted_word, word_index| {
        var pending = wanted_word;
        while (pending != 0) {
            const local_bit: usize = @intCast(@ctz(pending));
            pending &= pending - 1;
            const absolute = word_index * 64 + local_bit;
            if (absolute >= selector.compounds.len) continue;
            const predicate_id: usize = workspace.predicate_plan.state_ids[absolute];
            const seen_bit = @as(u64, 1) << @intCast(predicate_id % 64);
            if ((workspace.reverse_seen_predicates[predicate_id / 64] & seen_bit) != 0) continue;
            workspace.reverse_seen_predicates[predicate_id / 64] |= seen_bit;
            workspace.stats.local_unique_predicate_evals += 1;
            const representative: usize = @intCast(workspace.predicate_plan.representatives[predicate_id]);
            if (try matchesCompoundRtlCached(Doc, doc, selector, selector.compounds[representative], node, &workspace.node_ctx)) {
                for (workspace.reverse_local, wanted, workspace.predicate_plan.predicateMaskConst(predicate_id)) |*dst, eligible, mask| dst.* |= eligible & mask;
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
    workspace.stats.topology_parent_builds += 1;
    var previous: IndexInt = InvalidIndex;
    var cursor: IndexInt = parent + 1;
    const end = doc.nodes[parent].subtree_end;
    while (cursor <= end and cursor < doc.nodes.len) {
        const raw = &doc.nodes[cursor];
        if (raw.parent == parent) {
            workspace.stats.topology_child_visits += 1;
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
        ctx.begin(doc.allocator, 0);
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
    probe: AttrProbe = .{},
    child_position: usize = 0,
    last_child_cache: ?bool = null,

    pub fn begin(self: *@This(), allocator: std.mem.Allocator, child_position: usize) void {
        if (self.scratch == null) self.scratch = std.heap.ArenaAllocator.init(allocator);
        _ = self.scratch.?.reset(.retain_capacity);
        self.probe = .{};
        self.child_position = child_position;
        self.last_child_cache = null;
    }

    pub fn deinit(self: *@This()) void {
        if (self.scratch) |*scratch| scratch.deinit();
        self.scratch = null;
    }
};

const PseudoMode = enum { rtl, forward };

pub fn matchesCompoundForward(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, ctx: *NodeContext) !bool {
    std.debug.assert(ctx.scratch != null);
    return matchesCompoundCore(Doc, doc, selector, comp, node_index, ctx.scratch.?.allocator(), &ctx.probe, .forward, ctx.child_position, &ctx.last_child_cache);
}

fn matchesCompoundRtlCached(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, ctx: *NodeContext) !bool {
    std.debug.assert(ctx.scratch != null);
    return matchesCompoundCore(Doc, doc, selector, comp, node_index, ctx.scratch.?.allocator(), &ctx.probe, .rtl, 0, &ctx.last_child_cache);
}

fn matchesCompoundCore(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, scratch_alloc: std.mem.Allocator, attr_probe: *AttrProbe, pseudo_mode: PseudoMode, child_position: usize, last_child_cache: *?bool) !bool {
    if (!doc.nodes[node_index].isElement(node_index)) return false;
    const node = &doc.nodes[node_index];
    var collected_attrs: CollectedAttrs = .{};
    const use_collected = prepareCollectedAttrs(selector, comp, &collected_attrs);
    const collected_ptr: ?*CollectedAttrs = if (use_collected) &collected_attrs else null;

    if (comp.hasTag()) {
        const node_name = node.name_or_text.slice(doc.source);
        if (!tagMatches(Doc, selector.source, comp, node_name)) return false;
    }

    if (comp.hasId()) {
        const id = comp.id.slice(selector.source);
        const value = try attrValueByNameFrom(
            doc,
            node,
            scratch_alloc,
            attr_probe,
            collected_ptr,
            "id",
        ) orelse return false;
        if (!std.mem.eql(u8, value, id)) return false;
    }

    if (comp.class_len != 0) {
        const class_attr = try attrValueByNameFrom(
            doc,
            node,
            scratch_alloc,
            attr_probe,
            collected_ptr,
            "class",
        ) orelse return false;
        if (!hasAllClassesOnePass(selector, comp, class_attr)) return false;
    }

    var attr_i: IndexInt = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!try matchesAttrSelector(doc, node, scratch_alloc, attr_probe, collected_ptr, selector.source, attr_sel)) return false;
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
        if (try matchesNotSimple(doc, node, scratch_alloc, attr_probe, collected_ptr, selector.source, item)) return false;
    }

    return true;
}

fn matchesNotSimple(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    item: ast.NotSimple,
) !bool {
    return switch (item.kind) {
        .tag => std.ascii.eqlIgnoreCase(node.name_or_text.slice(doc.source), item.text.slice(selector_source)),
        .id => blk: {
            const value = (try attrValueByNameFrom(doc, node, allocator, probe, collected, "id")) orelse break :blk false;
            break :blk std.mem.eql(u8, value, item.text.slice(selector_source));
        },
        .class => try hasClass(doc, node, allocator, probe, collected, item.text.slice(selector_source)),
        .attr => try matchesAttrSelector(doc, node, allocator, probe, collected, selector_source, item.attr),
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
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    sel: ast.AttrSelector,
) !bool {
    const name = sel.name.slice(selector_source);
    const raw = (try attrValueByNameFrom(doc, node, allocator, probe, collected, name)) orelse return false;
    const value = sel.value.slice(selector_source);
    return evalAttrOp(raw, value, sel.op, sel.case);
}

fn hasClass(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    class_name: []const u8,
) !bool {
    const class_attr = (try attrValueByNameFrom(doc, node, allocator, probe, collected, "class")) orelse return false;
    return tables.tokenIncludesAsciiWhitespace(class_attr, class_name);
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
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    name: []const u8,
) !?[]const u8 {
    if (collected) |c| {
        if (findCollectedEntry(c, name)) |idx| {
            if (c.materialized or c.looked[idx]) return c.values[idx];

            if (!c.requested_once) {
                const value = try attrValueByName(doc, node, allocator, probe, name);
                c.values[idx] = value;
                c.looked[idx] = true;
                c.requested_once = true;
                return value;
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
            return c.values[idx];
        }
    }
    return try attrValueByName(doc, node, allocator, probe, name);
}

fn attrValueByName(doc: anytype, node: anytype, allocator: std.mem.Allocator, noalias probe: *AttrProbe, name: []const u8) !?[]const u8 {
    if (findProbeEntry(probe, name)) |idx| {
        return probe.entries[idx].value;
    }

    if (!probe.overflow and probe.count < MaxProbeEntries) {
        const result = try attr.getAttrValue(doc, node, name, allocator);
        const value = if (result) |r| r.value else null;
        const idx = probe.count;
        probe.entries[idx] = .{
            .name = name,
            .value = value,
        };
        probe.count += 1;
        return value;
    }

    probe.overflow = true;
    // Fallback for very large compounds bypasses memoization once the fixed probe
    // budget is exhausted. Rare expanding entity values may use arena scratch.
    const result = try attr.getAttrValue(doc, node, name, allocator);
    return if (result) |r| r.value else null;
}

const AttrProbeEntry = struct {
    name: []const u8 = "",
    value: ?[]const u8 = null,
};

const AttrProbe = struct {
    count: usize = 0,
    overflow: bool = false,
    entries: [MaxProbeEntries]AttrProbeEntry = [_]AttrProbeEntry{.{}} ** MaxProbeEntries,
};

const CollectedAttrs = struct {
    count: usize = 0,
    requested_once: bool = false,
    materialized: bool = false,
    names: [MaxCollectedAttrs][]const u8 = undefined,
    values: [MaxCollectedAttrs]?[]const u8 = [_]?[]const u8{null} ** MaxCollectedAttrs,
    looked: [MaxCollectedAttrs]bool = [_]bool{false} ** MaxCollectedAttrs,
};

fn prepareCollectedAttrs(selector: ast.Selector, comp: ast.Compound, out: *CollectedAttrs) bool {
    out.* = .{};

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

fn findProbeEntry(noalias probe: *const AttrProbe, needle: []const u8) ?usize {
    var i: usize = 0;
    while (i < probe.count) : (i += 1) {
        const entry = probe.entries[i];
        if (entry.name.len != needle.len) continue;
        if (entry.name.len != 0 and std.ascii.toLower(entry.name[0]) != std.ascii.toLower(needle[0])) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, needle)) return i;
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

test "predicate plan sizes masks by unique predicate count" {
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
    try std.testing.expectEqual(plan.word_count, plan.masks.len);
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
