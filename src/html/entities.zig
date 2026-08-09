// A lot of things use std's mem.eql which might use largest possible vector size which might not be optimal.
// Simd instructions heat cpu more; ones with larger data size heat up more; so it may be optimal to use lower data size.
// TODO: investigate this.
//
// other than that, attempts to optimize anything in here will likely fail.
const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const IndexInt = @import("../common.zig").IndexInt;
const tables = @import("tables.zig");
const scanner = @import("scanner.zig");
const named_entities = @import("../../bench/entity_lookup/generated/named_entities.zig");
const InvalidDigit = 0xff;
const ReplacementUtf8 = [3]u8{ 0xEF, 0xBF, 0xBD };
comptime {
    if (named_entities.MaxValueLen > 6) @compileError("Decoded.bytes is too small for the generated entity table");
}

pub const EntityDecoding = enum {
    minimal,
    common,
    full,
};

/// Result of decoding one HTML entity prefix.
pub const Decoded = struct {
    /// Number of source bytes consumed from the entity prefix.
    consumed: IndexInt,
    /// UTF-8 bytes produced by the decode.
    bytes: [6]u8,
    /// Number of valid bytes in `bytes`.
    len: u3,
    /// True only for a numeric reference whose codepoint is zero.
    numeric_null: bool = false,

    /// Formats this decoded entity result for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Decoded{{consumed={}, len={}, bytes={any}}}", .{
            self.consumed,
            self.len,
            self.bytes[0..self.len],
        });
    }
};

/// Result of an in-place decode attempt. `complete == false` means at least
/// one character reference would expand beyond its source bytes; the input is
/// left untouched so the caller can use an allocating fallback.
pub const InPlaceResult = struct {
    len: usize,
    complete: bool = true,
};

pub fn decodeInPlaceWithMode(comptime mode: EntityDecoding, comptime normalize_whitespace: bool, slice: []u8) usize {
    return decodeInPlaceResultWithMode(mode, normalize_whitespace, slice).len;
}

pub fn decodeInPlaceResultWithMode(comptime mode: EntityDecoding, comptime normalize_whitespace: bool, slice: []u8) InPlaceResult {
    if (expansionExtraWithMode(mode, false, slice) != 0) return .{ .len = slice.len, .complete = false };
    const first = scanner.findBytePosOrEnd(slice, 0, '&');
    if (first == slice.len) return .{ .len = if (comptime normalize_whitespace) normalizeWhitespaceInPlace(slice) else slice.len };
    return .{ .len = decodeInPlaceFromMode(mode, normalize_whitespace, slice, first) };
}

pub fn firstDecodableEntityWithMode(comptime mode: EntityDecoding, comptime attribute: bool, slice: []const u8, start: usize) ?usize {
    var i = start;
    while (true) {
        const amp = scanner.findBytePosOrEnd(slice, i, '&');
        if (amp == slice.len) return null;
        if (decodeEntityWithMode(mode, attribute, slice[amp + 1 ..]) != null) {
            @branchHint(.likely);
            return amp;
        } else {
            @branchHint(.cold);
            i = amp + 1;
        }
    }
    return null;
}

/// Total number of additional bytes needed when all decodable references are
/// expanded. Zero means the slice is safe for forward in-place decoding.
pub fn expansionExtraWithMode(comptime mode: EntityDecoding, comptime attribute: bool, slice: []const u8) usize {
    _ = attribute;
    if (comptime mode != .full) return 0;

    // In the WHATWG named-entity table only &nLt; and &nGt; produce more
    // bytes than they consume (six UTF-8 bytes from five source bytes).
    // Detect those two literals directly instead of running the full named
    // lookup for every ampersand before an in-place decode.
    var extra: usize = 0;
    var i: usize = 0;
    while (true) {
        const amp = scanner.findBytePosOrEnd(slice, i, '&');
        if (amp == slice.len) break;
        if (amp + 5 <= slice.len) {
            const candidate = slice[amp .. amp + 5];
            if (std.mem.eql(u8, candidate, "&nLt;") or std.mem.eql(u8, candidate, "&nGt;")) {
                extra += 1;
                i = amp + 5;
                continue;
            }
        }
        i = amp + 1;
    }
    return extra;
}

