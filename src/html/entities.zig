const std = @import("std");
const IndexInt = @import("../common.zig").IndexInt;
const InvalidDigit = 0xff;
const ReplacementUtf8 = [3]u8{ 0xEF, 0xBF, 0xBD };

/// Result of decoding one HTML entity prefix.
pub const Decoded = struct {
    /// Number of source bytes consumed from the entity prefix.
    consumed: IndexInt,
    /// UTF-8 bytes produced by the decode.
    bytes: [4]u8,
    /// Number of valid bytes in `bytes`.
    len: u3,

    /// Formats this decoded entity result for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Decoded{{consumed={}, len={}, bytes=[{},{},{},{}]}}", .{
            self.consumed,
            self.len,
            self.bytes[0],
            self.bytes[1],
            self.bytes[2],
            self.bytes[3],
        });
    }
};

const NumericParseResult = union(enum) {
    none,
    decoded: Decoded,
    replacement: usize,
};

const NumericBase = enum(u8) {
    decimal = 10,
    hex = 16,
};

inline fn isInvalidNumericCodepoint(value: u32) bool {
    return value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF);
}

/// Decodes entities in-place over entire slice and returns new length.
pub fn decodeInPlace(slice: []u8) usize {
    const first = std.mem.indexOfScalar(u8, slice, '&') orelse return slice.len;
    var r: usize = first;
    var w: usize = first;

    while (r < slice.len) {
        const amp_rel = std.mem.indexOfScalarPos(u8, slice, r, '&') orelse {
            if (w != r) {
                std.mem.copyForwards(u8, slice[w .. w + (slice.len - r)], slice[r..slice.len]);
            }
            w += slice.len - r;
            break;
        };

        if (amp_rel > r) {
            const chunk_len = amp_rel - r;
            if (w != r) {
                std.mem.copyForwards(u8, slice[w .. w + chunk_len], slice[r..amp_rel]);
            }
            w += chunk_len;
            r = amp_rel;
        }

        const maybe = decodeEntity(slice[r + 1 ..]);
        if (maybe) |decoded| {
            // Copy decoded scalar bytes directly into the write cursor.
            std.mem.copyForwards(u8, slice[w .. w + decoded.len], decoded.bytes[0..decoded.len]);
            r += decoded.consumed;
            w += decoded.len;
            continue;
        }

        slice[w] = slice[r];
        r += 1;
        w += 1;
    }

    return w;
}

fn decodeEntity(rem: []const u8) ?Decoded {
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
        '#' => switch (rem[1]) {
            'x', 'X' => switch (parseNumericHex(rem[2..])) {
                .none => null,
                .decoded => |n| .{ .consumed = n.consumed, .bytes = n.bytes, .len = n.len },
                .replacement => |consumed| replacementDecoded(consumed),
            },
            else => switch (parseNumericDecimal(rem[1..])) {
                .none => null,
                .decoded => |n| .{ .consumed = n.consumed, .bytes = n.bytes, .len = n.len },
                .replacement => |consumed| replacementDecoded(consumed),
            },
        },
        else => null,
    };
}

fn literalDecoded(consumed: usize, c: u8) Decoded {
    return .{
        .consumed = @intCast(consumed),
        .bytes = .{ c, 0, 0, 0 },
        .len = 1,
    };
}

