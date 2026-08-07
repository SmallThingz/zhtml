const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const tables = @import("tables.zig");
const entities = @import("entities.zig");

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
    if (c == '>' or c == '/') return .{ .name = null, .next_start = start };

    var i = start;
    const name_start = i;
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
        const j = std.mem.indexOfScalarPos(u8, source, i + 1, c) orelse span_end;
        const next_start = if (j < span_end) j + 1 else span_end;
        return .{ .kind = .quoted, .start = i + 1, .end = j, .next_start = next_start };
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

/// Destructive documents compact a complete tag's attributes on first access.
/// The compact form is `name[=decoded-value]NUL ... >`; empty assignments and
/// valueless attributes both use `nameNUL`.
pub fn materializeAttributes(source: []u8, name_end: usize) void {
    if (name_end >= source.len or !tables.WhitespaceTable[source[name_end]]) return;

    var read = name_end;
    var write = name_end;
    const end = source.len;

    while (read < end) {
        skipWhitespace(source, end, &read);
        if (read >= end) break;
        if (source[read] == '>') {
            source[write] = '>';
            return;
        }
        if (source[read] == '/') {
            while (read < end and source[read] != '>') : (read += 1) {}
            source[write] = '>';
            return;
        }

        const scanned = scanAttrNameOrSkip(source, end, read);
        const raw_name = scanned.name orelse {
            source[write] = '>';
            return;
        };
        read = scanned.next_start;
        if (raw_name.len == 0) continue;

        const name_dst = write;
        const bad_first_utf8 = invalidUtf8First(raw_name);
        std.mem.copyForwards(u8, source[write .. write + raw_name.len], raw_name);
        // RW mode sanitizes a malformed UTF-8 lead byte. RO traversal preserves it.
        if (bad_first_utf8) source[write] = 0x01;
        for (source[write .. write + raw_name.len]) |*b| {
            if (b.* == 0) b.* = 0x01;
        }
        write += raw_name.len;

        const delim = valueDelimiterIndex(source, end, read);
        if (delim < end and source[delim] == '=') {
            const raw = parseRawValue(source, end, delim);
            read = raw.next_start;
            if (raw.kind != .empty and raw.end > raw.start) {
                const decoded_len = entities.decodeAttributeInPlace(source[raw.start..raw.end], null);
                source[write] = '=';
                write += 1;
                std.mem.copyForwards(u8, source[write .. write + decoded_len], source[raw.start .. raw.start + decoded_len]);
                write += decoded_len;
            }
        } else {
            read = delim;
        }

        // `name_dst` documents that every successfully scanned name emits an attr.
        std.debug.assert(write > name_dst);
        source[write] = 0;
        write += 1;
    }
    if (write < end) source[write] = '>';
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
pub inline fn getAttrValue(noalias doc_ptr: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const Doc = @TypeOf(doc_ptr.*);
    if (comptime hasConstSource(Doc)) {
        return getAttrValueNonDestructive(doc_ptr, node, name, allocator);
    } else {
        return getAttrValueDestructive(doc_ptr, node, name);
    }
}

/// Returns the current raw attribute value span for `name`.
/// In destructive documents this may point at already-mutated decoded bytes.
pub fn getAttrValueRaw(noalias doc_ptr: anytype, node: anytype, name: []const u8) ?[]const u8 {
    return getAttrValueSingle(doc_ptr, node, name, undefined, .raw) catch unreachable;
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
        var idx: usize = 0;
        while (idx < selected_names.len) : (idx += 1) {
            if (out_values[idx] != null) continue;
            out_values[idx] = try getAttrValueNonDestructive(doc_ptr, node, selected_names[idx], allocator);
        }
        return;
    }

    const mut_doc = @constCast(doc_ptr);
    const source: []u8 = mut_doc.source;
    if (selected_names.len == 0) return;
    if (selected_names.len != out_values.len) return;

    const name_end: usize = node.name_or_text.end();
    materializeAttributes(source, name_end);
    var i = name_end;
    const end = source.len;
    var remaining: usize = 0;
    for (out_values) |v| {
        if (v == null) remaining += 1;
    }
    if (remaining == 0) return;

    while (i < end) {
        if (source[i] == '>') break;
        const name_start = i;
        while (i < end and source[i] != '=' and source[i] != 0 and source[i] != '>') : (i += 1) {}
        if (i >= end or source[i] == '>') break;
        const name_slice = source[name_start..i];
        const selected_idx = firstUnresolvedMatch(selected_names, out_values, name_slice);
        var value: []const u8 = "";
        if (source[i] == '=') {
            const value_start = i + 1;
            i = value_start;
            while (i < end and source[i] != 0) : (i += 1) {}
            value = source[value_start..i];
        }
        if (i < end and source[i] == 0) i += 1;
        if (selected_idx) |idx| {
            out_values[idx] = value;
            remaining -= 1;
            if (remaining == 0) return;
        }
    }
}

