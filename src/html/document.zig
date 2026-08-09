// we can reduce the size of the raw node further!?
// doubt it's possible; Would be crazy tho.
const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const tables = @import("tables.zig");
const attr = @import("attr.zig");
const entities = @import("entities.zig");
const tags = @import("tags.zig");
const ast = @import("../selector/ast.zig");
const matcher = @import("../selector/matcher.zig");
const forward = @import("../selector/forward.zig");
const prepared_selector = @import("../selector/prepared.zig");
const parser = @import("parser.zig");
const common = @import("../common.zig");
const IndexInt = common.IndexInt;

/// Sentinel used for missing node indexes and invalid spans.
pub const InvalidIndex: IndexInt = common.InvalidIndex;

var next_document_generation: std.atomic.Value(u64) = .init(1);
var next_document_generation_32: u64 = 1;
var document_generation_lock: std.atomic.Mutex = .unlocked;

fn freshDocumentGeneration() u64 {
    if (comptime @sizeOf(usize) >= @sizeOf(u64)) {
        var generation = next_document_generation.fetchAdd(1, .monotonic);
        if (generation == 0) generation = next_document_generation.fetchAdd(1, .monotonic);
        return generation;
    }

    // 32-bit targets cannot issue a native 64-bit atomic RMW in Zig. Document
    // creation/clear is cold compared with parsing and matching, so preserve the
    // full 64-bit generation space behind a tiny lock instead of narrowing the
    // public invalidation token.
    while (!document_generation_lock.tryLock()) std.atomic.spinLoopHint();
    defer document_generation_lock.unlock();
    var generation = next_document_generation_32;
    next_document_generation_32 +%= 1;
    if (generation == 0) {
        generation = next_document_generation_32;
        next_document_generation_32 +%= 1;
    }
    return generation;
}

/// Controls entity handling during HTML serialization.
pub const EntityEncoding = enum {
    /// Serialize the currently stored bytes without additional entity work.
    never,
    /// Re-encode only text already decoded in a destructive document.
    auto,
    /// Decode and canonically re-encode escapable text and attribute values.
    force,
};
pub const EntityDecoding = entities.EntityDecoding;
/// Inclusive-exclusive byte span into the document source buffer.
pub const Span = common.Span;

