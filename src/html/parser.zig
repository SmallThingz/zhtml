const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const tables = @import("tables.zig");
const tags = @import("tags.zig");
const scanner = @import("scanner.zig");
const common = @import("../common.zig");
const document = @import("document.zig");
const ast = @import("../selector/ast.zig");
const open_tag_index = @import("open_tag_index.zig");

const ParseOptions = document.ParseOptions;

const InvalidIndex: IndexInt = common.InvalidIndex;
const IndexInt = common.IndexInt;
const InitialParseStackCapacity: usize = 32;
const CloseIndexMinDepth: usize = 64;
const SmallInitialNodeCapacity: usize = 64;
const LargeInitialNodeCapacity: usize = 512;
const SmallInputThreshold: usize = 4 * 1024;
const NodeDensitySampleBytes: usize = 64 * 1024;

// SAFETY: Parser builds spans into `input`; indices are stored as `IndexInt`.
// In destructive mode tag names are normalized in-place. In non-destructive mode
// parsing is read-only and any lazy decode work happens outside this file.

/// Parses borrowed `input` and returns a document that owns its node storage.
/// The caller must keep `input` alive until the document is no longer used and
/// remains responsible for freeing it. Destructive mode may mutate `input`.
pub fn parse(comptime opts: ParseOptions, allocator: std.mem.Allocator, input: opts.Input()) !opts.Document() {
    if (!common.lenFits(input.len)) return error.InputTooLarge;

    const Doc = opts.Document();
    var doc = Doc.init(allocator);
    errdefer doc.deinit();
    doc.source = input;

    var state = ParseState(opts){
        .allocator = allocator,
        .input = input,
        .i = 0,
    };
    errdefer state.nodes.deinit(allocator);
    try state.parse();

    doc.nodes = try state.nodes.toOwnedSlice(allocator);
    return doc;
}

