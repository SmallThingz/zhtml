const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const tables = @import("tables.zig");
const entities = @import("entities.zig");
const scanner = @import("scanner.zig");
const common = @import("../common.zig");

pub const RawKind = enum {
    empty,
    quoted,
    naked,
};

pub const RawValue = struct {
    /// Raw value encoding detected at parse time.
    kind: RawKind,
    /// Inclusive start byte offset of the raw value payload.
    start: usize,
    /// Exclusive end byte offset of the raw value payload.
    end: usize,
    /// Quote byte for quoted values, otherwise zero.
    quote: u8 = 0,
    /// Next scan cursor after this raw value.
    next_start: usize,
};

pub const ScanAttrNameResult = struct {
    /// Parsed attribute name, `null` at tag terminator, or `""` when one byte was skipped.
    name: ?[]const u8,
    /// Next scan cursor after the attribute name or skipped byte.
    next_start: usize,
};

/// Index of the first non-whitespace byte following an attribute name.
/// This is the value delimiter (`=` or an in-place `0` marker), the next
/// attribute name, or the tag terminator.
pub fn valueDelimiterIndex(source: []const u8, end: usize, name_end: usize) usize {
    std.debug.assert(end <= source.len);
    std.debug.assert(name_end <= end);
    var i = name_end;
    while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
    return i;
}

const AttrValueMode = enum {
    raw,
    non_destructive,
};

/// Scans the next attribute name starting at `start`.
/// Returns null when the attribute list terminator is reached.
/// Returns an empty slice when the cursor is advanced past a non-name byte.
pub fn scanAttrNameOrSkip(source: []const u8, end: usize, start: usize) ScanAttrNameResult {
    std.debug.assert(end <= source.len);
    std.debug.assert(start < end);
    const c = source[start];
    if (c == '>') return .{ .name = null, .next_start = start };
    if (c == '/') {
        if (start + 1 >= end or source[start + 1] == '>') return .{ .name = null, .next_start = start };
        return .{ .name = "", .next_start = start + 1 };
    }

    const name_start = start;
    // In before-attribute-name state a leading `=` is a parse error but still
    // becomes the first byte of the attribute name. A later `=` is the normal
    // value delimiter, so only the first byte gets this special treatment.
    var i = start + @intFromBool(c == '=');
    while (i < end and tables.AttrNameCharTable[source[i]]) : (i += 1) {}
    if (i == name_start) {
        return .{ .name = "", .next_start = i + 1 };
    }
    return .{ .name = source[name_start..i], .next_start = i };
}

/// Parses raw attribute value span for in-place attribute traversal.
pub fn parseRawValue(source: []const u8, span_end: usize, eq_index: usize) RawValue {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(eq_index < span_end);
    var i = eq_index + 1;
    // Parsing starts from the `=` and skips leading whitespace so the caller
    // can reuse the original attribute traversal cursor.
    while (i < span_end and tables.WhitespaceTable[source[i]]) : (i += 1) {}

    if (i >= span_end) {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = i };
    }

    const c = source[i];
    if (c == '>') {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = i };
    }

    if (c == 0x27 or c == '"') {
        const found = scanner.findBytePosOrEnd(source[0..span_end], i + 1, c);
        const j = @min(found, span_end);
        const next_start = if (j < span_end) j + 1 else span_end;
        return .{ .kind = .quoted, .start = i + 1, .end = j, .quote = c, .next_start = next_start };
    }

    var j = i;
    while (j < span_end) : (j += 1) {
        const b = source[j];
        if (b == '>' or tables.WhitespaceTable[b]) break;
    }

    if (j == i) {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = j };
    }

    return .{ .kind = .naked, .start = i, .end = j, .next_start = j };
}

/// One raw attribute from source. `value` is null for valueless boolean
/// attributes (`name`) and Some for `name=` plus any value payload; the raw
/// `RawKind` describes the value encoding.
pub const RawAttribute = struct {
    source: []const u8,
    name: []const u8,
    name_start: usize,
    value: ?RawValue,

    pub inline fn nameSlice(self: @This()) []const u8 {
        return self.name;
    }

    pub inline fn valueRaw(self: @This()) ?[]const u8 {
        const raw = self.value orelse return null;
        return self.source[raw.start..raw.end];
    }
};

