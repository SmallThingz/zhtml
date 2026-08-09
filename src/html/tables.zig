const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

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

/// CSS selector identifier start; HTML names use separate blacklist tables.
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':';
}

/// Returns whether byte is consumed by the HTML tag-name state.
/// Matches the tokenizer shape: continue until whitespace, `/`, `>`, or NUL.
fn isTagNameChar(c: u8) bool {
    return !isWhitespace(c) and c != '/' and c != '>' and c != 0;
}

/// Returns whether byte is consumed by the HTML attribute-name state.
/// Attribute names are blacklist-based so framework punctuation remains valid.
fn isAttrNameChar(c: u8) bool {
    return !isWhitespace(c) and c != 0 and c != '>' and c != '/' and c != '=';
}

/// Precomputed whitespace classification table.
pub const WhitespaceTable = makeClassTable(isWhitespace);
/// Precomputed CSS selector identifier-start classification table.
pub const IdentStartTable = makeClassTable(isIdentStart);
/// Precomputed tag-name-char classification table.
pub const TagNameCharTable = makeClassTable(isTagNameChar);
/// Canonical lowercase byte for tag-name bytes; zero marks a tokenizer terminator.
pub const TagNameLowerTable = blk: {
    @setEvalBranchQuota(10_000);
    var table = [_]u8{0} ** 256;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isTagNameChar(c)) table[i] = std.ascii.toLower(c);
    }
    break :blk table;
};
/// Precomputed permissive attribute-name-char classification table.
pub const AttrNameCharTable = makeClassTable(isAttrNameChar);

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

test "attribute name state accepts parse-error data and rejects tokenizer delimiters" {
    for ("@*()[]:.-_\"'<") |c| try std.testing.expect(isAttrNameChar(c));
    for ([_]u8{ 0x01, 0x1f, 0x7f, 0x80 }) |c| try std.testing.expect(isAttrNameChar(c));
    for ([_]u8{ ' ', '\t', '\n', '\r', '\x0c', '>', '/', '=', 0 }) |c| {
        try std.testing.expect(!isAttrNameChar(c));
    }
}
