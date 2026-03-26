const std = @import("std");
const tables = @import("tables.zig");
const attr_inline = @import("attr_inline.zig");
const runtime_selector = @import("../selector/runtime.zig");
const ast = @import("../selector/ast.zig");
const matcher = @import("../selector/matcher.zig");
const matcher_debug = @import("../selector/matcher_debug.zig");
const selector_debug = @import("../debug/selector_debug.zig");
const instrumentation = @import("../debug/instrumentation.zig");
const parser = @import("parser.zig");
const node_api = @import("node.zig");
const tags = @import("tags.zig");
const common = @import("../common.zig");

// SAFETY: Document owns `source` bytes for the life of nodes/iterators.
// Node spans and indices are validated on parse; helpers guard against
// InvalidIndex and out-of-range indexes.

/// Sentinel used for missing node indexes and invalid spans.
pub const InvalidIndex: u32 = common.InvalidIndex;
const QueryAccelMinBudgetBytes: usize = 4096;
const QueryAccelBudgetDivisor: usize = 20; // 5%

const IndexSpan = struct {
    start: u32 = 0,
    len: u32 = 0,
};

const QueryAccelIdLookup = union(enum) {
    unavailable,
    miss,
    hit: u32,
};

const QueryAccelTagLookup = union(enum) {
    unavailable,
    hit: []const u32,
};

const TagIndexEntry = struct {
    tag_len: u16,
    tag_key: u64,
    span: IndexSpan,
};

