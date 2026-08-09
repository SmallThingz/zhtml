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

pub const CommentClose = struct {
    /// Exclusive end of the comment payload.
    content_end: usize,
    /// Exclusive end of the complete comment token.
    token_end: usize,
};

/// Scans an HTML tag name and builds its lowercase first-eight-byte key.
/// Destructive DOM parsing specializes `normalize_first8` to true and
/// canonicalizes the complete name; streaming parsing specializes it to false
/// and never writes to the source.
pub inline fn scanTagName(source: []const u8, start: usize, comptime normalize_first8: bool) TagName {
    var i = start;
    var key: u64 = 0;
    for (0..8) |off| {
        if (i >= source.len) break;
        const c = tables.TagNameLowerTable[source[i]];
        if (c == 0) break;
        if (comptime normalize_first8) @constCast(source)[i] = c;
        key |= @as(u64, c) << @as(u6, @intCast(off * 8));
        i += 1;
    } else {
        while (i < source.len) : (i += 1) {
            const c = tables.TagNameLowerTable[source[i]];
            if (c == 0) break;
            if (comptime normalize_first8) @constCast(source)[i] = c;
        }
    }
    return .{ .start = start, .end = i, .key = key };
}

/// Finds a normal tag's closing `>`, respecting the tokenizer distinction
/// between quoted values and quote bytes that occur in attribute names or
/// unquoted values. The common no-quote case stays a single vectorized search.
pub inline fn findTagEnd(source: []const u8, start: usize) ?usize {
    if (start >= source.len) return null;

    // The hot path scans only for `>` and `=`. Quotes matter to the tokenizer
    // only when an `=` has actually begun a quoted attribute value; scanning
    // for every quote doubles the number of candidates on ordinary HTML.
    var search = start;
    while (std.mem.indexOfAnyPos(u8, source, search, ">=")) |special| {
        if (source[special] == '>') return special;

        var value_start = special + 1;
        while (value_start < source.len and tables.WhitespaceTable[source[value_start]]) : (value_start += 1) {}
        if (value_start >= source.len) return null;

        const quote = source[value_start];
        if (quote != '\'' and quote != '"') {
            search = special + 1;
            continue;
        }

        // A later '=' inside an unquoted value must not manufacture a quoted
        // value (`a=x=">"`). Accept the common assignment shapes directly;
        // ambiguous malformed input falls back to the exact tokenizer below.
        if (!assignmentEqStartsAttributeValue(source, start, special)) return findTagEndSlow(source, start);
        search = (std.mem.indexOfScalarPos(u8, source, value_start + 1, quote) orelse return null) + 1;
    }
    return null;
}

inline fn assignmentEqStartsAttributeValue(source: []const u8, start: usize, eq: usize) bool {
    var i = eq;
    while (i > start and tables.WhitespaceTable[source[i - 1]]) : (i -= 1) {}
    const name_end = i;
    while (i > start and tables.AttrNameCharTable[source[i - 1]]) : (i -= 1) {}
    if (i == name_end) return false;
    return i == start or tables.WhitespaceTable[source[i - 1]] or source[i - 1] == '/';
}

fn findTagEndSlow(source: []const u8, start: usize) ?usize {
    const State = enum {
        before_attribute,
        attribute_name,
        after_attribute_name,
        before_value,
        quoted_single,
        quoted_double,
        unquoted,
        after_quoted,
    };

    var state: State = .before_attribute;
    var i = start;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        switch (state) {
            .before_attribute => {
                if (c == '>') return i;
                if (tables.WhitespaceTable[c] or c == '/') continue;
                state = .attribute_name;
            },
            .attribute_name => {
                if (c == '>') return i;
                if (tables.WhitespaceTable[c]) {
                    state = .after_attribute_name;
                } else if (c == '/') {
                    state = .before_attribute;
                } else if (c == '=') {
                    state = .before_value;
                }
            },
            .after_attribute_name => {
                if (c == '>') return i;
                if (tables.WhitespaceTable[c]) continue;
                if (c == '=') {
                    state = .before_value;
                } else if (c == '/') {
                    state = .before_attribute;
                } else {
                    state = .attribute_name;
                }
            },
            .before_value => {
                if (c == '>') return i;
                if (tables.WhitespaceTable[c]) continue;
                state = switch (c) {
                    '\'' => .quoted_single,
                    '"' => .quoted_double,
                    else => .unquoted,
                };
            },
            .quoted_single => {
                i = std.mem.indexOfScalarPos(u8, source, i, '\'') orelse return null;
                state = .after_quoted;
            },
            .quoted_double => {
                i = std.mem.indexOfScalarPos(u8, source, i, '"') orelse return null;
                state = .after_quoted;
            },
            .unquoted => {
                if (c == '>') return i;
                if (tables.WhitespaceTable[c]) state = .before_attribute;
            },
            .after_quoted => {
                if (c == '>') return i;
                if (tables.WhitespaceTable[c] or c == '/') {
                    state = .before_attribute;
                } else {
                    // Parse-error recovery reconsumes this byte as the start of
                    // the next attribute; quote characters here are name data.
                    state = .attribute_name;
                }
            },
        }
    }
    return null;
}

