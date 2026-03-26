const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr_inline = @import("../html/attr_inline.zig");
const common = @import("../common.zig");

// SAFETY: Selector AST indices are trusted to be internally consistent
// (group/compound/predicate ranges). Document node indices are validated
// before use; debug asserts guard scope bounds in key entry points.

const InvalidIndex: u32 = common.InvalidIndex;
const MaxProbeEntries: usize = 24;
const MaxCollectedAttrs: usize = 24;
const LocalMatchFrameCap: usize = 48;
const HashId: u32 = tables.hashIgnoreCaseAscii("id");
const HashClass: u32 = tables.hashIgnoreCaseAscii("class");
const EnableQueryAccel = true;
// Tag-index accel has shown unstable behavior under optimized bench builds.
// Keep id accel enabled and fall back to scan for tag-only pruning for now.
const EnableTagQueryAccel = false;
const EnableMultiAttrCollect = true;
const isElementLike = common.isElementLike;
const matchesScopeAnchor = common.matchesScopeAnchor;
const parentElement = common.parentElement;
const prevElementSibling = common.prevElementSibling;
const nextElementSibling = common.nextElementSibling;

pub const TraversalBounds = struct {
    start: u32,
    end_excl: u32,
};

pub fn traversalBounds(comptime Doc: type, doc: *const Doc, scope_root: u32) TraversalBounds {
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.items.len) {
        return .{ .start = 1, .end_excl = 1 };
    }
    const start: u32 = if (scope_root == InvalidIndex) 1 else scope_root + 1;
    const end_excl: u32 = if (scope_root == InvalidIndex)
        @as(u32, @intCast(doc.nodes.items.len))
    else
        doc.nodes.items[scope_root].subtree_end + 1;
    return .{ .start = start, .end_excl = end_excl };
}

pub fn tagMatches(selector_source: []const u8, comp: ast.Compound, node_name: []const u8) bool {
    const tag = comp.tag.slice(selector_source);
    const tag_key: u64 = if (comp.tag_key != 0) comp.tag_key else tags.first8Key(tag);
    const node_key = tags.first8Key(node_name);
    return tags.equalByLenAndKeyIgnoreCase(node_name, node_key, tag, tag_key);
}

pub fn evalAttrOp(raw: []const u8, value: []const u8, op: ast.AttrOp) bool {
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

pub fn matchesAttrSelectorDebug(
    doc: anytype,
    node: anytype,
    selector_source: []const u8,
    sel: ast.AttrSelector,
) bool {
    const name = sel.name.slice(selector_source);
    const raw = attr_inline.getAttrValue(doc, node, name) orelse return false;
    const value = sel.value.slice(selector_source);
    return evalAttrOp(raw, value, sel.op);
}

pub fn matchesNotSimpleCommon(ctx: anytype, item: ast.NotSimple) bool {
    return switch (item.kind) {
        .tag => tables.eqlIgnoreCaseAscii(ctx.nodeName(), item.text.slice(ctx.selector_source)),
        .id => blk: {
            const id = item.text.slice(ctx.selector_source);
            const v = ctx.getAttrValue("id") orelse break :blk false;
            break :blk std.mem.eql(u8, v, id);
        },
        .class => ctx.classMatches(item.text.slice(ctx.selector_source)),
        .attr => ctx.attrMatches(item.attr),
    };
}

pub fn NotSimpleCtxFast(comptime Doc: type, comptime Node: type) type {
    return struct {
        doc: Doc,
        node: Node,
        probe: *AttrProbe,
        collected: ?*CollectedAttrs,
        selector_source: []const u8,

        fn nodeName(self: @This()) []const u8 {
            return self.node.name_or_text.slice(self.doc.source);
        }

        fn getAttrValue(self: @This(), name: []const u8) ?[]const u8 {
            const hash = if (std.mem.eql(u8, name, "id")) HashId else tables.hashIgnoreCaseAscii(name);
            return attrValueByHashFrom(self.doc, self.node, self.probe, self.collected, name, hash);
        }

        fn classMatches(self: @This(), class_name: []const u8) bool {
            return hasClass(self.doc, self.node, self.probe, self.collected, class_name);
        }

        fn attrMatches(self: @This(), sel: ast.AttrSelector) bool {
            return matchesAttrSelector(self.doc, self.node, self.probe, self.collected, self.selector_source, sel);
        }
    };
}

pub fn NotSimpleCtxDebug(comptime Doc: type, comptime Node: type) type {
    return struct {
        doc: Doc,
        node: Node,
        selector_source: []const u8,

        fn nodeName(self: @This()) []const u8 {
            return self.node.name_or_text.slice(self.doc.source);
        }

        fn getAttrValue(self: @This(), name: []const u8) ?[]const u8 {
            return attr_inline.getAttrValue(self.doc, self.node, name);
        }

        fn classMatches(self: @This(), class_name: []const u8) bool {
            const class_attr = attr_inline.getAttrValue(self.doc, self.node, "class") orelse return false;
            return tables.tokenIncludesAsciiWhitespace(class_attr, class_name);
        }

        fn attrMatches(self: @This(), sel: ast.AttrSelector) bool {
            return matchesAttrSelectorDebug(self.doc, self.node, self.selector_source, sel);
        }
    };
}

/// Returns first matching node index for `selector` within optional `scope_root`.
pub fn queryOneIndex(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, scope_root: u32) ?u32 {
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.items.len) return null;
    var best: ?u32 = null;
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const idx = firstMatchForGroup(Doc, doc, selector, group, scope_root) orelse continue;
        if (best == null or idx < best.?) best = idx;
    }
    return best;
}