/// Stored node kind in the raw DOM backing arrays.
pub const NodeType = enum(u3) {
    document,
    element,
    text,

    /// Formats this node type for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

const isElementLike = common.isElementLike;

/// Compile-time parser options and type factory for generated public API types.
pub const ParseOptions = struct {
    // In fastest-mode style runs, whitespace-only text nodes can be dropped.
    drop_whitespace_text_nodes: bool = true,

    /// Formats parse options for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ParseOptions{{drop_whitespace_text_nodes={}}}", .{self.drop_whitespace_text_nodes});
    }

    /// Returns the raw node storage layout used by `Document.nodes`.
    pub fn GetNodeRaw(_: @This()) type {
        return struct {
            //! Backing node storage record for parsed DOM state.
            kind: NodeType,

            name_or_text: Span = .{},

            // Attribute bytes begin at `name_or_text.end` for element nodes and
            // end at `attr_end`.
            attr_end: u32 = 0,

            last_child: u32 = InvalidIndex, // first_child can be derived from the index of this node
            prev_sibling: u32 = InvalidIndex, // next_sibling can be derived form subtree_end
            parent: u32 = InvalidIndex,

            subtree_end: u32 = 0,
        };
    }

    /// Returns the parser's open-element stack entry type.
    pub fn GetOpenElem(_: @This()) type {
        return struct {
            tag_key: u64 = 0,
            idx: u32,
            tag_len: u16 = 0,
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

            doc: *DocType,
            index: u32,

            /// Returns the underlying raw node record.
            pub fn raw(self: @This()) *const options.GetNodeRaw() {
                return &self.doc.nodes.items[self.index];
            }

            /// Returns element tag name bytes from parsed source.
            pub fn tagName(self: @This()) []const u8 {
                return self.raw().name_or_text.slice(self.doc.source);
            }

            /// Writes HTML serialization of this node and its subtree to `writer`.
            pub fn writeHtml(self: @This(), writer: anytype) node_api.WriterError(@TypeOf(writer))!void {
                return node_api.writeHtml(self, writer);
            }

            /// Writes HTML serialization of this node only, excluding its children.
            pub fn writeHtmlSelf(self: @This(), writer: anytype) node_api.WriterError(@TypeOf(writer))!void {
                return node_api.writeHtmlSelf(self, writer);
            }

            /// Default formatter uses HTML serialization for this node.
            pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.writeHtml(writer);
            }

            /// Returns text content of this subtree; may borrow or allocate in `arena_alloc`.
            pub fn innerText(self: @This(), arena_alloc: std.mem.Allocator) ![]const u8 {
                return node_api.innerText(self, arena_alloc, .{});
            }

            /// Same as `innerText` but with explicit text-normalization options.
            pub fn innerTextWithOptions(self: @This(), arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
                return node_api.innerText(self, arena_alloc, opts);
            }

            /// Always materializes subtree text into newly allocated output.
            pub fn innerTextOwned(self: @This(), arena_alloc: std.mem.Allocator) ![]const u8 {
                return node_api.innerTextOwned(self, arena_alloc, .{});
            }

            /// Owned variant of `innerTextWithOptions`.
            pub fn innerTextOwnedWithOptions(self: @This(), arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
                return node_api.innerTextOwned(self, arena_alloc, opts);
            }

            /// Returns decoded attribute value for `name`, if present.
            pub fn getAttributeValue(self: @This(), name: []const u8) ?[]const u8 {
                return node_api.getAttributeValue(self, name);
            }

            /// Returns first element child.
            pub fn firstChild(self: @This()) ?@This() {
                return node_api.firstChild(self);
            }

            /// Returns last element child.
            pub fn lastChild(self: @This()) ?@This() {
                return node_api.lastChild(self);
            }

            /// Returns next element sibling.
            pub fn nextSibling(self: @This()) ?@This() {
                return node_api.nextSibling(self);
            }

            /// Returns previous element sibling.
            pub fn prevSibling(self: @This()) ?@This() {
                return node_api.prevSibling(self);
            }

            /// Returns parent element node.
            pub fn parentNode(self: @This()) ?@This() {
                return node_api.parentNode(self);
            }

            /// Returns direct-child node iterator.
            pub fn children(self: @This()) ChildrenIterType {
                return node_api.children(self);
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
            pub fn queryOneRuntime(self: @This(), selector: []const u8) runtime_selector.Error!?@This() {
                return self.doc.queryOneRuntimeFrom(selector, self.index);
            }

            /// Runtime debug query returning first match, diagnostics, and parse error if any.
            pub fn queryOneRuntimeDebug(self: @This(), selector: []const u8) DebugQueryResultType {
                return self.doc.queryOneRuntimeDebugFrom(selector, self.index);
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
            pub fn queryAllRuntime(self: @This(), selector: []const u8) runtime_selector.Error!QueryIterType {
                return self.doc.queryAllRuntimeFrom(selector, self.index);
            }
        };
    }

    /// Returns the lazy query iterator type for this option set.
    pub fn QueryIter(options: @This()) type {
        return struct {
            //! Lazy selector iterator over document or scoped subtree matches.
            const DocType = options.GetDocument();
            const NodeTypeWrapper = options.GetNode();

            doc: *DocType,
            selector: ast.Selector,
            scope_root: u32 = InvalidIndex,
            next_index: u32 = 1,
            runtime_generation: u64 = 0,

            /// Returns next matching node or `null` when exhausted.
            pub fn next(noalias self: *@This()) ?NodeTypeWrapper {
                if (self.runtime_generation != 0 and self.runtime_generation != self.doc.query_all_generation) {
                    return null;
                }

                while (self.next_index < self.doc.nodes.items.len) : (self.next_index += 1) {
                    const idx = self.next_index;

                    if (self.scope_root != InvalidIndex) {
                        const root = &self.doc.nodes.items[self.scope_root];
                        if (idx <= self.scope_root or idx > root.subtree_end) continue;
                    }

                    const node = &self.doc.nodes.items[idx];
                    if (!isElementLike(node.kind)) continue;

                    if (matcher.matchesSelectorAt(DocType, self.doc, self.selector, idx, self.scope_root)) {
                        self.next_index += 1;
                        return self.doc.nodeAt(idx);
                    }
                }
                return null;
            }

            /// Formats iterator state for human-readable output.
            pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                try writer.print("QueryIter{{scope_root={}, next_index={}, runtime_generation={}}}", .{
                    self.scope_root,
                    self.next_index,
                    self.runtime_generation,
                });
            }
        };
    }

    /// Returns the structured result type for debug query helpers.
    pub fn QueryDebugResult(options: @This()) type {
        return struct {
            node: ?options.GetNode() = null,
            report: selector_debug.QueryDebugReport = .{},
            err: ?runtime_selector.Error = null,
        };
    }

    /// Returns direct-child iterator type for this option set.
    pub fn ChildrenIter(options: @This()) type {
        return struct {
            //! Iterator over direct child nodes for a parent node.
            const DocType = options.GetDocument();
            const NodeTypeWrapper = options.GetNode();

            doc: *const DocType,
            next_idx: u32 = InvalidIndex,

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
            pub const OpenElemType = options.GetOpenElem();
            const ChildrenIterType = options.ChildrenIter();
            const NodeTypeWrapper = options.GetNode();
            const QueryIterType = options.QueryIter();

            allocator: std.mem.Allocator,
            source: []u8 = &[_]u8{},

            nodes: std.ArrayListUnmanaged(RawNodeType) = .empty,
            parse_stack: std.ArrayListUnmanaged(OpenElemType) = .empty,

            query_one_arena: ?std.heap.ArenaAllocator = null,
            query_all_arena: ?std.heap.ArenaAllocator = null,
            query_all_generation: u64 = 1,

            query_accel_budget_bytes: usize = 0,
            query_accel_used_bytes: usize = 0,
            query_accel_budget_exhausted: bool = false,
            query_accel_id_built: bool = false,
            query_accel_id_disabled: bool = false,
            query_accel_tag_disabled: bool = false,
            query_accel_id_map: std.AutoHashMapUnmanaged(u64, u32) = .{},
            query_accel_tag_entries: std.ArrayListUnmanaged(TagIndexEntry) = .empty,
            query_accel_tag_nodes: std.ArrayListUnmanaged(u32) = .empty,

            /// Initializes an empty document using `allocator` for internal storage.
            pub fn init(allocator: std.mem.Allocator) DocSelf {
                return .{
                    .allocator = allocator,
                };
            }

            /// Releases all document-owned memory.
            pub fn deinit(noalias self: *DocSelf) void {
                self.nodes.deinit(self.allocator);
                self.parse_stack.deinit(self.allocator);
                self.query_accel_id_map.deinit(self.allocator);
                self.query_accel_tag_entries.deinit(self.allocator);
                self.query_accel_tag_nodes.deinit(self.allocator);
                if (self.query_one_arena) |*arena| arena.deinit();
                if (self.query_all_arena) |*arena| arena.deinit();
            }

            /// Clears parsed state while retaining reusable capacities.
            pub fn clear(noalias self: *DocSelf) void {
                self.source = &[_]u8{};
                self.nodes.clearRetainingCapacity();
                self.parse_stack.clearRetainingCapacity();
                if (self.query_one_arena) |*arena| _ = arena.reset(.retain_capacity);
                if (self.query_all_arena) |*arena| _ = arena.reset(.retain_capacity);
                self.query_accel_budget_bytes = 0;
                self.resetQueryAccel();
                self.query_all_generation +%= 1;
                if (self.query_all_generation == 0) self.query_all_generation = 1;
            }

            /// Parses mutable HTML input in-place with supplied parse options.
            pub fn parse(noalias self: *DocSelf, input: []u8, comptime opts: ParseOptions) !void {
                self.clear();
                self.source = input;
                self.query_accel_budget_bytes = @max(input.len / QueryAccelBudgetDivisor, QueryAccelMinBudgetBytes);
                try parser.parseInto(DocSelf, self, input, opts);
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
            pub fn queryOneRuntime(self: *const DocSelf, selector: []const u8) runtime_selector.Error!?NodeTypeWrapper {
                return self.queryOneRuntimeFrom(selector, InvalidIndex);
            }

            /// Runtime debug query returning first match, diagnostics report, and parse error if any.
            pub fn queryOneRuntimeDebug(self: *const DocSelf, selector: []const u8) DebugQueryResultType {
                return self.queryOneRuntimeDebugFrom(selector, InvalidIndex);
            }

            fn queryOneRuntimeFrom(self: *const DocSelf, selector: []const u8, scope_root: u32) runtime_selector.Error!?NodeTypeWrapper {
                const mut_self: *DocSelf = @constCast(self);
                const arena = mut_self.ensureQueryOneArena();
                _ = arena.reset(.retain_capacity);
                const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
                return self.queryOneCachedFrom(sel, scope_root);
            }

            fn queryOneRuntimeDebugFrom(self: *const DocSelf, selector: []const u8, scope_root: u32) DebugQueryResultType {
                const mut_self: *DocSelf = @constCast(self);
                var report: selector_debug.QueryDebugReport = .{};
                report.reset(selector, scope_root, 0);
                const arena = mut_self.ensureQueryOneArena();
                _ = arena.reset(.retain_capacity);
                const sel = ast.Selector.compileRuntime(arena.allocator(), selector) catch |err| {
                    report.setRuntimeParseError();
                    return .{
                        .report = report,
                        .err = err,
                    };
                };
                return self.queryOneCachedDebugFrom(sel, scope_root);
            }

            fn queryOneCachedFrom(self: *const DocSelf, sel: ast.Selector, scope_root: u32) ?NodeTypeWrapper {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel);
                const idx = matcher.queryOneIndex(DocSelf, self, sel, scope_root) orelse InvalidIndex;
                if (idx == InvalidIndex) return null;
                return self.nodeAt(idx);
            }

            fn queryOneCachedDebugFrom(self: *const DocSelf, sel: ast.Selector, scope_root: u32) DebugQueryResultType {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel);
                var report: selector_debug.QueryDebugReport = .{};
                const idx = matcher_debug.explainFirstMatch(DocSelf, self, sel, scope_root, &report) orelse {
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
            pub fn queryAllRuntime(self: *const DocSelf, selector: []const u8) runtime_selector.Error!QueryIterType {
                return self.queryAllRuntimeFrom(selector, InvalidIndex);
            }

            fn queryAllRuntimeFrom(self: *const DocSelf, selector: []const u8, scope_root: u32) runtime_selector.Error!QueryIterType {
                const mut_self: *DocSelf = @constCast(self);
                // Runtime query-all iterators are invalidated when a newer runtime
                // query-all is created, to avoid holding selector memory that may be
                // replaced by the next runtime compile in `query_all_arena`.
                mut_self.query_all_generation +%= 1;
                if (mut_self.query_all_generation == 0) mut_self.query_all_generation = 1;

                const arena = mut_self.ensureQueryAllArena();
                _ = arena.reset(.retain_capacity);
                const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
                mut_self.ensureQueryPrereqs(sel);
                var out = if (scope_root == InvalidIndex)
                    self.queryAllCached(sel)
                else
                    QueryIterType{
                        .doc = @constCast(self),
                        .selector = sel,
                        .scope_root = scope_root,
                        .next_index = scope_root + 1,
                    };
                out.runtime_generation = mut_self.query_all_generation;
                return out;
            }

            fn ensureQueryPrereqs(noalias self: *DocSelf, selector: ast.Selector) void {
                _ = .{ self, selector };
            }

            /// Returns parent index for `idx`.
            pub fn parentIndex(self: *const DocSelf, idx: u32) u32 {
                if (idx >= self.nodes.items.len) return InvalidIndex;
                return self.nodes.items[idx].parent;
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
                    if (!isElementLike(n.kind)) continue;
                    if (tables.eqlIgnoreCaseAscii(n.name_or_text.slice(self.source), name)) return self.nodeAt(@intCast(i));
                }
                return null;
            }

            /// Wraps raw node index as public `Node` wrapper when valid.
            pub inline fn nodeAt(self: *const DocSelf, idx: u32) ?NodeTypeWrapper {
                if (idx == InvalidIndex or idx >= self.nodes.items.len) return null;
                return .{
                    .doc = @constCast(self),
                    .index = idx,
                };
            }

            /// Writes HTML serialization of this node and its subtree to `writer`.
            pub fn writeHtml(self: @This(), writer: anytype) node_api.WriterError(@TypeOf(writer))!void {
                return node_api.writeHtml(self.nodeAt(0).?, writer);
            }

            /// Writes HTML serialization of this document root only, excluding its children.
            pub fn writeHtmlSelf(self: @This(), writer: anytype) node_api.WriterError(@TypeOf(writer))!void {
                return node_api.writeHtmlSelf(self.nodeAt(0).?, writer);
            }

            /// Default formatter uses HTML serialization for this node.
            pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.writeHtml(writer);
            }

            fn ensureQueryOneArena(noalias self: *DocSelf) *std.heap.ArenaAllocator {
                if (self.query_one_arena == null) {
                    self.query_one_arena = std.heap.ArenaAllocator.init(self.allocator);
                }
                return &self.query_one_arena.?;
            }

            fn ensureQueryAllArena(noalias self: *DocSelf) *std.heap.ArenaAllocator {
                if (self.query_all_arena == null) {
                    self.query_all_arena = std.heap.ArenaAllocator.init(self.allocator);
                }
                return &self.query_all_arena.?;
            }

            fn resetQueryAccel(self: *DocSelf) void {
                self.query_accel_used_bytes = 0;
                self.query_accel_budget_exhausted = false;
                self.query_accel_id_built = false;
                self.query_accel_id_disabled = false;
                self.query_accel_tag_disabled = false;
                self.query_accel_id_map.clearRetainingCapacity();
                self.query_accel_tag_entries.clearRetainingCapacity();
                self.query_accel_tag_nodes.clearRetainingCapacity();
            }

            fn queryAccelReserve(self: *DocSelf, bytes: usize) bool {
                if (self.query_accel_budget_exhausted) return false;
                const remaining = self.query_accel_budget_bytes -| self.query_accel_used_bytes;
                if (bytes > remaining) {
                    self.query_accel_budget_exhausted = true;
                    return false;
                }
                self.query_accel_used_bytes += bytes;
                return true;
            }

            fn ensureIdIndex(self: *DocSelf) bool {
                if (self.query_accel_id_built) return true;
                if (self.query_accel_id_disabled or self.query_accel_budget_exhausted) return false;

                self.query_accel_id_map.clearRetainingCapacity();

                var idx: u32 = 1;
                while (idx < self.nodes.items.len) : (idx += 1) {
                    const node = &self.nodes.items[idx];
                    if (!isElementLike(node.kind)) continue;

                    const id = attr_inline.getAttrValue(self, node, "id") orelse continue;
                    if (id.len == 0) continue;
                    const id_hash = hashIdValue(id);

                    const gop = self.query_accel_id_map.getOrPut(self.allocator, id_hash) catch {
                        self.query_accel_id_disabled = true;
                        self.query_accel_id_map.clearRetainingCapacity();
                        return false;
                    };

                    if (gop.found_existing) {
                        const existing_idx = gop.value_ptr.*;
                        const existing_node = &self.nodes.items[existing_idx];
                        const existing_id = attr_inline.getAttrValue(self, existing_node, "id") orelse "";
                        // Hash collision on different ids would break index correctness.
                        // Disable this accel path and fall back to exact scan semantics.
                        if (!std.mem.eql(u8, existing_id, id)) {
                            self.query_accel_id_disabled = true;
                            self.query_accel_id_map.clearRetainingCapacity();
                            return false;
                        }
                        continue;
                    }

                    if (!self.queryAccelReserve(@sizeOf(u64) + @sizeOf(u32) + 16)) {
                        _ = self.query_accel_id_map.remove(id_hash);
                        self.query_accel_id_disabled = true;
                        self.query_accel_id_map.clearRetainingCapacity();
                        return false;
                    }

                    gop.value_ptr.* = idx;
                }

                self.query_accel_id_built = true;
                return true;
            }

            fn ensureTagIndex(self: *DocSelf, tag_name: []const u8, tag_key: u64) ?IndexSpan {
                if (self.query_accel_tag_disabled or self.query_accel_budget_exhausted) return null;
                const tag_len: u16 = @intCast(tag_name.len);
                for (self.query_accel_tag_entries.items) |entry| {
                    if (entry.tag_len == tag_len and entry.tag_key == tag_key) return entry.span;
                }

                var count: usize = 0;
                var scan_idx: usize = 1;
                while (scan_idx < self.nodes.items.len) : (scan_idx += 1) {
                    const node = self.nodes.items[scan_idx];
                    if (!isElementLike(node.kind)) continue;
                    const node_name = node.name_or_text.slice(self.source);
                    if (node_name.len != tag_name.len) continue;
                    if (tags.first8Key(node_name) != tag_key) continue;
                    count += 1;
                }

                const reserve_bytes = count * @sizeOf(u32) + @sizeOf(TagIndexEntry);
                if (!self.queryAccelReserve(reserve_bytes)) {
                    self.query_accel_tag_disabled = true;
                    return null;
                }

                const start: usize = self.query_accel_tag_nodes.items.len;
                self.query_accel_tag_nodes.ensureTotalCapacity(self.allocator, start + count) catch {
                    self.query_accel_tag_disabled = true;
                    return null;
                };

                var idx: u32 = 1;
                while (idx < self.nodes.items.len) : (idx += 1) {
                    const node = &self.nodes.items[idx];
                    if (!isElementLike(node.kind)) continue;
                    const node_name = node.name_or_text.slice(self.source);
                    if (node_name.len != tag_name.len) continue;
                    if (tags.first8Key(node_name) != tag_key) continue;
                    self.query_accel_tag_nodes.appendAssumeCapacity(idx);
                }

                const span: IndexSpan = .{
                    .start = @intCast(start),
                    .len = @intCast(self.query_accel_tag_nodes.items.len - start),
                };
                self.query_accel_tag_entries.append(self.allocator, .{
                    .tag_len = tag_len,
                    .tag_key = tag_key,
                    .span = span,
                }) catch {
                    self.query_accel_tag_disabled = true;
                    return null;
                };
                return span;
            }

            /// Internal id-index lookup used by matcher acceleration path.
            pub fn queryAccelLookupId(self: *const DocSelf, id: []const u8) QueryAccelIdLookup {
                const mut_self: *DocSelf = @constCast(self);
                if (!mut_self.ensureIdIndex()) {
                    return .unavailable;
                }
                const id_hash = hashIdValue(id);
                const idx = mut_self.query_accel_id_map.get(id_hash) orelse {
                    return .miss;
                };
                const node = &mut_self.nodes.items[idx];
                const current_id = attr_inline.getAttrValue(mut_self, node, "id") orelse {
                    return .miss;
                };
                if (std.mem.eql(u8, current_id, id)) {
                    return .{ .hit = idx };
                }

                // Collision or stale key materialization: permanently disable the id
                // index for this document and let caller use the scan fallback.
                mut_self.query_accel_id_disabled = true;
                mut_self.query_accel_id_built = false;
                mut_self.query_accel_id_map.clearRetainingCapacity();
                return .unavailable;
            }

            /// Internal tag-index lookup used by matcher acceleration path.
            pub fn queryAccelLookupTag(self: *const DocSelf, tag_name: []const u8, tag_key: u64) QueryAccelTagLookup {
                const mut_self: *DocSelf = @constCast(self);
                const span = mut_self.ensureTagIndex(tag_name, tag_key) orelse {
                    return .unavailable;
                };
                const start: usize = @intCast(span.start);
                const end: usize = start + @as(usize, @intCast(span.len));
                return .{ .hit = mut_self.query_accel_tag_nodes.items[start..end] };
            }

            /// Returns first direct element-like child index for `parent_idx`, if any.
            pub fn firstElementChildIndex(self: *const DocSelf, parent_idx: u32) u32 {
                if (parent_idx >= self.nodes.items.len) return InvalidIndex;

                const candidate1: u32 = parent_idx + 1;
                if (candidate1 >= self.nodes.items.len) return InvalidIndex;

                const node1 = &self.nodes.items[candidate1];
                if (node1.kind != .text) {
                    if (node1.parent == parent_idx and isElementLike(node1.kind)) return candidate1;
                    return InvalidIndex;
                }

                const candidate2: u32 = candidate1 + 1;
                if (candidate2 >= self.nodes.items.len) return InvalidIndex;

                const node2 = &self.nodes.items[candidate2];
                if (node2.kind == .text) {
                    @branchHint(.cold);
                    var scan: u32 = candidate2;
                    while (scan < self.nodes.items.len and self.nodes.items[scan].kind == .text) : (scan += 1) {}
                    if (scan >= self.nodes.items.len) return InvalidIndex;
                    const scanned = &self.nodes.items[scan];
                    if (scanned.parent == parent_idx and isElementLike(scanned.kind)) return scan;
                    return InvalidIndex;
                }
                if (node2.parent == parent_idx and isElementLike(node2.kind)) return candidate2;
                return InvalidIndex;
            }

            /// Returns next direct element-like sibling index for `node_idx`, if any.
            pub fn nextElementSiblingIndex(self: *const DocSelf, node_idx: u32) u32 {
                if (node_idx >= self.nodes.items.len) return InvalidIndex;
                const node = &self.nodes.items[node_idx];
                if (!isElementLike(node.kind)) return InvalidIndex;
                const parent_idx = node.parent;
                if (parent_idx == InvalidIndex) return InvalidIndex;

                var candidate: u32 = node.subtree_end + 1;
                while (candidate < self.nodes.items.len) : (candidate += 1) {
                    const cand = &self.nodes.items[candidate];
                    if (cand.parent != parent_idx) return InvalidIndex;
                    if (isElementLike(cand.kind)) return candidate;
                    if (cand.kind != .text) return InvalidIndex;
                }
                return InvalidIndex;
            }

            /// Returns direct-child node iterator for `parent_idx`.
            pub fn childrenIter(self: *const DocSelf, parent_idx: u32) ChildrenIterType {
                return .{
                    .doc = self,
                    .next_idx = self.firstElementChildIndex(parent_idx),
                };
            }
        };
    }
};

