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

pub const TraversalBounds = struct {
    /// First node index visited by the traversal.
    start: IndexInt,
    /// Exclusive end index that terminates the traversal.
    end_excl: IndexInt,
};

pub fn traversalBounds(comptime Doc: type, doc: *const Doc, scope_root: IndexInt) TraversalBounds {
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.len) {
        return .{ .start = 1, .end_excl = 1 };
    }
    // Queries walk the document's preorder node array. Scoped queries stay
    // inside the subtree range computed during parse.
    const start: IndexInt = if (scope_root == InvalidIndex) 1 else scope_root + 1;
    const end_excl: IndexInt = if (scope_root == InvalidIndex)
        @as(IndexInt, @intCast(doc.nodes.len))
    else
        doc.nodes[scope_root].subtree_end + 1;
    return .{ .start = start, .end_excl = end_excl };
}

pub fn tagMatches(comptime Doc: type, selector_source: []const u8, comp: ast.Compound, node_name: []const u8) bool {
    const tag = comp.tag.slice(selector_source);
    const tag_key: u64 = if (comp.tag_key != 0) comp.tag_key else tags.first8KeyWithMode(tag, false);
    const node_key = tags.first8KeyWithMode(node_name, Doc.Options.non_destructive);
    return tags.equalByLenAndKeyIgnoreCase(node_name, node_key, tag, tag_key);
}

pub fn evalAttrOp(raw: []const u8, value: []const u8, op: ast.AttrOp, case: ast.AttrCase) bool {
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

pub fn matchesAttrSelectorDebug(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    selector_source: []const u8,
    sel: ast.AttrSelector,
) !bool {
    const name = sel.name.slice(selector_source);
    const raw = (try attr.getAttrValue(doc, node, name, allocator)) orelse return false;
    const value = sel.value.slice(selector_source);
    return evalAttrOp(raw, value, sel.op, sel.case);
}

pub fn matchesNotSimpleCommon(ctx: anytype, item: ast.NotSimple) !bool {
    return switch (item.kind) {
        .tag => std.ascii.eqlIgnoreCase(ctx.nodeName(), item.text.slice(ctx.selector_source)),
        .id => blk: {
            const id = item.text.slice(ctx.selector_source);
            const v = (try ctx.getAttrValue("id")) orelse break :blk false;
            break :blk std.mem.eql(u8, v, id);
        },
        .class => try ctx.classMatches(item.text.slice(ctx.selector_source)),
        .attr => try ctx.attrMatches(item.attr),
    };
}

pub fn NotSimpleCtxFast(comptime Doc: type, comptime Node: type) type {
    return struct {
        doc: Doc,
        node: Node,
        allocator: std.mem.Allocator,
        probe: *AttrProbe,
        collected: ?*CollectedAttrs,
        selector_source: []const u8,

        fn nodeName(self: @This()) []const u8 {
            return self.node.name_or_text.slice(self.doc.source);
        }

        fn getAttrValue(self: @This(), name: []const u8) !?[]const u8 {
            return attrValueByNameFrom(self.doc, self.node, self.allocator, self.probe, self.collected, name);
        }

        fn classMatches(self: @This(), class_name: []const u8) !bool {
            return hasClass(self.doc, self.node, self.allocator, self.probe, self.collected, class_name);
        }

        fn attrMatches(self: @This(), sel: ast.AttrSelector) !bool {
            return matchesAttrSelector(self.doc, self.node, self.allocator, self.probe, self.collected, self.selector_source, sel);
        }
    };
}

pub fn NotSimpleCtxDebug(comptime Doc: type, comptime Node: type) type {
    return struct {
        doc: Doc,
        node: Node,
        allocator: std.mem.Allocator,
        selector_source: []const u8,

        fn nodeName(self: @This()) []const u8 {
            return self.node.name_or_text.slice(self.doc.source);
        }

        fn getAttrValue(self: @This(), name: []const u8) !?[]const u8 {
            return try attr.getAttrValue(self.doc, self.node, name, self.allocator);
        }

        fn classMatches(self: @This(), class_name: []const u8) !bool {
            const class_attr = (try attr.getAttrValue(self.doc, self.node, "class", self.allocator)) orelse return false;
            return tables.tokenIncludesAsciiWhitespace(class_attr, class_name);
        }

        fn attrMatches(self: @This(), sel: ast.AttrSelector) !bool {
            return matchesAttrSelectorDebug(self.doc, self.node, self.allocator, self.selector_source, sel);
        }
    };
}

/// Returns first matching node index for `selector` within optional `scope_root`.
pub fn firstMatchIndex(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, scope_root: IndexInt) !?IndexInt {
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.len) return null;
    var workspace = MatchWorkspace.init(doc.allocator);
    defer workspace.deinit();
    const bounds = traversalBounds(Doc, doc, scope_root);
    var i = bounds.start;
    while (i < bounds.end_excl and i < doc.nodes.len) : (i += 1) {
        if (!doc.nodes[i].isElement(i)) continue;
        if (!candidateCouldMatch(Doc, doc, selector, i)) continue;
        if (try matchesSelectorAtWithWorkspace(Doc, doc, selector, i, scope_root, &workspace)) return i;
    }
    return null;
}