/// Single source-of-truth iterator for non-compacted HTML attributes.
pub const RawIterator = struct {
    source: []const u8,
    cursor: usize,
    end: usize,

    pub fn next(self: *@This()) ?RawAttribute {
        while (self.cursor < self.end) {
            skipWhitespace(self.source, self.end, &self.cursor);
            if (self.cursor >= self.end) return null;

            const name_start = self.cursor;
            const scanned = scanAttrNameOrSkip(self.source, self.end, self.cursor);
            const name = scanned.name orelse return null;
            self.cursor = scanned.next_start;
            if (name.len == 0) continue;

            const delim = valueDelimiterIndex(self.source, self.end, self.cursor);
            if (delim >= self.end) {
                self.cursor = self.end;
                return .{
                    .source = self.source,
                    .name = name,
                    .name_start = name_start,
                    .value = null,
                };
            }

            if (self.source[delim] == '=') {
                const raw = parseRawValue(self.source, self.end, delim);
                self.cursor = raw.next_start;
                return .{ .source = self.source, .name = name, .name_start = name_start, .value = raw };
            }

            const terminates = self.source[delim] == '>' or
                (self.source[delim] == '/' and delim + 1 < self.end and self.source[delim + 1] == '>');
            const next_pos = if (terminates) self.end else if (delim == self.cursor) self.cursor + 1 else delim;
            self.cursor = next_pos;
            return .{
                .source = self.source,
                .name = name,
                .name_start = name_start,
                .value = null,
            };
        }
        return null;
    }
};

/// Compact value marker. `=` means the payload was decoded in place. The
/// other markers preserve the original quoting mode for a raw payload whose
/// entity decode would expand and therefore requires an allocating fallback.
pub const CompactValueMarker = enum(u8) {
    decoded = '=',
    raw_naked = '/',
    raw_single_quoted = '\'',
    raw_double_quoted = '"',
};

/// One attribute from the destructive compact form.
pub const CompactAttribute = struct {
    name: []const u8,
    value: ?[]const u8,
    marker: CompactValueMarker = .decoded,

    pub inline fn isDecoded(self: @This()) bool {
        return self.value == null or self.marker == .decoded;
    }
};

/// Iterator over materialized destructive attributes.
pub const CompactIterator = struct {
    source: []const u8,
    cursor: usize,
    raw_tail: ?RawIterator = null,

    pub fn next(self: *@This()) ?CompactAttribute {
        if (self.raw_tail) |*raw_it| return rawTailNext(raw_it);
        if (self.cursor >= self.source.len or self.source[self.cursor] == '>') return null;

        // A zero byte where a compact name would start marks a malformed-name
        // raw tail. Materialization switches to this representation only when
        // a recovered HTML attribute name contains one of the compact value
        // marker bytes (`=`, `'`, or `"`). Keeping the tail raw avoids either
        // escaping/growing names in place or pre-scanning every normal tag.
        if (self.source[self.cursor] == 0) {
            self.cursor += 1;
            self.raw_tail = .{ .source = self.source, .cursor = self.cursor, .end = self.source.len };
            return rawTailNext(&self.raw_tail.?);
        }

        const name_start = self.cursor;
        while (self.cursor < self.source.len and !isCompactValueDelimiter(self.source[self.cursor]) and self.source[self.cursor] != 0 and self.source[self.cursor] != '>') : (self.cursor += 1) {}
        if (self.cursor >= self.source.len or self.source[self.cursor] == '>') return null;
        const name = self.source[name_start..self.cursor];
        if (self.source[self.cursor] == 0) {
            self.cursor += 1;
            return .{ .name = name, .value = null };
        }
        const marker: CompactValueMarker = @enumFromInt(self.source[self.cursor]);
        self.cursor += 1;
        const value_start = self.cursor;
        while (self.cursor < self.source.len and self.source[self.cursor] != 0) : (self.cursor += 1) {}
        if (self.cursor >= self.source.len) return null;
        const value = self.source[value_start..self.cursor];
        self.cursor += 1;
        return .{ .name = name, .value = value, .marker = marker };
    }

    fn rawTailNext(raw_it: *RawIterator) ?CompactAttribute {
        const item = raw_it.next() orelse return null;
        const raw = item.value orelse return .{ .name = item.name, .value = null };
        // Destructive compaction intentionally collapses both valueless and
        // explicitly empty assignments. Raw-tail fallback must preserve that
        // public behavior for quoted-empty values as well as `name=`.
        if (raw.kind == .empty or raw.end == raw.start) return .{ .name = item.name, .value = null };
        return .{
            .name = item.name,
            .value = item.valueRaw(),
            .marker = rawCompactMarker(raw),
        };
    }
};

