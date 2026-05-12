const std = @import("std");
const tables = @import("tables.zig");
const attr = @import("attr.zig");
const entities = @import("entities.zig");
const tags = @import("tags.zig");
const runtime_selector = @import("../selector/runtime.zig");
const ast = @import("../selector/ast.zig");
const matcher = @import("../selector/matcher.zig");
const matcher_debug = @import("../selector/matcher_debug.zig");
const selector_debug = @import("../debug/selector_debug.zig");
const instrumentation = @import("../debug/instrumentation.zig");
const parser = @import("parser.zig");
const common = @import("../common.zig");
const IndexInt = common.IndexInt;

// SAFETY: Document retains the parsed source reference for the life of
// nodes/iterators. In destructive mode `source` aliases the caller's
// writable buffer. Node spans and indices are validated on parse; helpers guard
// against InvalidIndex and out-of-range indexes.

/// Sentinel used for missing node indexes and invalid spans.
pub const InvalidIndex: IndexInt = common.InvalidIndex;
/// Inclusive-exclusive byte span into the document source buffer.
pub const Span = struct {
    /// Inclusive start byte offset in the document source.
    start: IndexInt,
    /// Number of bytes in the span.
    len: IndexInt,

    /// Returns the exclusive end byte offset in the document source.
    pub fn end(self: @This()) IndexInt {
        return self.start + self.len;
    }

    /// Updates span length from an exclusive end offset.
    pub fn setEnd(self: *@This(), end_offset: IndexInt) void {
        std.debug.assert(end_offset >= self.start);
        self.len = end_offset - self.start;
    }

    /// Borrows immutable bytes referenced by this span.
    pub fn slice(self: @This(), source: []const u8) []const u8 {
        return source[self.start..self.end()];
    }

    /// Borrows mutable bytes referenced by this span.
    pub fn sliceMut(self: @This(), source: []u8) []u8 {
        return source[self.start..self.end()];
    }

    /// Formats this span for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Span{{start={}, len={}}}", .{ self.start, self.len });
    }
};

/// Compile-time parser options and type factory for generated public API types.
pub const ParseOptions = struct {
    /// Parse-time whitespace text handling.
    pub const WhitespaceText = enum {
        /// Preserve every text node exactly as it appears in source.
        none,
        /// Drop text nodes that contain only HTML whitespace.
        nodes,
        /// Drop whitespace-only text nodes and trim leading whitespace from
        /// retained text nodes. This is the default throughput-oriented mode.
        nodes_and_preceding,
    };

    /// Controls which whitespace-only text is discarded during parse.
    drop_whitespace_text_nodes: WhitespaceText = .nodes_and_preceding,
    /// Preserves caller bytes by parsing directly from the original source and
    /// keeping lazy attr/text decoding out of the input buffer.
    /// This is off by default so the destructive hot path stays unchanged.
    non_destructive: bool = false,
    /// Persist direct last-child links for O(1) `children().last()`.
    /// Off by default because first child and next sibling are already bounded.
    store_last_child: bool = false,
    /// Persist previous-sibling links for O(1) `prevSibling()` and sibling selectors.
    store_prev_sibling: bool = false,

    /// Returns the accepted parse input slice type for this option set.
    pub fn Input(options: @This()) type {
        return if (options.non_destructive) []const u8 else []u8;
    }

    /// Parses `input` and returns a fully-owned document for this option set.
    pub fn parse(comptime options: @This(), gpa: std.mem.Allocator, input: options.Input()) !options.Document() {
        return parser.parse(options, gpa, input);
    }

    /// Returns the lightweight node wrapper type bound to this option set.
    pub fn Node(options: @This()) type {
        return GetNode(options);
    }

    /// Returns the lazy query iterator type for this option set.
    pub fn QueryIter(options: @This()) type {
        return GetQueryIter(options);
    }

    /// Returns the structured result type for debug query helpers.
    pub fn QueryDebugResult(options: @This()) type {
        return GetQueryDebugResult(options);
    }

    /// Returns direct-child iterator type for this option set.
    pub fn ChildrenIter(options: @This()) type {
        return GetChildrenIter(options);
    }

    /// Returns the document type (parser + query surface) for this option set.
    pub fn Document(options: @This()) type {
        return GetDocument(options);
    }

    /// Returns the raw node storage type for this option set.
    pub fn RawNode(options: @This()) type {
        return GetRawNode(options);
    }

    /// Formats parse options for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ParseOptions{{drop_whitespace_text_nodes={s}, non_destructive={}, store_last_child={}, store_prev_sibling={}}}", .{
            @tagName(self.drop_whitespace_text_nodes),
            self.non_destructive,
            self.store_last_child,
            self.store_prev_sibling,
        });
    }
};

/// Returns an `IndexInt` field when enabled, otherwise a zero-sized field.
fn OptionalIndex(comptime enabled: bool) type {
    return if (enabled) IndexInt else void;
}

/// Builds the backing node storage record for a parse option set.
pub fn GetRawNode(comptime options: ParseOptions) type {
    return struct {
        /// Parent node index.
        parent: IndexInt,
        /// Inclusive subtree tail index for elements and document root.
        /// `0` marks text nodes because text nodes cannot have descendants.
        subtree_end: IndexInt,

        /// Tag-name span for elements or text span for text nodes.
        name_or_text: Span,

        /// Last direct element child index when `store_last_child` is enabled.
        last_child: OptionalIndex(options.store_last_child),
        /// Previous element sibling index when `store_prev_sibling` is enabled.
        prev_sibling: OptionalIndex(options.store_prev_sibling),

        /// Returns whether `idx` designates the synthetic document root.
        pub inline fn isDocument(_: *const @This(), idx: IndexInt) bool {
            return idx == 0;
        }

        /// Returns whether this node is a text node.
        pub inline fn isText(self: *const @This(), idx: IndexInt) bool {
            return idx != 0 and self.subtree_end == 0;
        }

        /// Returns whether this node is an element node.
        pub inline fn isElement(self: *const @This(), idx: IndexInt) bool {
            return idx != 0 and self.subtree_end != 0;
        }
    };
}

/// Default raw node layout used by type-level tests and external inspection.
pub const RawNode = GetRawNode(.{});

