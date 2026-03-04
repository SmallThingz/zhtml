const std = @import("std");
const tables = @import("tables.zig");

/// Returns a packed key of the first up-to-8 tag bytes.
///
/// Byte `i` (little-endian) stores `name[i]`.
pub inline fn first8Key(name: []const u8) u64 {
    var hash: u64 = 0;
    const n: usize = @min(name.len, 8);
    @memcpy(std.mem.asBytes(&hash)[0..n], name[0..n]);
    return hash;
}

/// Case-insensitive equality check accelerated by `(len,key)` prechecks.
///
/// The packed keys are byte-exact; callers are expected to canonicalize the first
/// eight bytes (parser does this in-place).
pub inline fn equalByLenAndKeyIgnoreCase(a: []const u8, a_key: u64, b: []const u8, b_key: u64) bool {
    if (a.len != b.len or a_key != b_key) return false;
    return if (a.len <= 8) true else tables.eqlIgnoreCaseAscii(a[8..], b[8..]);
}

inline fn litKey(comptime s: []const u8) u64 {
    return comptime first8Key(s);
}

const KEY = struct {
    const AREA = litKey("area");
    const BASE = litKey("base");
    const BR = litKey("br");
    const COL = litKey("col");
    const EMBED = litKey("embed");
    const HR = litKey("hr");
    const IMG = litKey("img");
    const INPUT = litKey("input");
    const LINK = litKey("link");
    const META = litKey("meta");
    const PARAM = litKey("param");
    const SOURCE = litKey("source");
    const TRACK = litKey("track");
    const WBR = litKey("wbr");

    const SCRIPT = litKey("script");
    const STYLE = litKey("style");
    const TITLE = litKey("title");
    const TEXTAREA = litKey("textarea");
    const PLAINTEXT = litKey("plaintex");

    const LI = litKey("li");
    const P = litKey("p");
    const DT = litKey("dt");
    const DD = litKey("dd");
    const OPTION = litKey("option");
    const TR = litKey("tr");
    const TD = litKey("td");
    const TH = litKey("th");
    const HEAD = litKey("head");
    const BODY = litKey("body");

    const ADDRESS = litKey("address");
    const ARTICLE = litKey("article");
    const ASIDE = litKey("aside");
    const BLOCKQUOTE = litKey("blockquote");
    const DIV = litKey("div");
    const DL = litKey("dl");
    const FIELDSET = litKey("fieldset");
    const FOOTER = litKey("footer");
    const FORM = litKey("form");
    const H1 = litKey("h1");
    const H2 = litKey("h2");
    const H3 = litKey("h3");
    const H4 = litKey("h4");
    const H5 = litKey("h5");
    const H6 = litKey("h6");
    const HEADER = litKey("header");
    const MAIN = litKey("main");
    const NAV = litKey("nav");
    const OL = litKey("ol");
    const PRE = litKey("pre");
    const SECTION = litKey("section");
    const TABLE = litKey("table");
    const UL = litKey("ul");

    const SVG = litKey("svg");
};

/// Returns whether tag is HTML void tag.
pub fn isVoidTag(name: []const u8) bool {
    return isVoidTagWithKey(name, first8Key(name));
}

/// Returns whether tag is HTML text-only tag closed by explicit end-tag.
///
/// This intentionally includes `title` and `textarea` in addition to raw-text
/// tags to keep parser behavior closer to HTML tokenization semantics while
/// staying in this parser's simplified state machine.
pub fn isRawTextTag(name: []const u8) bool {
    return isRawTextTagWithKey(name, first8Key(name));
}

/// Fast void-tag check with caller-provided key.
pub fn isVoidTagWithKey(name: []const u8, key: u64) bool {
    return switch (name.len) {
        2 => switch (key) {
            KEY.BR, KEY.HR => true,
            else => false,
        },
        3 => switch (key) {
            KEY.COL, KEY.IMG, KEY.WBR => true,
            else => false,
        },
        4 => switch (key) {
            KEY.AREA, KEY.BASE, KEY.LINK, KEY.META => true,
            else => false,
        },
        5 => switch (key) {
            KEY.EMBED, KEY.INPUT, KEY.PARAM, KEY.TRACK => true,
            else => false,
        },
        6 => switch (key) {
            KEY.SOURCE => true,
            else => false,
        },
        else => false,
    };
}

/// Fast text-only-tag check with caller-provided key.
pub fn isRawTextTagWithKey(name: []const u8, key: u64) bool {
    return switch (name.len) {
        5 => key == KEY.STYLE or key == KEY.TITLE,
        6 => key == KEY.SCRIPT,
        8 => key == KEY.TEXTAREA,
        else => false,
    };
}

/// Fast check for `<plaintext>` by `(len,key)`.
pub fn isPlainTextTagWithKey(name: []const u8, key: u64) bool {
    return name.len == 9 and key == KEY.PLAINTEXT and tables.lower(name[8]) == 't';
}