/// Destructive text spans use the byte immediately after the span as a lazy
/// materialization marker. Parser text is followed by whitespace, `<`, or NUL,
/// so these non-delimiter bytes are unambiguous after tree construction.
const RwTextState = enum(u8) {
    decode_failed = 1,
    raw_normalized = 2,
    decoded = 3,
    raw = 0xff,
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
    /// Selects the named-character-reference set; numeric references are always enabled.
    entity_decoding: EntityDecoding = .common,
    /// Persist direct last-child links for O(1) `children().last()`.
    /// Off by default because first child and next sibling are already bounded.
    store_last_child: bool = false,
    /// Persist previous-sibling links for O(1) `prevSibling()` and sibling selectors.
    store_prev_sibling: bool = false,

    /// Returns the accepted parse input slice type for this option set.
    pub fn Input(options: @This()) type {
        return if (options.non_destructive) []const u8 else []u8;
    }

    /// Returns the lightweight node wrapper type bound to this option set.
    pub fn Node(options: @This()) type {
        return GetNode(options);
    }

    /// Returns the lazy query iterator type for this option set.
    pub fn QueryIter(options: @This()) type {
        return GetQueryIter(options);
    }

    /// Returns direct-child iterator type for this option set.
    pub fn ChildrenIter(options: @This()) type {
        return GetChildrenIter(options);
    }

    /// Parses borrowed `input`; the returned document owns node storage only.
    pub fn parse(comptime options: @This(), gpa: std.mem.Allocator, input: options.Input()) !options.Document() {
        return parser.parse(options, gpa, input);
    }

    /// Returns the document type (parser + query surface) for this option set.
    pub fn Document(options: @This()) type {
        return GetDocument(options);
    }

    /// Formats parse options for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ParseOptions{{drop_whitespace_text_nodes={s}, non_destructive={}, entity_decoding={s}, store_last_child={}, store_prev_sibling={}}}", .{
            @tagName(self.drop_whitespace_text_nodes),
            self.non_destructive,
            @tagName(self.entity_decoding),
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

/// Builds the concrete node wrapper type for a parse option set.
fn GetNode(comptime options: ParseOptions) type {
    return struct {
        //! Public node wrapper that carries document pointer + node index.
        const RawNodeType = GetRawNode(options);
        const DocType = options.Document();
        const ChildrenIterType = GetChildrenIter(options);
        const QueryIterType = GetQueryIter(options);
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

        pub const TextResult = common.SliceResult;
        pub const AttributeValueResult = common.SliceResult;

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
            self.assertText();
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
                        }), .owned = true };
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
                    }), .owned = true };
                }

                break :blk first_idx;
            };

            const node = &self.doc.nodes[first_idx];

            if (comptime (options.non_destructive and (opts.unescape or opts.normalize_whitespace))) {
                return .{ .value = try self.innerTextOwnedFromScan(gpa, opts, .{
                    .first_idx = first_idx,
                    .resume_idx = first_idx + 1,
                }), .owned = true };
            }

            if (comptime opts.unescape or opts.normalize_whitespace) {
                const state = materializeRwText(doc, first_idx, opts.unescape, opts.normalize_whitespace);
                if (comptime opts.unescape) {
                    if (state == .decode_failed) {
                        return .{ .value = try self.innerTextOwnedFromScan(gpa, opts, .{
                            .first_idx = first_idx,
                            .resume_idx = first_idx + 1,
                        }), .owned = true };
                    }
                }
            }

            return .{ .value = node.name_or_text.slice(self.doc.source) };
        }

        /// Materializes text by scanning all text descendants from a known first text node.
        fn innerTextOwnedFromScan(self: @This(), gpa: std.mem.Allocator, comptime opts: Self.TextOptions, scan: TextScan) ![]const u8 {
            const doc = self.doc;
            const node_raw = self.raw();

            var total: usize = 0;
            var have_text = false;
            {
                // Materialize destructive text while sizing the owned result.
                // This used to be a separate full subtree walk before this pass.
                if (comptime !options.non_destructive and opts.unescape) {
                    _ = materializeRwText(doc, scan.first_idx, true, false);
                }
                const first_slice = doc.nodes[scan.first_idx].name_or_text.slice(doc.source);
                if (first_slice.len != 0) {
                    total = first_slice.len;
                    if (shouldDecodeOwnedText(doc, scan.first_idx, opts)) {
                        total = try std.math.add(usize, total, entities.expansionExtraWithMode(options.entity_decoding, false, first_slice));
                    }
                    have_text = true;
                }

                var idx = scan.resume_idx;
                while (idx <= node_raw.subtree_end and idx < doc.nodes.len) : (idx += 1) {
                    if (!doc.nodeAt(idx).isText()) continue;
                    if (comptime !options.non_destructive and opts.unescape) {
                        _ = materializeRwText(doc, idx, true, false);
                    }
                    const slice = doc.nodes[idx].name_or_text.slice(doc.source);
                    if (slice.len == 0) continue;
                    if (have_text) total = try std.math.add(usize, total, 1);
                    total = try std.math.add(usize, total, slice.len);
                    if (shouldDecodeOwnedText(doc, idx, opts)) {
                        total = try std.math.add(usize, total, entities.expansionExtraWithMode(options.entity_decoding, false, slice));
                    }
                    have_text = true;
                }
            }

            var out = try std.ArrayList(u8).initCapacity(gpa, total);
            errdefer out.deinit(gpa);

            appendOwnedText(&out, doc, scan.first_idx, opts);
            var idx = scan.resume_idx;
            while (idx <= node_raw.subtree_end and idx < doc.nodes.len) : (idx += 1) {
                if (!doc.nodeAt(idx).isText()) continue;
                appendOwnedText(&out, doc, idx, opts);
            }

            return try finishInnerTextOwned(&out, gpa, opts, opts.unescape, false);
        }

        /// Appends one text node to an owned result, decoding RO text per node
        /// so raw-text parents never pass through the entity decoder.
        fn appendOwnedText(out: *std.ArrayList(u8), doc: anytype, idx: IndexInt, comptime opts: Self.TextOptions) void {
            const slice = doc.nodes[idx].name_or_text.slice(doc.source);
            if (slice.len == 0) return;
            if (out.items.len != 0 and !tables.WhitespaceTable[out.items[out.items.len - 1]]) out.appendAssumeCapacity(' ');
            if (shouldDecodeOwnedText(doc, idx, opts)) {
                entities.appendDecodedAssumeCapacityWithMode(options.entity_decoding, false, out, slice);
            } else {
                out.appendSliceAssumeCapacity(slice);
            }
        }

        fn shouldDecodeOwnedText(doc: anytype, idx: IndexInt, comptime opts: Self.TextOptions) bool {
            if (comptime !opts.unescape) return false;
            if (isOpaqueTextNode(doc, idx)) return false;
            if (comptime options.non_destructive) return true;

            const state = rwTextState(doc, idx);
            if (state == .decode_failed) return true;
            if (state != .raw) return false;

            // EOF text has no following byte in which to persist the RW marker.
            // By the time this helper is used by the owned multi-text path the
            // span has already been materialized. Only an expanding reference
            // can therefore still require the allocating decoder.
            const node = &doc.nodes[idx];
            if (node.name_or_text.end() < doc.source.len) return false;
            return entities.expansionExtraWithMode(options.entity_decoding, false, node.name_or_text.slice(doc.source)) != 0;
        }

        /// Applies final text decoding/normalization and transfers buffer ownership.
        fn finishInnerTextOwned(
            noalias out: *std.ArrayList(u8),
            gpa: std.mem.Allocator,
            comptime opts: Self.TextOptions,
            comptime already_decoded: bool,
            comptime already_normalized: bool,
        ) ![]const u8 {
            if (comptime opts.unescape and !already_decoded) {
                out.items.len = entities.decodeInPlaceWithMode(options.entity_decoding, opts.normalize_whitespace and !already_normalized, out.items);
            } else if (comptime opts.normalize_whitespace and !already_normalized) {
                out.items.len = entities.normalizeWhitespaceInPlace(out.items);
            }
            return try out.toOwnedSlice(gpa);
        }

        /// Owned variant of `innerTextWithOptions`.
        pub fn innerTextOwnedWithOptions(self: @This(), gpa: std.mem.Allocator, comptime opts: Self.TextOptions) ![]const u8 {
            const result = try self.innerTextWithOptions(gpa, opts);
            if (result.owned) return result.value;
            return try gpa.dupe(u8, result.value);
        }

        /// Decodes and/or normalizes one RW text span. Expanding references are
        /// never partially written in place: they leave the raw span intact and
        /// store `.decode_failed` after it so callers can take an owned/streaming
        /// fallback without retrying an unsafe forward decode.
        fn materializeRwText(doc: anytype, idx: IndexInt, comptime unescape: bool, comptime normalize: bool) RwTextState {
            if (comptime options.non_destructive) return .raw;
            const node = &doc.nodes[idx];
            var state = rwTextState(doc, idx);

            if (comptime unescape) {
                if (state != .decoded and !isOpaqueTextNode(doc, idx)) {
                    if (state != .decode_failed) {
                        const result = entities.decodeInPlaceResultWithMode(options.entity_decoding, false, node.name_or_text.sliceMut(doc.source));
                        if (result.complete) {
                            node.name_or_text.len = @intCast(result.len);
                            state = .decoded;
                        } else {
                            state = .decode_failed;
                        }
                    }
                }
            }
            if (comptime normalize) {
                // When unescape was requested and failed, normalization belongs
                // after the allocating decode fallback, not before it.
                if (!unescape or state != .decode_failed) {
                    const new_len = entities.normalizeWhitespaceInPlace(node.name_or_text.sliceMut(doc.source));
                    node.name_or_text.len = @intCast(new_len);
                    if (state != .decoded) state = .raw_normalized;
                }
            }

            markRwTextState(doc, node, state);
            return state;
        }

        fn rwTextState(doc: anytype, idx: IndexInt) RwTextState {
            if (comptime options.non_destructive) return .raw;
            const node = &doc.nodes[idx];
            const end: usize = node.name_or_text.end();
            if (end >= doc.source.len) return .raw;
            return switch (doc.source[end]) {
                @intFromEnum(RwTextState.decoded) => .decoded,
                @intFromEnum(RwTextState.decode_failed) => .decode_failed,
                @intFromEnum(RwTextState.raw_normalized) => .raw_normalized,
                else => .raw,
            };
        }

        fn markRwTextState(doc: anytype, node: anytype, state: RwTextState) void {
            if (comptime options.non_destructive) return;
            if (state == .raw) return;
            const end: usize = node.name_or_text.end();
            if (end < doc.source.len) doc.source[end] = @intFromEnum(state);
        }

        /// Opaque children preserve both markup-looking bytes and entity syntax.
        fn isOpaqueTextNode(doc: anytype, idx: IndexInt) bool {
            const parent = doc.nodes[idx].parent;
            if (parent == InvalidIndex or parent == 0 or parent >= doc.nodes.len) return false;
            const parent_name = doc.nodes[parent].name_or_text.slice(doc.source);
            const key = tags.first8KeyWithMode(parent_name, options.non_destructive);
            return tags.isRawTextTagWithKey(parent_name, key) or
                tags.isPlainTextTagWithKey(parent_name, key) or
                tags.isSvgWithKey(parent_name, key);
        }

        /// Returns decoded attribute value for `name`, if present.
        pub fn getAttributeValue(self: @This(), allocator: std.mem.Allocator, name: []const u8) !?AttributeValueResult {
            self.assertElement();
            return attr.getAttrValue(self.doc, &self.doc.nodes[self.index], name, allocator);
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

        const TextScan = struct {
            first_idx: IndexInt,
            resume_idx: IndexInt,
        };

        /// Writes HTML serialization of this node and its subtree to `writer`.
        pub fn writeHtml(self: @This(), writer: anytype, comptime entity_encoding: EntityEncoding) WriterError(@TypeOf(writer))!void {
            try writeNodeHtml(self.doc, self.index, self.raw(), writer, true, entity_encoding);
        }

        /// Writes HTML serialization of this node only, excluding its children.
        pub fn writeSelfHtml(self: @This(), writer: anytype, comptime entity_encoding: EntityEncoding) WriterError(@TypeOf(writer))!void {
            try writeNodeHtml(self.doc, self.index, self.raw(), writer, false, entity_encoding);
        }

        /// Default formatter uses HTML serialization for this node.
        pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.writeHtml(writer, .never);
        }

        /// Writes one node as HTML, optionally including its full subtree.
        fn writeNodeHtml(
            doc: anytype,
            idx: IndexInt,
            noalias node_raw: anytype,
            writer: anytype,
            include_children: bool,
            comptime entity_encoding: EntityEncoding,
        ) WriterError(@TypeOf(writer))!void {
            if (node_raw.isText(idx)) {
                try writeTextHtml(doc, idx, node_raw, writer, entity_encoding);
                return;
            }

            if (idx != 0) {
                try writeElementOpenHtml(doc, node_raw, writer, entity_encoding);
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
                    try writeTextHtml(doc, next_idx, child, writer, entity_encoding);
                    continue;
                }

                try writeElementOpenHtml(doc, child, writer, entity_encoding);
                if (isVoidElement(doc, child)) continue;
                if (child.subtree_end == next_idx) {
                    try writeElementCloseHtml(doc, child, writer);
                    continue;
                }
                open_idx = next_idx;
            }

            while (open_idx != InvalidIndex) {
                try writeElementCloseHtml(doc, &doc.nodes[open_idx], writer);
                if (open_idx == idx) break;
                const parent = doc.nodes[open_idx].parent;
                open_idx = if (parent != InvalidIndex and parent != 0) parent else InvalidIndex;
            }
        }

        fn writeTextHtml(doc: anytype, idx: IndexInt, node_raw: anytype, writer: anytype, comptime entity_encoding: EntityEncoding) WriterError(@TypeOf(writer))!void {
            const raw_text = isOpaqueTextNode(doc, idx);
            const state = if (comptime options.non_destructive)
                RwTextState.raw
            else if (comptime entity_encoding == .force)
                materializeRwText(doc, idx, true, false)
            else
                rwTextState(doc, idx);
            const text_bytes = node_raw.name_or_text.slice(doc.source);
            if (comptime entity_encoding == .force) {
                if (raw_text) return writer.writeAll(text_bytes);
                if (comptime options.non_destructive) return writeDecodedEscaped(writer, text_bytes, false);
                if (state == .decode_failed) return writeDecodedEscaped(writer, text_bytes, false);
                return writeEscapedText(writer, text_bytes);
            }
            if (comptime entity_encoding == .auto) {
                if (!options.non_destructive and !raw_text and state == .decoded) return writeEscapedText(writer, text_bytes);
            }
            return writer.writeAll(text_bytes);
        }

        /// Writes an element start tag and its serialized attributes.
        fn writeElementOpenHtml(doc: anytype, noalias node_raw: anytype, writer: anytype, comptime entity_encoding: EntityEncoding) WriterError(@TypeOf(writer))!void {
            const name = node_raw.name_or_text.slice(doc.source);
            try writeByte(writer, '<');
            try writer.writeAll(name);
            try writeAttrsHtml(doc, node_raw, writer, entity_encoding);
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
            return tags.isVoidTagWithKey(name, tags.first8KeyWithMode(name, options.non_destructive));
        }

        /// Writes serialized attributes from raw or destructively parsed attr bytes.
        fn writeAttrsHtml(doc: anytype, noalias node_raw: anytype, writer: anytype, comptime entity_encoding: EntityEncoding) WriterError(@TypeOf(writer))!void {
            const i: usize = @intCast(node_raw.name_or_text.end());
            if (comptime !options.non_destructive) {
                attr.materializeAttributes(options.entity_decoding, doc.source, i);
                const source: []const u8 = doc.source;
                var it: attr.CompactIterator = .{ .source = source, .cursor = i };
                while (it.next()) |item| {
                    try writeAttrName(writer, item.name);
                    if (item.value) |value| {
                        if (item.isDecoded()) {
                            try writeAttrValue(writer, value);
                        } else {
                            try writer.writeAll("=\"");
                            try writeDecodedEscaped(writer, value, true);
                            try writeByte(writer, '"');
                        }
                    }
                }
                return;
            }

            const source: []const u8 = doc.source;
            var it: attr.RawIterator = .{ .source = source, .cursor = i, .end = source.len };
            while (it.next()) |item| {
                const value_raw = item.value orelse {
                    try writeAttrName(writer, item.name);
                    continue;
                };
                if (comptime entity_encoding == .force) {
                    try writeAttrName(writer, item.name);
                    try writer.writeAll("=\"");
                    try writeDecodedEscaped(writer, source[value_raw.start..value_raw.end], true);
                    try writeByte(writer, '"');
                } else {
                    try writeByte(writer, ' ');
                    try writer.writeAll(source[item.name_start..value_raw.next_start]);
                }
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
            var chunk_start: usize = 0;
            for (value, 0..) |c, i| {
                switch (c) {
                    0, '&', '<', '"' => {
                        if (chunk_start < i) try writer.writeAll(value[chunk_start..i]);
                        switch (c) {
                            0 => try writer.writeAll(" "),
                            '&' => try writer.writeAll("&amp;"),
                            '<' => try writer.writeAll("&lt;"),
                            '"' => try writer.writeAll("&quot;"),
                            else => unreachable,
                        }
                        chunk_start = i + 1;
                    },
                    else => {},
                }
            }
            if (chunk_start < value.len) try writer.writeAll(value[chunk_start..]);
        }

        /// Escapes decoded text bytes that can be interpreted as HTML markup.
        fn writeEscapedText(writer: anytype, value: []const u8) WriterError(@TypeOf(writer))!void {
            var chunk_start: usize = 0;
            for (value, 0..) |c, i| {
                switch (c) {
                    '&', '<', '>' => {
                        if (chunk_start < i) try writer.writeAll(value[chunk_start..i]);
                        switch (c) {
                            '&' => try writer.writeAll("&amp;"),
                            '<' => try writer.writeAll("&lt;"),
                            '>' => try writer.writeAll("&gt;"),
                            else => unreachable,
                        }
                        chunk_start = i + 1;
                    },
                    else => {},
                }
            }
            if (chunk_start < value.len) try writer.writeAll(value[chunk_start..]);
        }

        fn writeDecodedEscaped(writer: anytype, value: []const u8, comptime attribute: bool) WriterError(@TypeOf(writer))!void {
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, value, i, '&')) |amp| {
                if (amp > i) {
                    if (comptime attribute) try writeEscapedAttrValue(writer, value[i..amp]) else try writeEscapedText(writer, value[i..amp]);
                }
                // Decode only references present in the original input. Bytes
                // emitted by a decoded reference are written and never rescanned.
                const decoded_entity_opt = entities.decodeEntityWithMode(options.entity_decoding, attribute, value[amp + 1 ..]);
                if (decoded_entity_opt) |decoded_entity| {
                    const decoded = decoded_entity.bytes[0..decoded_entity.len];
                    if (comptime attribute) try writeEscapedAttrValue(writer, decoded) else try writeEscapedText(writer, decoded);
                    i = amp + decoded_entity.consumed;
                } else {
                    if (comptime attribute) try writeEscapedAttrValue(writer, "&") else try writeEscapedText(writer, "&");
                    i = amp + 1;
                }
            }
            if (i < value.len) {
                if (comptime attribute) try writeEscapedAttrValue(writer, value[i..]) else try writeEscapedText(writer, value[i..]);
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

        /// Returns whether this element itself matches `selector`.
        /// Unlike scoped `query`, `matches` accepts complete selectors only;
        /// leading relative combinators are rejected rather than reinterpreted
        /// as a relation to an implicit scope node.
        pub fn matches(self: @This(), comptime selector: []const u8) !bool {
            const sel = comptime ast.Selector.compile(selector);
            if (comptime hasLeadingCombinator(sel)) return error.InvalidSelector;
            if (!self.isElement()) return false;
            return matcher.matchesSelectorAt(DocType, self.doc, sel, self.index, InvalidIndex);
        }

        /// Runtime-compiled equivalent of `matches`.
        pub fn matchesRuntime(self: @This(), sel: ast.Selector) !bool {
            if (hasLeadingCombinator(sel)) return error.InvalidSelector;
            if (!self.isElement()) return false;
            return matcher.matchesSelectorAt(DocType, self.doc, sel, self.index, InvalidIndex);
        }

        /// Prepared-program equivalent of `matchesRuntime`.
        pub fn matchesPrepared(self: @This(), prepared: *const prepared_selector.PreparedSelector) !bool {
            const sel = prepared.selector;
            if (hasLeadingCombinator(sel)) return error.InvalidSelector;
            if (!self.isElement()) return false;
            return matcher.matchesSelectorAtPrepared(
                DocType,
                self.doc,
                sel,
                &prepared.execution_plan,
                self.index,
                InvalidIndex,
            );
        }

        fn hasLeadingCombinator(sel: ast.Selector) bool {
            for (sel.groups) |group| {
                if (group.compound_len == 0) continue;
                if (sel.compounds[group.compound_start].combinator != .none) return true;
            }
            return false;
        }

        /// Compiles selector at comptime and returns lazy descendant iterator.
        /// Call `deinit` when stopping before exhaustion to release retained matcher scratch.
        pub fn query(self: @This(), comptime selector: []const u8) QueryIterType {
            const sel = comptime ast.Selector.compile(selector);
            const plan = comptime forward.buildPlan(sel);
            if (self.doc.nodes.len == 0) return self.emptyQueryIter(sel, plan);
            self.assertContainer();
            return self.queryIter(sel, plan);
        }

        /// Returns lazy descendant iterator for already compiled selector.
        /// Call `deinit` when stopping before exhaustion to release retained matcher scratch.
        pub fn queryRuntime(self: @This(), sel: ast.Selector) QueryIterType {
            const plan = forward.buildPlan(sel);
            if (self.doc.nodes.len == 0) return self.emptyQueryIter(sel, plan);
            self.assertContainer();
            return self.queryIter(sel, plan);
        }

        /// Returns a lazy descendant iterator using a reusable prepared runtime selector.
        /// `prepared` must outlive the iterator.
        pub fn queryPrepared(self: @This(), prepared: *const prepared_selector.PreparedSelector) QueryIterType {
            if (self.doc.nodes.len == 0) return QueryIterType.initPrepared(self.doc, prepared, InvalidIndex, 1, 1);
            self.assertContainer();
            return QueryIterType.initPrepared(self.doc, prepared, self.index, self.index + 1, self.raw().subtree_end + 1);
        }

        /// Creates an exhausted iterator for empty documents.
        fn emptyQueryIter(self: @This(), sel: ast.Selector, plan: forward.Plan) QueryIterType {
            return QueryIterType.init(self.doc, sel, plan, InvalidIndex, 1, 1);
        }

        /// Creates a scoped query iterator rooted at this node.
        fn queryIter(self: *const @This(), sel: ast.Selector, plan: forward.Plan) QueryIterType {
            return QueryIterType.init(self.doc, sel, plan, self.index, self.index + 1, self.raw().subtree_end + 1);
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

    var first_idx: usize = @as(usize, @intCast(parent_idx)) + 1;
    const end: usize = @min(@as(usize, @intCast(parent.subtree_end)), doc.nodes.len - 1);
    while (first_idx <= end) : (first_idx += 1) {
        const first_int: IndexInt = @intCast(first_idx);
        const first = &doc.nodes[first_idx];
        if (first.parent == parent_idx and first.isElement(first_int)) return first_int;
    }

    return InvalidIndex;
}

/// Builds the concrete selector iterator type for a parse option set.
fn GetQueryIter(comptime options: ParseOptions) type {
    return struct {
        //! Lazy selector iterator over document or scoped subtree matches.
        //! Matcher scratch is retained across `next` calls and freed on exhaustion or `deinit`.
        const DocType = options.Document();
        const NodeTypeWrapper = GetNode(options);
        const ForwardExecutor = forward.Executor(DocType);
        const WideForwardExecutor = forward.WideExecutor(DocType);
        const Engine = union(enum) {
            compact: ForwardExecutor,
            wide: WideForwardExecutor,
        };

        /// Owning document pointer.
        doc: *const DocType,
        /// Document generation captured when the iterator is created.
        doc_generation: u64,
        /// Address of the iterator value that first called `next`. Once matcher
        /// scratch exists the iterator is address-stable; copied or moved started
        /// iterators are rejected instead of aliasing/freed twice.
        owner_address: usize = 0,
        /// Optional subtree root for scoped queries.
        scope_root: IndexInt = InvalidIndex,
        /// Next node index to test.
        next_index: IndexInt = 1,
        /// Exclusive traversal bound for `next_index`.
        end_index: IndexInt = 1,
        engine: Engine,

        fn init(doc: *const DocType, selector: ast.Selector, plan: forward.Plan, scope_root: IndexInt, next_index: IndexInt, end_index: IndexInt) @This() {
            const use_wide = selector.compounds.len > forward.MaxForwardCompounds;
            return .{
                .doc = doc,
                .doc_generation = doc.generation,
                .scope_root = scope_root,
                .next_index = next_index,
                .end_index = end_index,
                .engine = if (use_wide)
                    .{ .wide = WideForwardExecutor.init(doc, selector, plan, scope_root) }
                else
                    .{ .compact = ForwardExecutor.init(doc, selector, plan, scope_root) },
            };
        }

        fn initPrepared(doc: *const DocType, prepared: *const prepared_selector.PreparedSelector, scope_root: IndexInt, next_index: IndexInt, end_index: IndexInt) @This() {
            const selector = prepared.selector;
            const plan = prepared.compact_plan;
            const use_wide = selector.compounds.len > forward.MaxForwardCompounds;
            return .{
                .doc = doc,
                .doc_generation = doc.generation,
                .scope_root = scope_root,
                .next_index = next_index,
                .end_index = end_index,
                .engine = if (use_wide)
                    .{ .wide = WideForwardExecutor.initPrepared(doc, selector, plan, scope_root, &prepared.execution_plan) }
                else
                    .{ .compact = ForwardExecutor.init(doc, selector, plan, scope_root) },
            };
        }

        /// Releases matcher scratch if iteration stops before exhaustion.
        pub fn deinit(noalias self: *@This()) void {
            if (self.owner_address != 0 and self.owner_address != @intFromPtr(self)) return;
            switch (self.engine) {
                .compact => |*executor| executor.deinit(),
                .wide => |*executor| executor.deinit(),
            }
            self.owner_address = 0;
        }

        fn claimOwner(noalias self: *@This()) !void {
            const address = @intFromPtr(self);
            if (self.owner_address == 0) {
                self.owner_address = address;
                return;
            }
            if (self.owner_address != address) return error.QueryIteratorCopiedAfterStart;
        }

        /// Returns next matching node or `null` when exhausted.
        pub inline fn next(noalias self: *@This()) !?NodeTypeWrapper {
            try self.claimOwner();
            if (self.doc_generation != self.doc.generation or self.end_index > self.doc.nodes.len) {
                @branchHint(.cold);
                self.next_index = self.end_index;
                self.deinit();
                return null;
            }

            while (self.next_index < self.end_index) : (self.next_index += 1) {
                const matched = switch (self.engine) {
                    // Wide forward matching is stateful: every element can establish
                    // ancestry/sibling state for a later rightmost candidate. Do not
                    // apply candidateCouldMatch here; that predicate is only safe for
                    // the final candidate in an RTL/local match.
                    .compact => |*executor| executor.process(self.next_index),
                    .wide => |*executor| executor.process(self.next_index),
                } catch |err| {
                    // Matcher work is not transactionally reversible after an
                    // allocation failure: sibling/nth state may already have
                    // advanced for this node. Make the iterator terminal rather
                    // than allowing a retry to observe partially updated state.
                    self.next_index = self.end_index;
                    self.deinit();
                    return err;
                };
                if (matched) {
                    defer self.next_index += 1;
                    return self.doc.nodeAt(self.next_index);
                }
            }
            self.deinit();
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
        /// Allocator param is separate from doc.allocator; callers must free the
        /// returned slice with same allocator passed here (not doc.allocator).
        pub fn collect(noalias self: *@This(), allocator: std.mem.Allocator) ![]NodeTypeWrapper {
            var out = std.ArrayList(NodeTypeWrapper).empty;
            errdefer out.deinit(allocator);
            while (try self.next()) |node| try out.append(allocator, node);
            return out.toOwnedSlice(allocator);
        }
    };
}

/// Builds the direct element-child iterator type for a parse option set.
fn GetChildrenIter(comptime options: ParseOptions) type {
    return struct {
        //! Iterator over direct child nodes for a parent node.
        const DocType = options.Document();
        const NodeTypeWrapper = GetNode(options);

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
        /// Allocator param is separate from doc.allocator — callers must free the
        /// returned slice with same allocator passed here (not doc.allocator).
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
        pub const Options = options;
        const RawNodeType = GetRawNode(options);
        const ChildrenIterType = GetChildrenIter(options);
        const NodeTypeWrapper = GetNode(options);
        const QueryIterType = GetQueryIter(options);

        /// Allocator used for node storage and caller-directed temporary work.
        allocator: std.mem.Allocator,
        /// Source bytes referenced by node spans.
        source: options.Input(),

        /// Parsed node storage.
        nodes: []RawNodeType = &[_]RawNodeType{},
        /// Identity/version used to invalidate iterators and matcher caches after
        /// the document value is cleared or replaced by another parse.
        generation: u64 = 0,

        /// Initializes an empty document using `allocator` for internal storage.
        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .source = emptySource(),
                .generation = freshDocumentGeneration(),
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
            self.generation = freshDocumentGeneration();
        }

        /// Returns an empty source slice with mutability matching parse options.
        fn emptySource() options.Input() {
            if (comptime options.non_destructive) {
                return &[_]u8{};
            }
            return @constCast(@as([]const u8, &[_]u8{}));
        }

        pub fn root(self: *const @This()) NodeTypeWrapper {
            return self.nodeAt(0);
        }

        /// Compiles selector at comptime and returns lazy iterator over matches.
        /// Call iterator `deinit` when stopping before exhaustion.
        pub fn query(self: *const @This(), comptime selector: []const u8) QueryIterType {
            const sel = comptime ast.Selector.compile(selector);
            const plan = comptime forward.buildPlan(sel);
            if (self.nodes.len == 0) return QueryIterType.init(self, sel, plan, InvalidIndex, 1, 1);
            return self.root().queryIter(sel, plan);
        }

        /// Returns lazy iterator over matches for already compiled selector.
        /// Call iterator `deinit` when stopping before exhaustion.
        pub fn queryRuntime(self: *const @This(), sel: ast.Selector) QueryIterType {
            // Empty documents cannot match anything; avoid walking a potentially
            // large runtime selector solely to build transition masks.
            if (self.nodes.len == 0) return QueryIterType.init(self, sel, .{}, InvalidIndex, 1, 1);
            return self.root().queryIter(sel, forward.buildPlan(sel));
        }

        /// Returns lazy iterator over matches using a reusable prepared selector.
        /// `prepared` must outlive the iterator.
        pub fn queryPrepared(self: *const @This(), prepared: *const prepared_selector.PreparedSelector) QueryIterType {
            if (self.nodes.len == 0) return QueryIterType.initPrepared(self, prepared, InvalidIndex, 1, 1);
            return QueryIterType.initPrepared(self, prepared, InvalidIndex, 1, self.nodes[0].subtree_end + 1);
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
                if (std.ascii.eqlIgnoreCase(n.name_or_text.slice(self.source), name)) return .{ .doc = self, .index = @intCast(i) };
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
        pub fn writeHtml(self: *const @This(), writer: anytype, comptime entity_encoding: EntityEncoding) NodeTypeWrapper.WriterError(@TypeOf(writer))!void {
            if (self.nodes.len == 0) return;
            if (comptime options.non_destructive and entity_encoding != .force) {
                try writer.writeAll(self.source);
                return;
            }
            return self.root().writeHtml(writer, entity_encoding);
        }

        /// Default formatter uses HTML serialization for this node.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.writeHtml(writer, .never);
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
    _ = @sizeOf(GetRawNode(.{}));
    _ = @sizeOf(GetNode(.{}));
}

test "document type excludes parser-only and shadow-source state" {
    try std.testing.expect(!@hasField(GetDocument(.{}), "parse_stack"));
    try std.testing.expect(!@hasField(GetDocument(.{}), "original_source"));
    try std.testing.expect(!@hasField(GetDocument(.{}), "owned_shadow_source"));
    try std.testing.expect(!@hasField(GetDocument(.{}), "mutable_source"));
    try std.testing.expect(!@hasField(GetRawNode(.{}), "kind"));
    try std.testing.expect(!@hasField(GetRawNode(.{}), "attr_end"));
    try std.testing.expect(!@hasField(GetRawNode(.{}), "first_child"));
    try std.testing.expect(!@hasField(GetRawNode(.{}), "next_sibling"));
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

test "querying initialized or cleared document is empty" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var empty = doc.query("div");
    defer empty.deinit();
    try std.testing.expect(try empty.next() == null);

    var html = "<div></div>".*;
    try resetParsed(.{}, &doc, &html);
    doc.clear();

    var cleared = doc.query("div");
    defer cleared.deinit();
    try std.testing.expect(try cleared.next() == null);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const runtime = try ast.Selector.compileRuntime(arena.allocator(), "div");
    var runtime_empty = doc.queryRuntime(runtime);
    defer runtime_empty.deinit();
    try std.testing.expect(try runtime_empty.next() == null);
}

test "document source type follows parse mode" {
    try std.testing.expect(@FieldType(GetDocument(.{}), "source") == []u8);
    try std.testing.expect(@FieldType(GetDocument(.{ .non_destructive = true }), "source") == []const u8);
}

/// Test helper that checks iterator results by `id` attribute sequence.
fn expectIterIds(iter: anytype, expected_ids: []const []const u8) !void {
    var mut_iter = iter;
    var i: usize = 0;
    while (try mut_iter.next()) |node| {
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
    break :blk it.next() catch unreachable;
}) {
    var it = iter;
    defer it.deinit();
    return it.next() catch unreachable;
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
    defer it.deinit();
    try std.testing.expect(try it.next() != null);
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
    defer text.free(alloc);
    try std.testing.expectEqualStrings("a & b", text.value);

    try std.testing.expectEqualSlices(u8, before[0..], html[0..]);

    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(before[0..], rendered);
}

test "destructive attribute APIs preserve marker-colliding recovered names" {
    const alloc = std.testing.allocator;
    var html = "<div ok=v a\"b=x =lead='y&amp;z' tail=t></div>".*;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    const ok = (try node.getAttributeValue(alloc, "ok")) orelse return error.TestUnexpectedResult;
    defer ok.free(alloc);
    try std.testing.expectEqualStrings("v", ok.value);

    const quoted = (try node.getAttributeValue(alloc, "a\"b")) orelse return error.TestUnexpectedResult;
    defer quoted.free(alloc);
    try std.testing.expectEqualStrings("x", quoted.value);

    const leading = (try node.getAttributeValue(alloc, "=lead")) orelse return error.TestUnexpectedResult;
    defer leading.free(alloc);
    try std.testing.expectEqualStrings("y&z", leading.value);

    const tail = (try node.getAttributeValue(alloc, "tail")) orelse return error.TestUnexpectedResult;
    defer tail.free(alloc);
    try std.testing.expectEqualStrings("t", tail.value);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try node.writeHtml(&out.writer, .never);
    try std.testing.expectEqualStrings("<div ok=\"v\" a\"b=\"x\" =lead=\"y&amp;z\" tail=\"t\"></div>", out.written());
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

test "non-destructive mixed-case tags match lowercase selectors and stay void" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    const html = "<MAIN><DIV ID='x'><IMG SRC='a.png'><BR></DIV></MAIN>".*;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    // Tag selectors must match mixed-case source tags.
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("DIV", div.tagName());
    try std.testing.expect(firstQuery(doc.query("main div#x")) != null);
    try std.testing.expect(firstQuery(doc.query("img")) != null);
    try std.testing.expect(firstQuery(doc.query("br")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "main div")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "img")) != null);

    // Mixed-case void tags serialize without end tags.
    const img = firstQuery(doc.query("img")) orelse return error.TestUnexpectedResult;
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{img});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("<IMG SRC='a.png'>", rendered);

    try std.testing.expectEqualSlices(u8, html[0..], doc.source);
}