/// Builds the concrete node wrapper type for a parse option set.
fn GetNode(comptime options: ParseOptions) type {
    return struct {
        //! Public node wrapper that carries document pointer + node index.
        const RawNodeType = options.RawNode();
        const DocType = options.Document();
        const ChildrenIterType = options.ChildrenIter();
        const DebugQueryResultType = options.QueryDebugResult();
        const QueryIterType = options.QueryIter();
        const Self = @This();

        /// Controls text extraction behavior for `innerText*` APIs.
        pub const TextOptions = struct {
            /// Collapses runs of HTML whitespace to single spaces when true.
            normalize_whitespace: bool = true,
            /// Decodes HTML character references when true.
            unescape: bool = true,

            /// Formats text extraction options for human-readable output.
            pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                try writer.print("TextOptions{{normalize_whitespace={}, unescape={}}}", .{
                    self.normalize_whitespace,
                    self.unescape,
                });
            }
        };

        /// Text lookup result. `value` may borrow document source or point to an
        /// allocation made with the allocator passed to `innerTextWithOptions`.
        pub const TextResult = struct {
            /// Text bytes for the requested subtree.
            value: []const u8,

            /// Returns true when `value` points inside `doc` source.
            pub fn isBorrowed(self: @This(), doc: *const DocType) bool {
                return doc.isOwnedSlice(self.value);
            }

            /// Frees `value` only when it is not borrowed from `doc` source.
            pub fn free(self: @This(), doc: *const DocType, gpa: std.mem.Allocator) void {
                if (self.value.len == 0 or self.isBorrowed(doc)) return;
                gpa.free(self.value);
            }
        };

        /// Attribute lookup result. `value` may borrow document source or point
        /// to an allocation made with the allocator passed to `getAttributeValue`.
        pub const AttributeValueResult = struct {
            /// Decoded attribute value bytes.
            value: []const u8,

            /// Returns true when `value` points inside `doc` source.
            pub fn isBorrowed(self: @This(), doc: *const DocType) bool {
                return doc.isOwnedSlice(self.value);
            }

            /// Frees `value` only when it is not borrowed from `doc` source.
            pub fn free(self: @This(), doc: *const DocType, gpa: std.mem.Allocator) void {
                if (self.value.len == 0 or self.isBorrowed(doc)) return;
                if (comptime options.non_destructive) {
                    gpa.free(self.value);
                } else {
                    unreachable; // Logic error in library
                }
            }
        };

        /// Returns the error set exposed by a writer value or writer pointer.
        pub fn WriterError(comptime WriterType: type) type {
            return switch (@typeInfo(WriterType)) {
                .pointer => std.meta.Child(WriterType).Error,
                else => WriterType.Error,
            };
        }

        /// Owning document pointer.
        doc: *const DocType,
        /// Backing node index inside `doc.nodes`.
        index: IndexInt,

        /// Asserts that this wrapper still points into its owning document.
        fn assertValidNode(self: @This()) void {
            std.debug.assert(self.index < self.doc.nodes.len);
        }

        /// Asserts that this wrapper points at a text node.
        fn assertText(self: @This()) void {
            self.assertValidNode();
            std.debug.assert(self.isText());
        }

        /// Asserts that this wrapper points at an element node.
        fn assertElement(self: @This()) void {
            self.assertValidNode();
            std.debug.assert(self.isElement());
        }

        /// Asserts that this wrapper can contain descendants for traversal/query.
        fn assertContainer(self: @This()) void {
            self.assertValidNode();
            std.debug.assert(self.isDocument() or self.isElement());
        }

        /// Returns the underlying raw node record.
        pub fn raw(self: @This()) *const RawNodeType {
            self.assertValidNode();
            return &self.doc.nodes[self.index];
        }

        /// Returns whether `idx` designates the synthetic document root.
        pub inline fn isDocument(self: *const @This()) bool {
            return self.raw().isDocument(self.index);
        }

        /// Returns whether this node is a text node.
        pub inline fn isText(self: *const @This()) bool {
            return self.raw().isText(self.index);
        }

        /// Returns whether this node is an element node.
        pub inline fn isElement(self: *const @This()) bool {
            return self.raw().isElement(self.index);
        }

        /// Returns element tag name bytes from parsed source.
        pub fn tagName(self: @This()) []const u8 {
            self.assertElement();
            return self.raw().name_or_text.slice(self.doc.source);
        }

        pub fn text(self: @This()) []const u8 {
            assertText();
            return self.raw().name_or_text.slice(self.doc.source);
        }

        /// Returns text content of this subtree; may borrow or allocate with `gpa`.
        /// It is also valid to call this on a text node
        pub fn innerTextWithOptions(self: @This(), gpa: std.mem.Allocator, comptime opts: Self.TextOptions) !TextResult {
            const doc = self.doc;
            const node_raw = self.raw();

            const first_idx: IndexInt = if (node_raw.isText(self.index)) self.index else blk: {
                var first_idx = InvalidIndex;
                var idx = self.index + 1;

                std.debug.assert(node_raw.subtree_end < doc.nodes.len);
                while (idx <= node_raw.subtree_end) : (idx += 1) {
                    if (!doc.nodeAt(idx).isText()) continue;
                    first_idx = idx;
                    if (comptime options.non_destructive) {
                        return .{ .value = try self.innerTextOwnedFromScan(gpa, opts, .{
                            .first_idx = first_idx,
                            .resume_idx = first_idx + 1,
                        }) };
                    }
                    break;
                } else {
                    return .{ .value = "" };
                }

                idx += 1;
                while (idx <= node_raw.subtree_end) : (idx += 1) {
                    if (!doc.nodeAt(idx).isText()) continue;
                    return .{ .value = try self.innerTextOwnedFromScan(gpa, opts, .{
                        .first_idx = first_idx,
                        .resume_idx = idx,
                    }) };
                }

                break :blk first_idx;
            };

            const node = &self.doc.nodes[first_idx];

            if (comptime (options.non_destructive and (opts.unescape or opts.normalize_whitespace))) {
                return .{ .value = try self.innerTextOwnedFromScan(gpa, opts, .{
                    .first_idx = first_idx,
                    .resume_idx = first_idx + 1,
                }) };
            }

            if (comptime opts.unescape) {
                const new_len = entities.decodeInPlace(opts.normalize_whitespace, node.name_or_text.sliceMut(doc.source));
                node.name_or_text.len = @intCast(new_len);
            } else if (comptime opts.normalize_whitespace) {
                const new_len = entities.normalizeWhitespaceInPlace(node.name_or_text.sliceMut(doc.source));
                node.name_or_text.len = @intCast(new_len);
            }

            return .{ .value = node.name_or_text.slice(self.doc.source) };
        }

        /// Materializes text by scanning all text descendants from a known first text node.
        fn innerTextOwnedFromScan(self: @This(), gpa: std.mem.Allocator, comptime opts: Self.TextOptions, scan: InnerTextProbe.Scan) ![]const u8 {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(gpa);
            const doc = self.doc;
            const node_raw = self.raw();

            try out.appendSlice(gpa, doc.nodes[scan.first_idx].name_or_text.slice(doc.source));

            var idx = scan.resume_idx;
            while (idx <= node_raw.subtree_end and idx < doc.nodes.len) : (idx += 1) {
                if (!doc.nodeAt(idx).isText()) continue;
                if (out.items.len != 0 and !tables.WhitespaceTable[out.items[out.items.len - 1]]) {
                    try out.append(gpa, ' ');
                }
                try out.appendSlice(gpa, doc.nodes[idx].name_or_text.slice(doc.source));
            }

            return try finishInnerTextOwned(&out, gpa, opts);
        }

        /// Applies final text decoding/normalization and transfers buffer ownership.
        fn finishInnerTextOwned(noalias out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime opts: Self.TextOptions) ![]const u8 {
            if (comptime opts.unescape) {
                out.items.len = entities.decodeInPlace(opts.normalize_whitespace, out.items);
            } else if (comptime opts.normalize_whitespace) {
                out.items.len = entities.normalizeWhitespaceInPlace(out.items);
            }
            return try out.toOwnedSlice(gpa);
        }

        /// Owned variant of `innerTextWithOptions`.
        /// It is also valid to call this on a text node
        pub fn innerTextOwnedWithOptions(self: @This(), gpa: std.mem.Allocator, comptime opts: Self.TextOptions) ![]const u8 {
            const node_raw = self.raw();
            const doc = self.doc;

            if (node_raw.isText(self.index)) {
                var out = std.ArrayList(u8).empty;
                errdefer out.deinit(gpa);
                try out.appendSlice(gpa, node_raw.name_or_text.slice(doc.source));
                return try finishInnerTextOwned(&out, gpa, opts);
            }

            var idx = self.index + 1;
            while (idx <= node_raw.subtree_end and idx < doc.nodes.len) : (idx += 1) {
                if (!doc.nodes[idx].isText(idx)) continue;
                return innerTextOwnedFromScan(self, gpa, opts, .{
                    .first_idx = idx,
                    .resume_idx = idx + 1,
                });
            }

            return "";
        }

        /// Returns decoded attribute value for `name`, if present.
        pub fn getAttributeValue(self: @This(), allocator: std.mem.Allocator, name: []const u8) !?AttributeValueResult {
            self.assertElement();
            return .{ .value = try attr.getAttrValue(self.doc, &self.doc.nodes[self.index], name, allocator) orelse return null };
        }

        /// Returns raw attribute value bytes for `name`, if present.
        /// Warning: when `options.non_destructive` is false this may point at
        /// bytes already mutated by previous decoded attribute lookups.
        pub fn getAttributeValueRaw(self: @This(), name: []const u8) ?[]const u8 {
            self.assertElement();
            return attr.getAttrValueRaw(self.doc, &self.doc.nodes[self.index], name);
        }

        /// Returns next element sibling.
        pub fn nextSibling(self: @This()) ?@This() {
            self.assertElement();
            if (common.nextElementSibling(self.doc, self.index)) |next| return .{ .doc = self.doc, .index = next };
            return null;
        }

        /// Returns previous element sibling.
        pub fn prevSibling(self: @This()) ?@This() {
            self.assertElement();
            if (common.prevElementSibling(self.doc, self.index)) |prev| return .{ .doc = self.doc, .index = prev };
            return null;
        }

        /// Returns parent element node.
        pub fn parentNode(self: @This()) ?@This() {
            self.assertValidNode();
            const parent = self.raw().parent;
            if (parent == InvalidIndex or parent == 0) return null;
            return .{ .doc = self.doc, .index = parent };
        }

        /// Returns direct-child node iterator.
        pub fn children(self: @This()) ChildrenIterType {
            self.assertContainer();
            return .{
                .doc = self.doc,
                .parent_idx = self.index,
                .next_idx = firstElementChild(self.doc, self.index),
            };
        }

        const InnerTextProbe = union(enum) {
            const Scan = struct {
                first_idx: IndexInt,
                resume_idx: IndexInt,
            };

            borrowed: []const u8,
            owned: Scan,
        };

        /// Writes HTML serialization of this node and its subtree to `writer`.
        pub fn writeHtml(self: @This(), writer: anytype) WriterError(@TypeOf(writer))!void {
            try writeNodeHtml(self.doc, self.index, self.raw(), writer, true);
        }

        /// Writes HTML serialization of this node only, excluding its children.
        pub fn writeSelfHtml(self: @This(), writer: anytype) WriterError(@TypeOf(writer))!void {
            try writeNodeHtml(self.doc, self.index, self.raw(), writer, false);
        }

        /// Default formatter uses HTML serialization for this node.
        pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.writeHtml(writer);
        }

        /// Writes one node as HTML, optionally including its full subtree.
        fn writeNodeHtml(
            doc: anytype,
            idx: IndexInt,
            noalias node_raw: anytype,
            writer: anytype,
            include_children: bool,
        ) WriterError(@TypeOf(writer))!void {
            if (node_raw.isText(idx)) {
                try writer.writeAll(node_raw.name_or_text.slice(doc.source));
                return;
            }

            if (idx != 0) {
                try writeElementOpenHtml(doc, node_raw, writer);
                if (!include_children or isVoidElement(doc, node_raw)) return;
            }

            const end = node_raw.subtree_end;
            const len_idx: IndexInt = @intCast(doc.nodes.len);
            var next_idx = idx + 1;
            var open_idx: IndexInt = if (idx != 0) idx else InvalidIndex;

            while (next_idx <= end and next_idx < len_idx) : (next_idx += 1) {
                while (open_idx != InvalidIndex and doc.nodes[open_idx].subtree_end < next_idx) {
                    try writeElementCloseHtml(doc, &doc.nodes[open_idx], writer);
                    const parent = doc.nodes[open_idx].parent;
                    open_idx = if (parent != InvalidIndex and parent != 0) parent else InvalidIndex;
                }

                const child = &doc.nodes[next_idx];
                if (child.isText(next_idx)) {
                    try writer.writeAll(child.name_or_text.slice(doc.source));
                    continue;
                }

                try writeElementOpenHtml(doc, child, writer);
                if (isVoidElement(doc, child)) continue;
                if (child.subtree_end == next_idx) {
                    try writeElementCloseHtml(doc, child, writer);
                    continue;
                }
                open_idx = next_idx;
            }

            while (open_idx != InvalidIndex) {
                try writeElementCloseHtml(doc, &doc.nodes[open_idx], writer);
                const parent = doc.nodes[open_idx].parent;
                open_idx = if (parent != InvalidIndex and parent != 0) parent else InvalidIndex;
            }
        }

        /// Writes an element start tag and its serialized attributes.
        fn writeElementOpenHtml(doc: anytype, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
            const name = node_raw.name_or_text.slice(doc.source);
            try writeByte(writer, '<');
            try writer.writeAll(name);
            try writeAttrsHtml(doc, node_raw, writer);
            try writeByte(writer, '>');
        }

        /// Writes an element end tag.
        fn writeElementCloseHtml(doc: anytype, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
            try writer.writeAll("</");
            try writer.writeAll(node_raw.name_or_text.slice(doc.source));
            try writeByte(writer, '>');
        }

        /// Returns true for HTML void elements, which never serialize end tags.
        fn isVoidElement(doc: anytype, noalias node_raw: anytype) bool {
            const name = node_raw.name_or_text.slice(doc.source);
            return tags.isVoidTagWithKey(name, tags.first8Key(name));
        }

        /// Writes serialized attributes from raw or destructively parsed attr bytes.
        fn writeAttrsHtml(doc: anytype, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
            const source: []const u8 = doc.source;
            var i: usize = @intCast(node_raw.name_or_text.end());
            const end = source.len;

            while (i < end) {
                while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
                if (i >= end) return;

                if (source[i] == 0) {
                    i = attr.skipAttrGap(source, end, i);
                    continue;
                }

                const name_start = i;
                const scanned = attr.scanAttrNameOrSkip(source, end, i);
                const name = scanned.name orelse return;
                i = scanned.next_start;
                if (name.len == 0) continue;
                if (i >= end) {
                    try writeAttrName(writer, name);
                    return;
                }

                const delim = source[i];
                if (delim == '=') {
                    const raw_value = attr.parseRawValue(source, end, i);
                    try writeByte(writer, ' ');
                    try writer.writeAll(source[name_start..raw_value.next_start]);
                    i = raw_value.next_start;
                    continue;
                }

                if (delim == 0) {
                    if (comptime options.non_destructive) {
                        i += 1;
                        continue;
                    }
                    const parsed = attr.parseParsedValue(doc.source, end, i);
                    try writeAttrName(writer, name);
                    try writeAttrValue(writer, parsed.value);
                    i = parsed.next_start;
                    continue;
                }

                if (delim == '>' or delim == '/') {
                    try writeAttrName(writer, name);
                    return;
                }

                if (tables.WhitespaceTable[delim]) {
                    try writeAttrName(writer, name);
                    i += 1;
                    continue;
                }

                try writeAttrName(writer, name);
                i += 1;
            }
        }

        /// Writes one leading-space-prefixed attribute name.
        fn writeAttrName(writer: anytype, name: []const u8) WriterError(@TypeOf(writer))!void {
            try writeByte(writer, ' ');
            try writer.writeAll(name);
        }

        /// Writes one quoted and escaped attribute value.
        fn writeAttrValue(writer: anytype, value: []const u8) WriterError(@TypeOf(writer))!void {
            try writer.writeAll("=\"");
            try writeEscapedAttrValue(writer, value);
            try writeByte(writer, '"');
        }

        /// Escapes attribute value bytes required by HTML serialization.
        fn writeEscapedAttrValue(writer: anytype, value: []const u8) WriterError(@TypeOf(writer))!void {
            for (value) |c| {
                switch (c) {
                    '&' => try writer.writeAll("&amp;"),
                    '<' => try writer.writeAll("&lt;"),
                    '"' => try writer.writeAll("&quot;"),
                    else => try writeByte(writer, c),
                }
            }
        }

        /// Writes one byte through the generic writer API.
        fn writeByte(writer: anytype, b: u8) WriterError(@TypeOf(writer))!void {
            try writer.writeAll(&[_]u8{b});
        }

        test "format text options" {
            if (comptime options.non_destructive or options.drop_whitespace_text_nodes == .none) return error.SkipZigTest;

            const alloc = std.testing.allocator;
            const rendered = try std.fmt.allocPrint(alloc, "{f}", .{Self.TextOptions{ .normalize_whitespace = false }});
            defer alloc.free(rendered);
            try std.testing.expectEqualStrings("TextOptions{normalize_whitespace=false, unescape=true}", rendered);
        }

        /// Compiles selector at comptime and returns lazy descendant iterator.
        pub fn query(self: @This(), comptime selector: []const u8) QueryIterType {
            const sel = comptime ast.Selector.compile(selector);
            if (self.doc.nodes.len == 0) return self.emptyQueryIter(sel);
            self.assertContainer();
            return self.queryIter(sel);
        }

        /// Returns lazy descendant iterator for already compiled selector.
        pub fn queryRuntime(self: @This(), sel: ast.Selector) QueryIterType {
            if (self.doc.nodes.len == 0) return self.emptyQueryIter(sel);
            self.assertContainer();
            return self.queryIter(sel);
        }

        /// Creates an exhausted iterator for empty documents.
        fn emptyQueryIter(self: @This(), sel: ast.Selector) QueryIterType {
            return .{
                .doc = self.doc,
                .selector = sel,
                .scope_root = InvalidIndex,
                .next_index = 1,
                .end_index = 1,
            };
        }

        /// Creates a scoped query iterator rooted at this node.
        fn queryIter(self: *const @This(), sel: ast.Selector) QueryIterType {
            return .{
                .doc = self.doc,
                .selector = sel,
                .scope_root = self.index,
                .next_index = self.index + 1, // Node 0 will work too since it's index = 0
                .end_index = self.raw().subtree_end + 1, // Node 0 should work too sinde it's subtree_end should be last node
            };
        }
    };
}