/// Returns whether `node_index` matches any selector group within scope.
pub fn matchesSelectorAt(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, node_index: u32, scope_root: u32) bool {
    if (scope_root != InvalidIndex and scope_root >= doc.nodes.items.len) return false;
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const rightmost = group.compound_len - 1;
        if (matchGroupFromRight(Doc, doc, selector, group, rightmost, node_index, scope_root)) return true;
    }
    return false;
}

const MatchFramePhase = enum(u8) {
    enter,
    scan_descendant,
    scan_sibling,
};

const MatchFrame = struct {
    rel_index: u32,
    node_index: u32,
    phase: MatchFramePhase = .enter,
    cursor: u32 = InvalidIndex,
};

fn matchGroupFromRight(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, group: ast.Group, rel_index: u32, node_index: u32, scope_root: u32) bool {
    if (group.compound_len == 0) {
        @branchHint(.cold);
        return false;
    }

    const needed_frames: usize = @intCast(group.compound_len);
    var local_frames: [LocalMatchFrameCap]MatchFrame = undefined;
    var heap_frames: ?[]MatchFrame = null;
    defer if (heap_frames) |frames| std.heap.page_allocator.free(frames);

    const frames: []MatchFrame = if (needed_frames <= LocalMatchFrameCap)
        local_frames[0..needed_frames]
    else blk: {
        @branchHint(.cold);
        const buf = std.heap.page_allocator.alloc(MatchFrame, needed_frames) catch {
            @branchHint(.cold);
            return false;
        };
        heap_frames = buf;
        break :blk buf;
    };

    var depth: usize = 1;
    frames[0] = .{
        .rel_index = rel_index,
        .node_index = node_index,
    };

    while (depth != 0) {
        var frame = &frames[depth - 1];
        switch (frame.phase) {
            .enter => {
                const comp_abs: usize = @intCast(group.compound_start + frame.rel_index);
                const comp = selector.compounds[comp_abs];
                if (!matchesCompound(Doc, doc, selector, comp, frame.node_index)) {
                    depth -= 1;
                    continue;
                }

                if (frame.rel_index == 0) {
                    if (comp.combinator == .none or matchesScopeAnchor(doc, comp.combinator, frame.node_index, scope_root)) return true;
                    depth -= 1;
                    continue;
                }

                switch (comp.combinator) {
                    .child => {
                        const p = parentElement(doc, frame.node_index) orelse {
                            depth -= 1;
                            continue;
                        };
                        frame.rel_index -= 1;
                        frame.node_index = p;
                    },
                    .adjacent => {
                        const prev = prevElementSibling(doc, frame.node_index) orelse {
                            depth -= 1;
                            continue;
                        };
                        frame.rel_index -= 1;
                        frame.node_index = prev;
                    },
                    .descendant => {
                        const first = parentElement(doc, frame.node_index) orelse {
                            depth -= 1;
                            continue;
                        };
                        frame.phase = .scan_descendant;
                        frame.cursor = first;
                        frames[depth] = .{
                            .rel_index = frame.rel_index - 1,
                            .node_index = first,
                        };
                        depth += 1;
                    },
                    .sibling => {
                        const first = prevElementSibling(doc, frame.node_index) orelse {
                            depth -= 1;
                            continue;
                        };
                        frame.phase = .scan_sibling;
                        frame.cursor = first;
                        frames[depth] = .{
                            .rel_index = frame.rel_index - 1,
                            .node_index = first,
                        };
                        depth += 1;
                    },
                    .none => {
                        @branchHint(.cold);
                        depth -= 1;
                    },
                }
            },
            .scan_descendant => {
                const next = parentElement(doc, frame.cursor) orelse {
                    depth -= 1;
                    continue;
                };
                frame.cursor = next;
                frames[depth] = .{
                    .rel_index = frame.rel_index - 1,
                    .node_index = next,
                };
                depth += 1;
            },
            .scan_sibling => {
                const next = prevElementSibling(doc, frame.cursor) orelse {
                    depth -= 1;
                    continue;
                };
                frame.cursor = next;
                frames[depth] = .{
                    .rel_index = frame.rel_index - 1,
                    .node_index = next,
                };
                depth += 1;
            },
        }
    }

    return false;
}

