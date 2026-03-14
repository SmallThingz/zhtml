const std = @import("std");
const tables = @import("tables.zig");
const attr_scan = @import("attr_scan.zig");
const entities = @import("entities.zig");
const scanner = @import("scanner.zig");

// SAFETY: This module mutates `doc.source` in-place for attribute decoding.
// Invariants:
// - `node.attr_end` and `node.name_or_text.end` are within `doc.source.len`.
// - Attribute spans passed to helpers are bounded by `span_end`.
// - Callers uphold that `source` is the document buffer for the node.

const RawValue = attr_scan.RawValue;

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
    const source: []u8 = mut_doc.source;
    const lookup_kind = classifyLookupName(name);
    const lookup_hash = if (lookup_kind == .generic) tables.hashIgnoreCaseAscii(name) else 0;

    var i: usize = node.name_or_text.end;
    const end: usize = @intCast(node.attr_end);
    if (i >= end) return null;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) return null;

        const c = source[i];
        if (c == '>' or c == '/') return null;

        const name_start = i;
        var attr_name_hash: u32 = tables.FnvOffset;
        while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {
            if (lookup_kind == .generic) {
                attr_name_hash = tables.hashIgnoreCaseAsciiUpdate(attr_name_hash, source[i]);
            }
        }
        if (i == name_start) {
            i += 1;
            continue;
        }

        const name_end = i;
        const attr_name = source[name_start..name_end];
        const is_target = matchesLookupNameHashed(attr_name, attr_name_hash, name, lookup_kind, lookup_hash);

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
    const source: []u8 = mut_doc.source;
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

        const name_slice = attr_scan.scanAttrNameOrSkip(source, end, &i) orelse break;
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

/// Hash-assisted multi-attribute collector variant for selector matching.
pub fn collectSelectedValuesByHash(
    noalias doc_ptr: anytype,
    node: anytype,
    selected_names: []const []const u8,
    selected_hashes: []const u32,
    out_values: []?[]const u8,
) void {
    const mut_doc = @constCast(doc_ptr);
    const source: []u8 = mut_doc.source;
    if (selected_names.len == 0) return;
    if (selected_names.len != out_values.len or selected_names.len != selected_hashes.len) return;

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

        const c = source[i];
        if (c == '>' or c == '/') break;

        const name_start = i;
        var name_hash: u32 = tables.FnvOffset;
        while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {
            name_hash = tables.hashIgnoreCaseAsciiUpdate(name_hash, source[i]);
        }
        if (i == name_start) {
            i += 1;
            continue;
        }

        const name_slice = source[name_start..i];
        const selected_idx = firstUnresolvedMatchByHash(
            selected_names,
            selected_hashes,
            out_values,
            name_slice,
            name_hash,
        );

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
    // - extended skip metadata: 0x00, 0xFF, u32 len
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

    if (gap_len >= 6) {
        source[gap_start] = 0;
        source[gap_start + 1] = 0xff;
        const skip: u32 = @intCast(gap_len - 6);
        std.mem.writeInt(u32, source[gap_start + 2 .. gap_start + 6][0..4], skip, attr_scan.nativeEndian());
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
    const name = attr_scan.scanAttrNameOrSkip(&buf, span_end, &i) orelse return error.MissingAttr;
    try testing.expectEqualStrings("b", name);
}

fn firstUnresolvedMatch(selected_names: []const []const u8, out_values: []const ?[]const u8, name: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (matchesLookupName(name, selected_names[idx], .generic, tables.hashIgnoreCaseAscii(selected_names[idx]))) return idx;
    }
    return null;
}

fn firstUnresolvedMatchByHash(
    selected_names: []const []const u8,
    selected_hashes: []const u32,
    out_values: []const ?[]const u8,
    name: []const u8,
    name_hash: u32,
) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (selected_hashes[idx] != name_hash) continue;
        if (matchesLookupNameHashed(name, name_hash, selected_names[idx], .generic, selected_hashes[idx])) return idx;
    }
    return null;
}

fn matchesLookupName(attr_name: []const u8, lookup: []const u8, lookup_kind: LookupKind, lookup_hash: u32) bool {
    const attr_hash = if (lookup_kind == .generic) tables.hashIgnoreCaseAscii(attr_name) else 0;
    return matchesLookupNameHashed(attr_name, attr_hash, lookup, lookup_kind, lookup_hash);
}

fn matchesLookupNameHashed(attr_name: []const u8, attr_hash: u32, lookup: []const u8, lookup_kind: LookupKind, lookup_hash: u32) bool {
    switch (lookup_kind) {
        .id => return isExactAsciiWord(attr_name, "id"),
        .class => return isExactAsciiWord(attr_name, "class"),
        .href => return isExactAsciiWord(attr_name, "href"),
        .generic => {},
    }

    if (attr_name.len != lookup.len) return false;
    if (attr_name.len != 0 and toLowerAscii(attr_name[0]) != toLowerAscii(lookup[0])) return false;
    if (attr_hash != lookup_hash) return false;
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
