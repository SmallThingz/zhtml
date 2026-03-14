const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const test_helpers = @import("test_helpers.zig");

// SAFETY: Runtime parser owns `source` bytes via allocator and builds AST
// slices that refer to those owned bytes.

/// Runtime selector parser errors.
pub const Error = error{
    InvalidSelector,
    OutOfMemory,
};

/// Parses selector source into runtime-owned AST slices.
pub fn compileRuntimeImpl(alloc: std.mem.Allocator, source: []const u8) Error!ast.Selector {
    const owned_source = try alloc.dupe(u8, source);
    errdefer alloc.free(owned_source);

    var parser = Parser.init(owned_source, alloc);
    return try parser.parse();
}

const Parser = struct {
    source: []const u8,
    i: usize,
    alloc: std.mem.Allocator,

    groups: std.ArrayList(ast.Group),
    compounds: std.ArrayList(ast.Compound),
    classes: std.ArrayList(ast.Range),
    attrs: std.ArrayList(ast.AttrSelector),
    pseudos: std.ArrayList(ast.Pseudo),
    not_items: std.ArrayList(ast.NotSimple),

    fn init(source: []const u8, alloc: std.mem.Allocator) Parser {
        return .{
            .source = source,
            .i = 0,
            .alloc = alloc,
            .groups = std.ArrayList(ast.Group).empty,
            .compounds = std.ArrayList(ast.Compound).empty,
            .classes = std.ArrayList(ast.Range).empty,
            .attrs = std.ArrayList(ast.AttrSelector).empty,
            .pseudos = std.ArrayList(ast.Pseudo).empty,
            .not_items = std.ArrayList(ast.NotSimple).empty,
        };
    }

    fn parse(noalias self: *Parser) Error!ast.Selector {
        defer self.groups.deinit(self.alloc);
        defer self.compounds.deinit(self.alloc);
        defer self.classes.deinit(self.alloc);
        defer self.attrs.deinit(self.alloc);
        defer self.pseudos.deinit(self.alloc);
        defer self.not_items.deinit(self.alloc);

        self.skipWs();
        if (self.i >= self.source.len) return error.InvalidSelector;

        while (true) {
            const group_start: u32 = @intCast(self.compounds.items.len);
            var first_combinator: ast.Combinator = .none;
            if (self.i < self.source.len) {
                first_combinator = switch (self.peek()) {
                    '>' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.child;
                    },
                    '+' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.adjacent;
                    },
                    '~' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.sibling;
                    },
                    else => .none,
                };
            }
            try self.parseCompound(first_combinator);

            while (true) {
                const saw_ws = self.skipWsRet();
                if (self.i >= self.source.len or self.peek() == ',') break;

                var combinator: ast.Combinator = if (saw_ws) .descendant else .none;
                combinator = switch (self.peek()) {
                    '>' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.child;
                    },
                    '+' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.adjacent;
                    },
                    '~' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.sibling;
                    },
                    else => combinator,
                };

                if (combinator == .none) return error.InvalidSelector;
                try self.parseCompound(combinator);
            }

            const group_end: u32 = @intCast(self.compounds.items.len);
            if (group_end == group_start) return error.InvalidSelector;
            try self.pushGroup(.{
                .compound_start = group_start,
                .compound_len = group_end - group_start,
            });

            self.skipWs();
            if (self.i >= self.source.len) break;
            if (self.peek() != ',') return error.InvalidSelector;
            self.i += 1;
            self.skipWs();
            if (self.i >= self.source.len) return error.InvalidSelector;
        }

        const groups = try self.groups.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(groups);

        const compounds = try self.compounds.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(compounds);

        const classes = try self.classes.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(classes);

        const attrs = try self.attrs.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(attrs);

        const pseudos = try self.pseudos.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(pseudos);

        const not_items = try self.not_items.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(not_items);

        const requires_parent = selectorRequiresParent(compounds, pseudos);

        return .{
            .source = self.source,
            .requires_parent = requires_parent,
            .groups = groups,
            .compounds = compounds,
            .classes = classes,
            .attrs = attrs,
            .pseudos = pseudos,
            .not_items = not_items,
        };
    }

    fn parseCompound(noalias self: *Parser, combinator: ast.Combinator) Error!void {
        var out: ast.Compound = .{ .combinator = combinator };
        out.class_start = @intCast(self.classes.items.len);
        out.attr_start = @intCast(self.attrs.items.len);
        out.pseudo_start = @intCast(self.pseudos.items.len);
        out.not_start = @intCast(self.not_items.items.len);

        var consumed = false;

        if (self.i < self.source.len) {
            const c = self.peek();
            if (c == '*') {
                self.i += 1;
                consumed = true;
            } else if (isTagIdentStart(c)) {
                out.has_tag = 1;
                out.tag = self.parseIdent() orelse return error.InvalidSelector;
                self.lowerRange(out.tag);
                out.tag_key = tags.first8Key(out.tag.slice(self.source));
                consumed = true;
            }
        }

        while (self.i < self.source.len) {
            const c = self.peek();
            switch (c) {
                '#' => {
                    self.i += 1;
                    if (out.has_id != 0) return error.InvalidSelector;
                    out.has_id = 1;
                    out.id = self.parseIdent() orelse return error.InvalidSelector;
                    consumed = true;
                },
                '.' => {
                    self.i += 1;
                    const class_name = self.parseIdent() orelse return error.InvalidSelector;
                    try self.pushClass(class_name);
                    consumed = true;
                },
                '[' => {
                    self.i += 1;
                    const attr = try self.parseAttrSelector();
                    try self.pushAttr(attr);
                    consumed = true;
                },
                ':' => {
                    self.i += 1;
                    try self.parsePseudo();
                    consumed = true;
                },
                else => break,
            }
        }

        if (!consumed) return error.InvalidSelector;

        out.class_len = @as(u32, @intCast(self.classes.items.len)) - out.class_start;
        out.attr_len = @as(u32, @intCast(self.attrs.items.len)) - out.attr_start;
        out.pseudo_len = @as(u32, @intCast(self.pseudos.items.len)) - out.pseudo_start;
        out.not_len = @as(u32, @intCast(self.not_items.items.len)) - out.not_start;

        try self.pushCompound(out);
    }

    fn parseAttrSelector(noalias self: *Parser) Error!ast.AttrSelector {
        self.skipWs();
        const name = self.parseIdent() orelse return error.InvalidSelector;
        self.lowerRange(name);
        self.skipWs();

        if (!self.consumeIf('=')) {
            if (!self.consumeIf('^')) {
                if (!self.consumeIf('$')) {
                    if (!self.consumeIf('*')) {
                        if (!self.consumeIf('~')) {
                            if (!self.consumeIf('|')) {
                                if (!self.consumeIf(']')) return error.InvalidSelector;
                                return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .exists, .value = .{} };
                            }
                            if (!self.consumeIf('=')) return error.InvalidSelector;
                            const v = try self.parseAttrValueThenClose();
                            return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .dash_match, .value = v };
                        }
                        if (!self.consumeIf('=')) return error.InvalidSelector;
                        const v = try self.parseAttrValueThenClose();
                        return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .includes, .value = v };
                    }
                    if (!self.consumeIf('=')) return error.InvalidSelector;
                    const v = try self.parseAttrValueThenClose();
                    return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .contains, .value = v };
                }
                if (!self.consumeIf('=')) return error.InvalidSelector;
                const v = try self.parseAttrValueThenClose();
                return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .suffix, .value = v };
            }
            if (!self.consumeIf('=')) return error.InvalidSelector;
            const v = try self.parseAttrValueThenClose();
            return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .prefix, .value = v };
        }

        const v = try self.parseAttrValueThenClose();
        return .{ .name = name, .name_hash = tables.hashIgnoreCaseAscii(name.slice(self.source)), .op = .eq, .value = v };
    }

    fn parseAttrValueThenClose(noalias self: *Parser) Error!ast.Range {
        self.skipWs();
        const v = self.parseValueToken() orelse return error.InvalidSelector;
        self.skipWs();
        if (!self.consumeIf(']')) return error.InvalidSelector;
        return v;
    }

    fn parsePseudo(noalias self: *Parser) Error!void {
        const name = self.parseIdent() orelse return error.InvalidSelector;
        const name_slice = name.slice(self.source);

        if (tables.eqlIgnoreCaseAscii(name_slice, "first-child")) {
            try self.pushPseudo(.{ .kind = .first_child });
            return;
        }

        if (tables.eqlIgnoreCaseAscii(name_slice, "last-child")) {
            try self.pushPseudo(.{ .kind = .last_child });
            return;
        }

        if (tables.eqlIgnoreCaseAscii(name_slice, "nth-child")) {
            self.skipWs();
            if (!self.consumeIf('(')) return error.InvalidSelector;
            self.skipWs();
            const arg = self.parseUntil(')') orelse return error.InvalidSelector;
            const nth = parseNthExpr(tables.trimAsciiWhitespace(arg.slice(self.source))) orelse return error.InvalidSelector;
            try self.pushPseudo(.{ .kind = .nth_child, .nth = nth });
            return;
        }

        if (tables.eqlIgnoreCaseAscii(name_slice, "not")) {
            self.skipWs();
            if (!self.consumeIf('(')) return error.InvalidSelector;
            self.skipWs();
            const item = try self.parseSimpleNot();
            self.skipWs();
            if (!self.consumeIf(')')) return error.InvalidSelector;
            try self.pushNotItem(item);
            return;
        }

        return error.InvalidSelector;
    }

    fn parseSimpleNot(noalias self: *Parser) Error!ast.NotSimple {
        if (self.i >= self.source.len) return error.InvalidSelector;

        if (self.peek() == '#') {
            self.i += 1;
            const id = self.parseIdent() orelse return error.InvalidSelector;
            return .{ .kind = .id, .text = id };
        }

        if (self.peek() == '.') {
            self.i += 1;
            const c = self.parseIdent() orelse return error.InvalidSelector;
            return .{ .kind = .class, .text = c };
        }

        if (self.peek() == '[') {
            self.i += 1;
            const attr = try self.parseAttrSelector();
            return .{ .kind = .attr, .attr = attr };
        }

        if (tables.IdentStartTable[self.peek()]) {
            const tag = self.parseIdent() orelse return error.InvalidSelector;
            self.lowerRange(tag);
            return .{ .kind = .tag, .text = tag };
        }

        return error.InvalidSelector;
    }

    fn parseUntil(noalias self: *Parser, terminator: u8) ?ast.Range {
        const start = self.i;
        while (self.i < self.source.len and self.source[self.i] != terminator) : (self.i += 1) {}
        if (self.i >= self.source.len or self.source[self.i] != terminator) return null;
        const out = ast.Range.from(start, self.i);
        self.i += 1;
        return out;
    }

    fn parseValueToken(noalias self: *Parser) ?ast.Range {
        if (self.i >= self.source.len) return null;
        const c = self.peek();

        if (c == '\'' or c == '"') {
            self.i += 1;
            const start = self.i;
            while (self.i < self.source.len and self.source[self.i] != c) : (self.i += 1) {}
            if (self.i >= self.source.len) return null;
            const out = ast.Range.from(start, self.i);
            self.i += 1;
            return out;
        }

        const start = self.i;
        while (self.i < self.source.len) {
            const cur = self.source[self.i];
            if (cur == ']' or tables.WhitespaceTable[cur]) break;
            self.i += 1;
        }
        if (self.i == start) return null;
        return ast.Range.from(start, self.i);
    }

    fn parseIdent(noalias self: *Parser) ?ast.Range {
        if (self.i >= self.source.len) return null;
        if (!tables.IdentStartTable[self.source[self.i]]) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.source.len and isSelectorIdentChar(self.source[self.i])) : (self.i += 1) {}
        return ast.Range.from(start, self.i);
    }

    fn lowerRange(noalias self: *Parser, range: ast.Range) void {
        const start: usize = @intCast(range.start);
        const end = start + @as(usize, @intCast(range.len));
        tables.toLowerInPlace(@constCast(self.source[start..end]));
    }

    fn skipWs(noalias self: *Parser) void {
        _ = self.skipWsRet();
    }

    fn skipWsRet(noalias self: *Parser) bool {
        const start = self.i;
        while (self.i < self.source.len and tables.WhitespaceTable[self.source[self.i]]) : (self.i += 1) {}
        return self.i > start;
    }

    fn consumeIf(noalias self: *Parser, c: u8) bool {
        if (self.i < self.source.len and self.source[self.i] == c) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn peek(self: *const Parser) u8 {
        return self.source[self.i];
    }

    const appendAlloc = @import("../common.zig").appendAlloc;

    fn pushGroup(noalias self: *Parser, value: ast.Group) Error!void {
        try appendAlloc(ast.Group, &self.groups, self.alloc, value);
    }

    fn pushCompound(noalias self: *Parser, value: ast.Compound) Error!void {
        try appendAlloc(ast.Compound, &self.compounds, self.alloc, value);
    }

    fn pushClass(noalias self: *Parser, value: ast.Range) Error!void {
        try appendAlloc(ast.Range, &self.classes, self.alloc, value);
    }

    fn pushAttr(noalias self: *Parser, value: ast.AttrSelector) Error!void {
        try appendAlloc(ast.AttrSelector, &self.attrs, self.alloc, value);
    }

    fn pushPseudo(noalias self: *Parser, value: ast.Pseudo) Error!void {
        try appendAlloc(ast.Pseudo, &self.pseudos, self.alloc, value);
    }

    fn pushNotItem(noalias self: *Parser, value: ast.NotSimple) Error!void {
        try appendAlloc(ast.NotSimple, &self.not_items, self.alloc, value);
    }
};