/// Cheap rejection using only rightmost compound tag constraints.
pub fn candidateCouldMatch(comptime Doc: type, doc: *const Doc, selector: ast.Selector, node_index: IndexInt) bool {
    const node_name = doc.nodes[node_index].name_or_text.slice(doc.source);
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const rightmost: usize = @intCast(group.compound_start + group.compound_len - 1);
        const comp = selector.compounds[rightmost];
        if (!comp.hasTag() or tagMatches(Doc, selector.source, comp, node_name)) return true;
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
    try workspace.ensureReady(selector);
    workspace.prepare(selector, scope_root);
    const scratch = &workspace.scratch.?;

    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const rightmost = group.compound_len - 1;
        if (group.compound_len == 1) {
            const comp = selector.compounds[group.compound_start];
            if (try matchesCompound(Doc, doc, selector, comp, node_index, scratch) and
                (comp.combinator == .none or matchesScopeAnchor(doc, comp.combinator, node_index, scope_root))) return true;
            continue;
        }
        if (try matchGroupFromRight(Doc, doc, selector, group, rightmost, node_index, scope_root, scratch, workspace)) return true;
    }
    return false;
}

/// Matches one left-to-right group prefix at a specific node using the RTL engine.
/// Used once when seeding a scoped forward query from ancestors outside its scan.
pub fn matchesPrefixAt(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, group: ast.Group, prefix_len: usize, node_index: IndexInt, workspace: *MatchWorkspace) !bool {
    if (prefix_len == 0 or prefix_len > group.compound_len or node_index >= doc.nodes.len) return false;
    try workspace.ensureReady(selector);
    workspace.prepare(selector, InvalidIndex);
    const partial: ast.Group = .{
        .compound_start = group.compound_start,
        .compound_len = @intCast(prefix_len),
    };
    return matchGroupFromRight(
        Doc,
        doc,
        selector,
        partial,
        @intCast(prefix_len - 1),
        node_index,
        InvalidIndex,
        &workspace.scratch.?,
        workspace,
    );
}

pub const MatchWorkspace = struct {
    allocator: std.mem.Allocator,
    scratch: ?std.heap.ArenaAllocator = null,
    segments: std.ArrayListUnmanaged(RtlSegment) = .empty,
    solve_cache: []IndexInt = &.{},
    summary_cache: []IndexInt = &.{},
    eval_frames: std.ArrayListUnmanaged(EvalFrame) = .empty,
    topology_prev: std.AutoHashMapUnmanaged(IndexInt, IndexInt) = .empty,
    topology_parents: std.AutoHashMapUnmanaged(IndexInt, void) = .empty,
    stats: MatchStats = .{},
    prepared_source: usize = 0,
    prepared_compounds: usize = 0,
    prepared_scope: IndexInt = InvalidIndex,
    prepared_group_start: IndexInt = InvalidIndex,
    prepared_prefix_len: IndexInt = 0,
    prepared_node_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn ensureReady(self: *@This(), selector: ast.Selector) !void {
        if (self.scratch != null) return;
        _ = selector;
        self.scratch = std.heap.ArenaAllocator.init(self.allocator);
    }

    pub fn deinit(self: *@This()) void {
        if (self.scratch) |*scratch| scratch.deinit();
        self.segments.deinit(self.allocator);
        self.segments = .empty;
        if (self.solve_cache.len != 0) self.allocator.free(self.solve_cache);
        self.solve_cache = &.{};
        if (self.summary_cache.len != 0) self.allocator.free(self.summary_cache);
        self.summary_cache = &.{};
        self.eval_frames.deinit(self.allocator);
        self.eval_frames = .empty;
        self.topology_prev.deinit(self.allocator);
        self.topology_prev = .empty;
        self.topology_parents.deinit(self.allocator);
        self.topology_parents = .empty;
        self.scratch = null;
    }

    fn prepare(self: *@This(), selector: ast.Selector, scope_root: IndexInt) void {
        const source_id = @intFromPtr(selector.source.ptr);
        const compounds_id = @intFromPtr(selector.compounds.ptr);
        if (self.prepared_source == source_id and self.prepared_compounds == compounds_id and self.prepared_scope == scope_root) return;
        self.prepared_source = source_id;
        self.prepared_compounds = compounds_id;
        self.prepared_scope = scope_root;
        self.prepared_group_start = InvalidIndex;
        self.topology_prev.clearRetainingCapacity();
        self.topology_parents.clearRetainingCapacity();
    }
};

