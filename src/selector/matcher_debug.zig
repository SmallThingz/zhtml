const std = @import("std");
const ast = @import("ast.zig");
const matcher = @import("matcher.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr_inline = @import("../html/attr_inline.zig");
const selector_debug = @import("../debug/selector_debug.zig");
const common = @import("../common.zig");


/// Debug matcher that returns first match and records near-miss diagnostics.
pub fn explainFirstMatch(
    comptime Doc: type,
    noalias doc: *const Doc,
    selector: ast.Selector,
    scope_root: u32,
    noalias report: *selector_debug.QueryDebugReport,
) ?u32 {
    report.reset(selector.source, scope_root, selector.groups.len);

    const bounds = matcher.traversalBounds(Doc, doc, scope_root);

    var i = bounds.start;
    while (i < bounds.end_excl and i < doc.nodes.items.len) : (i += 1) {
        const node = &doc.nodes.items[i];
        if (!common.isElementLike(node.kind)) continue;
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
                first_failure = classifyGroupFailure(doc, selector, group, i, scope_root, g_idx);
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
    selector: ast.Selector,
    group: ast.Group,
    node_index: u32,
    scope_root: u32,
    group_index: usize,
) selector_debug.Failure {
    const rightmost = group.compound_len - 1;
    const comp_abs: usize = @intCast(group.compound_start + rightmost);
    const comp = selector.compounds[comp_abs];
    var reason = classifyCompoundFailure(doc, selector, comp, node_index, group_index, comp_abs);
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
    selector: ast.Selector,
    comp: ast.Compound,
    node_index: u32,
    group_index: usize,
    compound_index: usize,
) selector_debug.Failure {
    const node = &doc.nodes.items[node_index];
    var predicate_index: u16 = 0;
    const g: u16 = @intCast(@min(group_index, std.math.maxInt(u16)));
    const c: u16 = @intCast(@min(compound_index, std.math.maxInt(u16)));

    if (comp.has_tag != 0) {
        const node_name = node.name_or_text.slice(doc.source);
        if (!matcher.tagMatches(selector.source, comp, node_name)) {
            return .{ .kind = .tag, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    if (comp.has_id != 0) {
        const id = comp.id.slice(selector.source);
        const value = attr_inline.getAttrValue(doc, node, "id") orelse return .{
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
        const class_attr = attr_inline.getAttrValue(doc, node, "class") orelse return .{
            .kind = .class,
            .group_index = g,
            .compound_index = c,
            .predicate_index = predicate_index,
        };
        var class_i: u32 = 0;
        while (class_i < comp.class_len) : (class_i += 1) {
            const cls = selector.classes[comp.class_start + class_i].slice(selector.source);
            if (!tables.tokenIncludesAsciiWhitespace(class_attr, cls)) {
                return .{ .kind = .class, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
            }
            predicate_index += 1;
        }
    }

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!matcher.matchesAttrSelectorDebug(doc, node, selector.source, attr_sel)) {
            return .{ .kind = .attr, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    var pseudo_i: u32 = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        if (!matcher.matchesPseudo(doc, node_index, pseudo)) {
            return .{ .kind = .pseudo, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (matchesNotSimple(doc, node, selector.source, item)) {
            return .{ .kind = .not_simple, .group_index = g, .compound_index = c, .predicate_index = predicate_index };
        }
        predicate_index += 1;
    }

    return .{};
}

fn matchesNotSimple(
    doc: anytype,
    node: anytype,
    selector_source: []const u8,
    item: ast.NotSimple,
) bool {
    const Ctx = matcher.NotSimpleCtxDebug(@TypeOf(doc), @TypeOf(node));
    const ctx = Ctx{
        .doc = doc,
        .node = node,
        .selector_source = selector_source,
    };
    return matcher.matchesNotSimpleCommon(ctx, item);
}