fn isSelectorIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or
        c == '-';
}

fn isTagIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn parseNthExpr(expr: []const u8) ?ast.NthExpr {
    if (expr.len == 0) return null;
    if (tables.eqlIgnoreCaseAscii(expr, "odd")) return .{ .a = 2, .b = 1 };
    if (tables.eqlIgnoreCaseAscii(expr, "even")) return .{ .a = 2, .b = 0 };

    const n_pos: ?usize = blk: {
        var i: usize = 0;
        while (i < expr.len) : (i += 1) {
            const c = expr[i];
            if (c == 'n' or c == 'N') break :blk i;
        }
        break :blk null;
    };

    if (n_pos) |n_idx| {
        const a_part = tables.trimAsciiWhitespace(expr[0..n_idx]);
        const b_part = tables.trimAsciiWhitespace(expr[n_idx + 1 ..]);

        const a: i32 = if (a_part.len == 0 or std.mem.eql(u8, a_part, "+"))
            1
        else if (std.mem.eql(u8, a_part, "-"))
            -1
        else
            parseSignedInt(a_part) orelse return null;

        const b: i32 = if (b_part.len == 0)
            0
        else
            parseSignedInt(b_part) orelse return null;

        return .{ .a = a, .b = b };
    }

    const only = parseSignedInt(expr) orelse return null;
    return .{ .a = 0, .b = only };
}

