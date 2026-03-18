const std = @import("std");

/// Relationship between a compound and the compound to its left.
pub const Combinator = enum(u8) {
    none,
    descendant,
    child,
    adjacent,
    sibling,

    /// Formats this combinator for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// Attribute selector operator.
pub const AttrOp = enum(u8) {
    exists,
    eq,
    prefix,
    suffix,
    contains,
    includes,
    dash_match,

    /// Formats this attribute operator for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// Source byte range pointing into selector text.
pub const Range = extern struct {
    start: u32 = 0,
    len: u32 = 0,

    /// Returns empty range.
    pub fn empty() @This() {
        return .{ .start = 0, .len = 0 };
    }

    /// Creates range from `start..end`.
    pub fn from(start: usize, end: usize) @This() {
        return .{
            .start = @intCast(start),
            .len = @intCast(end - start),
        };
    }

    /// Returns true when range has zero length.
    pub fn isEmpty(self: @This()) bool {
        return self.len == 0;
    }

    /// Returns the slice represented by this range.
    pub fn slice(self: @This(), source: []const u8) []const u8 {
        const s: usize = @intCast(self.start);
        const e: usize = s + @as(usize, @intCast(self.len));
        return source[s..e];
    }

    /// Formats this range for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Range{{start={}, len={}}}", .{ self.start, self.len });
    }
};

/// One parsed attribute selector predicate.
pub const AttrSelector = extern struct {
    name: Range,
    name_hash: u32 = 0,
    op: AttrOp = .exists,
    value: Range = .{},

    /// Formats this attribute selector for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("AttrSelector{name=");
        try self.name.format(writer);
        try writer.print(", name_hash={}, op={s}, value=", .{ self.name_hash, @tagName(self.op) });
        try self.value.format(writer);
        try writer.writeAll("}");
    }
};

/// Parsed `An+B` expression for `:nth-child`.
pub const NthExpr = extern struct {
    // Matches values where index = a*n + b, n >= 0, index is 1-based.
    a: i32,
    b: i32,

    /// Evaluates this expression for a 1-based child index.
    pub fn matches(self: @This(), index_1based: usize) bool {
        const idx: i32 = @intCast(index_1based);
        if (self.a == 0) return idx == self.b;
        const diff = idx - self.b;
        if ((diff > 0 and self.a < 0) or (diff < 0 and self.a > 0)) return false;
        if (@rem(diff, self.a) != 0) return false;
        return @divTrunc(diff, self.a) >= 0;
    }

    /// Formats this nth expression for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("NthExpr{{a={}, b={}}}", .{ self.a, self.b });
    }
};

/// Supported pseudo classes.
pub const PseudoKind = enum(u8) {
    first_child,
    last_child,
    nth_child,

    /// Formats this pseudo kind for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// One parsed pseudo predicate.
pub const Pseudo = extern struct {
    kind: PseudoKind,
    nth: NthExpr = .{ .a = 0, .b = 1 },

    /// Formats this pseudo selector for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Pseudo{{kind={s}, nth=", .{@tagName(self.kind)});
        try self.nth.format(writer);
        try writer.writeAll("}");
    }
};

/// Supported simple selectors inside `:not(...)`.
pub const NotKind = enum(u8) {
    tag,
    id,
    class,
    attr,

    /// Formats this not-kind for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// One parsed simple `:not(...)` predicate.
pub const NotSimple = extern struct {
    kind: NotKind,
    text: Range = .{},
    attr: AttrSelector = .{ .name = .{}, .op = .exists, .value = .{} },

    /// Formats this `:not` predicate for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("NotSimple{{kind={s}, text=", .{@tagName(self.kind)});
        try self.text.format(writer);
        try writer.writeAll(", attr=");
        try self.attr.format(writer);
        try writer.writeAll("}");
    }
};

