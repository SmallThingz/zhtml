const std = @import("std");
const tables = @import("tables.zig");
const entities = @import("entities.zig");
const common = @import("../common.zig");

const IndexInt = common.IndexInt;
const ExtendedGapSentinel = 0xff;
const ExtendedGapHeaderLen = 2 + @sizeOf(IndexInt);

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

pub const ParsedValue = struct {
    /// Borrowed parsed attribute value bytes.
    value: []const u8,
    /// Next scan cursor after this parsed value.
    next_start: usize,
};

pub const ScanAttrNameResult = struct {
    /// Parsed attribute name, `null` at tag terminator, or `""` when one byte was skipped.
    name: ?[]const u8,
    /// Next scan cursor after the attribute name or skipped byte.
    next_start: usize,
};

const LookupKind = enum(u8) {
    generic,
    id,
    class,
    href,
};

const AttrValueMode = enum {
    raw,
    destructive,
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
    while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {}
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

/// Parses parsed in-place attribute value span (after name delimiter).
pub fn parseParsedValue(source: []const u8, span_end: usize, name_end: usize) ParsedValue {
    std.debug.assert(span_end <= source.len);
    if (name_end + 1 >= span_end) return .{ .value = "", .next_start = span_end };

    // In destructive mode parsed values are materialized in place and delimited
    // by zero bytes plus optional gap metadata.
    const marker = source[name_end + 1];
    const quoted = marker == 0;
    var value_start: usize = if (quoted) name_end + 2 else name_end + 1;
    if (value_start > span_end) value_start = span_end;

    const value_end = findParsedValueEnd(source, value_start, span_end, quoted);
    if (!quoted and value_end < span_end and source[value_end] == '>') {
        return .{ .value = source[value_start..value_end], .next_start = value_end };
    }
    const next = nextAfterValue(source, value_end, span_end);
    return .{ .value = source[value_start..value_end], .next_start = next };
}

/// Finds a destructive-mode parsed value end; naked values may end at `>`.
pub fn findParsedValueEnd(source: []const u8, value_start: usize, span_end: usize, quoted: bool) usize {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(value_start <= span_end);
    var i = value_start;
    if (quoted) {
        while (i < span_end and source[i] != 0) : (i += 1) {}
    } else {
        while (i < span_end and source[i] != 0 and source[i] != '>') : (i += 1) {}
    }
    return i;
}

/// Returns the next attribute scan cursor after a parsed value and gap metadata.
pub fn nextAfterValue(source: []const u8, value_end: usize, span_end: usize) usize {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(value_end <= span_end);
    if (value_end >= span_end) return span_end;
    var i = value_end + 1;
    if (i >= span_end) return span_end;

    if (source[i] == 0) {
        // Gap metadata preserves how much source was skipped when the decoded
        // value is shorter than its raw representation.
        if (i + 1 >= span_end) return span_end;

        const len_byte = source[i + 1];
        if (len_byte == ExtendedGapSentinel) {
            if (i + ExtendedGapHeaderLen > span_end) return span_end;
            const skip = std.mem.readInt(IndexInt, source[i + 2 .. i + ExtendedGapHeaderLen][0..@sizeOf(IndexInt)], nativeEndian());
            const next = i + ExtendedGapHeaderLen + @as(usize, @intCast(skip));
            return @min(next, span_end);
        }

        const next = i + 2 + @as(usize, len_byte);
        return @min(next, span_end);
    }

    if (tables.WhitespaceTable[source[i]]) {
        while (i < span_end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        return i;
    }

    return i;
}

/// Returns the next cursor after a destructive-mode attribute gap marker.
pub fn skipAttrGap(source: []const u8, span_end: usize, start: usize) usize {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(start < span_end);
    if (start + 1 >= span_end) return span_end;
    const len_byte = source[start + 1];
    if (len_byte == ExtendedGapSentinel) {
        if (start + ExtendedGapHeaderLen > span_end) return span_end;
        const skip = std.mem.readInt(IndexInt, source[start + 2 .. start + ExtendedGapHeaderLen][0..@sizeOf(IndexInt)], nativeEndian());
        const next = start + ExtendedGapHeaderLen + @as(usize, @intCast(skip));
        return @min(next, span_end);
    }
    const next = start + 2 + @as(usize, len_byte);
    return @min(next, span_end);
}

/// Returns native endian used to encode in-buffer gap metadata.
pub fn nativeEndian() std.builtin.Endian {
    return @import("builtin").cpu.arch.endian();
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

    // Selector matching often probes a few attribute names repeatedly; this
    // helper resolves all requested names in one traversal of the attr span.
    var i: usize = node.name_or_text.end();
    const end = source.len;
    var remaining: usize = 0;
    for (out_values) |v| {
        if (v == null) remaining += 1;
    }
    if (remaining == 0) return;

    while (i < end) {
        skipWhitespace(source, end, &i);
        if (i >= end) break;

        const scanned = scanAttrNameOrSkip(source, end, i);
        const name_slice = scanned.name orelse break;
        i = scanned.next_start;
        if (name_slice.len == 0) continue;
        const selected_idx = firstUnresolvedMatch(selected_names, out_values, name_slice);

        if (i >= end) {
            if (selected_idx) |idx| {
                out_values[idx] = "";
                remaining -= 1;
            }
            break;
        }

        const delim = source[i];
        if (delim == '=') {
            const eq_index = i;
            const raw = parseRawValue(source, end, eq_index);
            if (selected_idx) |idx| {
                out_values[idx] = materializeRawValue(source, end, eq_index, raw);
                const parsed = parseParsedValue(source, end, eq_index);
                i = parsed.next_start;
                remaining -= 1;
                if (remaining == 0) return;
            } else {
                i = raw.next_start;
            }
            continue;
        }

        if (delim == 0) {
            const parsed = parseParsedValue(source, end, i);
            i = parsed.next_start;
            if (selected_idx) |idx| {
                out_values[idx] = parsed.value;
                remaining -= 1;
                if (remaining == 0) return;
            }
            continue;
        }

        if (selected_idx) |idx| {
            out_values[idx] = "";
            remaining -= 1;
            if (remaining == 0) return;
        }

        if (delim == '>' or delim == '/') break;
        if (tables.WhitespaceTable[delim]) {
            i += 1;
            continue;
        }
        i += 1;
    }
}

/// Finds and lazily decodes one attribute value in destructive document source.
inline fn getAttrValueDestructive(doc: anytype, node: anytype, name: []const u8) ?[]const u8 {
    return getAttrValueSingle(doc, node, name, undefined, .destructive) catch unreachable;
}

/// Finds and materializes one attribute value without mutating document source.
inline fn getAttrValueNonDestructive(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    return getAttrValueSingle(doc, node, name, allocator, .non_destructive);
}

/// Shared single-attribute traversal; mode only changes value materialization.
inline fn getAttrValueSingle(doc: anytype, node: anytype, name: []const u8, allocator: std.mem.Allocator, comptime mode: AttrValueMode) !?[]const u8 {
    const source = if (comptime mode == .destructive) @constCast(doc).source else doc.source;
    const lookup_kind = classifyLookupName(name);

    var i: usize = node.name_or_text.end();
    const end = source.len;
    if (i >= end) return null;

    while (i < end) {
        skipWhitespace(source, end, &i);
        if (i >= end) return null;

        const scanned = scanAttrNameOrSkip(source, end, i);
        const attr_name = scanned.name orelse return null;
        i = scanned.next_start;
        if (attr_name.len == 0) continue;
        const is_target = matchesLookupName(attr_name, name, lookup_kind);

        if (i >= end) return if (is_target) "" else null;

        const delim = source[i];
        if (delim == '=') {
            const raw = parseRawValue(source, end, i);
            if (is_target) {
                return switch (comptime mode) {
                    .raw => source[raw.start..raw.end],
                    .destructive => materializeRawValue(source, end, i, raw),
                    .non_destructive => try materializeRawValueOwned(allocator, source, raw),
                };
            }
            i = raw.next_start;
            continue;
        }

        if (delim == 0) {
            const parsed = parseParsedValue(source, end, i);
            if (is_target) return parsed.value;
            i = parsed.next_start;
            continue;
        }

        if (is_target) return "";
        if (delim == '>' or delim == '/') return null;
        i += 1;
    }

    return null;
}

/// Returns decoded raw value for non-destructive documents, allocating only when needed.
fn materializeRawValueOwned(allocator: std.mem.Allocator, source: []const u8, raw: RawValue) ![]const u8 {
    if (raw.kind == .empty) return "";

    const slice = source[raw.start..raw.end];
    const first = entities.firstDecodableEntity(slice, 0) orelse return slice;

    const copied = try allocator.dupe(u8, slice);
    errdefer allocator.free(copied);

    const new_len = entities.decodeInPlaceFrom(false, copied, first);
    if (new_len == copied.len) return copied;
    return try allocator.realloc(copied, new_len);
}

/// Decodes a raw value into destructive source bytes and returns its new span.
fn materializeRawValue(source: []u8, span_end: usize, eq_index: usize, raw: RawValue) []const u8 {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(eq_index < span_end);
    std.debug.assert(raw.start <= raw.end and raw.end <= span_end);
    std.debug.assert(raw.next_start <= span_end);
    if (raw.kind == .empty) {
        source[eq_index] = ' ';
        return "";
    }

    var decoded_len: usize = raw.end - raw.start;
    decoded_len = entities.decodeInPlace(false, source[raw.start..raw.end]);

    if (raw.kind == .quoted) {
        source[eq_index] = 0;
        if (eq_index + 1 < span_end) source[eq_index + 1] = 0;

        const dst = @min(eq_index + 2, span_end);
        if (decoded_len != 0 and dst != raw.start and dst + decoded_len <= span_end) {
            std.mem.copyForwards(u8, source[dst .. dst + decoded_len], source[raw.start .. raw.start + decoded_len]);
        }

        const term = @min(dst + decoded_len, span_end);
        if (term < span_end) {
            source[term] = 0;
            patchGap(source, span_end, term, raw.next_start);
        }
        return source[dst..term];
    }

    source[eq_index] = 0;

    const dst = @min(eq_index + 1, span_end);
    if (decoded_len != 0 and dst != raw.start and dst + decoded_len <= span_end) {
        std.mem.copyForwards(u8, source[dst .. dst + decoded_len], source[raw.start .. raw.start + decoded_len]);
    }

    const term = @min(dst + decoded_len, span_end);
    if (term < span_end) {
        source[term] = 0;
        patchGap(source, span_end, term, raw.next_start);
    }

    return source[dst..term];
}

/// Writes gap metadata after a shortened decoded value.
fn patchGap(source: []u8, span_end: usize, value_end: usize, raw_next_start: usize) void {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(value_end <= span_end);
    if (value_end + 1 >= span_end) return;

    const next_start = @min(raw_next_start, span_end);
    if (next_start <= value_end + 1) return;

    const gap_start = value_end + 1;
    const gap_len = next_start - gap_start;
    if (gap_len == 0) return;

    if (gap_len == 1) {
        source[gap_start] = ' ';
        return;
    }

    if (gap_len <= 256) {
        source[gap_start] = 0;
        source[gap_start + 1] = @intCast(gap_len - 2);
        return;
    }

    source[gap_start] = 0;
    source[gap_start + 1] = ExtendedGapSentinel;
    const skip: IndexInt = @intCast(gap_len - ExtendedGapHeaderLen);
    std.mem.writeInt(IndexInt, source[gap_start + 2 .. gap_start + ExtendedGapHeaderLen][0..@sizeOf(IndexInt)], skip, nativeEndian());
}

/// Returns the first unresolved requested name matching `name`.
fn firstUnresolvedMatch(selected_names: []const []const u8, out_values: []const ?[]const u8, name: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (matchesLookupName(name, selected_names[idx], .generic)) return idx;
    }
    return null;
}

/// Returns whether an attribute name matches the requested lookup name.
fn matchesLookupName(attr_name: []const u8, lookup: []const u8, lookup_kind: LookupKind) bool {
    switch (lookup_kind) {
        .id => return isExactAsciiWord(attr_name, "id"),
        .class => return isExactAsciiWord(attr_name, "class"),
        .href => return isExactAsciiWord(attr_name, "href"),
        .generic => {},
    }

    if (attr_name.len != lookup.len) return false;
    if (attr_name.len != 0 and std.ascii.toLower(attr_name[0]) != std.ascii.toLower(lookup[0])) return false;
    return std.ascii.eqlIgnoreCase(attr_name, lookup);
}

/// Classifies common lookup names for cheaper comparisons.
fn classifyLookupName(lookup: []const u8) LookupKind {
    if (isExactAsciiWord(lookup, "id")) return .id;
    if (isExactAsciiWord(lookup, "class")) return .class;
    if (isExactAsciiWord(lookup, "href")) return .href;
    return .generic;
}

/// Returns true when `value` equals a known lowercase ASCII word.
fn isExactAsciiWord(value: []const u8, comptime lower: []const u8) bool {
    if (value.len != lower.len) return false;
    var i: usize = 0;
    while (i < lower.len) : (i += 1) {
        if (std.ascii.toLower(value[i]) != lower[i]) return false;
    }
    return true;
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

test "parseParsedValue honors gap markers and truncation" {
    const testing = std.testing;

    {
        var buf = [_]u8{ 'a', 0, 'v', 'a', 'l', 0, ' ', 'b' };
        const parsed = parseParsedValue(buf[0..], buf.len, 1);
        try testing.expectEqualStrings("val", parsed.value);
        try testing.expectEqual(@as(usize, 7), parsed.next_start);
    }
    {
        var buf = [_]u8{ 'a', 0, 0, 'v', 'a', 'l', 0, 0, 1, 'x', 'b' };
        const parsed = parseParsedValue(buf[0..], buf.len, 1);
        try testing.expectEqualStrings("val", parsed.value);
        try testing.expectEqual(@as(usize, 10), parsed.next_start);
    }
}

test "materializeRawValue preserves traversal for following attrs" {
    const testing = std.testing;

    var buf = "a=\"x\" b=\"y\"".*;
    const span_end = buf.len;
    const eq_index = std.mem.indexOfScalar(u8, &buf, '=') orelse return error.MissingEq;
    const raw = parseRawValue(&buf, span_end, eq_index);
    const value = materializeRawValue(buf[0..], span_end, eq_index, raw);
    try testing.expectEqualStrings("x", value);

    const parsed = parseParsedValue(buf[0..], span_end, eq_index);
    try testing.expectEqualStrings("x", parsed.value);

    var i = parsed.next_start;
    while (i < span_end and tables.WhitespaceTable[buf[i]]) : (i += 1) {}
    const scanned = scanAttrNameOrSkip(&buf, span_end, i);
    const name = scanned.name orelse return error.MissingAttr;
    try testing.expectEqualStrings("b", name);
}
