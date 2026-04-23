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

/// Compile-time parser options and type factory for generated public API types.
pub const ParseOptions = struct {
    /// Drops whitespace-only text nodes during parse when throughput matters more
    /// than preserving indentation-only text nodes.
    drop_whitespace_text_nodes: bool = true,
    /// Preserves caller bytes by parsing directly from the original source and
    /// keeping lazy attr/text decoding out of the input buffer.
    /// This is off by default so the destructive hot path stays unchanged.
    non_destructive: bool = false,

    /// Returns the accepted parse input slice type for this option set.
    pub fn GetInput(options: @This()) type {
        return if (options.non_destructive) []const u8 else []u8;
    }

    /// Returns the parser type bound to this option set.
    pub fn Parser(options: @This()) type {
        return parser.Parser(options);
    }

    /// Formats parse options for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ParseOptions{{drop_whitespace_text_nodes={}, non_destructive={}}}", .{
            self.drop_whitespace_text_nodes,
            self.non_destructive,
        });
    }

    /// Returns the raw node storage layout used by `Document.nodes`.
    pub fn GetNodeRaw(_: @This()) type {
        return struct {
            //! Backing node storage record for parsed DOM state.
            /// Tag-name span for elements or text span for text nodes.
            name_or_text: Span = .{},

            /// End of the raw attribute byte span for element nodes.
            /// Attribute bytes begin at `name_or_text.end`.
            /// `0` marks non-element nodes (document root at index 0, or text).
            attr_end: IndexInt = 0,

            /// Last direct child index. The first child is derived from `index + 1`.
            last_child: IndexInt = InvalidIndex,
            /// Previous sibling index. The next sibling is derived from `subtree_end + 1`.
            prev_sibling: IndexInt = InvalidIndex,
            /// Parent node index.
            parent: IndexInt = InvalidIndex,

            /// Inclusive subtree tail index for fast descendant skipping.
            subtree_end: IndexInt = 0,
        };
    }

    /// Returns the lightweight node wrapper type bound to this option set.
    pub fn GetNode(options: @This()) type {
        return struct {
            //! Public node wrapper that carries document pointer + node index.
            const DocType = options.GetDocument();
            const ChildrenIterType = options.ChildrenIter();
            const DebugQueryResultType = options.QueryDebugResult();
            const QueryIterType = options.QueryIter();
            const Self = @This();

            /// Controls text extraction behavior for `innerText*` APIs.
            pub const TextOptions = struct {
                /// Collapses runs of HTML whitespace to single spaces when true.
                normalize_whitespace: bool = true,

                /// Formats text extraction options for human-readable output.
                pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    try writer.print("TextOptions{{normalize_whitespace={}}}", .{self.normalize_whitespace});
                }
            };

            /// Owning document pointer.
            doc: *DocType,
            /// Backing node index inside `doc.nodes`.
            index: IndexInt,

            /// Returns the underlying raw node record.
            pub fn raw(self: @This()) *const options.GetNodeRaw() {
                return &self.doc.nodes.items[self.index];
            }

            /// Returns element tag name bytes from parsed source.
            pub fn tagName(self: @This()) []const u8 {
                return self.raw().name_or_text.slice(self.doc.source);
            }

            /// Writes HTML serialization of this node and its subtree to `writer`.
            pub fn writeHtml(self: @This(), writer: anytype) WriterError(@TypeOf(writer))!void {
                const node_raw = &self.doc.nodes.items[@intCast(self.index)];
                try writeNodeHtml(self.doc, self.index, node_raw, writer);
            }

            /// Writes HTML serialization of this node only, excluding its children.
            pub fn writeHtmlSelf(self: @This(), writer: anytype) WriterError(@TypeOf(writer))!void {
                const node_raw = &self.doc.nodes.items[@intCast(self.index)];
                try writeNodeHtmlSelf(self.doc, self.index, node_raw, writer);
            }

            /// Default formatter uses HTML serialization for this node.
            pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.writeHtml(writer);
            }

            /// Returns text content of this subtree; may borrow or allocate in `arena_alloc`.
            pub fn innerText(self: @This(), arena_alloc: std.mem.Allocator) ![]const u8 {
                return self.innerTextWithOptions(arena_alloc, .{});
            }

            /// Same as `innerText` but with explicit text-normalization options.
            pub fn innerTextWithOptions(self: @This(), arena_alloc: std.mem.Allocator, opts: Self.TextOptions) ![]const u8 {
                const doc = self.doc;
                const node_raw = &doc.nodes.items[self.index];

                if (comptime options.non_destructive) {
                    if (doc.isTextIndex(self.index)) {
                        const text = node_raw.name_or_text.slice(doc.source);
                        if (!opts.normalize_whitespace and std.mem.indexOfScalar(u8, text, '&') == null) return text;
                        return self.innerTextOwnedWithOptions(arena_alloc, opts);
                    }

                    var text_count: usize = 0;
                    var first_text: ?[]const u8 = null;
                    var idx = self.index + 1;
                    while (idx <= node_raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
                        const node = &doc.nodes.items[idx];
                        if (!doc.isTextIndex(idx)) continue;
                        text_count += 1;
                        if (text_count == 1) first_text = node.name_or_text.slice(doc.source);
                        if (text_count > 1) break;
                    }

                    if (text_count == 0) return "";
                    if (text_count == 1 and !opts.normalize_whitespace and std.mem.indexOfScalar(u8, first_text.?, '&') == null) {
                        return first_text.?;
                    }
                    return self.innerTextOwnedWithOptions(arena_alloc, opts);
                } else {
                    if (doc.isTextIndex(self.index)) {
                        const mut_node = &doc.nodes.items[self.index];
                        _ = decodeTextNode(mut_node, doc);
                        if (!opts.normalize_whitespace) return mut_node.name_or_text.slice(doc.source);
                        return normalizeTextNodeInPlace(mut_node, doc);
                    }

                    var first_idx: IndexInt = InvalidIndex;
                    var count: usize = 0;

                    var idx = self.index + 1;
                    while (idx <= node_raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
                        const node = &doc.nodes.items[idx];
                        if (!doc.isTextIndex(idx)) continue;
                        count += 1;
                        _ = decodeTextNode(node, doc);
                        if (count == 1) first_idx = idx;
                    }

                    if (count == 0) return "";
                    if (count == 1) {
                        const only = &doc.nodes.items[first_idx];
                        if (!opts.normalize_whitespace) return only.name_or_text.slice(doc.source);
                        return normalizeTextNodeInPlace(only, doc);
                    }

                    var out = std.ArrayList(u8).empty;
                    defer out.deinit(arena_alloc);

                    if (!opts.normalize_whitespace) {
                        idx = self.index + 1;
                        while (idx <= node_raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
                            const node = &doc.nodes.items[idx];
                            if (!doc.isTextIndex(idx)) continue;
                            const seg = node.name_or_text.slice(doc.source);
                            try ensureOutExtra(&out, arena_alloc, seg.len);
                            out.appendSliceAssumeCapacity(seg);
                        }
                    } else {
                        var state: WhitespaceNormState = .{};
                        idx = self.index + 1;
                        while (idx <= node_raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
                            const node = &doc.nodes.items[idx];
                            if (!doc.isTextIndex(idx)) continue;
                            try appendNormalizedSegment(&out, arena_alloc, node.name_or_text.slice(doc.source), &state);
                        }
                    }

                    if (out.items.len == 0) return "";
                    return try out.toOwnedSlice(arena_alloc);
                }
            }

            /// Always materializes subtree text into newly allocated output.
            pub fn innerTextOwned(self: @This(), arena_alloc: std.mem.Allocator) ![]const u8 {
                return self.innerTextOwnedWithOptions(arena_alloc, .{});
            }

            /// Owned variant of `innerTextWithOptions`.
            pub fn innerTextOwnedWithOptions(self: @This(), arena_alloc: std.mem.Allocator, opts: Self.TextOptions) ![]const u8 {
                const doc = self.doc;
                const node_raw = &doc.nodes.items[self.index];

                var out = std.ArrayList(u8).empty;
                defer out.deinit(arena_alloc);

                if (doc.isTextIndex(self.index)) {
                    const text = node_raw.name_or_text.slice(doc.source);
                    if (!opts.normalize_whitespace) {
                        try appendDecodedSegment(&out, arena_alloc, text);
                    } else {
                        var state: WhitespaceNormState = .{};
                        try appendDecodedNormalizedSegment(&out, arena_alloc, text, &state);
                    }
                    return try out.toOwnedSlice(arena_alloc);
                }

                if (!opts.normalize_whitespace) {
                    var idx = self.index + 1;
                    while (idx <= node_raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
                        const node = &doc.nodes.items[idx];
                        if (!doc.isTextIndex(idx)) continue;
                        try appendDecodedSegment(&out, arena_alloc, node.name_or_text.slice(doc.source));
                    }
                    return try out.toOwnedSlice(arena_alloc);
                }

                var state: WhitespaceNormState = .{};
                var idx = self.index + 1;
                while (idx <= node_raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
                    const node = &doc.nodes.items[idx];
                    if (!doc.isTextIndex(idx)) continue;
                    try appendDecodedNormalizedSegment(&out, arena_alloc, node.name_or_text.slice(doc.source), &state);
                }
                return try out.toOwnedSlice(arena_alloc);
            }

            /// Returns decoded attribute value for `name`, if present.
            pub fn getAttributeValue(self: @This(), name: []const u8) ?[]const u8 {
                if (comptime options.non_destructive) {
                    @compileError("Use getAttributeValueAlloc for non-destructive documents.");
                }
                const node_raw = &self.doc.nodes.items[self.index];
                return attr.getAttrValue(self.doc, node_raw, name, self.doc.allocator);
            }

            /// Returns decoded attribute value for `name`, allocating from `allocator` when needed.
            pub fn getAttributeValueAlloc(self: @This(), allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
                const node_raw = &self.doc.nodes.items[self.index];
                return attr.getAttrValue(self.doc, node_raw, name, allocator);
            }

            /// Returns first element child.
            pub fn firstChild(self: @This()) ?@This() {
                const idx = self.doc.firstElementChildIndex(self.index);
                if (idx == InvalidIndex) return null;
                return self.doc.nodeAt(idx);
            }

            /// Returns last element child.
            pub fn lastChild(self: @This()) ?@This() {
                const node_raw = &self.doc.nodes.items[self.index];
                var idx = node_raw.last_child;
                while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
                    if (self.doc.isElementIndex(idx)) return self.doc.nodeAt(idx);
                }
                return null;
            }

            /// Returns next element sibling.
            pub fn nextSibling(self: @This()) ?@This() {
                const idx = self.doc.nextElementSiblingIndex(self.index);
                if (idx == InvalidIndex) return null;
                return self.doc.nodeAt(idx);
            }

            /// Returns previous element sibling.
            pub fn prevSibling(self: @This()) ?@This() {
                const node_raw = &self.doc.nodes.items[self.index];
                var idx = node_raw.prev_sibling;
                while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
                    if (self.doc.isElementIndex(idx)) return self.doc.nodeAt(idx);
                }
                return null;
            }

            /// Returns parent element node.
            pub fn parentNode(self: @This()) ?@This() {
                const parent = self.doc.parentIndex(self.index);
                if (parent == InvalidIndex or parent == 0) return null;
                return self.doc.nodeAt(parent);
            }

            /// Returns direct-child node iterator.
            pub fn children(self: @This()) ChildrenIterType {
                return self.doc.childrenIter(self.index);
            }

            fn decodeTextNode(noalias node: anytype, doc: anytype) []const u8 {
                if (comptime options.non_destructive) unreachable;
                const text_mut = node.name_or_text.sliceMut(doc.source);
                const new_len = entities.decodeInPlace(text_mut);
                node.name_or_text.end = node.name_or_text.start + @as(IndexInt, @intCast(new_len));
                return node.name_or_text.slice(doc.source);
            }

            fn normalizeTextNodeInPlace(noalias node: anytype, doc: anytype) []const u8 {
                if (comptime options.non_destructive) unreachable;
                const text_mut = node.name_or_text.sliceMut(doc.source);
                const new_len = normalizeWhitespaceInPlace(text_mut);
                node.name_or_text.end = node.name_or_text.start + @as(IndexInt, @intCast(new_len));
                return node.name_or_text.slice(doc.source);
            }

            fn normalizeWhitespaceInPlace(bytes: []u8) usize {
                var r: usize = 0;
                var w: usize = 0;
                var pending_space = false;
                var wrote_any = false;

                while (r < bytes.len) : (r += 1) {
                    const c = bytes[r];
                    if (tables.WhitespaceTable[c]) {
                        pending_space = true;
                        continue;
                    }

                    if (pending_space and wrote_any) {
                        bytes[w] = ' ';
                        w += 1;
                    }
                    bytes[w] = c;
                    w += 1;
                    pending_space = false;
                    wrote_any = true;
                }

                return w;
            }

            const WhitespaceNormState = struct {
                pending_space: bool = false,
                wrote_any: bool = false,
            };

            pub fn WriterError(comptime WriterType: type) type {
                return switch (@typeInfo(WriterType)) {
                    .pointer => std.meta.Child(WriterType).Error,
                    else => WriterType.Error,
                };
            }

            fn appendNormalizedSegment(noalias out: *std.ArrayList(u8), alloc: std.mem.Allocator, seg: []const u8, noalias state: *WhitespaceNormState) !void {
                try ensureOutExtra(out, alloc, seg.len + 1);
                appendNormalizedSegmentAssumeCapacity(out, seg, state);
            }

            fn appendNormalizedSegmentAssumeCapacity(noalias out: *std.ArrayList(u8), seg: []const u8, noalias state: *WhitespaceNormState) void {
                for (seg) |c| {
                    if (tables.WhitespaceTable[c]) {
                        state.pending_space = true;
                        continue;
                    }

                    if (state.pending_space and state.wrote_any) {
                        out.appendAssumeCapacity(' ');
                    }
                    out.appendAssumeCapacity(c);
                    state.pending_space = false;
                    state.wrote_any = true;
                }
            }

            fn writeNodeHtml(doc: anytype, idx: IndexInt, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
                if (idx == 0) {
                    try writeChildrenHtml(doc, idx, node_raw, writer);
                    return;
                }
                if (node_raw.attr_end == 0) {
                    try writer.writeAll(node_raw.name_or_text.slice(doc.source));
                    return;
                }

                const name = node_raw.name_or_text.slice(doc.source);
                try writeByte(writer, '<');
                try writer.writeAll(name);
                try writeAttrsHtml(doc, node_raw, writer);
                try writeByte(writer, '>');

                if (!tags.isVoidTagWithKey(name, tags.first8Key(name))) {
                    try writeChildrenHtml(doc, idx, node_raw, writer);
                    try writer.writeAll("</");
                    try writer.writeAll(name);
                    try writeByte(writer, '>');
                }
            }

            fn writeNodeHtmlSelf(doc: anytype, idx: IndexInt, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
                if (idx == 0) {
                    try writeChildrenHtml(doc, idx, node_raw, writer);
                    return;
                }
                if (node_raw.attr_end == 0) {
                    try writer.writeAll(node_raw.name_or_text.slice(doc.source));
                    return;
                }

                const name = node_raw.name_or_text.slice(doc.source);
                try writeByte(writer, '<');
                try writer.writeAll(name);
                try writeAttrsHtml(doc, node_raw, writer);
                try writeByte(writer, '>');
            }

            fn writeChildrenHtml(doc: anytype, parent_idx: IndexInt, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
                const end: IndexInt = node_raw.subtree_end;
                var idx: IndexInt = parent_idx + 1;
                const len_idx: IndexInt = @intCast(doc.nodes.items.len);
                while (idx <= end and idx < len_idx) {
                    const child = &doc.nodes.items[@intCast(idx)];
                    if (child.parent != parent_idx) {
                        idx += 1;
                        continue;
                    }
                    try writeNodeHtml(doc, idx, child, writer);
                    const next = child.subtree_end + 1;
                    idx = if (next > idx) next else idx + 1;
                }
            }

            fn writeAttrsHtml(doc: anytype, noalias node_raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
                const source: []const u8 = doc.source;
                var i: usize = @intCast(node_raw.name_or_text.end);
                const end: usize = @intCast(node_raw.attr_end);

                while (i < end) {
                    while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
                    if (i >= end) return;

                    if (source[i] == 0) {
                        i = skipAttrGap(source, end, i);
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

            fn writeAttrName(writer: anytype, name: []const u8) WriterError(@TypeOf(writer))!void {
                try writeByte(writer, ' ');
                try writer.writeAll(name);
            }

            fn writeAttrValue(writer: anytype, value: []const u8) WriterError(@TypeOf(writer))!void {
                try writer.writeAll("=\"");
                try writeEscapedAttrValue(writer, value);
                try writeByte(writer, '"');
            }

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

            fn writeByte(writer: anytype, b: u8) WriterError(@TypeOf(writer))!void {
                try writer.writeAll(&[_]u8{b});
            }

            const ExtendedGapSentinel = 0xff;
            const ExtendedGapHeaderLen = 2 + @sizeOf(IndexInt);

            fn skipAttrGap(source: []const u8, span_end: usize, start: usize) usize {
                std.debug.assert(span_end <= source.len);
                std.debug.assert(start < span_end);
                if (start + 1 >= span_end) return span_end;
                const len_byte = source[start + 1];
                if (len_byte == ExtendedGapSentinel) {
                    if (start + ExtendedGapHeaderLen > span_end) return span_end;
                    const skip = std.mem.readInt(IndexInt, source[start + 2 .. start + ExtendedGapHeaderLen][0..@sizeOf(IndexInt)], attr.nativeEndian());
                    const next = start + ExtendedGapHeaderLen + @as(usize, @intCast(skip));
                    return @min(next, span_end);
                }
                const next = start + 2 + @as(usize, len_byte);
                return @min(next, span_end);
            }

            fn appendDecodedSegment(noalias out: *std.ArrayList(u8), alloc: std.mem.Allocator, seg: []const u8) !void {
                try ensureOutExtra(out, alloc, seg.len);
                var idx: usize = 0;
                while (idx < seg.len) {
                    const amp = std.mem.indexOfScalarPos(u8, seg, idx, '&') orelse {
                        out.appendSliceAssumeCapacity(seg[idx..]);
                        break;
                    };

                    if (amp > idx) out.appendSliceAssumeCapacity(seg[idx..amp]);
                    var decoded_bytes: [4]u8 = undefined;
                    if (decodeEntityPrefixBytes(alloc, seg[amp..], &decoded_bytes)) |decoded| {
                        out.appendSliceAssumeCapacity(decoded_bytes[0..decoded.len]);
                        idx = amp + decoded.consumed;
                    } else {
                        out.appendAssumeCapacity(seg[amp]);
                        idx = amp + 1;
                    }
                }
            }

            fn appendDecodedNormalizedSegment(noalias out: *std.ArrayList(u8), alloc: std.mem.Allocator, seg: []const u8, noalias state: *WhitespaceNormState) !void {
                try ensureOutExtra(out, alloc, seg.len + 1);
                var idx: usize = 0;
                while (idx < seg.len) {
                    const amp = std.mem.indexOfScalarPos(u8, seg, idx, '&') orelse {
                        appendNormalizedSegmentAssumeCapacity(out, seg[idx..], state);
                        break;
                    };

                    if (amp > idx) appendNormalizedSegmentAssumeCapacity(out, seg[idx..amp], state);
                    var decoded_bytes: [4]u8 = undefined;
                    if (decodeEntityPrefixBytes(alloc, seg[amp..], &decoded_bytes)) |decoded| {
                        appendNormalizedSegmentAssumeCapacity(out, decoded_bytes[0..decoded.len], state);
                        idx = amp + decoded.consumed;
                    } else {
                        appendNormalizedSegmentAssumeCapacity(out, seg[amp .. amp + 1], state);
                        idx = amp + 1;
                    }
                }
            }

            fn decodeEntityPrefixBytes(alloc: std.mem.Allocator, rem: []const u8, decoded_bytes: *[4]u8) ?struct { consumed: usize, len: usize } {
                const semi = std.mem.indexOfScalar(u8, rem, ';') orelse return null;
                const consumed = semi + 1;

                var stack_buf: [32]u8 = undefined;
                if (consumed <= stack_buf.len) {
                    @memcpy(stack_buf[0..consumed], rem[0..consumed]);
                    const new_len = entities.decodeInPlace(stack_buf[0..consumed]);
                    if (new_len >= consumed) return null;
                    if (new_len > decoded_bytes.len) return null;
                    @memcpy(decoded_bytes[0..new_len], stack_buf[0..new_len]);
                    return .{ .consumed = consumed, .len = new_len };
                }

                const copied = alloc.dupe(u8, rem[0..consumed]) catch return null;
                defer alloc.free(copied);
                const new_len = entities.decodeInPlace(copied);
                if (new_len >= consumed) return null;
                if (new_len > decoded_bytes.len) return null;
                @memcpy(decoded_bytes[0..new_len], copied[0..new_len]);
                return .{ .consumed = consumed, .len = new_len };
            }

            fn ensureOutExtra(noalias out: *std.ArrayList(u8), alloc: std.mem.Allocator, extra: usize) !void {
                const need = out.items.len + extra;
                if (need <= out.capacity) return;
                var target = out.capacity +| (out.capacity >> 1) + 16;
                if (target < need) target = need;
                if (target <= out.capacity) target = out.capacity + 1;
                try out.ensureTotalCapacity(alloc, target);
            }

            test "format text options" {
                if (comptime options.non_destructive or !options.drop_whitespace_text_nodes) return error.SkipZigTest;

                const alloc = std.testing.allocator;
                const rendered = try std.fmt.allocPrint(alloc, "{f}", .{Self.TextOptions{ .normalize_whitespace = false }});
                defer alloc.free(rendered);
                try std.testing.expectEqualStrings("TextOptions{normalize_whitespace=false}", rendered);
            }

            /// Compiles selector at comptime and returns first descendant match.
            pub fn queryOne(self: @This(), comptime selector: []const u8) ?@This() {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryOneCached(sel);
            }

            /// Returns first descendant match for already compiled selector.
            pub fn queryOneCached(self: @This(), sel: ast.Selector) ?@This() {
                return self.doc.queryOneCachedFrom(sel, self.index);
            }

            /// Debug variant of `queryOne` that returns mismatch diagnostics.
            pub fn queryOneDebug(self: @This(), comptime selector: []const u8) DebugQueryResultType {
                const sel = comptime ast.Selector.compile(selector);
                return self.doc.queryOneCachedDebugFrom(sel, self.index);
            }

            /// Parses selector at runtime and returns first descendant match.
            pub fn queryOneRuntime(self: @This(), allocator: std.mem.Allocator, selector: []const u8) runtime_selector.Error!?@This() {
                return self.doc.queryOneRuntimeFrom(allocator, selector, self.index);
            }

            /// Runtime debug query returning first match, diagnostics, and parse error if any.
            pub fn queryOneRuntimeDebug(self: @This(), allocator: std.mem.Allocator, selector: []const u8) DebugQueryResultType {
                return self.doc.queryOneRuntimeDebugFrom(allocator, selector, self.index);
            }

            /// Compiles selector at comptime and returns lazy descendant iterator.
            pub fn queryAll(self: @This(), comptime selector: []const u8) QueryIterType {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryAllCached(sel);
            }

            /// Returns lazy descendant iterator for already compiled selector.
            pub fn queryAllCached(self: @This(), sel: ast.Selector) QueryIterType {
                self.doc.ensureQueryPrereqs(sel);
                return .{ .doc = self.doc, .selector = sel, .scope_root = self.index, .next_index = self.index + 1 };
            }

            /// Parses selector at runtime and returns lazy descendant iterator.
            pub fn queryAllRuntime(self: @This(), allocator: std.mem.Allocator, selector: []const u8) runtime_selector.Error!QueryIterType {
                return self.doc.queryAllRuntimeFrom(allocator, selector, self.index);
            }
        };
    }

    /// Returns the lazy query iterator type for this option set.
    pub fn QueryIter(options: @This()) type {
        return struct {
            //! Lazy selector iterator over document or scoped subtree matches.
            const DocType = options.GetDocument();
            const NodeTypeWrapper = options.GetNode();

            /// Owning document pointer.
            doc: *DocType,
            /// Selector evaluated by this iterator.
            selector: ast.Selector,
            /// Optional subtree root for scoped queries.
            scope_root: IndexInt = InvalidIndex,
            /// Next node index to test.
            next_index: IndexInt = 1,

            /// Returns next matching node or `null` when exhausted.
            pub fn next(noalias self: *@This()) ?NodeTypeWrapper {
                while (self.next_index < self.doc.nodes.items.len) : (self.next_index += 1) {
                    const idx = self.next_index;

                    if (self.scope_root != InvalidIndex) {
                        const root = &self.doc.nodes.items[self.scope_root];
                        if (idx <= self.scope_root or idx > root.subtree_end) continue;
                    }

                    if (!self.doc.isElementIndex(idx)) continue;

                    if (matcher.matchesSelectorAt(DocType, self.doc, self.selector, idx, self.scope_root)) {
                        self.next_index += 1;
                        return self.doc.nodeAt(idx);
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
        };
    }

    /// Returns the structured result type for debug query helpers.
    pub fn QueryDebugResult(options: @This()) type {
        return struct {
            /// First matching node, if any.
            node: ?options.GetNode() = null,
            /// Detailed mismatch diagnostics for the attempted query.
            report: selector_debug.QueryDebugReport = .{},
            /// Runtime parse error, if selector compilation failed.
            err: ?runtime_selector.Error = null,
        };
    }

    /// Returns direct-child iterator type for this option set.
    pub fn ChildrenIter(options: @This()) type {
        return struct {
            //! Iterator over direct child nodes for a parent node.
            const DocType = options.GetDocument();
            const NodeTypeWrapper = options.GetNode();

            /// Owning document pointer.
            doc: *const DocType,
            /// Next direct child index to yield.
            next_idx: IndexInt = InvalidIndex,

            /// Returns next wrapped child node or `null` when exhausted.
            pub fn next(noalias self: *@This()) ?NodeTypeWrapper {
                if (self.next_idx == InvalidIndex) return null;
                const idx = self.next_idx;
                self.next_idx = self.doc.nextElementSiblingIndex(idx);
                return self.doc.nodeAt(idx);
            }

            /// Allocates and returns all remaining wrapped child nodes.
            pub fn collect(noalias self: *@This(), allocator: std.mem.Allocator) ![]NodeTypeWrapper {
                var count: usize = 0;
                var idx = self.next_idx;
                while (idx != InvalidIndex) : (idx = self.doc.nextElementSiblingIndex(idx)) {
                    count += 1;
                }

                const out = try allocator.alloc(NodeTypeWrapper, count);
                idx = self.next_idx;
                var out_idx: usize = 0;
                while (idx != InvalidIndex) : (idx = self.doc.nextElementSiblingIndex(idx)) {
                    out[out_idx] = self.doc.nodeAt(idx).?;
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

    /// Returns the document type (parser + query surface) for this option set.
    pub fn GetDocument(options: @This()) type {
        return struct {
            //! Parsed document owner and query entrypoint container.
            const DocSelf = @This();
            const DebugQueryResultType = options.QueryDebugResult();
            const RawNodeType = options.GetNodeRaw();
            const NodeStorage = struct {
                items: []RawNodeType = &[_]RawNodeType{},
            };
            const ChildrenIterType = options.ChildrenIter();
            const NodeTypeWrapper = options.GetNode();
            const QueryIterType = options.QueryIter();

            /// Allocator used for node storage and caller-directed temporary work.
            allocator: std.mem.Allocator,
            /// Source bytes referenced by node spans.
            source: options.GetInput(),

            /// Parsed node storage.
            nodes: NodeStorage = .{},

            /// Initializes an empty document using `allocator` for internal storage.
            pub fn init(allocator: std.mem.Allocator) DocSelf {
                return .{
                    .allocator = allocator,
                    .source = emptySource(),
                };
            }

            /// Releases all document-owned memory.
            pub fn deinit(noalias self: *DocSelf) void {
                if (self.nodes.items.len != 0) {
                    self.allocator.free(self.nodes.items);
                    self.nodes.items = &[_]RawNodeType{};
                }
            }

            /// Clears parsed state and releases parsed node storage.
            pub fn clear(noalias self: *DocSelf) void {
                self.source = emptySource();
                if (self.nodes.items.len != 0) {
                    self.allocator.free(self.nodes.items);
                    self.nodes.items = &[_]RawNodeType{};
                }
            }

            /// Parses HTML using the behavior encoded in this document type.
            /// Destructive documents parse `[]u8` in place.
            /// Non-destructive documents accept `[]const u8` and keep lazy decode out of `source`.
            pub fn parse(noalias self: *DocSelf, input: options.GetInput()) !void {
                self.clear();
                self.* = try options.Parser().parse(self.allocator, input);
            }

            fn emptySource() options.GetInput() {
                if (comptime options.non_destructive) {
                    return &[_]u8{};
                }
                return @constCast(@as([]const u8, &[_]u8{}));
            }

            /// Returns first matching element for comptime selector.
            pub fn queryOne(self: *const DocSelf, comptime selector: []const u8) ?NodeTypeWrapper {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryOneCached(sel);
            }

            /// Returns first matching element for precompiled selector.
            pub fn queryOneCached(self: *const DocSelf, sel: ast.Selector) ?NodeTypeWrapper {
                return self.queryOneCachedFrom(sel, InvalidIndex);
            }

            /// Debug variant of `queryOne` that records mismatch details.
            pub fn queryOneDebug(self: *const DocSelf, comptime selector: []const u8) DebugQueryResultType {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryOneCachedDebugFrom(sel, InvalidIndex);
            }

            /// Parses selector at runtime and returns first match.
            pub fn queryOneRuntime(self: *const DocSelf, allocator: std.mem.Allocator, selector: []const u8) runtime_selector.Error!?NodeTypeWrapper {
                return self.queryOneRuntimeFrom(allocator, selector, InvalidIndex);
            }

            /// Runtime debug query returning first match, diagnostics report, and parse error if any.
            pub fn queryOneRuntimeDebug(self: *const DocSelf, allocator: std.mem.Allocator, selector: []const u8) DebugQueryResultType {
                return self.queryOneRuntimeDebugFrom(allocator, selector, InvalidIndex);
            }

            fn queryOneRuntimeFrom(
                self: *const DocSelf,
                allocator: std.mem.Allocator,
                selector: []const u8,
                scope_root: IndexInt,
            ) runtime_selector.Error!?NodeTypeWrapper {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
                return self.queryOneCachedFrom(sel, scope_root);
            }

            fn queryOneRuntimeDebugFrom(
                self: *const DocSelf,
                allocator: std.mem.Allocator,
                selector: []const u8,
                scope_root: IndexInt,
            ) DebugQueryResultType {
                var report: selector_debug.QueryDebugReport = .{};
                report.reset(selector, scope_root, 0);
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const sel = ast.Selector.compileRuntime(arena.allocator(), selector) catch |err| {
                    report.setRuntimeParseError();
                    return .{
                        .report = report,
                        .err = err,
                    };
                };
                return self.queryOneCachedDebugFrom(sel, scope_root);
            }

            fn queryOneCachedFrom(self: *const DocSelf, sel: ast.Selector, scope_root: IndexInt) ?NodeTypeWrapper {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel);
                const idx = matcher.queryOneIndex(DocSelf, self, sel, scope_root) orelse InvalidIndex;
                if (idx == InvalidIndex) return null;
                return self.nodeAt(idx);
            }

            fn queryOneCachedDebugFrom(self: *const DocSelf, sel: ast.Selector, scope_root: IndexInt) DebugQueryResultType {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel);
                var report: selector_debug.QueryDebugReport = .{};
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                const idx = matcher_debug.explainFirstMatch(DocSelf, self, scratch.allocator(), sel, scope_root, &report) orelse {
                    return .{ .report = report };
                };
                return .{
                    .node = self.nodeAt(idx),
                    .report = report,
                };
            }

            /// Returns lazy iterator over matches for comptime selector.
            pub fn queryAll(self: *const DocSelf, comptime selector: []const u8) QueryIterType {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryAllCached(sel);
            }

            /// Returns lazy iterator over matches for precompiled selector.
            pub fn queryAllCached(self: *const DocSelf, sel: ast.Selector) QueryIterType {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel);
                return .{ .doc = @constCast(self), .selector = sel, .scope_root = InvalidIndex, .next_index = 1 };
            }

            /// Parses selector at runtime and returns lazy iterator.
            pub fn queryAllRuntime(self: *const DocSelf, allocator: std.mem.Allocator, selector: []const u8) runtime_selector.Error!QueryIterType {
                return self.queryAllRuntimeFrom(allocator, selector, InvalidIndex);
            }

            fn queryAllRuntimeFrom(
                self: *const DocSelf,
                allocator: std.mem.Allocator,
                selector: []const u8,
                scope_root: IndexInt,
            ) runtime_selector.Error!QueryIterType {
                const mut_self: *DocSelf = @constCast(self);
                const sel = try ast.Selector.compileRuntime(allocator, selector);
                mut_self.ensureQueryPrereqs(sel);
                return if (scope_root == InvalidIndex)
                    self.queryAllCached(sel)
                else
                    QueryIterType{
                        .doc = @constCast(self),
                        .selector = sel,
                        .scope_root = scope_root,
                        .next_index = scope_root + 1,
                    };
            }

            fn ensureQueryPrereqs(noalias self: *DocSelf, selector: ast.Selector) void {
                _ = .{ self, selector };
            }

            /// Returns parent index for `idx`.
            pub fn parentIndex(self: *const DocSelf, idx: IndexInt) IndexInt {
                if (idx >= self.nodes.items.len) return InvalidIndex;
                return self.nodes.items[idx].parent;
            }

            /// Returns whether `idx` is the document root node.
            pub inline fn isDocumentIndex(_: *const DocSelf, idx: IndexInt) bool {
                return idx == 0;
            }

            /// Returns whether `idx` is an element node.
            pub inline fn isElementIndex(self: *const DocSelf, idx: IndexInt) bool {
                return idx != 0 and idx < self.nodes.items.len and self.nodes.items[idx].attr_end != 0;
            }

            /// Returns whether `idx` is a text node.
            pub inline fn isTextIndex(self: *const DocSelf, idx: IndexInt) bool {
                return idx != 0 and idx < self.nodes.items.len and self.nodes.items[idx].attr_end == 0;
            }

            /// Returns first `<html>` element in the document.
            pub fn html(self: *const DocSelf) ?NodeTypeWrapper {
                return self.findFirstTag("html");
            }

            /// Returns whether `bytes` points inside the document's source buffer.
            pub fn isOwned(self: *const DocSelf, bytes: []const u8) bool {
                if (self.source.len == 0 or bytes.len == 0) return false;
                const src_start = @intFromPtr(self.source.ptr);
                const src_end = src_start + self.source.len;
                const bytes_start = @intFromPtr(bytes.ptr);
                const bytes_end = bytes_start + bytes.len;
                return bytes_start >= src_start and bytes_end <= src_end;
            }

            /// Returns first `<head>` element in the document.
            pub fn head(self: *const DocSelf) ?NodeTypeWrapper {
                return self.findFirstTag("head");
            }

            /// Returns first `<body>` element in the document.
            pub fn body(self: *const DocSelf) ?NodeTypeWrapper {
                return self.findFirstTag("body");
            }

            /// Returns first element whose tag name equals `name` (ASCII-insensitive).
            pub fn findFirstTag(self: *const DocSelf, name: []const u8) ?NodeTypeWrapper {
                var i: usize = 1;
                while (i < self.nodes.items.len) : (i += 1) {
                    const n = &self.nodes.items[i];
                    if (!self.isElementIndex(@intCast(i))) continue;
                    if (tables.eqlIgnoreCaseAscii(n.name_or_text.slice(self.source), name)) return self.nodeAt(@intCast(i));
                }
                return null;
            }

            /// Wraps raw node index as public `Node` wrapper when valid.
            pub inline fn nodeAt(self: *const DocSelf, idx: IndexInt) ?NodeTypeWrapper {
                if (idx == InvalidIndex or idx >= self.nodes.items.len) return null;
                return .{
                    .doc = @constCast(self),
                    .index = idx,
                };
            }

            /// Writes HTML serialization of this node and its subtree to `writer`.
            pub fn writeHtml(self: @This(), writer: anytype) NodeTypeWrapper.WriterError(@TypeOf(writer))!void {
                if (comptime options.non_destructive) {
                    try writer.writeAll(self.source);
                    return;
                }
                return self.nodeAt(0).?.writeHtml(writer);
            }

            /// Writes HTML serialization of this document root only, excluding its children.
            pub fn writeHtmlSelf(self: @This(), writer: anytype) NodeTypeWrapper.WriterError(@TypeOf(writer))!void {
                if (comptime options.non_destructive) {
                    try writer.writeAll(self.source);
                    return;
                }
                return self.nodeAt(0).?.writeHtmlSelf(writer);
            }

            /// Default formatter uses HTML serialization for this node.
            pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.writeHtml(writer);
            }

            /// Returns first direct element-like child index for `parent_idx`, if any.
            pub fn firstElementChildIndex(self: *const DocSelf, parent_idx: IndexInt) IndexInt {
                if (parent_idx >= self.nodes.items.len) return InvalidIndex;

                const candidate1: IndexInt = parent_idx + 1;
                if (candidate1 >= self.nodes.items.len) return InvalidIndex;

                const node1 = &self.nodes.items[candidate1];
                if (self.isElementIndex(candidate1)) {
                    if (node1.parent == parent_idx) return candidate1;
                    return InvalidIndex;
                }

                const candidate2: IndexInt = candidate1 + 1;
                if (candidate2 >= self.nodes.items.len) return InvalidIndex;

                const node2 = &self.nodes.items[candidate2];
                if (self.isTextIndex(candidate2)) {
                    @branchHint(.cold);
                    var scan: IndexInt = candidate2;
                    while (scan < self.nodes.items.len and self.isTextIndex(scan)) : (scan += 1) {}
                    if (scan >= self.nodes.items.len) return InvalidIndex;
                    const scanned = &self.nodes.items[scan];
                    if (scanned.parent == parent_idx and self.isElementIndex(scan)) return scan;
                    return InvalidIndex;
                }
                if (node2.parent == parent_idx and self.isElementIndex(candidate2)) return candidate2;
                return InvalidIndex;
            }

            /// Returns next direct element-like sibling index for `node_idx`, if any.
            pub fn nextElementSiblingIndex(self: *const DocSelf, node_idx: IndexInt) IndexInt {
                if (node_idx >= self.nodes.items.len) return InvalidIndex;
                const node = &self.nodes.items[node_idx];
                if (!self.isElementIndex(node_idx)) return InvalidIndex;
                const parent_idx = node.parent;
                if (parent_idx == InvalidIndex) return InvalidIndex;

                var candidate: IndexInt = node.subtree_end + 1;
                while (candidate < self.nodes.items.len) : (candidate += 1) {
                    const cand = &self.nodes.items[candidate];
                    if (cand.parent != parent_idx) return InvalidIndex;
                    if (self.isElementIndex(candidate)) return candidate;
                    if (!self.isTextIndex(candidate)) return InvalidIndex;
                }
                return InvalidIndex;
            }

            /// Returns direct-child node iterator for `parent_idx`.
            pub fn childrenIter(self: *const DocSelf, parent_idx: IndexInt) ChildrenIterType {
                return .{
                    .doc = self,
                    .next_idx = self.firstElementChildIndex(parent_idx),
                };
            }
        };
    }
};

/// Inclusive-exclusive byte span into the document source buffer.
pub const Span = struct {
    /// Inclusive start byte offset in the document source.
    start: IndexInt = 0,
    /// Exclusive end byte offset in the document source.
    end: IndexInt = 0,

    /// Returns the span length in bytes.
    pub fn len(self: @This()) IndexInt {
        return self.end - self.start;
    }

    /// Borrows immutable bytes referenced by this span.
    pub fn slice(self: @This(), source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    /// Borrows mutable bytes referenced by this span.
    pub fn sliceMut(self: @This(), source: []u8) []u8 {
        return source[self.start..self.end];
    }

    /// Formats this span for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Span{{start={}, end={}}}", .{ self.start, self.end });
    }
};

const DefaultTypeOptions: ParseOptions = .{};
const StrictTypeOptions: ParseOptions = .{ .drop_whitespace_text_nodes = false };
const NonDestructiveTypeOptions: ParseOptions = .{ .non_destructive = true };
const NodeRaw = DefaultTypeOptions.GetNodeRaw();
const Node = DefaultTypeOptions.GetNode();
/// Re-exported text extraction options used by node text APIs.
pub const TextOptions = Node.TextOptions;
const QueryIter = DefaultTypeOptions.QueryIter();
const Document = DefaultTypeOptions.GetDocument();
const StrictDocument = StrictTypeOptions.GetDocument();
const NonDestructiveDocument = NonDestructiveTypeOptions.GetDocument();

fn assertNodeTypeLayouts() void {
    _ = @sizeOf(NodeRaw);
    _ = @sizeOf(Node);
}

test "document type excludes parser-only and shadow-source state" {
    try std.testing.expect(!@hasField(Document, "parse_stack"));
    try std.testing.expect(!@hasField(Document, "original_source"));
    try std.testing.expect(!@hasField(Document, "owned_shadow_source"));
    try std.testing.expect(!@hasField(Document, "mutable_source"));
    try std.testing.expect(!@hasField(NodeRaw, "kind"));
    try std.testing.expect(!@hasDecl(ParseOptions, "GetOpenElem"));
}

test "document source type follows parse mode" {
    try std.testing.expect(@FieldType(Document, "source") == []u8);
    try std.testing.expect(@FieldType(NonDestructiveDocument, "source") == []const u8);
}

fn expectIterIds(iter: QueryIter, expected_ids: []const []const u8) !void {
    var mut_iter = iter;
    var i: usize = 0;
    while (mut_iter.next()) |node| {
        if (i >= expected_ids.len) return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[i], id);
        i += 1;
    }
    try std.testing.expectEqual(expected_ids.len, i);
}

fn expectDocQueryComptime(doc: *const Document, comptime selector: []const u8, expected_ids: []const []const u8) !void {
    const it = doc.queryAll(selector);
    try expectIterIds(it, expected_ids);

    const first = doc.queryOne(selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn expectDocQueryRuntime(doc: *const Document, selector: []const u8, expected_ids: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const it = try doc.queryAllRuntime(arena.allocator(), selector);
    try expectIterIds(it, expected_ids);

    const first = try doc.queryOneRuntime(arena.allocator(), selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn expectNodeQueryComptime(scope: Node, comptime selector: []const u8, expected_ids: []const []const u8) !void {
    const it = scope.queryAll(selector);
    try expectIterIds(it, expected_ids);

    const first = scope.queryOne(selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn expectNodeQueryRuntime(scope: Node, selector: []const u8, expected_ids: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const it = try scope.queryAllRuntime(arena.allocator(), selector);
    try expectIterIds(it, expected_ids);

    const first = try scope.queryOneRuntime(arena.allocator(), selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn parseViaMove(alloc: std.mem.Allocator, input: []u8) !Document {
    var doc = Document.init(alloc);
    try doc.parse(input);
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
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<html><head><title>A</title></head><body><div id='x' class='a b'>ok</div><p>n</p></body></html>".*;
    try doc.parse(&html);

    const one = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", one.tagName());

    var it = doc.queryAll("body > *");
    try std.testing.expect(it.next() != null);
}

test "non-destructive parse preserves caller bytes and formats exact original source" {
    const alloc = std.testing.allocator;
    var doc = NonDestructiveDocument.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x' data-v='a&amp;b'> a &amp; b </div>".*;
    const before = html;
    try doc.parse(&html);

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    const attr_value = node.getAttributeValueAlloc(arena.allocator(), "data-v") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", attr_value);

    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("a & b", text);

    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);

    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(before[0..], rendered);
}

test "non-destructive attribute reads do not rewrite attribute bytes" {
    const alloc = std.testing.allocator;
    var doc = NonDestructiveDocument.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b' data-q='1>2'></div>".*;
    const before = html;
    try doc.parse(&html);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    const value = node.getAttributeValueAlloc(arena.allocator(), "data-v") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", value);

    const attr_start: usize = @intCast(node.raw().name_or_text.end);
    const attr_end: usize = @intCast(node.raw().attr_end);
    try std.testing.expect(std.mem.indexOf(u8, doc.source[attr_start..attr_end], "&amp;") != null);
    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);
}

test "non-destructive text reads do not rewrite text bytes" {
    const alloc = std.testing.allocator;
    var doc = NonDestructiveDocument.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<p id='x'> a &amp;  b </p>".*;
    const before = html;
    try doc.parse(&html);

    const node = doc.queryOne("p#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("a & b", text);

    const text_node = doc.nodes.items[node.index + 1];
    try std.testing.expectEqualStrings(" a &amp;  b ", text_node.name_or_text.slice(doc.source));
    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);
}

test "non-destructive innerText ignores oversized malformed entity prefixes safely" {
    const alloc = std.testing.allocator;
    var doc = NonDestructiveDocument.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>&xxxxxxxxxxxxxxxxxxxx&amp;</div>".*;
    const before = html;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("&xxxxxxxxxxxxxxxxxxxx&", text);
    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);
}

test "runtime queryAll iterator is stable across queryOneRuntime calls" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='x'></span></div>".*;
    try doc.parse(&html);

    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();
    var it = try doc.queryAllRuntime(runtime_arena.allocator(), "span.x");

    // This uses a different arena and must not invalidate `it`.
    _ = try doc.queryOneRuntime(alloc, "div");

    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime queryAll iterators compiled from runtime selectors remain independent" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='y'></span></div>".*;
    try doc.parse(&html);

    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();
    var old_it = try doc.queryAllRuntime(runtime_arena.allocator(), "span.x");
    var new_it = try doc.queryAllRuntime(runtime_arena.allocator(), "span.y");

    try std.testing.expect(old_it.next() != null);
    try std.testing.expect(old_it.next() == null);
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "runtime queryAll iterator is invalidated by clear and reparsing" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div><span class='x'></span></div>".*;
    try doc.parse(&html_a);

    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();
    var old_it = try doc.queryAllRuntime(runtime_arena.allocator(), "span.x");
    doc.clear();
    try std.testing.expect(old_it.next() == null);
    try std.testing.expect(doc.queryOne("span.x") == null);

    var html_b = "<div><span class='y'></span></div>".*;
    try doc.parse(&html_b);
    try std.testing.expect(old_it.next() == null);

    var new_it = try doc.queryAllRuntime(runtime_arena.allocator(), "span.y");
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "matcher queryOneIndex rejects invalid scope roots safely" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x'></div>".*;
    try doc.parse(&html);

    const sel = comptime ast.Selector.compile("div");
    const idx = matcher.queryOneIndex(Document, &doc, sel, @as(IndexInt, @intCast(doc.nodes.items.len + 10)));
    try std.testing.expect(idx == null);
}

test "query results matrix (comptime selectors)" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html);

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
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html);

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
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html);

    const list = doc.queryOne("#list") orelse return error.TestUnexpectedResult;
    try expectNodeQueryComptime(list, "li", &.{ "li1", "li2", "li3" });
    try expectNodeQueryComptime(list, "span.name", &.{ "name1", "name2", "name3" });
    try expectNodeQueryRuntime(list, "li:not(.skip)", &.{ "li1", "li2" });

    const sibs = doc.queryOne("#sibs") orelse return error.TestUnexpectedResult;
    try expectNodeQueryComptime(sibs, "a.link", &.{ "a1", "a2", "a3" });
    try expectNodeQueryRuntime(sibs, "a + span.marker", &.{"after_a2"});
    try expectNodeQueryRuntime(sibs, "li", &.{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "a.link");
    const it = sibs.queryAllCached(sel);
    try expectIterIds(it, &.{ "a1", "a2", "a3" });
    const first = sibs.queryOneCached(sel) orelse return error.TestUnexpectedResult;
    const id = first.getAttributeValue("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", id);
}

test "innerText normalizes whitespace by default" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha \n\t beta   gamma  </div>".*;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("alpha beta gamma", text);
}

test "innerText can return non-normalized text" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha \n\t beta   gamma  </div>".*;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(arena.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("  alpha \n\t beta   gamma  ", text);
}

test "innerText normalization is applied across text-node boundaries" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>A <b></b>   B</div>".*;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("A B", text);
}

