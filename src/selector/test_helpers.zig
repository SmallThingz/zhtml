const std = @import("std");

pub fn expectAllAttributeOps(sel: anytype) !void {
    try std.testing.expectEqual(@as(usize, 1), sel.groups.len);
    try std.testing.expectEqual(@as(usize, 1), sel.compounds.len);

    const comp = sel.compounds[0];
    try std.testing.expectEqual(@as(u32, 7), comp.attr_len);
    try std.testing.expect(sel.attrs[comp.attr_start + 0].op == .exists);
    try std.testing.expect(sel.attrs[comp.attr_start + 1].op == .eq);
    try std.testing.expect(sel.attrs[comp.attr_start + 2].op == .prefix);
    try std.testing.expect(sel.attrs[comp.attr_start + 3].op == .suffix);
    try std.testing.expect(sel.attrs[comp.attr_start + 4].op == .contains);
    try std.testing.expect(sel.attrs[comp.attr_start + 5].op == .includes);
    try std.testing.expect(sel.attrs[comp.attr_start + 6].op == .dash_match);
}

pub fn expectCombinatorChain(sel: anytype) !void {
    try std.testing.expectEqual(@as(usize, 2), sel.groups.len);
    try std.testing.expectEqual(@as(usize, 6), sel.compounds.len);

    try std.testing.expect(sel.compounds[0].combinator == .none);
    try std.testing.expect(sel.compounds[1].combinator == .descendant);
    try std.testing.expect(sel.compounds[2].combinator == .child);
    try std.testing.expect(sel.compounds[3].combinator == .adjacent);
    try std.testing.expect(sel.compounds[4].combinator == .sibling);
    try std.testing.expect(sel.compounds[5].combinator == .none);
}