fn ParseState(comptime opts: ParseOptions) type {
    return struct {
        /// Allocator for the persistent node buffer and rare scratch spill.
        allocator: std.mem.Allocator,
        /// Source bytes being tokenized for this parse pass.
        input: []const u8,
        /// Current byte cursor inside `input`.
        i: usize,
        /// Growable node buffer owned directly by parser during tree construction.
        nodes: std.ArrayListUnmanaged(RawNode) = .empty,
        /// Open-element stack used only while building the tree. Most HTML
        /// stays in the inline buffer; unusually deep documents spill once.
        parse_stack: std.ArrayListUnmanaged(OpenElem) = .empty,
        parse_stack_inline: [InitialParseStackCapacity]OpenElem = undefined,
        parse_stack_heap_owned: bool = false,
        /// Optional-end-tag source classes currently present on the open stack.
        implicit_source_mask: u8 = 0,
        implicit_source_duplicates: u8 = 0,
        /// Malformed-close index exists only after a deep full-stack miss.
        tag_index: ?*open_tag_index.LiveIndex(OpenElem) = null,

        const Self = @This();
        const RawNode = document.GetRawNode(opts);
        const OpenElem = struct {
            /// First-8-bytes lowercase key for the open tag name.
            tag_key: u64 = 0,
            /// Node index of the open element.
            idx: IndexInt,
            /// Last direct element child only when sibling/child links are persisted.
            last_child: if (opts.store_last_child or opts.store_prev_sibling) IndexInt else void = if (opts.store_last_child or opts.store_prev_sibling) InvalidIndex else {},
            /// Optional-close source class cached in struct padding.
            implicit_source: u8 = 0,

            pub inline fn keyValue(self: *const @This()) u64 {
                return self.tag_key;
            }
        };
        const TagNameScan = scanner.TagName;

        /// Reserve capacities + add initial values to containers
        inline fn initContainers(noalias self: *Self) !void {
            const initial_nodes = if (self.input.len <= SmallInputThreshold)
                SmallInitialNodeCapacity
            else blk: {
                const sample_len = @min(self.input.len, NodeDensitySampleBytes);
                const lt_count = std.mem.countScalar(u8, self.input[0..sample_len], '<');
                const projected_tags = std.math.mul(usize, lt_count, self.input.len) catch self.input.len;
                const density_estimate = projected_tags / sample_len;
                break :blk @max(LargeInitialNodeCapacity, density_estimate + density_estimate / 8 + 1);
            };
            try self.nodes.ensureTotalCapacity(self.allocator, initial_nodes);
            self.parse_stack = .initBuffer(&self.parse_stack_inline);

            // Seed the synthetic document root so every parsed node has a stable
            // parent chain and the open-element stack always has a sentinel.
            self.nodes.appendAssumeCapacity(.{
                .name_or_text = .{ .start = 0, .len = 0 },
                .last_child = if (comptime opts.store_last_child) InvalidIndex else {},
                .prev_sibling = if (comptime opts.store_prev_sibling) InvalidIndex else {},
                .parent = InvalidIndex,
                .subtree_end = 0,
            });
            self.parse_stack.appendAssumeCapacity(.{
                .idx = 0,
                .tag_key = 0,
                .last_child = if (comptime opts.store_last_child or opts.store_prev_sibling) InvalidIndex else {},
            });
        }

        inline fn parse(noalias self: *Self) !void {
            defer self.deinitParseStack();
            defer self.deinitTagIndex();
            try self.initContainers();

            // Main tokenization loop. Text spans and tags are dispatched here,
            // while specialized helpers handle the actual node construction.
            while (self.i + 1 < self.input.len) {
                if (self.input[self.i] != '<') {
                    try self.handleText();
                } else switch (self.input[self.i + 1]) {
                    '/' => try self.parseClosingTag(false),
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
                    else => try self.parseOpeningTag(false),
                }
            }

            // Handle the last char; only possibility: self.i == self.input.len - 1
            if (self.input.len != 0 and self.i == self.input.len - 1) {
                const parent_idx = self.currentParent();
                const last_idx = self.nodes.items.len - 1;
                const last = &self.nodes.items[last_idx];
                if (last.isText(@intCast(last_idx)) and last.parent == parent_idx and last.name_or_text.end() == self.i) {
                    last.name_or_text.setEnd(@intCast(self.input.len));
                } else {
                    if ((comptime opts.drop_whitespace_text_nodes == .none) or !tables.WhitespaceTable[self.input[self.i]]) {
                        try self.addNode(.{ self.i, self.input.len }, false, .{});
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

        noinline fn parseIndexedRemainder(noalias self: *Self) !void {
            @branchHint(.cold);
            std.debug.assert(self.tag_index != null);
            while (self.i + 1 < self.input.len) {
                if (self.input[self.i] != '<') {
                    try self.handleText();
                } else switch (self.input[self.i + 1]) {
                    '/' => try self.parseClosingTag(true),
                    '?' => self.skipPi(),
                    '!' => {
                        if (self.i + 3 < self.input.len and self.input[self.i + 2] == '-' and self.input[self.i + 3] == '-')
                            self.skipComment()
                        else
                            self.skipBangNode();
                    },
                    else => try self.parseOpeningTag(true),
                }
            }
        }

        inline fn handleText(noalias self: *Self) !void {
            std.debug.assert(self.input[self.i] != '<');
            std.debug.assert(self.i < self.input.len - 1);

            var start = self.i;
            if (comptime opts.drop_whitespace_text_nodes != .none) {
                self.skipWs();
                if (self.i == self.input.len) {
                    @branchHint(.cold);
                    return;
                }

                // likely to hit a tag after ws on normal documents
                if (self.input[self.i] == '<') return;
                if (comptime opts.drop_whitespace_text_nodes == .nodes_and_preceding) start = self.i;
            }

            self.i = std.mem.indexOfScalarPos(u8, self.input, self.i, '<') orelse self.input.len;
            try self.addNode(.{ start, self.i }, false, .{});
        }

        /// Intended to be called from inside of parseOpeningTag to parse the remaining contents as text
        noinline fn handleInvalidOpeningTag(noalias self: *Self, start: IndexInt) !void {
            const parent_idx = self.currentParent();
            const last = &self.nodes.items[self.nodes.items.len - 1];
            self.i = std.mem.indexOfScalarPos(u8, self.input, self.i, '<') orelse self.input.len;
            if (last.isText(@intCast(self.nodes.items.len - 1)) and last.parent == parent_idx and last.name_or_text.end() == start) { // Merge the node if the last node is text already
                last.name_or_text.setEnd(@intCast(self.i));
            } else { // append new node if last node was not text
                try self.addNode(.{ start, self.i }, false, .{});
            }

            std.debug.assert(self.i >= self.input.len - 1 or self.input[self.i] == '<');
        }

        /// Intended to be called from inside of parseOpeningTag to parse the remaining contents as text
        /// Skip SVG subtrees entirely to keep parse work focused on primary HTML content.
        /// Nested <svg> blocks are counted; `<svg` in quoted attributes is ignored by quote-aware tag-end scanning.
        noinline fn handleSvgTag(
            noalias self: *Self,
            name_start: usize,
            name_end: usize,
            attr_end: usize,
        ) !void {
            const parent_idx: IndexInt = @intCast(self.nodes.items.len);
            try self.addNode(.{ name_start, name_end }, true, .{});
            if (scanner.isSelfClosingStartTag(self.input, name_end, attr_end)) return;

            const content_start = self.i;
            const content_end = self.findSvgContentEnd() orelse blk: {
                self.i = self.input.len;
                break :blk self.i;
            };
            if (content_start < content_end) {
                @branchHint(.likely);
                self.nodes.items[parent_idx].subtree_end = @intCast(self.nodes.items.len);
                try self.addNode(.{ content_start, content_end }, false, .{ .parent = parent_idx });
            }
        }

        noinline fn handlePlaintextTag(noalias self: *Self, name_start: usize, name_end: usize) !void {
            const parent_idx: IndexInt = @intCast(self.nodes.items.len);
            try self.addNode(.{ name_start, name_end }, true, .{});
            if (self.i < self.input.len) {
                self.nodes.items[parent_idx].subtree_end = @intCast(self.nodes.items.len);
                try self.addNode(.{ self.i, self.input.len }, false, .{ .parent = parent_idx });
            }
            self.i = self.input.len;
        }

        noinline fn handleTextOnlyTag(
            noalias self: *Self,
            name_start: usize,
            name_end: usize,
            tag_name_key: u64,
        ) !void {
            const parent_idx: IndexInt = @intCast(self.nodes.items.len);
            try self.addNode(.{ name_start, name_end }, true, .{});
            const tag_name = self.input[name_start..name_end];
            const content_start = self.i;
            const content_end = blk: {
                if (self.findRawTextClose(tag_name, tag_name_key, self.i)) |close| {
                    self.i = close.close_end;
                    break :blk close.content_end;
                }
                self.i = self.input.len;
                break :blk self.i;
            };
            if (content_start < content_end) {
                self.nodes.items[parent_idx].subtree_end = @intCast(self.nodes.items.len);
                try self.addNode(.{ content_start, content_end }, false, .{ .parent = parent_idx });
            }
        }

        inline fn parseOpeningTag(noalias self: *Self, comptime indexed: bool) !void {
            self.i += 1; // <
            // no whitespace after `<` is allowed, same behavior as browser

            const tag = self.scanTagName();
            const name_start = tag.start;
            const name_end = tag.end;
            const tag_name_key = tag.key;
            const tag_name = self.input[name_start..name_end];

            // A non-tag `<...` remains text, but EOF while a start tag token is
            // still open discards that token (HTML tokenizer `eof-in-tag`).
            if (name_end == name_start) {
                @branchHint(.cold);
                return self.handleInvalidOpeningTag(@intCast(name_start - 1));
            }
            if (self.i >= self.input.len) {
                @branchHint(.cold);
                self.i = self.input.len;
                return;
            }

            const attr_end: usize = blk: {
                if (self.input[self.i] == '>') {
                    defer self.i += 1;
                    break :blk self.i;
                } else if (self.findTagEndRespectAttrQuotes()) |v| {
                    break :blk v;
                } else {
                    @branchHint(.cold);
                    // invalid tag, skip content; same as browser
                    self.i = self.input.len;
                    return;
                }
            };

            // Resolve optional-close HTML elements before any special-content
            // branch so tags such as <plaintext> cannot remain nested in an open <p>.
            if (self.implicit_source_mask != 0 and self.parse_stack.items.len > 1) {
                const trigger_mask = tags.implicitCloseTriggerMask(tag_name, tag_name_key);
                if (self.implicit_source_mask & trigger_mask != 0) {
                    const top = self.parse_stack.items[self.parse_stack.items.len - 1];
                    if (top.implicit_source & trigger_mask != 0) {
                        const popped = self.popOpen(indexed);
                        self.nodes.items[popped.idx].subtree_end = @intCast(self.nodes.items.len - 1);
                        if (self.implicit_source_mask & trigger_mask != 0) self.applyImplicitClosures(trigger_mask, indexed);
                    } else {
                        self.applyImplicitClosures(trigger_mask, indexed);
                    }
                }
            }

            switch (tags.classifyOpenTag(tag_name, tag_name_key)) {
                .svg => return self.handleSvgTag(name_start, name_end, attr_end),
                .plaintext => return self.handlePlaintextTag(name_start, name_end),
                .text_only => return self.handleTextOnlyTag(name_start, name_end, tag_name_key),
                .void => {
                    try self.addNode(.{ name_start, name_end }, true, .{});
                    return;
                },
                .normal => {},
            }

            const node_idx = self.nodes.items.len;
            try self.addNode(.{ name_start, name_end }, true, .{});

            // Non-void, non-raw elements stay on the open stack until an
            // explicit close, an optional-close rule, or EOF pops them.
            try self.pushOpen(indexed, .{
                .idx = @intCast(node_idx),
                .tag_key = tag_name_key,
                .last_child = if (comptime opts.store_last_child or opts.store_prev_sibling) InvalidIndex else {},
                .implicit_source = tags.implicitCloseSourceMask(tag_name.len, tag_name_key),
            });
        }

        inline fn parseClosingTag(noalias self: *Self, comptime indexed: bool) !void {
            self.i += 2; // </
            // no whitespace after `<` is allowed, same behavior as browser

            const tag = self.scanTagName();
            const name_start = tag.start;
            const name_end = tag.end;
            const close_key = tag.key;
            const close_name = self.input[name_start..name_end];

            if (self.i < self.input.len and self.input[self.i] == '>') {
                self.i += 1;
            } else if (self.findTagEndRespectAttrQuotes() == null) {
                // HTML tokenizer eof-in-tag: the unfinished end-tag token is
                // discarded, so it must not mutate the open-element stack.
                self.i = self.input.len;
                return;
            }

            if (close_name.len == 0 or self.parse_stack.items.len <= 1) { // root-only stack means there is nothing to close
                @branchHint(.cold);
                return;
            }

            const top = self.parse_stack.items[self.parse_stack.items.len - 1];
            // Fast path: most closing tags match the current open element.
            if (self.openElemMatchesClose(top, close_name, close_key)) {
                @branchHint(.likely);
                _ = self.popOpen(indexed);
                var node = &self.nodes.items[top.idx];
                node.subtree_end = @intCast(self.nodes.items.len - 1);
                return;
            }

            if (try self.findOpenForSlowClose(indexed, close_name, close_key)) |found_pos| {
                @branchHint(.likely);
                const pos: usize = @intCast(found_pos);
                // Permissive recovery: pop everything above the matched opener.
                while (self.parse_stack.items.len > pos) {
                    const open = self.popOpen(indexed);
                    var node = &self.nodes.items[open.idx];
                    node.subtree_end = @intCast(self.nodes.items.len - 1);
                }
            } else {
                @branchHint(.unlikely);
                if (comptime !indexed) {
                    if (self.tag_index != null) try self.parseIndexedRemainder();
                }
            }
        }

        noinline fn applyImplicitClosures(noalias self: *Self, trigger_mask: u8, comptime indexed: bool) void {
            while (self.parse_stack.items.len > 1) {
                var pos = self.parse_stack.items.len;
                var found: ?usize = null;
                var scope: tags.ImplicitCloseScope = .{};
                while (pos > 1) {
                    pos -= 1;
                    const open = self.parse_stack.items[pos];
                    const open_len = self.nodes.items[open.idx].name_or_text.len;
                    if (open.implicit_source & trigger_mask != 0 and scope.permits(open_len, open.tag_key)) {
                        found = pos;
                        break;
                    }
                    scope.observe(open_len, open.tag_key);
                }

                const found_pos = found orelse break;
                // Pop the optional-close source and every inline descendant
                // above it, exactly as an explicit close of that source would.
                while (self.parse_stack.items.len > found_pos) {
                    const popped = self.popOpen(indexed);
                    var n = &self.nodes.items[popped.idx];
                    n.subtree_end = @intCast(self.nodes.items.len - 1);
                }
            }
        }

        inline fn deinitParseStack(noalias self: *Self) void {
            if (self.parse_stack_heap_owned) self.parse_stack.deinit(self.allocator);
        }

        inline fn addImplicitSource(noalias self: *Self, open: OpenElem) void {
            const source = open.implicit_source;
            if (source == 0) return;
            if (self.implicit_source_mask & source != 0) self.implicit_source_duplicates |= source;
            self.implicit_source_mask |= source;
        }

        inline fn removeImplicitSource(noalias self: *Self, open: OpenElem) void {
            const source = open.implicit_source;
            if (source == 0) return;
            if (self.implicit_source_duplicates & source == 0) {
                self.implicit_source_mask &= ~source;
                return;
            }
            self.recountImplicitSource(source);
        }

        noinline fn recountImplicitSource(noalias self: *Self, source: u8) void {
            @branchHint(.cold);
            var seen: u2 = 0;
            for (self.parse_stack.items[1..]) |item| {
                if (item.implicit_source & source == 0) continue;
                seen += 1;
                if (seen == 2) return;
            }
            self.implicit_source_duplicates &= ~source;
            if (seen == 0) self.implicit_source_mask &= ~source;
        }

        noinline fn growParseStack(noalias self: *Self) !void {
            @branchHint(.cold);
            if (!self.parse_stack_heap_owned) {
                var heap = try std.ArrayListUnmanaged(OpenElem).initCapacity(
                    self.allocator,
                    self.parse_stack.capacity * 2,
                );
                heap.appendSliceAssumeCapacity(self.parse_stack.items);
                self.parse_stack = heap;
                self.parse_stack_heap_owned = true;
                return;
            }
            try self.parse_stack.ensureUnusedCapacity(self.allocator, 1);
        }

        inline fn pushOpen(noalias self: *Self, comptime indexed: bool, open: OpenElem) !void {
            if (comptime indexed) return self.pushOpenIndexed(open);
            if (self.parse_stack.items.len == self.parse_stack.capacity) {
                @branchHint(.unlikely);
                try self.growParseStack();
            }
            self.parse_stack.appendAssumeCapacity(open);
            self.addImplicitSource(open);
        }

        noinline fn pushOpenIndexed(noalias self: *Self, open: OpenElem) !void {
            @branchHint(.cold);
            if (self.parse_stack.items.len == self.parse_stack.capacity) try self.growParseStack();
            const index = self.tag_index.?;
            try index.preparePush(self.allocator, &open);
            self.parse_stack.appendAssumeCapacity(open);
            index.commitPush(&open, self.parse_stack.items.len);
            self.addImplicitSource(open);
        }

        inline fn popOpen(noalias self: *Self, comptime indexed: bool) OpenElem {
            if (comptime indexed) return self.popOpenIndexed();
            const open = self.parse_stack.pop().?;
            std.debug.assert(open.idx != 0);
            self.removeImplicitSource(open);
            return open;
        }

        noinline fn popOpenIndexed(noalias self: *Self) OpenElem {
            @branchHint(.cold);
            const stack_len = self.parse_stack.items.len;
            const open = self.parse_stack.pop().?;
            std.debug.assert(open.idx != 0);
            self.removeImplicitSource(open);
            self.tag_index.?.pop(&open, stack_len);
            return open;
        }

        fn findOpenForSlowClose(noalias self: *Self, comptime indexed: bool, close_name: []const u8, close_key: u64) !?open_tag_index.StackPos {
            if (comptime indexed) {
                const index = self.tag_index.?;
                var pos = index.find(close_key) orelse return null;
                while (pos != open_tag_index.no_stack_pos) {
                    const p: usize = @intCast(pos);
                    if (self.openElemMatchesClose(self.parse_stack.items[p], close_name, close_key)) return pos;
                    pos = index.previous(pos);
                }
                return null;
            }

            var pos = self.parse_stack.items.len;
            while (pos > 1) {
                pos -= 1;
                if (self.openElemMatchesClose(self.parse_stack.items[pos], close_name, close_key)) return @intCast(pos);
            }

            // Only a deep full miss transfers parsing into indexed recovery.
            if (self.parse_stack.items.len < CloseIndexMinDepth) return null;
            const index = try self.allocator.create(open_tag_index.LiveIndex(OpenElem));
            errdefer self.allocator.destroy(index);
            index.* = .{};
            errdefer index.deinit(self.allocator);
            try index.activate(self.allocator, self.parse_stack.items);
            self.tag_index = index;
            return null;
        }

        noinline fn deinitTagIndex(noalias self: *Self) void {
            if (self.tag_index) |index| {
                index.deinit(self.allocator);
                self.allocator.destroy(index);
                self.tag_index = null;
            }
        }

        noinline fn growNodes(noalias self: *Self) !void {
            @branchHint(.cold);
            try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        }

        inline fn addNode(noalias self: *Self, name_or_text: anytype, is_element: bool, overrides: anytype) !void {
            const Overrides = @TypeOf(overrides);
            comptime for (@typeInfo(Overrides).@"struct".fields) |field| {
                std.debug.assert(std.mem.eql(u8, field.name, "parent"));
            };
            const parent_idx: IndexInt = @intCast(if (@hasField(Overrides, "parent")) overrides.parent else self.currentParent());
            const idx: IndexInt = @intCast(self.nodes.items.len);
            const parent_stack_idx = self.parse_stack.items.len - 1;
            var prev_element = InvalidIndex;
            if (is_element) {
                std.debug.assert(parent_idx == self.currentParent());
                if (comptime opts.store_last_child or opts.store_prev_sibling) prev_element = self.parse_stack.items[parent_stack_idx].last_child;
            }

            if (self.nodes.items.len == self.nodes.capacity) {
                @branchHint(.unlikely);
                try self.growNodes();
            }
            self.nodes.appendAssumeCapacity(.{
                .name_or_text = .{
                    .start = @intCast(name_or_text[0]),
                    .len = @intCast(name_or_text[1] - name_or_text[0]),
                },
                .last_child = if (comptime opts.store_last_child) InvalidIndex else {},
                .prev_sibling = if (comptime opts.store_prev_sibling) prev_element else {},
                .parent = parent_idx,
                .subtree_end = if (is_element) idx else 0,
            });
            if (is_element) {
                if (comptime opts.store_last_child or opts.store_prev_sibling) self.parse_stack.items[parent_stack_idx].last_child = idx;
                if (comptime opts.store_last_child) self.nodes.items[parent_idx].last_child = idx;
            }
        }

        inline fn currentParent(noalias self: *const Self) IndexInt {
            std.debug.assert(self.parse_stack.items.len != 0);
            return self.parse_stack.items[self.parse_stack.items.len - 1].idx;
        }

        inline fn openElemMatchesClose(noalias self: *const Self, open: OpenElem, close_name: []const u8, close_key: u64) bool {
            const open_span = self.nodes.items[open.idx].name_or_text;
            if (open_span.len != close_name.len or open.tag_key != close_key) return false;
            if (close_name.len <= 8) return true;
            const open_name = open_span.slice(self.input);
            return std.ascii.eqlIgnoreCase(open_name[8..], close_name[8..]);
        }

        inline fn scanTagName(noalias self: *Self) TagNameScan {
            const tag = scanner.scanTagName(self.input, self.i, !opts.non_destructive);
            self.i = tag.end;
            return tag;
        }

        fn skipComment(noalias self: *Self) void {
            const close = scanner.findCommentClose(self.input, self.i + 4);
            self.i = close.token_end;
        }

        fn skipBangNode(noalias self: *Self) void {
            self.i += 2;
            // Doctype-like nodes are skipped as opaque declarations.
            if (self.findTagEndRespectAnyQuotes()) |_| {} else {
                self.i = self.input.len;
            }
        }

        inline fn findTagEndRespectAttrQuotes(noalias self: *Self) ?usize {
            std.debug.assert(self.i <= self.input.len);
            const end = scanner.findTagEnd(self.input, self.i) orelse return null;
            self.i = end + 1;
            return end;
        }

        inline fn findTagEndRespectAnyQuotes(noalias self: *Self) ?usize {
            std.debug.assert(self.i <= self.input.len);
            const end = scanner.findDeclarationEnd(self.input, self.i) orelse return null;
            self.i = end + 1;
            return end;
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

        inline fn isSvgTag(tag_name: []const u8) bool {
            return tag_name.len == 3 and std.ascii.toLower(tag_name[0]) == 's' and
                std.ascii.toLower(tag_name[1]) == 'v' and std.ascii.toLower(tag_name[2]) == 'g';
        }

        inline fn isSvgTagKey(tag_key: u64) bool {
            return tag_key == comptime tags.first8KeyWithMode("svg", false);
        }

        inline fn findSvgContentEnd(noalias self: *Self) ?usize {
            var depth: usize = 1;
            while (self.i < self.input.len) {
                const lt = std.mem.indexOfScalarPos(u8, self.input, self.i, '<') orelse return null;
                if (lt + 1 >= self.input.len) return null;

                self.i = lt + 1;
                if (self.i >= self.input.len) return null;

                switch (self.input[self.i]) {
                    '!' => {
                        const bang = self.i;
                        self.i = lt; // shared helpers expect the cursor at `<`
                        if (bang + 2 < self.input.len and self.input[bang + 1] == '-' and self.input[bang + 2] == '-') {
                            self.skipComment();
                        } else {
                            self.skipBangNode();
                        }
                    },
                    '?' => {
                        self.i = lt; // skipPi likewise consumes from `<`
                        self.skipPi();
                    },
                    '/' => {
                        self.i += 1;
                        const name_start = self.i;
                        while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {}
                        const tag_end = scanner.findTagEnd(self.input, self.i) orelse return null;
                        if (self.i - name_start == 3 and isSvgTag(self.input[name_start..self.i])) {
                            depth -= 1;
                            if (depth == 0) {
                                self.i = tag_end + 1;
                                return lt;
                            }
                        }
                        self.i = tag_end + 1;
                    },
                    else => {
                        const name_start = self.i;
                        while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {}
                        const name_end = self.i;
                        if (name_end == name_start) {
                            self.i = lt + 1;
                            continue;
                        }

                        const tag_end = self.findTagEndRespectAttrQuotes() orelse return null;
                        if (name_end - name_start == 3 and isSvgTag(self.input[name_start..name_end]) and !scanner.isSelfClosingStartTag(self.input, name_end, tag_end)) {
                            depth += 1;
                        }
                    },
                }
            }
            return null;
        }

        inline fn findRawTextClose(noalias self: *Self, tag_name: []const u8, tag_key: u64, start: usize) ?struct { content_end: usize, close_end: usize } {
            const close = scanner.findRawTextClose(self.input, tag_name, tag_key, start) orelse return null;
            self.i = close.close_end;
            return .{ .content_end = close.content_end, .close_end = close.close_end };
        }
    };
}

const DefaultTestOptions: ParseOptions = .{};
const StrictTestOptions: ParseOptions = .{ .drop_whitespace_text_nodes = .none };
const NonDestructiveTestOptions: ParseOptions = .{ .non_destructive = true };
const TestDocument = DefaultTestOptions.Document();
const StrictTestDocument = StrictTestOptions.Document();
const NonDestructiveTestDocument = NonDestructiveTestOptions.Document();

fn resetParsed(comptime options: ParseOptions, doc: *options.Document(), input: options.Input()) !void {
    doc.deinit();
    doc.* = try options.parse(doc.allocator, input);
}

test "malformed comment closes do not swallow following nodes" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{ "<!-->", "<!--->", "<!--x--!>" };

    for (cases) |prefix| {
        var buf: [64]u8 = undefined;
        const html_slice = try std.fmt.bufPrint(&buf, "{s}<div id=x></div>", .{prefix});
        var doc = TestDocument.init(alloc);
        defer doc.deinit();
        try resetParsed(DefaultTestOptions, &doc, html_slice);

        var iter = doc.query("div");
        defer iter.deinit();
        try std.testing.expect(try iter.next() != null);
    }
}

fn expectDocumentStructureValid(doc: anytype) !void {
    const testing = std.testing;
    const nodes = doc.nodes;
    try testing.expect(nodes.len >= 1);
    try testing.expect(nodes[0].parent == InvalidIndex);
    try testing.expectEqual(@as(IndexInt, @intCast(nodes.len - 1)), nodes[0].subtree_end);

    for (nodes, 0..) |node, i| {
        const idx: IndexInt = @intCast(i);
        const is_text = node.isText(idx);
        const is_element = node.isElement(idx);
        const span_start: usize = @intCast(node.name_or_text.start);
        const span_end: usize = @intCast(node.name_or_text.end());

        try testing.expect(span_start <= span_end);
        try testing.expect(span_end <= doc.source.len);
        if (is_text) {
            try testing.expectEqual(@as(IndexInt, 0), node.subtree_end);
        } else {
            try testing.expect(node.subtree_end >= idx);
            try testing.expect(@as(usize, @intCast(node.subtree_end)) < nodes.len);
        }

        if (is_element) {
            const attr_end = std.mem.indexOfScalarPos(u8, doc.source, span_end, '>') orelse doc.source.len;
            try testing.expect(span_end <= attr_end);
            try testing.expect(attr_end <= doc.source.len);
        }

        if (node.parent == InvalidIndex) {
            try testing.expectEqual(@as(usize, 0), i);
        } else {
            const parent_idx: usize = @intCast(node.parent);
            try testing.expect(parent_idx < nodes.len);
            try testing.expect(parent_idx == 0 or nodes[parent_idx].isElement(node.parent));
            try testing.expect(nodes[parent_idx].subtree_end >= idx);
        }

        const RawNode = @TypeOf(node);
        if (comptime @FieldType(RawNode, "prev_sibling") != void) {
            if (node.prev_sibling != InvalidIndex) {
                const prev_idx: usize = @intCast(node.prev_sibling);
                try testing.expect(prev_idx < i);
                try testing.expectEqual(node.parent, nodes[prev_idx].parent);
                try testing.expect(!node.isText(idx));
                try testing.expect(!nodes[prev_idx].isText(node.prev_sibling));
                try testing.expect(@as(usize, @intCast(nodes[prev_idx].subtree_end)) < i);
            }
        }

        if (comptime @FieldType(RawNode, "last_child") != void) {
            if (node.last_child != InvalidIndex) {
                const last_child_idx: usize = @intCast(node.last_child);
                try testing.expect(!is_text);
                try testing.expect(last_child_idx > i);
                try testing.expect(last_child_idx <= @as(usize, @intCast(node.subtree_end)));
                try testing.expectEqual(idx, nodes[last_child_idx].parent);
                try testing.expect(!nodes[last_child_idx].isText(node.last_child));
            } else if (is_text) {
                try testing.expectEqual(InvalidIndex, node.last_child);
            }
        }
    }
}

fn expectEquivalentStructures(a: *const TestDocument, b: *const NonDestructiveTestDocument) !void {
    const testing = std.testing;
    try testing.expectEqual(a.nodes.len, b.nodes.len);

    for (a.nodes, b.nodes) |lhs, rhs| {
        try testing.expectEqual(lhs.name_or_text.start, rhs.name_or_text.start);
        try testing.expectEqual(lhs.name_or_text.end(), rhs.name_or_text.end());
        if (comptime @FieldType(@TypeOf(lhs), "prev_sibling") != void) try testing.expectEqual(lhs.prev_sibling, rhs.prev_sibling);
        if (comptime @FieldType(@TypeOf(lhs), "last_child") != void) try testing.expectEqual(lhs.last_child, rhs.last_child);
        try testing.expectEqual(lhs.parent, rhs.parent);
        try testing.expectEqual(lhs.subtree_end, rhs.subtree_end);
    }
}

fn firstQuery(iter: anytype) @TypeOf(blk: {
    var it = iter;
    break :blk it.next() catch unreachable;
}) {
    var it = iter;
    defer it.deinit();
    return it.next() catch unreachable;
}

fn runtimeFirst(scope: anytype, allocator: std.mem.Allocator, selector: []const u8) !@TypeOf(firstQuery(scope.query("*"))) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
    return firstQuery(scope.queryRuntime(sel));
}

fn expectRuntimeQueryParity(a: *const TestDocument, b: *const NonDestructiveTestDocument, selector: []const u8) !void {
    const testing = std.testing;
    const lhs = try runtimeFirst(a, testing.allocator, selector);
    const rhs = try runtimeFirst(b, testing.allocator, selector);
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
        _ = try runtimeFirst(doc, alloc, selector);
    }

    var visited: usize = 0;
    var idx: usize = 0;
    while (idx < doc.nodes.len and visited < 16) : (idx += 1) {
        const node = doc.nodeAt(@intCast(idx));
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        if (doc.nodes[idx].isElement(@intCast(idx))) {
            if (comptime @FieldType(@TypeOf(doc.*), "source") == []const u8) {
                _ = try node.getAttributeValue(arena.allocator(), "id");
                _ = try node.getAttributeValue(arena.allocator(), "class");
                _ = try node.getAttributeValue(arena.allocator(), "href");
                _ = try node.getAttributeValue(arena.allocator(), "data-v");
            } else {
                _ = try node.getAttributeValue(alloc, "id");
                _ = try node.getAttributeValue(alloc, "class");
                _ = try node.getAttributeValue(alloc, "href");
                _ = try node.getAttributeValue(alloc, "data-v");
            }
        }
        const text = try node.innerTextWithOptions(arena.allocator(), .{});
        text.free(arena.allocator());
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
    if (input.len == 0) return;

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

    const first = doc.nodeAt(1);
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

    var doc = NonDestructiveTestDocument.init(alloc);
    defer doc.deinit();
    try resetParsed(NonDestructiveTestOptions, &doc, mapped.memory);

    try std.testing.expectEqual(@as(usize, 3), doc.nodes.len);
    const plaintext = doc.nodeAt(1);
    try std.testing.expectEqualStrings("plaintext", plaintext.tagName());

    const text = doc.nodeAt(2);
    try std.testing.expectEqual(@as(IndexInt, @intCast(tag.len)), text.raw().name_or_text.start);
    try std.testing.expectEqual(@as(IndexInt, @intCast(len - tag.len)), text.raw().name_or_text.len);
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

    const node = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", (try node.getAttributeValue(arena.allocator(), "data-v")).?.value);
    const text = try node.innerTextWithOptions(arena.allocator(), .{});
    defer text.free(arena.allocator());
    try std.testing.expectEqualStrings("hi & bye", text.value);
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

    const script = firstQuery(doc.query("script")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.raw().subtree_end > script.index);

    const text_node = doc.nodes[script.index + 1];
    try std.testing.expect(text_node.isText(@intCast(script.index + 1)));
    try std.testing.expectEqualStrings("const x = 1;", text_node.name_or_text.slice(doc.source));

    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(div.index > script.raw().subtree_end);
}

test "SVG opaque scan keeps cursor contracts for empty comments and PI" {
    const alloc = std.testing.allocator;
    var html = "<svg><!----><?pi?><g></g></svg><div id='tail'></div>".*;

    var doc = TestDocument.init(alloc);
    defer doc.deinit();
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("svg")) != null);
    try std.testing.expect(firstQuery(doc.query("#tail")) != null);
}

test "SVG slash inside unquoted value does not terminate nested SVG" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = ("<svg><svg data=x/>inside</svg><span id='still-svg'></span></svg>" ++
        "<div id='after'></div>").*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#still-svg")) == null);
    try std.testing.expect(firstQuery(doc.query("#after")) != null);
}

