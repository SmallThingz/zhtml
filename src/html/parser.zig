const std = @import("std");
const tables = @import("tables.zig");
const tags = @import("tags.zig");
const scanner = @import("scanner.zig");
const common = @import("../common.zig");
const document = @import("document.zig");

const ParseOptions = document.ParseOptions;
const RawNode = document.RawNode;

const InvalidIndex: IndexInt = common.InvalidIndex;
const IndexInt = common.IndexInt;
const SvgTagKey: u64 = tags.first8Key("svg");
const InitialParseStackCapacity: usize = 1024;
const MaxInitialNodeReserve: usize = 1 << 20;

// SAFETY: Parser builds spans into `input`; indices are stored as `IndexInt`.
// In destructive mode tag names are normalized in-place. In non-destructive mode
// parsing is read-only and any lazy decode work happens outside this file.

/// Parses `input` and returns a fully owned document for `opts`.
pub fn parse(comptime opts: ParseOptions, allocator: std.mem.Allocator, input: opts.Input()) !opts.Document() {
    if (!common.lenFits(input.len)) return error.InputTooLarge;

    const Doc = opts.Document();
    var doc = Doc.init(allocator);
    errdefer doc.deinit();
    doc.source = input;

    var node_buf: std.ArrayListUnmanaged(RawNode) = .empty;
    errdefer node_buf.deinit(allocator);

    var state = ParseState(opts){
        .doc = &doc,
        .input = input,
        .i = 0,
        .nodes = &node_buf,
    };
    try state.parse();

    doc.nodes = try node_buf.toOwnedSlice(allocator);
    return doc;
}