/// Computes the first direct element child from preorder storage.
fn firstElementChild(doc: anytype, parent_idx: IndexInt) IndexInt {
    const parent = &doc.nodes[parent_idx];
    const RawNodeType = @TypeOf(parent.*);
    if (comptime @FieldType(RawNodeType, "last_child") != void) {
        if (parent.last_child == InvalidIndex) return InvalidIndex;
    } else if (parent.subtree_end == parent_idx) {
        return InvalidIndex;
    }

    const first_idx: usize = @as(usize, @intCast(parent_idx)) + 1;
    const end: usize = @min(@as(usize, @intCast(parent.subtree_end)), doc.nodes.len - 1);
    if (first_idx <= end) {
        const first_int: IndexInt = @intCast(first_idx);
        const first = &doc.nodes[first_idx];
        if (first.parent == parent_idx and first.isElement(first_int)) return first_int;
    }

    const second_idx = first_idx + 1;
    if (second_idx <= end) {
        const second_int: IndexInt = @intCast(second_idx);
        const second = &doc.nodes[second_idx];
        if (second.parent == parent_idx and second.isElement(second_int)) return second_int;
    }

    return InvalidIndex;
}

/// Builds the concrete selector iterator type for a parse option set.
fn GetQueryIter(comptime options: ParseOptions) type {
    return struct {
        //! Lazy selector iterator over document or scoped subtree matches.
        const DocType = options.Document();
        const NodeTypeWrapper = options.Node();

        /// Owning document pointer.
        doc: *const DocType,
        /// Selector evaluated by this iterator.
        selector: ast.Selector,
        /// Optional subtree root for scoped queries.
        scope_root: IndexInt = InvalidIndex,
        /// Next node index to test.
        next_index: IndexInt = 1,
        /// Exclusive traversal bound for `next_index`.
        end_index: IndexInt = 1,

        /// Returns next matching node or `null` when exhausted.
        pub inline fn next(noalias self: *@This()) ?NodeTypeWrapper {
            if (self.end_index > self.doc.nodes.len) {
                @branchHint(.cold);
                self.next_index = self.end_index;
                return null;
            }

            while (self.next_index < self.end_index) : (self.next_index += 1) {
                if (!self.doc.nodeAt(self.next_index).isElement()) continue;

                if (matcher.matchesSelectorAt(DocType, self.doc, self.selector, self.next_index, self.scope_root)) {
                    defer self.next_index += 1;
                    return self.doc.nodeAt(self.next_index);
                }
            }
            return null;
        }

        /// Formats iterator state for human-readable output.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("QueryIter{{scope_root={}, next_index={}}}", .{
                self.scope_root,
                self.next_index,
            });
        }

        /// Allocates and returns all remaining matches.
        pub fn collect(self: @This(), allocator: std.mem.Allocator) ![]NodeTypeWrapper {
            const upper_bound: usize = if (self.next_index < self.end_index and self.end_index <= self.doc.nodes.len)
                @intCast(self.end_index - self.next_index)
            else
                0;
            const out = try allocator.alloc(NodeTypeWrapper, upper_bound);

            var fill_it = self;
            var out_idx: usize = 0;
            while (fill_it.next()) |node| : (out_idx += 1) out[out_idx] = node;
            if (out_idx == out.len) return out;
            if (out_idx == 0) {
                allocator.free(out);
                return try allocator.alloc(NodeTypeWrapper, 0);
            }
            return allocator.realloc(out, out_idx) catch |err| {
                allocator.free(out);
                return err;
            };
        }
    };
}

/// Builds the debug query result type for a parse option set.
fn GetQueryDebugResult(comptime options: ParseOptions) type {
    return struct {
        /// First matching node, if any.
        node: ?options.Node() = null,
        /// Detailed mismatch diagnostics for the attempted query.
        report: selector_debug.QueryDebugReport = .{},
        /// Runtime parse error, if selector compilation failed.
        err: ?runtime_selector.Error = null,
    };
}

/// Builds the direct element-child iterator type for a parse option set.
fn GetChildrenIter(comptime options: ParseOptions) type {
    return struct {
        //! Iterator over direct child nodes for a parent node.
        const DocType = options.Document();
        const NodeTypeWrapper = options.Node();

        /// Owning document pointer.
        doc: *const DocType,
        /// Parent whose direct children are being iterated.
        parent_idx: IndexInt = InvalidIndex,
        /// Next direct child index to yield.
        next_idx: IndexInt = InvalidIndex,

        /// Returns next wrapped child node or `null` when exhausted.
        pub inline fn next(noalias self: *@This()) ?NodeTypeWrapper {
            if (self.next_idx == InvalidIndex) return null;
            defer self.next_idx = common.nextElementSibling(self.doc, self.next_idx) orelse InvalidIndex;
            return .{ .doc = self.doc, .index = self.next_idx };
        }

        /// Returns last remaining wrapped child node without consuming it.
        pub fn last(self: @This()) ?NodeTypeWrapper {
            if (comptime !options.store_last_child) {
                @compileError("children().last() requires .store_last_child = true");
            }
            if (self.next_idx == InvalidIndex or self.parent_idx == InvalidIndex) return null;
            const last_child = self.doc.nodes[self.parent_idx].last_child;
            if (last_child == InvalidIndex) return null;
            return .{ .doc = self.doc, .index = last_child };
        }

        /// Allocates and returns all remaining wrapped child nodes.
        pub fn collect(noalias self: *@This(), allocator: std.mem.Allocator) ![]NodeTypeWrapper {
            var count: usize = 0;
            var idx = self.next_idx;
            while (idx != InvalidIndex) : (idx = common.nextElementSibling(self.doc, idx) orelse InvalidIndex) {
                count += 1;
            }

            const out = try allocator.alloc(NodeTypeWrapper, count);
            idx = self.next_idx;
            var out_idx: usize = 0;
            while (idx != InvalidIndex) : (idx = common.nextElementSibling(self.doc, idx) orelse InvalidIndex) {
                out[out_idx] = .{
                    .doc = self.doc,
                    .index = idx,
                };
                out_idx += 1;
            }
            self.next_idx = InvalidIndex;
            return out;
        }

        /// Formats iterator state for human-readable output.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("ChildrenIter{{next_idx={}}}", .{self.next_idx});
        }
    };
}