test "raw-text close handles mixed-case end tag and embedded < bytes" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<script>if (a < b) { x = \"<tag>\"; }</ScRiPt   ><div id='after'></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const script = firstQuery(doc.query("script")) orelse return error.TestUnexpectedResult;
    const after = firstQuery(doc.query("div#after")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.raw().subtree_end < after.index);
}

test "raw-text unterminated tail keeps element open to end of input" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<script>const a = 1; <div>still script".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const script = firstQuery(doc.query("script")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(IndexInt, @intCast(doc.nodes.len - 1)), script.raw().subtree_end);
    try std.testing.expect(firstQuery(doc.query("div")) == null);
}

test "svg subtrees are skipped and stored as one text child payload" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='before'></div><svg id='s'><g><svg id='inner'><rect id='r'/></svg><circle id='c'/></g></svg><div id='after'></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const first_svg = firstQuery(doc.query("svg")) orelse return error.TestUnexpectedResult;
    const svg_text = try first_svg.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer svg_text.free(alloc);
    try std.testing.expectEqualStrings("<g><svg id='inner'><rect id='r'/></svg><circle id='c'/></g>", svg_text.value);

    var svg_it = doc.query("svg");
    try std.testing.expect(try svg_it.next() != null);
    try std.testing.expect(try svg_it.next() == null);

    try std.testing.expect(firstQuery(doc.query("#before")) != null);
    try std.testing.expect(firstQuery(doc.query("#after")) != null);
    try std.testing.expect(firstQuery(doc.query("#inner")) == null);
    try std.testing.expect(firstQuery(doc.query("#r")) == null);
    try std.testing.expect(firstQuery(doc.query("#c")) == null);
}