pub const MatchStats = struct {
    local_predicate_evals: usize = 0,
    rtl_segment_first_evals: usize = 0,
    rtl_segment_cache_hits: usize = 0,
    rtl_ancestor_summary_first_evals: usize = 0,
    rtl_ancestor_summary_cache_hits: usize = 0,
    rtl_sibling_summary_first_evals: usize = 0,
    rtl_sibling_summary_cache_hits: usize = 0,
    rtl_parent_steps: usize = 0,
    rtl_prev_sibling_steps: usize = 0,
    topology_parent_builds: usize = 0,
    topology_child_visits: usize = 0,
};

const RtlSegment = struct {
    left_rel: IndexInt,
    right_rel: IndexInt,
    boundary: ast.Combinator,
};

const Uncomputed = InvalidIndex;
const Failed = InvalidIndex - 1;
const EvalKind = enum(u8) { solve, summary };

const EvalFrame = struct {
    kind: EvalKind,
    segment: usize,
    node: IndexInt,
    phase: u8 = 0,
    anchor: IndexInt = Failed,
    child_result: IndexInt = Failed,
};

fn matchGroupFromRight(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, group: ast.Group, rel_index: IndexInt, node_index: IndexInt, scope_root: IndexInt, scratch: *std.heap.ArenaAllocator, workspace: *MatchWorkspace) !bool {
    if (group.compound_len == 0) {
        @branchHint(.cold);
        return false;
    }
    if (!groupHasExistential(selector, group, rel_index)) {
        return matchDeterministicGroup(Doc, doc, selector, group, rel_index, node_index, scope_root, scratch, &workspace.stats);
    }
    try prepareSegments(workspace, selector, group, rel_index, doc.nodes.len);
    workspace.eval_frames.clearRetainingCapacity();
    try workspace.eval_frames.append(workspace.allocator, .{ .kind = .solve, .segment = 0, .node = node_index });

    var final_result: IndexInt = Failed;
    while (workspace.eval_frames.items.len != 0) {
        const frame_index = workspace.eval_frames.items.len - 1;
        const snapshot = workspace.eval_frames.items[frame_index];
        const cache = if (snapshot.kind == .solve) workspace.solve_cache else workspace.summary_cache;
        const cache_index = snapshot.segment * doc.nodes.len + @as(usize, @intCast(snapshot.node));
        if (cache[cache_index] != Uncomputed) {
            if (snapshot.kind == .solve) workspace.stats.rtl_segment_cache_hits += 1 else {
                const boundary = workspace.segments.items[snapshot.segment].boundary;
                if (boundary == .descendant) workspace.stats.rtl_ancestor_summary_cache_hits += 1 else workspace.stats.rtl_sibling_summary_cache_hits += 1;
            }
            completeWitness(workspace, cache[cache_index], &final_result);
            continue;
        }

        var frame = &workspace.eval_frames.items[frame_index];
        switch (frame.kind) {
            .solve => switch (frame.phase) {
                0 => {
                    workspace.stats.rtl_segment_first_evals += 1;
                    const segment = workspace.segments.items[frame.segment];
                    const anchor = try evalSegment(Doc, doc, selector, group, segment, frame.node, scratch, &workspace.stats);
                    if (anchor == Failed) {
                        finishWitness(workspace, cache_index, Failed, &final_result);
                        continue;
                    }
                    if (frame.segment + 1 == workspace.segments.items.len) {
                        const left = selector.compounds[group.compound_start + segment.left_rel];
                        const value = if (left.combinator == .none or matchesScopeAnchor(doc, left.combinator, anchor, scope_root)) anchor else Failed;
                        finishWitness(workspace, cache_index, value, &final_result);
                        continue;
                    }
                    frame.anchor = anchor;
                    frame.phase = 1;
                    try workspace.eval_frames.append(workspace.allocator, .{ .kind = .summary, .segment = frame.segment, .node = anchor });
                },
                else => finishWitness(workspace, cache_index, if (frame.child_result == Failed) Failed else frame.anchor, &final_result),
            },
            .summary => switch (frame.phase) {
                0 => {
                    const boundary = workspace.segments.items[frame.segment].boundary;
                    const candidate = if (boundary == .descendant)
                        parentElement(doc, frame.node)
                    else
                        try prevElementSiblingAccelerated(Doc, doc, frame.node, workspace);
                    if (candidate == null) {
                        finishWitness(workspace, cache_index, Failed, &final_result);
                        continue;
                    }
                    if (boundary == .descendant) {
                        workspace.stats.rtl_ancestor_summary_first_evals += 1;
                        workspace.stats.rtl_parent_steps += 1;
                    } else {
                        workspace.stats.rtl_sibling_summary_first_evals += 1;
                        workspace.stats.rtl_prev_sibling_steps += 1;
                    }
                    frame.anchor = candidate.?;
                    frame.phase = 1;
                    try workspace.eval_frames.append(workspace.allocator, .{ .kind = .solve, .segment = frame.segment + 1, .node = candidate.? });
                },
                1 => {
                    if (frame.child_result != Failed) {
                        finishWitness(workspace, cache_index, frame.anchor, &final_result);
                        continue;
                    }
                    frame.phase = 2;
                    try workspace.eval_frames.append(workspace.allocator, .{ .kind = .summary, .segment = frame.segment, .node = frame.anchor });
                },
                else => finishWitness(workspace, cache_index, frame.child_result, &final_result),
            },
        }
    }
    return final_result != Failed;
}

