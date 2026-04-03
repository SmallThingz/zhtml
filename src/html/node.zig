const std = @import("std");
const tables = @import("tables.zig");
const attr_scan = @import("attr_scan.zig");
const entities = @import("entities.zig");
const attr_inline = @import("attr_inline.zig");
const scanner = @import("scanner.zig");
const tags = @import("tags.zig");
const common = @import("../common.zig");
const IndexInt = common.IndexInt;

// SAFETY: Node helpers assume `self.index` is in-bounds for `doc.nodes.items`
// and that `doc.source` outlives returned slices. Attribute parsing relies on
// `raw.attr_end <= doc.source.len`.

const InvalidIndex: IndexInt = common.InvalidIndex;
const isElementLike = common.isElementLike;

/// Controls text extraction behavior for `innerText*` APIs.
pub const TextOptions = struct {
    normalize_whitespace: bool = true,

    /// Formats text extraction options for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("TextOptions{{normalize_whitespace={}}}", .{self.normalize_whitespace});
    }
};

/// Returns first element child of this node.
pub fn firstChild(self: anytype) ?@TypeOf(self) {
    const idx = self.doc.firstElementChildIndex(self.index);
    if (idx == InvalidIndex) return null;
    return self.doc.nodeAt(idx);
}

/// Returns last element child of this node.
pub fn lastChild(self: anytype) ?@TypeOf(self) {
    const raw = &self.doc.nodes.items[self.index];
    var idx = raw.last_child;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (isElementLike(c.kind)) return self.doc.nodeAt(idx);
    }
    return null;
}

/// Returns next element sibling of this node.
pub fn nextSibling(self: anytype) ?@TypeOf(self) {
    const idx = self.doc.nextElementSiblingIndex(self.index);
    if (idx == InvalidIndex) return null;
    return self.doc.nodeAt(idx);
}

/// Returns previous element sibling of this node.
pub fn prevSibling(self: anytype) ?@TypeOf(self) {
    const raw = &self.doc.nodes.items[self.index];
    var idx = raw.prev_sibling;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (isElementLike(c.kind)) return self.doc.nodeAt(idx);
    }
    return null;
}

/// Returns parent element of this node, if available.
pub fn parentNode(self: anytype) ?@TypeOf(self) {
    const parent = self.doc.parentIndex(self.index);
    if (parent == InvalidIndex or parent == 0) return null;
    return self.doc.nodeAt(parent);
}

/// Returns direct-child node iterator for this node.
pub fn children(self: anytype) @TypeOf(self.doc.childrenIter(self.index)) {
    return self.doc.childrenIter(self.index);
}

/// Returns decoded attribute value for `name`, if present.
pub fn getAttributeValue(self: anytype, name: []const u8) ?[]const u8 {
    const raw = &self.doc.nodes.items[self.index];
    return attr_inline.getAttrValue(self.doc, raw, name);
}

/// Returns subtree text; may borrow in-place bytes or allocate into `arena_alloc`.
pub fn innerText(self: anytype, arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
    const doc = self.doc;
    const raw = &doc.nodes.items[self.index];

    if (raw.kind == .text) {
        const mut_node = &doc.nodes.items[self.index];
        _ = decodeTextNode(mut_node, doc);
        if (!opts.normalize_whitespace) return mut_node.name_or_text.slice(doc.source);
        return normalizeTextNodeInPlace(mut_node, doc);
    }

    var first_idx: IndexInt = InvalidIndex;
    var count: usize = 0;

    var idx = self.index + 1;
    while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
        const node = &doc.nodes.items[idx];
        if (node.kind != .text) continue;
        count += 1;
        _ = decodeTextNode(node, doc);
        if (count == 1) first_idx = idx;
    }

    if (count == 0) return "";
    if (count == 1) {
        // Single text-node result can stay fully borrowed/non-alloc.
        const only = &doc.nodes.items[first_idx];
        if (!opts.normalize_whitespace) return only.name_or_text.slice(doc.source);
        return normalizeTextNodeInPlace(only, doc);
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena_alloc);

    if (!opts.normalize_whitespace) {
        idx = self.index + 1;
        while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            const seg = node.name_or_text.slice(doc.source);
            try ensureOutExtra(&out, arena_alloc, seg.len);
            out.appendSliceAssumeCapacity(seg);
        }
    } else {
        var state: WhitespaceNormState = .{};
        idx = self.index + 1;
        while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            try appendNormalizedSegment(&out, arena_alloc, node.name_or_text.slice(doc.source), &state);
        }
    }

    if (out.items.len == 0) return "";
    return try out.toOwnedSlice(arena_alloc);
}

/// Always materializes subtree text into owned bytes allocated from `alloc`.
pub fn innerTextOwned(self: anytype, alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
    const doc = self.doc;
    const raw = &doc.nodes.items[self.index];

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    if (raw.kind == .text) {
        const text = raw.name_or_text.slice(doc.source);
        if (!opts.normalize_whitespace) {
            try appendDecodedSegment(&out, alloc, text);
        } else {
            var state: WhitespaceNormState = .{};
            try appendDecodedNormalizedSegment(&out, alloc, text, &state);
        }
        return try out.toOwnedSlice(alloc);
    }

    if (!opts.normalize_whitespace) {
        var idx = self.index + 1;
        while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            try appendDecodedSegment(&out, alloc, node.name_or_text.slice(doc.source));
        }
        return try out.toOwnedSlice(alloc);
    }

    var state: WhitespaceNormState = .{};
    var idx = self.index + 1;
    while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
        const node = &doc.nodes.items[idx];
        if (node.kind != .text) continue;
        try appendDecodedNormalizedSegment(&out, alloc, node.name_or_text.slice(doc.source), &state);
    }
    return try out.toOwnedSlice(alloc);
}