/// Returns true when `new_tag` can trigger optional-close logic.
pub inline fn mayTriggerImplicitCloseWithKey(new_tag: []const u8, new_key: u64) bool {
    return switch (new_tag.len) {
        1 => new_key == KEY.P,
        2 => switch (new_key) {
            KEY.LI,
            KEY.DT,
            KEY.DD,
            KEY.TR,
            KEY.TD,
            KEY.TH,
            KEY.HR,
            KEY.H1,
            KEY.H2,
            KEY.H3,
            KEY.H4,
            KEY.H5,
            KEY.H6,
            KEY.DL,
            KEY.OL,
            KEY.UL,
            => true,
            else => false,
        },
        3 => switch (new_key) {
            KEY.DIV,
            KEY.NAV,
            KEY.PRE,
            => true,
            else => false,
        },
        4 => switch (new_key) {
            KEY.BODY,
            KEY.FORM,
            KEY.MAIN,
            => true,
            else => false,
        },
        5 => switch (new_key) {
            KEY.ASIDE,
            KEY.TABLE,
            => true,
            else => false,
        },
        6 => switch (new_key) {
            KEY.OPTION,
            KEY.FOOTER,
            KEY.HEADER,
            KEY.ADDRESS,
            KEY.ARTICLE,
            KEY.SECTION,
            => true,
            else => false,
        },
        7 => switch (new_key) {
            KEY.FIELDSET => true,
            else => false,
        },
        10 => switch (new_key) {
            KEY.BLOCKQUOTE => tables.lower(new_tag[8]) == 't' and tables.lower(new_tag[9]) == 'e',
            else => false,
        },
        else => false,
    };
}

/// Returns true when `open_tag` is an optional-close source tag.
pub fn isImplicitCloseSourceWithKey(open_tag: []const u8, open_key: u64) bool {
    return switch (open_tag.len) {
        1 => open_key == KEY.P,
        2 => switch (open_key) {
            KEY.LI,
            KEY.DT,
            KEY.DD,
            KEY.TR,
            KEY.TD,
            KEY.TH,
            => true,
            else => false,
        },
        4 => switch (open_key) {
            KEY.HEAD => true,
            else => false,
        },
        6 => switch (open_key) {
            KEY.OPTION => true,
            else => false,
        },
        else => false,
    };
}

/// Optional-close predicate with precomputed `(len,key)` fast path.
pub fn shouldImplicitlyCloseWithKeys(open_tag: []const u8, open_key: u64, new_tag: []const u8, new_key: u64) bool {
    return switch (open_tag.len) {
        1 => open_key == KEY.P and closesPWithKey(new_tag, new_key),
        2 => switch (open_key) {
            KEY.LI => new_key == KEY.LI,
            KEY.DT, KEY.DD => new_key == KEY.DT or new_key == KEY.DD,
            KEY.TR => new_key == KEY.TR,
            KEY.TD, KEY.TH => new_key == KEY.TD or new_key == KEY.TH,
            else => false,
        },
        4 => switch (open_key) {
            KEY.HEAD => new_key == KEY.BODY,
            else => false,
        },
        6 => switch (open_key) {
            KEY.OPTION => new_key == KEY.OPTION,
            else => false,
        },
        else => false,
    };
}

fn closesPWithKey(new_tag: []const u8, new_key: u64) bool {
    return switch (new_tag.len) {
        1 => new_key == KEY.P,
        2 => switch (new_key) {
            KEY.HR,
            KEY.H1,
            KEY.H2,
            KEY.H3,
            KEY.H4,
            KEY.H5,
            KEY.H6,
            KEY.DL,
            KEY.OL,
            KEY.UL,
            => true,
            else => false,
        },
        3 => switch (new_key) {
            KEY.DIV,
            KEY.NAV,
            KEY.PRE,
            => true,
            else => false,
        },
        4 => switch (new_key) {
            KEY.FORM,
            KEY.MAIN,
            => true,
            else => false,
        },
        5 => switch (new_key) {
            KEY.ASIDE,
            KEY.TABLE,
            => true,
            else => false,
        },
        6 => switch (new_key) {
            KEY.FOOTER,
            KEY.HEADER,
            KEY.ADDRESS,
            KEY.ARTICLE,
            KEY.SECTION,
            => true,
            else => false,
        },
        7 => switch (new_key) {
            KEY.FIELDSET => true,
            else => false,
        },
        10 => switch (new_key) {
            KEY.BLOCKQUOTE => tables.lower(new_tag[8]) == 't' and tables.lower(new_tag[9]) == 'e',
            else => false,
        },
        else => false,
    };
}

/// Fast check for `svg` tag by `(len,key)`.
pub inline fn isSvgWithKey(name: []const u8, key: u64) bool {
    return name.len == 3 and key == KEY.SVG;
}

test "tag helpers on canonical lowercase names" {
    try std.testing.expect(isVoidTag("img"));
    try std.testing.expect(isRawTextTag("script"));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "blockquote", KEY.BLOCKQUOTE));
}

test "equalByLenAndKeyIgnoreCase handles long names with canonical keys" {
    const a = "blockquote";
    const b = "blockquote";
    try std.testing.expect(equalByLenAndKeyIgnoreCase(a, first8Key(a), b, first8Key(b)));
}