test "parse-time text normalization is off by default and query-time normalization still works" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha  &amp;   beta  </div>".*;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text_node = doc.nodes.items[node.index + 1];
    try std.testing.expect(text_node.attr_end == 0);
    try std.testing.expectEqualStrings("  alpha  &amp;   beta  ", text_node.name_or_text.slice(doc.source));

    const raw = try node.innerTextWithOptions(arena.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("  alpha  &   beta  ", raw);

    const normalized = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("alpha & beta", normalized);
}

test "parse-time attribute decoding is off by default and query-time lookup decodes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b'></div>".*;
    try doc.parse(&html);

    const node = doc.findFirstTag("div") orelse return error.TestUnexpectedResult;
    const attr_start: usize = node.raw().name_or_text.end;
    const span = doc.source[attr_start..@as(usize, @intCast(node.raw().attr_end))];
    try std.testing.expect(std.mem.indexOf(u8, span, "&amp;") != null);

    const value = node.getAttributeValue("data-v") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", value);
}

test "isOwned distinguishes borrowed single-text and allocated multi-text innerText" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>single</div><div id='y'>a<b></b>b</div>".*;
    try doc.parse(&html);

    const x = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const y = doc.queryOne("#y") orelse return error.TestUnexpectedResult;

    const x_text = try x.innerText(arena.allocator());
    try std.testing.expectEqualStrings("single", x_text);
    try std.testing.expect(doc.isOwned(x_text));

    const y_text = try y.innerText(arena.allocator());
    try std.testing.expectEqualStrings("ab", y_text);
    try std.testing.expect(!doc.isOwned(y_text));
}