/// Re-exported text extraction options used by node text APIs.
pub const TextOptions = node_api.TextOptions;

/// Inclusive-exclusive byte span into the document source buffer.
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    /// Returns the span length in bytes.
    pub fn len(self: @This()) u32 {
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
const NodeRaw = DefaultTypeOptions.GetNodeRaw();
const Node = DefaultTypeOptions.GetNode();
const QueryIter = DefaultTypeOptions.QueryIter();
const Document = DefaultTypeOptions.GetDocument();

fn hashIdValue(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id);
}

fn assertNodeTypeLayouts() void {
    _ = @sizeOf(NodeRaw);
    _ = @sizeOf(Node);
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
    const it = try doc.queryAllRuntime(selector);
    try expectIterIds(it, expected_ids);

    const first = try doc.queryOneRuntime(selector);
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
    const it = try scope.queryAllRuntime(selector);
    try expectIterIds(it, expected_ids);

    const first = try scope.queryOneRuntime(selector);
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
    try doc.parse(input, .{});
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
    try doc.parse(&html, .{});

    const one = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", one.tagName());

    var it = doc.queryAll("body > *");
    try std.testing.expect(it.next() != null);
}

test "runtime queryAll iterator is stable across queryOneRuntime calls" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='x'></span></div>".*;
    try doc.parse(&html, .{});

    var it = try doc.queryAllRuntime("span.x");

    // This uses a different arena and must not invalidate `it`.
    _ = try doc.queryOneRuntime("div");

    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime queryAll iterator is invalidated by a newer runtime queryAll call" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='y'></span></div>".*;
    try doc.parse(&html, .{});

    var old_it = try doc.queryAllRuntime("span.x");
    var new_it = try doc.queryAllRuntime("span.y");

    try std.testing.expect(old_it.next() == null);
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "runtime queryAll iterator is invalidated by clear and reparsing" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div><span class='x'></span></div>".*;
    try doc.parse(&html_a, .{});

    var old_it = try doc.queryAllRuntime("span.x");
    doc.clear();
    try std.testing.expect(old_it.next() == null);
    try std.testing.expect(doc.queryOne("span.x") == null);

    var html_b = "<div><span class='y'></span></div>".*;
    try doc.parse(&html_b, .{});
    try std.testing.expect(old_it.next() == null);

    var new_it = try doc.queryAllRuntime("span.y");
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "raw text element metadata remains valid after child append growth" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>const x = 1;</script><div>ok</div>".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.raw().subtree_end > script.index);

    const text_node = doc.nodes.items[script.index + 1];
    try std.testing.expect(text_node.kind == .text);
    try std.testing.expectEqualStrings("const x = 1;", text_node.name_or_text.slice(doc.source));

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;
    try std.testing.expect(div.index > script.raw().subtree_end);
}