test "attribute value results distinguish borrowed and allocated non-destructive reads" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' plain='abc' data-v='a&amp;b'></div>".*;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    const plain = (try node.getAttributeValue(alloc, "plain")) orelse return error.TestUnexpectedResult;
    defer plain.free(alloc);
    try std.testing.expect(!plain.owned);
    try std.testing.expectEqualStrings("abc", plain.value);

    const decoded = (try node.getAttributeValue(alloc, "data-v")) orelse return error.TestUnexpectedResult;
    defer decoded.free(alloc);
    try std.testing.expect(decoded.owned);
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
    try std.testing.expect(!value.owned);
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

test "raw destructive attribute value reflects whole-tag materialization" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-v='a&amp;b'></div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = firstQuery(doc.query("#x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", node.getAttributeValueRaw("data-v") orelse return error.TestUnexpectedResult);

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
    defer text.free(alloc);
    try std.testing.expectEqualStrings("a & b", text.value);

    const owned = try node.innerTextOwnedWithOptions(alloc, .{});
    defer alloc.free(owned);
    try std.testing.expectEqualStrings("a & b", owned);

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
    defer text.free(alloc);
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

    try std.testing.expect(try it.next() != null);
    try std.testing.expect(try it.next() != null);
    try std.testing.expect(try it.next() == null);
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

    try std.testing.expect(try old_it.next() != null);
    try std.testing.expect(try old_it.next() == null);
    try std.testing.expect(try new_it.next() != null);
    try std.testing.expect(try new_it.next() == null);
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
    try std.testing.expect(try old_it.next() == null);
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.len);

    var html_b = "<div><span class='y'></span></div>".*;
    try resetParsed(.{}, &doc, &html_b);
    try std.testing.expect(try old_it.next() == null);

    var new_it = try runtimeQuery(&doc, runtime_arena.allocator(), "span.y");
    try std.testing.expect(try new_it.next() != null);
    try std.testing.expect(try new_it.next() == null);

    // Reparse before the stale iterator is touched. Length-based invalidation
    // alone cannot detect this when the replacement document is large enough.
    var stale = try runtimeQuery(&doc, runtime_arena.allocator(), "span.y");
    var html_c = "<main><span class='z'></span><span></span></main>".*;
    try resetParsed(.{}, &doc, &html_c);
    try std.testing.expect(try stale.next() == null);
}

test "stale query iterator deinitializes with its captured allocator" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var first_html = "<div><span></span><span></span></div>".*;
    var doc = try opts.parse(alloc, &first_html);

    var it = doc.query("div > span");
    defer it.deinit();
    _ = (try it.next()) orelse return error.TestUnexpectedResult;

    // Replace the document value with one backed by a different allocator. A
    // stale iterator must free its old matcher scratch through the allocator it
    // captured at construction, not through the replacement document.
    doc.deinit();
    // Keep the alternate allocator comfortably above representation-size
    // differences between u16/u32/u64 index configurations. This test is about
    // allocator identity, not a fixed-buffer capacity boundary.
    var fixed_storage: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed_storage);
    var second_html = "<main><i></i><i></i></main>".*;
    doc = try opts.parse(fba.allocator(), &second_html);
    defer doc.deinit();

    try std.testing.expect(try it.next() == null);
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
    defer text.free(alloc);
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
    defer text.free(alloc);
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
    defer text.free(alloc);
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
    defer text.free(alloc);
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
    defer escaped.free(alloc);
    try std.testing.expectEqualStrings("alpha  &amp;   beta  ", escaped.value);

    const raw = try node.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer raw.free(alloc);
    try std.testing.expectEqualStrings("alpha  &   beta  ", raw.value);

    const normalized = try node.innerTextWithOptions(alloc, .{});
    defer normalized.free(alloc);
    try std.testing.expectEqualStrings("alpha & beta", normalized.value);

    var escaped_doc = GetDocument(.{}).init(alloc);
    defer escaped_doc.deinit();
    var escaped_html = "<div id='x'>  alpha  &amp;   beta  </div>".*;
    try resetParsed(.{}, &escaped_doc, &escaped_html);
    const escaped_node = firstQuery(escaped_doc.query("#x")) orelse return error.TestUnexpectedResult;
    const escaped_normalized = try escaped_node.innerTextWithOptions(alloc, .{ .unescape = false });
    defer escaped_normalized.free(alloc);
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