fn decodeInPlaceFromMode(comptime mode: EntityDecoding, comptime normalize_whitespace: bool, slice: []u8, first: usize) usize {
    std.debug.assert(first < slice.len);
    std.debug.assert(slice[first] == '&');
    std.debug.assert(expansionExtraWithMode(mode, false, slice) == 0);
    if (comptime normalize_whitespace) return decodeNormalizeInPlaceFrom(slice, first, mode);
    return decodePlainInPlaceFrom(slice, first, false, mode, false);
}

pub fn decodeAttributeInPlaceWithMode(comptime mode: EntityDecoding, slice: []u8, first: ?usize) usize {
    return decodeAttributeInPlaceResultWithMode(mode, slice, first).len;
}

pub fn decodeAttributeInPlaceResultWithMode(comptime mode: EntityDecoding, slice: []u8, first: ?usize) InPlaceResult {
    if (expansionExtraWithMode(mode, true, slice) != 0) return .{ .len = slice.len, .complete = false };
    const new_len = if (first orelse firstDecodableEntityWithMode(mode, true, slice, 0)) |amp|
        decodePlainInPlaceFrom(slice, amp, false, mode, true)
    else
        slice.len;
    for (slice[0..new_len]) |*c| {
        if (c.* == 0) c.* = ' ';
    }
    return .{ .len = new_len };
}

/// Allocating decode path used only when a reference can expand or the caller
/// already needs owned storage.
pub fn decodeAllocWithMode(comptime mode: EntityDecoding, comptime attribute: bool, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const extra = expansionExtraWithMode(mode, attribute, input);
    const capacity = try std.math.add(usize, input.len, extra);
    var out = try std.ArrayList(u8).initCapacity(allocator, capacity);
    errdefer out.deinit(allocator);

    appendDecodedAssumeCapacityWithMode(mode, attribute, &out, input);
    return try out.toOwnedSlice(allocator);
}

/// Appends a fully decoded slice to an ArrayList whose spare capacity is at
/// least `input.len + expansionExtraWithMode(...)`. This is the allocation-free
/// fallback used by callers which already own an output buffer.
pub fn appendDecodedAssumeCapacityWithMode(
    comptime mode: EntityDecoding,
    comptime attribute: bool,
    out: *std.ArrayList(u8),
    input: []const u8,
) void {
    std.debug.assert(out.capacity - out.items.len >= input.len + expansionExtraWithMode(mode, attribute, input));

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != '&') {
            if (comptime attribute) {
                out.appendAssumeCapacity(if (c == 0) ' ' else c);
            } else {
                out.appendAssumeCapacity(c);
            }
            i += 1;
            continue;
        }
        if (decodeEntityWithMode(mode, attribute, input[i + 1 ..])) |decoded| {
            out.appendSliceAssumeCapacity(decoded.bytes[0..decoded.len]);
            i += decoded.consumed;
        } else {
            out.appendAssumeCapacity('&');
            i += 1;
        }
    }
}

fn decodePlainInPlaceFrom(slice: []u8, first: usize, comptime null_as_space: bool, comptime mode: EntityDecoding, comptime attribute: bool) usize {
    var r: usize = first;
    var w: usize = first;

    while (true) {
        if (decodeEntityWithMode(mode, attribute, slice[r + 1 ..])) |decoded| {
            @branchHint(.likely);
            writeDecoded(slice, w, decoded, null_as_space);
            r += decoded.consumed;
            w += decodedLen(decoded, null_as_space);

            if (r != w) {
                @branchHint(.likely);
                break;
            }
        } else {
            r += 1;
            w += 1;
        }

        const next_amp = scanner.findBytePosOrEnd(slice, r, '&');
        if (next_amp == slice.len) return slice.len;
        r = next_amp;
        w = next_amp;
    }

    while (true) {
        const next_amp = scanner.findBytePosOrEnd(slice, r, '&');
        if (next_amp == slice.len) {
            std.mem.copyForwards(u8, slice[w .. w + (slice.len - r)], slice[r..]);
            return w + (slice.len - r);
        }
        const chunk_len = next_amp - r;
        if (chunk_len != 0) {
            std.mem.copyForwards(u8, slice[w .. w + chunk_len], slice[r..next_amp]);
            w += chunk_len;
        }

        r = next_amp;
        if (decodeEntityWithMode(mode, attribute, slice[r + 1 ..])) |decoded| {
            writeDecoded(slice, w, decoded, null_as_space);
            r += decoded.consumed;
            w += decodedLen(decoded, null_as_space);
        } else {
            slice[w] = '&';
            r += 1;
            w += 1;
        }
    }
}