/// Builds the concrete document owner type for a parse option set.
fn GetDocument(comptime options: ParseOptions) type {
    return struct {
        //! Parsed document owner and query entrypoint container.
        const RawNodeType = options.RawNode();
        const DebugQueryResultType = options.QueryDebugResult();
        const ChildrenIterType = options.ChildrenIter();
        const NodeTypeWrapper = options.Node();
        const QueryIterType = options.QueryIter();

        /// Allocator used for node storage and caller-directed temporary work.
        allocator: std.mem.Allocator,
        /// Source bytes referenced by node spans.
        source: options.Input(),

        /// Parsed node storage.
        nodes: []RawNodeType = &[_]RawNodeType{},

        /// Initializes an empty document using `allocator` for internal storage.
        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .source = emptySource(),
            };
        }

        /// Releases all document-owned memory.
        pub fn deinit(noalias self: *@This()) void {
            if (self.nodes.len == 0) return;
            self.allocator.free(self.nodes);
            self.nodes = &[_]RawNodeType{};
        }

        /// Clears parsed state and releases parsed node storage.
        pub fn clear(noalias self: *@This()) void {
            self.source = emptySource();
            self.deinit(); // this just clears the nodes
        }

        /// Returns an empty source slice with mutability matching parse options.
        fn emptySource() options.Input() {
            if (comptime options.non_destructive) {
                return &[_]u8{};
            }
            return @constCast(@as([]const u8, &[_]u8{}));
        }

        /// Returns whether `bytes` points inside the document's source buffer.
        pub fn isOwnedSlice(self: *const @This(), bytes: []const u8) bool {
            if (self.source.len == 0 or bytes.len == 0) return false;
            const source_start = @intFromPtr(self.source.ptr);
            const source_end = source_start + self.source.len;
            const bytes_start = @intFromPtr(bytes.ptr);
            const bytes_end = bytes_start + bytes.len;
            return bytes_start >= source_start and bytes_end <= source_end;
        }

        pub fn root(self: *const @This()) NodeTypeWrapper {
            return self.nodeAt(0);
        }

        /// Compiles selector at comptime and returns lazy iterator over matches.
        pub fn query(self: *const @This(), comptime selector: []const u8) QueryIterType {
            return self.root().query(selector);
        }

        /// Returns lazy iterator over matches for already compiled selector.
        pub fn queryRuntime(self: *const @This(), sel: ast.Selector) QueryIterType {
            return self.root().queryIter(sel);
        }

        /// Runs debug selector matching from a document or node scope.
        fn debugFirstMatchFrom(self: *const @This(), sel: ast.Selector, scope_root: IndexInt) DebugQueryResultType {
            var report: selector_debug.QueryDebugReport = .{};
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const idx = matcher_debug.explainFirstMatch(@This(), self, scratch.allocator(), sel, scope_root, &report) orelse {
                return .{ .report = report };
            };
            return .{
                .node = .{ .doc = self, .index = idx },
                .report = report,
            };
        }

        /// Returns first `<html>` element in the document.
        pub fn html(self: *const @This()) ?NodeTypeWrapper {
            return self.findFirstTag("html");
        }

        /// Returns first `<head>` element in the document.
        pub fn head(self: *const @This()) ?NodeTypeWrapper {
            return self.findFirstTag("head");
        }

        /// Returns first `<body>` element in the document.
        pub fn body(self: *const @This()) ?NodeTypeWrapper {
            return self.findFirstTag("body");
        }

        /// Returns first element whose tag name equals `name` (ASCII-insensitive).
        pub fn findFirstTag(self: *const @This(), name: []const u8) ?NodeTypeWrapper {
            var i: usize = 1;
            while (i < self.nodes.len) : (i += 1) {
                const n = &self.nodes[i];
                if (!n.isElement(@intCast(i))) continue;
                if (tables.eqlIgnoreCaseAscii(n.name_or_text.slice(self.source), name)) return .{ .doc = self, .index = @intCast(i) };
            }
            return null;
        }

        /// Wraps a raw node index as a public `Node` wrapper.
        pub inline fn nodeAt(self: *const @This(), idx: IndexInt) NodeTypeWrapper {
            std.debug.assert(idx != InvalidIndex);
            std.debug.assert(idx < self.nodes.len);
            return .{
                .doc = self,
                .index = idx,
            };
        }

        /// Writes HTML serialization of this node and its subtree to `writer`.
        pub fn writeHtml(self: *const @This(), writer: anytype) NodeTypeWrapper.WriterError(@TypeOf(writer))!void {
            if (comptime options.non_destructive) {
                try writer.writeAll(self.source);
                return;
            }
            return self.root().writeHtml(writer);
        }

        /// Default formatter uses HTML serialization for this node.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.writeHtml(writer);
        }
    };
}

/// Re-exported text extraction options used by node text APIs.
pub const TextOptions = GetNode(.{}).TextOptions;

/// Test helper that replaces a document with freshly parsed input.
fn resetParsed(comptime options: ParseOptions, doc: *options.Document(), input: options.Input()) !void {
    doc.deinit();
    doc.* = try options.parse(doc.allocator, input);
}

/// Test helper forcing node/document layout instantiation.
fn assertNodeTypeLayouts() void {
    _ = @sizeOf(RawNode);
    _ = @sizeOf(GetNode(.{}));
}

test "document type excludes parser-only and shadow-source state" {
    try std.testing.expect(!@hasField(GetDocument(.{}), "parse_stack"));
    try std.testing.expect(!@hasField(GetDocument(.{}), "original_source"));
    try std.testing.expect(!@hasField(GetDocument(.{}), "owned_shadow_source"));
    try std.testing.expect(!@hasField(GetDocument(.{}), "mutable_source"));
    try std.testing.expect(!@hasField(RawNode, "kind"));
    try std.testing.expect(!@hasField(RawNode, "attr_end"));
    try std.testing.expect(!@hasField(RawNode, "first_child"));
    try std.testing.expect(!@hasField(RawNode, "next_sibling"));
    try std.testing.expect(!@hasDecl(ParseOptions, "GetOpenElem"));
}

test "raw node optional metadata follows parse options" {
    const CompactRaw = GetRawNode(.{ .store_last_child = false, .store_prev_sibling = false });
    const FullRaw = GetRawNode(.{ .store_last_child = true, .store_prev_sibling = true });

    try std.testing.expect(@FieldType(CompactRaw, "last_child") == void);
    try std.testing.expect(@FieldType(CompactRaw, "prev_sibling") == void);
    try std.testing.expect(@FieldType(FullRaw, "last_child") == IndexInt);
    try std.testing.expect(@FieldType(FullRaw, "prev_sibling") == IndexInt);
}

test "document source type follows parse mode" {
    try std.testing.expect(@FieldType(GetDocument(.{}), "source") == []u8);
    try std.testing.expect(@FieldType(GetDocument(.{ .non_destructive = true }), "source") == []const u8);
}

/// Test helper that checks iterator results by `id` attribute sequence.
fn expectIterIds(iter: anytype, expected_ids: []const []const u8) !void {
    var mut_iter = iter;
    var i: usize = 0;
    while (mut_iter.next()) |node| {
        if (i >= expected_ids.len) return error.TestUnexpectedResult;
        const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[i], id.value);
        i += 1;
    }
    try std.testing.expectEqual(expected_ids.len, i);
}

/// Test helper that returns the first item from an iterator copy.
fn firstQuery(iter: anytype) @TypeOf(blk: {
    var it = iter;
    break :blk it.next();
}) {
    var it = iter;
    return it.next();
}

/// Test helper that compiles a runtime selector and returns its first match.
fn runtimeFirst(scope: anytype, allocator: std.mem.Allocator, selector: []const u8) !@TypeOf(firstQuery(scope.query("*"))) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
    return firstQuery(scope.queryRuntime(sel));
}

/// Test helper that compiles a runtime selector and returns a query iterator.
fn runtimeQuery(scope: anytype, allocator: std.mem.Allocator, selector: []const u8) !@TypeOf(scope.query("*")) {
    const sel = try ast.Selector.compileRuntime(allocator, selector);
    return scope.queryRuntime(sel);
}

/// Test helper that validates document-scoped comptime selector results.
fn expectDocQueryComptime(doc: *const GetDocument(.{}), comptime selector: []const u8, expected_ids: []const []const u8) !void {
    const it = doc.query(selector);
    try expectIterIds(it, expected_ids);

    const first = firstQuery(doc.query(selector));
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id.value);
    }
}

/// Test helper that validates document-scoped runtime selector results.
fn expectDocQueryRuntime(doc: *const GetDocument(.{}), selector: []const u8, expected_ids: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
    const it = doc.queryRuntime(sel);
    try expectIterIds(it, expected_ids);

    const first = firstQuery(doc.queryRuntime(sel));
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id.value);
    }
}

/// Test helper that validates node-scoped comptime selector results.
fn expectNodeQueryComptime(scope: GetNode(.{}), comptime selector: []const u8, expected_ids: []const []const u8) !void {
    const it = scope.query(selector);
    try expectIterIds(it, expected_ids);

    const first = firstQuery(scope.query(selector));
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id.value);
    }
}

/// Test helper that validates node-scoped runtime selector results.
fn expectNodeQueryRuntime(scope: GetNode(.{}), selector: []const u8, expected_ids: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
    const it = scope.queryRuntime(sel);
    try expectIterIds(it, expected_ids);

    const first = firstQuery(scope.queryRuntime(sel));
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id.value);
    }
}

/// Test helper that returns a parsed document through a move.
fn parseViaMove(alloc: std.mem.Allocator, input: []u8) !GetDocument(.{}) {
    var doc = GetDocument(.{}).init(alloc);
    try resetParsed(.{}, &doc, input);
    return doc;
}

const selector_fixture_html =
    "<html><body><div id='root'>" ++
    "<ul id='list'>" ++
    "<li id='li1' class='item a' data-k='v' data-prefix='prelude' data-suffix='trail-end' data-sub='in-middle' data-words='alpha beta gamma' lang='en-US'><span id='name1' class='name'>one</span></li>" ++
    "<li id='li2' class='item b' data-k='v2' data-prefix='presto' data-suffix='mid-end' data-sub='middle' data-words='beta delta' lang='en'><span id='name2' class='name'>two</span></li>" ++
    "<li id='li3' class='item c skip' data-k='x' data-prefix='nop' data-suffix='tail' data-sub='zzz' data-words='omega' lang='fr'><span id='name3' class='name'>three</span></li>" ++
    "</ul>" ++
    "<div id='sibs'>" ++
    "<a id='a1' class='link'></a>" ++
    "<a id='a2' class='link hot'></a>" ++
    "<span id='after_a2' class='marker'></span>" ++
    "<a id='a3' class='link'></a>" ++
    "</div>" ++
    "</div></body></html>";

test "document parse + query basics" {
    assertNodeTypeLayouts();

    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<html><head><title>A</title></head><body><div id='x' class='a b'>ok</div><p>n</p></body></html>".*;
    try resetParsed(.{}, &doc, &html);

    const one = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", one.tagName());

    var it = doc.query("body > *");
    try std.testing.expect(it.next() != null);
}

test "non-destructive parse preserves caller bytes and formats exact original source" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x' data-v='a&amp;b'> a &amp; b </div>".*;
    const before = html;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    const node = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    const attr_value = (try node.getAttributeValue(arena.allocator(), "data-v")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", attr_value.value);

    const text = try node.innerTextWithOptions(alloc, .{});
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("a & b", text.value);

    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);

    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(before[0..], rendered);
}

test "non-destructive attribute reads do not rewrite attribute bytes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b' data-q='1>2'></div>".*;
    const before = html;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const node = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    const value = (try node.getAttributeValue(arena.allocator(), "data-v")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", value.value);

    const attr_start: usize = @intCast(node.raw().name_or_text.end());
    const attr_end = std.mem.indexOfScalarPos(u8, doc.source, attr_start, '>') orelse doc.source.len;
    try std.testing.expect(std.mem.indexOf(u8, doc.source[attr_start..attr_end], "&amp;") != null);
    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);
}