/// Finds and lazily decodes one attribute value in destructive document source.
inline fn getAttrValueDestructive(doc: anytype, node: anytype, name: []const u8) ?[]const u8 {
    const source: []u8 = @constCast(doc).source;
    const name_end: usize = node.name_or_text.end();
    materializeAttributes(source, name_end);
    return getCompactAttrValue(source, name_end, name);
}

/// Finds and materializes one attribute value without mutating document source.
inline fn getAttrValueNonDestructive(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    return getAttrValueSingle(doc, node, name, allocator, .non_destructive);
}

/// Shared single-attribute traversal; mode only changes value materialization.
inline fn getAttrValueSingle(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator, comptime mode: AttrValueMode) !?[]const u8 {
    const source = doc.source;

    var i: usize = node.name_or_text.end();
    const end = source.len;
    if (i >= end) return null;
    if (!tables.WhitespaceTable[source[i]]) return getCompactAttrValue(source, i, name);

    while (i < end) {
        skipWhitespace(source, end, &i);
        if (i >= end) return null;

        const scanned = scanAttrNameOrSkip(source, end, i);
        const attr_name = scanned.name orelse return null;
        i = scanned.next_start;
        if (attr_name.len == 0) continue;
        const is_target = std.ascii.eqlIgnoreCase(attr_name, name);

        const delim_index = valueDelimiterIndex(source, end, i);
        if (delim_index >= end) return if (is_target) "" else null;

        const delim = source[delim_index];
        if (delim == '=') {
            const raw = parseRawValue(source, end, delim_index);
            if (is_target) {
                return switch (comptime mode) {
                    .raw => source[raw.start..raw.end],
                    .non_destructive => try materializeRawValueOwned(allocator, source, raw),
                };
            }
            i = raw.next_start;
            continue;
        }

        if (is_target) return "";
        if (delim == '>' or delim == '/') return null;
        i = if (delim_index == i) i + 1 else delim_index;
    }

    return null;
}

fn getCompactAttrValue(source: []const u8, start: usize, name: []const u8) ?[]const u8 {
    var i = start;
    while (i < source.len and source[i] != '>') {
        const name_start = i;
        while (i < source.len and source[i] != '=' and source[i] != 0 and source[i] != '>') : (i += 1) {}
        if (i >= source.len or source[i] == '>') return null;
        const is_target = std.ascii.eqlIgnoreCase(source[name_start..i], name);
        if (source[i] == 0) {
            i += 1;
            if (is_target) return "";
            continue;
        }
        const value_start = i + 1;
        i = value_start;
        while (i < source.len and source[i] != 0) : (i += 1) {}
        if (i >= source.len) return null;
        if (is_target) return source[value_start..i];
        i += 1;
    }
    return null;
}

/// Returns decoded raw value for non-destructive documents, allocating only when needed.
fn materializeRawValueOwned(allocator: std.mem.Allocator, source: []const u8, raw: RawValue) ![]const u8 {
    if (raw.kind == .empty) return "";

    const slice = source[raw.start..raw.end];
    const first = entities.firstDecodableEntity(slice, 0);
    if (first == null and std.mem.indexOfScalar(u8, slice, 0) == null) return slice;

    const copied = try allocator.dupe(u8, slice);
    errdefer allocator.free(copied);

    const new_len = entities.decodeAttributeInPlace(copied, first);
    if (new_len == copied.len) return copied;
    return try allocator.realloc(copied, new_len);
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
        try testing.expectEqual(@as(usize, 0), name.len);
        try testing.expectEqual(@as(usize, 1), i);
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
    materializeAttributes(&buf, 2);
    try std.testing.expectEqualSlices(u8, "b=x&y\x00c\x00d=a>b\x00>", buf[2..17]);
    try std.testing.expectEqualStrings("x&y", getCompactAttrValue(&buf, 2, "b").?);
    try std.testing.expectEqualStrings("", getCompactAttrValue(&buf, 2, "c").?);
    try std.testing.expectEqualStrings("a>b", getCompactAttrValue(&buf, 2, "d").?);
}

test "materializeAttributes preserves slash values and collapses empty assignments" {
    var slash = "<a b=/>".*;
    materializeAttributes(&slash, 2);
    try std.testing.expectEqualSlices(u8, "b=/\x00>", slash[2..]);

    var empty = "<a b=>".*;
    materializeAttributes(&empty, 2);
    try std.testing.expectEqualSlices(u8, "b\x00>>", empty[2..]);
}

test "RW compaction preserves invalid value bytes and sanitizes invalid name leads" {
    var buf = [_]u8{ '<', 'a', ' ', 0x80, 'b', '=', 0xff, 'x', '>' };
    const raw = scanAttrNameOrSkip(&buf, buf.len, 3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 'b' }, raw.name.?);

    materializeAttributes(&buf, 2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 'b', '=', 0xff, 'x', 0, '>' }, buf[2..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 'x' }, getCompactAttrValue(&buf, 2, &[_]u8{ 0x01, 'b' }).?);
}