inline fn decodedLen(decoded: Decoded, comptime null_as_space: bool) usize {
    return if (comptime null_as_space) if (decoded.numeric_null) 1 else decoded.len else decoded.len;
}

inline fn writeDecoded(out: []u8, start: usize, decoded: Decoded, comptime null_as_space: bool) void {
    if (comptime null_as_space) {
        if (decoded.numeric_null) {
            out[start] = ' ';
            return;
        }
    }
    @memcpy(out[start..][0..decoded.len], decoded.bytes[0..decoded.len]);
}

/// Collapses HTML whitespace in-place and returns the new length.
pub fn normalizeWhitespaceInPlace(bytes: []u8) usize {
    var state: WhitespaceState = .{};
    var w: usize = 0;
    var r: usize = 0;
    while (r < bytes.len) : (r += 1) appendNormalizedByte(bytes, &w, &state, bytes[r]);
    return w;
}

const WhitespaceState = struct {
    pending_space: bool = false,
    wrote_any: bool = false,
};

fn decodeNormalizeInPlaceFrom(bytes: []u8, first: usize, comptime mode: EntityDecoding) usize {
    var state: WhitespaceState = .{};
    var r: usize = first;
    var w: usize = 0;

    appendNormalizedBytes(bytes, &w, &state, bytes[0..first]);

    while (r < bytes.len) {
        const c = bytes[r];
        if (c != '&') {
            appendNormalizedByte(bytes, &w, &state, c);
            r += 1;
            continue;
        }

        if (decodeEntityWithMode(mode, false, bytes[r + 1 ..])) |decoded| {
            appendNormalizedBytes(bytes, &w, &state, decoded.bytes[0..decoded.len]);
            r += decoded.consumed;
        } else {
            appendNormalizedByte(bytes, &w, &state, '&');
            r += 1;
        }
    }

    return w;
}

fn appendNormalizedBytes(out: []u8, noalias w: *usize, noalias state: *WhitespaceState, bytes: []const u8) void {
    for (bytes) |c| appendNormalizedByte(out, w, state, c);
}

fn appendNormalizedByte(out: []u8, noalias w: *usize, noalias state: *WhitespaceState, c: u8) void {
    if (tables.WhitespaceTable[c]) {
        state.pending_space = true;
        return;
    }

    if (state.pending_space and state.wrote_any) {
        out[w.*] = ' ';
        w.* += 1;
    }
    out[w.*] = c;
    w.* += 1;
    state.pending_space = false;
    state.wrote_any = true;
}

fn decodeReferenceAlloc(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(alloc, input[i]);
            i += 1;
            continue;
        }

        if (i + 1 >= input.len) {
            try out.append(alloc, '&');
            break;
        }

        if (decodeEntityWithMode(.common, false, input[i + 1 ..])) |decoded| {
            try out.appendSlice(alloc, decoded.bytes[0..decoded.len]);
            i += decoded.consumed;
            continue;
        }

        try out.append(alloc, '&');
        i += 1;
    }

    return try out.toOwnedSlice(alloc);
}

