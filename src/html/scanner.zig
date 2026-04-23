const std = @import("std");
const tables = @import("tables.zig");

// SAFETY: Scanners operate on byte slices and rely on caller-provided bounds.
// All indexing stays within `hay.len` and is guarded by bounds checks or
// debug asserts where assumptions are made.

/// Result of scanning to a tag end while respecting quoted attributes.
pub const TagEnd = struct {
    /// Index of the closing `>` byte.
    gt_index: usize,
    /// End of the raw attribute region immediately before `>` or `/>`.
    attr_end: usize,

    /// Formats this tag end summary for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("TagEnd{{gt_index={}, attr_end={}}}", .{ self.gt_index, self.attr_end });
    }
};

/// Result of scanning a text run up to the next `<`.
pub const TextRun = struct {
    /// Index of the next `<`, or `hay.len` when none exists.
    lt_index: usize,
    /// True when the scanned run contained any non-whitespace byte.
    has_non_whitespace: bool,
};

/// Scans from `start` to the next `<`, tracking whether the run contains any non-whitespace bytes.
pub fn scanTextRun(hay: []const u8, start: usize) TextRun {
    // TODO: Make this faster in the case where we don't discard whitespace only nodes 
    if (start >= hay.len) return .{ .lt_index = hay.len, .has_non_whitespace = false };

    var i = start;
    while (i < hay.len and tables.WhitespaceTable[hay[i]]) : (i += 1) {}
    if (i >= hay.len) return .{ .lt_index = hay.len, .has_non_whitespace = false };
    if (hay[i] == '<') return .{ .lt_index = i, .has_non_whitespace = false };

    return .{
        .lt_index = std.mem.indexOfScalarPos(u8, hay, i, '<') orelse hay.len,
        .has_non_whitespace = true,
    };
}

/// Scans from `start` to next `>` while skipping quoted `>` inside attributes.
pub fn findTagEndRespectQuotes(hay: []const u8, _start: usize) ?TagEnd {
    std.debug.assert(_start <= hay.len);
    var start = _start;
    var end = @call(.always_inline, std.mem.indexOfAnyPos, .{ u8, hay, start, ">'\"" }) orelse {
        @branchHint(.cold);
        return null;
    };
    blk: switch (hay[end]) {
        '>' => return .{
            .gt_index = end,
            .attr_end = end,
        },
        '\'', '"' => |q| {
            start = 1 + end;
            start = 1 + (std.mem.indexOfScalarPos(u8, hay, start, q) orelse {
                @branchHint(.cold);
                return null;
            });
            end = @call(.always_inline, std.mem.indexOfAnyPos, .{ u8, hay, start, ">'\"" }) orelse {
                @branchHint(.cold);
                return null;
            };
            continue :blk hay[end];
        },
        else => unreachable,
    }
}

/// Returns true when a tag ending at `gt_index` is explicitly self-closing
/// via `.../>` (allowing whitespace before `>`).
/// Only to be used for svg
pub inline fn isExplicitSelfClosingTag(hay: []const u8, start: usize, gt_index: usize) bool {
    if (gt_index == 0 or gt_index >= hay.len or hay[gt_index] != '>') return false;
    var j = gt_index;
    while (j > start and tables.WhitespaceTable[hay[j - 1]]) : (j -= 1) {}
    return j > start and hay[j - 1] == '/';
}

/// Scans from `start` (right after an opening `<svg...>` tag) to the matching
/// closing `</svg>`, counting nested `<svg>` blocks and ignoring `<svg` text
/// inside quoted attributes.
pub fn findSvgSubtreeEnd(hay: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < hay.len) {
        const lt = std.mem.indexOfScalarPos(u8, hay, i, '<') orelse return null;
        if (lt + 1 >= hay.len) return null;

        var k = lt + 1;
        while (k < hay.len and tables.WhitespaceTable[hay[k]]) : (k += 1) {}
        if (k >= hay.len) return null;

        switch (hay[k]) {
            '!' => {
                if (k + 2 < hay.len and hay[k + 1] == '-' and hay[k + 2] == '-') {
                    var j = k + 3;
                    while (j + 2 < hay.len) {
                        const dash = std.mem.indexOfScalarPos(u8, hay, j, '-') orelse return null;
                        if (dash + 2 < hay.len and hay[dash + 1] == '-' and hay[dash + 2] == '>') {
                            i = dash + 3;
                            break;
                        }
                        j = dash + 1;
                    } else return null;
                } else {
                    const gt = std.mem.indexOfScalarPos(u8, hay, k + 1, '>') orelse return null;
                    i = gt + 1;
                }
            },
            '?' => {
                const gt = std.mem.indexOfScalarPos(u8, hay, k + 1, '>') orelse return null;
                i = gt + 1;
            },
            '/' => {
                var j = k + 1;
                while (j < hay.len and tables.WhitespaceTable[hay[j]]) : (j += 1) {}
                const name_start = j;
                while (j < hay.len and tables.TagNameCharTable[hay[j]]) : (j += 1) {}
                const gt = std.mem.indexOfScalarPos(u8, hay, j, '>') orelse return null;
                if (isSvgTagName(hay[name_start..j])) {
                    depth -= 1;
                    if (depth == 0) return gt + 1;
                }
                i = gt + 1;
            },
            else => {
                var j = k;
                while (j < hay.len and tables.TagNameCharTable[hay[j]]) : (j += 1) {}
                if (j == k) {
                    i = lt + 1;
                    continue;
                }

                const tag_end = findTagEndRespectQuotes(hay, j) orelse return null;
                if (isSvgTagName(hay[k..j]) and !isExplicitSelfClosingTag(hay, j, tag_end.gt_index)) {
                    depth += 1;
                }
                i = tag_end.gt_index + 1;
            },
        }
    }
    return null;
}