test "svg skip scanner ignores <svg in quoted attributes" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-k=\"prefix <svg attr='x'> suffix\"></div><p id='after'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const x = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const v = (try x.getAttributeValue(alloc, "data-k")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("prefix <svg attr='x'> suffix", v.value);
    try std.testing.expect(firstQuery(doc.query("#after")) != null);
}

test "self-closing svg is stored as regular element with no text child" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='before'></div><svg id='s' viewBox='0 0 1 1' /><div id='after'></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const first_svg = firstQuery(doc.query("svg")) orelse return error.TestUnexpectedResult;
    const svg_text = try first_svg.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer svg_text.free(alloc);
    try std.testing.expectEqualStrings("", svg_text.value);
    var svg_children = first_svg.children();
    try std.testing.expect(svg_children.next() == null);

    try std.testing.expect(firstQuery(doc.query("#before")) != null);
    try std.testing.expect(firstQuery(doc.query("#after")) != null);
}

test "closing tag attributes respect quoted greater-than" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div></div data-x=\"a>b\"><p id='after'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    // Synthetic root + div + p. The `b\">` suffix must not leak out as text.
    try std.testing.expectEqual(@as(usize, 3), doc.nodes.len);
    try std.testing.expect(firstQuery(doc.query("#after")) != null);
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

    try std.testing.expect(firstQuery(doc.query("#p1 + #d1")) != null);
    try std.testing.expect(firstQuery(doc.query("#li1 + #li2")) != null);
    try std.testing.expect(firstQuery(doc.query("#dt1 + #dd1")) != null);
    try std.testing.expect(firstQuery(doc.query("#dd1 + #dt2")) != null);
    try std.testing.expect(firstQuery(doc.query("#td1 + #th1")) != null);
    try std.testing.expect(firstQuery(doc.query("#th1 + #td2")) != null);
    try std.testing.expect(firstQuery(doc.query("head + body")) != null);
}