fn prepareSegments(workspace: *MatchWorkspace, selector: ast.Selector, group: ast.Group, rel_index: IndexInt, node_count: usize) !void {
    if (workspace.prepared_group_start == group.compound_start and workspace.prepared_prefix_len == rel_index + 1 and workspace.prepared_node_count == node_count) return;
    workspace.segments.clearRetainingCapacity();
    var right = rel_index;
    while (true) {
        var left = right;
        while (left > 0) {
            const relation = selector.compounds[group.compound_start + left].combinator;
            if (relation == .descendant or relation == .sibling) break;
            left -= 1;
        }
        const boundary = selector.compounds[group.compound_start + left].combinator;
        try workspace.segments.append(workspace.allocator, .{ .left_rel = left, .right_rel = right, .boundary = boundary });
        if (left == 0) break;
        right = left - 1;
    }
    const cell_count = try std.math.mul(usize, workspace.segments.items.len, node_count);
    if (workspace.solve_cache.len != cell_count) {
        if (workspace.solve_cache.len != 0) workspace.allocator.free(workspace.solve_cache);
        workspace.solve_cache = try workspace.allocator.alloc(IndexInt, cell_count);
        if (workspace.summary_cache.len != 0) workspace.allocator.free(workspace.summary_cache);
        workspace.summary_cache = try workspace.allocator.alloc(IndexInt, cell_count);
    }
    @memset(workspace.solve_cache, Uncomputed);
    @memset(workspace.summary_cache, Uncomputed);
    workspace.prepared_group_start = group.compound_start;
    workspace.prepared_prefix_len = rel_index + 1;
    workspace.prepared_node_count = node_count;
}

fn completeWitness(workspace: *MatchWorkspace, result: IndexInt, final_result: *IndexInt) void {
    _ = workspace.eval_frames.pop();
    if (workspace.eval_frames.items.len == 0) final_result.* = result else workspace.eval_frames.items[workspace.eval_frames.items.len - 1].child_result = result;
}

fn finishWitness(workspace: *MatchWorkspace, cache_index: usize, result: IndexInt, final_result: *IndexInt) void {
    const frame = workspace.eval_frames.items[workspace.eval_frames.items.len - 1];
    if (frame.kind == .solve) workspace.solve_cache[cache_index] = result else workspace.summary_cache[cache_index] = result;
    completeWitness(workspace, result, final_result);
}

fn evalSegment(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, segment: RtlSegment, start_node: IndexInt, scratch: *std.heap.ArenaAllocator, stats: *MatchStats) !IndexInt {
    var rel = segment.right_rel;
    var node = start_node;
    while (true) {
        stats.local_predicate_evals += 1;
        if (!try matchesCompound(Doc, doc, selector, selector.compounds[group.compound_start + rel], node, scratch)) return Failed;
        if (rel == segment.left_rel) return node;
        node = switch (selector.compounds[group.compound_start + rel].combinator) {
            .child => parentElement(doc, node),
            .adjacent => prevElementSibling(doc, node),
            else => unreachable,
        } orelse return Failed;
        rel -= 1;
    }
}