test "innerTextOwned always returns allocated output and does not mutate source text bytes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>a &amp; b</div>".*;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text_node_before = doc.nodes.items[node.index + 1];
    try std.testing.expect(text_node_before.attr_end == 0);
    try std.testing.expectEqualStrings("a &amp; b", text_node_before.name_or_text.slice(doc.source));

    const owned = try node.innerTextOwned(arena.allocator());
    try std.testing.expectEqualStrings("a & b", owned);
    try std.testing.expect(!doc.isOwned(owned));

    const text_node_after = doc.nodes.items[node.index + 1];
    try std.testing.expectEqualStrings("a &amp; b", text_node_after.name_or_text.slice(doc.source));
}

test "inplace attribute parser treats explicit empty assignment as name-only" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' b a=   ></div>".*;
    try doc.parse(&html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const a = node.getAttributeValue("a") orelse return error.TestUnexpectedResult;
    const b = node.getAttributeValue("b") orelse return error.TestUnexpectedResult;
    const c = node.getAttributeValue("c");
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(usize, 0), b.len);
    try std.testing.expect(c == null);

    try std.testing.expect(doc.queryOne("div[a]") != null);
    try std.testing.expect(doc.queryOne("div[b]") != null);
    try std.testing.expect(doc.queryOne("div[c]") == null);
}