pub fn decodeEntityWithMode(comptime mode: EntityDecoding, comptime attribute: bool, rem: []const u8) ?Decoded {
    if (rem.len < 2) return null;

    if (rem[0] == '#') return switch (rem[1]) {
        'x', 'X' => parseNumericHex(rem[2..]),
        else => parseNumericDecimal(rem[1..]),
    };

    if (comptime mode == .full) {
        if (named_entities.longestPrefix(rem, attribute)) |named| {
            var out: [6]u8 = undefined;
            @memcpy(out[0..named.value.len], named.value);
            return .{ .consumed = named.consumed, .bytes = out, .len = @intCast(named.value.len) };
        }
        return null;
    }
    return switch (rem[0]) {
        'a' => matchNamedLiteral(attribute, rem, "amp", "&", true) orelse
            matchNamedLiteral(attribute, rem, "apos", "'", false),
        'A' => matchNamedLiteral(attribute, rem, "AMP", "&", true),
        'l' => matchNamedLiteral(attribute, rem, "lt", "<", true),
        'L' => matchNamedLiteral(attribute, rem, "LT", "<", true),
        'g' => matchNamedLiteral(attribute, rem, "gt", ">", true),
        'G' => matchNamedLiteral(attribute, rem, "GT", ">", true),
        'q' => matchNamedLiteral(attribute, rem, "quot", "\"", true),
        'Q' => matchNamedLiteral(attribute, rem, "QUOT", "\"", true),
        'n' => if (comptime mode == .common)
            matchNamedLiteral(attribute, rem, "nbsp", "\xc2\xa0", true) orelse
                matchNamedLiteral(attribute, rem, "ndash", "\xe2\x80\x93", false)
        else
            null,
        'c' => if (comptime mode == .common) matchNamedLiteral(attribute, rem, "copy", "\xc2\xa9", true) else null,
        'C' => if (comptime mode == .common) matchNamedLiteral(attribute, rem, "COPY", "\xc2\xa9", true) else null,
        'r' => if (comptime mode == .common) matchNamedLiteral(attribute, rem, "reg", "\xc2\xae", true) else null,
        'R' => if (comptime mode == .common) matchNamedLiteral(attribute, rem, "REG", "\xc2\xae", true) else null,
        'm' => if (comptime mode == .common) matchNamedLiteral(attribute, rem, "mdash", "\xe2\x80\x94", false) else null,
        'h' => if (comptime mode == .common) matchNamedLiteral(attribute, rem, "hellip", "\xe2\x80\xa6", false) else null,
        else => null,
    };
}

/// Matches one hardcoded named reference. The basic legacy names plus nbsp/copy/reg
/// have no-semicolon spellings in the WHATWG table. In attributes those
/// legacy spellings are not references when followed by ASCII alphanumeric or `=`.
fn matchNamedLiteral(
    comptime attribute: bool,
    rem: []const u8,
    comptime name: []const u8,
    comptime value: []const u8,
    comptime legacy_no_semicolon: bool,
) ?Decoded {
    if (!std.mem.startsWith(u8, rem, name)) return null;
    if (rem.len > name.len and rem[name.len] == ';') return bytesDecoded(name.len + 2, value);
    if (comptime !legacy_no_semicolon) return null;
    if (comptime attribute) {
        if (rem.len > name.len) {
            const next = rem[name.len];
            const ascii_alnum = (next >= '0' and next <= '9') or
                (next >= 'A' and next <= 'Z') or
                (next >= 'a' and next <= 'z');
            if (next == '=' or ascii_alnum) return null;
        }
    }
    return bytesDecoded(name.len + 1, value);
}

fn bytesDecoded(consumed: usize, value: []const u8) Decoded {
    var out: [6]u8 = undefined;
    @memcpy(out[0..value.len], value);
    return .{ .consumed = @intCast(consumed), .bytes = out, .len = @intCast(value.len) };
}

fn replacementDecoded(consumed: usize) Decoded {
    return .{
        .consumed = @intCast(consumed),
        .bytes = .{ ReplacementUtf8[0], ReplacementUtf8[1], ReplacementUtf8[2], undefined, undefined, undefined },
        .len = 3,
    };
}

const NumericDigitTable = blk: {
    var table = [_]u8{InvalidDigit} ** 256;
    var c: u8 = '0';
    while (c <= '9') : (c += 1) table[c] = c - '0';
    c = 'a';
    while (c <= 'f') : (c += 1) table[c] = 10 + (c - 'a');
    c = 'A';
    while (c <= 'F') : (c += 1) table[c] = 10 + (c - 'A');
    break :blk table;
};

fn parseNumericDecimal(rem: []const u8) ?Decoded {
    var i: usize = 0;
    var value: u32 = 0;
    var too_large = false;
    while (i < rem.len and NumericDigitTable[rem[i]] <= 9) : (i += 1) {
        if (!too_large) {
            const digit: u32 = NumericDigitTable[rem[i]];
            if (value > (0x10ffff - digit) / 10) {
                too_large = true;
            } else {
                value = value * 10 + digit;
            }
        }
    }
    if (i == 0) return null;
    const has_semicolon = i < rem.len and rem[i] == ';';
    const consumed = i + 2 + @intFromBool(has_semicolon);
    if (too_large) return replacementDecoded(consumed);
    return finishNumeric(value, consumed);
}