fn prevElementSiblingAccelerated(comptime Doc: type, doc: *const Doc, node_index: IndexInt, workspace: *MatchWorkspace) !?IndexInt {
    const RawNode = @TypeOf(doc.nodes[0]);
    if (comptime @FieldType(RawNode, "prev_sibling") != void) {
        const previous = doc.nodes[node_index].prev_sibling;
        return if (previous == InvalidIndex) null else previous;
    }
    if (workspace.topology_prev.get(node_index)) |previous| return if (previous == InvalidIndex) null else previous;
    const parent = doc.nodes[node_index].parent;
    if (parent == InvalidIndex or parent >= doc.nodes.len) return null;
    if (!workspace.topology_parents.contains(parent)) {
        try workspace.topology_parents.put(workspace.allocator, parent, {});
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
                }
                cursor = raw.subtree_end + 1;
            } else {
                cursor += 1;
            }
        }
    }
    const previous = workspace.topology_prev.get(node_index) orelse InvalidIndex;
    return if (previous == InvalidIndex) null else previous;
}

fn groupHasExistential(selector: ast.Selector, group: ast.Group, rel_index: IndexInt) bool {
    var rel: IndexInt = 1;
    while (rel <= rel_index) : (rel += 1) {
        const combinator = selector.compounds[group.compound_start + rel].combinator;
        if (combinator == .descendant or combinator == .sibling) return true;
    }
    return false;
}

fn matchDeterministicGroup(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, start_rel: IndexInt, start_node: IndexInt, scope_root: IndexInt, scratch: *std.heap.ArenaAllocator, stats: *MatchStats) !bool {
    var rel = start_rel;
    var node = start_node;
    while (true) {
        const comp = selector.compounds[group.compound_start + rel];
        stats.local_predicate_evals += 1;
        if (!try matchesCompound(Doc, doc, selector, comp, node, scratch)) return false;
        if (rel == 0) return comp.combinator == .none or matchesScopeAnchor(doc, comp.combinator, node, scope_root);
        node = switch (comp.combinator) {
            .child => parentElement(doc, node),
            .adjacent => prevElementSibling(doc, node),
            else => unreachable,
        } orelse return false;
        rel -= 1;
    }
}

pub const ForwardNodeContext = struct {
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

fn matchesCompound(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, scratch: *std.heap.ArenaAllocator) !bool {
    if (!doc.nodes[node_index].isElement(node_index)) return false;
    _ = scratch.reset(.retain_capacity);
    var attr_probe: AttrProbe = .{};
    var last_child_cache: ?bool = null;
    return matchesCompoundCore(Doc, doc, selector, comp, node_index, scratch.allocator(), &attr_probe, .rtl, 0, &last_child_cache);
}

pub fn matchesCompoundForward(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: IndexInt, ctx: *ForwardNodeContext) !bool {
    std.debug.assert(ctx.scratch != null);
    return matchesCompoundCore(Doc, doc, selector, comp, node_index, ctx.scratch.?.allocator(), &ctx.probe, .forward, ctx.child_position, &ctx.last_child_cache);
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
    const Ctx = NotSimpleCtxFast(@TypeOf(doc), @TypeOf(node));
    const ctx = Ctx{
        .doc = doc,
        .node = node,
        .allocator = allocator,
        .probe = probe,
        .collected = collected,
        .selector_source = selector_source,
    };
    return try matchesNotSimpleCommon(ctx, item);
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
                break;
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
        const value = try attr.getAttrValue(doc, node, name, allocator);
        const idx = probe.count;
        probe.entries[idx] = .{
            .name = name,
            .value = value,
        };
        probe.count += 1;
        return value;
    }

    probe.overflow = true;
    // Fallback for very large compounds still stays allocation-free; we simply
    // bypass memoization once the fixed probe budget is exhausted.
    return try attr.getAttrValue(doc, node, name, allocator);
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
    try std.testing.expectEqual(@as(?IndexInt, 2), try firstMatchIndex(@TypeOf(doc), &doc, sel, InvalidIndex));
    try std.testing.expect(try matchesSelectorAt(@TypeOf(doc), &doc, sel, 2, InvalidIndex));
    try std.testing.expect(!try matchesSelectorAt(@TypeOf(doc), &doc, sel, 4, InvalidIndex));
    try std.testing.expect(!try matchesSelectorAt(@TypeOf(doc), &doc, sel, @intCast(doc.nodes.len), InvalidIndex));
}