inline fn isCompactValueDelimiter(c: u8) bool {
    return c == '=' or c == '/' or c == '\'' or c == '"';
}

fn rawCompactMarker(raw: RawValue) CompactValueMarker {
    return switch (raw.kind) {
        .naked => .raw_naked,
        .quoted => if (raw.quote == '\'') .raw_single_quoted else .raw_double_quoted,
        .empty => .decoded,
    };
}

/// Destructive documents compact a complete tag's attributes on first access.
/// The compact form is `name[marker value]NUL ... >`; `=` marks decoded values
/// and the quote/slash markers identify raw values requiring decode fallback.
/// Empty assignments and valueless attributes both use `nameNUL`.
pub fn materializeAttributes(comptime entity_decoding: entities.EntityDecoding, source: []u8, name_end: usize) void {
    if (name_end >= source.len) return;
    // Normal attributes begin after whitespace. A slash that is not immediately
    // followed by `>` is HTML tokenizer recovery into the before-attribute-name
    // state (`<div/id=x>`), and must be compacted too. Any other non-whitespace
    // byte at `name_end` means this tag was already compacted in place.
    if (!tables.WhitespaceTable[source[name_end]] and source[name_end] != '/') return;

    var write = name_end;
    var it: RawIterator = .{ .source = source, .cursor = name_end, .end = source.len };
    while (it.next()) |item| {
        const name_write = write;
        if (std.mem.indexOfAny(u8, item.name, "=/'\"") != null) {
            // `write` is always before this raw attribute: at least one HTML
            // separator or recovery slash preceded its name. Preserve the
            // malformed attribute and everything after it as raw syntax, moved
            // left behind a zero-byte mode switch. Detect this before copying
            // the name because the normal left-shift may overlap its source.
            const tag_end = scanner.findTagEnd(source, item.name_start) orelse source.len - 1;
            const tail_len = @min(source.len, tag_end + 1) - item.name_start;
            source[name_write] = 0;
            std.mem.copyForwards(u8, source[name_write + 1 .. name_write + 1 + tail_len], source[item.name_start .. item.name_start + tail_len]);
            return;
        }

        const bad_first_utf8 = invalidUtf8First(item.name);
        std.mem.copyForwards(u8, source[write .. write + item.name.len], item.name);
        if (bad_first_utf8) source[write] = 0x01;
        write += item.name.len;

        if (item.value) |raw| {
            if (raw.kind != .empty and raw.end > raw.start) {
                const raw_slice = source[raw.start..raw.end];
                const decoded = entities.decodeAttributeInPlaceResultWithMode(entity_decoding, raw_slice, null);
                if (decoded.complete) {
                    source[write] = @intFromEnum(CompactValueMarker.decoded);
                    write += 1;
                    std.mem.copyForwards(u8, source[write .. write + decoded.len], source[raw.start .. raw.start + decoded.len]);
                    write += decoded.len;
                } else {
                    source[write] = @intFromEnum(rawCompactMarker(raw));
                    write += 1;
                    std.mem.copyForwards(u8, source[write .. write + raw_slice.len], raw_slice);
                    for (source[write .. write + raw_slice.len]) |*b| {
                        if (b.* == 0) b.* = ' ';
                    }
                    write += raw_slice.len;
                }
            }
        }

        source[write] = 0;
        write += 1;
    }
    if (write < source.len) source[write] = '>';
}