test "query results matrix (comptime selectors)" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text_node = doc.nodes.items[node.index + 1];
    try std.testing.expect(text_node.kind == .text);
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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text_node_before = doc.nodes.items[node.index + 1];
    try std.testing.expect(text_node_before.kind == .text);
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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

    const by_selector = try doc.queryOneRuntime("div[q='&z'][n='a&b']");
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
    try doc.parse(&html, .{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "div[href^=https][class*=button]");
    try std.testing.expect(doc.queryOneCached(sel) == null);
    try std.testing.expect((try doc.queryOneRuntime("div[href^=https][class*=button]")) == null);

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

    try doc.parse(html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html_a, .{});

    try std.testing.expect((try doc.queryOneRuntime("div.x")) != null);
    try std.testing.expect((try doc.queryOneRuntime("div.x")) != null);

    var html_b = "<section class='x'></section>".*;
    try doc.parse(&html_b, .{});
    try std.testing.expect((try doc.queryOneRuntime("div.x")) == null);

    doc.clear();
    var html_c = "<div class='x'></div>".*;
    try doc.parse(&html_c, .{});
    try std.testing.expect((try doc.queryOneRuntime("div.x")) != null);
}

test "raw-text close handles mixed-case end tag and embedded < bytes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>if (a < b) { x = \"<tag>\"; }</ScRiPt   ><div id='after'></div>".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    const after = doc.queryOne("div#after") orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.raw().subtree_end < after.index);
}