test "spaced assignments materialize and serialize consistently" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div id = \"x\" class= \"a b\" data-k \n = v hidden data-n = \"a&amp;b&#x00;c\x00d\"></div>".*;
    try resetParsed(.{}, &doc, &html);

    const node = doc.findFirstTag("div") orelse return error.TestUnexpectedResult;
    const formatted = try std.fmt.allocPrint(alloc, "{f}", .{node});
    defer alloc.free(formatted);
    try std.testing.expectEqualStrings(
        "<div id=\"x\" class=\"a b\" data-k=\"v\" hidden data-n=\"a&amp;b�c d\"></div>",
        formatted,
    );

    try std.testing.expect(firstQuery(doc.query("div#x.a[data-k=v][hidden]")) != null);
    try std.testing.expect(firstQuery(doc.query("div[v]")) == null);
    const data_n = (try node.getAttributeValue(alloc, "data-n")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b�c d", data_n.value);

    const materialized = try std.fmt.allocPrint(alloc, "{f}", .{node});
    defer alloc.free(materialized);
    try std.testing.expectEqualStrings(
        "<div id=\"x\" class=\"a b\" data-k=\"v\" hidden data-n=\"a&amp;b�c d\"></div>",
        materialized,
    );
}

test "read-only spaced attributes decode and sanitize without source mutation" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();

    var html = "<div id \n = x data-n= \"a&amp;b&#0;c\x00d\"></div>".*;
    const before = html;
    try resetParsed(.{ .non_destructive = true }, &doc, &html);

    const node = firstQuery(doc.query("div#x")) orelse return error.TestUnexpectedResult;
    const data_n = (try node.getAttributeValue(alloc, "data-n")) orelse return error.TestUnexpectedResult;
    defer data_n.free(alloc);
    try std.testing.expectEqualStrings("a&b�c d", data_n.value);
    try std.testing.expect(data_n.owned);
    try std.testing.expectEqualSlices(u8, &before, doc.source);
    try std.testing.expectEqualSlices(u8, &before, &html);
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
    defer x_text.free(alloc);
    try std.testing.expectEqualStrings("single", x_text.value);
    try std.testing.expect(!x_text.owned);

    const y_text = try y.innerTextWithOptions(alloc, .{});
    defer y_text.free(alloc);
    try std.testing.expectEqualStrings("a b", y_text.value);
    try std.testing.expect(y_text.owned);
}

test "innerTextOwned returns allocated output and materializes RW source text" {
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

    const text_node_after = doc.nodes[node.index + 1];
    try std.testing.expectEqualStrings("a & b", text_node_after.name_or_text.slice(doc.source));
    try std.testing.expectEqual(@as(u8, @intFromEnum(RwTextState.decoded)), doc.source[text_node_after.name_or_text.end()]);
}

test "RW text decoding stores and moves the trailing decoded marker" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<p> a&amp;  b </p>".*;
    try resetParsed(.{}, &doc, &html);
    const p = firstQuery(doc.query("p")) orelse return error.TestUnexpectedResult;
    const text_idx = p.index + 1;

    const decoded = try p.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("a&  b ", decoded.value);
    const decoded_end: usize = doc.nodes[text_idx].name_or_text.end();
    try std.testing.expectEqual(@as(u8, @intFromEnum(RwTextState.decoded)), doc.source[decoded_end]);

    const normalized = try p.innerTextWithOptions(alloc, .{ .unescape = false, .normalize_whitespace = true });
    try std.testing.expectEqualStrings("a& b", normalized.value);
    const normalized_end: usize = doc.nodes[text_idx].name_or_text.end();
    try std.testing.expect(normalized_end < decoded_end);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RwTextState.decoded)), doc.source[normalized_end]);
}

test "RW terminal text marks only when decoding creates room" {
    const alloc = std.testing.allocator;

    var encoded_doc = GetDocument(.{}).init(alloc);
    defer encoded_doc.deinit();
    var encoded = "<p>x&amp;y".*;
    try resetParsed(.{}, &encoded_doc, &encoded);
    const encoded_p = firstQuery(encoded_doc.query("p")) orelse return error.TestUnexpectedResult;
    const decoded = try encoded_p.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("x&y", decoded.value);
    const encoded_text = encoded_doc.nodes[encoded_p.index + 1];
    try std.testing.expect(encoded_text.name_or_text.end() < encoded_doc.source.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RwTextState.decoded)), encoded_doc.source[encoded_text.name_or_text.end()]);

    var plain_doc = GetDocument(.{}).init(alloc);
    defer plain_doc.deinit();
    var plain = "<p>plain".*;
    try resetParsed(.{}, &plain_doc, &plain);
    const plain_p = firstQuery(plain_doc.query("p")) orelse return error.TestUnexpectedResult;
    const value = try plain_p.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("plain", value.value);
    try std.testing.expectEqual(plain_doc.source.len, @as(usize, plain_doc.nodes[plain_p.index + 1].name_or_text.end()));
}

test "RW multi-node owned text materializes each span and still normalizes after joining" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var html = "<div>a&amp;<b></b>  c&amp;d</div>".*;
    try resetParsed(.{}, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    const value = try div.innerTextOwnedWithOptions(alloc, .{});
    defer alloc.free(value);
    try std.testing.expectEqualStrings("a& c&d", value);

    var idx = div.index + 1;
    while (idx <= div.raw().subtree_end) : (idx += 1) {
        if (!doc.nodes[idx].isText(idx)) continue;
        const end: usize = doc.nodes[idx].name_or_text.end();
        try std.testing.expect(end < doc.source.len);
        try std.testing.expectEqual(@as(u8, @intFromEnum(RwTextState.decoded)), doc.source[end]);
        try std.testing.expect(std.mem.indexOf(u8, doc.nodes[idx].name_or_text.slice(doc.source), "&amp;") == null);
    }
}

test "empty document serialization is empty" {
    const alloc = std.testing.allocator;

    var rw = GetDocument(.{}).init(alloc);
    defer rw.deinit();
    var rw_out: std.Io.Writer.Allocating = .init(alloc);
    defer rw_out.deinit();
    try rw.writeHtml(&rw_out.writer, .force);
    try std.testing.expectEqualStrings("", rw_out.written());

    var ro = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer ro.deinit();
    var ro_out: std.Io.Writer.Allocating = .init(alloc);
    defer ro_out.deinit();
    try ro.writeHtml(&ro_out.writer, .force);
    try std.testing.expectEqualStrings("", ro_out.written());
}

test "RW serialization reconstructs markup replaced by a text marker" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<p>a&amp;b</p>".*;
    try resetParsed(.{}, &doc, &html);
    const p = firstQuery(doc.query("p")) orelse return error.TestUnexpectedResult;
    _ = try p.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try p.writeHtml(&out.writer, .never);
    try std.testing.expectEqualStrings("<p>a&b</p>", out.written());
}

test "nested node serialization stops at the requested subtree" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div><span>x</span></div>".*;
    try resetParsed(.{}, &doc, &html);
    const span = firstQuery(doc.query("span")) orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try span.writeHtml(&out.writer, .never);
    try std.testing.expectEqualStrings("<span>x</span>", out.written());
}

test "writeHtml optionally encodes materialized text while format keeps raw behavior" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div>a&lt;b & c &gt; d</div>".*;
    try resetParsed(.{}, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try div.writeHtml(&encoded.writer, .force);
    try std.testing.expectEqualStrings("<div>a&lt;b &amp; c &gt; d</div>", encoded.written());

    const formatted = try std.fmt.allocPrint(alloc, "{f}", .{div});
    defer alloc.free(formatted);
    try std.testing.expectEqualStrings("<div>a<b & c > d</div>", formatted);
}

test "read-only writeHtml keeps exact encoded source for either encoding choice" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();
    const html = "<div>a&lt;b &amp; c</div>";
    try resetParsed(.{ .non_destructive = true }, &doc, html);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try doc.writeHtml(&out.writer, .force);
    try std.testing.expectEqualStrings(html, out.written());
}

test "raw and escapable raw text use distinct decode and serialization rules" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<script>a&amp;<b</script><style>c&amp;<d</style><title>e&amp;<f</title><textarea>g&amp;<h</textarea>".*;
    try resetParsed(.{}, &doc, &html);

    const script = firstQuery(doc.query("script")) orelse return error.TestUnexpectedResult;
    const style = firstQuery(doc.query("style")) orelse return error.TestUnexpectedResult;
    const title = firstQuery(doc.query("title")) orelse return error.TestUnexpectedResult;
    const textarea = firstQuery(doc.query("textarea")) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("a&amp;<b", (try script.innerTextWithOptions(alloc, .{ .normalize_whitespace = false })).value);
    try std.testing.expectEqualStrings("c&amp;<d", (try style.innerTextWithOptions(alloc, .{ .normalize_whitespace = false })).value);
    try std.testing.expectEqualStrings("e&<f", (try title.innerTextWithOptions(alloc, .{ .normalize_whitespace = false })).value);
    try std.testing.expectEqualStrings("g&<h", (try textarea.innerTextWithOptions(alloc, .{ .normalize_whitespace = false })).value);

    var script_out: std.Io.Writer.Allocating = .init(alloc);
    defer script_out.deinit();
    try script.writeHtml(&script_out.writer, .force);
    try std.testing.expectEqualStrings("<script>a&amp;<b</script>", script_out.written());

    var title_out: std.Io.Writer.Allocating = .init(alloc);
    defer title_out.deinit();
    try title.writeHtml(&title_out.writer, .force);
    try std.testing.expectEqualStrings("<title>e&amp;&lt;f</title>", title_out.written());
}

test "mixed subtree text decoding leaves script entities literal" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div>x&amp;<script>y&amp;</script><title>z&amp;</title></div>".*;
    try resetParsed(.{}, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    const value = try div.innerTextOwnedWithOptions(alloc, .{ .normalize_whitespace = false });
    defer alloc.free(value);
    try std.testing.expectEqualStrings("x& y&amp; z&", value);
}

test "read-only extraction decodes escapable raw text but not raw text" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer doc.deinit();
    const html = "<script>a&amp;<b</script><title>c&amp;<d</title>";
    try resetParsed(.{ .non_destructive = true }, &doc, html);

    const script = firstQuery(doc.query("script")) orelse return error.TestUnexpectedResult;
    const title = firstQuery(doc.query("title")) orelse return error.TestUnexpectedResult;
    const script_text = try script.innerTextOwnedWithOptions(alloc, .{ .normalize_whitespace = false });
    defer alloc.free(script_text);
    const title_text = try title.innerTextOwnedWithOptions(alloc, .{ .normalize_whitespace = false });
    defer alloc.free(title_text);
    try std.testing.expectEqualStrings("a&amp;<b", script_text);
    try std.testing.expectEqualStrings("c&<d", title_text);
    try std.testing.expectEqualStrings(html, doc.source);
}

test "full named entity parse option applies to text and attributes" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .entity_decoding = .full };
    var doc = opts.Document().init(alloc);
    defer doc.deinit();
    var html = "<div title='&eacute;'>&NotNestedGreaterGreater;</div>".*;
    try resetParsed(opts, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    const title = (try div.getAttributeValue(alloc, "title")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("\xc3\xa9", title.value);
    const text = try div.innerTextOwnedWithOptions(alloc, .{ .normalize_whitespace = false });
    defer alloc.free(text);
    try std.testing.expectEqualStrings("\xe2\xaa\xa2\xcc\xb8", text);
}

test "expanding full entities use marked allocating fallbacks" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .entity_decoding = .full };
    var doc = opts.Document().init(alloc);
    defer doc.deinit();
    var html = "<div naked=&nLt; single='&nGt;' double=\"&nLt;\">&nLt;</div>".*;
    try resetParsed(opts, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    const expected_lt = try entities.decodeAllocWithMode(.full, true, alloc, "&nLt;");
    defer alloc.free(expected_lt);
    const expected_gt = try entities.decodeAllocWithMode(.full, true, alloc, "&nGt;");
    defer alloc.free(expected_gt);

    const naked = (try div.getAttributeValue(alloc, "naked")) orelse return error.TestUnexpectedResult;
    defer naked.free(alloc);
    const single = (try div.getAttributeValue(alloc, "single")) orelse return error.TestUnexpectedResult;
    defer single.free(alloc);
    const double = (try div.getAttributeValue(alloc, "double")) orelse return error.TestUnexpectedResult;
    defer double.free(alloc);
    try std.testing.expect(naked.owned and single.owned and double.owned);
    try std.testing.expectEqualSlices(u8, expected_lt, naked.value);
    try std.testing.expectEqualSlices(u8, expected_gt, single.value);
    try std.testing.expectEqualSlices(u8, expected_lt, double.value);

    var compact: attr.CompactIterator = .{ .source = doc.source, .cursor = div.raw().name_or_text.end() };
    const compact_naked = compact.next() orelse return error.TestUnexpectedResult;
    const compact_single = compact.next() orelse return error.TestUnexpectedResult;
    const compact_double = compact.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(attr.CompactValueMarker.raw_naked, compact_naked.marker);
    try std.testing.expectEqual(attr.CompactValueMarker.raw_single_quoted, compact_single.marker);
    try std.testing.expectEqual(attr.CompactValueMarker.raw_double_quoted, compact_double.marker);

    const text = try div.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer text.free(alloc);
    try std.testing.expect(text.owned);
    try std.testing.expectEqualSlices(u8, expected_lt, text.value);
    const text_idx = div.index + 1;
    const text_end: usize = doc.nodes[text_idx].name_or_text.end();
    try std.testing.expect(text_end < doc.source.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RwTextState.decode_failed)), doc.source[text_end]);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer, .force);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "&nLt;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "&nGt;") == null);

    // EOF text has no following source byte available for a persistent marker.
    // Force serialization must still honor the transactional decode result from
    // this call rather than rereading a marker that cannot exist.
    var eof_doc = opts.Document().init(alloc);
    defer eof_doc.deinit();
    var eof_html = "<div>&nLt;".*;
    try resetParsed(opts, &eof_doc, &eof_html);
    const eof_div = firstQuery(eof_doc.query("div")) orelse return error.TestUnexpectedResult;
    var eof_out: std.Io.Writer.Allocating = .init(alloc);
    defer eof_out.deinit();
    try eof_div.writeHtml(&eof_out.writer, .force);
    try std.testing.expect(std.mem.indexOf(u8, eof_out.written(), "&nLt;") == null);
    try std.testing.expect(std.mem.indexOf(u8, eof_out.written(), "&amp;nLt;") == null);
}