test "inplace attr lazy parse updates state markers and supports selector-triggered parsing" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' q='&amp;z' n=a&amp;b></div>".*;
    try doc.parse(&html);

    const by_selector = try doc.queryOneRuntime(alloc, "div[q='&z'][n='a&b']");
    try std.testing.expect(by_selector != null);

    const node = by_selector orelse return error.TestUnexpectedResult;
    const q = node.getAttributeValue("q") orelse return error.TestUnexpectedResult;
    const n = node.getAttributeValue("n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("&z", q);
    try std.testing.expectEqualStrings("a&b", n);

    const attr_start: usize = node.raw().name_or_text.end;
    const span = doc.source[attr_start..@as(usize, @intCast(node.raw().attr_end))];
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
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' href='/local' class='button'></div>".*;
    try doc.parse(&html);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "div[href^=https][class*=button]");
    try std.testing.expect(doc.queryOneCached(sel) == null);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "div[href^=https][class*=button]")) == null);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const attr_start: usize = node.raw().name_or_text.end;
    const span = doc.source[attr_start..@as(usize, @intCast(node.raw().attr_end))];
    const class_pos = std.mem.indexOf(u8, span, "class") orelse return error.TestUnexpectedResult;
    const marker_pos = class_pos + "class".len;
    try std.testing.expect(marker_pos < span.len);
    try std.testing.expectEqual(@as(u8, '='), span[marker_pos]);
}