test "raw-text unterminated tail keeps element open to end of input" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>const a = 1; <div>still script".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(doc.nodes.items.len - 1)), script.raw().subtree_end);
    try std.testing.expect((doc.queryOne("div")) == null);
}

test "svg subtrees are skipped and stored as one text child payload" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='before'></div><svg id='s'><g><svg id='inner'><rect id='r'/></svg><circle id='c'/></g></svg><div id='after'></div>".*;
    try doc.parse(&html, .{});

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
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' data-k=\"prefix <svg attr='x'> suffix\"></div><p id='after'></p>".*;
    try doc.parse(&html, .{});

    const x = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const v = x.getAttributeValue("data-k") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("prefix <svg attr='x'> suffix", v);
    try std.testing.expect(doc.queryOne("#after") != null);
}

test "self-closing svg is stored as regular element with no text child" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='before'></div><svg id='s' viewBox='0 0 1 1' /><div id='after'></div>".*;
    try doc.parse(&html, .{});

    const first_svg = doc.queryOne("svg") orelse return error.TestUnexpectedResult;
    const svg_text = try first_svg.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("", svg_text);
    try std.testing.expect(first_svg.firstChild() == null);

    try std.testing.expect(doc.queryOne("#before") != null);
    try std.testing.expect(doc.queryOne("#after") != null);
}