/// Writes the HTML serialization of this node (and its subtree) to `writer`.
pub fn writeHtml(self: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
    const doc = self.doc;
    const idx: IndexInt = self.index;
    const raw = &doc.nodes.items[@intCast(idx)];
    try writeNodeHtml(doc, idx, raw, writer);
}

/// Writes HTML serialization for this node only, excluding its children.
pub fn writeHtmlSelf(self: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
    const doc = self.doc;
    const idx: IndexInt = self.index;
    const raw = &doc.nodes.items[@intCast(idx)];
    try writeNodeHtmlSelf(doc, idx, raw, writer);
}

fn decodeTextNode(noalias node: anytype, doc: anytype) []const u8 {
    const text_mut = node.name_or_text.sliceMut(doc.source);
    const new_len = entities.decodeInPlaceIfEntity(text_mut);
    node.name_or_text.end = node.name_or_text.start + @as(IndexInt, @intCast(new_len));
    return node.name_or_text.slice(doc.source);
}

fn normalizeTextNodeInPlace(noalias node: anytype, doc: anytype) []const u8 {
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

fn writeNodeHtml(doc: anytype, idx: IndexInt, noalias raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
    switch (raw.kind) {
        .document => try writeChildrenHtml(doc, idx, raw, writer),
        .text => try writer.writeAll(raw.name_or_text.slice(doc.source)),
        .element => {
            const name = raw.name_or_text.slice(doc.source);
            try writeByte(writer, '<');
            try writer.writeAll(name);
            try writeAttrsHtml(doc, raw, writer);
            try writeByte(writer, '>');

            if (!tags.isVoidTagWithKey(name, tags.first8Key(name))) {
                try writeChildrenHtml(doc, idx, raw, writer);
                try writer.writeAll("</");
                try writer.writeAll(name);
                try writeByte(writer, '>');
            }
        },
    }
}

fn writeNodeHtmlSelf(doc: anytype, idx: IndexInt, noalias raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
    switch (raw.kind) {
        .document => try writeChildrenHtml(doc, idx, raw, writer),
        .text => try writer.writeAll(raw.name_or_text.slice(doc.source)),
        .element => {
            const name = raw.name_or_text.slice(doc.source);
            try writeByte(writer, '<');
            try writer.writeAll(name);
            try writeAttrsHtml(doc, raw, writer);
            try writeByte(writer, '>');
        },
    }
}

fn writeChildrenHtml(doc: anytype, parent_idx: IndexInt, noalias raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
    const end: IndexInt = raw.subtree_end;
    var idx: IndexInt = parent_idx + 1;
    const len_u32: IndexInt = @intCast(doc.nodes.items.len);
    while (idx <= end and idx < len_u32) {
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

fn writeAttrsHtml(doc: anytype, noalias raw: anytype, writer: anytype) WriterError(@TypeOf(writer))!void {
    const source: []u8 = doc.source;
    var i: usize = @intCast(raw.name_or_text.end);
    const end: usize = @intCast(raw.attr_end);

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) return;

        if (source[i] == 0) {
            i = skipAttrGap(source, end, i);
            continue;
        }

        const name_start = i;
        const scanned = attr_scan.scanAttrNameOrSkip(source, end, i);
        const name = scanned.name orelse return;
        i = scanned.next_start;
        if (name.len == 0) continue;
        if (i >= end) {
            try writeAttrName(writer, name);
            return;
        }

        const delim = source[i];
        if (delim == '=') {
            const raw_value = attr_scan.parseRawValue(source, end, i);
            // Preserve original raw attribute text when not parsed in-place.
            try writeByte(writer, ' ');
            try writer.writeAll(source[name_start..raw_value.next_start]);
            i = raw_value.next_start;
            continue;
        }

        if (delim == 0) {
            const parsed = attr_scan.parseParsedValue(source, end, i);
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

const ParsedAttrValue = attr_scan.ParsedValue;
const ExtendedGapSentinel = 0xff;
const ExtendedGapHeaderLen = 2 + @sizeOf(IndexInt);

fn skipAttrGap(source: []const u8, span_end: usize, start: usize) usize {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(start < span_end);
    if (start + 1 >= span_end) return span_end;
    const len_byte = source[start + 1];
    if (len_byte == ExtendedGapSentinel) {
        if (start + ExtendedGapHeaderLen > span_end) return span_end;
        const skip = std.mem.readInt(IndexInt, source[start + 2 .. start + ExtendedGapHeaderLen][0..@sizeOf(IndexInt)], attr_scan.nativeEndian());
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
        if (entities.decodeEntityPrefix(seg[amp..])) |decoded| {
            out.appendSliceAssumeCapacity(decoded.bytes[0..decoded.len]);
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
        if (entities.decodeEntityPrefix(seg[amp..])) |decoded| {
            appendNormalizedSegmentAssumeCapacity(out, decoded.bytes[0..decoded.len], state);
            idx = amp + decoded.consumed;
        } else {
            appendNormalizedSegmentAssumeCapacity(out, seg[amp .. amp + 1], state);
            idx = amp + 1;
        }
    }
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
    const alloc = std.testing.allocator;
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{TextOptions{ .normalize_whitespace = false }});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("TextOptions{normalize_whitespace=false}", rendered);
}