test "multi-node innerText decodes an expanding final EOF text span" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .entity_decoding = .full };
    var doc = opts.Document().init(alloc);
    defer doc.deinit();

    var html = "<div>a<span>b</span>&nLt;".*;
    try resetParsed(opts, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    const expected_tail = try entities.decodeAllocWithMode(.full, false, alloc, "&nLt;");
    defer alloc.free(expected_tail);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);
    try expected.appendSlice(alloc, "a b ");
    try expected.appendSlice(alloc, expected_tail);

    const text = try div.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    defer text.free(alloc);
    try std.testing.expect(text.owned);
    try std.testing.expectEqualSlices(u8, expected.items, text.value);
}

test "entity serialization modes preserve auto and force contracts" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div>a&lt;b & c</div>".*;
    try resetParsed(.{}, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var before: std.Io.Writer.Allocating = .init(alloc);
    defer before.deinit();
    try div.writeHtml(&before.writer, .auto);
    try std.testing.expectEqualStrings("<div>a&lt;b & c</div>", before.written());

    _ = try div.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    var after: std.Io.Writer.Allocating = .init(alloc);
    defer after.deinit();
    try div.writeHtml(&after.writer, .auto);
    try std.testing.expectEqualStrings("<div>a&lt;b &amp; c</div>", after.written());
}

test "force serialization respects the configured entity decoding mode" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .non_destructive = true, .entity_decoding = .minimal };
    var doc = opts.Document().init(alloc);
    defer doc.deinit();
    const html = "<div title='&eacute;'>&nbsp;&eacute;</div>";
    try resetParsed(opts, &doc, html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer, .force);
    try std.testing.expectEqualStrings("<div title=\"&amp;eacute;\">&amp;nbsp;&amp;eacute;</div>", out.written());

    const rw_opts: ParseOptions = .{ .entity_decoding = .minimal };
    var rw_doc = rw_opts.Document().init(alloc);
    defer rw_doc.deinit();
    var rw_html = "<div title='&eacute;'>&nbsp;&eacute;</div>".*;
    try resetParsed(rw_opts, &rw_doc, &rw_html);
    const rw_div = firstQuery(rw_doc.query("div")) orelse return error.TestUnexpectedResult;
    // Materialize first using the deliberately narrower extraction policy.
    _ = (try rw_div.getAttributeValue(alloc, "title")) orelse return error.TestUnexpectedResult;
    _ = try rw_div.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    var rw_out: std.Io.Writer.Allocating = .init(alloc);
    defer rw_out.deinit();
    try rw_div.writeHtml(&rw_out.writer, .force);
    try std.testing.expectEqualStrings("<div title=\"&amp;eacute;\">&amp;nbsp;&amp;eacute;</div>", rw_out.written());
}

test "force serialization does not decode entity text produced by amp" {
    const alloc = std.testing.allocator;
    const html = "<div title='&amp;eacute;'>&amp;eacute;</div>";

    var ro_doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer ro_doc.deinit();
    try resetParsed(.{ .non_destructive = true }, &ro_doc, html);
    const ro_div = firstQuery(ro_doc.query("div")) orelse return error.TestUnexpectedResult;
    var ro_out: std.Io.Writer.Allocating = .init(alloc);
    defer ro_out.deinit();
    try ro_div.writeHtml(&ro_out.writer, .force);
    try std.testing.expectEqualStrings("<div title=\"&amp;eacute;\">&amp;eacute;</div>", ro_out.written());

    var rw_doc = GetDocument(.{}).init(alloc);
    defer rw_doc.deinit();
    var rw_html = html.*;
    try resetParsed(.{}, &rw_doc, &rw_html);
    const rw_div = firstQuery(rw_doc.query("div")) orelse return error.TestUnexpectedResult;
    // Exercise the exact regression: materialize before force serialization.
    _ = (try rw_div.getAttributeValue(alloc, "title")) orelse return error.TestUnexpectedResult;
    _ = try rw_div.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    var rw_out: std.Io.Writer.Allocating = .init(alloc);
    defer rw_out.deinit();
    try rw_div.writeHtml(&rw_out.writer, .force);
    try std.testing.expectEqualStrings("<div title=\"&amp;eacute;\">&amp;eacute;</div>", rw_out.written());
}

test "force serialization preserves SVG and plaintext opaque payloads" {
    const alloc = std.testing.allocator;

    var svg_doc = GetDocument(.{}).init(alloc);
    defer svg_doc.deinit();
    var svg_html = "<svg><g/>&amp;</svg>".*;
    try resetParsed(.{}, &svg_doc, &svg_html);
    const svg = firstQuery(svg_doc.query("svg")) orelse return error.TestUnexpectedResult;
    var svg_out: std.Io.Writer.Allocating = .init(alloc);
    defer svg_out.deinit();
    try svg.writeHtml(&svg_out.writer, .force);
    try std.testing.expectEqualStrings("<svg><g/>&amp;</svg>", svg_out.written());

    var plaintext_doc = GetDocument(.{ .non_destructive = true }).init(alloc);
    defer plaintext_doc.deinit();
    const plaintext_html = "<plaintext><b>&amp;";
    try resetParsed(.{ .non_destructive = true }, &plaintext_doc, plaintext_html);
    const plaintext = firstQuery(plaintext_doc.query("plaintext")) orelse return error.TestUnexpectedResult;
    var plaintext_out: std.Io.Writer.Allocating = .init(alloc);
    defer plaintext_out.deinit();
    try plaintext.writeHtml(&plaintext_out.writer, .force);
    try std.testing.expectEqualStrings("<plaintext><b>&amp;</plaintext>", plaintext_out.written());
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
    const span = doc.source[attr_start..];
    const q_marker = "q=&z\x00";
    const q_pos = std.mem.indexOf(u8, span, q_marker) orelse return error.TestUnexpectedResult;
    try std.testing.expect(q_pos < span.len);

    const n_marker = "n=a&b\x00";
    const n_pos = std.mem.indexOf(u8, span, n_marker) orelse return error.TestUnexpectedResult;
    try std.testing.expect(n_pos + n_marker.len <= span.len);
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
    const span = doc.source[attr_start..];
    const class_pos = std.mem.indexOf(u8, span, "class") orelse return error.TestUnexpectedResult;
    const marker_pos = class_pos + "class".len;
    try std.testing.expect(marker_pos < span.len);
    try std.testing.expectEqual(@as(u8, '='), span[marker_pos]);
    try std.testing.expect(std.mem.indexOf(u8, span, "class=button\x00") != null);
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
    while (try it_odd.next()) |_| c_odd += 1;
    try std.testing.expectEqual(@as(usize, 4), c_odd);

    var c_plus: usize = 0;
    var it_plus = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(3n+1)");
    while (try it_plus.next()) |_| c_plus += 1;
    try std.testing.expectEqual(@as(usize, 3), c_plus);

    var c_signed: usize = 0;
    var it_signed = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(+3n-2)");
    while (try it_signed.next()) |_| c_signed += 1;
    try std.testing.expectEqual(@as(usize, 3), c_signed);

    var c_neg_a: usize = 0;
    var it_neg_a = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(-n+6)");
    while (try it_neg_a.next()) |_| c_neg_a += 1;
    try std.testing.expectEqual(@as(usize, 6), c_neg_a);

    var c_neg_b: usize = 0;
    var it_neg_b = try runtimeQuery(&doc, runtime_arena.allocator(), "#pseudos :nth-child(-n+5)");
    while (try it_neg_b.next()) |_| c_neg_b += 1;
    try std.testing.expectEqual(@as(usize, 5), c_neg_b);
}

test "root element first-child and nth-child one are equivalent" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<html><body></body></html>".*;
    try resetParsed(.{}, &doc, &html);
    try std.testing.expect(firstQuery(doc.query("html:first-child")) != null);
    try std.testing.expect(firstQuery(doc.query("html:nth-child(1)")) != null);
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
    while (try it_em.next()) |_| em_count += 1;
    try std.testing.expectEqual(@as(usize, 2), em_count);

    var it_oooo = try runtimeQuery(frag_root, runtime_arena.allocator(), "> div #oooo");
    var oooo_count: usize = 0;
    while (try it_oooo.next()) |_| oooo_count += 1;
    try std.testing.expectEqual(@as(usize, 1), oooo_count);

    var doc_ctx = GetDocument(.{}).init(alloc);
    defer doc_ctx.deinit();
    var doc_html =
        "<root><div id='hsoob'><div class='a b'><div class='d e sib' id='booshTest'><p><span id='spanny'></span></p></div><em class='sib'></em><span class='h i a sib'></span></div><p class='odd'></p></div><div id='lonelyHsoob'></div></root>".*;
    try resetParsed(.{}, &doc_ctx, &doc_html);
    const ctx_root = firstQuery(doc_ctx.query("root")) orelse return error.TestUnexpectedResult;

    var it_hsoob = try runtimeQuery(ctx_root, runtime_arena.allocator(), "> #hsoob");
    var hsoob_count: usize = 0;
    while (try it_hsoob.next()) |_| hsoob_count += 1;
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

test "document attribute lookup accepts framework attribute names" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div @click=a *ngIf=b (change)=c [value]=d v-on:click=e x-on:keydown=f data-foo.bar=g></div>".*;
    try resetParsed(.{}, &doc, &html);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;
    const names = [_][]const u8{ "@click", "*ngIf", "(change)", "[value]", "v-on:click", "x-on:keydown", "data-foo.bar" };
    const values = "abcdefg";
    for (names, values) |name, value| {
        const found = (try div.getAttributeValue(alloc, name)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, &[_]u8{value}, found.value);
    }

    const selectors = [_][]const u8{
        "div[@click=a]",
        "div[*ngIf=b]",
        "div[(change)=c]",
        "div[[value]=d]",
        "div[v-on:click=e]",
        "div[x-on:keydown=f]",
        "div[data-foo.bar=g]",
    };
    for (selectors) |selector| try std.testing.expect(try runtimeFirst(&doc, alloc, selector) != null);
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
    try std.testing.expect(!text_before_clear.owned);

    doc.clear();
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), doc.source.len);
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
    try doc.writeHtml(&out.writer, .never);
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

test "format document types" {
    const alloc = std.testing.allocator;

    const opts: ParseOptions = .{ .drop_whitespace_text_nodes = .none };
    const opts_out = try std.fmt.allocPrint(alloc, "{f}", .{opts});
    defer alloc.free(opts_out);
    try std.testing.expectEqualStrings("ParseOptions{drop_whitespace_text_nodes=none, non_destructive=false, entity_decoding=common, store_last_child=false, store_prev_sibling=false}", opts_out);

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

test "query iterator lifecycle releases scratch and copies independently" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<div><span id=a></span><span id=b></span><span id=c></span></div>".*;
    try resetParsed(.{}, &doc, &src);

    // Dropping an iterator before its first next() is allocation-free.
    {
        const unused = doc.query("span");
        try std.testing.expect(!unused.engine.compact.initialized);
    }

    var early = doc.query("div > span");
    try std.testing.expect(try early.next() != null);
    try std.testing.expect(early.engine.compact.initialized);
    early.deinit();
    try std.testing.expect(!early.engine.compact.initialized);

    var exhausted = doc.query(".missing");
    try std.testing.expect(try exhausted.next() == null);
    try std.testing.expect(!exhausted.engine.compact.initialized);

    var original = doc.query("span");
    var copied = original;
    const original_first = (try original.next()) orelse return error.TestUnexpectedResult;
    const copied_first = (try copied.next()) orelse return error.TestUnexpectedResult;
    defer original.deinit();
    defer copied.deinit();
    try std.testing.expectEqual(original_first.index, copied_first.index);

    const remaining = try original.collect(alloc);
    defer alloc.free(remaining);
    try std.testing.expectEqual(@as(usize, 2), remaining.len);
    try std.testing.expectEqualStrings("b", (try remaining[0].getAttributeValue(alloc, "id")).?.value);
    try std.testing.expectEqualStrings("c", (try remaining[1].getAttributeValue(alloc, "id")).?.value);

    var started = doc.query("div > span");
    defer started.deinit();
    _ = (try started.next()) orelse return error.TestUnexpectedResult;
    var copied_after_start = started;
    defer copied_after_start.deinit();
    try std.testing.expectError(error.QueryIteratorCopiedAfterStart, copied_after_start.next());
}

test "query iterator reports matcher allocation failure" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<div></div>".*;
    try resetParsed(.{}, &doc, &src);

    var selector_source = std.ArrayList(u8).empty;
    defer selector_source.deinit(alloc);
    for (0..65) |i| {
        if (i != 0) try selector_source.append(alloc, ' ');
        try selector_source.appendSlice(alloc, "div");
    }
    var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
    defer selector.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    doc.allocator = failing.allocator();
    defer doc.allocator = alloc;
    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expectError(error.OutOfMemory, it.next());
    try std.testing.expect(try it.next() == null);
}

test "wide forward query processes all elements without a rightmost candidate prefilter" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<div><div></div></div>".*;
    try resetParsed(.{}, &doc, &src);

    var selector_source = std.ArrayList(u8).empty;
    defer selector_source.deinit(alloc);
    for (0..64) |i| {
        if (i != 0) try selector_source.append(alloc, ' ');
        try selector_source.appendSlice(alloc, "div");
    }
    try selector_source.appendSlice(alloc, " span");
    var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
    defer selector.deinit(alloc);

    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(try it.next() == null);
    // Wide forward matching is stateful: every element establishes ancestry
    // state, so both divs were processed even though `span` is absent and the
    // rightmost compound can never match. No candidate prefilter is applied.
    try std.testing.expectEqual(@as(usize, 2), it.engine.wide.stats.nodes_processed);
}

test "deep-selector workspace frame allocation is reused across candidates" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var source_writer: std.Io.Writer.Allocating = .init(alloc);
    defer source_writer.deinit();
    for (0..65) |_| try source_writer.writer.writeAll("<div>");
    for (0..65) |_| try source_writer.writer.writeAll("</div>");
    const src = try source_writer.toOwnedSlice();
    defer alloc.free(src);
    try resetParsed(.{}, &doc, src);

    var selector_source = std.ArrayList(u8).empty;
    defer selector_source.deinit(alloc);
    for (0..65) |i| {
        if (i != 0) try selector_source.appendSlice(alloc, " > ");
        try selector_source.appendSlice(alloc, "div");
    }
    var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
    defer selector.deinit(alloc);

    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(try it.next() != null);
    try std.testing.expectEqual(@as(usize, 2), it.engine.wide.word_count);
    try std.testing.expect(it.engine.wide.exec_plan.masks.len != 0);
}