test "optional-close option and optgroup preserve select sibling structure" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<select><optgroup id='g1'><option id='o1'>one<optgroup id='g2'><option id='o2'>two</select>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#g1 + #g2")) != null);
    try std.testing.expect(firstQuery(doc.query("#g1 #o1")) != null);
    try std.testing.expect(firstQuery(doc.query("#g2 #o2")) != null);
    try std.testing.expect(firstQuery(doc.query("#o1 #g2")) == null);
}

test "hr closes open option and optgroup in select" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<select><optgroup id='g'><option id='o'>one<hr id='h'></select>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#g + #h")) != null);
    try std.testing.expect(firstQuery(doc.query("#g #o")) != null);
    try std.testing.expect(firstQuery(doc.query("#o #h")) == null);
}

test "plaintext start tag implicitly closes an open paragraph" {
    const alloc = std.testing.allocator;
    var html = "<p id='p'>before<plaintext>after".*;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();
    try resetParsed(DefaultTestOptions, &doc, &html);

    const p_node = firstQuery(doc.query("#p")) orelse return error.TestUnexpectedResult;
    const plaintext = firstQuery(doc.query("plaintext")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(IndexInt, 0), plaintext.raw().parent);
    try std.testing.expect(plaintext.index > p_node.raw().subtree_end);
}

