const std = @import("std");
const builtin = @import("builtin");
const declaration_testing = @import("../testing.zig");
const tables = @import("tables.zig");
const tags = @import("tags.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

const use_vectors = switch (builtin.zig_backend) {
    .stage2_aarch64,
    .stage2_powerpc,
    .stage2_riscv64,
    .stage2_spirv,
    => false,
    else => true,
};

/// Counts `value` in `source` using direct vector masks.
/// Kept separate from the parser body so the sampling path does not inflate
/// the tokenization loop.
pub noinline fn countByte(source: []const u8, value: u8) usize {
    var index: usize = 0;
    var count: usize = 0;

    if (use_vectors and !std.debug.inValgrind() and !@inComptime()) {
        if (std.simd.suggestVectorLength(u8)) |suggested_len| {
            const Block = @Vector(suggested_len, u8);
            const BoolBlock = @Vector(suggested_len, bool);
            const MaskInt = std.meta.Int(.unsigned, suggested_len);
            const mask: Block = @splat(value);

            while (index + suggested_len <= source.len) : (index += suggested_len) {
                const block: Block = source[index..][0..suggested_len].*;
                const matches: BoolBlock = block == mask;
                const bits: MaskInt = @bitCast(matches);
                count += @popCount(bits);
            }
        }
    }

    while (index < source.len) : (index += 1) {
        count += @intFromBool(source[index] == value);
    }
    return count;
}

/// Finds `value` at or after `start`; returns `source.len` on a miss.
/// Keep this specialized and non-optional: on current Zig/LLVM, `?usize`
/// uses a hidden result pointer and `std.simd.firstTrue` lowers to a long
/// reduction tree, while bitcasting the compare mask feeds `@ctz` directly.
pub fn findBytePosOrEnd(source: []const u8, start: usize, value: u8) usize {
    if (start >= source.len) return source.len;

    var index = start;
    if (use_vectors and !std.debug.inValgrind() and !@inComptime()) {
        if (std.simd.suggestVectorLength(u8)) |suggested_len| {
            const max_len = suggested_len * 2;
            const min_len = @min(suggested_len, 4);

            comptime var block_len_sum: u16 = max_len;
            inline while (block_len_sum >= min_len) : (block_len_sum /= 2) {
                const block_len = @min(block_len_sum, suggested_len);
                const block_cnt = @max(1, block_len_sum / block_len);
                const Block = @Vector(block_len, u8);
                const BoolBlock = @Vector(block_len, bool);
                const MaskInt = std.meta.Int(.unsigned, block_len);
                const mask: Block = @splat(value);

                if (index + block_len_sum <= source.len) while (true) {
                    inline for (0..block_cnt) |_| {
                        if (comptime block_len == suggested_len) {
                            const block: Block = source[index..][0..block_len].*;
                            const matches: BoolBlock = block == mask;
                            const bits: MaskInt = @bitCast(matches);
                            if (bits != 0) return index + @ctz(bits);
                        } else {
                            var offset: usize = 0;
                            while (offset < block_len) : (offset += 1) {
                                if (source[index + offset] == value) return index + offset;
                            }
                        }
                        index += block_len;
                    }

                    if (block_len_sum == max_len) {
                        if (index + block_len_sum > source.len) break;
                    } else break;
                };
            }
        }
    }

    while (index < source.len) : (index += 1) {
        if (source[index] == value) return index;
    }
    return source.len;
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

        // Once an equals sign is followed by a quote, local byte context is
        // not enough to know whether that equals sign is an assignment. It may
        // itself be data in an unquoted value or the first byte of a recovered
        // attribute name. Use the exact tokenizer state machine for this tag.
        return findTagEndSlow(source, start);
    }
    return null;
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
                i = findBytePosOrEnd(source, i, '\'');
                if (i == source.len) return null;
                state = .after_quoted;
            },
            .quoted_double => {
                i = findBytePosOrEnd(source, i, '"');
                if (i == source.len) return null;
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

/// Finds the exclusive end of a CDATA token whose payload starts at
/// `content_start` (immediately after `<![CDATA[`). Unterminated CDATA runs
/// through EOF.
pub inline fn findCdataEnd(source: []const u8, content_start: usize) usize {
    const close = std.mem.indexOfPos(u8, source, content_start, "]]>") orelse return source.len;
    return close + 3;
}

/// Finds an opaque declaration's closing `>`. Unlike normal attributes,
/// declaration syntax can contain standalone quoted spans.
pub inline fn findDeclarationEnd(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '>' => return i,
            '\'', '"' => |quote| {
                i = findBytePosOrEnd(source, i + 1, quote);
                if (i == source.len) return null;
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
    while (true) {
        const lt = findBytePosOrEnd(source, search, '<');
        if (lt == source.len) return null;
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

test "tag end scanner does not promote unquoted value fragments to quoted attributes" {
    // After `a=` the whitespace is still before-value state, so `b='` begins
    // the unquoted value. The quote before `c` is data, and `c='` starts the
    // actual unterminated quoted attribute value.
    try std.testing.expect(findTagEnd(" a= b=' c='>", 0) == null);

    // Slash is ordinary data in an unquoted value. It must not make `b='`
    // look like a new quoted attribute assignment.
    try std.testing.expect(findTagEnd(" a=x/b=' c='>", 0) == null);
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