fn ParseState(comptime opts: ParseOptions) type {
    return struct {
        /// Document being populated with completed parse output.
        doc: *opts.Document(),
        /// Source bytes being tokenized for this parse pass.
        input: []const u8,
        /// Current byte cursor inside `input`.
        i: usize,
        /// Growable node buffer owned by parser during tree construction.
        nodes: *std.ArrayListUnmanaged(RawNode),
        /// Open-element stack used only while building the tree.
        parse_stack: std.ArrayListUnmanaged(OpenElem) = .empty,

        const Self = @This();
        const OpenElem = struct {
            /// First-8-bytes lowercase key for the open tag name.
            tag_key: u64 = 0,
            /// Node index of the open element.
            idx: IndexInt,
            /// Original tag-name length for close matching and optional-close logic.
            tag_len: u16 = 0,
        };

        /// Reserve capacities + add initial values to containers
        inline fn initContainers(noalias self: *Self) !void {
            const alloc = self.doc.allocator;
            const input_len = self.input.len;

            var estimated_nodes: usize = undefined;
            // Fastest mode tends to collapse pure-whitespace runs, so its node
            // count grows more slowly than strict mode on the same input bytes.
            if (opts.drop_whitespace_text_nodes) {
                estimated_nodes = @max(@as(usize, 32), (input_len / 32) + 32);
            } else {
                estimated_nodes = @max(@as(usize, 16), (input_len / 16) + 8);
            }

            // Keep startup reserves bounded so giant sparse/plaintext inputs do
            // not try to preallocate nodes proportional to total byte length.
            estimated_nodes = @min(estimated_nodes, MaxInitialNodeReserve);

            try self.nodes.ensureTotalCapacity(alloc, estimated_nodes);
            try self.parse_stack.ensureTotalCapacity(alloc, InitialParseStackCapacity);

            // Seed the synthetic document root so every parsed node has a stable
            // parent chain and the open-element stack always has a sentinel.
            self.nodes.appendAssumeCapacity(.{
                .name_or_text = .{ .start = 0, .end = 0 },
                .attr_end = .text_node,
                .last_child = InvalidIndex,
                .prev_sibling = InvalidIndex,
                .parent = InvalidIndex,
                .subtree_end = 0,
            });
            self.parse_stack.appendAssumeCapacity(.{
                .idx = 0,
                .tag_key = 0,
                .tag_len = 0,
            });
        }

        inline fn parse(noalias self: *Self) !void {
            defer self.parse_stack.deinit(self.doc.allocator);
            try self.initContainers();

            // Main tokenization loop. Text spans and tags are dispatched here,
            // while specialized helpers handle the actual node construction.
            while (self.i + 1 < self.input.len) {
                if (self.input[self.i] != '<') {
                    try self.handleText();
                } else switch (self.input[self.i + 1]) {
                    '/' => self.parseClosingTag(),
                    '?' => {
                        @branchHint(.cold);
                        self.skipPi();
                    },
                    '!' => {
                        @branchHint(.unlikely);
                        if (self.i + 3 < self.input.len and self.input[self.i + 2] == '-' and self.input[self.i + 3] == '-') {
                            self.skipComment();
                        } else {
                            @branchHint(.cold);
                            self.skipBangNode();
                        }
                    },
                    else => try self.parseOpeningTag(),
                }
            }

            // Handle the last char; only possibility: self.i == self.input.len - 1
            if (self.i == self.input.len - 1) {
                const parent_idx = self.currentParent();
                const last_idx = self.nodes.items.len - 1;
                const last = &self.nodes.items[last_idx];
                if (last.isText(@intCast(last_idx)) and last.parent == parent_idx and last.name_or_text.end == self.i) {
                    last.name_or_text.end = @intCast(self.input.len);
                } else {
                    if (!(comptime opts.drop_whitespace_text_nodes) or !tables.WhitespaceTable[self.input[self.i]]) {
                        try self.addNode(.{self.i, self.input.len}, .text_node, .{});
                    }
                }
                self.i += 1;
            }
            std.debug.assert(self.i == self.input.len);

            // Any elements still on the open stack are implicitly closed at EOF.
            // Their subtrees end at the final parsed node.
            for (self.parse_stack.items) |open| self.nodes.items[open.idx].subtree_end = @intCast(self.nodes.items.len - 1);
            self.nodes.items[0].subtree_end = @intCast(self.nodes.items.len - 1);
            self.parse_stack.clearRetainingCapacity();
        }

        inline fn handleText(noalias self: *Self) !void {
            std.debug.assert(self.input[self.i] != '<');
            std.debug.assert(self.i < self.input.len - 1);

            const start = self.i;
            if (comptime opts.drop_whitespace_text_nodes) {
                self.skipWs();
                if (self.i == self.input.len) {
                    @branchHint(.cold);
                    return;
                }

                // likely to hit a tag after ws on normal documents
                if (self.input[self.i] == '<') return;
            }

            self.i = std.mem.indexOfScalarPos(u8, self.input, self.i, '<') orelse self.input.len;
            try self.addNode(.{start, self.i}, .text_node, .{});
        }

        /// Intended to be called from inside of parseOpeningTag to parse the remaining contents as text
        inline fn handleInvalidOpeningTag(noalias self: *Self, start: IndexInt) !void {
            const parent_idx = self.currentParent();
            const last = &self.nodes.items[self.nodes.items.len - 1];
            self.i = std.mem.indexOfScalarPos(u8, self.input, self.i, '<') orelse self.input.len;
            if (last.isText(@intCast(self.nodes.items.len - 1)) and last.parent == parent_idx and last.name_or_text.end == start) { // Merge the node if the last node is text already
                last.name_or_text.end = @intCast(self.i);
            } else { // append new node if last node was not text
                try self.addNode(.{start, self.i}, .text_node, .{});
            }

            std.debug.assert(self.i >= self.input.len - 1 or self.input[self.i] == '<');
        }

        /// Intended to be called from inside of parseOpeningTag to parse the remaining contents as text
        /// Skip SVG subtrees entirely to keep parse work focused on primary HTML content.
        /// Nested <svg> blocks are counted; `<svg` in quoted attributes is ignored by quote-aware tag-end scanning.
        inline fn handleSvgTag(
            noalias self: *Self,
            name_start: usize,
            name_end: usize,
            attr_end: usize,
        ) !void {
            const parent_idx: IndexInt = @intCast(self.nodes.items.len);
            try self.addNode(.{name_start, name_end}, @enumFromInt(attr_end), .{});
            if (self.input[attr_end - 1] == '/') return;

            const content_start = self.i;
            const end = blk: {
                if (scanner.findSvgSubtreeEnd(self.input, self.i)) |end| {
                    self.i = end.gt_index + 1;
                    break :blk end;
                } else {
                    self.i = self.input.len;
                    break :blk scanner.SvgEnd{ .gt_index = self.i, .content_end = self.i };
                }
            };
            if (content_start < end.content_end) {
                @branchHint(.likely);
                self.nodes.items[parent_idx].subtree_end = @intCast(self.nodes.items.len);
                try self.addNode(.{content_start, end.content_end}, .text_node, .{.parent = parent_idx});
            }
        }

        inline fn parseOpeningTag(noalias self: *Self) !void {
            self.i += 1; // <
            // no whitespace after `<` is allowed, same behavior as browser

            const name_start = self.i;
            var tag_name_key: u64 = 0;
            var tag_name_key_len: u8 = 0;
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                if (tag_name_key_len < 8) {
                    var c = self.input[self.i];
                    c = tables.lower(c);
                    if (!comptime opts.non_destructive) {
                        @constCast(self.input)[self.i] = c;
                    }
                    tag_name_key |= @as(u64, c) << @as(u6, @intCast(tag_name_key_len * 8));
                    tag_name_key_len += 1;
                }
            }
            const name_end = self.i;
            const tag_name = self.input[name_start..name_end];

            // Handle malformed input similar to browser; treated the `<` as text only
            if (name_end == name_start or self.i >= self.input.len) {
                @branchHint(.cold);
                return self.handleInvalidOpeningTag(@intCast(name_start - 1));
            }

            const attr_end: usize = blk: {
                if (self.input[self.i] == '>') {
                    defer self.i += 1;
                    break :blk self.i;
                } else if (scanner.findTagEndRespectQuotes(self.input, self.i)) |v| {
                    self.i = v.gt_index + 1;
                    break :blk v.attr_end;
                } else {
                    @branchHint(.cold);
                    // invalid tag, skip content; same as browser
                    self.i = self.input.len;
                    return;
                }
            };

            // In case this is an svg tag: Note: we still treat svg's attribute like we do html attributes which is not 100% correct
            // This is preferred over the complications that arise from parsing as xml tho
            if (isSvgTag(tag_name, tag_name_key)) {
                return self.handleSvgTag(name_start, name_end, attr_end);
            } else if (tags.isPlainTextTagWithKey(tag_name, tag_name_key)) {
                // Plaintext tags consume the rest of the document as one text child.
                const parent_idx: IndexInt = @intCast(self.nodes.items.len);
                try self.addNode(.{name_start, name_end}, @enumFromInt(attr_end), .{});
                if (self.i < self.input.len) {
                    @branchHint(.likely);
                    self.nodes.items[parent_idx].subtree_end = @intCast(self.nodes.items.len);
                    try self.addNode(.{self.i, self.input.len}, .text_node, .{.parent = parent_idx});
                }
                self.i = self.input.len;
                return;
            } else if (tags.isRawTextTagWithKey(tag_name, tag_name_key)) {
                // Raw-text tags stay structured as elements, but their contents are
                // copied as one opaque text child up to the matching close tag.
                const parent_idx: IndexInt = @intCast(self.nodes.items.len);
                try self.addNode(.{name_start, name_end}, @enumFromInt(attr_end), .{});

                const content_start = self.i;
                const content_end = blk: {
                    if (self.findRawTextClose(tag_name, self.i)) |close| {
                        self.i = close.close_end;
                        break :blk close.content_end;
                    } else {
                        self.i = self.input.len;
                        break :blk self.i;
                    }
                };

                if (content_start < content_end) {
                    @branchHint(.likely);
                    self.nodes.items[parent_idx].subtree_end = @intCast(self.nodes.items.len);
                    try self.addNode(.{content_start, content_end}, .text_node, .{.parent = parent_idx});
                }
                return;
            }

            // Optional-close HTML elements are resolved before the new element
            // is appended so sibling/parent links reflect the implied structure.
            if (self.parse_stack.items.len > 1 and tags.mayTriggerImplicitCloseWithKey(tag_name, tag_name_key)) {
                self.applyImplicitClosures(tag_name, tag_name_key);
            }

            const node_idx = self.nodes.items.len;
            try self.addNode(.{name_start, name_end}, @enumFromInt(attr_end), .{});

            if (tags.isVoidTagWithKey(tag_name, tag_name_key)) return;

            // Non-void, non-raw elements stay on the open stack until an
            // explicit close, an optional-close rule, or EOF pops them.
            try self.parse_stack.append(self.doc.allocator, .{.idx = @intCast(node_idx), .tag_key = tag_name_key, .tag_len = @intCast(tag_name.len)});
        }

        inline fn parseClosingTag(noalias self: *Self) void {
            self.i += 2; // </

            const name_start = self.i;
            var close_key: u64 = 0;
            var close_key_len: u8 = 0;
            // Closing tags rebuild the same first-8-bytes key so stack matching
            // usually avoids slicing the stored element name.
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                if (close_key_len < 8) {
                    var c = self.input[self.i];
                    c = tables.lower(c);
                    if (!comptime opts.non_destructive) {
                        @constCast(self.input)[self.i] = c;
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
                self.i = 1 + (std.mem.indexOfScalarPos(u8, self.input, self.i, '>') orelse (self.input.len - 1));
            }

            if (close_name.len == 0 or self.parse_stack.items.len == 0) { // same behavior as browser; skip this
                @branchHint(.cold);
                return;
            }

            const top = self.parse_stack.items[self.parse_stack.items.len - 1];
            // Fast path: most closing tags match the current open element.
            if (self.openElemMatchesClose(top, close_name, close_key)) {
                @branchHint(.likely);
                _ = self.parse_stack.pop();
                var node = &self.nodes.items[top.idx];
                node.subtree_end = @intCast(self.nodes.items.len - 1);
                return;
            }

            var found: ?usize = null;
            var s = self.parse_stack.items.len - 1;
            while (s > 1) {
                s -= 1;
                const open = self.parse_stack.items[s];
                if (!self.openElemMatchesClose(open, close_name, close_key)) continue;
                found = s;
                break;
            }

            if (found) |pos| {
                @branchHint(.likely);
                // Permissive recovery: pop everything above the matched opener.
                while (self.parse_stack.items.len > pos) {
                    const open = self.parse_stack.pop().?;
                    var node = &self.nodes.items[open.idx];
                    node.subtree_end = @intCast(self.nodes.items.len - 1);
                }
            } else {
                @branchHint(.unlikely);
            }
        }

        inline fn applyImplicitClosures(noalias self: *Self, new_tag: []const u8, new_tag_key: u64) void {
            while (self.parse_stack.items.len > 1) {
                const top = self.parse_stack.items[self.parse_stack.items.len - 1];
                if (!tags.isImplicitCloseSourceWithLenAndKey(top.tag_len, top.tag_key)) break;
                if (!tags.shouldImplicitlyCloseWithLenAndKey(top.tag_len, top.tag_key, new_tag, new_tag_key)) break;

                // Optional-close rules rewrite nesting into sibling structure
                // before the incoming tag is appended.
                _ = self.parse_stack.pop();
                var n = &self.nodes.items[top.idx];
                n.subtree_end = @intCast(self.nodes.items.len - 1);
            }
        }

        inline fn addNode(noalias self: *Self, name_or_text: anytype, attr_end: document.RawNode.AttrEnd, overrides: anytype) !void {
            const Overrides = @TypeOf(overrides);
            comptime for (@typeInfo(Overrides).@"struct".fields) |field| {
                std.debug.assert(std.mem.eql(u8, field.name, "parent"));
            };
            const parent_idx: IndexInt = @intCast(if (@hasField(Overrides, "parent")) overrides.parent else self.currentParent());
            const idx: IndexInt = @intCast(self.nodes.items.len);

            try self.nodes.append(self.doc.allocator, .{
                .name_or_text = .{
                    .start = @intCast(name_or_text[0]),
                    .end = @intCast(name_or_text[1]),
                },
                .attr_end = attr_end,
                .last_child = InvalidIndex,
                .prev_sibling = self.nodes.items[parent_idx].last_child,
                .parent = parent_idx,
                .subtree_end = idx,
            });
            self.nodes.items[parent_idx].last_child = idx;
        }

        inline fn currentParent(noalias self: *Self) IndexInt {
            std.debug.assert(self.parse_stack.items.len != 0);
            return self.parse_stack.items[self.parse_stack.items.len - 1].idx;
        }

        inline fn openElemMatchesClose(noalias self: *Self, open: OpenElem, close_name: []const u8, close_key: u64) bool {
            // Length + key rejects the common non-match case without touching
            // the stored tag bytes. Long names only compare the tail on a hit.
            if (open.tag_len != close_name.len or open.tag_key != close_key) return false;
            if (close_name.len <= 8) return true;
            const open_name = self.nodes.items[open.idx].name_or_text.slice(self.input);
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
                const dash = std.mem.indexOfScalarPos(u8, self.input, j, '-') orelse {
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
            // Doctype-like nodes are skipped as opaque declarations.
            if (scanner.findTagEndRespectQuotes(self.input, self.i)) |tag_end| {
                self.i = tag_end.gt_index + 1;
            } else {
                self.i = self.input.len;
            }
        }

        inline fn skipPi(noalias self: *Self) void {
            self.i += 2;
            // Processing-instruction-like forms are treated as opaque and end at
            // the next `>`.
            self.i = std.mem.indexOfScalarPos(u8, self.input, self.i, '>') orelse self.input.len;
            if (self.i < self.input.len) self.i += 1;
        }

        inline fn skipWs(noalias self: *Self) void {
            while (self.i < self.input.len and tables.WhitespaceTable[self.input[self.i]]) : (self.i += 1) {}
        }

        inline fn isSvgTag(tag_name: []const u8, tag_key: u64) bool {
            return tag_name.len == 3 and tag_key == SvgTagKey;
        }

        inline fn findRawTextClose(noalias self: *Self, tag_name: []const u8, start: usize) ?struct { content_end: usize, close_end: usize } {
            // Raw-text scanning only recognizes a real `</tag>` terminator.
            // Everything else, including stray `<` bytes, stays in the text run.
            var j = std.mem.indexOfScalarPos(u8, self.input, start, '<') orelse return null;
            const tag_len = tag_name.len;
            if (tag_len == 0) return null;
            const tag_key = tags.first8Key(tag_name);
            const first = tables.lower(tag_name[0]);
            while (j + 3 < self.input.len) {
                if (self.input[j + 1] != '/') {
                    j = std.mem.indexOfScalarPos(u8, self.input, j + 1, '<') orelse return null;
                    continue;
                }
                if (j + 2 >= self.input.len or tables.lower(self.input[j + 2]) != first) {
                    j = std.mem.indexOfScalarPos(u8, self.input, j + 1, '<') orelse return null;
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
                    j = std.mem.indexOfScalarPos(u8, self.input, j + 1, '<') orelse return null;
                    continue;
                }

                if (k - name_start != tag_len or close_key != tag_key) {
                    j = std.mem.indexOfScalarPos(u8, self.input, j + 1, '<') orelse return null;
                    continue;
                }

                while (k < self.input.len and tables.WhitespaceTable[self.input[k]]) : (k += 1) {}
                if (k >= self.input.len or self.input[k] != '>') {
                    j = std.mem.indexOfScalarPos(u8, self.input, j + 1, '<') orelse return null;
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

const DefaultTestOptions: ParseOptions = .{};
const StrictTestOptions: ParseOptions = .{ .drop_whitespace_text_nodes = false };
const NonDestructiveTestOptions: ParseOptions = .{ .non_destructive = true };
const TestDocument = DefaultTestOptions.Document();
const StrictTestDocument = StrictTestOptions.Document();
const NonDestructiveTestDocument = NonDestructiveTestOptions.Document();

fn resetParsed(comptime options: ParseOptions, doc: *options.Document(), input: options.Input()) !void {
    doc.deinit();
    doc.* = try options.parse(doc.allocator, input);
}

fn expectDocumentStructureValid(doc: anytype) !void {
    const testing = std.testing;
    const nodes = doc.nodes;
    try testing.expect(nodes.len >= 1);
    try testing.expect(nodes[0].attr_end == .text_node);
    try testing.expect(nodes[0].parent == InvalidIndex);
    try testing.expectEqual(@as(IndexInt, @intCast(nodes.len - 1)), nodes[0].subtree_end);

    for (nodes, 0..) |node, i| {
        const idx: IndexInt = @intCast(i);
        const is_text = idx != 0 and node.attr_end == .text_node;
        const is_element = idx != 0 and node.attr_end != .text_node;
        const span_start: usize = @intCast(node.name_or_text.start);
        const span_end: usize = @intCast(node.name_or_text.end);

        try testing.expect(span_start <= span_end);
        try testing.expect(span_end <= doc.source.len);
        try testing.expect(node.subtree_end >= idx);
        try testing.expect(@as(usize, @intCast(node.subtree_end)) < nodes.len);

        if (is_element) {
            const attr_end: usize = @intCast(@intFromEnum(node.attr_end));
            try testing.expect(span_end <= attr_end);
            try testing.expect(attr_end <= doc.source.len);
        }

        if (node.parent == InvalidIndex) {
            try testing.expectEqual(@as(usize, 0), i);
        } else {
            const parent_idx: usize = @intCast(node.parent);
            try testing.expect(parent_idx < nodes.len);
            try testing.expect(parent_idx == 0 or nodes[parent_idx].attr_end != .text_node);
            try testing.expect(nodes[parent_idx].subtree_end >= idx);
        }

        if (node.prev_sibling != InvalidIndex) {
            const prev_idx: usize = @intCast(node.prev_sibling);
            try testing.expect(prev_idx < i);
            try testing.expectEqual(node.parent, nodes[prev_idx].parent);
            try testing.expect(@as(usize, @intCast(nodes[prev_idx].subtree_end)) < i);
        }

        if (node.last_child != InvalidIndex) {
            const last_child_idx: usize = @intCast(node.last_child);
            try testing.expect(!is_text);
            try testing.expect(last_child_idx > i);
            try testing.expect(last_child_idx <= @as(usize, @intCast(node.subtree_end)));
            try testing.expectEqual(idx, nodes[last_child_idx].parent);
            try testing.expect(i + 1 < nodes.len);
            try testing.expectEqual(idx, nodes[i + 1].parent);
        } else if (is_text) {
            try testing.expectEqual(InvalidIndex, node.last_child);
        }
    }
}

fn expectEquivalentStructures(a: *const TestDocument, b: *const NonDestructiveTestDocument) !void {
    const testing = std.testing;
    try testing.expectEqual(a.nodes.len, b.nodes.len);

    for (a.nodes, b.nodes) |lhs, rhs| {
        try testing.expectEqual(lhs.name_or_text.start, rhs.name_or_text.start);
        try testing.expectEqual(lhs.name_or_text.end, rhs.name_or_text.end);
        try testing.expectEqual(lhs.attr_end, rhs.attr_end);
        try testing.expectEqual(lhs.last_child, rhs.last_child);
        try testing.expectEqual(lhs.prev_sibling, rhs.prev_sibling);
        try testing.expectEqual(lhs.parent, rhs.parent);
        try testing.expectEqual(lhs.subtree_end, rhs.subtree_end);
    }
}

fn expectRuntimeQueryParity(a: *TestDocument, b: *NonDestructiveTestDocument, selector: []const u8) !void {
    const testing = std.testing;
    const lhs = try a.queryOneRuntime(testing.allocator, selector);
    const rhs = try b.queryOneRuntime(testing.allocator, selector);
    try testing.expect((lhs == null) == (rhs == null));
    if (lhs) |left_node| {
        try testing.expectEqual(left_node.index, rhs.?.index);
    }
}

fn exerciseRuntimeApis(doc: anytype, alloc: std.mem.Allocator) !void {
    const selectors = [_][]const u8{
        "div",
        "span",
        "script",
        "svg",
        "img",
        "#x",
        ".a",
        "[href]",
        "body > *",
        "a[href^=http]",
        "div[class~=item]",
    };

    inline for (selectors) |selector| {
        _ = try doc.queryOneRuntime(alloc, selector);
    }

    var visited: usize = 0;
    var idx: usize = 0;
    while (idx < doc.nodes.len and visited < 16) : (idx += 1) {
        const node = doc.nodeAt(@intCast(idx)) orelse continue;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        if (doc.nodes[idx].isElement(@intCast(idx))) {
            if (comptime @FieldType(@TypeOf(doc.*), "source") == []const u8) {
                _ = node.getAttributeValueAlloc(arena.allocator(), "id");
                _ = node.getAttributeValueAlloc(arena.allocator(), "class");
                _ = node.getAttributeValueAlloc(arena.allocator(), "href");
                _ = node.getAttributeValueAlloc(arena.allocator(), "data-v");
            } else {
                _ = node.getAttributeValue("id");
                _ = node.getAttributeValue("class");
                _ = node.getAttributeValue("href");
                _ = node.getAttributeValue("data-v");
            }
        }
        _ = try node.innerText(arena.allocator());
        visited += 1;
    }
}

fn fillInterestingParserBytes(random: std.Random, out: []u8) void {
    for (out) |*b| {
        b.* = switch (random.uintLessThan(u5, 20)) {
            0 => '<',
            1 => '>',
            2 => '/',
            3 => '=',
            4 => '&',
            5 => ';',
            6 => '#',
            7 => 'x',
            8 => 'X',
            9 => ' ',
            10 => '\n',
            11 => '\'',
            12 => '"',
            13 => '-',
            14 => '0' + random.uintLessThan(u8, 10),
            15 => 'a' + random.uintLessThan(u8, 26),
            16 => 'A' + random.uintLessThan(u8, 26),
            else => random.int(u8),
        };
    }
}

fn fillInterestingParserBytesSmith(smith: *std.testing.Smith, out: []u8) void {
    for (out) |*b| {
        b.* = switch (smith.value(u5)) {
            0 => '<',
            1 => '>',
            2 => '/',
            3 => '=',
            4 => '&',
            5 => ';',
            6 => '#',
            7 => 'x',
            8 => 'X',
            9 => ' ',
            10 => '\n',
            11 => '\'',
            12 => '"',
            13 => '-',
            14 => '0' + smith.valueRangeAtMost(u8, 0, 9),
            15 => 'a' + smith.valueRangeAtMost(u8, 0, 25),
            16 => 'A' + smith.valueRangeAtMost(u8, 0, 25),
            else => smith.value(u8),
        };
    }
}

fn runParserPropertyCase(alloc: std.mem.Allocator, input: []const u8) !void {
    const destructive_input = try alloc.dupe(u8, input);
    defer alloc.free(destructive_input);
    const nondestructive_input = try alloc.dupe(u8, input);
    defer alloc.free(nondestructive_input);

    var destructive_doc = TestDocument.init(alloc);
    defer destructive_doc.deinit();
    try resetParsed(DefaultTestOptions, &destructive_doc, destructive_input);

    var nondestructive_doc = NonDestructiveTestDocument.init(alloc);
    defer nondestructive_doc.deinit();
    try resetParsed(NonDestructiveTestOptions, &nondestructive_doc, nondestructive_input);

    try expectDocumentStructureValid(&destructive_doc);
    try expectDocumentStructureValid(&nondestructive_doc);
    try expectEquivalentStructures(&destructive_doc, &nondestructive_doc);

    try exerciseRuntimeApis(&destructive_doc, alloc);
    try exerciseRuntimeApis(&nondestructive_doc, alloc);

    const selectors = [_][]const u8{
        "div",
        "span",
        "script",
        "svg",
        "#x",
        ".a",
        "[href]",
        "body > *",
        "a[href^=http]",
    };
    inline for (selectors) |selector| {
        try expectRuntimeQueryParity(&destructive_doc, &nondestructive_doc, selector);
    }

    try std.testing.expectEqualSlices(u8, input, nondestructive_input);

    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{nondestructive_doc});
    defer alloc.free(rendered);
    try std.testing.expectEqualSlices(u8, input, rendered);
}

test "tag-name state keeps < inside malformed start tag name" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var src = "<div<div>".*;
    try resetParsed(DefaultTestOptions, &doc, &src);

    const first = doc.nodeAt(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div<div", first.tagName());
}

test "u16 parse rejects oversized input" {
    if (IndexInt != u16) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    const max_len: usize = if (@sizeOf(IndexInt) >= @sizeOf(usize))
        std.math.maxInt(usize)
    else
        @as(usize, std.math.maxInt(IndexInt));
    const src = try alloc.alloc(u8, max_len + 1);
    defer alloc.free(src);
    @memset(src, 'a');
    src[0] = '<';
    src[1] = 'p';
    src[2] = '>';

    try std.testing.expectError(error.InputTooLarge, DefaultTestOptions.parse(alloc, src));
}

test "u64 parse accepts sparse 8 GiB plaintext input" {
    if (IndexInt != u64) return error.SkipZigTest;
    if (@sizeOf(usize) < @sizeOf(u64)) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var rand_src: std.Random.IoSource = .{ .io = io };
    const path = try std.fmt.allocPrint(alloc, "/tmp/html-u64-8g-{x}.html", .{rand_src.interface().int(u64)});
    defer alloc.free(path);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
    });
    defer {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    const len = 8 * 1024 * 1024 * 1024;
    try file.setLength(io, len);

    var mapped = try std.Io.File.MemoryMap.create(io, file, .{
        .len = len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = true },
    });
    defer mapped.destroy(io);

    const tag = "<plaintext>";
    @memcpy(mapped.memory[0..tag.len], tag);

    var doc = TestDocument.init(alloc);
    defer doc.deinit();
    try resetParsed(NonDestructiveTestOptions, &doc, mapped.memory);

    try std.testing.expectEqual(@as(usize, 3), doc.nodes.len);
    const plaintext = doc.nodeAt(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("plaintext", plaintext.tagName());

    const text = doc.nodeAt(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(IndexInt, @intCast(tag.len)), text.raw().name_or_text.start);
    try std.testing.expectEqual(@as(IndexInt, @intCast(len)), text.raw().name_or_text.end);
}

test "non-destructive parse supports file-backed memory maps without changing bytes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var rand_src: std.Random.IoSource = .{ .io = io };
    const path = try std.fmt.allocPrint(alloc, "/tmp/html-nondestructive-mmap-{x}.html", .{rand_src.interface().int(u64)});
    defer alloc.free(path);

    const html = "<div id='x' data-v='a&amp;b'> hi &amp; bye </div>";
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
    });
    defer {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    try file.setLength(io, html.len);

    var init_map = try std.Io.File.MemoryMap.create(io, file, .{
        .len = html.len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = true },
    });
    @memcpy(init_map.memory[0..html.len], html);
    init_map.destroy(io);

    var mapped = try std.Io.File.MemoryMap.create(io, file, .{
        .len = html.len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = false },
    });
    defer mapped.destroy(io);

    var doc = NonDestructiveTestDocument.init(alloc);
    defer doc.deinit();
    try resetParsed(NonDestructiveTestOptions, &doc, mapped.memory);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", node.getAttributeValueAlloc(arena.allocator(), "data-v").?);
    try std.testing.expectEqualStrings("hi & bye", try node.innerText(arena.allocator()));
    try std.testing.expectEqualStrings(html, mapped.memory);

    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(html, rendered);
}

