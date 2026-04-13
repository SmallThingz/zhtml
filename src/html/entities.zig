const std = @import("std");
/// Result of decoding one HTML entity prefix.
pub const Decoded = struct {
    /// Number of source bytes consumed from the entity prefix.
    consumed: usize,
    /// UTF-8 bytes produced by the decode.
    bytes: [4]u8,
    /// Number of valid bytes in `bytes`.
    len: usize,

    /// Formats this decoded entity result for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "Decoded{{consumed={}, len={}, bytes=[{d},{d},{d},{d}]}}",
            .{ self.consumed, self.len, self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] },
        );
    }
};

/// Decodes entities in-place over entire slice and returns new length.
pub fn decodeInPlace(slice: []u8) usize {
    return decodeInPlaceFrom(slice, 0);
}

/// Fast-path entity decode that skips work when no `&` is present.
pub fn decodeInPlaceIfEntity(slice: []u8) usize {
    // Fast reject to keep the no-entity path single-pass and branch-light.
    const first = std.mem.indexOfScalarPos(u8, slice, 0, '&') orelse return slice.len;
    return decodeInPlaceFrom(slice, first);
}

/// Decodes a single entity prefix from `rem`, if valid.
pub fn decodeEntityPrefix(rem: []const u8) ?Decoded {
    return decodeEntity(rem);
}

fn decodeInPlaceFrom(slice: []u8, start_index: usize) usize {
    var r: usize = start_index;
    var w: usize = start_index;

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

        const maybe = decodeEntity(slice[r..]);
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
    if (rem.len < 4 or rem[0] != '&') return null;

    if (std.mem.startsWith(u8, rem[1..], "amp;")) return literalDecoded(5, '&');
    if (std.mem.startsWith(u8, rem[1..], "lt;")) return literalDecoded(4, '<');
    if (std.mem.startsWith(u8, rem[1..], "gt;")) return literalDecoded(4, '>');
    if (std.mem.startsWith(u8, rem[1..], "quot;")) return literalDecoded(6, '"');
    if (std.mem.startsWith(u8, rem[1..], "apos;")) return literalDecoded(6, '\'');

    if (rem.len >= 4 and rem[1] == '#') {
        if (parseNumeric(rem)) |n| {
            return .{ .consumed = n.consumed, .bytes = n.bytes, .len = n.len };
        }
    }

    return null;
}

fn literalDecoded(consumed: usize, c: u8) Decoded {
    return .{
        .consumed = consumed,
        .bytes = .{ c, 0, 0, 0 },
        .len = 1,
    };
}

fn parseNumeric(rem: []const u8) ?struct { consumed: usize, bytes: [4]u8, len: usize } {
    if (rem.len < 4 or rem[0] != '&' or rem[1] != '#') return null;

    var i: usize = 2;
    var base: u32 = 10;
    if (i < rem.len and (rem[i] == 'x' or rem[i] == 'X')) {
        base = 16;
        i += 1;
    }

    const start = i;
    var value: u32 = 0;
    while (i < rem.len and rem[i] != ';') : (i += 1) {
        const digit = decodeDigit(rem[i], base) orelse return null;
        const limit = (0x10FFFF - digit) / base;
        if (value > limit) return null;
        value = value * base + digit;
        if (value > 0x10FFFF) return null;
    }

    if (i == start or i >= rem.len or rem[i] != ';') return null;

    var out: [4]u8 = undefined;
    const codepoint: u21 = @intCast(value);
    const len = std.unicode.utf8Encode(codepoint, &out) catch return null;
    return .{ .consumed = i + 1, .bytes = out, .len = len };
}

fn decodeDigit(c: u8, base: u32) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => if (base == 16) 10 + (c - 'a') else null,
        'A'...'F' => if (base == 16) 10 + (c - 'A') else null,
        else => null,
    };
}

test "decode entities" {
    var buf = "a&amp;b&#x20;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings("a&b ", buf[0..n]);
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