/// Returns whether the slash immediately before `tag_end` is the tokenizer's
/// self-closing marker rather than part of an unquoted attribute value.
///
/// `tag_end` is the index of `>` and `name_end` is the first byte after the tag
/// name. In HTML tokenization `/` is ordinary data while in an unquoted value,
/// so `<x a=b/>` has value `b/` and is not a self-closing start tag.
pub fn isSelfClosingStartTag(source: []const u8, name_end: usize, tag_end: usize) bool {
    if (tag_end <= name_end or tag_end >= source.len or source[tag_end] != '>' or source[tag_end - 1] != '/') return false;
    const slash = tag_end - 1;
    if (slash == name_end) return true;

    const State = enum {
        before_attribute,
        attribute_name,
        after_attribute_name,
        before_value,
        quoted_single,
        quoted_double,
        unquoted,
        after_quoted,
    };

    var state: State = .before_attribute;
    var i = name_end;
    while (i < slash) : (i += 1) {
        const c = source[i];
        switch (state) {
            .before_attribute => {
                if (tables.WhitespaceTable[c]) continue;
                if (c == '/') continue;
                state = .attribute_name;
            },
            .attribute_name => {
                if (tables.WhitespaceTable[c]) {
                    state = .after_attribute_name;
                } else if (c == '=') {
                    state = .before_value;
                } else if (c == '/') {
                    state = .before_attribute;
                }
            },
            .after_attribute_name => {
                if (tables.WhitespaceTable[c]) continue;
                if (c == '=') {
                    state = .before_value;
                } else if (c == '/') {
                    state = .before_attribute;
                } else {
                    state = .attribute_name;
                }
            },
            .before_value => {
                if (tables.WhitespaceTable[c]) continue;
                state = switch (c) {
                    '\'' => .quoted_single,
                    '"' => .quoted_double,
                    else => .unquoted,
                };
            },
            .quoted_single => {
                if (c == '\'') state = .after_quoted;
            },
            .quoted_double => {
                if (c == '"') state = .after_quoted;
            },
            .unquoted => {
                if (tables.WhitespaceTable[c]) state = .before_attribute;
            },
            .after_quoted => {
                if (tables.WhitespaceTable[c]) {
                    state = .before_attribute;
                } else if (c == '/') {
                    state = .before_attribute;
                } else {
                    // Parse-error recovery starts another attribute.
                    state = .attribute_name;
                }
            },
        }
    }

    return switch (state) {
        .unquoted, .before_value, .quoted_single, .quoted_double => false,
        else => true,
    };
}

/// Finds the end of an HTML comment whose payload begins at `content_start`
/// (immediately after `<!--`). This recognizes the tokenizer's abrupt empty
/// closes (`<!-->` and `<!--->`), normal `-->`, and the parse-error close
/// `--!>`. At EOF both returned positions equal `source.len`.
pub inline fn findCommentClose(source: []const u8, content_start: usize) CommentClose {
    if (content_start >= source.len) return .{ .content_end = source.len, .token_end = source.len };

    // Comment-start and comment-start-dash states have two short malformed
    // forms which close without contributing bytes to the comment payload.
    if (source[content_start] == '>') {
        return .{ .content_end = content_start, .token_end = content_start + 1 };
    }
    if (content_start + 1 < source.len and source[content_start] == '-' and source[content_start + 1] == '>') {
        return .{ .content_end = content_start, .token_end = content_start + 2 };
    }

    var search = content_start;
    while (std.mem.indexOfPos(u8, source, search, "--")) |dashes| {
        const after = dashes + 2;
        if (after < source.len and source[after] == '>') {
            return .{ .content_end = dashes, .token_end = after + 1 };
        }
        if (after + 1 < source.len and source[after] == '!' and source[after + 1] == '>') {
            return .{ .content_end = dashes, .token_end = after + 2 };
        }
        // Overlapping pairs matter for runs such as `--->`.
        search = dashes + 1;
    }

    return .{ .content_end = source.len, .token_end = source.len };
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
) ?RawTextClose {
    // Candidate end-tag names live inside the raw text until they have been
    // proven to be an appropriate end tag. Never normalize those speculative
    // bytes in place: a near miss such as </ScRiPtX> is script data.
    if (name.len == 0) return null;
    var search = start;
    const first = std.ascii.toLower(name[0]);
    while (std.mem.indexOfScalarPos(u8, source, search, '<')) |lt| {
        search = lt + 1;
        if (lt + 2 >= source.len or source[lt + 1] != '/' or std.ascii.toLower(source[lt + 2]) != first) continue;

        const close = scanTagName(source, lt + 2, false);
        if (!tags.equalByLenAndKeyIgnoreCase(source[close.start..close.end], close.key, name, key)) continue;
        if (close.end >= source.len) return null;
        const delimiter = source[close.end];
        if (delimiter != '>' and delimiter != '/' and !tables.WhitespaceTable[delimiter]) continue;
        const tag_end = findTagEnd(source, close.end) orelse return null;
        return .{ .content_end = lt, .close_start = lt, .close_end = tag_end + 1 };
    }
    return null;
}