/// One selector compound (tag/id/class/attr/pseudo/not + combinator).
pub const Compound = extern struct {
    combinator: Combinator = .none,

    tag: Range = .{},
    tag_key: u64 = 0,
    id: Range = .{},

    class_start: u32 = 0,
    class_len: u32 = 0,

    attr_start: u32 = 0,
    attr_len: u32 = 0,

    pseudo_start: u32 = 0,
    pseudo_len: u32 = 0,

    not_start: u32 = 0,
    not_len: u32 = 0,

    pub fn hasTag(self: @This()) bool {
        return !self.tag.isEmpty();
    }

    pub fn hasId(self: @This()) bool {
        return !self.id.isEmpty();
    }

    /// Formats this compound selector for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Compound{{combinator={s}, tag=", .{@tagName(self.combinator)});
        try self.tag.format(writer);
        try writer.print(", tag_key={}, id=", .{self.tag_key});
        try self.id.format(writer);
        try writer.print(
            ", class_start={}, class_len={}, attr_start={}, attr_len={}, pseudo_start={}, pseudo_len={}, not_start={}, not_len={}}}",
            .{
                self.class_start,
                self.class_len,
                self.attr_start,
                self.attr_len,
                self.pseudo_start,
                self.pseudo_len,
                self.not_start,
                self.not_len,
            },
        );
    }
};

/// One comma-separated selector group.
pub const Group = extern struct {
    compound_start: u32,
    compound_len: u32,

    /// Formats this selector group for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Group{{compound_start={}, compound_len={}}}", .{ self.compound_start, self.compound_len });
    }
};

/// Compiled selector used by matcher/query APIs.
pub const Selector = struct {
    source: []const u8,
    groups: []const Group,
    compounds: []const Compound,
    classes: []const Range,
    attrs: []const AttrSelector,
    pseudos: []const Pseudo,
    not_items: []const NotSimple,

    /// Compiles a selector at comptime with compile-time diagnostics.
    pub fn compile(comptime source: []const u8) @This() {
        return @import("compile_time.zig").compileImpl(source);
    }

    /// Compiles a selector at runtime.
    pub fn compileRuntime(allocator: std.mem.Allocator, source: []const u8) @import("runtime.zig").Error!@This() {
        return @import("runtime.zig").compileRuntimeImpl(allocator, source);
    }

    /// Releases memory owned by runtime-compiled selector.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.source));
        allocator.free(self.groups);
        allocator.free(self.compounds);
        allocator.free(self.classes);
        allocator.free(self.attrs);
        allocator.free(self.pseudos);
        allocator.free(self.not_items);
        self.* = undefined;
    }

    /// Formats this selector summary for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "Selector{{source=\"{s}\", groups={}, compounds={}, classes={}, attrs={}, pseudos={}, not_items={}}}",
            .{
                self.source,
                self.groups.len,
                self.compounds.len,
                self.classes.len,
                self.attrs.len,
                self.pseudos.len,
                self.not_items.len,
            },
        );
    }
};