test "inplace extended skip metadata preserves traversal for following attributes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
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

    try doc.parse(html);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const a = node.getAttributeValue("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 320), a.len);
    for (a) |c| try std.testing.expect(c == '&');

    const b = node.getAttributeValue("b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ok", b);
}

test "cached selector APIs are equivalent to runtime string wrappers" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html);

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

        const it = doc.queryAllCached(sel);
        try expectIterIds(it, case.expected);
        const first = doc.queryOneCached(sel);
        if (case.expected.len == 0) {
            try std.testing.expect(first == null);
        } else {
            const node = first orelse return error.TestUnexpectedResult;
            const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(case.expected[0], id);
        }
    }
}

test "runtime query parsing remains correct across parse and clear" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div class='x'></div>".*;
    try doc.parse(&html_a);

    try std.testing.expect((try doc.queryOneRuntime(alloc, "div.x")) != null);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "div.x")) != null);

    var html_b = "<section class='x'></section>".*;
    try doc.parse(&html_b);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "div.x")) == null);

    doc.clear();
    var html_c = "<div class='x'></div>".*;
    try doc.parse(&html_c);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "div.x")) != null);
}

test "attr fast-path names are equivalent to generic lookup semantics" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<a id='x' class='btn primary' href='https://example.com' data-k='v'></a>".*;
    try doc.parse(&html);

    const a = doc.queryOne("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", a.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("btn primary", a.getAttributeValue("class").?);
    try std.testing.expectEqualStrings("https://example.com", a.getAttributeValue("href").?);
    try std.testing.expectEqualStrings("v", a.getAttributeValue("data-k").?);

    try std.testing.expect(a.getAttributeValue("missing") == null);
}

