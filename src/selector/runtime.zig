const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const test_helpers = @import("test_helpers.zig");
const IndexInt = ast.Int;

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
    source: []u8,
    i: usize,
    alloc: std.mem.Allocator,

    groups: std.ArrayList(ast.Group),
    compounds: std.ArrayList(ast.Compound),
    classes: std.ArrayList(ast.Range),
    attrs: std.ArrayList(ast.AttrSelector),
    pseudos: std.ArrayList(ast.Pseudo),
    not_items: std.ArrayList(ast.NotSimple),

    fn init(source: []u8, alloc: std.mem.Allocator) Parser {
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
            const group_start: IndexInt = @intCast(self.compounds.items.len);
            const first_combinator = self.consumeCombinator() orelse .none;
            try self.parseCompound(first_combinator);

            while (true) {
                const saw_ws = self.skipWsRet();
                if (self.i >= self.source.len or self.peek() == ',') break;

                const combinator = self.consumeCombinator() orelse if (saw_ws) ast.Combinator.descendant else .none;

                if (combinator == .none) return error.InvalidSelector;
                try self.parseCompound(combinator);
            }

            const group_end: IndexInt = @intCast(self.compounds.items.len);
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

        return .{
            .source = self.source,
            .groups = groups,
            .compounds = compounds,
            .classes = classes,
            .attrs = attrs,
            .pseudos = pseudos,
            .not_items = not_items,
        };
    }

    fn consumeCombinator(noalias self: *Parser) ?ast.Combinator {
        if (self.i >= self.source.len) return null;
        const combinator: ast.Combinator = switch (self.peek()) {
            '>' => .child,
            '+' => .adjacent,
            '~' => .sibling,
            else => return null,
        };
        self.i += 1;
        self.skipWs();
        return combinator;
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
                    if (!out.id.isEmpty()) return error.InvalidSelector;
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

        out.class_len = @as(IndexInt, @intCast(self.classes.items.len)) - out.class_start;
        out.attr_len = @as(IndexInt, @intCast(self.attrs.items.len)) - out.attr_start;
        out.pseudo_len = @as(IndexInt, @intCast(self.pseudos.items.len)) - out.pseudo_start;
        out.not_len = @as(IndexInt, @intCast(self.not_items.items.len)) - out.not_start;

        try self.pushCompound(out);
    }

    fn parseAttrSelector(noalias self: *Parser) Error!ast.AttrSelector {
        self.skipWs();
        const name = self.parseIdent() orelse return error.InvalidSelector;
        self.lowerRange(name);
        self.skipWs();

        const op = (try self.parseAttrOp()) orelse return .{ .name = name, .op = .exists, .value = .{} };
        const parsed = try self.parseAttrValueThenClose();
        return .{ .name = name, .op = op, .case = parsed.case, .value = parsed.value };
    }

    fn parseAttrOp(noalias self: *Parser) Error!?ast.AttrOp {
        return switch (self.peekOrInvalid()) {
            ']' => {
                self.i += 1;
                return null;
            },
            '=' => blk: {
                self.i += 1;
                break :blk .eq;
            },
            '^' => blk: {
                self.i += 1;
                if (!self.consumeIf('=')) return error.InvalidSelector;
                break :blk .prefix;
            },
            '$' => blk: {
                self.i += 1;
                if (!self.consumeIf('=')) return error.InvalidSelector;
                break :blk .suffix;
            },
            '*' => blk: {
                self.i += 1;
                if (!self.consumeIf('=')) return error.InvalidSelector;
                break :blk .contains;
            },
            '~' => blk: {
                self.i += 1;
                if (!self.consumeIf('=')) return error.InvalidSelector;
                break :blk .includes;
            },
            '|' => blk: {
                self.i += 1;
                if (!self.consumeIf('=')) return error.InvalidSelector;
                break :blk .dash_match;
            },
            else => return error.InvalidSelector,
        };
    }

    fn peekOrInvalid(self: *const Parser) u8 {
        if (self.i >= self.source.len) return 0;
        return self.source[self.i];
    }

    const ParsedAttrValue = struct {
        value: ast.Range,
        case: ast.AttrCase = .sensitive,
    };

    fn parseAttrValueThenClose(noalias self: *Parser) Error!ParsedAttrValue {
        self.skipWs();
        const v = self.parseValueToken() orelse return error.InvalidSelector;
        self.skipWs();
        const case: ast.AttrCase = if (self.i < self.source.len and self.source[self.i] != ']') blk: {
            const flag = self.source[self.i];
            self.i += 1;
            self.skipWs();
            break :blk switch (flag) {
                'i', 'I' => .insensitive_ascii,
                's', 'S' => .sensitive,
                else => return error.InvalidSelector,
            };
        } else .sensitive;
        if (!self.consumeIf(']')) return error.InvalidSelector;
        return .{ .value = v, .case = case };
    }

    fn parsePseudo(noalias self: *Parser) Error!void {
        const name = self.parseIdent() orelse return error.InvalidSelector;
        const name_slice = name.slice(self.source);

        if (std.ascii.eqlIgnoreCase(name_slice, "first-child")) {
            try self.pushPseudo(.{ .kind = .first_child });
            return;
        }

        if (std.ascii.eqlIgnoreCase(name_slice, "last-child")) {
            try self.pushPseudo(.{ .kind = .last_child });
            return;
        }

        if (std.ascii.eqlIgnoreCase(name_slice, "nth-child")) {
            try self.parseNthChildPseudo();
            return;
        }

        if (std.ascii.eqlIgnoreCase(name_slice, "not")) {
            try self.parseNotPseudo();
            return;
        }

        return error.InvalidSelector;
    }

    fn parseNthChildPseudo(noalias self: *Parser) Error!void {
        self.skipWs();
        if (!self.consumeIf('(')) return error.InvalidSelector;
        self.skipWs();
        const arg = self.parseUntil(')') orelse return error.InvalidSelector;
        const nth = parseNthExpr(tables.trimAsciiWhitespace(arg.slice(self.source))) orelse return error.InvalidSelector;
        try self.pushPseudo(.{ .kind = .nth_child, .nth = nth });
    }

    fn parseNotPseudo(noalias self: *Parser) Error!void {
        self.skipWs();
        if (!self.consumeIf('(')) return error.InvalidSelector;
        self.skipWs();
        const item = try self.parseSimpleNot();
        self.skipWs();
        if (!self.consumeIf(')')) return error.InvalidSelector;
        try self.pushNotItem(item);
    }

    fn parseSimpleNot(noalias self: *Parser) Error!ast.NotSimple {
        if (self.i >= self.source.len) return error.InvalidSelector;
        return switch (self.peek()) {
            '#' => blk: {
                self.i += 1;
                const id = self.parseIdent() orelse return error.InvalidSelector;
                break :blk .{ .kind = .id, .text = id };
            },
            '.' => blk: {
                self.i += 1;
                const c = self.parseIdent() orelse return error.InvalidSelector;
                break :blk .{ .kind = .class, .text = c };
            },
            '[' => blk: {
                self.i += 1;
                const attr = try self.parseAttrSelector();
                break :blk .{ .kind = .attr, .attr = attr };
            },
            else => blk: {
                if (!tables.IdentStartTable[self.peek()]) return error.InvalidSelector;
                const tag = self.parseIdent() orelse return error.InvalidSelector;
                self.lowerRange(tag);
                break :blk .{ .kind = .tag, .text = tag };
            },
        };
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
        const bytes = self.source[start..end];
        _ = std.ascii.lowerString(bytes, bytes);
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

    fn pushGroup(noalias self: *Parser, value: ast.Group) Error!void {
        try self.groups.append(self.alloc, value);
    }

    fn pushCompound(noalias self: *Parser, value: ast.Compound) Error!void {
        try self.compounds.append(self.alloc, value);
    }

    fn pushClass(noalias self: *Parser, value: ast.Range) Error!void {
        try self.classes.append(self.alloc, value);
    }

    fn pushAttr(noalias self: *Parser, value: ast.AttrSelector) Error!void {
        try self.attrs.append(self.alloc, value);
    }

    fn pushPseudo(noalias self: *Parser, value: ast.Pseudo) Error!void {
        try self.pseudos.append(self.alloc, value);
    }

    fn pushNotItem(noalias self: *Parser, value: ast.NotSimple) Error!void {
        try self.not_items.append(self.alloc, value);
    }
};