fn replacementDecoded(consumed: usize) Decoded {
    return .{
        .consumed = @intCast(consumed),
        .bytes = .{ ReplacementUtf8[0], ReplacementUtf8[1], ReplacementUtf8[2], 0 },
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

fn parseNumericDecimal(rem: []const u8) NumericParseResult {
    return parseNumeric(.decimal, rem);
}

fn parseNumericHex(rem: []const u8) NumericParseResult {
    return parseNumeric(.hex, rem);
}

fn parseNumeric(comptime base: NumericBase, rem: []const u8) NumericParseResult {
    if (rem.len == 0) return .none;

    var i: usize = 0;
    while (i < rem.len and rem[i] == '0') : (i += 1) {}

    const max_scan = switch (base) {
        .decimal => 9,
        .hex => 8,
    };
    const max_digits = switch (base) {
        .decimal => 7,
        .hex => 6,
    };
    const consumed_extra = switch (base) {
        .decimal => 3,
        .hex => 4,
    };

    const scan_end = @min(rem.len, i + max_scan);
    const semi_rel = std.mem.indexOfScalar(u8, rem[i..scan_end], ';') orelse return .none;
    const semi = i + semi_rel;
    const consumed = semi + consumed_extra;
    if (semi_rel == 0 or semi_rel > max_digits) return .{ .replacement = consumed };

    var value: u32 = 0;
    while (i < semi) : (i += 1) {
        const digit_u8 = NumericDigitTable[rem[i]];
        if (digit_u8 >= @intFromEnum(base)) return .{ .replacement = consumed };
        value = value * @intFromEnum(base) + digit_u8;
    }

    if (isInvalidNumericCodepoint(value)) return .{ .replacement = consumed };
    return if (encodeNumericValue(value, consumed)) |decoded|
        .{ .decoded = decoded }
    else
        .{ .replacement = consumed };
}

fn encodeNumericValue(value: u32, consumed: usize) ?Decoded {
    var out: [4]u8 = undefined;
    const codepoint: u21 = @intCast(value);
    const len = std.unicode.utf8Encode(codepoint, &out) catch return null;
    return .{ .consumed = @intCast(consumed), .bytes = out, .len = len };
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

fn fillInterestingEntityBytes(random: std.Random, out: []u8) void {
    for (out) |*b| {
        b.* = switch (random.uintLessThan(u5, 16)) {
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
            11 => '0' + random.uintLessThan(u8, 10),
            12 => 'a' + random.uintLessThan(u8, 26),
            13 => 'A' + random.uintLessThan(u8, 26),
            else => random.int(u8),
        };
    }
}

fn fillInterestingEntityBytesSmith(smith: *std.testing.Smith, out: []u8) void {
    for (out) |*b| {
        b.* = switch (smith.value(u4)) {
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
            11 => '0' + smith.valueRangeAtMost(u8, 0, 9),
            12 => 'a' + smith.valueRangeAtMost(u8, 0, 25),
            13 => 'A' + smith.valueRangeAtMost(u8, 0, 25),
            else => smith.value(u8),
        };
    }
}

fn expectDecodeMatchesReference(alloc: std.mem.Allocator, input: []const u8) !void {
    const expected = try decodeReferenceAlloc(alloc, input);
    defer alloc.free(expected);

    const buf = try alloc.dupe(u8, input);
    defer alloc.free(buf);

    const actual_len = decodeInPlace(buf);
    try std.testing.expect(actual_len <= buf.len);
    try std.testing.expectEqualSlices(u8, expected, buf[0..actual_len]);
}

test "decode entities" {
    var buf = "a&amp;b&#x20;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings("a&b ", buf[0..n]);
}

test "decode decimal and uppercase hex entities" {
    var buf = "&#32;&#X3E;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings(" >", buf[0..n]);
}

test "decode numeric entities allows leading zeros and rejects oversized values" {
    var buf = "&#0000032;&#x00003E;&#1114112;&#x110000;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualSlices(u8, " >" ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects missing digits" {
    var buf = "&#;&#x;&#X;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects null codepoint" {
    var buf = "&#0;&#00;&#x0;&#X000;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects surrogate codepoints" {
    var buf = "&#55296;&#57343;&#xD800;&#xDFFF;&#xd800;&#xdfff;".*;
    const n = decodeInPlace(&buf);
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
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings("plain text", buf[0..n]);
}

test "format decoded entity" {
    const alloc = std.testing.allocator;
    const decoded: Decoded = .{
        .consumed = 3,
        .bytes = .{ 1, 2, 3, 4 },
        .len = 2,
    };
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{decoded});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("Decoded{consumed=3, len=2, bytes=[1,2,3,4]}", rendered);
}