fn parseSignedInt(bytes: []const u8) ?i32 {
    if (bytes.len == 0) return null;
    var start: usize = 0;
    var sign: i64 = 1;
    if (bytes[0] == '+') {
        start = 1;
    } else if (bytes[0] == '-') {
        start = 1;
        sign = -1;
    }
    if (start >= bytes.len) return null;
    const mag = std.fmt.parseInt(i64, bytes[start..], 10) catch return null;
    const value = sign * mag;
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return null;
    return @intCast(value);
}

fn selectorRequiresParent(compounds: []const ast.Compound, pseudos: []const ast.Pseudo) bool {
    for (compounds) |comp| {
        switch (comp.combinator) {
            .child, .descendant => return true,
            else => {},
        }

        var i: u32 = 0;
        while (i < comp.pseudo_len) : (i += 1) {
            const p = pseudos[comp.pseudo_start + i];
            if (p.kind == .nth_child) return true;
        }
    }
    return false;
}

test "runtime selector parser covers all attribute operators" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "div[a][b=v][c^=x][d$=y][e*=z][f~=m][g|=en]");
    defer sel.deinit(alloc);
    try test_helpers.expectAllAttributeOps(sel);
}

test "runtime selector parser tracks combinator chain and grouping" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "a b > c + d ~ e, #x");
    defer sel.deinit(alloc);
    try test_helpers.expectCombinatorChain(sel);
}