inline fn invalidUtf8First(name: []const u8) bool {
    if (name.len == 0 or name[0] < 0x80) return false;
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return true;
    if (len > name.len) return true;
    _ = std.unicode.utf8Decode(name[0..len]) catch return true;
    return false;
}

/// Advances `i` past ASCII/HTML whitespace within an attribute span.
inline fn skipWhitespace(source: []const u8, end: usize, i: *usize) void {
    while (i.* < end and tables.WhitespaceTable[source[i.*]]) : (i.* += 1) {}
}

/// Returns whether document source is immutable/non-destructive.
inline fn hasConstSource(comptime Doc: type) bool {
    return @FieldType(Doc, "source") == []const u8;
}

/// Returns attribute value by name from in-place attribute bytes, decoding lazily.
/// The result is owned by `allocator` exactly when `SliceResult.owned` is set.
pub inline fn getAttrValue(noalias doc_ptr: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator) !?common.SliceResult {
    const Doc = @TypeOf(doc_ptr.*);
    if (comptime hasConstSource(Doc)) {
        return getAttrValueNonDestructive(doc_ptr, node, name, allocator);
    } else {
        return try getAttrValueDestructive(doc_ptr, node, name, allocator);
    }
}

/// Returns whether an attribute name is present without decoding/materializing
/// its value. This is the selector `[attr]` hot path: existence tests must not
/// pay entity-decoding or temporary-allocation costs for bytes they never use.
pub inline fn hasAttr(noalias doc_ptr: anytype, node: anytype, name: []const u8) bool {
    const source = doc_ptr.source;
    const start: usize = node.name_or_text.end();
    if (start >= source.len) return false;

    if (comptime !hasConstSource(@TypeOf(doc_ptr.*))) {
        // Destructive documents may already have a compacted attribute list.
        // Raw lists always begin with HTML whitespace or a recovery slash.
        if (!tables.WhitespaceTable[source[start]] and source[start] != '/') {
            var it: CompactIterator = .{ .source = source, .cursor = start };
            while (it.next()) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
            }
            return false;
        }
    }

    var it: RawIterator = .{ .source = source, .cursor = start, .end = source.len };
    while (it.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
    }
    return false;
}

/// Returns the current raw attribute value span for `name`.
/// In destructive documents this may point at already-mutated decoded bytes.
pub fn getAttrValueRaw(noalias doc_ptr: anytype, node: anytype, name: []const u8) ?[]const u8 {
    const result = getAttrValueSingle(doc_ptr, node, name, undefined, .raw) catch unreachable;
    return if (result) |r| r.value else null;
}

/// One-pass multi-attribute collector used by matcher hot paths.
pub fn collectSelectedValues(
    noalias doc_ptr: anytype,
    node: anytype,
    selected_names: []const []const u8,
    out_values: []?[]const u8,
    allocator: std.mem.Allocator,
) !void {
    const Doc = @TypeOf(doc_ptr.*);
    if (comptime hasConstSource(Doc)) {
        return collectSelectedValuesNonDestructive(doc_ptr, node, selected_names, out_values, allocator);
    }

    const mut_doc = @constCast(doc_ptr);
    const source: []u8 = mut_doc.source;
    if (selected_names.len == 0) return;
    if (selected_names.len != out_values.len) return;

    const name_end: usize = node.name_or_text.end();
    materializeAttributes(Doc.Options.entity_decoding, source, name_end);
    var remaining: usize = 0;
    for (out_values) |v| {
        if (v == null) remaining += 1;
    }
    if (remaining == 0) return;

    var it: CompactIterator = .{ .source = source, .cursor = name_end };
    while (it.next()) |item| {
        const selected_idx = firstUnresolvedMatch(selected_names, out_values, item.name) orelse continue;
        if (item.value) |value| {
            out_values[selected_idx] = if (item.isDecoded())
                value
            else
                try entities.decodeAllocWithMode(Doc.Options.entity_decoding, true, allocator, value);
        } else {
            out_values[selected_idx] = "";
        }
        remaining -= 1;
        if (remaining == 0) return;
    }
}