test "attribute value results distinguish borrowed and allocated non-destructive reads" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' plain='abc' data-v='a&amp;b'></div>".*;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const plain = (try node.getAttributeValue(alloc, "plain")) orelse return error.TestUnexpectedResult;
    defer plain.free(&doc, alloc);
    try std.testing.expect(plain.isBorrowed(&doc));
    try std.testing.expectEqualStrings("abc", plain.value);

    const decoded = (try node.getAttributeValue(alloc, "data-v")) orelse return error.TestUnexpectedResult;
    defer decoded.free(&doc, alloc);
    try std.testing.expect(!decoded.isBorrowed(&doc));
    try std.testing.expectEqualStrings("a&b", decoded.value);
    try std.testing.expectEqualStrings("a&amp;b", node.getAttributeValueRaw("data-v") orelse return error.TestUnexpectedResult);
}

test "non-destructive attribute with undecodable ampersand does not allocate" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&bogus'></div>".*;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const value = (try node.getAttributeValue(failing.allocator(), "data-v")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value.isBorrowed(&doc));
    try std.testing.expectEqualStrings("a&bogus", value.value);
}

test "non-destructive decoded attribute frees temporary allocation on resize failure" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b'></div>".*;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    var failing = std.testing.FailingAllocator.init(alloc, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.OutOfMemory, node.getAttributeValue(failing.allocator(), "data-v"));
}

test "raw destructive attribute value reflects lazy decode mutation" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b'></div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&amp;b", node.getAttributeValueRaw("data-v") orelse return error.TestUnexpectedResult);

    const decoded = (try node.getAttributeValue(alloc, "data-v")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", decoded.value);
    try std.testing.expectEqualStrings("a&b", node.getAttributeValueRaw("data-v") orelse return error.TestUnexpectedResult);
}

test "non-destructive text reads do not rewrite text bytes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<p id='x'> a &amp;  b </p>".*;
    const before = html;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    const node = firstQuery(doc.query("p#x")) orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(alloc, .{});
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("a & b", text.value);

    const text_node = doc.nodes[node.index + 1];
    try std.testing.expectEqualStrings("a &amp;  b ", text_node.name_or_text.slice(doc.source));
    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);
}

test "non-destructive innerText ignores oversized malformed entity prefixes safely" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>&xxxxxxxxxxxxxxxxxxxx&amp;</div>".*;
    const before = html;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(alloc, .{});
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("&xxxxxxxxxxxxxxxxxxxx&", text.value);
    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);
}

test "runtime query iterator is stable across runtime query calls" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='x'></span></div>".*;
    try resetParsed(.{}, &doc, &html);

    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();
    var it = try runtimeQuery(&doc, runtime_arena.allocator(), "span.x");

    // This uses a different arena and must not invalidate `it`.
    _ = try runtimeFirst(&doc, alloc, "div");

    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime query iterators compiled from runtime selectors remain independent" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='y'></span></div>".*;
    try resetParsed(.{}, &doc, &html);

    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();
    var old_it = try runtimeQuery(&doc, runtime_arena.allocator(), "span.x");
    var new_it = try runtimeQuery(&doc, runtime_arena.allocator(), "span.y");

    try std.testing.expect(old_it.next() != null);
    try std.testing.expect(old_it.next() == null);
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "runtime query iterator is invalidated by clear and reparsing" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html_a = "<div><span class='x'></span></div>".*;
    try resetParsed(.{}, &doc, &html_a);

    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();
    var old_it = try runtimeQuery(&doc, runtime_arena.allocator(), "span.x");
    doc.clear();
    try std.testing.expect(old_it.next() == null);
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.len);

    var html_b = "<div><span class='y'></span></div>".*;
    try resetParsed(.{}, &doc, &html_b);
    try std.testing.expect(old_it.next() == null);

    var new_it = try runtimeQuery(&doc, runtime_arena.allocator(), "span.y");
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "matcher firstMatchIndex rejects invalid scope roots safely" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x'></div>".*;
    try resetParsed(.{}, &doc, &html);

    const sel = comptime ast.Selector.compile("div");
    const idx = matcher.firstMatchIndex(GetDocument(.{}), &doc, sel, @as(IndexInt, @intCast(doc.nodes.len + 10)));
    try std.testing.expect(idx == null);
}

test "query results matrix (comptime selectors)" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try resetParsed(.{}, &doc, &html);

    try expectDocQueryComptime(&doc, "li", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "#li2", &.{"li2"});
    try expectDocQueryComptime(&doc, ".item", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "li, .item", &.{ "li1", "li2", "li3" });

    try expectDocQueryComptime(&doc, "[data-k]", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "[data-k=v]", &.{"li1"});
    try expectDocQueryComptime(&doc, "[data-prefix^=pre]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[data-suffix$=end]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[data-sub*=middle]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[data-words~=beta]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[lang|=en]", &.{ "li1", "li2" });

    try expectDocQueryComptime(&doc, "ul > li", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "ul li > span.name", &.{ "name1", "name2", "name3" });
    try expectDocQueryComptime(&doc, "li + li", &.{ "li2", "li3" });
    try expectDocQueryComptime(&doc, "li ~ li", &.{ "li2", "li3" });
    try expectDocQueryComptime(&doc, "a.link + span.marker", &.{"after_a2"});
    try expectDocQueryComptime(&doc, "a.hot ~ a.link", &.{"a3"});

    try expectDocQueryComptime(&doc, "li:first-child", &.{"li1"});
    try expectDocQueryComptime(&doc, "li:last-child", &.{"li3"});
    try expectDocQueryComptime(&doc, "li:nth-child(2)", &.{"li2"});
    try expectDocQueryComptime(&doc, "li:nth-child(2n+1)", &.{ "li1", "li3" });
    try expectDocQueryComptime(&doc, "li:not(.skip)", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "li:not([data-k=x])", &.{ "li1", "li2" });

    try expectDocQueryComptime(&doc, "li#li1, li#li3", &.{ "li1", "li3" });
    try expectDocQueryComptime(&doc, ".does-not-exist", &.{});
}

test "query results matrix (runtime selectors)" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try resetParsed(.{}, &doc, &html);

    try expectDocQueryRuntime(&doc, "li", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "#li2", &.{"li2"});
    try expectDocQueryRuntime(&doc, ".item", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "li, .item", &.{ "li1", "li2", "li3" });

    try expectDocQueryRuntime(&doc, "[data-k]", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "[data-k=v]", &.{"li1"});
    try expectDocQueryRuntime(&doc, "[data-prefix^=pre]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[data-suffix$=end]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[data-sub*=middle]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[data-words~=beta]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[lang|=en]", &.{ "li1", "li2" });

    try expectDocQueryRuntime(&doc, "ul > li", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "ul li > span.name", &.{ "name1", "name2", "name3" });
    try expectDocQueryRuntime(&doc, "li + li", &.{ "li2", "li3" });
    try expectDocQueryRuntime(&doc, "li ~ li", &.{ "li2", "li3" });
    try expectDocQueryRuntime(&doc, "a.link + span.marker", &.{"after_a2"});
    try expectDocQueryRuntime(&doc, "a.hot ~ a.link", &.{"a3"});

    try expectDocQueryRuntime(&doc, "li:first-child", &.{"li1"});
    try expectDocQueryRuntime(&doc, "li:last-child", &.{"li3"});
    try expectDocQueryRuntime(&doc, "li:nth-child(2)", &.{"li2"});
    try expectDocQueryRuntime(&doc, "li:nth-child(2n+1)", &.{ "li1", "li3" });
    try expectDocQueryRuntime(&doc, "li:not(.skip)", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "li:not([data-k=x])", &.{ "li1", "li2" });

    try expectDocQueryRuntime(&doc, "li#li1, li#li3", &.{ "li1", "li3" });
    try expectDocQueryRuntime(&doc, ".does-not-exist", &.{});
}

test "node-scoped queries return complete descendants only" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try resetParsed(.{}, &doc, &html);

    const list = firstQuery(doc.query("#list")) orelse return error.TestUnexpectedResult;
    try expectNodeQueryComptime(list, "li", &.{ "li1", "li2", "li3" });
    try expectNodeQueryComptime(list, "span.name", &.{ "name1", "name2", "name3" });
    try expectNodeQueryRuntime(list, "li:not(.skip)", &.{ "li1", "li2" });

    const sibs = firstQuery(doc.query("#sibs")) orelse return error.TestUnexpectedResult;
    try expectNodeQueryComptime(sibs, "a.link", &.{ "a1", "a2", "a3" });
    try expectNodeQueryRuntime(sibs, "a + span.marker", &.{"after_a2"});
    try expectNodeQueryRuntime(sibs, "li", &.{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "a.link");
    const it = sibs.queryRuntime(sel);
    try expectIterIds(it, &.{ "a1", "a2", "a3" });
    const first = firstQuery(sibs.queryRuntime(sel)) orelse return error.TestUnexpectedResult;
    const id = (try first.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", id.value);
}

test "innerText normalizes whitespace by default" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha \n\t beta   gamma  </div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(alloc, .{});
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("alpha beta gamma", text.value);
}

test "innerText can return non-normalized text" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha \n\t beta   gamma  </div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("alpha \n\t beta   gamma  ", text.value);
}

test "innerText normalization is applied across text-node boundaries" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>A <b></b>   B</div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(alloc, .{});
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("A B", text.value);
}

test "innerText inserts separator between text-node slices without trailing whitespace" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x'>A<b></b>B</div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer text.free(&doc, alloc);
    try std.testing.expectEqualStrings("A B", text.value);
}

test "parse-time text whitespace trimming is on by default and query-time normalization still works" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha  &amp;   beta  </div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text_node = doc.nodes[node.index + 1];
    try std.testing.expect(text_node.isText(@intCast(node.index + 1)));
    try std.testing.expectEqualStrings("alpha  &amp;   beta  ", text_node.name_or_text.slice(doc.source));

    const escaped = try node.innerTextWithOptions(alloc, .{ .normalize_whitespace = false, .unescape = false });
    defer escaped.free(&doc, alloc);
    try std.testing.expectEqualStrings("alpha  &amp;   beta  ", escaped.value);

    const raw = try node.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer raw.free(&doc, alloc);
    try std.testing.expectEqualStrings("alpha  &   beta  ", raw.value);

    const normalized = try node.innerTextWithOptions(alloc, .{});
    defer normalized.free(&doc, alloc);
    try std.testing.expectEqualStrings("alpha & beta", normalized.value);

    var escaped_doc = GetDocument(.{}).init(alloc);
    defer escaped_doc.deinit();
    var escaped_html = "<div id='x'>  alpha  &amp;   beta  </div>".*;
    try resetParsed(.{}, &escaped_doc, &escaped_html);
    const escaped_node = firstQuery(escaped_doc.query("#x")) orelse return error.TestUnexpectedResult;
    const escaped_normalized = try escaped_node.innerTextWithOptions(alloc, .{ .unescape = false });
    defer escaped_normalized.free(&escaped_doc, alloc);
    try std.testing.expectEqualStrings("alpha &amp; beta", escaped_normalized.value);
}

