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
const named_entities = @import("named_entities.zig");
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

/// Decodes entities in-place over entire slice and returns new length.
pub fn decodeInPlace(comptime normalize_whitespace: bool, slice: []u8) usize {
    return decodeInPlaceWithMode(.common, normalize_whitespace, slice);
}

pub fn decodeInPlaceFull(comptime normalize_whitespace: bool, slice: []u8) usize {
    return decodeInPlaceWithMode(.full, normalize_whitespace, slice);
}

pub fn decodeInPlaceWithMode(comptime mode: EntityDecoding, comptime normalize_whitespace: bool, slice: []u8) usize {
    const first = std.mem.indexOfScalar(u8, slice, '&') orelse {
        return if (comptime normalize_whitespace) normalizeWhitespaceInPlace(slice) else slice.len;
    };
    return decodeInPlaceFromMode(mode, normalize_whitespace, slice, first);
}

/// Returns the first `&` offset that begins a decodable entity.
pub fn firstDecodableEntity(slice: []const u8, start: usize) ?usize {
    return firstDecodableEntityWithMode(.common, false, slice, start);
}

pub fn firstDecodableEntityFull(comptime attribute: bool, slice: []const u8, start: usize) ?usize {
    return firstDecodableEntityWithMode(.full, attribute, slice, start);
}