fn collectSelectedValuesNonDestructive(
    noalias doc_ptr: anytype,
    node: anytype,
    selected_names: []const []const u8,
    out_values: []?[]const u8,
    allocator: std.mem.Allocator,
) !void {
    if (selected_names.len == 0 or selected_names.len != out_values.len) return;

    var remaining: usize = 0;
    for (out_values) |value| {
        if (value == null) remaining += 1;
    }
    if (remaining == 0) return;

    const source = doc_ptr.source;
    const start: usize = node.name_or_text.end();
    if (start >= source.len) return;

    var it: RawIterator = .{ .source = source, .cursor = start, .end = source.len };
    while (remaining != 0) {
        const item = it.next() orelse break;
        const idx = firstUnresolvedMatch(selected_names, out_values, item.name) orelse continue;
        out_values[idx] = if (item.value) |raw|
            (try materializeRawValue(@TypeOf(doc_ptr.*).Options.entity_decoding, allocator, source, raw)).value
        else
            "";
        remaining -= 1;
    }
}

/// Finds and lazily decodes one attribute value in destructive document source.
inline fn getAttrValueDestructive(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator) !?common.SliceResult {
    const Doc = @TypeOf(doc.*);
    const source: []u8 = doc.source;
    const name_end: usize = node.name_or_text.end();
    materializeAttributes(Doc.Options.entity_decoding, source, name_end);
    var it: CompactIterator = .{ .source = source, .cursor = name_end };
    while (it.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
        const value = item.value orelse return .{ .value = "" };
        if (item.isDecoded()) return .{ .value = value };
        return .{ .value = try entities.decodeAllocWithMode(Doc.Options.entity_decoding, true, allocator, value), .owned = true };
    }
    return null;
}

/// Finds and materializes one attribute value without mutating document source.
inline fn getAttrValueNonDestructive(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator) !?common.SliceResult {
    return getAttrValueSingle(doc, node, name, allocator, .non_destructive);
}

/// Shared single-attribute traversal; mode only changes value materialization.
inline fn getAttrValueSingle(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator, comptime mode: AttrValueMode) !?common.SliceResult {
    const source = doc.source;
    const start: usize = node.name_or_text.end();
    if (start >= source.len) return null;
    // Only destructive documents ever use the compact `name[=value]NUL` form.
    // Read-only documents must keep using the raw scanner even when malformed
    // bytes appear immediately after the tag name.
    if (comptime !hasConstSource(@TypeOf(doc.*))) {
        // A compact list always starts with an attribute-name byte (or `>` for
        // no attributes). A raw slash at name_end is tokenizer recovery or the
        // self-closing marker, not one of our compact value markers.
        if (!tables.WhitespaceTable[source[start]] and source[start] != '/') {
            const value = getCompactAttrValue(source, start, name) orelse return null;
            return .{ .value = value };
        }
    }

    var it: RawIterator = .{ .source = source, .cursor = start, .end = source.len };
    while (it.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
        const raw = item.value orelse return .{ .value = "" };
        return switch (comptime mode) {
            .raw => .{ .value = source[raw.start..raw.end] },
            .non_destructive => try materializeRawValue(@TypeOf(doc.*).Options.entity_decoding, allocator, source, raw),
        };
    }
    return null;
}

fn getCompactAttrValue(source: []const u8, start: usize, name: []const u8) ?[]const u8 {
    var it: CompactIterator = .{ .source = source, .cursor = start };
    while (it.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
        return item.value orelse "";
    }
    return null;
}

/// Decodes a raw attribute value, allocating only when decoding or NUL
/// replacement is required. Ownership is explicit in the returned result.
fn materializeRawValue(comptime entity_decoding: entities.EntityDecoding, allocator: std.mem.Allocator, source: []const u8, raw: RawValue) !common.SliceResult {
    if (raw.kind == .empty) return .{ .value = "" };

    const slice = source[raw.start..raw.end];
    const first = entities.firstDecodableEntityWithMode(entity_decoding, true, slice, 0);
    if (first == null and scanner.findBytePosOrEnd(slice, 0, 0) == slice.len) return .{ .value = slice };

    return .{
        .value = try entities.decodeAllocWithMode(entity_decoding, true, allocator, slice),
        .owned = true,
    };
}