test "optional-close p/li/td-th/dt-dd/head-body preserve expected query semantics" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = ("<html><head><title>x</title><body>" ++
        "<p id='p1'>a<div id='d1'></div>" ++
        "<ul><li id='li1'>x<li id='li2'>y</ul>" ++
        "<dl><dt id='dt1'>a<dd id='dd1'>b<dt id='dt2'>c</dl>" ++
        "<table><tr><td id='td1'>1<th id='th1'>2<td id='td2'>3</tr></table>" ++
        "</body></html>").*;
    try doc.parse(&html, .{});

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
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<abcdefgh1 id='outer'><span id='inner'></span></abcdefgh2><p id='after'></p>".*;
    try doc.parse(&html, .{});

    const outer = doc.queryOne("abcdefgh1#outer") orelse return error.TestUnexpectedResult;
    const after = doc.queryOne("p#after") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(outer.index, after.parentNode().?.index);
}

test "attr fast-path names are equivalent to generic lookup semantics" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<a id='x' class='btn primary' href='https://example.com' data-k='v'></a>".*;
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

    try std.testing.expect(doc.queryOne("div#x[data-k=v]") != null);
    try std.testing.expect((try doc.queryOneRuntime("div > span#y")) != null);

    const div = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A b", div.getAttributeValue("class").?);
}

test "multiple class predicates in one compound match correctly" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' class='alpha beta gamma'></div><div id='y' class='alpha beta'></div>".*;
    try doc.parse(&html, .{});

    try expectDocQueryComptime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.delta", &.{});
}

test "class token matching treats all ascii whitespace as separators" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='t' class='a\tb\nc\rd\x0ce'></div>".*;
    try doc.parse(&html, .{});

    try std.testing.expect(doc.queryOne("#t.a") != null);
    try std.testing.expect(doc.queryOne("#t.b") != null);
    try std.testing.expect(doc.queryOne("#t.c") != null);
    try std.testing.expect(doc.queryOne("#t.d") != null);
    try std.testing.expect(doc.queryOne("#t.e") != null);
    try std.testing.expect((try doc.queryOneRuntime("#t[class~=d]")) != null);
    try std.testing.expect((try doc.queryOneRuntime("#t[class~=e]")) != null);
}

test "scoped query falls back from id index when first id hit fails extra predicates" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='outside'><span id='dup' class='x'></span></div><div id='scope'><span id='dup' class='y'></span></div>".*;
    try doc.parse(&html, .{});

    const scope = doc.queryOne("#scope") orelse return error.TestUnexpectedResult;
    const found_ct = scope.queryOne("#dup.y") orelse return error.TestUnexpectedResult;
    const found_rt = (try scope.queryOneRuntime("#dup.y")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(found_ct.index, found_rt.index);
    const parent = found_ct.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("scope", parent.getAttributeValue("id").?);
}

test "runtime selector rejects multiple ids in one compound" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var html = "<div id='a'></div>".*;
    try doc.parse(&html, .{});

    try std.testing.expectError(error.InvalidSelector, doc.queryOneRuntime("#a#a"));
}