fn parseNumericHex(rem: []const u8) ?Decoded {
    var i: usize = 0;
    var value: u32 = 0;
    var too_large = false;
    while (i < rem.len and NumericDigitTable[rem[i]] != InvalidDigit) : (i += 1) {
        if (!too_large) {
            const digit: u32 = NumericDigitTable[rem[i]];
            if (value > (0x10ffff - digit) / 16) {
                too_large = true;
            } else {
                value = value * 16 + digit;
            }
        }
    }
    if (i == 0) return null;
    const has_semicolon = i < rem.len and rem[i] == ';';
    const consumed = i + 3 + @intFromBool(has_semicolon);
    if (too_large) return replacementDecoded(consumed);
    return finishNumeric(value, consumed);
}

inline fn finishNumeric(input_value: u32, consumed: usize) Decoded {
    if (input_value == 0) return numericNullDecoded(consumed);
    const value = legacyNumericCodepoint(input_value);
    if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return replacementDecoded(consumed);

    var encoded: [4]u8 = undefined;
    const codepoint: u21 = @intCast(value);
    const len = std.unicode.utf8Encode(codepoint, &encoded) catch return replacementDecoded(consumed);
    var out: [6]u8 = undefined;
    @memcpy(out[0..len], encoded[0..len]);
    return .{ .consumed = @intCast(consumed), .bytes = out, .len = len };
}

fn legacyNumericCodepoint(value: u32) u32 {
    return switch (value) {
        0x80 => 0x20ac,
        0x82 => 0x201a,
        0x83 => 0x0192,
        0x84 => 0x201e,
        0x85 => 0x2026,
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02c6,
        0x89 => 0x2030,
        0x8a => 0x0160,
        0x8b => 0x2039,
        0x8c => 0x0152,
        0x8e => 0x017d,
        0x91 => 0x2018,
        0x92 => 0x2019,
        0x93 => 0x201c,
        0x94 => 0x201d,
        0x95 => 0x2022,
        0x96 => 0x2013,
        0x97 => 0x2014,
        0x98 => 0x02dc,
        0x99 => 0x2122,
        0x9a => 0x0161,
        0x9b => 0x203a,
        0x9c => 0x0153,
        0x9e => 0x017e,
        0x9f => 0x0178,
        else => value,
    };
}

inline fn numericNullDecoded(consumed: usize) Decoded {
    var decoded = replacementDecoded(consumed);
    decoded.numeric_null = true;
    return decoded;
}

// ---
// Testing
// ---

fn fillInterestingEntityBytes(random: std.Random, out: []u8) void {
    for (out) |*b| {
        b.* = interestingEntityByte(
            @intCast(random.uintLessThan(u5, 16)),
            random.uintLessThan(u8, 10),
            random.uintLessThan(u8, 26),
            random.uintLessThan(u8, 26),
            random.int(u8),
        );
    }
}

fn fillInterestingEntityBytesSmith(smith: *std.testing.Smith, out: []u8) void {
    for (out) |*b| {
        b.* = interestingEntityByte(
            smith.value(u4),
            smith.valueRangeAtMost(u8, 0, 9),
            smith.valueRangeAtMost(u8, 0, 25),
            smith.valueRangeAtMost(u8, 0, 25),
            smith.value(u8),
        );
    }
}

fn interestingEntityByte(choice: u4, digit: u8, lower: u8, upper: u8, other: u8) u8 {
    return switch (choice) {
        0 => '&',
        1 => ';',
        2 => '#',
        3 => 'x',
        4 => 'X',
        5 => '<',
        6 => '>',
        7 => '\'',
        8 => '"',
        9 => ' ',
        10 => '\n',
        11 => '0' + digit,
        12 => 'a' + lower,
        13 => 'A' + upper,
        else => other,
    };
}

fn expectDecodeMatchesReference(alloc: std.mem.Allocator, input: []const u8) !void {
    const expected = try decodeReferenceAlloc(alloc, input);
    defer alloc.free(expected);

    const buf = try alloc.dupe(u8, input);
    defer alloc.free(buf);

    const actual_len = decodeInPlaceWithMode(.common, false, buf);
    try std.testing.expect(actual_len <= buf.len);
    try std.testing.expectEqualSlices(u8, expected, buf[0..actual_len]);
}

test "decode entities" {
    var buf = "a&amp;b&#x20;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("a&b ", buf[0..n]);
}

