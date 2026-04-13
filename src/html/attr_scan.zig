const std = @import("std");
const tables = @import("tables.zig");
const common = @import("../common.zig");

const IndexInt = common.IndexInt;
const ExtendedGapSentinel = 0xff;
const ExtendedGapHeaderLen = 2 + @sizeOf(IndexInt);

// SAFETY: Callers provide slice bounds and indices. Invariants asserted in debug:
// - `span_end <= source.len`
// - `i.* < end` for scanAttrNameOrSkip
// - `eq_index < span_end` for parseRawValue
// - `value_start <= span_end` / `value_end <= span_end` for value helpers

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

/// Scans the next attribute name starting at `i`.
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
pub fn parseParsedValue(source: []u8, span_end: usize, name_end: usize) ParsedValue {
    std.debug.assert(span_end <= source.len);
    if (name_end + 1 >= span_end) return .{ .value = "", .next_start = span_end };

    const marker = source[name_end + 1];
    var value_start: usize = if (marker == 0) name_end + 2 else name_end + 1;
    if (value_start > span_end) value_start = span_end;

    const value_end = findValueEnd(source, value_start, span_end);
    const next = nextAfterValue(source, value_end, span_end);
    return .{ .value = source[value_start..value_end], .next_start = next };
}

pub fn findValueEnd(source: []const u8, value_start: usize, span_end: usize) usize {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(value_start <= span_end);
    var i = value_start;
    while (i < span_end and source[i] != 0) : (i += 1) {}
    return i;
}

pub fn nextAfterValue(source: []const u8, value_end: usize, span_end: usize) usize {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(value_end <= span_end);
    if (value_end >= span_end) return span_end;
    var i = value_end + 1;
    if (i >= span_end) return span_end;

    if (source[i] == 0) {
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

pub fn nativeEndian() std.builtin.Endian {
    return @import("builtin").cpu.arch.endian();
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
    {
        const skip: IndexInt = 2;
        var buf: [7 + ExtendedGapHeaderLen + skip + 1]u8 = undefined;
        @memset(&buf, 0);
        buf[0] = 'a';
        buf[3] = 'v';
        buf[4] = 'a';
        buf[5] = 'l';
        buf[7] = 0;
        buf[8] = ExtendedGapSentinel;
        std.mem.writeInt(IndexInt, buf[9 .. 9 + @sizeOf(IndexInt)], skip, nativeEndian());
        buf[7 + ExtendedGapHeaderLen + skip] = 'b';
        const parsed = parseParsedValue(buf[0..], buf.len, 1);
        try testing.expectEqualStrings("val", parsed.value);
        try testing.expectEqual(7 + ExtendedGapHeaderLen + @as(usize, skip), parsed.next_start);
    }
    {
        var buf = [_]u8{ 'a', 0, 0, 'v', 0, 0, 0xff, 1 };
        const parsed = parseParsedValue(buf[0..], buf.len, 1);
        try testing.expectEqualStrings("v", parsed.value);
        try testing.expectEqual(buf.len, parsed.next_start);
    }
}