test "runtime selector supports nth-child shorthand variants" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='pseudos'><div></div><div></div><div></div><div></div><a></a><div></div><div></div></div>".*;
    try doc.parse(&html, .{});

    const comptime_one = doc.queryOne("#pseudos :nth-child(odd)");
    const runtime_one = try doc.queryOneRuntime("#pseudos :nth-child(odd)");
    try std.testing.expect((comptime_one == null) == (runtime_one == null));
    if (comptime_one) |a| {
        try std.testing.expectEqual(a.index, runtime_one.?.index);
    }

    var c_odd: usize = 0;
    var it_odd = try doc.queryAllRuntime("#pseudos :nth-child(odd)");
    while (it_odd.next()) |_| c_odd += 1;
    try std.testing.expectEqual(@as(usize, 4), c_odd);

    var c_plus: usize = 0;
    var it_plus = try doc.queryAllRuntime("#pseudos :nth-child(3n+1)");
    while (it_plus.next()) |_| c_plus += 1;
    try std.testing.expectEqual(@as(usize, 3), c_plus);

    var c_signed: usize = 0;
    var it_signed = try doc.queryAllRuntime("#pseudos :nth-child(+3n-2)");
    while (it_signed.next()) |_| c_signed += 1;
    try std.testing.expectEqual(@as(usize, 3), c_signed);

    var c_neg_a: usize = 0;
    var it_neg_a = try doc.queryAllRuntime("#pseudos :nth-child(-n+6)");
    while (it_neg_a.next()) |_| c_neg_a += 1;
    try std.testing.expectEqual(@as(usize, 6), c_neg_a);

    var c_neg_b: usize = 0;
    var it_neg_b = try doc.queryAllRuntime("#pseudos :nth-child(-n+5)");
    while (it_neg_b.next()) |_| c_neg_b += 1;
    try std.testing.expectEqual(@as(usize, 5), c_neg_b);
}

test "leading child combinator works in node-scoped queries" {
    const alloc = std.testing.allocator;

    var frag_doc = Document.init(alloc);
    defer frag_doc.deinit();
    var frag_html =
        "<root><div class='d i v'><p id='oooo'><em></em><em id='emem'></em></p></div><p id='sep'><div class='a'><span></span></div></p></root>".*;
    try frag_doc.parse(&frag_html, .{});
    const frag_root = frag_doc.queryOne("root") orelse return error.TestUnexpectedResult;

    var it_em = try frag_root.queryAllRuntime("> div p em");
    var em_count: usize = 0;
    while (it_em.next()) |_| em_count += 1;
    try std.testing.expectEqual(@as(usize, 2), em_count);

    var it_oooo = try frag_root.queryAllRuntime("> div #oooo");
    var oooo_count: usize = 0;
    while (it_oooo.next()) |_| oooo_count += 1;
    try std.testing.expectEqual(@as(usize, 1), oooo_count);

    var doc_ctx = Document.init(alloc);
    defer doc_ctx.deinit();
    var doc_html =
        "<root><div id='hsoob'><div class='a b'><div class='d e sib' id='booshTest'><p><span id='spanny'></span></p></div><em class='sib'></em><span class='h i a sib'></span></div><p class='odd'></p></div><div id='lonelyHsoob'></div></root>".*;
    try doc_ctx.parse(&doc_html, .{});
    const ctx_root = doc_ctx.queryOne("root") orelse return error.TestUnexpectedResult;

    var it_hsoob = try ctx_root.queryAllRuntime("> #hsoob");
    var hsoob_count: usize = 0;
    while (it_hsoob.next()) |_| hsoob_count += 1;
    try std.testing.expectEqual(@as(usize, 1), hsoob_count);
}

test "parse option bundles preserve selector/query behavior for representative input" {
    const alloc = std.testing.allocator;

    var strict_doc = Document.init(alloc);
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

    try strict_doc.parse(&strict_html, .{});
    try fast_doc.parse(&fast_html, .{
        .drop_whitespace_text_nodes = true,
    });

    const selectors = [_][]const u8{
        "div#x[data-k=v]",
        "img#im",
        "a[href^=https][class*=button]:not(.missing)",
        "p#p1 > span#s1",
        "div[a]",
    };

    for (selectors) |sel| {
        const a = try strict_doc.queryOneRuntime(sel);
        const b = try fast_doc.queryOneRuntime(sel);
        try std.testing.expect((a == null) == (b == null));
    }

    const strict_empty = (strict_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    const fast_empty = (fast_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(strict_empty, fast_empty);
}

test "whitespace-only text nodes drop only in fastest mode" {
    const alloc = std.testing.allocator;

    var strict_doc = Document.init(alloc);
    defer strict_doc.deinit();
    var fast_doc = Document.init(alloc);
    defer fast_doc.deinit();

    var strict_html = "<div id='x'> \n\t </div><div id='y'> hi </div>".*;
    var fast_html = strict_html;

    try strict_doc.parse(&strict_html, .{ .drop_whitespace_text_nodes = false });
    try fast_doc.parse(&fast_html, .{ .drop_whitespace_text_nodes = true });

    try std.testing.expectEqual(@as(usize, 5), strict_doc.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 4), fast_doc.nodes.items.len);

    const y = fast_doc.queryOne("#y") orelse return error.TestUnexpectedResult;
    const text = try y.innerTextWithOptions(alloc, .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings(" hi ", text);
}

test "attribute scanner handles quoted > and self-closing tails" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='a' data-q='x>y' data-n=abc></div><img id='i' src='x' /><br id='b'>".*;
    try doc.parse(&html, .{
        .drop_whitespace_text_nodes = true,
    });

    try std.testing.expect(doc.queryOne("div#a[data-q='x>y']") != null);
    try std.testing.expect(doc.queryOne("img#i[src='x']") != null);
    try std.testing.expect(doc.queryOne("br#b") != null);
}

test "attribute parsing still builds the DOM" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x'><span id='y'></span></div>".*;
    try doc.parse(&html, .{
        .drop_whitespace_text_nodes = true,
    });

    // Document node plus parsed element nodes must exist.
    try std.testing.expect(doc.nodes.items.len > 1);
    try std.testing.expect(doc.queryOne("#x") != null);
    try std.testing.expect(doc.queryOne("#y") != null);
}

test "children() iterator traverses sibling-chain nodes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span></div>".*;
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

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
    try std.testing.expectEqual(@as(u32, a.index), b.parentNode().?.index);
}

