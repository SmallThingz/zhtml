const std = @import("std");
const ast = @import("ast.zig");
const matcher = @import("matcher.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr = @import("../html/attr.zig");
const selector_debug = @import("../debug/selector_debug.zig");
const common = @import("../common.zig");
const IndexInt = common.IndexInt;

// SAFETY: Debug matcher uses the same traversal bounds as the fast matcher
// and only indexes validated node ranges.

/// Debug matcher that returns first match and records near-miss diagnostics.
pub fn explainFirstMatch(
    comptime Doc: type,
    noalias doc: *const Doc,
    allocator: std.mem.Allocator,
    selector: ast.Selector,
    scope_root: IndexInt,
    noalias report: *selector_debug.QueryDebugReport,
) ?IndexInt {
    report.reset(selector.source, scope_root, selector.groups.len);

    const bounds = matcher.traversalBounds(Doc, doc, scope_root);

    var i = bounds.start;
    while (i < bounds.end_excl and i < doc.nodes.len) : (i += 1) {
        if (!doc.isElementIndex(i)) continue;
        report.visited_elements += 1;

        var first_failure: selector_debug.Failure = .{};
        var g_idx: usize = 0;
        while (g_idx < selector.groups.len) : (g_idx += 1) {
            const group = selector.groups[g_idx];
            if (group.compound_len == 0) continue;
            if (g_idx < selector_debug.MaxSelectorGroups) {
                report.group_eval_counts[g_idx] += 1;
            }

            var one_group_selector = selector;
            one_group_selector.groups = selector.groups[g_idx .. g_idx + 1];
            if (matcher.matchesSelectorAt(Doc, doc, one_group_selector, i, scope_root)) {
                if (g_idx < selector_debug.MaxSelectorGroups) {
                    report.group_match_counts[g_idx] += 1;
                }
                report.matched_index = i;
                report.matched_group = @intCast(@min(g_idx, std.math.maxInt(u16)));
                return i;
            }

            if (first_failure.isNone()) {
                first_failure = classifyGroupFailure(doc, allocator, selector, group, i, scope_root, g_idx);
            }
        }

        if (!first_failure.isNone()) {
            report.pushNearMiss(i, first_failure);
        }
    }

    return null;
}

fn classifyGroupFailure(
    doc: anytype,
    allocator: std.mem.Allocator,
    selector: ast.Selector,
    group: ast.Group,
    node_index: IndexInt,
    scope_root: IndexInt,
    group_index: usize,
) selector_debug.Failure {
    const rightmost = group.compound_len - 1;
    const comp_abs: usize = @intCast(group.compound_start + rightmost);
    const comp = selector.compounds[comp_abs];
    var reason = classifyCompoundFailure(doc, allocator, selector, comp, node_index, group_index, comp_abs);
    if (!reason.isNone()) return reason;

    if (group.compound_len == 1 and comp.combinator != .none and !common.matchesScopeAnchor(doc, comp.combinator, node_index, scope_root)) {
        return .{
            .kind = .scope,
            .group_index = @intCast(@min(group_index, std.math.maxInt(u16))),
            .compound_index = @intCast(@min(comp_abs, std.math.maxInt(u16))),
        };
    }

    if (group.compound_len > 1) {
        return .{
            .kind = .combinator,
            .group_index = @intCast(@min(group_index, std.math.maxInt(u16))),
            .compound_index = @intCast(@min(comp_abs, std.math.maxInt(u16))),
        };
    }

    return .{};
}

fn classifyCompoundFailure(
    doc: anytype,
    allocator: std.mem.Allocator,
    selector: ast.Selector,
    comp: ast.Compound,
    node_index: IndexInt,
    group_index: usize,
    compound_index: usize,
) selector_debug.Failure {
    const node = &doc.nodes[node_index];
    var predicate_index: u16 = 0;
    const g: u16 = @intCast(@min(group_index, std.math.maxInt(u16)));
    const c: u16 = @intCast(@min(compound_index, std.math.maxInt(u16)));

    if (comp.hasTag()) {
        const node_name = node.name_or_text.slice(doc.source);
        if (!matcher.tagMatches(selector.source, comp, node_name)) {
            return .{ .kind = .tag, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    if (comp.hasId()) {
        const id = comp.id.slice(selector.source);
        const value = attr.getAttrValue(doc, node, "id", allocator) orelse return .{
            .kind = .id,
            .group_index = g,
            .compound_index = c,
            .predicate_index = predicate_index,
        };
        if (!std.mem.eql(u8, value, id)) {
            return .{ .kind = .id, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    if (comp.class_len != 0) {
        const class_attr = attr.getAttrValue(doc, node, "class", allocator) orelse return .{
            .kind = .class,
            .group_index = g,
            .compound_index = c,
            .predicate_index = predicate_index,
        };
        var class_i: IndexInt = 0;
        while (class_i < comp.class_len) : (class_i += 1) {
            const cls = selector.classes[comp.class_start + class_i].slice(selector.source);
            if (!tables.tokenIncludesAsciiWhitespace(class_attr, cls)) {
                return .{ .kind = .class, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
            }
            predicate_index += 1;
        }
    }

    var attr_i: IndexInt = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!matcher.matchesAttrSelectorDebug(doc, node, allocator, selector.source, attr_sel)) {
            return .{ .kind = .attr, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    var pseudo_i: IndexInt = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        if (!matcher.matchesPseudo(doc, node_index, pseudo)) {
            return .{ .kind = .pseudo, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    var not_i: IndexInt = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (matchesNotSimple(doc, node, allocator, selector.source, item)) {
            return .{ .kind = .not_simple, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    return .{};
}

fn matchesNotSimple(
    doc: anytype,
    node: anytype,
    allocator: std.mem.Allocator,
    selector_source: []const u8,
    item: ast.NotSimple,
) bool {
    const Ctx = matcher.NotSimpleCtxDebug(@TypeOf(doc), @TypeOf(node));
    const ctx = Ctx{
        .doc = doc,
        .node = node,
        .allocator = allocator,
        .selector_source = selector_source,
    };
    return matcher.matchesNotSimpleCommon(ctx, item);
}