test "format selector AST types" {
    const alloc = std.testing.allocator;

    const combinator_out = try std.fmt.allocPrint(alloc, "{f}", .{Combinator.child});
    defer alloc.free(combinator_out);
    try std.testing.expectEqualStrings("child", combinator_out);

    const op_out = try std.fmt.allocPrint(alloc, "{f}", .{AttrOp.prefix});
    defer alloc.free(op_out);
    try std.testing.expectEqualStrings("prefix", op_out);

    const range = Range.from(2, 5);
    const range_out = try std.fmt.allocPrint(alloc, "{f}", .{range});
    defer alloc.free(range_out);
    try std.testing.expectEqualStrings("Range{start=2, len=3}", range_out);

    const value_range = Range.from(6, 9);
    const attr_sel: AttrSelector = .{
        .name = range,
        .name_hash = 123,
        .op = .prefix,
        .value = value_range,
    };
    const attr_out = try std.fmt.allocPrint(alloc, "{f}", .{attr_sel});
    defer alloc.free(attr_out);
    try std.testing.expectEqualStrings(
        "AttrSelector{name=Range{start=2, len=3}, name_hash=123, op=prefix, value=Range{start=6, len=3}}",
        attr_out,
    );

    const nth: NthExpr = .{ .a = 2, .b = 1 };
    const nth_out = try std.fmt.allocPrint(alloc, "{f}", .{nth});
    defer alloc.free(nth_out);
    try std.testing.expectEqualStrings("NthExpr{a=2, b=1}", nth_out);

    const pseudo_kind_out = try std.fmt.allocPrint(alloc, "{f}", .{PseudoKind.nth_child});
    defer alloc.free(pseudo_kind_out);
    try std.testing.expectEqualStrings("nth_child", pseudo_kind_out);

    const pseudo: Pseudo = .{ .kind = .nth_child, .nth = nth };
    const pseudo_out = try std.fmt.allocPrint(alloc, "{f}", .{pseudo});
    defer alloc.free(pseudo_out);
    try std.testing.expectEqualStrings("Pseudo{kind=nth_child, nth=NthExpr{a=2, b=1}}", pseudo_out);

    const not_kind_out = try std.fmt.allocPrint(alloc, "{f}", .{NotKind.class});
    defer alloc.free(not_kind_out);
    try std.testing.expectEqualStrings("class", not_kind_out);

    const not_simple: NotSimple = .{
        .kind = .class,
        .text = Range.from(1, 4),
        .attr = attr_sel,
    };
    const not_out = try std.fmt.allocPrint(alloc, "{f}", .{not_simple});
    defer alloc.free(not_out);
    try std.testing.expectEqualStrings(
        "NotSimple{kind=class, text=Range{start=1, len=3}, attr=AttrSelector{name=Range{start=2, len=3}, name_hash=123, op=prefix, value=Range{start=6, len=3}}}",
        not_out,
    );

    const compound: Compound = .{
        .combinator = .child,
        .tag = Range.from(0, 3),
        .tag_key = 0xabc,
        .id = Range.from(4, 6),
        .class_start = 1,
        .class_len = 2,
        .attr_start = 3,
        .attr_len = 4,
        .pseudo_start = 5,
        .pseudo_len = 6,
        .not_start = 7,
        .not_len = 8,
    };
    const compound_out = try std.fmt.allocPrint(alloc, "{f}", .{compound});
    defer alloc.free(compound_out);
    try std.testing.expectEqualStrings(
        "Compound{combinator=child, tag=Range{start=0, len=3}, tag_key=2748, id=Range{start=4, len=2}, class_start=1, class_len=2, attr_start=3, attr_len=4, pseudo_start=5, pseudo_len=6, not_start=7, not_len=8}",
        compound_out,
    );

    const group: Group = .{ .compound_start = 0, .compound_len = 2 };
    const group_out = try std.fmt.allocPrint(alloc, "{f}", .{group});
    defer alloc.free(group_out);
    try std.testing.expectEqualStrings("Group{compound_start=0, compound_len=2}", group_out);

    const groups = [_]Group{group};
    const compounds = [_]Compound{compound};
    const classes = [_]Range{range};
    const attrs = [_]AttrSelector{attr_sel};
    const pseudos = [_]Pseudo{pseudo};
    const not_items = [_]NotSimple{not_simple};
    const selector: Selector = .{
        .source = "div.cls",
        .groups = groups[0..],
        .compounds = compounds[0..],
        .classes = classes[0..],
        .attrs = attrs[0..],
        .pseudos = pseudos[0..],
        .not_items = not_items[0..],
    };
    const selector_out = try std.fmt.allocPrint(alloc, "{f}", .{selector});
    defer alloc.free(selector_out);
    try std.testing.expectEqualStrings(
        "Selector{source=\"div.cls\", groups=1, compounds=1, classes=1, attrs=1, pseudos=1, not_items=1}",
        selector_out,
    );
}
