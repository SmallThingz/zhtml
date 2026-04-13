const std = @import("std");
const tables = @import("tables.zig");
const attr_scan = @import("attr_scan.zig");
const entities = @import("entities.zig");
const scanner = @import("scanner.zig");
const common = @import("../common.zig");

// SAFETY: Destructive mode mutates `doc.mutable_source` in place for attribute
// decoding. Non-destructive mode scans `doc.source` read-only and allocates only
// when a decoded value cannot be represented as a direct source slice.

const RawValue = attr_scan.RawValue;
const IndexInt = common.IndexInt;
const ExtendedGapSentinel = 0xff;
const ExtendedGapHeaderLen = 2 + @sizeOf(IndexInt);

const LookupKind = enum(u8) {
    generic,
    id,
    class,
    href,
};

// Attribute traversal and value materialization are intentionally in-place.
// Wire states after name parsing:
// - `name=...` raw value, lazily materialized on first read
// - `name\0...` parsed value (with marker layout handled by parseParsedValue)
// - `name` + delimiter/end -> boolean/name-only attribute
/// Returns attribute value by name from in-place attribute bytes, decoding lazily.
pub fn getAttrValue(noalias doc_ptr: anytype, node: anytype, name: []const u8) ?[]const u8 {
    const mut_doc = @constCast(doc_ptr);
    if (mut_doc.mutable_source == null) {
        return getAttrValueNonDestructive(mut_doc, node, name);
    }

    const source: []u8 = mut_doc.mutable_source.?;
    const lookup_kind = classifyLookupName(name);

    var i: usize = node.name_or_text.end;
    const end: usize = @intCast(node.attr_end);
    if (i >= end) return null;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) return null;

        const c = source[i];
        if (c == '>' or c == '/') return null;

        const name_start = i;
        while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {}
        if (i == name_start) {
            i += 1;
            continue;
        }

        const name_end = i;
        const attr_name = source[name_start..name_end];
        const is_target = matchesLookupName(attr_name, name, lookup_kind);

        if (i >= end) {
            if (is_target) return "";
            return null;
        }

        const delim = source[i];
        if (delim == '=') {
            const raw = attr_scan.parseRawValue(source, end, i);
            if (is_target) {
                return materializeRawValue(source, end, i, raw);
            }
            i = raw.next_start;
            continue;
        }

        if (delim == 0) {
            const parsed = attr_scan.parseParsedValue(source, end, i);
            if (is_target) return parsed.value;
            i = parsed.next_start;
            continue;
        }

        if (is_target) return "";

        if (delim == '>' or delim == '/') return null;

        if (tables.WhitespaceTable[delim]) {
            i += 1;
            continue;
        }

        i += 1;
    }

    return null;
}

/// One-pass multi-attribute collector used by matcher hot paths.
pub fn collectSelectedValues(noalias doc_ptr: anytype, node: anytype, selected_names: []const []const u8, out_values: []?[]const u8) void {
    const mut_doc = @constCast(doc_ptr);
    if (mut_doc.mutable_source == null) {
        var idx: usize = 0;
        while (idx < selected_names.len) : (idx += 1) {
            if (out_values[idx] != null) continue;
            out_values[idx] = getAttrValueNonDestructive(mut_doc, node, selected_names[idx]);
        }
        return;
    }

    const source: []u8 = mut_doc.mutable_source.?;
    if (selected_names.len == 0) return;
    if (selected_names.len != out_values.len) return;

    var i: usize = node.name_or_text.end;
    const end: usize = @intCast(node.attr_end);
    var remaining: usize = 0;
    for (out_values) |v| {
        if (v == null) remaining += 1;
    }
    if (remaining == 0) return;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) break;

        const scanned = attr_scan.scanAttrNameOrSkip(source, end, i);
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
            const raw = attr_scan.parseRawValue(source, end, eq_index);
            if (selected_idx) |idx| {
                out_values[idx] = materializeRawValue(source, end, eq_index, raw);
                const parsed = attr_scan.parseParsedValue(source, end, eq_index);
                i = parsed.next_start;
                remaining -= 1;
                if (remaining == 0) return;
            } else {
                i = raw.next_start;
            }
            continue;
        }

        if (delim == 0) {
            const parsed = attr_scan.parseParsedValue(source, end, i);
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

const ParsedValue = attr_scan.ParsedValue;

fn getAttrValueNonDestructive(doc: anytype, node: anytype, name: []const u8) ?[]const u8 {
    const source: []const u8 = doc.source;
    const lookup_kind = classifyLookupName(name);

    var i: usize = node.name_or_text.end;
    const end: usize = @intCast(node.attr_end);
    if (i >= end) return null;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) return null;

        const c = source[i];
        if (c == '>' or c == '/') return null;

        const scanned = attr_scan.scanAttrNameOrSkip(source, end, i);
        const attr_name = scanned.name orelse return null;
        i = scanned.next_start;
        if (attr_name.len == 0) continue;
        const is_target = matchesLookupName(attr_name, name, lookup_kind);

        if (i >= end) {
            if (is_target) return "";
            return null;
        }

        const delim = source[i];
        if (delim == '=') {
            const raw = attr_scan.parseRawValue(source, end, i);
            if (is_target) return materializeRawValueOwned(doc, source, raw);
            i = raw.next_start;
            continue;
        }

        if (is_target) return "";
        if (delim == '>' or delim == '/') return null;
        i += 1;
    }

    return null;
}