test "raw text element metadata remains valid after child append growth" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<script>const x = 1;</script><div>ok</div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.raw().subtree_end > script.index);

    const text_node = doc.nodes[script.index + 1];
    try std.testing.expect(text_node.attr_end == .text_node);
    try std.testing.expectEqualStrings("const x = 1;", text_node.name_or_text.slice(doc.source));

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;
    try std.testing.expect(div.index > script.raw().subtree_end);
}

test "raw-text close handles mixed-case end tag and embedded < bytes" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<script>if (a < b) { x = \"<tag>\"; }</ScRiPt   ><div id='after'></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    const after = doc.queryOne("div#after") orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.raw().subtree_end < after.index);
}

test "raw-text unterminated tail keeps element open to end of input" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<script>const a = 1; <div>still script".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(IndexInt, @intCast(doc.nodes.len - 1)), script.raw().subtree_end);
    try std.testing.expect(doc.queryOne("div") == null);
}

test "svg subtrees are skipped and stored as one text child payload" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='before'></div><svg id='s'><g><svg id='inner'><rect id='r'/></svg><circle id='c'/></g></svg><div id='after'></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const first_svg = doc.queryOne("svg") orelse return error.TestUnexpectedResult;
    const svg_text = try first_svg.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("<g><svg id='inner'><rect id='r'/></svg><circle id='c'/></g>", svg_text);

    var svg_it = doc.queryAll("svg");
    try std.testing.expect(svg_it.next() != null);
    try std.testing.expect(svg_it.next() == null);

    try std.testing.expect(doc.queryOne("#before") != null);
    try std.testing.expect(doc.queryOne("#after") != null);
    try std.testing.expect(doc.queryOne("#inner") == null);
    try std.testing.expect(doc.queryOne("#r") == null);
    try std.testing.expect(doc.queryOne("#c") == null);
}