inline fn isSvgTagName(name: []const u8) bool {
    return name.len == 3 and
        tables.lower(name[0]) == 's' and
        tables.lower(name[1]) == 'v' and
        tables.lower(name[2]) == 'g';
}

test "scanTextRun tracks next tag and whitespace-only runs" {
    const a = scanTextRun(" \n\t<em>", 0);
    try std.testing.expectEqual(@as(usize, 3), a.lt_index);
    try std.testing.expect(!a.has_non_whitespace);

    const b = scanTextRun("  hi<em>", 0);
    try std.testing.expectEqual(@as(usize, 4), b.lt_index);
    try std.testing.expect(b.has_non_whitespace);

    const c = scanTextRun("plain text", 0);
    try std.testing.expectEqual(@as(usize, 10), c.lt_index);
    try std.testing.expect(c.has_non_whitespace);

    const d = scanTextRun(" \n\t hi \n\t<em>", 0);
    try std.testing.expectEqual(@as(usize, 9), d.lt_index);
    try std.testing.expect(d.has_non_whitespace);
}

test "findTagEndRespectQuotes handles quoted >" {
    const s = " x='1>2' y=z />";
    const out = findTagEndRespectQuotes(s, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, s.len - 1), out.gt_index);
    try std.testing.expectEqual(@as(usize, s.len - 1), out.attr_end);
}

test "isExplicitSelfClosingTag detects slash before > with optional whitespace" {
    const a = " x='1' />";
    const a_gt = std.mem.indexOfScalarPos(u8, a, 0, '>') orelse return error.TestUnexpectedResult;
    try std.testing.expect(isExplicitSelfClosingTag(a, 0, a_gt));

    const b = " x='1'/   >";
    const b_gt = std.mem.indexOfScalarPos(u8, b, 0, '>') orelse return error.TestUnexpectedResult;
    try std.testing.expect(isExplicitSelfClosingTag(b, 0, b_gt));

    const c = " x='1' >";
    const c_gt = std.mem.indexOfScalarPos(u8, c, 0, '>') orelse return error.TestUnexpectedResult;
    try std.testing.expect(!isExplicitSelfClosingTag(c, 0, c_gt));
}

test "findSvgSubtreeEnd handles nested svg and quoted attribute bait" {
    const s = "<svg id='outer'><g data-k=\"x<svg y='z'>q\"><svg id='inner'><rect/></svg></g></svg><p id='after'></p>";
    const open_gt = std.mem.indexOfScalarPos(u8, s, 0, '>') orelse return error.TestUnexpectedResult;
    const out = findSvgSubtreeEnd(s, open_gt + 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<p id='after'></p>", s[out..]);
}

test "findSvgSubtreeEnd does not count nested self-closing svg as depth increase" {
    const s = "<svg id='outer'><svg id='inner' /><g/></svg><p id='after'></p>";
    const open_gt = std.mem.indexOfScalarPos(u8, s, 0, '>') orelse return error.TestUnexpectedResult;
    const out = findSvgSubtreeEnd(s, open_gt + 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<p id='after'></p>", s[out..]);
}

test "findSvgSubtreeEnd returns null when subtree is unterminated" {
    const s = "<svg><g><path></g>";
    const open_gt = std.mem.indexOfScalarPos(u8, s, 0, '>') orelse return error.TestUnexpectedResult;
    try std.testing.expect(findSvgSubtreeEnd(s, open_gt + 1) == null);
}

test "format tag end" {
    const alloc = std.testing.allocator;
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{TagEnd{ .gt_index = 10, .attr_end = 7 }});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("TagEnd{gt_index=10, attr_end=7}", rendered);
}