pub fn firstDecodableEntityWithMode(comptime mode: EntityDecoding, comptime attribute: bool, slice: []const u8, start: usize) ?usize {
    var i = start;
    while (std.mem.indexOfScalarPos(u8, slice, i, '&')) |amp| {
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

/// Decodes entities in-place starting at a known `&` offset.
pub fn decodeInPlaceFrom(comptime normalize_whitespace: bool, slice: []u8, first: usize) usize {
    return decodeInPlaceFromMode(.common, normalize_whitespace, slice, first);
}

fn decodeInPlaceFromMode(comptime mode: EntityDecoding, comptime normalize_whitespace: bool, slice: []u8, first: usize) usize {
    std.debug.assert(first < slice.len);
    std.debug.assert(slice[first] == '&');
    if (comptime normalize_whitespace) return decodeNormalizeInPlaceFrom(slice, first, mode);
    return decodePlainInPlaceFrom(slice, first, false, mode, false);
}

/// Decodes an attribute value, replacing numeric references to codepoint zero
/// with U+FFFD and literal NUL bytes with ASCII spaces. `first` may be supplied by callers
/// that already searched for a decodable entity.
pub fn decodeAttributeInPlace(slice: []u8, first: ?usize) usize {
    return decodeAttributeInPlaceWithMode(.common, slice, first);
}

pub fn decodeAttributeInPlaceFull(slice: []u8, first: ?usize) usize {
    return decodeAttributeInPlaceWithMode(.full, slice, first);
}

pub fn decodeAttributeInPlaceWithMode(comptime mode: EntityDecoding, slice: []u8, first: ?usize) usize {
    const new_len = if (first orelse firstDecodableEntityWithMode(mode, true, slice, 0)) |amp|
        decodePlainInPlaceFrom(slice, amp, false, mode, true)
    else
        slice.len;
    for (slice[0..new_len]) |*c| {
        if (c.* == 0) c.* = ' ';
    }
    return new_len;
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

        const next_amp = std.mem.indexOfScalarPos(u8, slice, r, '&') orelse return slice.len;
        r = next_amp;
        w = next_amp;
    }

    while (true) {
        const next_amp = std.mem.indexOfScalarPos(u8, slice, r, '&') orelse {
            std.mem.copyForwards(u8, slice[w .. w + (slice.len - r)], slice[r..]);
            return w + (slice.len - r);
        };
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

        if (decodeEntity(input[i + 1 ..])) |decoded| {
            try out.appendSlice(alloc, decoded.bytes[0..decoded.len]);
            i += decoded.consumed;
            continue;
        }

        try out.append(alloc, '&');
        i += 1;
    }

    return try out.toOwnedSlice(alloc);
}

pub fn decodeEntity(rem: []const u8) ?Decoded {
    return decodeEntityWithMode(.common, false, rem);
}

pub fn decodeEntityFull(comptime attribute: bool, rem: []const u8) ?Decoded {
    return decodeEntityWithMode(.full, attribute, rem);
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
    if (rem.len < 3) return null;

    return switch (rem[0]) {
        'a' => if (rem.len >= 4 and rem[1] == 'm' and rem[2] == 'p' and rem[3] == ';')
            literalDecoded(5, '&')
        else if (rem.len >= 5 and rem[1] == 'p' and rem[2] == 'o' and rem[3] == 's' and rem[4] == ';')
            literalDecoded(6, '\'')
        else
            null,
        'l' => if (rem[1] == 't' and rem[2] == ';') literalDecoded(4, '<') else null,
        'g' => if (rem[1] == 't' and rem[2] == ';') literalDecoded(4, '>') else null,
        'q' => if (rem.len >= 5 and rem[1] == 'u' and rem[2] == 'o' and rem[3] == 't' and rem[4] == ';') literalDecoded(6, '"') else null,
        'n' => if (comptime mode == .common) if (std.mem.startsWith(u8, rem, "nbsp;")) bytesDecoded(6, "\xc2\xa0") else if (std.mem.startsWith(u8, rem, "ndash;")) bytesDecoded(7, "\xe2\x80\x93") else null else null,
        'c' => if (comptime mode == .common) if (std.mem.startsWith(u8, rem, "copy;")) bytesDecoded(6, "\xc2\xa9") else null else null,
        'r' => if (comptime mode == .common) if (std.mem.startsWith(u8, rem, "reg;")) bytesDecoded(5, "\xc2\xae") else null else null,
        'm' => if (comptime mode == .common) if (std.mem.startsWith(u8, rem, "mdash;")) bytesDecoded(7, "\xe2\x80\x94") else null else null,
        'h' => if (comptime mode == .common) if (std.mem.startsWith(u8, rem, "hellip;")) bytesDecoded(8, "\xe2\x80\xa6") else null else null,
        else => null,
    };
}

fn literalDecoded(consumed: usize, c: u8) Decoded {
    return .{
        .consumed = @intCast(consumed),
        .bytes = .{ c, undefined, undefined, undefined, undefined, undefined },
        .len = 1,
    };
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
    if (rem.len == 0) return null;

    var i: usize = 0;
    while (i < rem.len and rem[i] == '0') : (i += 1) {}

    const scan_end = @min(rem.len, i + 9);
    const semi_rel = std.mem.indexOfScalar(u8, rem[i..scan_end], ';') orelse return null;
    const semi = i + semi_rel;
    const consumed = semi + 3;
    if (semi_rel == 0) return if (i == 0) replacementDecoded(consumed) else numericNullDecoded(consumed);
    if (semi_rel > 7) return replacementDecoded(consumed);

    var value: u32 = 0;
    while (i < semi) : (i += 1) {
        const digit_u8 = NumericDigitTable[rem[i]];
        if (digit_u8 > 9) return replacementDecoded(consumed);
        value = value * 10 + digit_u8;
    }

    return finishNumeric(value, consumed);
}

fn parseNumericHex(rem: []const u8) ?Decoded {
    if (rem.len == 0) return null;

    var i: usize = 0;
    while (i < rem.len and rem[i] == '0') : (i += 1) {}

    const scan_end = @min(rem.len, i + 8);
    const semi_rel = std.mem.indexOfScalar(u8, rem[i..scan_end], ';') orelse return null;
    const semi = i + semi_rel;
    const consumed = semi + 4;
    if (semi_rel == 0) return if (i == 0) replacementDecoded(consumed) else numericNullDecoded(consumed);
    if (semi_rel > 6) return replacementDecoded(consumed);

    var value: u32 = 0;
    while (i < semi) : (i += 1) {
        const digit_u8 = NumericDigitTable[rem[i]];
        if (digit_u8 == InvalidDigit) return replacementDecoded(consumed);
        value = value * 16 + digit_u8;
    }

    return finishNumeric(value, consumed);
}

inline fn finishNumeric(value: u32, consumed: usize) Decoded {
    if (value == 0) return numericNullDecoded(consumed);
    var encoded: [4]u8 = undefined;
    const codepoint = std.math.cast(u21, value) orelse {
        @branchHint(.unlikely);
        return replacementDecoded(consumed);
    };
    const len = std.unicode.utf8Encode(codepoint, &encoded) catch {
        @branchHint(.unlikely);
        return replacementDecoded(consumed);
    };
    var out: [6]u8 = undefined;
    @memcpy(out[0..len], encoded[0..len]);
    return .{ .consumed = @intCast(consumed), .bytes = out, .len = len };
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

    const actual_len = decodeInPlace(false, buf);
    try std.testing.expect(actual_len <= buf.len);
    try std.testing.expectEqualSlices(u8, expected, buf[0..actual_len]);
}

test "decode entities" {
    var buf = "a&amp;b&#x20;".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualStrings("a&b ", buf[0..n]);
}

test "decode entities preserves literal run after shrinking first entity" {
    var buf = "a&amp;bc&amp;d".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualStrings("a&bc&d", buf[0..n]);
}

test "decode from first decodable entity skips invalid ampersands" {
    var buf = "a&bogus&amp;b".*;
    const first = firstDecodableEntity(&buf, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 7), first);
    const n = decodeInPlaceFrom(false, &buf, first);
    try std.testing.expectEqualStrings("a&bogus&b", buf[0..n]);
}

