const std = @import("std");
const declaration_testing = @import("../testing.zig");
const tables = @import("tables.zig");
const tags = @import("tags.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

pub const TagName = struct {
    start: usize,
    end: usize,
    key: u64,
};

pub const RawTextClose = struct {
    content_end: usize,
    close_start: usize,
    close_end: usize,
};

/// Scans an HTML tag name and builds its lowercase first-eight-byte key.
/// Destructive DOM parsing specializes `normalize_first8` to true; streaming
/// parsing specializes it to false and never writes to the source.
pub inline fn scanTagName(source: []const u8, start: usize, comptime normalize_first8: bool) TagName {
    var i = start;
    var key: u64 = 0;
    for (0..8) |off| {
        if (i >= source.len or !tables.TagNameCharTable[source[i]]) break;
        const c = std.ascii.toLower(source[i]);
        if (comptime normalize_first8) @constCast(source)[i] = c;
        key |= @as(u64, c) << @as(u6, @intCast(off * 8));
        i += 1;
    } else {
        while (i < source.len and tables.TagNameCharTable[source[i]]) : (i += 1) {}
    }
    return .{ .start = start, .end = i, .key = key };
}

pub inline fn startsWithIgnoreCase(source: []const u8, start: usize, comptime needle: []const u8) bool {
    if (start + needle.len > source.len) return false;
    inline for (needle, 0..) |want, off| {
        if (std.ascii.toLower(source[start + off]) != want) return false;
    }
    return true;
}

/// Finds a normal tag's closing `>`, respecting quoted attribute values and
/// optional whitespace between `=` and the opening quote.
pub inline fn findTagEnd(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) {
        const pos = std.mem.indexOfAnyPos(u8, source, i, ">=") orelse return null;
        if (source[pos] == '>') return pos;

        i = pos + 1;
        while (i < source.len and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i < source.len and (source[i] == '\'' or source[i] == '"')) {
            const quote = source[i];
            i = (std.mem.indexOfScalarPos(u8, source, i + 1, quote) orelse return null) + 1;
        }
    }
    return null;
}

/// Finds an opaque declaration's closing `>`. Unlike normal attributes,
/// declaration syntax can contain standalone quoted spans.
pub inline fn findDeclarationEnd(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '>' => return i,
            '\'', '"' => |quote| {
                i = std.mem.indexOfScalarPos(u8, source, i + 1, quote) orelse return null;
            },
            else => {},
        }
    }
    return null;
}

/// Finds the matching raw/escapable-raw closing tag. The result uses an
/// exclusive `close_end`, ready for either parser's cursor.
pub inline fn findRawTextClose(
    source: []const u8,
    name: []const u8,
    key: u64,
    start: usize,
    comptime normalize_first8: bool,
) ?RawTextClose {
    if (name.len == 0) return null;
    var search = start;
    const first = std.ascii.toLower(name[0]);
    while (std.mem.indexOfScalarPos(u8, source, search, '<')) |lt| {
        search = lt + 1;
        if (lt + 2 >= source.len or source[lt + 1] != '/' or std.ascii.toLower(source[lt + 2]) != first) continue;

        const close = scanTagName(source, lt + 2, normalize_first8);
        if (!tags.equalByLenAndKeyIgnoreCase(source[close.start..close.end], close.key, name, key)) continue;
        const tag_end = findTagEnd(source, close.end) orelse return null;
        return .{ .content_end = lt, .close_start = lt, .close_end = tag_end + 1 };
    }
    return null;
}

test "shared tag scanner preserves mode-specific normalization" {
    var destructive = "ScRiPt-long ".*;
    const rw = scanTagName(&destructive, 0, true);
    try std.testing.expectEqualStrings("script-long", destructive[0..rw.end]);

    const read_only = "ScRiPt-long ";
    const ro = scanTagName(read_only, 0, false);
    try std.testing.expectEqualStrings("ScRiPt-long", read_only[0..ro.end]);
    try std.testing.expectEqual(rw.key, ro.key);
}

test "shared tag end scanner respects only attribute value quotes" {
    const source = "x = \"a>b\" y='c>d'>tail";
    try std.testing.expectEqual(@as(?usize, 17), findTagEnd(source, 0));
    try std.testing.expectEqual(@as(?usize, 4), findTagEnd("x ' >", 0));
    try std.testing.expectEqual(@as(?usize, 6), findDeclarationEnd("x '>' >", 0));
}

test "shared raw text close scanner handles case and spaced attributes" {
    const source = "a<b</ScRiPt x = \"a>b\">tail";
    const key = tags.first8KeyWithMode("script", false);
    const close = findRawTextClose(source, "script", key, 0, false).?;
    try std.testing.expectEqual(@as(usize, 3), close.content_end);
    try std.testing.expectEqualStrings("tail", source[close.close_end..]);
}