fn materializeRawValueOwned(doc: anytype, source: []const u8, raw: RawValue) []const u8 {
    if (raw.kind == .empty) return "";

    const slice = source[raw.start..raw.end];
    if (std.mem.indexOfScalar(u8, slice, '&') == null) return slice;

    const arena = doc.ensureDecodedValueArena();
    const alloc = arena.allocator();
    const copied = alloc.dupe(u8, slice) catch return slice;
    const new_len = entities.decodeInPlaceIfEntity(copied);
    return copied[0..new_len];
}

fn materializeRawValue(source: []u8, span_end: usize, eq_index: usize, raw: RawValue) []const u8 {
    std.debug.assert(span_end <= source.len);
    std.debug.assert(eq_index < span_end);
    std.debug.assert(raw.start <= raw.end and raw.end <= span_end);
    std.debug.assert(raw.next_start <= span_end);
    if (raw.kind == .empty) {
        // Canonical rewrite for explicit empty assignment: `a=` -> `a `.
        source[eq_index] = ' ';
        return "";
    }

    var decoded_len: usize = raw.end - raw.start;
    decoded_len = entities.decodeInPlaceIfEntity(source[raw.start..raw.end]);

    if (raw.kind == .quoted) {
        // Quoted values use a double-NUL marker so traversal can distinguish
        // this family and preserve skip metadata correctness after shifts.
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

fn patchGap(source: []u8, span_end: usize, value_end: usize, raw_next_start: usize) void {
    // Any removed bytes are encoded as:
    // - single-space for tiny gaps
    // - short skip metadata: 0x00, len
    // - extended skip metadata: 0x00, 0xFF, IndexInt len
    // This keeps traversal O(n) without reparsing shifted tails.
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

    if (gap_len >= ExtendedGapHeaderLen) {
        source[gap_start] = 0;
        source[gap_start + 1] = ExtendedGapSentinel;
        const skip: IndexInt = @intCast(gap_len - ExtendedGapHeaderLen);
        std.mem.writeInt(IndexInt, source[gap_start + 2 .. gap_start + ExtendedGapHeaderLen][0..@sizeOf(IndexInt)], skip, attr_scan.nativeEndian());
        return;
    }

    source[gap_start] = ' ';
}

test "materializeRawValue preserves traversal for following attrs" {
    const testing = std.testing;

    var buf = "a=\"x\" b=\"y\"".*;
    const span_end = buf.len;
    const eq_index = std.mem.indexOfScalar(u8, &buf, '=') orelse return error.MissingEq;
    const raw = attr_scan.parseRawValue(&buf, span_end, eq_index);
    const value = materializeRawValue(buf[0..], span_end, eq_index, raw);
    try testing.expectEqualStrings("x", value);

    const parsed = attr_scan.parseParsedValue(buf[0..], span_end, eq_index);
    try testing.expectEqualStrings("x", parsed.value);

    var i = parsed.next_start;
    while (i < span_end and tables.WhitespaceTable[buf[i]]) : (i += 1) {}
    const scanned = attr_scan.scanAttrNameOrSkip(&buf, span_end, i);
    const name = scanned.name orelse return error.MissingAttr;
    i = scanned.next_start;
    try testing.expectEqualStrings("b", name);
}

fn firstUnresolvedMatch(selected_names: []const []const u8, out_values: []const ?[]const u8, name: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (matchesLookupName(name, selected_names[idx], .generic)) return idx;
    }
    return null;
}

fn matchesLookupName(attr_name: []const u8, lookup: []const u8, lookup_kind: LookupKind) bool {
    switch (lookup_kind) {
        .id => return isExactAsciiWord(attr_name, "id"),
        .class => return isExactAsciiWord(attr_name, "class"),
        .href => return isExactAsciiWord(attr_name, "href"),
        .generic => {},
    }

    if (attr_name.len != lookup.len) return false;
    if (attr_name.len != 0 and toLowerAscii(attr_name[0]) != toLowerAscii(lookup[0])) return false;
    return tables.eqlIgnoreCaseAscii(attr_name, lookup);
}

fn classifyLookupName(lookup: []const u8) LookupKind {
    if (isExactAsciiWord(lookup, "id")) return .id;
    if (isExactAsciiWord(lookup, "class")) return .class;
    if (isExactAsciiWord(lookup, "href")) return .href;
    return .generic;
}

fn isExactAsciiWord(value: []const u8, comptime lower: []const u8) bool {
    if (value.len != lower.len) return false;
    var i: usize = 0;
    while (i < lower.len) : (i += 1) {
        if (toLowerAscii(value[i]) != lower[i]) return false;
    }
    return true;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}