/// Returns the first unresolved requested name matching `name`.
fn firstUnresolvedMatch(selected_names: []const []const u8, out_values: []const ?[]const u8, name: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (std.ascii.eqlIgnoreCase(name, selected_names[idx])) return idx;
    }
    return null;
}

test "scanAttrNameOrSkip handles terminators and skips non-name bytes" {
    const testing = std.testing;

    {
        const src = "a=1";
        var i: usize = 0;
        const scanned = scanAttrNameOrSkip(src, src.len, i);
        const name = scanned.name orelse return error.UnexpectedNull;
        i = scanned.next_start;
        try testing.expectEqualStrings("a", name);
        try testing.expectEqual(@as(usize, 1), i);
    }
    {
        const src = "=a";
        var i: usize = 0;
        const scanned = scanAttrNameOrSkip(src, src.len, i);
        const name = scanned.name orelse return error.UnexpectedNull;
        i = scanned.next_start;
        try testing.expectEqualStrings("=a", name);
        try testing.expectEqual(src.len, i);
    }
    {
        const src = ">";
        const i: usize = 0;
        const scanned = scanAttrNameOrSkip(src, src.len, i);
        try testing.expect(scanned.name == null);
    }
    {
        const src = "/";
        const i: usize = 0;
        const scanned = scanAttrNameOrSkip(src, src.len, i);
        try testing.expect(scanned.name == null);
    }
}

test "destructive materialization recovers attributes after tag-name slash" {
    var source = "div/id=x>".*;
    materializeAttributes(.full, &source, 3);

    var it: CompactIterator = .{ .source = &source, .cursor = 3 };
    const id = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("id", id.name);
    try std.testing.expectEqualStrings("x", id.value.?);
    try std.testing.expect(it.next() == null);
}

test "destructive raw lookup does not confuse recovery slash with compact marker" {
    const FakeDoc = struct {
        const Options = struct {
            const entity_decoding: entities.EntityDecoding = .common;
        };
        source: []u8,
    };
    const FakeNode = struct {
        name_or_text: common.Span,
    };
    var source = "div/id=x>".*;
    var doc = FakeDoc{ .source = &source };
    const node = FakeNode{ .name_or_text = .{ .start = 0, .len = 3 } };

    const result = try getAttrValueSingle(&doc, node, "id", undefined, .raw);
    try std.testing.expectEqualStrings("x", result.?.value);
}

test "raw iterator recovers after stray slash between attributes" {
    const source = " / id=x a / b=y>";
    var it: RawIterator = .{ .source = source, .cursor = 0, .end = source.len };

    const id = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("id", id.name);
    try std.testing.expectEqualStrings("x", id.valueRaw().?);

    const a = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expect(a.value == null);

    const b = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", b.name);
    try std.testing.expectEqualStrings("y", b.valueRaw().?);
    try std.testing.expect(it.next() == null);
}

test "hasAttr checks raw and compact lists without materializing values" {
    const RawDoc = struct { source: []const u8 };
    const MutableDoc = struct { source: []u8 };
    const FakeNode = struct { name_or_text: common.Span };
    const node = FakeNode{ .name_or_text = .{ .start = 0, .len = 3 } };

    const raw_source = "div href='a&amp;b' disabled data-x=1>";
    const raw_doc = RawDoc{ .source = raw_source };
    try std.testing.expect(hasAttr(&raw_doc, node, "href"));
    try std.testing.expect(hasAttr(&raw_doc, node, "DISABLED"));
    try std.testing.expect(!hasAttr(&raw_doc, node, "missing"));

    var mutable_source = raw_source.*;
    const before = mutable_source;
    var mutable_doc = MutableDoc{ .source = &mutable_source };
    try std.testing.expect(hasAttr(&mutable_doc, node, "href"));
    try std.testing.expectEqualSlices(u8, &before, &mutable_source);

    materializeAttributes(.common, &mutable_source, 3);
    try std.testing.expect(hasAttr(&mutable_doc, node, "href"));
    try std.testing.expect(hasAttr(&mutable_doc, node, "disabled"));
    try std.testing.expect(!hasAttr(&mutable_doc, node, "missing"));
}