test "forward query results agree with RTL matching across combinators and structural pseudos" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = ("<main class=outside><section id=scope>" ++
        "<ul><li id=a class=x></li> text <li id=b></li><li id=c class=y><span id=inner></span></li></ul>" ++
        "<article><p id=p1></p><p id=p2 class=x></p><em id=e></em></article>" ++
        "</section></main>").*;
    try resetParsed(.{}, &doc, &src);

    const selectors = [_][]const u8{
        "ul > li",
        "main li span",
        "li + li",
        ".x ~ li",
        "main > section ul > li + li",
        "main > section li",
        "main section > ul",
        "li + li > span",
        "li ~ li span",
        "ul > li + li",
        "li + li ~ li",
        "li ~ li + li",
        "li:first-child",
        "li:nth-child(1)",
        "li:nth-child(2)",
        "li:nth-child(2n+1)",
        "li:nth-child(-n+2)",
        "li:last-child span",
        "p + em, li.y",
        "main > section, p.x + em",
        "main, section, ul, li, article, p, em, span, body",
    };

    for (selectors) |source| {
        var selector = try ast.Selector.compileRuntime(alloc, source);
        defer selector.deinit(alloc);

        var expected = std.ArrayList(IndexInt).empty;
        defer expected.deinit(alloc);
        var idx: IndexInt = 1;
        while (idx < doc.nodes.len) : (idx += 1) {
            if (try matcher.matchesSelectorAt(GetDocument(.{}), &doc, selector, idx, 0)) try expected.append(alloc, idx);
        }

        var it = doc.queryRuntime(selector);
        defer it.deinit();
        var actual = std.ArrayList(IndexInt).empty;
        defer actual.deinit(alloc);
        while (try it.next()) |node| try actual.append(alloc, node.index);
        try std.testing.expectEqualSlices(IndexInt, expected.items, actual.items);
    }
}

test "random selector differential agrees across reference forward dynamic and RTL" {
    const alloc = std.testing.allocator;
    const Doc = GetDocument(.{});

    var doc = Doc.init(alloc);
    defer doc.deinit();
    var src = ("<main id=root class=a data-x><div class=a><span data-x></span><i class=b></i><b></b></div>" ++
        "<div class=b data-k=v><span class=a></span><em data-x></em><i></i></div>" ++
        "<section><div class=a data-k=v><b class=b></b><span></span></div><em class=a></em></section></main>").*;
    try resetParsed(.{}, &doc, &src);
    try std.testing.expect(doc.nodes.len <= 20);

    const Reference = struct {
        fn matches(
            comptime D: type,
            d: *const D,
            selector: ast.Selector,
            node_index: IndexInt,
            ctx: *matcher.NodeContext,
        ) !bool {
            if (node_index >= d.nodes.len or !d.nodes[node_index].isElement(node_index)) return false;
            for (selector.groups) |group| {
                if (group.compound_len == 0) continue;
                if (try matchGroup(D, d, selector, group, group.compound_len - 1, node_index, ctx)) return true;
            }
            return false;
        }

        fn matchGroup(
            comptime D: type,
            d: *const D,
            selector: ast.Selector,
            group: ast.Group,
            relative: IndexInt,
            node_index: IndexInt,
            ctx: *matcher.NodeContext,
        ) !bool {
            const comp = selector.compounds[group.compound_start + relative];
            const child_position = common.elementSiblingPosition(d, node_index) orelse 0;
            ctx.begin(d.allocator, child_position);
            if (!try matcher.matchesCompoundForward(D, d, selector, comp, node_index, ctx)) return false;
            if (relative == 0) return comp.combinator == .none;

            const previous = relative - 1;
            return switch (comp.combinator) {
                .child => blk: {
                    const parent = d.nodes[node_index].parent;
                    if (parent == InvalidIndex or parent >= d.nodes.len or !d.nodes[parent].isElement(parent)) break :blk false;
                    break :blk try matchGroup(D, d, selector, group, previous, parent, ctx);
                },
                .descendant => blk: {
                    var parent = d.nodes[node_index].parent;
                    while (parent != InvalidIndex and parent < d.nodes.len) {
                        if (d.nodes[parent].isElement(parent) and try matchGroup(D, d, selector, group, previous, parent, ctx)) break :blk true;
                        parent = d.nodes[parent].parent;
                    }
                    break :blk false;
                },
                .adjacent => blk: {
                    const sibling = common.prevElementSibling(d, node_index) orelse break :blk false;
                    break :blk try matchGroup(D, d, selector, group, previous, sibling, ctx);
                },
                .sibling => blk: {
                    var sibling = common.prevElementSibling(d, node_index);
                    while (sibling) |candidate| {
                        if (try matchGroup(D, d, selector, group, previous, candidate, ctx)) break :blk true;
                        sibling = common.prevElementSibling(d, candidate);
                    }
                    break :blk false;
                },
                .none => false,
            };
        }
    };

    const atoms = [_][]const u8{
        "main",     "div",            "span",  "i",            "b",            "em",          ".a",               ".b",
        "[data-x]", "[data-k=v]",     "div.a", "span[data-x]", ":first-child", ":last-child", ":nth-child(2n+1)", ":nth-child(2)",
        ":not(.a)", ":not([data-x])",
    };
    const combinators = [_][]const u8{ " ", " > ", " + ", " ~ " };

    var prng = std.Random.DefaultPrng.init(0x51e6_40d1_ffe2_cafe);
    const random = prng.random();
    for (0..320) |_| {
        var source = std.ArrayList(u8).empty;
        defer source.deinit(alloc);
        const group_count = 1 + random.uintLessThan(usize, 3);
        for (0..group_count) |group_index| {
            if (group_index != 0) try source.appendSlice(alloc, ", ");
            const compound_count = 1 + random.uintLessThan(usize, 6);
            for (0..compound_count) |compound_index| {
                if (compound_index != 0) try source.appendSlice(alloc, combinators[random.uintLessThan(usize, combinators.len)]);
                try source.appendSlice(alloc, atoms[random.uintLessThan(usize, atoms.len)]);
            }
        }

        var selector = try ast.Selector.compileRuntime(alloc, source.items);
        defer selector.deinit(alloc);

        var reference_ctx: matcher.NodeContext = .{};
        defer reference_ctx.deinit();
        var expected = std.ArrayList(IndexInt).empty;
        defer expected.deinit(alloc);
        var rtl = std.ArrayList(IndexInt).empty;
        defer rtl.deinit(alloc);

        var idx: IndexInt = 1;
        while (idx < doc.nodes.len) : (idx += 1) {
            if (try Reference.matches(Doc, &doc, selector, idx, &reference_ctx)) try expected.append(alloc, idx);
            if (try matcher.matchesSelectorAt(Doc, &doc, selector, idx, 0)) try rtl.append(alloc, idx);
        }
        try std.testing.expectEqualSlices(IndexInt, expected.items, rtl.items);

        var normal = std.ArrayList(IndexInt).empty;
        defer normal.deinit(alloc);
        var it = doc.queryRuntime(selector);
        defer it.deinit();
        while (try it.next()) |node| try normal.append(alloc, node.index);
        try std.testing.expectEqualSlices(IndexInt, expected.items, normal.items);

        var dynamic = std.ArrayList(IndexInt).empty;
        defer dynamic.deinit(alloc);
        var executor = forward.WideExecutor(Doc).init(&doc, selector, forward.buildPlan(selector), 0);
        defer executor.deinit();
        idx = 1;
        while (idx < doc.nodes.len) : (idx += 1) {
            if (try executor.process(idx)) try dynamic.append(alloc, idx);
        }
        try std.testing.expectEqualSlices(IndexInt, expected.items, dynamic.items);
    }
}

test "forward iterator preserves sibling and ancestry state across yields" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<div><i class=x><b class=x></b></i><i class=y></i><i class=y></i></div>".*;
    try resetParsed(.{}, &doc, &src);

    var paused = doc.query(".x, .x + .y, .x .x, .y + .y");
    defer paused.deinit();
    const first = (try paused.next()) orelse return error.TestUnexpectedResult;
    const second = (try paused.next()) orelse return error.TestUnexpectedResult;
    const third = (try paused.next()) orelse return error.TestUnexpectedResult;
    const fourth = (try paused.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(IndexInt, &.{ 2, 3, 4, 5 }, &.{ first.index, second.index, third.index, fourth.index });
    try std.testing.expect(try paused.next() == null);
}

test "scoped forward query seeds selector prefixes from outside ancestors" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<body class=outside><div id=scope><span id=inside></span><div><em id=deep></em></div></div></body>".*;
    try resetParsed(.{}, &doc, &src);
    const scope = firstQuery(doc.query("#scope")) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("inside", (firstQuery(scope.query(".outside span")) orelse return error.TestUnexpectedResult).getAttributeValueRaw("id").?);
    try std.testing.expect(firstQuery(scope.query("> span")) != null);
    try std.testing.expect(firstQuery(scope.query("> div em")) != null);
    try std.testing.expect(firstQuery(scope.query("body > #scope em")) != null);
}

test "forward plan boundary uses inline state through 64 compounds and wide state after it" {
    const alloc = std.testing.allocator;
    var source64 = std.ArrayList(u8).empty;
    defer source64.deinit(alloc);
    for (0..64) |i| {
        if (i != 0) try source64.append(alloc, ' ');
        try source64.appendSlice(alloc, "div");
    }
    var selector64 = try ast.Selector.compileRuntime(alloc, source64.items);
    defer selector64.deinit(alloc);
    try std.testing.expect(forward.buildPlan(selector64).stateful);

    var source63 = std.ArrayList(u8).empty;
    defer source63.deinit(alloc);
    for (0..63) |i| {
        if (i != 0) try source63.append(alloc, ' ');
        try source63.appendSlice(alloc, "div");
    }
    var selector63 = try ast.Selector.compileRuntime(alloc, source63.items);
    defer selector63.deinit(alloc);
    try std.testing.expect(forward.buildPlan(selector63).stateful);

    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..64) |_| try html_writer.writer.writeAll("<div>");
    for (0..64) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    var forward_it = doc.queryRuntime(selector64);
    defer forward_it.deinit();
    try std.testing.expect(std.meta.activeTag(forward_it.engine) == .compact);
    var forward_count: usize = 0;
    while (try forward_it.next()) |_| forward_count += 1;
    var rtl_count: usize = 0;
    var idx: IndexInt = 1;
    while (idx < doc.nodes.len) : (idx += 1) {
        if (try matcher.matchesSelectorAt(GetDocument(.{}), &doc, selector64, idx, 0)) rtl_count += 1;
    }
    try std.testing.expectEqual(rtl_count, forward_count);

    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..65) |i| {
        if (i != 0) try source.append(alloc, ' ');
        try source.appendSlice(alloc, "div");
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);
    try std.testing.expect(forward.buildPlan(selector).stateful);

    var wide_it = doc.queryRuntime(selector);
    defer wide_it.deinit();
    try std.testing.expect(std.meta.activeTag(wide_it.engine) == .wide);
    var wide_count: usize = 0;
    while (try wide_it.next()) |_| wide_count += 1;
    try std.testing.expectEqual(@as(usize, 0), wide_count);
}

test "wide forward query processes intermediate tags that cannot be final candidates" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..64) |_| try html_writer.writer.writeAll("<div>");
    try html_writer.writer.writeAll("<span id=target></span>");
    for (0..64) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    var selector_source = std.ArrayList(u8).empty;
    defer selector_source.deinit(alloc);
    for (0..64) |i| {
        if (i != 0) try selector_source.appendSlice(alloc, " > ");
        try selector_source.appendSlice(alloc, "div");
    }
    try selector_source.appendSlice(alloc, " > span#target");
    var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
    defer selector.deinit(alloc);
    try std.testing.expect(forward.buildPlan(selector).stateful);

    const target: IndexInt = @intCast(doc.nodes.len - 1);
    try std.testing.expect(try matcher.matchesSelectorAt(GetDocument(.{}), &doc, selector, target, 0));

    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
    const hit = (try it.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(target, hit.index);
    try std.testing.expect(try it.next() == null);
}

test "forward automaton processes and emits nested matches exactly once" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..128) |_| try html_writer.writer.writeAll("<div>");
    for (0..128) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    var it = doc.query("div div");
    defer it.deinit();
    var emitted: usize = 0;
    while (try it.next()) |_| emitted += 1;
    try std.testing.expectEqual(@as(usize, 127), emitted);
    try std.testing.expectEqual(@as(usize, 128), it.engine.compact.stats.nodes_processed);
    try std.testing.expectEqual(@as(usize, 127), it.engine.compact.stats.nodes_emitted);
    try std.testing.expectEqual(@as(usize, 128), it.engine.compact.stats.local_unique_predicate_evals);
}

test "dynamic forward fans a repeated predicate out once per node" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..128) |_| try html_writer.writer.writeAll("<div>");
    for (0..128) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var selector_source = std.ArrayList(u8).empty;
    defer selector_source.deinit(alloc);
    for (0..128) |i| {
        if (i != 0) try selector_source.append(alloc, ' ');
        try selector_source.appendSlice(alloc, "div");
    }
    var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
    defer selector.deinit(alloc);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
    while (try it.next()) |_| {}

    try std.testing.expectEqual(@as(usize, 128), it.engine.wide.stats.nodes_processed);
    try std.testing.expectEqual(@as(usize, 128), it.engine.wide.stats.local_unique_predicate_evals);
    // The one unique predicate spans exactly two state words. It should fan
    // into those two sparse uses once per node, not once per eligible state.
    try std.testing.expectEqual(@as(usize, 256), it.engine.wide.stats.predicate_state_word_fanouts);
}

