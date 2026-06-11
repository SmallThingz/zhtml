// I tried combining the tables but that results in
// ~ 0.5% (all 4 in 1 or isIdentStart+isIdentChar)
// ~ 1.5% (isTagNameChar+isWhitespace)
// performance loss [tested 3v3 runs for all 3 cases]
//
// Maybe i did something wrong or this was just noise; want to reduce the table sizes tho
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
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':';
}

/// Returns whether byte is a valid identifier continuation.
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.';
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

/// Trims HTML/ASCII whitespace from both ends using the parser whitespace table.
pub fn trimAsciiWhitespace(slice: []const u8) []const u8 {
    var start: usize = 0;
    var end = slice.len;
    while (start < end and WhitespaceTable[slice[start]]) : (start += 1) {}
    while (end > start and WhitespaceTable[slice[end - 1]]) : (end -= 1) {}
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

test "tag name state includes < and excludes delimiters" {
    try std.testing.expect(isTagNameChar('<'));
    try std.testing.expect(!isTagNameChar('>'));
    try std.testing.expect(!isTagNameChar('/'));
    try std.testing.expect(!isTagNameChar(' '));
}