test "optional-close sources are found through inline descendants without crossing scope" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = ("<p id='p'><span id='ps'>x<div id='d'></div>" ++
        "<ul><li id='li1'><span>x<li id='li2'>y</ul>" ++
        "<p id='p-li'>x<li id='loose-li'>y" ++
        "<dl><dt id='dt'><span>x<dd id='dd'>y</dl>" ++
        "<p id='scoped'><button><span>x<div id='inside-button'></div></button></p>" ++
        "<ul><li id='outer-li'><button><span>x<li id='after-button-li'>y</ul>").*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#p + #d")) != null);
    try std.testing.expect(firstQuery(doc.query("#li1 + #li2")) != null);
    try std.testing.expect(firstQuery(doc.query("#p-li + #loose-li")) != null);
    try std.testing.expect(firstQuery(doc.query("#dt + #dd")) != null);
    try std.testing.expect(firstQuery(doc.query("#scoped #inside-button")) != null);
    try std.testing.expect(firstQuery(doc.query("#outer-li + #after-button-li")) != null);
}

test "p optional-close set includes modern block elements" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = ("<p id='p1'>a<details id='d'></details>" ++
        "<p id='p2'>b<figure id='f'></figure>" ++
        "<p id='p3'>c<menu id='m'></menu>" ++
        "<p id='p4'>d<search id='s'></search>").*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#p1 + #d")) != null);
    try std.testing.expect(firstQuery(doc.query("#p2 + #f")) != null);
    try std.testing.expect(firstQuery(doc.query("#p3 + #m")) != null);
    try std.testing.expect(firstQuery(doc.query("#p4 + #s")) != null);
}

test "unterminated start tags at EOF are discarded consistently" {
    const alloc = std.testing.allocator;

    var no_attrs = "<div".*;
    var doc_a = try parse(DefaultTestOptions, alloc, &no_attrs);
    defer doc_a.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc_a.nodes.len);

    var attrs = "<div id=x".*;
    var doc_b = try parse(DefaultTestOptions, alloc, &attrs);
    defer doc_b.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc_b.nodes.len);
}