test "parse-time attribute decoding is off by default and query-time lookup decodes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b'></div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = doc.findFirstTag("div") orelse return error.TestUnexpectedResult;
    const attr_start: usize = node.raw().name_or_text.end();
    const attr_end = std.mem.indexOfScalarPos(u8, doc.source, attr_start, '>') orelse doc.source.len;
    const span = doc.source[attr_start..attr_end];
    try std.testing.expect(std.mem.indexOf(u8, span, "&amp;") != null);

    const value = (try node.getAttributeValue(alloc, "data-v")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", value.value);
}

test "isOwned distinguishes borrowed single-text and allocated multi-text innerText" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>single</div><div id='y'>a<b></b>b</div>".*;
    try resetParsed(.{}, &doc, &html);

    const x = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const y = firstQuery(doc.query("#y")) orelse return error.TestUnexpectedResult;

    const x_text = try x.innerTextWithOptions(alloc, .{});
    defer x_text.free(&doc, alloc);
    try std.testing.expectEqualStrings("single", x_text.value);
    try std.testing.expect(x_text.isBorrowed(&doc));

    const y_text = try y.innerTextWithOptions(alloc, .{});
    defer y_text.free(&doc, alloc);
    try std.testing.expectEqualStrings("a b", y_text.value);
    try std.testing.expect(!y_text.isBorrowed(&doc));
}

test "innerTextOwned always returns allocated output and does not mutate source text bytes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>a &amp; b</div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const text_node_before = doc.nodes[node.index + 1];
    try std.testing.expect(text_node_before.isText(@intCast(node.index + 1)));
    try std.testing.expectEqualStrings("a &amp; b", text_node_before.name_or_text.slice(doc.source));

    const owned = try node.innerTextOwnedWithOptions(alloc, .{});
    defer alloc.free(owned);
    try std.testing.expectEqualStrings("a & b", owned);
    try std.testing.expect(!doc.isOwnedSlice(owned));

    const text_node_after = doc.nodes[node.index + 1];
    try std.testing.expectEqualStrings("a &amp; b", text_node_after.name_or_text.slice(doc.source));
}

test "inplace attribute parser treats explicit empty assignment as name-only" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' b a=   ></div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const a = (try node.getAttributeValue(alloc, "a")) orelse return error.TestUnexpectedResult;
    const b = (try node.getAttributeValue(alloc, "b")) orelse return error.TestUnexpectedResult;
    const c = try node.getAttributeValue(alloc, "c");
    try std.testing.expectEqual(@as(usize, 0), a.value.len);
    try std.testing.expectEqual(@as(usize, 0), b.value.len);
    try std.testing.expect(c == null);

    try std.testing.expect(firstQuery(doc.query("div[a]")) != null);
    try std.testing.expect(firstQuery(doc.query("div[b]")) != null);
    try std.testing.expect(firstQuery(doc.query("div[c]")) == null);
}

test "inplace attr lazy parse updates state markers and supports selector-triggered parsing" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' q='&amp;z' n=a&amp;b></div>".*;
    try resetParsed(.{}, &doc, &html);

    const by_selector = try runtimeFirst(&doc, alloc, "div[q='&z'][n='a&b']");
    try std.testing.expect(by_selector != null);

    const node = by_selector orelse return error.TestUnexpectedResult;
    const q = (try node.getAttributeValue(alloc, "q")) orelse return error.TestUnexpectedResult;
    const n = (try node.getAttributeValue(alloc, "n")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("&z", q.value);
    try std.testing.expectEqualStrings("a&b", n.value);

    const attr_start: usize = node.raw().name_or_text.end();
    const attr_end = std.mem.indexOfScalarPos(u8, doc.source, attr_start, '>') orelse doc.source.len;
    const span = doc.source[attr_start..attr_end];
    const q_marker = [_]u8{ 'q', 0, 0 };
    const q_pos = std.mem.indexOf(u8, span, &q_marker) orelse return error.TestUnexpectedResult;
    try std.testing.expect(q_pos < span.len);

    const n_marker = [_]u8{ 'n', 0 };
    const n_pos = std.mem.indexOf(u8, span, &n_marker) orelse return error.TestUnexpectedResult;
    try std.testing.expect(n_pos + 2 <= span.len);
    try std.testing.expect(span[n_pos + 1] == 0);
    try std.testing.expect(span[n_pos + 2] != 0);
}

test "attribute matching short-circuits and does not parse later attrs on early failure" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' href='/local' class='button'></div>".*;
    try resetParsed(.{}, &doc, &html);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "div[href^=https][class*=button]");
    try std.testing.expect(firstQuery(doc.queryRuntime(sel)) == null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "div[href^=https][class*=button]")) == null);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const attr_start: usize = node.raw().name_or_text.end();
    const attr_end = std.mem.indexOfScalarPos(u8, doc.source, attr_start, '>') orelse doc.source.len;
    const span = doc.source[attr_start..attr_end];
    const class_pos = std.mem.indexOf(u8, span, "class") orelse return error.TestUnexpectedResult;
    const marker_pos = class_pos + "class".len;
    try std.testing.expect(marker_pos < span.len);
    try std.testing.expectEqual(@as(u8, '='), span[marker_pos]);
}

test "inplace extended skip metadata preserves traversal for following attributes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(alloc);
    const prefix = "<div id='x' a='";
    const entity = "&amp;";
    const suffix = "' b='ok'></div>";
    try builder.ensureTotalCapacity(alloc, prefix.len + (320 * entity.len) + suffix.len);
    builder.appendSliceAssumeCapacity(prefix);
    var i: usize = 0;
    while (i < 320) : (i += 1) {
        builder.appendSliceAssumeCapacity(entity);
    }
    builder.appendSliceAssumeCapacity(suffix);

    const html = try builder.toOwnedSlice(alloc);
    defer alloc.free(html);

    try resetParsed(.{}, &doc, html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const a = (try node.getAttributeValue(alloc, "a")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 320), a.value.len);
    for (a.value) |c| try std.testing.expect(c == '&');

    const b = (try node.getAttributeValue(alloc, "b")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ok", b.value);
}

test "cached selector APIs are equivalent to runtime string wrappers" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try resetParsed(.{}, &doc, &html);

    const cases = [_]struct { selector: []const u8, expected: []const []const u8 }{
        .{ .selector = "li", .expected = &.{ "li1", "li2", "li3" } },
        .{ .selector = "[data-k=v]", .expected = &.{"li1"} },
        .{ .selector = "[data-prefix^=pre]", .expected = &.{ "li1", "li2" } },
        .{ .selector = "li:not([data-k=x])", .expected = &.{ "li1", "li2" } },
        .{ .selector = "ul li > span.name", .expected = &.{ "name1", "name2", "name3" } },
        .{ .selector = "a.hot ~ a.link", .expected = &.{"a3"} },
        .{ .selector = "a[href^=https][class*=button]:not(.missing)", .expected = &.{} },
        .{ .selector = "a[href^=https][class*=nav]:not(.missing)", .expected = &.{} },
    };

    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const sel = try ast.Selector.compileRuntime(arena.allocator(), case.selector);
        try expectDocQueryRuntime(&doc, case.selector, case.expected);

        const it = doc.queryRuntime(sel);
        try expectIterIds(it, case.expected);
        const first = firstQuery(doc.queryRuntime(sel));
        if (case.expected.len == 0) {
            try std.testing.expect(first == null);
        } else {
            const node = first orelse return error.TestUnexpectedResult;
            const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(case.expected[0], id.value);
        }
    }
}

test "runtime query parsing remains correct across parse and clear" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html_a = "<div class='x'></div>".*;
    try resetParsed(.{}, &doc, &html_a);

    try std.testing.expect((try runtimeFirst(&doc, alloc, "div.x")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "div.x")) != null);

    var html_b = "<section class='x'></section>".*;
    try resetParsed(.{}, &doc, &html_b);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "div.x")) == null);

    doc.clear();
    var html_c = "<div class='x'></div>".*;
    try resetParsed(.{}, &doc, &html_c);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "div.x")) != null);
}

test "attr fast-path names are equivalent to generic lookup semantics" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<a id='x' class='btn primary' href='https://example.com' data-k='v'></a>".*;
    try resetParsed(.{}, &doc, &html);

    const a = firstQuery(doc.query("a")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", (try a.getAttributeValue(std.testing.allocator, "id")).?.value);
    try std.testing.expectEqualStrings("btn primary", (try a.getAttributeValue(alloc, "class")).?.value);
    try std.testing.expectEqualStrings("https://example.com", (try a.getAttributeValue(alloc, "href")).?.value);
    try std.testing.expectEqualStrings("v", (try a.getAttributeValue(alloc, "data-k")).?.value);

    try std.testing.expect(try a.getAttributeValue(alloc, "missing") == null);
}

test "mixed-case tags and attrs are queryable via lowercase selectors" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<DiV ID='x' ClAsS='A b' DaTa-K='v'><SpAn id='y'></SpAn></DiV>".*;
    try resetParsed(.{}, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("div#x[data-k=v]")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "div > span#y")) != null);

    const div = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A b", (try div.getAttributeValue(alloc, "class")).?.value);
}

test "attribute selectors support case-sensitivity flags" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<a id='a' data-k='Hello-World' rel='Tag BLUE'></a><a id='b' data-k='hello-world' rel='tag blue'></a>".*;
    try resetParsed(.{}, &doc, &html);

    try expectDocQueryComptime(&doc, "a[data-k=hello-world]", &.{"b"});
    try expectDocQueryComptime(&doc, "a[data-k=hello-world i]", &.{ "a", "b" });
    try expectDocQueryComptime(&doc, "a[data-k=hello-world s]", &.{"b"});
    try expectDocQueryComptime(&doc, "a[data-k^=hello i][data-k$=WORLD i][data-k*=LO-WO i]", &.{ "a", "b" });
    try expectDocQueryComptime(&doc, "a[rel~=blue i]", &.{ "a", "b" });
    try expectDocQueryComptime(&doc, "a[rel~=blue s]", &.{"b"});
    try expectDocQueryRuntime(&doc, "a[data-k|=HELLO i]", &.{ "a", "b" });
    try expectDocQueryRuntime(&doc, "a:not([data-k=hello-world i])", &.{});
}

test "multiple class predicates in one compound match correctly" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' class='alpha beta gamma'></div><div id='y' class='alpha beta'></div>".*;
    try resetParsed(.{}, &doc, &html);

    try expectDocQueryComptime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.delta", &.{});
}