fn isSelectorIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isTagIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn parseNthExpr(expr: []const u8) ?ast.NthExpr {
    if (expr.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(expr, "odd")) return .{ .a = 2, .b = 1 };
    if (std.ascii.eqlIgnoreCase(expr, "even")) return .{ .a = 2, .b = 0 };

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
            std.fmt.parseInt(i32, a_part, 10) catch return null;

        const b: i32 = if (b_part.len == 0)
            0
        else
            std.fmt.parseInt(i32, b_part, 10) catch return null;

        return .{ .a = a, .b = b };
    }

    const only = std.fmt.parseInt(i32, expr, 10) catch return null;
    return .{ .a = 0, .b = only };
}

test "runtime selector parser covers all attribute operators" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "div[a][b=v][c^=x][d$=y][e*=z][f~=m][g|=en]");
    defer sel.deinit(alloc);
    try test_helpers.expectAllAttributeOps(sel);
}

test "runtime selector parser accepts attribute case flags" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "div[a=x][b=y i][c='Z' s]");
    defer sel.deinit(alloc);
    try test_helpers.expectAttributeCaseFlags(sel);
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
    try std.testing.expect(!sel.compounds[0].id.isEmpty());

    var sel2 = try compileRuntimeImpl(alloc, "#pseudos :nth-child(odd)");
    defer sel2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), sel2.compounds.len);
    try std.testing.expect(sel2.compounds[1].combinator == .descendant);
    try std.testing.expectEqual(@as(IndexInt, 1), sel2.compounds[1].pseudo_len);
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
        "div[attr i]",
        "div[attr=value q]",
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
