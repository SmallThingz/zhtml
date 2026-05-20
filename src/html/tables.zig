const std = @import("std");

/// Builds a 256-entry boolean lookup table from a predicate.
pub fn makeClassTable(comptime predicate: fn (u8) bool) [256]bool {
    @setEvalBranchQuota(10_000);
    var table = [_]bool{false} ** 256;
    inline for (0..256) |i| {
        table[i] = predicate(@as(u8, @intCast(i)));
    }
    return table;
}

/// Returns whether byte is ASCII whitespace relevant to HTML tokenization.
fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '\x0c';
}

/// Returns whether byte is a valid identifier start.
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':';
}

/// Returns whether byte is a valid identifier continuation.
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

/// Returns whether byte is consumed by the HTML tag-name state.
/// Matches the tokenizer shape: continue until whitespace, `/`, `>`, or NUL.
fn isTagNameChar(c: u8) bool {
    return !isWhitespace(c) and c != '/' and c != '>' and c != 0;
}

/// Precomputed whitespace classification table.
pub const WhitespaceTable = makeClassTable(isWhitespace);
/// Precomputed identifier-start classification table.
pub const IdentStartTable = makeClassTable(isIdentStart);
/// Precomputed identifier-char classification table.
pub const IdentCharTable = makeClassTable(isIdentChar);
/// Precomputed tag-name-char classification table.
pub const TagNameCharTable = makeClassTable(isTagNameChar);

/// Lowercases one ASCII byte without a table lookup.
pub inline fn lower(c: u8) u8 {
    return c | (@as(u8, @intFromBool(c -% 'A' <= 'Z' - 'A')) << 5);
}

/// Lowercases ASCII bytes in-place.
pub fn toLowerInPlace(bytes: []u8) void {
    for (bytes) |*c| c.* = lower(c.*);
}

/// Case-insensitive ASCII equality.
pub fn eqlIgnoreCaseAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

/// Case-insensitive ASCII prefix check.
pub fn startsWithIgnoreCaseAscii(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    return eqlIgnoreCaseAscii(hay[0..needle.len], needle);
}

/// Trims ASCII whitespace from both ends of `slice`.
pub fn trimAsciiWhitespace(slice: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = slice.len;
    while (start < end and WhitespaceTable[slice[start]]) start += 1;
    while (end > start and WhitespaceTable[slice[end - 1]]) end -= 1;
    return slice[start..end];
}

/// Returns true when `token` appears in `value` as an ASCII-whitespace-separated token.
pub fn tokenIncludesAsciiWhitespace(value: []const u8, token: []const u8) bool {
    if (token.len == 0) return false;

    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and WhitespaceTable[value[i]]) : (i += 1) {}
        if (i >= value.len) return false;

        const start = i;
        while (i < value.len and !WhitespaceTable[value[i]]) : (i += 1) {}
        if (std.mem.eql(u8, value[start..i], token)) return true;
    }
    return false;
}

test "branchless ascii lower" {
    try std.testing.expect(lower('A') == 'a');
    try std.testing.expect(lower('z') == 'z');
    try std.testing.expect(lower('@') == '@');
    try std.testing.expect(lower('[') == '[');
    try std.testing.expect(lower(0xff) == 0xff);
}

test "tag name state includes < and excludes delimiters" {
    try std.testing.expect(isTagNameChar('<'));
    try std.testing.expect(!isTagNameChar('>'));
    try std.testing.expect(!isTagNameChar('/'));
    try std.testing.expect(!isTagNameChar(' '));
}