test "class token matching treats all ascii whitespace as separators" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='t' class='a\tb\nc\rd\x0ce'></div>".*;
    try resetParsed(.{}, &doc, &html);

    try std.testing.expect(firstQuery(doc.query("#t.a")) != null);
    try std.testing.expect(firstQuery(doc.query("#t.b")) != null);
    try std.testing.expect(firstQuery(doc.query("#t.c")) != null);
    try std.testing.expect(firstQuery(doc.query("#t.d")) != null);
    try std.testing.expect(firstQuery(doc.query("#t.e")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "#t[class~=d]")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "#t[class~=e]")) != null);
}

test "scoped query with duplicate ids respects scope and extra predicates" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='outside'><span id='dup' class='x'></span></div><div id='scope'><span id='dup' class='y'></span></div>".*;
    try resetParsed(.{}, &doc, &html);

    const scope = firstQuery(doc.query("#scope")) orelse return error.TestUnexpectedResult;
    const found_ct = firstQuery(scope.query("#dup.y")) orelse return error.TestUnexpectedResult;
    const found_rt = (try runtimeFirst(scope, alloc, "#dup.y")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(found_ct.index, found_rt.index);
    const parent = found_ct.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("scope", (try parent.getAttributeValue(std.testing.allocator, "id")).?.value);
}

test "runtime selector rejects multiple ids in one compound" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div id='a'></div>".*;
    try resetParsed(.{}, &doc, &html);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidSelector, ast.Selector.compileRuntime(arena.allocator(), "#a#a"));
}

test "runtime selector supports nth-child shorthand variants" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();

    var html = "<div id='pseudos'><div></div><div></div><div></div><div></div><a></a><div></div><div></div></div>".*;
    try resetParsed(.{}, &doc, &html);

    const comptime_one = firstQuery(doc.query("#pseudos :nth-child(odd)"));
    const runtime_one = try runtimeFirst(&doc, alloc, "#pseudos :nth-child(odd)");
    try std.testing.expect((comptime_one == null) == (runtime_one == null));
    if (comptime_one) |a| {
        try std.testing.expectEqual(a.index, runtime_one.?.index);
    }

    var c_odd: usize = 0;
    var it_odd = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(odd)");
    while (it_odd.next()) |_| c_odd += 1;
    try std.testing.expectEqual(@as(usize, 4), c_odd);

    var c_plus: usize = 0;
    var it_plus = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(3n+1)");
    while (it_plus.next()) |_| c_plus += 1;
    try std.testing.expectEqual(@as(usize, 3), c_plus);

    var c_signed: usize = 0;
    var it_signed = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(+3n-2)");
    while (it_signed.next()) |_| c_signed += 1;
    try std.testing.expectEqual(@as(usize, 3), c_signed);

    var c_neg_a: usize = 0;
    var it_neg_a = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(-n+6)");
    while (it_neg_a.next()) |_| c_neg_a += 1;
    try std.testing.expectEqual(@as(usize, 6), c_neg_a);

    var c_neg_b: usize = 0;
    var it_neg_b = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(-n+5)");
    while (it_neg_b.next()) |_| c_neg_b += 1;
    try std.testing.expectEqual(@as(usize, 5), c_neg_b);
}

test "leading child combinator works in node-scoped queries" {
    const alloc = std.testing.allocator;
    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();

    var frag_doc = GetDocument(.{}).init(alloc);
    defer frag_doc.deinit();
    var frag_html =
        "<root><div class='d i v'><p id='oooo'><em></em><em id='emem'></em></p></div><p id='sep'><div class='a'><span></span></div></p></root>".*;
    try resetParsed(.{}, &frag_doc, &frag_html);
    const frag_root = firstQuery(frag_doc.query("root")) orelse return error.TestUnexpectedResult;

    var it_em = try runtimeQuery(frag_root, runtime_arena.allocator(), "> div p em");
    var em_count: usize = 0;
    while (it_em.next()) |_| em_count += 1;
    try std.testing.expectEqual(@as(usize, 2), em_count);

    var it_oooo = try runtimeQuery(frag_root, runtime_arena.allocator(), "> div #oooo");
    var oooo_count: usize = 0;
    while (it_oooo.next()) |_| oooo_count += 1;
    try std.testing.expectEqual(@as(usize, 1), oooo_count);

    var doc_ctx = GetDocument(.{}).init(alloc);
    defer doc_ctx.deinit();
    var doc_html =
        "<root><div id='hsoob'><div class='a b'><div class='d e sib' id='booshTest'><p><span id='spanny'></span></p></div><em class='sib'></em><span class='h i a sib'></span></div><p class='odd'></p></div><div id='lonelyHsoob'></div></root>".*;
    try resetParsed(.{}, &doc_ctx, &doc_html);
    const ctx_root = firstQuery(doc_ctx.query("root")) orelse return error.TestUnexpectedResult;

    var it_hsoob = try runtimeQuery(ctx_root, runtime_arena.allocator(), "> #hsoob");
    var hsoob_count: usize = 0;
    while (it_hsoob.next()) |_| hsoob_count += 1;
    try std.testing.expectEqual(@as(usize, 1), hsoob_count);
}

test "parse option bundles preserve selector/query behavior for representative input" {
    const alloc = std.testing.allocator;

    var strict_doc = GetDocument(.{ .drop_whitespace_text_nodes = .none }).init(alloc);
    defer strict_doc.deinit();
    var fast_doc = GetDocument(.{}).init(alloc);
    defer fast_doc.deinit();

    var strict_html = ("<html><body>" ++
        "<div id='x' class='alpha beta' data-k='v' data-q='1>2'>x</div>" ++
        "<img id='im' src='a.png' />" ++
        "<a id='a1' href='https://example.com' class='nav button'>ok</a>" ++
        "<p id='p1'>a<span id='s1'>b</span></p>" ++
        "<div id='e' a= ></div>" ++
        "</body></html>").*;
    var fast_html = strict_html;

    try resetParsed(.{ .drop_whitespace_text_nodes = .none }, &strict_doc, &strict_html);
    try resetParsed(.{}, &fast_doc, &fast_html);

    const selectors = [_][]const u8{
        "div#x[data-k=v]",
        "img#im",
        "a[href^=https][class*=button]:not(.missing)",
        "p#p1 > span#s1",
        "div[a]",
    };

    for (selectors) |sel| {
        const a = try runtimeFirst(&strict_doc, alloc, sel);
        const b = try runtimeFirst(&fast_doc, alloc, sel);
        try std.testing.expect((a == null) == (b == null));
    }

    const strict_empty = (try (firstQuery(strict_doc.query("#e")) orelse return error.TestUnexpectedResult).getAttributeValue(alloc, "a")) orelse return error.TestUnexpectedResult;
    const fast_empty = (try (firstQuery(fast_doc.query("#e")) orelse return error.TestUnexpectedResult).getAttributeValue(alloc, "a")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(strict_empty.value, fast_empty.value);
}

test "children() iterator traverses sibling-chain nodes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span></div>".*;
    try resetParsed(.{}, &doc, &html);

    const root = firstQuery(doc.query("div#root")) orelse return error.TestUnexpectedResult;
    var kids = root.children();
    const nodes = try kids.collect(alloc);
    defer alloc.free(nodes);
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("a", (try nodes[0].getAttributeValue(std.testing.allocator, "id")).?.value);
    try std.testing.expectEqualStrings("b", (try nodes[1].getAttributeValue(std.testing.allocator, "id")).?.value);

    var again = root.children();
    const nodes_again = try again.collect(alloc);
    defer alloc.free(nodes_again);
    try std.testing.expectEqual(@as(usize, 2), nodes_again.len);
}

test "children() collect respects iterator progress" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span><span id='c'></span></div>".*;
    try resetParsed(.{}, &doc, &html);

    const root = firstQuery(doc.query("div#root")) orelse return error.TestUnexpectedResult;
    var kids = root.children();
    const first = kids.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", (try first.getAttributeValue(std.testing.allocator, "id")).?.value);

    const rest = try kids.collect(alloc);
    defer alloc.free(rest);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("b", (try rest[0].getAttributeValue(std.testing.allocator, "id")).?.value);
    try std.testing.expectEqualStrings("c", (try rest[1].getAttributeValue(std.testing.allocator, "id")).?.value);
}

test "children() iterator next uses element links across text nodes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .drop_whitespace_text_nodes = .none }).init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span> text <span id='b'></span><em id='c'></em></div>".*;
    try resetParsed(.{ .drop_whitespace_text_nodes = .none }, &doc, &html);

    const root = firstQuery(doc.query("div#root")) orelse return error.TestUnexpectedResult;
    var kids = root.children();

    const a = kids.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", (try a.getAttributeValue(alloc, "id")).?.value);

    const b = kids.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", (try b.getAttributeValue(alloc, "id")).?.value);
    try std.testing.expectEqual(a.index, (b.prevSibling() orelse return error.TestUnexpectedResult).index);

    const rest = try kids.collect(alloc);
    defer alloc.free(rest);
    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("c", (try rest[0].getAttributeValue(alloc, "id")).?.value);
}

test "optional last_child enables children last without changing iteration" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .store_last_child = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span> text <span id='b'></span><em id='c'></em></div>".*;
    try resetParsed(.{ .store_last_child = true }, &doc, &html);

    const root = firstQuery(doc.query("div#root")) orelse return error.TestUnexpectedResult;
    const last = root.children().last() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c", (try last.getAttributeValue(alloc, "id")).?.value);
    try std.testing.expectEqual(last.index, doc.nodes[root.index].last_child);
}

test "disabled prev_sibling keeps navigation and sibling selectors correct" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .store_prev_sibling = false }).init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span> text <span id='b'></span><em id='c'></em></div>".*;
    try resetParsed(.{ .store_prev_sibling = false }, &doc, &html);

    const b = firstQuery(doc.query("span#b")) orelse return error.TestUnexpectedResult;
    const a = b.prevSibling() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", (try a.getAttributeValue(alloc, "id")).?.value);

    const adjacent = firstQuery(doc.query("span#b + em")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c", (try adjacent.getAttributeValue(alloc, "id")).?.value);

    const nth = firstQuery(doc.query("em:nth-child(3)")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c", (try nth.getAttributeValue(alloc, "id")).?.value);
}

test "unquoted attribute values preserve slash characters" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<a id=x href=/docs/v1/api data-path=assets/img/logo.svg></a>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("a#x")) orelse return error.TestUnexpectedResult;
    const href = (try node.getAttributeValue(alloc, "href")) orelse return error.TestUnexpectedResult;
    const data_path = (try node.getAttributeValue(alloc, "data-path")) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("/docs/v1/api", href.value);
    try std.testing.expectEqualStrings("assets/img/logo.svg", data_path.value);
    try std.testing.expect(firstQuery(doc.query("a[href='/docs/v1/api'][data-path='assets/img/logo.svg']")) != null);
}