test "shared tag scanner preserves mode-specific normalization" {
    var destructive = "ScRiPt-lOnG ".*;
    const rw = scanTagName(&destructive, 0, true);
    try std.testing.expectEqualStrings("script-long", destructive[0..rw.end]);

    const read_only = "ScRiPt-lOnG ";
    const ro = scanTagName(read_only, 0, false);
    try std.testing.expectEqualStrings("ScRiPt-lOnG", read_only[0..ro.end]);
    try std.testing.expectEqual(rw.key, ro.key);
}

test "shared tag end scanner respects only attribute value quotes" {
    const source = "x = \"a>b\" y='c>d'>tail";
    try std.testing.expectEqual(@as(?usize, 17), findTagEnd(source, 0));
    try std.testing.expectEqual(@as(?usize, 4), findTagEnd("x ' >", 0));
    try std.testing.expectEqual(@as(?usize, 6), findDeclarationEnd("x '>' >", 0));
}

test "tag end scanner does not invent quoted values inside unquoted data" {
    // In an unquoted value, `=` and quote bytes are parse-error data. The first
    // `>` therefore closes the tag rather than being hidden by a fake quote.
    const malformed = " a=x=\">\" id=y>tail";
    try std.testing.expectEqual(@as(?usize, 6), findTagEnd(malformed, 0));

    const quoted = " a=\"x>y\" id=z>tail";
    try std.testing.expectEqual(@as(?usize, 13), findTagEnd(quoted, 0));
}

test "self-closing marker excludes slash inside unquoted attribute values" {
    try std.testing.expect(isSelfClosingStartTag("<x/>", 2, 3));
    try std.testing.expect(isSelfClosingStartTag("<x disabled/>", 2, 12));
    try std.testing.expect(isSelfClosingStartTag("<x a='b'/>", 2, 9));
    try std.testing.expect(isSelfClosingStartTag("<x a=b />", 2, 8));

    try std.testing.expect(!isSelfClosingStartTag("<x a=b/>", 2, 7));
    try std.testing.expect(!isSelfClosingStartTag("<x a=/>", 2, 6));
    try std.testing.expect(!isSelfClosingStartTag("<x a= />", 2, 7));
}

test "shared comment scanner handles abrupt and incorrectly closed comments" {
    const cases = [_]struct {
        source: []const u8,
        content: []const u8,
        tail: []const u8,
    }{
        .{ .source = "<!--><p>", .content = "", .tail = "<p>" },
        .{ .source = "<!---><p>", .content = "", .tail = "<p>" },
        .{ .source = "<!--x--><p>", .content = "x", .tail = "<p>" },
        .{ .source = "<!--x--!><p>", .content = "x", .tail = "<p>" },
        .{ .source = "<!--x---><p>", .content = "x-", .tail = "<p>" },
        .{ .source = "<!--unterminated", .content = "unterminated", .tail = "" },
    };

    for (cases) |case| {
        const close = findCommentClose(case.source, 4);
        try std.testing.expectEqualStrings(case.content, case.source[4..close.content_end]);
        try std.testing.expectEqualStrings(case.tail, case.source[close.token_end..]);
    }
}

test "shared raw text close scanner handles case and spaced attributes" {
    const source = "a<b</ScRiPt x = \"a>b\">tail";
    const key = tags.first8KeyWithMode("script", false);
    const close = findRawTextClose(source, "script", key, 0).?;
    try std.testing.expectEqual(@as(usize, 3), close.content_end);
    try std.testing.expectEqualStrings("tail", source[close.close_end..]);
}

test "raw text close requires an end-tag-name delimiter" {
    const key = tags.first8KeyWithMode("script", false);
    const source = "a</script=x>b</script!>c</script>d";
    const close = findRawTextClose(source, "script", key, 0).?;
    try std.testing.expectEqualStrings("a</script=x>b</script!>c", source[0..close.content_end]);
    try std.testing.expectEqualStrings("d", source[close.close_end..]);
}

test "destructive raw text search does not mutate rejected close candidates" {
    var source = "x</ScRiPtX>y</SCRIPT=z>q</SCRIPT>tail".*;
    const original = source;
    const key = tags.first8KeyWithMode("script", false);
    const close = findRawTextClose(&source, "script", key, 0).?;
    try std.testing.expectEqualStrings("x</ScRiPtX>y</SCRIPT=z>q", source[0..close.content_end]);
    try std.testing.expectEqualStrings("tail", source[close.close_end..]);
    // Searching itself is read-only, including the ultimately accepted close.
    try std.testing.expectEqualSlices(u8, &original, &source);
}