fn firstMatchForGroup(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, scope_root: u32) ?u32 {
    const rightmost = group.compound_len - 1;
    const comp_abs: usize = @intCast(group.compound_start + rightmost);
    const comp = selector.compounds[comp_abs];

    if (EnableQueryAccel and @hasDecl(Doc, "queryAccelLookupId") and comp.hasId()) {
        const id = comp.id.slice(selector.source);
        switch (doc.queryAccelLookupId(id)) {
            .hit => |idx| {
                if (inScope(doc, idx, scope_root) and matchGroupFromRight(Doc, doc, selector, group, rightmost, idx, scope_root)) {
                    return idx;
                }
                // Duplicate ids are common in real HTML. If the accelerated hit does not
                // satisfy scope/other predicates, fall back to full scan semantics.
            },
            .miss => return null,
            .unavailable => {},
        }
    }

    if (EnableTagQueryAccel and EnableQueryAccel and @hasDecl(Doc, "queryAccelLookupTag") and comp.hasTag()) {
        const tag = comp.tag.slice(selector.source);
        const tag_key = if (comp.tag_key != 0) comp.tag_key else tags.first8Key(tag);
        switch (doc.queryAccelLookupTag(tag, tag_key)) {
            .hit => |candidates| {
                if (scope_root != InvalidIndex) {
                    if (scope_root >= doc.nodes.items.len) return null;
                    const scope_end = doc.nodes.items[scope_root].subtree_end;
                    for (candidates) |idx| {
                        if (idx <= scope_root) continue;
                        if (idx > scope_end) break;
                        if (matchGroupFromRight(Doc, doc, selector, group, rightmost, idx, scope_root)) return idx;
                    }
                    return null;
                }
                for (candidates) |idx| {
                    if (matchGroupFromRight(Doc, doc, selector, group, rightmost, idx, scope_root)) return idx;
                }
                return null;
            },
            .unavailable => {},
        }
    }

    const bounds = traversalBounds(Doc, doc, scope_root);
    var i = bounds.start;
    while (i < bounds.end_excl and i < doc.nodes.items.len) : (i += 1) {
        const node = &doc.nodes.items[i];
        if (!isElementLike(node.kind)) continue;
        if (matchGroupFromRight(Doc, doc, selector, group, rightmost, i, scope_root)) return i;
    }
    return null;
}

fn inScope(doc: anytype, idx: u32, scope_root: u32) bool {
    if (idx == InvalidIndex or idx >= doc.nodes.items.len) return false;
    if (scope_root == InvalidIndex) return idx > 0;
    return idx > scope_root and idx <= doc.nodes.items[scope_root].subtree_end;
}