test "mixed-case tags and attrs are queryable via lowercase selectors" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<DiV ID='x' ClAsS='A b' DaTa-K='v'><SpAn id='y'></SpAn></DiV>".*;
    try doc.parse(&html);

    try std.testing.expect(doc.queryOne("div#x[data-k=v]") != null);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "div > span#y")) != null);

    const div = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A b", div.getAttributeValue("class").?);
}

test "multiple class predicates in one compound match correctly" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' class='alpha beta gamma'></div><div id='y' class='alpha beta'></div>".*;
    try doc.parse(&html);

    try expectDocQueryComptime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.delta", &.{});
}

test "class token matching treats all ascii whitespace as separators" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='t' class='a\tb\nc\rd\x0ce'></div>".*;
    try doc.parse(&html);

    try std.testing.expect(doc.queryOne("#t.a") != null);
    try std.testing.expect(doc.queryOne("#t.b") != null);
    try std.testing.expect(doc.queryOne("#t.c") != null);
    try std.testing.expect(doc.queryOne("#t.d") != null);
    try std.testing.expect(doc.queryOne("#t.e") != null);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "#t[class~=d]")) != null);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "#t[class~=e]")) != null);
}

test "scoped query with duplicate ids respects scope and extra predicates" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='outside'><span id='dup' class='x'></span></div><div id='scope'><span id='dup' class='y'></span></div>".*;
    try doc.parse(&html);

    const scope = doc.queryOne("#scope") orelse return error.TestUnexpectedResult;
    const found_ct = scope.queryOne("#dup.y") orelse return error.TestUnexpectedResult;
    const found_rt = (try scope.queryOneRuntime(alloc, "#dup.y")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(found_ct.index, found_rt.index);
    const parent = found_ct.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("scope", parent.getAttributeValue("id").?);
}