test "svg skip scanner ignores <svg in quoted attributes" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-k=\"prefix <svg attr='x'> suffix\"></div><p id='after'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const x = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const v = x.getAttributeValue("data-k") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("prefix <svg attr='x'> suffix", v);
    try std.testing.expect(doc.queryOne("#after") != null);
}

test "self-closing svg is stored as regular element with no text child" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='before'></div><svg id='s' viewBox='0 0 1 1' /><div id='after'></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const first_svg = doc.queryOne("svg") orelse return error.TestUnexpectedResult;
    const svg_text = try first_svg.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("", svg_text);
    try std.testing.expect(first_svg.firstChild() == null);

    try std.testing.expect(doc.queryOne("#before") != null);
    try std.testing.expect(doc.queryOne("#after") != null);
}

test "optional-close p/li/td-th/dt-dd/head-body preserve expected query semantics" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = ("<html><head><title>x</title><body>" ++
        "<p id='p1'>a<div id='d1'></div>" ++
        "<ul><li id='li1'>x<li id='li2'>y</ul>" ++
        "<dl><dt id='dt1'>a<dd id='dd1'>b<dt id='dt2'>c</dl>" ++
        "<table><tr><td id='td1'>1<th id='th1'>2<td id='td2'>3</tr></table>" ++
        "</body></html>").*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(doc.queryOne("#p1 + #d1") != null);
    try std.testing.expect(doc.queryOne("#li1 + #li2") != null);
    try std.testing.expect(doc.queryOne("#dt1 + #dd1") != null);
    try std.testing.expect(doc.queryOne("#dd1 + #dt2") != null);
    try std.testing.expect(doc.queryOne("#td1 + #th1") != null);
    try std.testing.expect(doc.queryOne("#th1 + #td2") != null);
    try std.testing.expect(doc.queryOne("head + body") != null);
}