test "forward query processes every element once across selector shapes" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..128) |_| try html_writer.writer.writeAll("<div>");
    for (0..128) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    const Case = struct {
        source: []const u8,
        expected: usize,
    };
    const cases = [_]Case{
        .{ .source = "div", .expected = 128 },
        .{ .source = "div div", .expected = 127 },
        .{ .source = "div div div div", .expected = 125 },
        .{ .source = "div, div div, div div div", .expected = 128 },
    };

    for (cases) |case| {
        var selector = try ast.Selector.compileRuntime(alloc, case.source);
        defer selector.deinit(alloc);
        var it = doc.queryRuntime(selector);
        defer it.deinit();
        try std.testing.expect(std.meta.activeTag(it.engine) == .compact);

        var count: usize = 0;
        var previous: ?IndexInt = null;
        while (try it.next()) |node| {
            if (previous) |prev| try std.testing.expect(node.index > prev);
            previous = node.index;
            count += 1;
        }
        try std.testing.expectEqual(case.expected, count);
        try std.testing.expectEqual(@as(usize, 128), it.engine.compact.stats.nodes_processed);
        try std.testing.expectEqual(case.expected, it.engine.compact.stats.nodes_emitted);
    }
}

test "forward terminal states are never propagated" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div><div><div></div></div></div>".*;
    try resetParsed(.{}, &doc, &html);

    var it = doc.query("div div");
    defer it.deinit();
    _ = (try it.next()) orelse return error.TestUnexpectedResult;

    const final_bit = @as(u64, 1) << 1;
    try std.testing.expect((it.engine.compact.root.self_matches & final_bit) == 0);
    try std.testing.expect((it.engine.compact.root.lineage_matches & final_bit) == 0);
    try std.testing.expect((it.engine.compact.root.prev_child_matches & final_bit) == 0);
    try std.testing.expect((it.engine.compact.root.any_child_matches & final_bit) == 0);
    for (it.engine.compact.stack.items) |frame| {
        try std.testing.expect((frame.self_matches & final_bit) == 0);
        try std.testing.expect((frame.lineage_matches & final_bit) == 0);
        try std.testing.expect((frame.prev_child_matches & final_bit) == 0);
        try std.testing.expect((frame.any_child_matches & final_bit) == 0);
    }
}

test "selector-list overlap emits each candidate once" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div><div><div></div></div></div>".*;
    try resetParsed(.{}, &doc, &html);

    var it = doc.query("div, div, div div, div div div");
    defer it.deinit();
    var indexes: [3]IndexInt = undefined;
    var count: usize = 0;
    while (try it.next()) |node| {
        indexes[count] = node.index;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(IndexInt, &.{ 1, 2, 3 }, indexes[0..count]);
}

test "wide RTL automaton shifts predecessor state across word boundaries" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    var selector_writer: std.Io.Writer.Allocating = .init(alloc);
    defer selector_writer.deinit();
    for (0..65) |i| {
        try html_writer.writer.writeAll("<div>");
        if (i != 0) try selector_writer.writer.writeByte(' ');
        try selector_writer.writer.writeAll("div");
    }
    for (0..65) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);
    const selector_source = try selector_writer.toOwnedSlice();
    defer alloc.free(selector_source);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);
    var selector = try ast.Selector.compileRuntime(alloc, selector_source);
    defer selector.deinit(alloc);
    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();

    try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(GetDocument(.{}), &doc, selector, @intCast(doc.nodes.len - 1), InvalidIndex, &workspace));
    try std.testing.expectEqual(@as(usize, 65), workspace.stats.reverse_nodes_processed);
    try std.testing.expectEqual(@as(usize, 65), workspace.stats.local_unique_predicate_evals);
}

test "dynamic forward and RTL transitions cross selector word boundaries" {
    const alloc = std.testing.allocator;

    var nested_html: std.Io.Writer.Allocating = .init(alloc);
    defer nested_html.deinit();
    for (0..129) |_| try nested_html.writer.writeAll("<div>");
    for (0..129) |_| try nested_html.writer.writeAll("</div>");
    const nested_source = try nested_html.toOwnedSlice();
    defer alloc.free(nested_source);
    var nested_doc = GetDocument(.{}).init(alloc);
    defer nested_doc.deinit();
    try resetParsed(.{}, &nested_doc, nested_source);
    const nested_target: IndexInt = @intCast(nested_doc.nodes.len - 1);

    var sibling_html: std.Io.Writer.Allocating = .init(alloc);
    defer sibling_html.deinit();
    try sibling_html.writer.writeAll("<main>");
    for (0..129) |_| try sibling_html.writer.writeAll("<i></i>");
    try sibling_html.writer.writeAll("</main>");
    const sibling_source = try sibling_html.toOwnedSlice();
    defer alloc.free(sibling_source);
    var sibling_doc = GetDocument(.{}).init(alloc);
    defer sibling_doc.deinit();
    try resetParsed(.{}, &sibling_doc, sibling_source);
    const sibling_target: IndexInt = @intCast(sibling_doc.nodes.len - 1);

    const Case = struct {
        separator: []const u8,
        tag: []const u8,
        sibling: bool,
    };
    const cases = [_]Case{
        .{ .separator = " > ", .tag = "div", .sibling = false },
        .{ .separator = " ", .tag = "div", .sibling = false },
        .{ .separator = " + ", .tag = "i", .sibling = true },
        .{ .separator = " ~ ", .tag = "i", .sibling = true },
    };

    for ([_]usize{ 65, 129 }) |compound_count| {
        for (cases) |case| {
            var selector_source = std.ArrayList(u8).empty;
            defer selector_source.deinit(alloc);
            for (0..compound_count) |i| {
                if (i != 0) try selector_source.appendSlice(alloc, case.separator);
                try selector_source.appendSlice(alloc, case.tag);
            }
            var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
            defer selector.deinit(alloc);

            const Doc = GetDocument(.{});
            const doc: *const Doc = if (case.sibling) &sibling_doc else &nested_doc;
            const target = if (case.sibling) sibling_target else nested_target;

            var it = doc.queryRuntime(selector);
            defer it.deinit();
            try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
            const first = (try it.next()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(compound_count, it.engine.wide.exec_plan.state_count);
            try std.testing.expectEqual(compound_count / 64 + @intFromBool(compound_count % 64 != 0), it.engine.wide.word_count);
            var saw_target = first.index == target;
            while (try it.next()) |node| {
                if (node.index == target) saw_target = true;
            }
            try std.testing.expect(saw_target);

            var workspace = matcher.MatchWorkspace.init(alloc);
            defer workspace.deinit();
            try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(Doc, doc, selector, target, InvalidIndex, &workspace));
        }
    }
}

test "RTL descendant failure merges ambiguous states and processes each node once" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..128) |_| try html_writer.writer.writeAll("<div>");
    for (0..128) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);

    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, ".never");
    for (1..64) |_| try source.appendSlice(alloc, " div");
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(GetDocument(.{}), &doc, selector, @intCast(doc.nodes.len - 1), InvalidIndex, &workspace));
    try std.testing.expectEqual(@as(usize, 128), workspace.stats.reverse_nodes_processed);
    try std.testing.expectEqual(@as(usize, 0), workspace.stats.reverse_node_duplicate_processes);
    try std.testing.expectEqual(workspace.stats.reverse_nodes_processed, workspace.stats.reverse_cells_created);
    try std.testing.expectEqual(workspace.stats.reverse_nodes_processed, workspace.stats.reverse_queue_pushes);
    try std.testing.expect(workspace.stats.local_unique_predicate_evals <= 128 * 2);
}

test "RTL reached-node map spills without duplicate processing" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    for (0..300) |_| try html_writer.writer.writeAll("<div>");
    for (0..300) |_| try html_writer.writer.writeAll("</div>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, ".never");
    for (1..64) |_| try source.appendSlice(alloc, " div");
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        selector,
        @intCast(doc.nodes.len - 1),
        InvalidIndex,
        &workspace,
    ));
    try std.testing.expectEqual(@as(usize, 300), workspace.stats.reverse_nodes_processed);
    try std.testing.expectEqual(@as(usize, 300), workspace.stats.reverse_cells_created);
    try std.testing.expectEqual(@as(usize, 300), workspace.stats.reverse_queue_pushes);
    try std.testing.expectEqual(@as(usize, 0), workspace.stats.reverse_node_duplicate_processes);
}

test "RTL workspace notices selector changes after allocator address reuse" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div class=a><x><div><div></div></div></x></div>".*;
    try resetParsed(.{}, &doc, &html);
    const target: IndexInt = @intCast(doc.nodes.len - 1);

    var selector_buffer: [4096]u8 = undefined;
    var first_allocator = std.heap.FixedBufferAllocator.init(&selector_buffer);
    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();

    const first = try ast.Selector.compileRuntime(first_allocator.allocator(), ".a div div");
    const first_source_ptr = first.source.ptr;
    const first_compounds_ptr = first.compounds.ptr;
    try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        first,
        target,
        InvalidIndex,
        &workspace,
    ));

    var second_allocator = std.heap.FixedBufferAllocator.init(&selector_buffer);
    const second = try ast.Selector.compileRuntime(second_allocator.allocator(), ".a~div div");
    // Equal-size compilation into a retained arena deliberately recreates the
    // pointer-identity ABA case that a workspace cache must not mistake for the
    // previous selector.
    try std.testing.expect(first_source_ptr == second.source.ptr);
    try std.testing.expect(first_compounds_ptr == second.compounds.ptr);
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        second,
        target,
        InvalidIndex,
        &workspace,
    ));
}

test "failed reverse-plan rebuild invalidates its previous selector identity" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div class=a><x><div><div></div></div></x></div>".*;
    try resetParsed(.{}, &doc, &html);
    const target: IndexInt = @intCast(doc.nodes.len - 1);

    var first = try ast.Selector.compileRuntime(alloc, ".a div div");
    defer first.deinit(alloc);
    var second = try ast.Selector.compileRuntime(alloc, ".a~div div");
    defer second.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{});
    var workspace = matcher.MatchWorkspace.init(failing.allocator());
    defer workspace.deinit();
    try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        first,
        target,
        InvalidIndex,
        &workspace,
    ));

    // Fail the first allocation after the cache miss. compileReversePlan has
    // already begun replacing the old plan at that point.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        second,
        target,
        InvalidIndex,
        &workspace,
    ));

    // Once allocation succeeds again, the first selector must be rebuilt, not
    // accepted against whatever partial state the failed second build left.
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        first,
        target,
        InvalidIndex,
        &workspace,
    ));
}

test "RTL sibling topology cache invalidates across document generations" {
    const alloc = std.testing.allocator;
    var selector = try ast.Selector.compileRuntime(alloc, "i ~ b");
    defer selector.deinit(alloc);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();

    // Both documents put <b> at index 4. The first topology says its previous
    // element is index 2; the second inserts the matching <i> at index 3.
    var first = "<main><x></x>text<b></b></main>".*;
    try resetParsed(.{}, &doc, &first);
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(GetDocument(.{}), &doc, selector, 4, InvalidIndex, &workspace));

    var second = "<main><x></x><i></i><b></b></main>".*;
    try resetParsed(.{}, &doc, &second);
    try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(GetDocument(.{}), &doc, selector, 4, InvalidIndex, &workspace));
}

test "RTL sibling failure merges witnesses and uses optional topology" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    try html_writer.writer.writeAll("<main>");
    for (0..128) |_| try html_writer.writer.writeAll("<i></i>");
    try html_writer.writer.writeAll("</main>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, ".never");
    for (1..64) |_| try source.appendSlice(alloc, " ~ i");
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var compact_doc = GetDocument(.{ .store_prev_sibling = false }).init(alloc);
    defer compact_doc.deinit();
    try resetParsed(.{ .store_prev_sibling = false }, &compact_doc, html);
    var compact_workspace = matcher.MatchWorkspace.init(alloc);
    defer compact_workspace.deinit();
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(@TypeOf(compact_doc), &compact_doc, selector, @intCast(compact_doc.nodes.len - 1), InvalidIndex, &compact_workspace));
    try std.testing.expectEqual(@as(usize, 128), compact_workspace.stats.reverse_nodes_processed);
    try std.testing.expectEqual(@as(usize, 0), compact_workspace.stats.reverse_node_duplicate_processes);
    try std.testing.expectEqual(compact_workspace.stats.reverse_nodes_processed, compact_workspace.stats.reverse_cells_created);
    try std.testing.expectEqual(compact_workspace.stats.reverse_nodes_processed, compact_workspace.stats.reverse_queue_pushes);
    try std.testing.expectEqual(@as(usize, 1), compact_workspace.stats.topology_parent_builds);
    try std.testing.expectEqual(@as(usize, 128), compact_workspace.stats.topology_child_visits);

    var linked_doc = GetDocument(.{ .store_prev_sibling = true }).init(alloc);
    defer linked_doc.deinit();
    try resetParsed(.{ .store_prev_sibling = true }, &linked_doc, html);
    var linked_workspace = matcher.MatchWorkspace.init(alloc);
    defer linked_workspace.deinit();
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(@TypeOf(linked_doc), &linked_doc, selector, @intCast(linked_doc.nodes.len - 1), InvalidIndex, &linked_workspace));
    try std.testing.expectEqual(@as(usize, 128), linked_workspace.stats.reverse_nodes_processed);
    try std.testing.expectEqual(@as(usize, 0), linked_workspace.stats.reverse_node_duplicate_processes);
    try std.testing.expectEqual(linked_workspace.stats.reverse_nodes_processed, linked_workspace.stats.reverse_cells_created);
    try std.testing.expectEqual(linked_workspace.stats.reverse_nodes_processed, linked_workspace.stats.reverse_queue_pushes);
    try std.testing.expectEqual(@as(usize, 0), linked_workspace.stats.topology_parent_builds);
}

test "large stateless selector lists use dynamic zero-state executor" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..128) |i| {
        if (i != 0) try source.appendSlice(alloc, ", ");
        var name_buf: [16]u8 = undefined;
        try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, ".a{}", .{i}));
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);
    const plan = forward.buildPlan(selector);
    try std.testing.expect(!plan.stateful);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div class=a127></div>".*;
    try resetParsed(.{}, &doc, &html);
    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
    try std.testing.expect(try it.next() != null);
    try std.testing.expectEqual(@as(usize, 0), it.engine.wide.exec_plan.state_count);
    try std.testing.expectEqual(@as(usize, 0), it.engine.wide.word_count);
    try std.testing.expect(!it.engine.wide.exec_plan.has_tag_constraints);
    try std.testing.expectEqual(@as(usize, 0), it.engine.wide.exec_plan.tag_dispatch.entries.len);
    try std.testing.expectEqual(@as(usize, 0), it.engine.wide.exec_plan.tag_dispatch.wildcard_simple.len);
    try std.testing.expectEqual(@as(usize, 0), it.engine.wide.tag_allowed.len);
    try std.testing.expectEqual(@as(usize, 1), it.engine.wide.stats.nodes_processed);
    try std.testing.expectEqual(@as(usize, 128), it.engine.wide.stats.local_unique_predicate_evals);
}