test "moved document keeps node-scoped queries and navigation valid" {
    const alloc = std.testing.allocator;
    var html = "<root><div id='a'><span id='b'></span></div></root>".*;
    var doc = try parseViaMove(alloc, &html);
    defer doc.deinit();

    const a = firstQuery(doc.query("#a")) orelse return error.TestUnexpectedResult;
    const b = firstQuery(a.query("span#b")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("span", b.tagName());
    try std.testing.expectEqual(@as(IndexInt, a.index), b.parentNode().?.index);
}

test "clear resets parsed state and ownership tracking" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html_a = "<div><a id='x'></a><a id='y'></a></div>".*;
    try resetParsed(.{}, &doc, &html_a);

    var html_b = "<main><p id='z'>owned</p></main>".*;
    try resetParsed(.{}, &doc, &html_b);
    try std.testing.expect(firstQuery(doc.query("main")) != null);
    try std.testing.expect(firstQuery(doc.query("#x")) == null);

    const text_before_clear = (firstQuery(doc.query("#z")) orelse return error.TestUnexpectedResult)
        .innerTextWithOptions(alloc, .{ .normalize_whitespace = false }) catch return error.TestUnexpectedResult;
    try std.testing.expect(text_before_clear.isBorrowed(&doc));

    doc.clear();
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), doc.source.len);
    try std.testing.expect(!doc.isOwnedSlice(text_before_clear.value));
}

test "writeHtml handles deep documents without recursive calls" {
    const alloc = std.testing.allocator;
    const depth = 4096;

    var input_builder: std.Io.Writer.Allocating = .init(alloc);
    defer input_builder.deinit();
    for (0..depth) |_| try input_builder.writer.writeAll("<div>");
    for (0..depth) |_| try input_builder.writer.writeAll("</div>");

    const input = try input_builder.toOwnedSlice();
    defer alloc.free(input);

    const opts: ParseOptions = .{};
    var doc = try opts.parse(alloc, input);
    defer doc.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try doc.writeHtml(&out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "runtime attr-heavy selector stress uses in-node parents" {
    const alloc = std.testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    const prefix = "<html><body><div id='root'>";
    const suffix = "</div></body></html>";
    try builder.writer.writeAll(prefix);
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        if ((i % 4) == 0) {
            try builder.writer.print("<a id='a{d}' href='https://example/{d}' class='nav button'>x</a>", .{ i, i });
        } else {
            try builder.writer.print("<a id='a{d}' href='/local/{d}' class='nav link'>x</a>", .{ i, i });
        }
    }
    try builder.writer.writeAll(suffix);

    const html = try builder.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    const selector = "a[href^=https][class*=button]:not(.missing)";
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const compiled = try ast.Selector.compileRuntime(arena.allocator(), selector);
    var loops: usize = 0;
    while (loops < 256) : (loops += 1) {
        const a = try runtimeFirst(&doc, alloc, selector);
        const b = firstQuery(doc.queryRuntime(compiled));
        try std.testing.expect((a == null) == (b == null));
    }
    try std.testing.expectEqual(0, doc.nodes[1].parent);
}

test "bench fixture attr-heavy runtime and cached query smoke" {
    const alloc = std.testing.allocator;
    const fixture_path = "bench/fixtures/rust-lang.html";
    const fixture = std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer alloc.free(fixture);

    const selector = "a[href^=https][class*=button]:not(.missing)";

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const compiled = try ast.Selector.compileRuntime(arena.allocator(), selector);
    {
        const html = try alloc.dupe(u8, fixture);
        defer alloc.free(html);

        var doc = GetDocument(.{}).init(alloc);
        defer doc.deinit();
        try resetParsed(.{}, &doc, html);

        var loops: usize = 0;
        while (loops < 32) : (loops += 1) {
            const a = try runtimeFirst(&doc, alloc, selector);
            const b = firstQuery(doc.queryRuntime(compiled));
            try std.testing.expect((a == null) == (b == null));
        }
        try std.testing.expectEqual(0, doc.nodes[1].parent);
    }

    {
        const html = try alloc.dupe(u8, fixture);
        defer alloc.free(html);

        var doc = GetDocument(.{}).init(alloc);
        defer doc.deinit();
        try resetParsed(.{}, &doc, html);

        var loops: usize = 0;
        while (loops < 32) : (loops += 1) {
            const a = try runtimeFirst(&doc, alloc, selector);
            const b = firstQuery(doc.queryRuntime(compiled));
            try std.testing.expect((a == null) == (b == null));
        }
        try std.testing.expectEqual(0, doc.nodes[1].parent);
    }
}

test "runtime selector debug reports runtime selector parse errors" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x'></div>".*;
    try resetParsed(.{}, &doc, &html);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var report: selector_debug.QueryDebugReport = .{};
    report.reset("div[", InvalidIndex, 0);
    _ = ast.Selector.compileRuntime(arena.allocator(), "div[") catch |err| {
        report.setRuntimeParseError();
        const result: GetQueryDebugResult(.{}) = .{ .report = report, .err = err };
        try std.testing.expectEqual(@as(?runtime_selector.Error, error.InvalidSelector), result.err);
        try std.testing.expect(result.report.runtime_parse_error);
        try std.testing.expectEqualStrings("div[", result.report.selector_source);
        return;
    };
    return error.TestUnexpectedResult;
}

test "query debug reports near misses and matched index" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div><a id='x' class='k'></a><a id='y'></a></div>".*;
    try resetParsed(.{}, &doc, &html);

    const miss = doc.debugFirstMatchFrom(comptime ast.Selector.compile("a[href^=https]"), InvalidIndex);
    try std.testing.expect(miss.err == null);
    try std.testing.expect(miss.node == null);
    try std.testing.expect(miss.report.visited_elements > 0);
    try std.testing.expect(miss.report.near_miss_len > 0);
    try std.testing.expect(miss.report.near_misses[0].reason.kind != .none);

    const hit = doc.debugFirstMatchFrom(comptime ast.Selector.compile("a#x"), InvalidIndex);
    const hit_node = hit.node orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(hit_node.index, hit.report.matched_index);
    try std.testing.expectEqual(@as(u16, 0), hit.report.matched_group);
}

test "node-scoped runtime debug query reports scope/combinator failures" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<root><div><span id='inside'></span></div><span id='outside'></span></root>".*;
    try resetParsed(.{}, &doc, &html);

    const root = firstQuery(doc.query("root")) orelse return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "> span#inside");
    const found = doc.debugFirstMatchFrom(sel, root.index);
    try std.testing.expect(found.err == null);
    try std.testing.expect(found.node == null);
    try std.testing.expect(found.report.scope_root == root.index);
    try std.testing.expect(found.report.near_miss_len > 0);
    try std.testing.expect(found.report.near_misses[0].reason.kind != .none);
}

const HookProbe = struct {
    parse_start_calls: usize = 0,
    parse_end_calls: usize = 0,
    query_start_calls: usize = 0,
    query_end_calls: usize = 0,
    last_input_len: usize = 0,
    last_query_kind: instrumentation.QueryInstrumentationKind = .query,
    last_selector_len: usize = 0,
    last_parse_stats: instrumentation.ParseInstrumentationStats = .{
        .elapsed_ns = 0,
        .input_len = 0,
        .node_count = 0,
    },
    last_query_stats: instrumentation.QueryInstrumentationStats = .{
        .elapsed_ns = 0,
        .selector_len = 0,
        .kind = .query,
        .matched = null,
    },

    /// Test hook callback for parse start.
    pub fn onParseStart(self: *@This(), input_len: usize) void {
        self.parse_start_calls += 1;
        self.last_input_len = input_len;
    }

    /// Test hook callback for parse completion.
    pub fn onParseEnd(self: *@This(), stats: instrumentation.ParseInstrumentationStats) void {
        self.parse_end_calls += 1;
        self.last_parse_stats = stats;
    }

    /// Test hook callback for query start.
    pub fn onQueryStart(self: *@This(), kind: instrumentation.QueryInstrumentationKind, selector_len: usize) void {
        self.query_start_calls += 1;
        self.last_query_kind = kind;
        self.last_selector_len = selector_len;
    }

    /// Test hook callback for query completion.
    pub fn onQueryEnd(self: *@This(), stats: instrumentation.QueryInstrumentationStats) void {
        self.query_end_calls += 1;
        self.last_query_stats = stats;
    }
};

test "instrumentation wrappers invoke compile-time hooks and preserve results" {
    const alloc = std.testing.allocator;
    var hooks: HookProbe = .{};

    var html = "<div><a id='x' href='https://example'></a></div>".*;
    var doc = try instrumentation.parseWithHooks(std.testing.io, ParseOptions{}, alloc, &html, &hooks);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_start_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_end_calls);
    try std.testing.expect(hooks.last_parse_stats.elapsed_ns > 0);
    try std.testing.expectEqual(html.len, hooks.last_input_len);
    try std.testing.expect(hooks.last_parse_stats.node_count >= 2);

    var runtime_it = instrumentation.queryWithHooks(std.testing.io, &doc, "a#x", &hooks);
    try std.testing.expect(runtime_it.next() != null);
    try std.testing.expectEqual(instrumentation.QueryInstrumentationKind.query, hooks.last_query_kind);
    try std.testing.expectEqual(@as(?bool, null), hooks.last_query_stats.matched);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "a#x");

    _ = instrumentation.queryRuntimeWithHooks(std.testing.io, &doc, sel, &hooks);
    try std.testing.expectEqual(instrumentation.QueryInstrumentationKind.query_runtime, hooks.last_query_kind);
    try std.testing.expectEqual(@as(?bool, null), hooks.last_query_stats.matched);
    try std.testing.expect(hooks.query_start_calls >= 2);
    try std.testing.expect(hooks.query_end_calls >= 2);
}

test "format document types" {
    const alloc = std.testing.allocator;

    const opts: ParseOptions = .{ .drop_whitespace_text_nodes = .none };
    const opts_out = try std.fmt.allocPrint(alloc, "{f}", .{opts});
    defer alloc.free(opts_out);
    try std.testing.expectEqualStrings("ParseOptions{drop_whitespace_text_nodes=none, non_destructive=false, store_last_child=false, store_prev_sibling=false}", opts_out);

    const span: Span = .{ .start = 2, .len = 3 };
    const span_out = try std.fmt.allocPrint(alloc, "{f}", .{span});
    defer alloc.free(span_out);
    try std.testing.expectEqualStrings("Span{start=2, len=3}", span_out);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<div><span></span><span></span></div>".*;
    try resetParsed(.{}, &doc, &src);

    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    const qit = div.query("span");
    const qit_out = try std.fmt.allocPrint(alloc, "{f}", .{qit});
    defer alloc.free(qit_out);
    try std.testing.expectEqualStrings("QueryIter{scope_root=1, next_index=2}", qit_out);

    const cit = div.children();
    const cit_out = try std.fmt.allocPrint(alloc, "{f}", .{cit});
    defer alloc.free(cit_out);
    try std.testing.expectEqualStrings("ChildrenIter{next_idx=2}", cit_out);

    const doc_out = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(doc_out);
    try std.testing.expectEqualStrings("<div><span></span><span></span></div>", doc_out);
}