test "mismatched close with identical first8 prefix does not close long tag" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<abcdefgh1 id='outer'><span id='inner'></span></abcdefgh2><p id='after'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const outer = doc.queryOne("abcdefgh1#outer") orelse return error.TestUnexpectedResult;
    const after = doc.queryOne("p#after") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(outer.index, after.parentNode().?.index);
}

test "processing-instruction-like nodes end at the next >" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<?xml version='1.0'><div id='x'></div><p id='y'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const x = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    const y = doc.queryOne("p#y") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", x.tagName());
    try std.testing.expectEqualStrings("p", y.tagName());
}

test "bang nodes respect quoted > when skipping doctype-like declarations" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<!DOCTYPE html SYSTEM \"a>b\"><div id='x'></div><p id='y'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const x = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    const y = doc.queryOne("p#y") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", x.tagName());
    try std.testing.expectEqualStrings("p", y.tagName());
}

test "whitespace-only text nodes drop only in fastest mode" {
    const alloc = std.testing.allocator;

    var strict_doc = StrictTestDocument.init(alloc);
    defer strict_doc.deinit();
    var fast_doc = TestDocument.init(alloc);
    defer fast_doc.deinit();

    var strict_html = "<div id='x'> \n\t </div><div id='y'> hi </div>".*;
    var fast_html = strict_html;

    try resetParsed(StrictTestOptions, &strict_doc, &strict_html);
    try resetParsed(DefaultTestOptions, &fast_doc, &fast_html);

    try std.testing.expectEqual(@as(usize, 5), strict_doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 4), fast_doc.nodes.len);

    const y = fast_doc.queryOne("#y") orelse return error.TestUnexpectedResult;
    const text = try y.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings(" hi ", text);
}