fn matchesCompound(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: u32) bool {
    const node = &doc.nodes.items[node_index];
    if (!isElementLike(node.kind)) return false;
    // Per-node memo for attribute probes inside one compound match.
    // This preserves selector-order short-circuiting while avoiding repeated
    // full attribute traversals for the same name.
    var attr_probe: AttrProbe = .{};
    var collected_attrs: CollectedAttrs = .{};
    const use_collected = EnableMultiAttrCollect and prepareCollectedAttrs(selector, comp, &collected_attrs);
    const collected_ptr: ?*CollectedAttrs = if (use_collected) &collected_attrs else null;

    if (comp.hasTag()) {
        const node_name = node.name_or_text.slice(doc.source);
        if (!tagMatches(selector.source, comp, node_name)) return false;
    }

    if (comp.hasId()) {
        const id = comp.id.slice(selector.source);
        const value = attrValueByHashFrom(
            doc,
            node,
            &attr_probe,
            collected_ptr,
            "id",
            HashId,
        ) orelse return false;
        if (!std.mem.eql(u8, value, id)) return false;
    }

    if (comp.class_len != 0) {
        const class_attr = attrValueByHashFrom(
            doc,
            node,
            &attr_probe,
            collected_ptr,
            "class",
            HashClass,
        ) orelse return false;
        if (!hasAllClassesOnePass(selector, comp, class_attr)) return false;
    }

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!matchesAttrSelector(doc, node, &attr_probe, collected_ptr, selector.source, attr_sel)) return false;
    }

    var pseudo_i: u32 = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        if (!matchesPseudo(doc, node_index, pseudo)) return false;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (matchesNotSimple(doc, node, &attr_probe, collected_ptr, selector.source, item)) return false;
    }

    return true;
}

fn matchesNotSimple(
    doc: anytype,
    node: anytype,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    item: ast.NotSimple,
) bool {
    const Ctx = NotSimpleCtxFast(@TypeOf(doc), @TypeOf(node));
    const ctx = Ctx{
        .doc = doc,
        .node = node,
        .probe = probe,
        .collected = collected,
        .selector_source = selector_source,
    };
    return matchesNotSimpleCommon(ctx, item);
}

pub fn matchesPseudo(doc: anytype, node_index: u32, pseudo: ast.Pseudo) bool {
    return switch (pseudo.kind) {
        .first_child => prevElementSibling(doc, node_index) == null,
        .last_child => nextElementSibling(doc, node_index) == null,
        .nth_child => blk: {
            _ = parentElement(doc, node_index) orelse break :blk false;
            var position: usize = 1;
            var prev = doc.nodes.items[node_index].prev_sibling;
            while (prev != InvalidIndex) : (prev = doc.nodes.items[prev].prev_sibling) {
                position += 1;
            }
            break :blk pseudo.nth.matches(position);
        },
    };
}

fn matchesAttrSelector(
    doc: anytype,
    node: anytype,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    sel: ast.AttrSelector,
) bool {
    const name = sel.name.slice(selector_source);
    const name_hash = if (sel.name_hash != 0) sel.name_hash else tables.hashIgnoreCaseAscii(name);
    const raw = attrValueByHashFrom(doc, node, probe, collected, name, name_hash) orelse return false;
    const value = sel.value.slice(selector_source);
    return evalAttrOp(raw, value, sel.op);
}

fn hasClass(doc: anytype, node: anytype, noalias probe: *AttrProbe, collected: ?*CollectedAttrs, class_name: []const u8) bool {
    const class_attr = attrValueByHashFrom(doc, node, probe, collected, "class", HashClass) orelse return false;
    return tables.tokenIncludesAsciiWhitespace(class_attr, class_name);
}