test "decode entities preserves literal run after shrinking first entity" {
    var buf = "a&amp;bc&amp;d".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("a&bc&d", buf[0..n]);
}

test "decode from first decodable entity skips invalid ampersands" {
    var buf = "a&bogus&amp;b".*;
    const first = firstDecodableEntityWithMode(.common, false, &buf, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 7), first);
    const n = decodeInPlaceFromMode(.common, false, &buf, first);
    try std.testing.expectEqualStrings("a&bogus&b", buf[0..n]);
}

test "decode and normalize whitespace in one pass" {
    var buf = "  a\t&amp;\n b  ".*;
    const n = decodeInPlaceWithMode(.common, true, &buf);
    try std.testing.expectEqualStrings("a & b", buf[0..n]);
}

test "decode from first entity and normalize earlier literal text" {
    var buf = " a&bogus  &amp;\n b ".*;
    const first = firstDecodableEntityWithMode(.common, false, &buf, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 10), first);
    const n = decodeInPlaceFromMode(.common, true, &buf, first);
    try std.testing.expectEqualStrings("a&bogus & b", buf[0..n]);
}

test "decode decimal and uppercase hex entities" {
    var buf = "&#32;&#X3E;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings(" >", buf[0..n]);
}

test "decode two-byte numeric entity" {
    var buf = "a&#169;b".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("a\xc2\xa9b", buf[0..n]);
}

test "decode numeric entities allows leading zeros and rejects oversized values" {
    var buf = "&#0000032;&#x00003E;&#1114112;&#x110000;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualSlices(u8, " >" ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode oversized numeric entities beyond fast digit windows" {
    var buf = "&#123456789;&#1234567890;&#x12345678;&#x123456789;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualSlices(
        u8,
        &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8,
        buf[0..n],
    );
}

test "decode numeric entities rejects missing digits" {
    var buf = "&#;&#x;&#X;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("&#;&#x;&#X;", buf[0..n]);
}

test "decode numeric entities accepts a missing semicolon and remaps C1 controls" {
    var buf = "&#65 &#x41 &#128;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("A A \xe2\x82\xac", buf[0..n]);
}

test "decode numeric entities rejects null codepoint" {
    var buf = "&#0;&#00;&#x0;&#X000;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "attribute decoding replaces numeric nulls and literal nulls" {
    var buf = "a&#0;b&#x00;c\x00d&amp;e".*;
    const n = decodeAttributeInPlaceWithMode(.common, &buf, null);
    try std.testing.expectEqualSlices(u8, "a" ++ &ReplacementUtf8 ++ "b" ++ &ReplacementUtf8 ++ "c d&e", buf[0..n]);
}

test "decode numeric entities rejects surrogate codepoints" {
    var buf = "&#55296;&#57343;&#xD800;&#xDFFF;&#xd800;&#xdfff;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualSlices(
        u8,
        &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8,
        buf[0..n],
    );
}

test "decodeInPlace randomized reference sweep" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x8f45_53f2_3be9_19d1);
    const random = prng.random();

    var case_idx: usize = 0;
    while (case_idx < 1024) : (case_idx += 1) {
        const len = random.intRangeLessThan(usize, 0, 129);
        const input = try alloc.alloc(u8, len);
        defer alloc.free(input);
        fillInterestingEntityBytes(random, input);
        try expectDecodeMatchesReference(alloc, input);
    }
}

fn fuzzDecodeMatchesReference(alloc: std.mem.Allocator, smith: *std.testing.Smith) !void {
    const len = smith.value(u8);
    const input = try alloc.alloc(u8, len);
    defer alloc.free(input);
    fillInterestingEntityBytesSmith(smith, input);
    try expectDecodeMatchesReference(alloc, input);
}

test "fuzz decodeInPlace matches reference decoder" {
    try std.testing.fuzz(std.testing.allocator, fuzzDecodeMatchesReference, .{ .corpus = &.{
        "",
        "&",
        "plain text",
        "&&&&",
        "&amp;",
        "&lt;&gt;&quot;&apos;",
        "&#32;&#x3e;&#X3E;",
        "&#;&#x;&#0;&#x0;",
        "&#xD800;&#xDFFF;&#55296;&#57343;",
        "&#1114112;&#x110000;",
        "<div data-x='&amp;&#32;'>&#x3c;</div>",
        "unterminated &amp and &#123 and &#xabc",
    } });
}