test "raw iterator preserves parse-error bytes in attribute names" {
    const source = " a\"b=x =lead=y ctl\x01name=z>";
    var it: RawIterator = .{ .source = source, .cursor = 0, .end = source.len };

    const quoted = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a\"b", quoted.name);
    try std.testing.expectEqualStrings("x", quoted.valueRaw().?);

    const leading_equal = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("=lead", leading_equal.name);
    try std.testing.expectEqualStrings("y", leading_equal.valueRaw().?);

    const control = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ctl\x01name", control.name);
    try std.testing.expectEqualStrings("z", control.valueRaw().?);
    try std.testing.expect(it.next() == null);
}

test "destructive compaction falls back to raw tail for marker-colliding names" {
    var source = "div ok=v a\"b=x =lead=y tail=z>".*;
    materializeAttributes(.common, &source, 3);

    var it: CompactIterator = .{ .source = &source, .cursor = 3 };
    const ok = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ok", ok.name);
    try std.testing.expectEqualStrings("v", ok.value.?);
    try std.testing.expect(ok.isDecoded());

    const quoted = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a\"b", quoted.name);
    try std.testing.expectEqualStrings("x", quoted.value.?);
    try std.testing.expect(!quoted.isDecoded());

    const leading_equal = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("=lead", leading_equal.name);
    try std.testing.expectEqualStrings("y", leading_equal.value.?);

    const tail = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tail", tail.name);
    try std.testing.expectEqualStrings("z", tail.value.?);
    try std.testing.expect(it.next() == null);

    // Re-materialization must recognize the raw-tail sentinel and be idempotent.
    const once = source;
    materializeAttributes(.common, &source, 3);
    try std.testing.expectEqualSlices(u8, &once, &source);
}

test "destructive raw-tail fallback can begin at the first attribute" {
    var source = "div a'b=x plain=y>".*;
    materializeAttributes(.common, &source, 3);
    try std.testing.expectEqual(@as(u8, 0), source[3]);

    var it: CompactIterator = .{ .source = &source, .cursor = 3 };
    const malformed = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a'b", malformed.name);
    try std.testing.expectEqualStrings("x", malformed.value.?);
    const plain = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("plain", plain.name);
    try std.testing.expectEqualStrings("y", plain.value.?);
    try std.testing.expect(it.next() == null);
}

test "destructive raw-tail fallback collapses quoted-empty assignments" {
    var source = "div =lead=\"\" a'b='' tail=z>".*;
    materializeAttributes(.common, &source, 3);

    var it: CompactIterator = .{ .source = &source, .cursor = 3 };
    const leading_equal = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("=lead", leading_equal.name);
    try std.testing.expect(leading_equal.value == null);

    const quoted_name = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a'b", quoted_name.name);
    try std.testing.expect(quoted_name.value == null);

    const tail = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tail", tail.name);
    try std.testing.expectEqualStrings("z", tail.value.?);
    try std.testing.expect(it.next() == null);
}

test "scanAttrNameOrSkip accepts framework attribute punctuation" {
    const src = "@click *ngIf (change) [value] v-on:click x-on:keydown data-foo.bar";
    var i: usize = 0;
    const expected = [_][]const u8{ "@click", "*ngIf", "(change)", "[value]", "v-on:click", "x-on:keydown", "data-foo.bar" };
    for (expected) |want| {
        while (i < src.len and tables.WhitespaceTable[src[i]]) : (i += 1) {}
        const scanned = scanAttrNameOrSkip(src, src.len, i);
        try std.testing.expectEqualStrings(want, scanned.name.?);
        i = scanned.next_start;
    }
}

test "valueDelimiterIndex skips whitespace before assignment" {
    const src = "id \n\t = \"x\" next";
    try std.testing.expectEqual(
        std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq,
        valueDelimiterIndex(src, src.len, 2),
    );
    const bare = "id   next";
    try std.testing.expectEqual(@as(usize, 5), valueDelimiterIndex(bare, bare.len, 2));
}