test "runtime selector parser supports leading combinator and pseudo-only compounds" {
    const alloc = std.testing.allocator;

    var sel = try compileRuntimeImpl(alloc, "> #hsoob");
    defer sel.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), sel.groups.len);
    try std.testing.expectEqual(@as(usize, 1), sel.compounds.len);
    try std.testing.expect(sel.compounds[0].combinator == .child);
    try std.testing.expect(sel.compounds[0].has_id == 1);

    var sel2 = try compileRuntimeImpl(alloc, "#pseudos :nth-child(odd)");
    defer sel2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), sel2.compounds.len);
    try std.testing.expect(sel2.compounds[1].combinator == .descendant);
    try std.testing.expectEqual(@as(u32, 1), sel2.compounds[1].pseudo_len);
    try std.testing.expect(sel2.pseudos[sel2.compounds[1].pseudo_start].kind == .nth_child);
}

test "runtime selector parser accepts nth-child shorthand variants" {
    const alloc = std.testing.allocator;
    const valid = [_][]const u8{
        ":nth-child(odd)",
        ":nth-child(even)",
        ":nth-child(3n+1)",
        ":nth-child(+3n-2)",
        ":nth-child(-n+6)",
        ":nth-child(-n+5)",
        ":nth-child(2)",
    };
    for (valid) |v| {
        var sel = try compileRuntimeImpl(alloc, v);
        sel.deinit(alloc);
    }
}

