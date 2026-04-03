const std = @import("std");
const tables = @import("tables.zig");
const tags = @import("tags.zig");
const scanner = @import("scanner.zig");
const common = @import("../common.zig");

const InvalidIndex: IndexInt = common.InvalidIndex;
const IndexInt = common.IndexInt;
const SvgTagKey: u64 = tags.first8Key("svg");
const InitialParseStackCapacity: usize = 1024;
const MaxInitialNodeReserve: usize = 1 << 20;

// SAFETY: Parser builds in-place spans into `input`; indices are stored as `IndexInt`.
// We reject inputs larger than `IndexInt::max` to prevent truncation.

/// Parses mutable HTML bytes into `doc` using permissive, in-place tree construction.
pub fn parseInto(comptime Doc: type, noalias doc: *Doc, input: []u8, comptime opts: anytype) !void {
    if (!common.lenFits(input.len)) return error.InputTooLarge;
    var p = Parser(Doc, opts){
        .doc = doc,
        .input = input,
        .i = 0,
    };
    try p.parse();
}

fn Parser(comptime Doc: type, comptime opts: anytype) type {
    return struct {
        doc: *Doc,
        input: []u8,
        i: usize,

        const Self = @This();
        const OpenElem = Doc.OpenElemType;

        fn parse(noalias self: *Self) !void {
            try self.reserveCapacities();

            _ = try self.pushNode(.{
                .kind = .document,
                .subtree_end = 0,
            });
            try self.pushStack(0, 0, 0);

            try self.parseLoop(comptime opts.drop_whitespace_text_nodes);
            self.finishOpenElements();
        }

        fn parseLoop(noalias self: *Self, comptime drop_ws_text: bool) !void {
            while (self.i < self.input.len) {
                if (self.input[self.i] != '<') {
                    if (comptime drop_ws_text) {
                        try self.parseTextDropWhitespace();
                    } else {
                        try self.parseTextKeepWhitespace();
                    }
                    continue;
                }

                if (self.i + 1 >= self.input.len) {
                    @branchHint(.cold);
                    self.i += 1;
                    continue;
                }

                switch (self.input[self.i + 1]) {
                    '/' => self.parseClosingTag(),
                    '?' => self.skipPi(),
                    '!' => {
                        if (self.i + 3 < self.input.len and self.input[self.i + 2] == '-' and self.input[self.i + 3] == '-') {
                            self.skipComment();
                        } else {
                            @branchHint(.unlikely);
                            self.skipBangNode();
                        }
                    },
                    else => try self.parseOpeningTag(),
                }
            }
        }

        fn finishOpenElements(noalias self: *Self) void {
            while (self.doc.parse_stack.items.len > 1) {
                const open = self.doc.parse_stack.pop().?;
                var node = &self.doc.nodes.items[open.idx];
                node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
            self.doc.nodes.items[0].subtree_end = @intCast(self.doc.nodes.items.len - 1);
            self.doc.parse_stack.clearRetainingCapacity();
        }

        fn reserveCapacities(noalias self: *Self) !void {
            const alloc = self.doc.allocator;
            const input_len = self.input.len;

            var estimated_nodes: usize = undefined;
            if (opts.drop_whitespace_text_nodes) {
                estimated_nodes = @max(@as(usize, 32), (input_len / 32) + 32);
            } else {
                estimated_nodes = @max(@as(usize, 16), (input_len / 16) + 8);
            }

            // Keep startup reserves bounded so giant sparse/plaintext inputs do
            // not try to preallocate nodes proportional to total byte length.
            estimated_nodes = @min(estimated_nodes, MaxInitialNodeReserve);

            try self.doc.nodes.ensureTotalCapacity(alloc, estimated_nodes);
            try self.doc.parse_stack.ensureTotalCapacity(alloc, InitialParseStackCapacity);
        }

        inline fn parseTextKeepWhitespace(noalias self: *Self) !void {
            const start = self.i;
            self.i = scanner.findByte(self.input, self.i, '<') orelse self.input.len;
            if (self.i == start) return;

            const parent_idx = self.currentParent();
            const node_idx = try self.appendTextNode(parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.name_or_text = .{ .start = @intCast(start), .end = @intCast(self.i) };
            node.subtree_end = node_idx;
        }

        inline fn parseTextDropWhitespace(noalias self: *Self) !void {
            const start = self.i;
            const scanned = scanner.scanTextRun(self.input, self.i);
            self.i = scanned.lt_index;
            if (self.i == start) return;
            if (!scanned.has_non_whitespace) return;

            const parent_idx = self.currentParent();
            const node_idx = try self.appendTextNode(parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.name_or_text = .{ .start = @intCast(start), .end = @intCast(self.i) };
            node.subtree_end = node_idx;
        }

        fn parseOpeningTag(noalias self: *Self) !void {
            self.i += 1; // <
            self.skipWs();

            const name_start = self.i;
            var tag_name_key: u64 = 0;
            var tag_name_key_len: u8 = 0;
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                if (tag_name_key_len < 8) {
                    var c = self.input[self.i];
                    if (c >= 'A' and c <= 'Z') {
                        c = tables.lower(c);
                        self.input[self.i] = c;
                    }
                    tag_name_key |= @as(u64, c) << @as(u6, @intCast(tag_name_key_len * 8));
                    tag_name_key_len += 1;
                }
            }

            if (self.i == name_start) {
                @branchHint(.cold);
                // malformed tag, consume one byte and move on
                self.i = @min(self.i + 1, self.input.len);
                return;
            }

            const tag_name = self.input[name_start..self.i];
            const name_end = self.i;

            if (self.doc.parse_stack.items.len > 1 and tags.mayTriggerImplicitCloseWithKey(tag_name, tag_name_key)) {
                self.applyImplicitClosures(tag_name, tag_name_key);
            }

            var attr_bytes_end: usize = self.i;
            const attr_bytes_start: usize = self.i;
            var tag_gt_index: usize = self.i;

            if (self.i < self.input.len and self.input[self.i] == '>') {
                tag_gt_index = self.i;
                attr_bytes_end = self.i;
                self.i += 1;
            } else if (scanner.findTagEndRespectQuotes(self.input, self.i)) |tag_end| {
                tag_gt_index = tag_end.gt_index;
                attr_bytes_end = tag_end.attr_end;
                self.i = tag_end.gt_index + 1;
            } else {
                @branchHint(.cold);
                attr_bytes_end = self.input.len;
                self.i = self.input.len;
                tag_gt_index = self.input.len;
            }

            if (self.i == self.input.len and attr_bytes_end < self.i) {
                attr_bytes_end = self.i;
            }

            const self_close = tag_name.len <= 6 and tags.isVoidTagWithKey(tag_name, tag_name_key);

            // Skip SVG subtrees entirely to keep parse work focused on primary HTML
            // content. Nested <svg> blocks are counted; `<svg` in quoted attributes
            // is ignored by quote-aware tag-end scanning.
            if (isSvgTag(tag_name, tag_name_key)) {
                const svg_self_close = scanner.isExplicitSelfClosingTag(self.input, attr_bytes_start, tag_gt_index);
                const parent_idx = self.currentParent();
                const node_idx = try self.appendElementNode(parent_idx);
                var node = &self.doc.nodes.items[node_idx];
                node.name_or_text = .{ .start = @intCast(name_start), .end = @intCast(name_end) };
                node.attr_end = @intCast(attr_bytes_end);
                if (svg_self_close) {
                    node.subtree_end = node_idx;
                    return;
                }

                const content_start = self.i;
                if (scanner.findSvgSubtreeEnd(self.input, self.i)) |close_end| {
                    var content_end = close_end;
                    while (content_end > content_start and self.input[content_end - 1] != '<') : (content_end -= 1) {}

                    if (content_end > content_start) {
                        const text_idx = try self.appendTextNode(node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.name_or_text = .{ .start = @intCast(content_start), .end = @intCast(content_end - 1) };
                        text_node.subtree_end = text_idx;
                    }

                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = close_end;
                    return;
                } else {
                    if (self.input.len > content_start) {
                        const text_idx = try self.appendTextNode(node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.name_or_text = .{ .start = @intCast(content_start), .end = @intCast(self.input.len) };
                        text_node.subtree_end = text_idx;
                    }
                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = self.input.len;
                    return;
                }
            }

            const parent_idx = self.currentParent();
            const node_idx = try self.appendElementNode(parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.name_or_text = .{ .start = @intCast(name_start), .end = @intCast(name_end) };
            node.attr_end = @intCast(attr_bytes_end);

            if (!self_close and tags.isPlainTextTagWithKey(tag_name, tag_name_key)) {
                const content_start = self.i;
                if (self.input.len > content_start) {
                    const text_idx = try self.appendTextNode(node_idx);
                    var text_node = &self.doc.nodes.items[text_idx];
                    text_node.name_or_text = .{ .start = @intCast(content_start), .end = @intCast(self.input.len) };
                    text_node.subtree_end = text_idx;
                }

                node = &self.doc.nodes.items[node_idx];
                node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                self.i = self.input.len;
                return;
            }

            if (!self_close and tags.isRawTextTagWithKey(tag_name, tag_name_key)) {
                const content_start = self.i;
                if (self.findRawTextClose(tag_name, self.i)) |close| {
                    if (close.content_end > content_start) {
                        const text_idx = try self.appendTextNode(node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.name_or_text = .{ .start = @intCast(content_start), .end = @intCast(close.content_end) };
                        text_node.subtree_end = text_idx;
                    }

                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = close.close_end;
                    return;
                } else {
                    @branchHint(.cold);
                    if (self.input.len > content_start) {
                        const text_idx = try self.appendTextNode(node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.name_or_text = .{ .start = @intCast(content_start), .end = @intCast(self.input.len) };
                        text_node.subtree_end = text_idx;
                    }
                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = self.input.len;
                    return;
                }
            }

            if (self_close) {
                node.subtree_end = node_idx;
                return;
            }

            self.skipDroppedWhitespaceAfterStartTag();
            try self.pushStack(node_idx, tag_name_key, @intCast(tag_name.len));
        }

        fn parseClosingTag(noalias self: *Self) void {
            self.i += 2; // </
            self.skipWs();

            const name_start = self.i;
            var close_key: u64 = 0;
            var close_key_len: u8 = 0;
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                if (close_key_len < 8) {
                    var c = self.input[self.i];
                    if (c >= 'A' and c <= 'Z') {
                        c = tables.lower(c);
                        self.input[self.i] = c;
                    }
                    close_key |= @as(u64, c) << @as(u6, @intCast(close_key_len * 8));
                    close_key_len += 1;
                }
            }
            const name_end = self.i;
            const close_name = self.input[name_start..name_end];

            if (self.i < self.input.len and self.input[self.i] == '>') {
                self.i += 1;
            } else {
                self.i = scanner.findByte(self.input, self.i, '>') orelse self.input.len;
                if (self.i < self.input.len) self.i += 1;
            }

            if (close_name.len == 0) {
                @branchHint(.cold);
                return;
            }

            if (self.doc.parse_stack.items.len > 1) {
                const top = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                if (self.openElemMatchesClose(top, close_name, close_key)) {
                    _ = self.doc.parse_stack.pop();
                    var node = &self.doc.nodes.items[top.idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    return;
                }
            }

            var found: ?usize = null;
            var s = self.doc.parse_stack.items.len;
            while (s > 1) {
                s -= 1;
                const open = self.doc.parse_stack.items[s];
                if (!self.openElemMatchesClose(open, close_name, close_key)) continue;
                found = s;
                break;
            }

            if (found) |pos| {
                while (self.doc.parse_stack.items.len > pos) {
                    const open = self.doc.parse_stack.pop().?;
                    var node = &self.doc.nodes.items[open.idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                }
            } else {
                @branchHint(.unlikely);
            }
        }

        inline fn applyImplicitClosures(noalias self: *Self, new_tag: []const u8, new_tag_key: u64) void {
            while (self.doc.parse_stack.items.len > 1) {
                const top = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                if (!tags.isImplicitCloseSourceWithLenAndKey(top.tag_len, top.tag_key)) break;
                if (!tags.shouldImplicitlyCloseWithLenAndKey(top.tag_len, top.tag_key, new_tag, new_tag_key)) break;

                _ = self.doc.parse_stack.pop();
                var n = &self.doc.nodes.items[top.idx];
                n.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
        }

        fn appendTextNode(noalias self: *Self, parent_idx: IndexInt) !IndexInt {
            const idx: IndexInt = @intCast(self.doc.nodes.items.len);
            const node: @TypeOf(self.doc.nodes.items[0]) = .{
                .kind = .text,
                .parent = parent_idx,
                .subtree_end = idx,
            };
            _ = try self.pushNode(node);
            return idx;
        }

        fn appendElementNode(noalias self: *Self, parent_idx: IndexInt) !IndexInt {
            const idx: IndexInt = @intCast(self.doc.nodes.items.len);
            const node: @TypeOf(self.doc.nodes.items[0]) = .{
                .kind = .element,
                .parent = parent_idx,
                .subtree_end = idx,
            };

            _ = try self.pushNode(node);

            if (parent_idx != InvalidIndex) {
                var p = &self.doc.nodes.items[parent_idx];
                if (p.last_child == InvalidIndex) {
                    p.last_child = idx;
                } else {
                    const prev = p.last_child;
                    self.doc.nodes.items[idx].prev_sibling = prev;
                    p.last_child = idx;
                }
            }

            return idx;
        }

        const appendAlloc = common.appendAlloc;
        fn pushNode(noalias self: *Self, node: @TypeOf(self.doc.nodes.items[0])) !IndexInt {
            const len = self.doc.nodes.items.len;
            try appendAlloc(@TypeOf(node), &self.doc.nodes, self.doc.allocator, node);
            return @intCast(len);
        }

        fn pushStack(noalias self: *Self, idx: IndexInt, tag_key: u64, tag_len: u16) !void {
            try appendAlloc(OpenElem, &self.doc.parse_stack, self.doc.allocator, .{
                .idx = idx,
                .tag_key = tag_key,
                .tag_len = tag_len,
            });
        }

        inline fn currentParent(noalias self: *Self) IndexInt {
            if (self.doc.parse_stack.items.len == 0) return InvalidIndex;
            return self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1].idx;
        }

        inline fn openElemMatchesClose(noalias self: *Self, open: OpenElem, close_name: []const u8, close_key: u64) bool {
            if (open.tag_len != close_name.len or open.tag_key != close_key) return false;
            if (close_name.len <= 8) return true;
            const open_name = self.doc.nodes.items[open.idx].name_or_text.slice(self.input);
            return tables.eqlIgnoreCaseAscii(open_name[8..], close_name[8..]);
        }

        fn skipComment(noalias self: *Self) void {
            self.i += 4;
            if (self.i < self.input.len and self.input[self.i] == '>') {
                // Fast-path malformed short comment form: "<!-->"
                self.i += 1;
                return;
            }

            var j = self.i;
            while (j + 2 < self.input.len) {
                const dash = scanner.findByte(self.input, j, '-') orelse {
                    @branchHint(.cold);
                    self.i = self.input.len;
                    return;
                };
                if (dash + 2 < self.input.len and self.input[dash + 1] == '-' and self.input[dash + 2] == '>') {
                    self.i = dash + 3;
                    return;
                }
                j = dash + 1;
            }
            self.i = self.input.len;
        }

        fn skipBangNode(noalias self: *Self) void {
            self.i += 2;
            if (scanner.findTagEndRespectQuotes(self.input, self.i)) |tag_end| {
                self.i = tag_end.gt_index + 1;
            } else {
                self.i = self.input.len;
            }
        }

        fn skipPi(noalias self: *Self) void {
            self.i += 2;
            self.i = scanner.findByte(self.input, self.i, '>') orelse self.input.len;
            if (self.i < self.input.len) self.i += 1;
        }

        inline fn skipWs(noalias self: *Self) void {
            while (self.i < self.input.len and tables.WhitespaceTable[self.input[self.i]]) : (self.i += 1) {}
        }

        inline fn skipDroppedWhitespaceAfterStartTag(noalias self: *Self) void {
            if (!opts.drop_whitespace_text_nodes) return;
            if (self.i >= self.input.len or !tables.WhitespaceTable[self.input[self.i]]) return;

            var j = self.i + 1;
            while (j < self.input.len and tables.WhitespaceTable[self.input[j]]) : (j += 1) {}
            if (j < self.input.len and self.input[j] == '<') {
                self.i = j;
            }
        }

        inline fn isSvgTag(tag_name: []const u8, tag_key: u64) bool {
            return tag_name.len == 3 and tag_key == SvgTagKey;
        }

        inline fn findRawTextClose(noalias self: *Self, tag_name: []const u8, start: usize) ?struct { content_end: usize, close_end: usize } {
            var j = scanner.findByte(self.input, start, '<') orelse return null;
            const tag_len = tag_name.len;
            if (tag_len == 0) return null;
            const tag_key = tags.first8Key(tag_name);
            const first = tables.lower(tag_name[0]);
            while (j + 3 < self.input.len) {
                if (self.input[j + 1] != '/') {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }
                if (j + 2 >= self.input.len or tables.lower(self.input[j + 2]) != first) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                var k = j + 2;
                const name_start = k;
                var close_key: u64 = 0;
                var close_key_len: u8 = 0;
                while (k < self.input.len and tables.TagNameCharTable[self.input[k]]) : (k += 1) {}
                {
                    var p = name_start;
                    while (p < k and close_key_len < 8) : (p += 1) {
                        close_key |= @as(u64, tables.lower(self.input[p])) << @as(u6, @intCast(close_key_len * 8));
                        close_key_len += 1;
                    }
                }
                if (k == name_start) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                if (k - name_start != tag_len or close_key != tag_key) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                while (k < self.input.len and tables.WhitespaceTable[self.input[k]]) : (k += 1) {}
                if (k >= self.input.len or self.input[k] != '>') {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                return .{
                    .content_end = j,
                    .close_end = k + 1,
                };
            }
            return null;
        }
    };
}