test "decode and normalize whitespace in one pass" {
    var buf = "  a\t&amp;\n b  ".*;
    const n = decodeInPlace(true, &buf);
    try std.testing.expectEqualStrings("a & b", buf[0..n]);
}

test "decode from first entity and normalize earlier literal text" {
    var buf = " a&bogus  &amp;\n b ".*;
    const first = firstDecodableEntity(&buf, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 10), first);
    const n = decodeInPlaceFrom(true, &buf, first);
    try std.testing.expectEqualStrings("a&bogus & b", buf[0..n]);
}

test "decode decimal and uppercase hex entities" {
    var buf = "&#32;&#X3E;".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualStrings(" >", buf[0..n]);
}

test "decode two-byte numeric entity" {
    var buf = "a&#169;b".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualStrings("a\xc2\xa9b", buf[0..n]);
}

test "decode numeric entities allows leading zeros and rejects oversized values" {
    var buf = "&#0000032;&#x00003E;&#1114112;&#x110000;".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualSlices(u8, " >" ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects missing digits" {
    var buf = "&#;&#x;&#X;".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects null codepoint" {
    var buf = "&#0;&#00;&#x0;&#X000;".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "attribute decoding replaces numeric nulls and literal nulls" {
    var buf = "a&#0;b&#x00;c\x00d&amp;e".*;
    const n = decodeAttributeInPlace(&buf, null);
    try std.testing.expectEqualSlices(u8, "a" ++ &ReplacementUtf8 ++ "b" ++ &ReplacementUtf8 ++ "c d&e", buf[0..n]);
}

test "decode numeric entities rejects surrogate codepoints" {
    var buf = "&#55296;&#57343;&#xD800;&#xDFFF;&#xd800;&#xdfff;".*;
    const n = decodeInPlace(false, &buf);
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
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualStrings("plain text", buf[0..n]);
}

test "common named entities decode without full table" {
    var buf = "&nbsp;&copy;&reg;&mdash;&ndash;&hellip;".*;
    const n = decodeInPlace(false, &buf);
    try std.testing.expectEqualStrings("\xc2\xa0\xc2\xa9\xc2\xae\xe2\x80\x94\xe2\x80\x93\xe2\x80\xa6", buf[0..n]);
}

test "minimal entity mode excludes optional common names" {
    var buf = "&amp;&nbsp;&copy;".*;
    const n = decodeInPlaceWithMode(.minimal, false, &buf);
    try std.testing.expectEqualStrings("&&nbsp;&copy;", buf[0..n]);
}

test "full named entity mode decodes uncommon and two-codepoint values" {
    var buf = "&eacute; &NotNestedGreaterGreater;".*;
    const n = decodeInPlaceFull(false, &buf);
    try std.testing.expectEqualStrings("\xc3\xa9 \xe2\xaa\xa2\xcc\xb8", buf[0..n]);
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
