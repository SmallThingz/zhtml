const std = @import("std");
const tables = @import("tables.zig");
const scanner = @import("scanner.zig");

pub const RawKind = enum {
    empty,
    quoted,
    naked,
};

pub const RawValue = struct {
    kind: RawKind,
    start: usize,
    end: usize,
    next_start: usize,
};

pub const ParsedValue = struct {
    value: []const u8,
    next_start: usize,
};

/// Scans the next attribute name starting at `i`.
/// Returns null when the attribute list terminator is reached.
/// Returns an empty slice when the cursor is advanced past a non-name byte.
pub fn scanAttrNameOrSkip(source: []const u8, end: usize, i: *usize) ?[]const u8 {
    const c = source[i.*];
    if (c == '>' or c == '/') return null;

    const name_start = i.*;
    while (i.* < end and tables.IdentCharTable[source[i.*]]) : (i.* += 1) {}
    if (i.* == name_start) {
        i.* += 1;
        return "";
    }
    return source[name_start..i.*];
}

/// Parses raw attribute value span for in-place attribute traversal.
pub fn parseRawValue(source: []const u8, span_end: usize, eq_index: usize) RawValue {
    var i = eq_index + 1;
    while (i < span_end and tables.WhitespaceTable[source[i]]) : (i += 1) {}

    if (i >= span_end) {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = i };
    }

    const c = source[i];
    if (c == '>' or c == '/') {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = i };
    }

    if (c == 0x27 or c == '"') {
        const j = scanner.findByte(source, i + 1, c) orelse span_end;
        const next_start = if (j < span_end) j + 1 else span_end;
        return .{ .kind = .quoted, .start = i + 1, .end = j, .next_start = next_start };
    }

    var j = i;
    while (j < span_end) : (j += 1) {
        const b = source[j];
        if (b == '>' or b == '/' or tables.WhitespaceTable[b]) break;
    }

    if (j == i) {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = j };
    }

    return .{ .kind = .naked, .start = i, .end = j, .next_start = j };
}

/// Parses parsed in-place attribute value span (after name delimiter).
pub fn parseParsedValue(source: []u8, span_end: usize, name_end: usize) ParsedValue {
    if (name_end + 1 >= span_end) return .{ .value = "", .next_start = span_end };

    const marker = source[name_end + 1];
    var value_start: usize = if (marker == 0) name_end + 2 else name_end + 1;
    if (value_start > span_end) value_start = span_end;

    const value_end = findValueEnd(source, value_start, span_end);
    const next = nextAfterValue(source, value_end, span_end);
    return .{ .value = source[value_start..value_end], .next_start = next };
}

pub fn findValueEnd(source: []const u8, value_start: usize, span_end: usize) usize {
    var i = value_start;
    while (i < span_end and source[i] != 0) : (i += 1) {}
    return i;
}

pub fn nextAfterValue(source: []const u8, value_end: usize, span_end: usize) usize {
    if (value_end >= span_end) return span_end;
    var i = value_end + 1;
    if (i >= span_end) return span_end;

    if (source[i] == 0) {
        if (i + 1 >= span_end) return span_end;

        const len_byte = source[i + 1];
        if (len_byte == 0xff) {
            if (i + 6 > span_end) return span_end;
            const skip = std.mem.readInt(u32, source[i + 2 .. i + 6][0..4], nativeEndian());
            const next = i + 6 + @as(usize, @intCast(skip));
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