test "runtime selector rejects multiple ids in one compound" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var html = "<div id='a'></div>".*;
    try doc.parse(&html);

    try std.testing.expectError(error.InvalidSelector, doc.queryOneRuntime(alloc, "#a#a"));
}

test "runtime selector supports nth-child shorthand variants" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();

    var html = "<div id='pseudos'><div></div><div></div><div></div><div></div><a></a><div></div><div></div></div>".*;
    try doc.parse(&html);

    const comptime_one = doc.queryOne("#pseudos :nth-child(odd)");
    const runtime_one = try doc.queryOneRuntime(alloc, "#pseudos :nth-child(odd)");
    try std.testing.expect((comptime_one == null) == (runtime_one == null));
    if (comptime_one) |a| {
        try std.testing.expectEqual(a.index, runtime_one.?.index);
    }

    var c_odd: usize = 0;
    var it_odd = try doc.queryAllRuntime(runtime_arena.allocator(), "#pseudos :nth-child(odd)");
    while (it_odd.next()) |_| c_odd += 1;
    try std.testing.expectEqual(@as(usize, 4), c_odd);

    var c_plus: usize = 0;
    var it_plus = try doc.queryAllRuntime(runtime_arena.allocator(), "#pseudos :nth-child(3n+1)");
    while (it_plus.next()) |_| c_plus += 1;
    try std.testing.expectEqual(@as(usize, 3), c_plus);

    var c_signed: usize = 0;
    var it_signed = try doc.queryAllRuntime(runtime_arena.allocator(), "#pseudos :nth-child(+3n-2)");
    while (it_signed.next()) |_| c_signed += 1;
    try std.testing.expectEqual(@as(usize, 3), c_signed);

    var c_neg_a: usize = 0;
    var it_neg_a = try doc.queryAllRuntime(runtime_arena.allocator(), "#pseudos :nth-child(-n+6)");
    while (it_neg_a.next()) |_| c_neg_a += 1;
    try std.testing.expectEqual(@as(usize, 6), c_neg_a);

    var c_neg_b: usize = 0;
    var it_neg_b = try doc.queryAllRuntime(runtime_arena.allocator(), "#pseudos :nth-child(-n+5)");
    while (it_neg_b.next()) |_| c_neg_b += 1;
    try std.testing.expectEqual(@as(usize, 5), c_neg_b);
}

test "leading child combinator works in node-scoped queries" {
    const alloc = std.testing.allocator;
    var runtime_arena = std.heap.ArenaAllocator.init(alloc);
    defer runtime_arena.deinit();

    var frag_doc = Document.init(alloc);
    defer frag_doc.deinit();
    var frag_html =
        "<root><div class='d i v'><p id='oooo'><em></em><em id='emem'></em></p></div><p id='sep'><div class='a'><span></span></div></p></root>".*;
    try frag_doc.parse(&frag_html);
    const frag_root = frag_doc.queryOne("root") orelse return error.TestUnexpectedResult;

    var it_em = try frag_root.queryAllRuntime(runtime_arena.allocator(), "> div p em");
    var em_count: usize = 0;
    while (it_em.next()) |_| em_count += 1;
    try std.testing.expectEqual(@as(usize, 2), em_count);

    var it_oooo = try frag_root.queryAllRuntime(runtime_arena.allocator(), "> div #oooo");
    var oooo_count: usize = 0;
    while (it_oooo.next()) |_| oooo_count += 1;
    try std.testing.expectEqual(@as(usize, 1), oooo_count);

    var doc_ctx = Document.init(alloc);
    defer doc_ctx.deinit();
    var doc_html =
        "<root><div id='hsoob'><div class='a b'><div class='d e sib' id='booshTest'><p><span id='spanny'></span></p></div><em class='sib'></em><span class='h i a sib'></span></div><p class='odd'></p></div><div id='lonelyHsoob'></div></root>".*;
    try doc_ctx.parse(&doc_html);
    const ctx_root = doc_ctx.queryOne("root") orelse return error.TestUnexpectedResult;

    var it_hsoob = try ctx_root.queryAllRuntime(runtime_arena.allocator(), "> #hsoob");
    var hsoob_count: usize = 0;
    while (it_hsoob.next()) |_| hsoob_count += 1;
    try std.testing.expectEqual(@as(usize, 1), hsoob_count);
}

test "parse option bundles preserve selector/query behavior for representative input" {
    const alloc = std.testing.allocator;

    var strict_doc = StrictDocument.init(alloc);
    defer strict_doc.deinit();
    var fast_doc = Document.init(alloc);
    defer fast_doc.deinit();

    var strict_html = ("<html><body>" ++
        "<div id='x' class='alpha beta' data-k='v' data-q='1>2'>x</div>" ++
        "<img id='im' src='a.png' />" ++
        "<a id='a1' href='https://example.com' class='nav button'>ok</a>" ++
        "<p id='p1'>a<span id='s1'>b</span></p>" ++
        "<div id='e' a= ></div>" ++
        "</body></html>").*;
    var fast_html = strict_html;

    try strict_doc.parse(&strict_html);
    try fast_doc.parse(&fast_html);

    const selectors = [_][]const u8{
        "div#x[data-k=v]",
        "img#im",
        "a[href^=https][class*=button]:not(.missing)",
        "p#p1 > span#s1",
        "div[a]",
    };

    for (selectors) |sel| {
        const a = try strict_doc.queryOneRuntime(alloc, sel);
        const b = try fast_doc.queryOneRuntime(alloc, sel);
        try std.testing.expect((a == null) == (b == null));
    }

    const strict_empty = (strict_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    const fast_empty = (fast_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(strict_empty, fast_empty);
}

test "children() iterator traverses sibling-chain nodes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span></div>".*;
    try doc.parse(&html);

    const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    var kids = root.children();
    const nodes = try kids.collect(alloc);
    defer alloc.free(nodes);
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("a", nodes[0].getAttributeValue("id").?);
    try std.testing.expectEqualStrings("b", nodes[1].getAttributeValue("id").?);

    var again = root.children();
    const nodes_again = try again.collect(alloc);
    defer alloc.free(nodes_again);
    try std.testing.expectEqual(@as(usize, 2), nodes_again.len);
}

test "children() collect respects iterator progress" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span><span id='c'></span></div>".*;
    try doc.parse(&html);

    const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    var kids = root.children();
    const first = kids.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", first.getAttributeValue("id").?);

    const rest = try kids.collect(alloc);
    defer alloc.free(rest);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("b", rest[0].getAttributeValue("id").?);
    try std.testing.expectEqualStrings("c", rest[1].getAttributeValue("id").?);
}