fn hasAllClassesOnePass(selector: ast.Selector, comp: ast.Compound, class_attr: []const u8) bool {
    const class_count = comp.class_len;
    if (class_count == 0) return true;
    if (class_count > 63) {
        var i: u32 = 0;
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

        var j: u32 = 0;
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

fn attrValueByHashFrom(
    doc: anytype,
    node: anytype,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    name: []const u8,
    name_hash: u32,
) ?[]const u8 {
    if (collected) |c| {
        if (findCollectedEntry(c, name, name_hash)) |idx| {
            if (c.materialized or c.looked[idx]) return c.values[idx];

            if (c.request_count == 0) {
                const value = attrValueByHash(doc, node, probe, name, name_hash);
                c.values[idx] = value;
                c.looked[idx] = true;
                c.request_count = 1;
                return value;
            }

            attr_inline.collectSelectedValuesByHash(
                doc,
                node,
                c.names[0..c.count],
                c.name_hashes[0..c.count],
                c.values[0..c.count],
            );
            c.materialized = true;
            var i: usize = 0;
            while (i < c.count) : (i += 1) c.looked[i] = true;
            return c.values[idx];
        }
    }
    return attrValueByHash(doc, node, probe, name, name_hash);
}

fn attrValueByHash(doc: anytype, node: anytype, noalias probe: *AttrProbe, name: []const u8, name_hash: u32) ?[]const u8 {
    if (findProbeEntry(probe, name, name_hash)) |idx| {
        return probe.entries[idx].value;
    }

    if (!probe.overflow and probe.count < MaxProbeEntries) {
        const value = attr_inline.getAttrValue(doc, node, name);
        const idx = probe.count;
        probe.entries[idx] = .{
            .name = name,
            .name_hash = name_hash,
            .value = value,
        };
        probe.count += 1;
        return value;
    }

    probe.overflow = true;
    // Fallback for very large compounds still stays allocation-free; we simply
    // bypass memoization once the fixed probe budget is exhausted.
    return attr_inline.getAttrValue(doc, node, name);
}

const AttrProbeEntry = struct {
    name: []const u8 = "",
    name_hash: u32 = 0,
    value: ?[]const u8 = null,
};

const AttrProbe = struct {
    count: usize = 0,
    overflow: bool = false,
    entries: [MaxProbeEntries]AttrProbeEntry = [_]AttrProbeEntry{.{}} ** MaxProbeEntries,
};

const CollectedAttrs = struct {
    count: usize = 0,
    request_count: u8 = 0,
    materialized: bool = false,
    names: [MaxCollectedAttrs][]const u8 = [_][]const u8{""} ** MaxCollectedAttrs,
    name_hashes: [MaxCollectedAttrs]u32 = [_]u32{0} ** MaxCollectedAttrs,
    values: [MaxCollectedAttrs]?[]const u8 = [_]?[]const u8{null} ** MaxCollectedAttrs,
    looked: [MaxCollectedAttrs]bool = [_]bool{false} ** MaxCollectedAttrs,
};

fn prepareCollectedAttrs(selector: ast.Selector, comp: ast.Compound, out: *CollectedAttrs) bool {
    out.* = .{};

    if (comp.hasId() and !pushCollectedName(out, "id", HashId)) return false;
    if (comp.class_len != 0 and !pushCollectedName(out, "class", HashClass)) return false;

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        const name = attr_sel.name.slice(selector.source);
        const hash = if (attr_sel.name_hash != 0) attr_sel.name_hash else tables.hashIgnoreCaseAscii(name);
        if (!pushCollectedName(out, name, hash)) return false;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        switch (item.kind) {
            .id => if (!pushCollectedName(out, "id", HashId)) return false,
            .class => if (!pushCollectedName(out, "class", HashClass)) return false,
            .attr => {
                const name = item.attr.name.slice(selector.source);
                const hash = if (item.attr.name_hash != 0) item.attr.name_hash else tables.hashIgnoreCaseAscii(name);
                if (!pushCollectedName(out, name, hash)) return false;
            },
            else => {},
        }
    }

    return out.count >= 2;
}

fn pushCollectedName(out: *CollectedAttrs, name: []const u8, name_hash: u32) bool {
    if (findCollectedEntry(out, name, name_hash) != null) return true;
    if (out.count >= MaxCollectedAttrs) return false;
    out.names[out.count] = name;
    out.name_hashes[out.count] = name_hash;
    out.values[out.count] = null;
    out.count += 1;
    return true;
}

fn findCollectedEntry(collected: *const CollectedAttrs, needle: []const u8, needle_hash: u32) ?usize {
    var i: usize = 0;
    while (i < collected.count) : (i += 1) {
        if (collected.name_hashes[i] != needle_hash) continue;
        const cand = collected.names[i];
        if (cand.len != needle.len) continue;
        if (cand.len != 0 and tables.lower(cand[0]) != tables.lower(needle[0])) continue;
        if (tables.eqlIgnoreCaseAscii(cand, needle)) return i;
    }
    return null;
}

fn findProbeEntry(noalias probe: *const AttrProbe, needle: []const u8, needle_hash: u32) ?usize {
    var i: usize = 0;
    while (i < probe.count) : (i += 1) {
        const entry = probe.entries[i];
        if (entry.name_hash != needle_hash) continue;
        if (entry.name.len != needle.len) continue;
        if (entry.name.len != 0 and tables.lower(entry.name[0]) != tables.lower(needle[0])) continue;
        if (tables.eqlIgnoreCaseAscii(entry.name, needle)) return i;
    }
    return null;
}