test "runtime selector parser rejects invalid selectors" {
    const alloc = std.testing.allocator;
    const invalid = [_][]const u8{
        "",
        ",",
        "div >",
        "div +",
        "div ~",
        "div,",
        "#a#b",
        "div:not()",
        "div:not(.a,.b)",
        "div:nth-child()",
        "div:nth-child(2n+)",
        "div:unknown",
        "[attr",
        "div[attr^]",
    };

    for (invalid) |source| {
        if (compileRuntimeImpl(alloc, source)) |sel| {
            var owned = sel;
            owned.deinit(alloc);
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expect(err == error.InvalidSelector);
        }
    }
}

test "runtime selector parse" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "div#id.cls[attr^=x]:first-child, span + a");
    defer sel.deinit(alloc);

    try std.testing.expect(sel.groups.len == 2);

    var sel2 = try compileRuntimeImpl(alloc, "div > span.k");
    defer sel2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), sel2.groups.len);
    try std.testing.expectEqual(@as(usize, 2), sel2.compounds.len);
    try std.testing.expect(sel2.compounds[1].combinator == .child);
}

test "runtime selector owns source bytes" {
    const alloc = std.testing.allocator;
    var buf = "span.x".*;

    var sel = try compileRuntimeImpl(alloc, &buf);
    defer sel.deinit(alloc);

    buf[0] = 'd';
    buf[1] = 'i';
    buf[2] = 'v';

    const cls = sel.classes[0].slice(sel.source);
    try std.testing.expectEqualStrings("x", cls);
    try std.testing.expectEqualStrings("span", sel.compounds[0].tag.slice(sel.source));
}