test "unquoted attribute values preserve slash characters" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<a id=x href=/docs/v1/api data-path=assets/img/logo.svg></a>".*;
    try doc.parse(&html);

    const node = doc.queryOne("a#x") orelse return error.TestUnexpectedResult;
    const href = node.getAttributeValue("href") orelse return error.TestUnexpectedResult;
    const data_path = node.getAttributeValue("data-path") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("/docs/v1/api", href);
    try std.testing.expectEqualStrings("assets/img/logo.svg", data_path);
    try std.testing.expect(doc.queryOne("a[href='/docs/v1/api'][data-path='assets/img/logo.svg']") != null);
}

test "moved document keeps node-scoped queries and navigation valid" {
    const alloc = std.testing.allocator;
    var html = "<root><div id='a'><span id='b'></span></div></root>".*;
    var doc = try parseViaMove(alloc, &html);
    defer doc.deinit();

    const a = doc.queryOne("#a") orelse return error.TestUnexpectedResult;
    const b = a.queryOne("span#b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("span", b.tagName());
    try std.testing.expectEqual(@as(IndexInt, a.index), b.parentNode().?.index);
}

test "clear resets parsed state and ownership tracking" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div><a id='x'></a><a id='y'></a></div>".*;
    try doc.parse(&html_a);

    var html_b = "<main><p id='z'>owned</p></main>".*;
    try doc.parse(&html_b);
    try std.testing.expect(doc.queryOne("main") != null);
    try std.testing.expect(doc.queryOne("#x") == null);

    const text_before_clear = (doc.queryOne("#z") orelse return error.TestUnexpectedResult)
        .innerTextWithOptions(alloc, .{ .normalize_whitespace = false }) catch return error.TestUnexpectedResult;
    try std.testing.expect(doc.isOwned(text_before_clear));

    doc.clear();
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.source.len);
    try std.testing.expect(!doc.isOwned(text_before_clear));
    try std.testing.expect(doc.queryOne("main") == null);
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

    var doc = Document.init(alloc);
    defer doc.deinit();
    try doc.parse(html);

    const selector = "a[href^=https][class*=button]:not(.missing)";
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const compiled = try ast.Selector.compileRuntime(arena.allocator(), selector);
    var loops: usize = 0;
    while (loops < 256) : (loops += 1) {
        const a = try doc.queryOneRuntime(alloc, selector);
        const b = doc.queryOneCached(compiled);
        try std.testing.expect((a == null) == (b == null));
    }
    try std.testing.expectEqual(0, doc.nodes.items[1].parent);
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

        var doc = Document.init(alloc);
        defer doc.deinit();
        try doc.parse(html);

        var loops: usize = 0;
        while (loops < 32) : (loops += 1) {
            const a = try doc.queryOneRuntime(alloc, selector);
            const b = doc.queryOneCached(compiled);
            try std.testing.expect((a == null) == (b == null));
        }
        try std.testing.expectEqual(0, doc.nodes.items[1].parent);
    }

    {
        const html = try alloc.dupe(u8, fixture);
        defer alloc.free(html);

        var doc = Document.init(alloc);
        defer doc.deinit();
        try doc.parse(html);

        var loops: usize = 0;
        while (loops < 32) : (loops += 1) {
            const a = try doc.queryOneRuntime(alloc, selector);
            const b = doc.queryOneCached(compiled);
            try std.testing.expect((a == null) == (b == null));
        }
        try std.testing.expectEqual(0, doc.nodes.items[1].parent);
    }
}

test "queryOneRuntimeDebug reports runtime selector parse errors" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x'></div>".*;
    try doc.parse(&html);

    const result = doc.queryOneRuntimeDebug(alloc, "div[");
    try std.testing.expectEqual(@as(?runtime_selector.Error, error.InvalidSelector), result.err);
    try std.testing.expect(result.report.runtime_parse_error);
    try std.testing.expectEqualStrings("div[", result.report.selector_source);
}

test "queryOneDebug reports near misses and matched index" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><a id='x' class='k'></a><a id='y'></a></div>".*;
    try doc.parse(&html);

    const miss = doc.queryOneDebug("a[href^=https]");
    try std.testing.expect(miss.err == null);
    try std.testing.expect(miss.node == null);
    try std.testing.expect(miss.report.visited_elements > 0);
    try std.testing.expect(miss.report.near_miss_len > 0);
    try std.testing.expect(miss.report.near_misses[0].reason.kind != .none);

    const hit = doc.queryOneDebug("a#x");
    const hit_node = hit.node orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(hit_node.index, hit.report.matched_index);
    try std.testing.expectEqual(@as(u16, 0), hit.report.matched_group);
}

test "node-scoped runtime debug query reports scope/combinator failures" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<root><div><span id='inside'></span></div><span id='outside'></span></root>".*;
    try doc.parse(&html);

    const root = doc.queryOne("root") orelse return error.TestUnexpectedResult;
    const found = root.queryOneRuntimeDebug(alloc, "> span#inside");
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
    last_query_kind: instrumentation.QueryInstrumentationKind = .one_runtime,
    last_selector_len: usize = 0,
    last_parse_stats: instrumentation.ParseInstrumentationStats = .{
        .elapsed_ns = 0,
        .input_len = 0,
        .node_count = 0,
    },
    last_query_stats: instrumentation.QueryInstrumentationStats = .{
        .elapsed_ns = 0,
        .selector_len = 0,
        .kind = .one_runtime,
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
    var doc = Document.init(alloc);
    defer doc.deinit();
    var hooks: HookProbe = .{};

    var html = "<div><a id='x' href='https://example'></a></div>".*;
    try instrumentation.parseWithHooks(std.testing.io, &doc, &html, &hooks);
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_start_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_end_calls);
    try std.testing.expect(hooks.last_parse_stats.elapsed_ns > 0);
    try std.testing.expectEqual(html.len, hooks.last_input_len);
    try std.testing.expect(hooks.last_parse_stats.node_count >= 2);

    const runtime_one = try instrumentation.queryOneRuntimeWithHooks(std.testing.io, &doc, alloc, "a#x", &hooks);
    try std.testing.expect(runtime_one != null);
    try std.testing.expectEqual(instrumentation.QueryInstrumentationKind.one_runtime, hooks.last_query_kind);
    try std.testing.expectEqual(@as(?bool, true), hooks.last_query_stats.matched);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "a#x");

    const cached_one = instrumentation.queryOneCachedWithHooks(std.testing.io, &doc, sel, &hooks);
    try std.testing.expect(cached_one != null);
    try std.testing.expectEqual(instrumentation.QueryInstrumentationKind.one_cached, hooks.last_query_kind);
    try std.testing.expectEqual(@as(?bool, true), hooks.last_query_stats.matched);

    _ = try instrumentation.queryAllRuntimeWithHooks(std.testing.io, &doc, arena.allocator(), "a", &hooks);
    try std.testing.expectEqual(instrumentation.QueryInstrumentationKind.all_runtime, hooks.last_query_kind);
    try std.testing.expectEqual(@as(?bool, null), hooks.last_query_stats.matched);

    _ = instrumentation.queryAllCachedWithHooks(std.testing.io, &doc, sel, &hooks);
    try std.testing.expectEqual(instrumentation.QueryInstrumentationKind.all_cached, hooks.last_query_kind);
    try std.testing.expectEqual(@as(?bool, null), hooks.last_query_stats.matched);
    try std.testing.expect(hooks.query_start_calls >= 4);
    try std.testing.expect(hooks.query_end_calls >= 4);
}

test "format document types" {
    const alloc = std.testing.allocator;

    const opts: ParseOptions = .{ .drop_whitespace_text_nodes = false };
    const opts_out = try std.fmt.allocPrint(alloc, "{f}", .{opts});
    defer alloc.free(opts_out);
    try std.testing.expectEqualStrings("ParseOptions{drop_whitespace_text_nodes=false, non_destructive=false}", opts_out);

    const span: Span = .{ .start = 2, .end = 5 };
    const span_out = try std.fmt.allocPrint(alloc, "{f}", .{span});
    defer alloc.free(span_out);
    try std.testing.expectEqualStrings("Span{start=2, end=5}", span_out);

    var doc = Document.init(alloc);
    defer doc.deinit();
    var src = "<div><span></span><span></span></div>".*;
    try doc.parse(&src);

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    const qit = div.queryAll("span");
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