test "non-destructive malformed attr separator cannot panic batch lookup" {
    const alloc = std.testing.allocator;
    var doc = NonDestructiveTestDocument.init(alloc);
    defer doc.deinit();

    const html = "<div\x00 id=x></div>";
    try resetParsed(NonDestructiveTestOptions, &doc, html);

    try std.testing.expect(firstQuery(doc.query("div#x")) != null);
    try std.testing.expect(firstQuery(doc.query("div#x.missing")) == null);
}

test "mismatched close with identical first8 prefix does not close long tag" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<abcdefgh1 id='outer'><span id='inner'></span></abcdefgh2><p id='after'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const outer = firstQuery(doc.query("abcdefgh1#outer")) orelse return error.TestUnexpectedResult;
    const after = firstQuery(doc.query("p#after")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(outer.index, after.parentNode().?.index);
}

test "open-element stack preserves tag names longer than u16" {
    const alloc = std.testing.allocator;
    const name_len = 65_536;
    const input_len = name_len * 2 + 5;
    if (comptime input_len > common.MaxLen) return error.SkipZigTest;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    input[0] = '<';
    @memset(input[1 .. name_len + 1], 'a');
    input[name_len + 1] = '>';
    input[name_len + 2] = '<';
    input[name_len + 3] = '/';
    @memset(input[name_len + 4 .. name_len * 2 + 4], 'a');
    input[name_len * 2 + 4] = '>';

    var doc = try parse(DefaultTestOptions, alloc, input);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, name_len), doc.nodeAt(1).tagName().len);
    try std.testing.expectEqual(@as(IndexInt, 1), doc.nodes[1].subtree_end);
}

test "processing-instruction-like nodes end at the next >" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<?xml version='1.0'><div id='x'></div><p id='y'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const x = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    const y = firstQuery(doc.query("p#y")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", x.tagName());
    try std.testing.expectEqualStrings("p", y.tagName());
}

test "spaced svg end tag does not terminate skipped svg subtree" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<svg>opaque</ svg><div id='inside'></div></svg><p id='after'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#inside")) == null);
    try std.testing.expect(firstQuery(doc.query("#after")) != null);
}

test "bang nodes respect quoted > when skipping doctype-like declarations" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<!DOCTYPE html SYSTEM \"a>b\"><div id='x'></div><p id='y'></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    const x = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    const y = firstQuery(doc.query("p#y")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", x.tagName());
    try std.testing.expectEqualStrings("p", y.tagName());
}

test "whitespace-only text nodes drop only in fastest mode" {
    const alloc = std.testing.allocator;

    var strict_doc = StrictTestDocument.init(alloc);
    defer strict_doc.deinit();
    const NodesOnlyOptions: ParseOptions = .{ .drop_whitespace_text_nodes = .nodes };
    var nodes_doc = NodesOnlyOptions.Document().init(alloc);
    defer nodes_doc.deinit();
    var fast_doc = TestDocument.init(alloc);
    defer fast_doc.deinit();

    var strict_html = "<div id='x'> \n\t </div><div id='y'> hi </div>".*;
    var nodes_html = strict_html;
    var fast_html = strict_html;

    try resetParsed(StrictTestOptions, &strict_doc, &strict_html);
    try resetParsed(NodesOnlyOptions, &nodes_doc, &nodes_html);
    try resetParsed(DefaultTestOptions, &fast_doc, &fast_html);

    try std.testing.expectEqual(@as(usize, 5), strict_doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 4), nodes_doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 4), fast_doc.nodes.len);

    const nodes_y = firstQuery(nodes_doc.query("#y")) orelse return error.TestUnexpectedResult;
    const nodes_text = try nodes_y.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer nodes_text.free(alloc);
    try std.testing.expectEqualStrings(" hi ", nodes_text.value);

    const y = firstQuery(fast_doc.query("#y")) orelse return error.TestUnexpectedResult;
    const text = try y.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer text.free(alloc);
    try std.testing.expectEqualStrings("hi ", text.value);
}

test "fastest mode drops indentation-only runs between child elements" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div>\n  <a></a>\n  <b></b>\n</div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expectEqual(@as(usize, 4), doc.nodes.len);

    const div = doc.nodeAt(1);
    var div_children = div.children();
    const a = div_children.next() orelse return error.TestUnexpectedResult;
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

    try std.testing.expect(firstQuery(doc.query("div#a[data-q='x>y']")) != null);
    try std.testing.expect(firstQuery(doc.query("img#i[src='x']")) != null);
    try std.testing.expect(firstQuery(doc.query("br#b")) != null);
}

test "attribute scanner respects quoted greater-than with whitespace around equals" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div title \n = \"a>b\"><span id = x></span></div><p id= \"after\"></p>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("div[title='a>b'] span#x")) != null);
    try std.testing.expect(firstQuery(doc.query("p#after")) != null);
}

test "raw-text and svg scanners respect spaced quoted end delimiters" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = ("<script>const x = '<svg>';</script data-x = \"a>b\">" ++
        "<svg><svg data-x = \"a>b\"><g></g></svg></svg>" ++
        "<div id = after></div>").*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("script")) != null);
    try std.testing.expect(firstQuery(doc.query("div#after")) != null);
    var svg_it = doc.query("svg");
    try std.testing.expect(try svg_it.next() != null);
    try std.testing.expect(try svg_it.next() == null);
}

test "attribute parsing still builds the DOM" {
    const alloc = std.testing.allocator;
    var doc = TestDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='x'><span id='y'></span></div>".*;
    try resetParsed(DefaultTestOptions, &doc, &html);

    try std.testing.expect(doc.nodes.len > 1);
    try std.testing.expect(firstQuery(doc.query("#x")) != null);
    try std.testing.expect(firstQuery(doc.query("#y")) != null);
}

test "parser randomized structural sweep" {
    const alloc = std.testing.allocator;
    var seed: u64 = 0;
    while (seed < 16) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed +% 0x4a91_13d2_7d6f_20b5);
        const random = prng.random();

        var case_idx: usize = 0;
        while (case_idx < 512) : (case_idx += 1) {
            const len = random.intRangeLessThan(usize, 0, 257);
            const input = try alloc.alloc(u8, len);
            defer alloc.free(input);
            fillInterestingParserBytes(random, input);
            try runStreamPropertyCase(alloc, input);
            runParserPropertyCase(alloc, input) catch |err| {
                std.debug.print("parser randomized seed={} case {} failed err={} len={}\n", .{ seed, case_idx, err, len });
                return err;
            };
        }
    }
}

test "closing-tag index tracks duplicate names and rejects unmatched tags" {
    const alloc = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(alloc);
    defer source.deinit();
    try source.writer.writeAll("<A><b><a></A><c>");
    for (0..2048) |_| try source.writer.writeAll("</never-opened>");
    try source.writer.writeAll("</A>");

    const input = try source.toOwnedSlice();
    defer alloc.free(input);
    var doc = try (ParseOptions{}).parse(alloc, input);
    defer doc.deinit();

    const c = firstQuery(doc.query("c")) orelse return error.TestUnexpectedResult;
    const parent = c.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", parent.tagName());
}