test "parseRawValue handles quoted, naked, empty, and unterminated" {
    const testing = std.testing;

    {
        const src = "a=\"x\"";
        const eq = std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq;
        const raw = parseRawValue(src, src.len, eq);
        try testing.expectEqual(RawKind.quoted, raw.kind);
        try testing.expectEqual(@as(usize, 3), raw.start);
        try testing.expectEqual(@as(usize, 4), raw.end);
        try testing.expectEqual(@as(usize, 5), raw.next_start);
    }
    {
        const src = "a=xyz";
        const eq = std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq;
        const raw = parseRawValue(src, src.len, eq);
        try testing.expectEqual(RawKind.naked, raw.kind);
        try testing.expectEqual(@as(usize, 2), raw.start);
        try testing.expectEqual(@as(usize, 5), raw.end);
        try testing.expectEqual(@as(usize, 5), raw.next_start);
    }
    {
        const src = "a=/docs/v1/api";
        const eq = std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq;
        const raw = parseRawValue(src, src.len, eq);
        try testing.expectEqual(RawKind.naked, raw.kind);
        try testing.expectEqual(@as(usize, 2), raw.start);
        try testing.expectEqual(src.len, raw.end);
        try testing.expectEqual(src.len, raw.next_start);
    }
    {
        const src = "a=   \"z\"";
        const eq = std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq;
        const raw = parseRawValue(src, src.len, eq);
        try testing.expectEqual(RawKind.quoted, raw.kind);
        try testing.expectEqual(@as(usize, 6), raw.start);
        try testing.expectEqual(@as(usize, 7), raw.end);
        try testing.expectEqual(@as(usize, 8), raw.next_start);
    }
    {
        const src = "a=>";
        const eq = std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq;
        const raw = parseRawValue(src, src.len, eq);
        try testing.expectEqual(RawKind.empty, raw.kind);
        try testing.expectEqual(@as(usize, 2), raw.start);
        try testing.expectEqual(@as(usize, 2), raw.end);
        try testing.expectEqual(@as(usize, 2), raw.next_start);
    }
    {
        const src = "a=\"xyz";
        const eq = std.mem.indexOfScalar(u8, src, '=') orelse return error.MissingEq;
        const raw = parseRawValue(src, src.len, eq);
        try testing.expectEqual(RawKind.quoted, raw.kind);
        try testing.expectEqual(@as(usize, 3), raw.start);
        try testing.expectEqual(src.len, raw.end);
        try testing.expectEqual(src.len, raw.next_start);
    }
}

test "materializeAttributes compacts and decodes the complete list" {
    var buf = "<a b = \"x&amp;y\" c d='a>b'>".*;
    materializeAttributes(.common, &buf, 2);
    try std.testing.expectEqualSlices(u8, "b=x&y\x00c\x00d=a>b\x00>", buf[2..17]);
    try std.testing.expectEqualStrings("x&y", getCompactAttrValue(&buf, 2, "b").?);
    try std.testing.expectEqualStrings("", getCompactAttrValue(&buf, 2, "c").?);
    try std.testing.expectEqualStrings("a>b", getCompactAttrValue(&buf, 2, "d").?);
}

test "materializeAttributes preserves slash values and collapses empty assignments" {
    var slash = "<a b=/>".*;
    materializeAttributes(.common, &slash, 2);
    try std.testing.expectEqualSlices(u8, "b=/\x00>", slash[2..]);

    var empty = "<a b=>".*;
    materializeAttributes(.common, &empty, 2);
    try std.testing.expectEqualSlices(u8, "b\x00>>", empty[2..]);
}

test "RW compaction preserves invalid value bytes and sanitizes invalid name leads" {
    var buf = [_]u8{ '<', 'a', ' ', 0x80, 'b', '=', 0xff, 'x', '>' };
    const raw = scanAttrNameOrSkip(&buf, buf.len, 3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 'b' }, raw.name.?);

    materializeAttributes(.common, &buf, 2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 'b', '=', 0xff, 'x', 0, '>' }, buf[2..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 'x' }, getCompactAttrValue(&buf, 2, &[_]u8{ 0x01, 'b' }).?);
}