test "decode entities keeps plain text unchanged" {
    var buf = "plain text".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("plain text", buf[0..n]);
}

test "legacy named references without semicolons follow text and attribute rules" {
    var text = "&amp &lt &gt &quot &nbsp &copy &reg &apos".*;
    const text_len = decodeInPlaceWithMode(.common, false, &text);
    try std.testing.expectEqualStrings("& < > \" \xc2\xa0 \xc2\xa9 \xc2\xae &apos", text[0..text_len]);

    var attribute = "&ampx &amp= &amp! &copycat &copy!".*;
    const attr_len = decodeAttributeInPlaceWithMode(.common, &attribute, null);
    try std.testing.expectEqualStrings("&ampx &amp= &! &copycat \xc2\xa9!", attribute[0..attr_len]);
}

test "fast entity modes include canonical uppercase legacy aliases" {
    var minimal = "&AMP;&LT;&GT;&QUOT; &AMP &LT &GT &QUOT".*;
    const minimal_len = decodeInPlaceWithMode(.minimal, false, &minimal);
    try std.testing.expectEqualStrings("&<>\" & < > \"", minimal[0..minimal_len]);

    var common = "&COPY;&REG; &COPY &REG".*;
    const common_len = decodeInPlaceWithMode(.common, false, &common);
    try std.testing.expectEqualStrings("\xc2\xa9\xc2\xae \xc2\xa9 \xc2\xae", common[0..common_len]);

    var attribute = "&AMPx &AMP= &AMP! &COPYcat &COPY!".*;
    const attr_len = decodeAttributeInPlaceWithMode(.common, &attribute, null);
    try std.testing.expectEqualStrings("&AMPx &AMP= &! &COPYcat \xc2\xa9!", attribute[0..attr_len]);
}

test "common named entities decode without full table" {
    var buf = "&nbsp;&copy;&reg;&mdash;&ndash;&hellip;".*;
    const n = decodeInPlaceWithMode(.common, false, &buf);
    try std.testing.expectEqualStrings("\xc2\xa0\xc2\xa9\xc2\xae\xe2\x80\x94\xe2\x80\x93\xe2\x80\xa6", buf[0..n]);
}

test "minimal entity mode excludes optional common names" {
    var buf = "&amp;&nbsp;&copy;".*;
    const n = decodeInPlaceWithMode(.minimal, false, &buf);
    try std.testing.expectEqualStrings("&&nbsp;&copy;", buf[0..n]);
}

test "full named entity mode decodes uncommon and two-codepoint values" {
    var buf = "&eacute; &NotNestedGreaterGreater;".*;
    const n = decodeInPlaceWithMode(.full, false, &buf);
    try std.testing.expectEqualStrings("\xc3\xa9 \xe2\xaa\xa2\xcc\xb8", buf[0..n]);
}

test "full expansion preflight recognizes exactly the expanding literals" {
    try std.testing.expectEqual(@as(usize, 2), expansionExtraWithMode(.full, false, "a&nLt;b&nGt;c"));
    try std.testing.expectEqual(@as(usize, 0), expansionExtraWithMode(.full, false, "&nLtv;&NotNestedGreaterGreater;&amp;"));
    try std.testing.expectEqual(@as(usize, 0), expansionExtraWithMode(.common, false, "&nLt;&nGt;"));
}

test "expanding full entities reject in-place decode transactionally" {
    var buf = "x&nLt;y".*;
    const before = buf;
    const result = decodeInPlaceResultWithMode(.full, false, &buf);
    try std.testing.expect(!result.complete);
    try std.testing.expectEqual(before.len, result.len);
    try std.testing.expectEqualSlices(u8, &before, &buf);

    const decoded = try decodeAllocWithMode(.full, false, std.testing.allocator, &buf);
    defer std.testing.allocator.free(decoded);
    try std.testing.expect(decoded.len > buf.len);
}

test "format decoded entity" {
    const alloc = std.testing.allocator;
    const decoded: Decoded = .{
        .consumed = 3,
        .bytes = .{ 1, 2, 3, 4, 5, 6 },
        .len = 2,
    };
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{decoded});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("Decoded{consumed=3, len=2, bytes={ 1, 2 }}", rendered);
}