test "lazy closing-tag index activates only for deep misses and stays live" {
    const alloc = std.testing.allocator;
    const TestOptions: ParseOptions = .{};
    const input = "abcdefghX1 abcdefghY1 a b c x y";
    var state = ParseState(TestOptions){ .allocator = alloc, .input = @constCast(input), .i = 0 };
    defer state.nodes.deinit(alloc);
    defer state.deinitParseStack();
    defer state.deinitTagIndex();
    try state.initContainers();

    const Push = struct {
        fn one(s: anytype, comptime indexed: bool, start: usize, end_: usize) !void {
            const name = s.input[start..end_];
            const node_idx = s.nodes.items.len;
            try s.addNode(.{ start, end_ }, true, .{});
            try s.pushOpen(indexed, .{
                .idx = @intCast(node_idx),
                .tag_key = tags.first8KeyWithMode(name, false),
                .last_child = if (comptime TestOptions.store_last_child or TestOptions.store_prev_sibling) InvalidIndex else {},
            });
        }
    };

    try Push.one(&state, false, 22, 23); // a
    try Push.one(&state, false, 24, 25); // b
    try Push.one(&state, false, 26, 27); // c
    try std.testing.expectEqual(@as(usize, 1), (try state.findOpenForSlowClose(false, "a", tags.first8KeyWithMode("a", false))).?);

    // Shallow malformed closes stay on the allocation-free backwards scan path.
    try std.testing.expect(try state.findOpenForSlowClose(false, "missing", tags.first8KeyWithMode("missing", false)) == null);
    try std.testing.expect(state.tag_index == null);

    // A deep miss activates the recovery index exactly once.
    while (state.parse_stack.items.len < CloseIndexMinDepth) try Push.one(&state, false, 28, 29); // x
    try std.testing.expect(try state.findOpenForSlowClose(false, "missing", tags.first8KeyWithMode("missing", false)) == null);
    try std.testing.expect(state.tag_index != null);
    try std.testing.expectEqual(state.parse_stack.items.len - 1, (try state.findOpenForSlowClose(true, "x", tags.first8KeyWithMode("x", false))).?);
    try std.testing.expectEqual(@as(usize, 1), (try state.findOpenForSlowClose(true, "a", tags.first8KeyWithMode("a", false))).?);

    _ = state.popOpen(true);
    try Push.one(&state, true, 30, 31); // y
    try std.testing.expectEqual(state.parse_stack.items.len - 1, (try state.findOpenForSlowClose(true, "y", tags.first8KeyWithMode("y", false))).?);
    try std.testing.expect(try state.findOpenForSlowClose(true, "still-missing", tags.first8KeyWithMode("still-missing", false)) == null);

    // First-eight-byte collisions still walk the secondary link chain and verify
    // the complete tag name against the source span.
    while (state.parse_stack.items.len > 1) _ = state.popOpen(true);
    try Push.one(&state, true, 0, 10);
    try Push.one(&state, true, 11, 21);
    const first_long = input[0..10];
    try std.testing.expectEqual(@as(usize, 1), (try state.findOpenForSlowClose(true, first_long, tags.first8KeyWithMode(first_long, false))).?);
    try std.testing.expectEqual(@as(usize, 2), (try state.findOpenForSlowClose(true, "abcdefghy1", tags.first8KeyWithMode("abcdefghy1", false))).?);
}

fn runStreamPropertyCase(alloc: std.mem.Allocator, input: []const u8) !void {
    const stream = @import("stream.zig");
    const Ctx = struct {
        saw_attrs: bool = false,
        fn cb(self: *@This(), ev: stream.Event) !bool {
            if (ev.kind == .start_tag) {
                var it = ev.attributes();
                while (it.next()) |a| {
                    _ = a.nameSlice();
                    _ = a.valueRaw();
                    self.saw_attrs = true;
                }
            }
            return true;
        }
    };
    var ctx: Ctx = .{};
    try stream.parse(alloc, input, &ctx, Ctx.cb);

    const SkipCtx = struct {
        fn cb(self: *@This(), ev: stream.Event) !bool {
            _ = self;
            if (ev.kind == .start_tag) {
                const n = ev.nameSlice();
                if (std.ascii.eqlIgnoreCase(n, "script") or std.ascii.eqlIgnoreCase(n, "style") or std.ascii.eqlIgnoreCase(n, "section")) return false;
            }
            return true;
        }
    };
    var skip_ctx: SkipCtx = .{};
    try stream.parse(alloc, input, &skip_ctx, SkipCtx.cb);

    const OptCtx = struct {
        fn cb(self: *@This(), ev: stream.Event) !bool {
            _ = .{ self, ev };
            return true;
        }
    };
    var opt_ctx: OptCtx = .{};
    try (stream.Parser{ .options = .{
        .include_comments = true,
        .include_doctype = true,
        .include_processing_instructions = true,
        .track_nesting = false,
        .drop_whitespace_text_nodes = true,
    } }).parse(alloc, input, &opt_ctx, OptCtx.cb);
    _ = &ctx;
}

fn fuzzParserProperties(alloc: std.mem.Allocator, smith: *std.testing.Smith) !void {
    const len = smith.value(u8);
    if (len == 0) return;
    const input = try alloc.alloc(u8, len);
    defer alloc.free(input);
    fillInterestingParserBytesSmith(smith, input);
    try runParserPropertyCase(alloc, input);
}

test "DOM parser accepts empty input" {
    const alloc = std.testing.allocator;
    var input: [0]u8 = .{};
    var doc = try (ParseOptions{}).parse(alloc, &input);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqual(@as(IndexInt, 0), doc.nodes[0].subtree_end);
}

test "fuzz parser preserves invariants across parse modes" {
    try std.testing.fuzz(std.testing.allocator, fuzzParserProperties, .{ .corpus = &.{
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

test "curated tokenizer corpus keeps destructive and read-only modes equivalent" {
    const alloc = std.testing.allocator;
    const corpus = [_][]const u8{
        "<!DOCTYPE html><!--before--><DiV ID=x DaTa-V = 'a&amp;b'>text<!--middle-->tail</DiV>",
        "<p id=a>one<p id=b>two<ul><li>x<li>y</ul>",
        "<script>if (a < b) x = '&amp;';</ScRiPt x = \"a>b\"><title>a&amp;<b</title>",
        "<div a='single > quote' b=\"double > quote\" c = naked d=></div>",
        "<div id=x <broken = 'a>b'><span id=y></span></div>",
        "<![CDATA[not markup <div id=x>]]><p id=after></p>",
        "<plaintext><DIV id=not-a-node>&amp;<!--still text-->",
        "<very-long-custom-element-name data-very-long-attribute-name='abcdefghijklmnopqrstuvwxyz&amp;0123456789'></very-long-custom-element-name>",
        "<div data-n='a\x00b&#0;c' data-invalid='\xff\xfe'><span>\x00&amp;\xff</span></div>",
    };

    for (corpus) |input| try runParserPropertyCase(alloc, input);

    var deep: std.Io.Writer.Allocating = .init(alloc);
    defer deep.deinit();
    for (0..128) |_| try deep.writer.writeAll("<DiV data-v='a&amp;b'>");
    try deep.writer.writeAll("leaf");
    for (0..128) |_| try deep.writer.writeAll("</dIv>");
    try runParserPropertyCase(alloc, deep.written());
}