test "RTL point setup is proportional to reached nodes, not document size" {
    const alloc = std.testing.allocator;
    var html_writer: std.Io.Writer.Allocating = .init(alloc);
    defer html_writer.deinit();
    try html_writer.writer.writeAll("<main>");
    const unrelated_count: usize = @min(100_000, (common.MaxLen - 1024) / "<i></i>".len);
    for (0..unrelated_count) |_| try html_writer.writer.writeAll("<i></i>");
    for (0..8) |_| try html_writer.writer.writeAll("<div>");
    for (0..8) |_| try html_writer.writer.writeAll("</div>");
    try html_writer.writer.writeAll("</main>");
    const html = try html_writer.toOwnedSlice();
    defer alloc.free(html);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, html);
    const target: IndexInt = @intCast(doc.nodes.len - 1);
    try std.testing.expect(target > unrelated_count);

    var selector = try ast.Selector.compileRuntime(alloc, ".never div div");
    defer selector.deinit(alloc);
    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(GetDocument(.{}), &doc, selector, target, InvalidIndex, &workspace));

    // Only the eight-node ancestor chain and its <main> parent are reachable.
    try std.testing.expect(workspace.stats.reverse_nodes_processed <= 9);
    try std.testing.expectEqual(workspace.stats.reverse_nodes_processed, workspace.stats.reverse_cells_created);
    try std.testing.expectEqual(workspace.stats.reverse_nodes_processed, workspace.stats.reverse_queue_pushes);
    try std.testing.expectEqual(@as(usize, 0), workspace.stats.reverse_node_duplicate_processes);
}

test "deterministic point-match group avoids reverse-plan setup" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div id=target><span></span></div>".*;
    try resetParsed(.{}, &doc, &html);
    const target: IndexInt = @intCast(doc.nodes.len - 1);

    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "#target > span, .never");
    for (0..96) |_| try source.appendSlice(alloc, " div");
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var workspace = matcher.MatchWorkspace.init(failing.allocator());
    defer workspace.deinit();
    try std.testing.expect(try matcher.matchesSelectorAtWithWorkspace(GetDocument(.{}), &doc, selector, target, InvalidIndex, &workspace));
    try std.testing.expectEqual(@as(usize, 0), workspace.execution_plan.state_count);
    try std.testing.expectEqual(@as(usize, 0), workspace.stats.reverse_cells_created);
    try std.testing.expectEqual(@as(usize, 0), workspace.stats.reverse_queue_pushes);
}

test "reverse point matching cleans up every allocation failure" {
    const alloc = std.testing.allocator;
    const Doc = GetDocument(.{});

    var doc = Doc.init(alloc);
    defer doc.deinit();
    var html = "<main><div class=a><div><span></span></div></div><i></i></main>".*;
    try resetParsed(.{}, &doc, &html);
    var selector = try ast.Selector.compileRuntime(alloc, ".missing div span, .also-missing ~ span");
    defer selector.deinit(alloc);
    const target: IndexInt = 4;

    const Case = struct {
        fn run(allocator: std.mem.Allocator, original: *const Doc, sel: ast.Selector, node: IndexInt) !void {
            var workspace = matcher.MatchWorkspace.init(allocator);
            defer workspace.deinit();
            try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(
                Doc,
                original,
                sel,
                node,
                InvalidIndex,
                &workspace,
            ));
        }
    };
    try std.testing.checkAllAllocationFailures(alloc, Case.run, .{ &doc, selector, target });
}

test "dynamic forward initialization cleans up every allocation failure" {
    const alloc = std.testing.allocator;
    const Doc = GetDocument(.{});

    var selector_source = std.ArrayList(u8).empty;
    defer selector_source.deinit(alloc);
    for (0..65) |i| {
        if (i != 0) try selector_source.append(alloc, ' ');
        try selector_source.appendSlice(alloc, "div");
    }
    var selector = try ast.Selector.compileRuntime(alloc, selector_source.items);
    defer selector.deinit(alloc);

    var doc = Doc.init(alloc);
    defer doc.deinit();
    var html = "<div></div>".*;
    try resetParsed(.{}, &doc, &html);

    const Case = struct {
        fn run(allocator: std.mem.Allocator, original: *const Doc, sel: ast.Selector) !void {
            // The document storage remains owned by the test allocator; only
            // executor scratch is redirected through the failing allocator.
            var local_doc = original.*;
            local_doc.allocator = allocator;
            var executor = forward.WideExecutor(Doc).init(&local_doc, sel, forward.buildPlan(sel), 0);
            defer executor.deinit();
            _ = try executor.process(1);
        }
    };
    try std.testing.checkAllAllocationFailures(alloc, Case.run, .{ &doc, selector });
}

test "dynamic simple groups evaluate one repeated local predicate" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..128) |i| {
        if (i != 0) try source.appendSlice(alloc, ",");
        try source.appendSlice(alloc, "div");
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div></div>".*;
    try resetParsed(.{}, &doc, &html);
    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
    try std.testing.expect(try it.next() != null);
    try std.testing.expectEqual(@as(usize, 1), it.engine.wide.stats.local_unique_predicate_evals);
}

test "dynamic predicate cache is cleared only for predicates touched on the previous node" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..128) |i| {
        if (i != 0) try source.appendSlice(alloc, ",");
        try source.appendSlice(alloc, "[data-x]");
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<main><div data-x></div><div></div></main>".*;
    try resetParsed(.{}, &doc, &html);
    var it = doc.queryRuntime(selector);
    defer it.deinit();
    const hit = (try it.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(IndexInt, 2), hit.index);
    try std.testing.expect(try it.next() == null);
    try std.testing.expectEqual(@as(usize, 3), it.engine.wide.stats.local_unique_predicate_evals);
}

test "reverse predicate cache does not leak local results across reached nodes" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div><div data-x></div></div>".*;
    try resetParsed(.{}, &doc, &html);
    var selector = try ast.Selector.compileRuntime(alloc, "[data-x] [data-x]");
    defer selector.deinit(alloc);
    var workspace = matcher.MatchWorkspace.init(alloc);
    defer workspace.deinit();
    try std.testing.expect(!try matcher.matchesSelectorAtWithWorkspace(
        GetDocument(.{}),
        &doc,
        selector,
        @intCast(doc.nodes.len - 1),
        InvalidIndex,
        &workspace,
    ));
    try std.testing.expectEqual(@as(usize, 2), workspace.stats.local_unique_predicate_evals);
}

test "dynamic tag dispatch preserves selector-list short-circuit order" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "div");
    for (0..127) |i| {
        var name_buf: [24]u8 = undefined;
        try source.appendSlice(alloc, ",");
        try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, ".never{}", .{i}));
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<div></div>".*;
    try resetParsed(.{}, &doc, &html);
    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
    try std.testing.expect(try it.next() != null);
    try std.testing.expectEqual(@as(usize, 1), it.engine.wide.stats.local_unique_predicate_evals);
}

test "dynamic tag dispatch rejects incompatible simple predicates before local matching" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..128) |i| {
        if (i != 0) try source.appendSlice(alloc, ",");
        var name_buf: [24]u8 = undefined;
        try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, "x{}", .{i}));
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);

    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<x127></x127>".*;
    try resetParsed(.{}, &doc, &html);
    var it = doc.queryRuntime(selector);
    defer it.deinit();
    try std.testing.expect(std.meta.activeTag(it.engine) == .wide);
    try std.testing.expect(try it.next() != null);
    try std.testing.expectEqual(@as(usize, 1), it.engine.wide.stats.local_unique_predicate_evals);
}

test "node matches uses candidate-centric point matching" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var html = "<main><div id=p><span class=x></span></div></main>".*;
    try resetParsed(.{}, &doc, &html);
    const span = firstQuery(doc.query("span.x")) orelse return error.TestUnexpectedResult;

    try std.testing.expect(try span.matches("main div > span.x"));
    try std.testing.expect(!try span.matches("aside span.x"));
    try std.testing.expectError(error.InvalidSelector, span.matches("> span"));

    var runtime = try ast.Selector.compileRuntime(alloc, "#p > span.x");
    defer runtime.deinit(alloc);
    try std.testing.expect(try span.matchesRuntime(runtime));
    var prepared = try prepared_selector.PreparedSelector.compile(alloc, "main #p > span.x");
    defer prepared.deinit();
    try std.testing.expect(try span.matchesPrepared(&prepared));
    var relative = try ast.Selector.compileRuntime(alloc, "+ span");
    defer relative.deinit(alloc);
    try std.testing.expectError(error.InvalidSelector, span.matchesRuntime(relative));
}

test "query collect frees partial output when growth fails" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();

    var src: std.Io.Writer.Allocating = .init(alloc);
    defer src.deinit();
    try src.writer.writeAll("<div>");
    for (0..64) |_| try src.writer.writeAll("<span></span>");
    try src.writer.writeAll("</div>");
    const doc_source = try src.toOwnedSlice();
    defer alloc.free(doc_source);
    try resetParsed(.{}, &doc, doc_source);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
    var it = doc.query("span");
    try std.testing.expectError(error.OutOfMemory, it.collect(failing.allocator()));
}

test "serialization state matrix after attribute and text decoding" {
    const alloc = std.testing.allocator;
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    var src = "<div title=\"a&amp;b &quot;c&quot;\">a&amp;b   a&lt;b</div>".*;
    try resetParsed(.{}, &doc, &src);
    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var before: std.Io.Writer.Allocating = .init(alloc);
    defer before.deinit();
    try div.writeHtml(&before.writer, .never);
    try std.testing.expectEqualStrings(
        "<div title=\"a&amp;b &quot;c&quot;\">a&amp;b   a&lt;b</div>",
        before.written(),
    );

    const title = (try div.getAttributeValue(alloc, "title")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b \"c\"", title.value);

    var after_attr: std.Io.Writer.Allocating = .init(alloc);
    defer after_attr.deinit();
    try div.writeHtml(&after_attr.writer, .never);
    try std.testing.expectEqualStrings(before.written(), after_attr.written());

    const decoded = try div.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("a&b   a<b", decoded.value);

    var raw: std.Io.Writer.Allocating = .init(alloc);
    defer raw.deinit();
    try div.writeHtml(&raw.writer, .never);
    try std.testing.expectEqualStrings(
        "<div title=\"a&amp;b &quot;c&quot;\">a&b   a<b</div>",
        raw.written(),
    );

    const normalized = try div.innerTextWithOptions(alloc, .{});
    try std.testing.expectEqualStrings("a&b a<b", normalized.value);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try div.writeHtml(&encoded.writer, .force);
    try std.testing.expectEqualStrings(
        "<div title=\"a&amp;b &quot;c&quot;\">a&amp;b a&lt;b</div>",
        encoded.written(),
    );
}

test "chunked escaping preserves large sparse attribute and text spans" {
    const alloc = std.testing.allocator;
    var input: std.Io.Writer.Allocating = .init(alloc);
    defer input.deinit();
    try input.writer.writeAll("<div title=\"");
    for (0..4096) |_| try input.writer.writeAll("a");
    try input.writer.writeAll("&amp;&quot;&lt;");
    for (0..4096) |_| try input.writer.writeAll("b");
    try input.writer.writeAll("\">");
    for (0..4096) |_| try input.writer.writeAll("x");
    try input.writer.writeAll("&amp;&lt;&gt;");
    for (0..4096) |_| try input.writer.writeAll("y");
    try input.writer.writeAll("</div>");

    const source = try input.toOwnedSlice();
    defer alloc.free(source);
    const expected = try alloc.dupe(u8, source);
    defer alloc.free(expected);
    var doc = GetDocument(.{}).init(alloc);
    defer doc.deinit();
    try resetParsed(.{}, &doc, source);

    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try doc.writeHtml(&output.writer, .force);
    try std.testing.expectEqualSlices(u8, expected, output.written());

    const CountingWriter = struct {
        pub const Error = error{};
        calls: usize = 0,
        bytes: usize = 0,

        pub fn writeAll(self: *@This(), bytes: []const u8) Error!void {
            self.calls += 1;
            self.bytes += bytes.len;
        }
    };
    var counter: CountingWriter = .{};
    try doc.writeHtml(&counter, .force);
    try std.testing.expectEqual(expected.len, counter.bytes);
    try std.testing.expect(counter.calls < 64);
}

test "prepared wide selector matches runtime query for document and scope" {
    const alloc = std.testing.allocator;
    var source_writer: std.Io.Writer.Allocating = .init(alloc);
    defer source_writer.deinit();
    try source_writer.writer.writeAll("<main><section>");
    for (0..72) |_| try source_writer.writer.writeAll("<div>");
    try source_writer.writer.writeAll("<span id=target></span>");
    for (0..72) |_| try source_writer.writer.writeAll("</div>");
    try source_writer.writer.writeAll("</section></main>");
    const source = try source_writer.toOwnedSlice();
    defer alloc.free(source);

    var selector_writer: std.Io.Writer.Allocating = .init(alloc);
    defer selector_writer.deinit();
    for (0..72) |_| try selector_writer.writer.writeAll("div ");
    try selector_writer.writer.writeAll("span#target");
    const selector_source = try selector_writer.toOwnedSlice();
    defer alloc.free(selector_source);

    const opts: ParseOptions = .{};
    var doc = try opts.parse(alloc, source);
    defer doc.deinit();
    var prepared = try prepared_selector.PreparedSelector.compile(alloc, selector_source);
    defer prepared.deinit();

    var runtime_it = doc.queryRuntime(prepared.selector);
    defer runtime_it.deinit();
    var prepared_it = doc.queryPrepared(&prepared);
    defer prepared_it.deinit();
    const runtime_match = (try runtime_it.next()) orelse return error.TestUnexpectedResult;
    const prepared_match = (try prepared_it.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(runtime_match.index, prepared_match.index);
    try std.testing.expect((try runtime_it.next()) == null);
    try std.testing.expect((try prepared_it.next()) == null);

    const section = firstQuery(doc.query("section")) orelse return error.TestUnexpectedResult;
    var scoped = section.queryPrepared(&prepared);
    defer scoped.deinit();
    const scoped_match = (try scoped.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(prepared_match.index, scoped_match.index);
}