test "fastest mode drops indentation-only runs between child elements" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div>\n  <a></a>\n  <b></b>\n</div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expectEqual(@as(usize, 4), doc.nodes.len);

    const div = doc.nodeAt(1) orelse return error.TestUnexpectedResult;
    const a = div.firstChild() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", doc.nodes[a.index].name_or_text.slice(doc.source));

    const b = a.nextSibling() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", doc.nodes[b.index].name_or_text.slice(doc.source));
    try std.testing.expect(b.nextSibling() == null);
}

test "attribute scanner handles quoted > and self-closing tails" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='a' data-q='x>y' data-n=abc></div><img id='i' src='x' /><br id='b'>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(doc.queryOne("div#a[data-q='x>y']") != null);
    try std.testing.expect(doc.queryOne("img#i[src='x']") != null);
    try std.testing.expect(doc.queryOne("br#b") != null);
}

test "attribute parsing still builds the DOM" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='x'><span id='y'></span></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(doc.nodes.len > 1);
    try std.testing.expect(doc.queryOne("#x") != null);
    try std.testing.expect(doc.queryOne("#y") != null);
}

test "parser randomized structural sweep" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4a91_13d2_7d6f_20b5);
    const random = prng.random();

    var case_idx: usize = 0;
    while (case_idx < 512) : (case_idx += 1) {
        const len = random.intRangeLessThan(usize, 0, 257);
        const input = try alloc.alloc(u8, len);
        defer alloc.free(input);
        fillInterestingParserBytes(random, input);
        runParserPropertyCase(alloc, input) catch |err| {
            std.debug.print("parser randomized case {} failed err={} len={}\n", .{ case_idx, err, len });
            return err;
        };
    }
}

fn fuzzParserProperties(alloc: std.mem.Allocator, smith: *std.testing.Smith) !void {
    const len = smith.value(u8);
    const input = try alloc.alloc(u8, len);
    defer alloc.free(input);
    fillInterestingParserBytesSmith(smith, input);
    try runParserPropertyCase(alloc, input);
}

test "fuzz parser preserves invariants across parse modes" {
    try std.testing.fuzz(std.testing.allocator, fuzzParserProperties, .{ .corpus = &.{
        "",
        "<div></div>",
        "<div id='x' class='a b'>text</div>",
        "<script>if (a < b) { x = \"<tag>\"; }</script>",
        "<svg id='s'><g><circle/></g></svg>",
        "<!DOCTYPE html><html><body><p>a<div>b</div></body></html>",
        "<div data-v='a&amp;b' data-q='1>2'><span>&#x3c;</span></div>",
        "<div<div>",
        "<?xml version='1.0'><div id='x'></div>",
        "<div id='x' data-k=\"prefix <svg attr='x'> suffix\"></div>",
        "<script>const a = 1; <div>still script",
    } });
}