test "query accel id/tag indexes match selector results" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html =
        "<div id='root'><a id='x' href='https://example' class='nav button'></a><span id='y'></span><a id='z' href='/local' class='nav'></a></div>".*;
    try doc.parse(&html, .{});

    const x = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", x.raw().name_or_text.slice(doc.source));

    const id_idx = switch (doc.queryAccelLookupId("x")) {
        .hit => |idx| idx,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(x.index, id_idx);

    const a_key = tags.first8Key("a");
    const tag_candidates = switch (doc.queryAccelLookupTag("a", a_key)) {
        .hit => |candidates| candidates,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), tag_candidates.len);
    try std.testing.expectEqual(x.index, tag_candidates[0]);
    try std.testing.expectEqualStrings("a", doc.nodes.items[tag_candidates[1]].name_or_text.slice(doc.source));

    const sel_hit = doc.queryOne("a[href^=https][class*=button]") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(x.index, sel_hit.index);

    const x_node = doc.nodeAt(id_idx) orelse return error.TestUnexpectedResult;
    _ = x_node.getAttributeValue("class") orelse return error.TestUnexpectedResult;
    const id_idx_after = switch (doc.queryAccelLookupId("x")) {
        .hit => |idx| idx,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(id_idx, id_idx_after);
}

test "query accel state is invalidated by parse and clear" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div><a id='x'></a><a id='y'></a></div>".*;
    try doc.parse(&html_a, .{});

    try std.testing.expect(doc.queryAccelLookupId("x") != .unavailable);

    try std.testing.expect(doc.queryAccelLookupTag("a", tags.first8Key("a")) != .unavailable);
    try std.testing.expect(doc.query_accel_id_built);
    try std.testing.expect(doc.query_accel_tag_nodes.items.len != 0);

    var html_b = "<main><p id='z'>owned</p></main>".*;
    try doc.parse(&html_b, .{});
    try std.testing.expect(!doc.query_accel_id_built);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_entries.items.len);

    try std.testing.expect(doc.queryAccelLookupId("x") == .miss);

    const text_before_clear = (doc.queryOne("#z") orelse return error.TestUnexpectedResult)
        .innerTextWithOptions(alloc, .{ .normalize_whitespace = false }) catch return error.TestUnexpectedResult;
    try std.testing.expect(doc.isOwned(text_before_clear));

    doc.clear();
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.source.len);
    try std.testing.expect(!doc.isOwned(text_before_clear));
    try std.testing.expect(doc.queryOne("main") == null);
    try std.testing.expect(!doc.query_accel_id_built);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_entries.items.len);
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
    try doc.parse(html, .{});

    const selector = "a[href^=https][class*=button]:not(.missing)";
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const compiled = try ast.Selector.compileRuntime(arena.allocator(), selector);
    var loops: usize = 0;
    while (loops < 256) : (loops += 1) {
        const a = try doc.queryOneRuntime(selector);
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
        try doc.parse(html, .{});

        var loops: usize = 0;
        while (loops < 32) : (loops += 1) {
            const a = try doc.queryOneRuntime(selector);
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
        try doc.parse(html, .{ .drop_whitespace_text_nodes = true });

        var loops: usize = 0;
        while (loops < 32) : (loops += 1) {
            const a = try doc.queryOneRuntime(selector);
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
    try doc.parse(&html, .{});

    const result = doc.queryOneRuntimeDebug("div[");
    try std.testing.expectEqual(@as(?runtime_selector.Error, error.InvalidSelector), result.err);
    try std.testing.expect(result.report.runtime_parse_error);
    try std.testing.expectEqualStrings("div[", result.report.selector_source);
}

test "queryOneDebug reports near misses and matched index" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><a id='x' class='k'></a><a id='y'></a></div>".*;
    try doc.parse(&html, .{});

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
    try doc.parse(&html, .{});

    const root = doc.queryOne("root") orelse return error.TestUnexpectedResult;
    const found = root.queryOneRuntimeDebug("> span#inside");
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
    try instrumentation.parseWithHooks(std.testing.io, &doc, &html, .{}, &hooks);
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_start_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_end_calls);
    try std.testing.expect(hooks.last_parse_stats.elapsed_ns > 0);
    try std.testing.expectEqual(html.len, hooks.last_input_len);
    try std.testing.expect(hooks.last_parse_stats.node_count >= 2);

    const runtime_one = try instrumentation.queryOneRuntimeWithHooks(std.testing.io, &doc, "a#x", &hooks);
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

    _ = try instrumentation.queryAllRuntimeWithHooks(std.testing.io, &doc, "a", &hooks);
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

    const node_type_out = try std.fmt.allocPrint(alloc, "{f}", .{NodeType.element});
    defer alloc.free(node_type_out);
    try std.testing.expectEqualStrings("element", node_type_out);

    const opts: ParseOptions = .{ .drop_whitespace_text_nodes = false };
    const opts_out = try std.fmt.allocPrint(alloc, "{f}", .{opts});
    defer alloc.free(opts_out);
    try std.testing.expectEqualStrings("ParseOptions{drop_whitespace_text_nodes=false}", opts_out);

    const span: Span = .{ .start = 2, .end = 5 };
    const span_out = try std.fmt.allocPrint(alloc, "{f}", .{span});
    defer alloc.free(span_out);
    try std.testing.expectEqualStrings("Span{start=2, end=5}", span_out);

    var doc = Document.init(alloc);
    defer doc.deinit();
    var src = "<div><span></span><span></span></div>".*;
    try doc.parse(&src, .{});

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    const qit = div.queryAll("span");
    const qit_out = try std.fmt.allocPrint(alloc, "{f}", .{qit});
    defer alloc.free(qit_out);
    try std.testing.expectEqualStrings("QueryIter{scope_root=1, next_index=2, runtime_generation=0}", qit_out);

    const cit = div.children();
    const cit_out = try std.fmt.allocPrint(alloc, "{f}", .{cit});
    defer alloc.free(cit_out);
    try std.testing.expectEqualStrings("ChildrenIter{next_idx=2}", cit_out);

    const doc_out = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(doc_out);
    try std.testing.expectEqualStrings("<div><span></span><span></span></div>", doc_out);
}
